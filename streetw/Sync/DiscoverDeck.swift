// DiscoverDeck.swift
// The supply behind the Discover tab: paging, what has already been looked at, and the
// order the cards come out in.
//
// This holds the feed rather than a view doing it, for the reason `ContentView` learned the
// hard way: a `@Query` at the root subscribes the whole view tree to a table, and this deck
// needs a wardrobe, a taste vector and a dismissal list — three queries — to rank anything.
// Held here, none of them are in the dependency graph, and a card arriving from the network
// does not rebuild the tab bar.
//
// **Nothing here is written to SwiftData.** A discovery card is a garment from a brand
// nobody follows, and the store's feed query is `#Predicate<BrandUpdate> { !$0.isSeen }` —
// so persisting these would empty every other catalogue in the system into somebody's feed.
// Only a *save* writes a row, and `DiscoverSave` writes it already seen.

import Foundation
import OSLog
import StreetwCore
import SwiftUI

/// What the deck needs to know about the person to rank anything.
///
/// Passed in rather than queried, so the deck owns no `@Query` and the view decides when
/// this has genuinely changed. Equatable so a `.task(id:)` can key on it — the ranking is a
/// pass over every held card and must not run per `body`.
struct DeckContext: Equatable {
    /// What they own, as `Pairing` wants it. Empty is ordinary — most people have saved
    /// nothing on day one — and produces a deck ranked on nothing, which is honest.
    var wardrobe: [Garment] = []
    /// The centroid of what they keep. Empty below `BrandSuggestions.minimumSavesToReRank`.
    var taste: BrandVector = BrandVector()
    /// Brands explicitly refused. Local, and they stay local: the server is never told what
    /// somebody turned down.
    var dismissed: Set<UUID> = []
    /// How many of each essential slot they own, for `WardrobeGap`.
    var owned: [GarmentSlot: Int] = [:]
    /// The one filter that hides. Size reorders and never hides — see `SizeProfile`.
    ///
    /// The preference rather than a flag beside it: `GenderPreference.everything` is already
    /// "no filter", and a separate boolean would be a second way to say the same thing that
    /// could disagree with the first.
    var gender: GenderPreference = .everything
    /// What they have written about themselves, which can overrule the colour wheel.
    var statement: StyleStatement = StyleStatement()
    /// An optional slot narrowing, from the chip row.
    var slot: GarmentSlot?
}

/// What a card is *saying*, which decides how it is drawn.
///
/// **Three voices, and which one a card gets is decided by what the app can actually back
/// up** — not by a rotation and not at random. That is the same rule the rest of the feed
/// follows: the reason a card gives is the reason the ranking used, or there is no reason.
///
/// It also fixes something the single-voice version got wrong. Every card looked identical,
/// so a feed of forty was forty of the same sentence with different photographs — and the
/// cold-start case, where nobody has saved anything and there is no pairing to print, had no
/// voice of its own at all and fell back to a limp category line.
enum DeckPresentation: Equatable {
    /// "Look at this brand's new collection." The strongest and the rarest — a named season
    /// is more interesting than any one garment in it.
    case release
    /// "This piece would go with your olive cargos." The one sentence no catalogue could
    /// write, and only available once there is a wardrobe to write it against.
    case pairing
    /// "Look at this brand." The fallback, and deliberately not a lesser one: it is what an
    /// exploration slot is for, and it is the whole of what the app can honestly say to
    /// somebody on their first day.
    case brand
}

/// One card, with everything the view needs already worked out.
struct DeckCard: Identifiable, Equatable {
    var card: DiscoverCard
    /// The pieces from the wardrobe this was matched against, best first. Empty when there
    /// is no wardrobe or nothing paired — and the card then says nothing rather than
    /// inventing a reason.
    var pairs: [Garment] = []
    /// The line the card prints. Nil is a real state: `Pairing` returns no reason when
    /// nothing has been measured, and printing one anyway would be a claim we cannot back.
    var reason: String?
    /// Whether this was placed by the ranking or by an exploration slot. The two say
    /// different things on screen, and a card must never claim the first while being the
    /// second.
    var isExploration: Bool = false
    /// Which of the three voices this card speaks in.
    var presentation: DeckPresentation = .brand

    var id: String { card.productExternalID }
}

@MainActor
@Observable
final class DiscoverDeck {
    private static let log = Logger(subsystem: "com.kern.functional.streetw", category: "discover")

    /// The ordered feed, as the view draws it.
    private(set) var cards: [DeckCard] = []
    private(set) var isLoading = false
    /// The catalogue is spent. Said out loud rather than looped — a feed that starts again
    /// at the top is claiming to have more, which is the one thing it must not do.
    private(set) var isExhausted = false

    /// Raw pages, before ranking. Kept separately so re-ranking on a wardrobe change costs
    /// no network.
    private var held: [DiscoverCard] = []
    private var cursor: String?
    private var saturation = Saturation()
    private var context = DeckContext()

    /// How close to the end a scroll gets before the next page is asked for. Three, so the
    /// request is in flight well before anybody reaches the bottom — a paging feed that
    /// stalls visibly is worse than one that loads a little eagerly.
    static let prefetchMargin = 3

    // MARK: - What has already been looked at

    /// Products that have gone past, so a second session does not open on the same jacket.
    ///
    /// **Local, and it stays local.** The server pages by depth and knows nothing about what
    /// was actually shown, which is deliberate: what somebody scrolled past is a behavioural
    /// record, and the only other behavioural signals in this app — the taste vector, the
    /// dismissals, the style statement — are all local for the same reason.
    ///
    /// Capped and ordered, oldest first. A set would be cheaper to test and impossible to
    /// trim, and an unbounded ledger is a `UserDefaults` key that grows forever on a feed
    /// designed to be scrolled.
    private static let seenKey = "discoverSeen"
    private static let seenLimit = 2000

    private var seen: [String] {
        get { UserDefaults.standard.stringArray(forKey: Self.seenKey) ?? [] }
        set {
            UserDefaults.standard.set(Array(newValue.suffix(Self.seenLimit)), forKey: Self.seenKey)
        }
    }

    private var seenSet: Set<String> = []

    init() {
        seenSet = Set(seen)
    }

    /// Marks a card as looked at. Called when it reaches the screen, not when it is
    /// fetched — a page held in memory that nobody scrolled to has not been seen.
    func markSeen(_ id: String) {
        guard !seenSet.contains(id) else { return }
        seenSet.insert(id)
        seen.append(id)
    }

    // MARK: - Paging

    func loadIfNeeded(remote: RemoteSync, settings: ServerSettings) async {
        guard settings.isConfigured, settings.isRegistered else { return }
        guard !isLoading, !isExhausted else { return }
        await load(remote: remote)
    }

    /// Asks for the next page when the visible card is near the end of what is held.
    func loadMoreIfNeeded(
        reaching index: Int,
        remote: RemoteSync,
        settings: ServerSettings
    ) async {
        guard index >= cards.count - Self.prefetchMargin else { return }
        await loadIfNeeded(remote: remote, settings: settings)
    }

    /// How many consecutive already-seen pages one call will skip past.
    ///
    /// A page that is entirely already-seen is not the end of the catalogue — it is somebody
    /// who has been scrolling for a while, and the ledger holds two thousand ids. So an
    /// empty result keeps asking. Bounded because that is a network loop, and because
    /// somebody is waiting on it: past this the deck returns what it has and the next scroll
    /// asks again, which is slower and cannot hang.
    private static let maxSkippedPages = 5

    private func load(remote: RemoteSync) async {
        isLoading = true
        defer { isLoading = false }

        for _ in 0..<Self.maxSkippedPages {
            do {
                let page = try await remote.discover(cursor: cursor)
                cursor = page.nextCursor
                if page.nextCursor == nil { isExhausted = true }

                // Deduplicated against what is held as well as against the ledger. The
                // server's enumeration is a partition and should never repeat, but a page
                // held across a re-rank plus a retry could, and one jacket appearing twice in
                // a scroll reads as the whole feed being broken.
                let known = Set(held.map(\.productExternalID))
                let fresh = page.cards.filter {
                    !known.contains($0.productExternalID) && !seenSet.contains($0.productExternalID)
                }

                if !fresh.isEmpty {
                    held += fresh
                    rank()
                    return
                }
                if isExhausted { return }
            } catch {
                // Quiet and non-fatal: the deck keeps what it has, and the obvious recovery
                // is to keep scrolling, which asks again.
                Self.log.info("discover page failed: \(error.localizedDescription)")
                return
            }
        }
    }

    // MARK: - Ranking

    /// Re-ranks against a changed wardrobe. Cheap enough to call on change, far too
    /// expensive to call per `body` — it runs `Pairing` over every held card.
    func update(context: DeckContext) {
        guard context != self.context else { return }
        self.context = context
        rank()
    }

    /// A brand was followed or refused: its cards leave, and its saturation goes with them.
    ///
    /// Both halves matter. Leaving the penalty behind would mean that un-refusing a brand
    /// later — or following and then unfollowing — carried a handicap earned by cards
    /// nobody can see any more.
    func forget(brandID: UUID) {
        held.removeAll { $0.brand.id == brandID }
        saturation.forget(brandID)
        rank()
    }

    private func rank() {
        // Saturation is rebuilt from scratch on every rank rather than carried through it.
        // Carrying it would make the order depend on how many times the wardrobe happened to
        // change while scrolling, so scrolling back would show a different card — the
        // property `Discovery.order` is deterministic in order to give.
        var fresh = Saturation()
        let gaps = WardrobeGap.weights(owned: context.owned)

        var byID: [String: DeckCard] = [:]
        var candidates: [DiscoveryCandidate] = []

        for card in held {
            // The one filter that hides. Short-circuited the way `BrandUpdate.passes` is:
            // `allows` answers true immediately for `.everything`, but Swift evaluates the
            // argument first, and `itemGender` is a classifier run.
            if context.gender != .everything, !context.gender.allows(card.itemGender) { continue }

            let garment = card.garment
            if let wanted = context.slot, garment.slot != wanted { continue }

            let best = Pairing.best(
                for: garment,
                from: context.wardrobe,
                limit: 2,
                statement: context.statement
            )

            // Affinity has two sources and a fallback. The pairing verdict is the sharpest —
            // it is about *these clothes* — but it needs a wardrobe, so a taste similarity
            // stands in when there is nothing owned yet, and neither is available on day one.
            var affinity: Double
            if let top = best.first {
                affinity = top.verdict.score
            } else if let vector = card.vector, !context.taste.isEmpty {
                affinity = context.taste.similarity(to: vector)
            } else {
                affinity = 0.5
            }
            // A release cannot produce a pairing verdict — it has no garment slot, so
            // `Pairing`'s gate refuses it before scoring — and would otherwise lose to every
            // jacket in the deck on a bare vector similarity. See `Discovery.releaseFloor`.
            if card.isRelease { affinity = max(affinity, Discovery.releaseFloor) }

            // "Familiar" means the taste profile has something to say, not that the brand is
            // any good. A card with no vector, or a vector sharing nothing with what somebody
            // keeps, is exactly what an exploration slot is for.
            let isFamiliar: Bool = {
                guard !context.taste.isEmpty, let vector = card.vector else { return false }
                return context.taste.similarity(to: vector) > 0
            }()

            // The voice, decided by what is true rather than by a rotation. A release is a
            // release whatever else is going on; a pairing needs a wardrobe to pair against;
            // and a brand card is what is left, which is also what an exploration slot and a
            // first-day user get.
            let presentation: DeckPresentation = card.isRelease
                ? .release
                : (best.isEmpty ? .brand : .pairing)

            let id = card.productExternalID
            byID[id] = DeckCard(
                card: card,
                pairs: best.map(\.garment),
                reason: best.first?.verdict.reason,
                presentation: presentation
            )
            candidates.append(
                DiscoveryCandidate(
                    id: id,
                    brandID: card.brand.id ?? UUID(),
                    slot: garment.slot,
                    affinity: affinity,
                    isFamiliar: isFamiliar
                )
            )
        }

        let ordered = Discovery.order(candidates, saturation: &fresh, gaps: gaps)
        saturation = fresh

        cards = ordered.enumerated().compactMap { position, candidate in
            guard var card = byID[candidate.id] else { return nil }
            card.isExploration = Discovery.isExploration(position: position)
            // An exploration card is not being shown because it goes with anything, so it
            // must not print a sentence claiming it does. Same rule `sharedTraits` follows:
            // the reason a card gives is the reason the ranking used, or there is no reason.
            if card.isExploration {
                card.pairs = []
                card.reason = nil
                // It was not placed for a pairing, so it must not speak as one. A release
                // keeps its own voice — an exploration slot is about *which* brand is shown,
                // not about what the card is allowed to say it is.
                if card.presentation == .pairing { card.presentation = .brand }
            }
            return card
        }
    }
}

extension DiscoverCard {
    /// The card as `Pairing` sees it.
    ///
    /// Colour, busyness and text coverage are absent until `DiscoveryAnalysis` has looked at
    /// the photograph — and `Pairing` scores a nil colour as **neutral rather than badly**,
    /// which is what lets the whole deck rank and print a sentence before a single image has
    /// been decoded. The measured reading only ever sharpens the answer.
    var garment: Garment {
        Garment(
            id: productExternalID,
            title: title,
            productType: productType,
            tags: tags
        )
    }
}
