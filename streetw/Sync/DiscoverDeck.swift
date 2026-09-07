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
    /// The **remote** ids of the brands they follow.
    ///
    /// `/v1/discover`'s candidates are by construction the brands nobody here follows, so
    /// this exists for the other supply: the unread garments from brands they *do* follow
    /// that `FollowedSupply` hands over. A card whose brand is in here is drawn differently
    /// — no Follow, no "not for me", both of those decisions having already been made — and
    /// is never eligible for an exploration slot, which is for a label the ranking has no
    /// opinion about and is the opposite of one somebody chose.
    var followed: Set<UUID> = []
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
    /// Whether this came from a brand they already follow — see `FollowedSupply`.
    ///
    /// It changes what the card is allowed to offer, not how it is ranked: Follow and "not
    /// for me" are both verdicts on a shop that has already been judged, and offering either
    /// again is the app failing to remember a decision somebody made.
    var isFollowed: Bool = false
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
    /// The other supply: unread garments from brands they already follow, read out of the
    /// store by the view rather than fetched. See `FollowedSupply` for what qualifies and
    /// why this is not simply the feed again. Kept apart from `held` because it is replaced
    /// wholesale on every change rather than paged onto the end.
    private var local: [DiscoverCard] = []
    private var cursor: String?
    private var saturation = Saturation()
    private var context = DeckContext()

    /// How close to the end a scroll gets before the next page is asked for.
    ///
    /// **Ten, and it used to be three**, which was set purely so the request is in flight
    /// before anybody reaches the bottom. That is necessary and not sufficient: a page is one
    /// group of about fifteen brands, so with a margin of three a reader worked through
    /// nearly all of a page — every one of those brands, twice — before a single new brand
    /// could join the ordering. The next page's cards land in the *unpinned* tail and are
    /// ranked together with what is left of this one, so asking earlier does not merely
    /// prevent a stall, it widens the pool the rest of the scroll is drawn from. This is the
    /// second half of the fix `Discovery.defaultPerBrand` describes: one spaces a brand's own
    /// cards a full round apart, this makes the round longer.
    static let prefetchMargin = 10

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

    /// The ledger as it stood when the app launched, which is a different question from
    /// `seenSet` and the two must not be confused.
    ///
    /// A server page is filtered against the ledger **once**, when it arrives, and never
    /// again — so a card scrolled past stays in the deck for the rest of the session and
    /// `pinningRead` keeps it where it was read. The followed-brand supply is handed over
    /// repeatedly (it is rebuilt whenever the unread set changes), so filtering it against
    /// the *live* set would delete the cards somebody had just scrolled past, out of the
    /// middle of the list, while they were still scrolling. Same session, same rule: what was
    /// already read before today does not come back; what was read a minute ago stays put.
    private let seenAtLaunch: Set<String>

    init() {
        let ledger = Set(UserDefaults.standard.stringArray(forKey: Self.seenKey) ?? [])
        seenSet = ledger
        seenAtLaunch = ledger
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

    /// Takes the current offer from the brands they follow. See `FollowedSupply`.
    ///
    /// Replaced wholesale rather than accumulated: the set shrinks as things are read in the
    /// feed and grows as a sync lands, and reconciling that incrementally is the class of
    /// drift `DropReminders.refresh` refuses for the same reason. Cheap when nothing changed,
    /// because ranking is a `Pairing` pass over every card in the deck.
    ///
    /// Filtered against `seenAtLaunch`, not the live ledger — see that property.
    func adopt(followed cards: [DiscoverCard]) {
        // **Anything already scrolled past stays, whatever the store now says.** Reading one
        // of these in the feed — or with the card's own "mark read" — takes it out of the
        // unread query and therefore out of `cards` here, and dropping it would shorten the
        // deck *above* the reader on the very tap that did it, sliding the next card up under
        // their thumb. That is the failure `pinningRead` exists to prevent, arriving through
        // the supply rather than through the ranking. Cards ahead of the line are free to
        // come and go, because nobody has seen them.
        let kept = local.filter { seenSet.contains($0.productExternalID) }
        let keptIDs = Set(kept.map(\.productExternalID))
        let fresh = cards.filter {
            !keptIDs.contains($0.productExternalID) && !seenAtLaunch.contains($0.productExternalID)
        }
        let next = kept + fresh
        guard next.map(\.id) != local.map(\.id) else { return }
        local = next
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
        /// Every unfollowed card's taste similarity, for the page-relative familiarity
        /// cutoff, and the same figure per card so the verdict can be applied afterwards.
        var similarities: [Double] = []
        var pendingFamiliarity: [String: Double?] = [:]
        /// Every ranked pairing's reason, by card and then by wardrobe garment — so
        /// `spreadAnchors` can move the anchor and take the right sentence with it.
        var reasons: [String: [String: String?]] = [:]

        // Both supplies, ranked as one pool. They are separate arrays because they arrive
        // differently — one is paged and appended, the other replaced wholesale — and one
        // list because every rule in `Discovery` is about the whole run: a per-brand cap that
        // did not see the followed-brand cards would let a brand mid-drop take a position in
        // each half.
        //
        // Deduplicated by id, and the server cannot produce a collision (its candidates are
        // by construction the brands nobody here follows) — but a follow made *during* a
        // session leaves that brand's cards in `held` until the next `forget`, and one
        // garment appearing twice in a scroll reads as the whole feed being broken.
        var supplied: [DiscoverCard] = []
        var suppliedIDs: Set<String> = []
        for card in local + held where suppliedIDs.insert(card.productExternalID).inserted {
            supplied.append(card)
        }

        for card in supplied {
            let isFollowed = card.brand.id.map { context.followed.contains($0) } ?? false

            // **A refused brand stays refused, including on pages fetched afterwards.**
            //
            // `forget(brandID:)` drops that brand's cards out of `held` the moment "not for
            // me" is tapped, and that was the whole of the mechanism — so the refusal held
            // exactly until the next page arrived. The server pages by depth and knows
            // nothing about dismissals (deliberately: what somebody turned down never leaves
            // the phone), so the brand came straight back, three cards later, from the tab
            // whose one negative signal is supposed to be permanent. `context.dismissed` was
            // already being assembled and passed in and nothing read it.
            if let brandID = card.brand.id, context.dismissed.contains(brandID) { continue }

            // The one filter that hides. Short-circuited the way `BrandUpdate.passes` is:
            // `allows` answers true immediately for `.everything`, but Swift evaluates the
            // argument first, and `itemGender` is a classifier run.
            if context.gender != .everything, !context.gender.allows(card.itemGender) { continue }

            let garment = card.garment
            if let wanted = context.slot, garment.slot != wanted { continue }

            // **Ranked deep, not shallow.** Two was enough while the card printed only the
            // winner; it is not enough for `spreadAnchors` to have anything to choose from,
            // and the truncation is free — `Pairing.best` scores the whole wardrobe either
            // way and `limit` only cuts the tail off the answer.
            let best = Pairing.best(
                for: garment,
                from: context.wardrobe,
                limit: Self.anchorPool,
                statement: context.statement
            )

            // Affinity has two sources and a fallback. The pairing verdict is the sharpest —
            // it is about *these clothes* — but it needs a wardrobe, so a taste similarity
            // stands in when there is nothing owned yet, and neither is available on day one.
            // Computed once and read twice — for the affinity fallback here, and for the
            // familiarity cutoff below. Nil means there is nothing to compare: no vector on
            // the card, or nothing saved yet to compare it against.
            let similarity: Double? = context.taste.isEmpty
                ? nil
                : card.vector.map { context.taste.similarity(to: $0) }

            var affinity: Double
            if let top = best.first {
                affinity = top.verdict.score
            } else if let similarity {
                affinity = similarity
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
            //
            // A brand they follow is familiar by definition, whatever the vectors say — and
            // `FollowedSupply` sends no vector at all, so without this every followed card
            // would be *unfamiliar* and therefore first in line for the exploration slots.
            // Those exist to show a label the ranking has no opinion about; filling them with
            // shops somebody already chose is the exact inversion of the point.
            // Decided after the loop, because it is relative to the rest of the page — see
            // `Discovery.familiarityCutoff` for why an absolute test could not work. A
            // followed brand is familiar by definition whatever the vectors say, and never
            // takes part in the cutoff: `FollowedSupply` sends no vector at all, so without
            // this every followed card would be *unfamiliar* and therefore first in line for
            // the exploration slots — filling the one position reserved for shops somebody
            // has never seen with the shops they picked themselves.
            if !isFollowed, let similarity { similarities.append(similarity) }

            // The voice, decided by what is true rather than by a rotation. A release is a
            // release whatever else is going on; a pairing needs a wardrobe to pair against;
            // and a brand card is what is left, which is also what an exploration slot and a
            // first-day user get.
            //
            // A followed card is **always** about the garment, even with nothing to pair it
            // against. Two reasons, and the second is a hard one: a `.brand` card is drawn as
            // a mosaic of `spread`, which `FollowedSupply` deliberately does not send — a
            // wall of "six more things this label makes" is an argument for following a shop
            // that has already been followed — so falling through to `.brand` would draw an
            // empty grid. And the card is *news about one product*, which is what `.pairing`
            // already means here.
            let presentation: DeckPresentation = card.isRelease
                ? .release
                : (isFollowed || !best.isEmpty ? .pairing : .brand)

            let id = card.productExternalID
            byID[id] = DeckCard(
                card: card,
                pairs: best.map(\.garment),
                reason: best.first?.verdict.reason,
                isFollowed: isFollowed,
                presentation: presentation
            )
            reasons[id] = Dictionary(
                best.map { ($0.garment.id, $0.verdict.reason) },
                uniquingKeysWith: { first, _ in first }
            )
            candidates.append(
                DiscoveryCandidate(
                    id: id,
                    // **Not a fresh `UUID()`.** A nil brand id used to mint a new random one
                    // per card per `rank()`, which defeats the per-brand cap for every card
                    // holding one — they are all "different brands" — and puts an RNG in the
                    // one path documented as having none, so scrolling back could show a
                    // different order. `Discovery.unattributed` is a fixed id: cards with no
                    // brand are then capped *together*, which is the safe reading of "we do
                    // not know who made these".
                    brandID: card.brand.id ?? Discovery.unattributed,
                    slot: garment.slot,
                    affinity: affinity,
                    isFamiliar: isFollowed
                )
            )
            pendingFamiliarity[id] = isFollowed ? nil : similarity
        }

        // The cutoff needs the whole page, so familiarity is settled here rather than in the
        // loop above. A card with no vector stays unfamiliar — no opinion is exactly what an
        // exploration slot is for — and a followed brand stays familiar.
        if let cutoff = Discovery.familiarityCutoff(similarities) {
            for index in candidates.indices where !candidates[index].isFamiliar {
                let similarity = pendingFamiliarity[candidates[index].id] ?? nil
                candidates[index].isFamiliar = (similarity ?? 0) > cutoff
            }
        }

        let ranked = Discovery.order(candidates, saturation: &fresh, gaps: gaps)

        // **The flag belongs to the slot the ordering chose, not to the position the card
        // ends up at.** `pinningRead` moves the card being read back to the top, which shifts
        // every position after it — so the card `order` deliberately placed in an exploration
        // slot generally was not the one being stripped of its pairing, and some
        // well-targeted card was instead. Marked against the ranked order, then applied by
        // id after the pin.
        let exploring = Set(
            ranked.enumerated()
                .filter { Discovery.isExploration(position: $0.offset) }
                .map(\.element.id)
        )

        let ordered = pinningRead(ranked)
        saturation = fresh

        cards = ordered.compactMap { candidate in
            guard var card = byID[candidate.id] else { return nil }
            card.isExploration = exploring.contains(candidate.id)
            // An exploration card is not being shown because it goes with anything, so it
            // must not print a sentence claiming it does. Same rule `sharedTraits` follows:
            // the reason a card gives is the reason the ranking used, or there is no reason.
            if card.isExploration {
                card.pairs = []
                card.reason = nil
                // It was not placed for a pairing, so it must not speak as one. A release
                // keeps its own voice — an exploration slot is about *which* brand is shown,
                // not about what the card is allowed to say it is.
                //
                // **Except a followed brand, which has no `.brand` card to fall back to.**
                // `FollowedSupply` sends `spread: []` deliberately — a wall of "six more
                // things this label makes" is an argument for following a shop that has
                // already been followed — and `.brand` is drawn as a mosaic of that spread,
                // so downgrading one produced a wordmark on an empty card. Cards 4, 8 and 12
                // were blank whenever the deck was showing followed supply ahead of the first
                // `/v1/discover` page, which is every cold launch. It keeps its own voice and
                // loses only the pairing sentence, which is what an exploration slot is
                // actually about. Rare now that `familiarityCutoff` keeps followed cards out
                // of these slots in the first place — but the fallback pool can still put one
                // here rather than leave a hole, so the guard stays.
                if card.presentation == .pairing, !card.isFollowed { card.presentation = .brand }
            }
            return card
        }
        spreadAnchors(reasons: reasons)
    }

    /// How many of the wardrobe's answers a card keeps, so there is something to spread with.
    private static let anchorPool = 8

    /// Gives consecutive cards **different** things out of the wardrobe to point at.
    ///
    /// The symptom was that every card in the feed said the same sentence about the same
    /// garment. The cause is not a bug in `Pairing` — it is what a tie looks like at scale.
    /// `ImageTagger` runs over saves and `DiscoveryAnalysis` over the cards at the viewport,
    /// so most of a wardrobe has no measured colour yet; with nothing to separate them,
    /// `ColorHarmony` scores every candidate identically, the layering bonus is the only thing
    /// that moves, and `Pairing.best` breaks the tie on `id` — deterministically, and
    /// therefore on the *same* garment for every card in the deck. Correct arithmetic,
    /// useless output: forty cards claiming to go with one jacket reads as the feature being
    /// broken, and it is exactly the "same sentence forty times" failure `DeckPresentation`
    /// was written to fix one level up.
    ///
    /// So the anchor is chosen across the deck rather than per card: each card takes its
    /// best-ranked pairing that no earlier card has used, and the pool is recycled once it is
    /// spent — the same round-robin `Discovery.interleave` uses to stop one brand owning a
    /// page, pointed at the wardrobe instead. **The reason moves with the anchor**, or the
    /// card would print the verdict for a garment it is no longer showing.
    ///
    /// Deterministic: it reads the final order and nothing else, so scrolling back shows the
    /// same card making the same argument.
    private func spreadAnchors(reasons: [String: [String: String?]]) {
        var used: Set<String> = []
        for index in cards.indices {
            let options = cards[index].pairs
            guard options.count > 1 else {
                if let only = options.first { used.insert(only.id) }
                continue
            }
            var choice = options.first { !used.contains($0.id) }
            if choice == nil {
                // Everything on offer has been spent. Start the rotation again rather than
                // falling back to the top-ranked one forever, which is the behaviour this
                // exists to end.
                used.removeAll()
                choice = options.first
            }
            guard let anchor = choice else { continue }
            used.insert(anchor.id)
            cards[index].pairs = [anchor] + options.filter { $0.id != anchor.id }
            cards[index].reason = reasons[cards[index].id]?[anchor.id] ?? nil
        }
    }

    /// Keeps everything already scrolled past exactly where it was, and orders only the rest.
    ///
    /// **A re-rank must not move the card somebody is looking at.** Every input to the ranking
    /// changes *while the feed is open*: saving a garment changes the wardrobe, which changes
    /// `deckContext`, which re-ranks — so keeping something with the bookmark, or with the
    /// double tap, could shuffle the deck under the reading thumb and leave a different card
    /// in front of you than the one you just acted on. That is the failure `FeedView`
    /// documents at length for brand ordering and the reason `Discovery.order` has no RNG in
    /// it, arriving through a door neither of them was watching.
    ///
    /// The line is `seenSet`, which is already maintained for exactly this notion of "has
    /// been reached" — marked when a card lands on screen rather than when it was fetched.
    /// Cards behind that line keep the order they were read in; everything ahead is ordered
    /// freely, which is where a sharper wardrobe should be spent anyway. Filtering still
    /// applies to both halves: a brand refused or followed leaves the deck wherever it sat.
    private func pinningRead(_ ordered: [DiscoveryCandidate]) -> [DiscoveryCandidate] {
        let read = cards.map(\.id).filter { seenSet.contains($0) }
        guard !read.isEmpty else { return ordered }

        let position = Dictionary(
            read.enumerated().map { ($0.element, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        var pinned = [DiscoveryCandidate?](repeating: nil, count: read.count)
        var rest: [DiscoveryCandidate] = []
        for candidate in ordered {
            if let slot = position[candidate.id] {
                pinned[slot] = candidate
            } else {
                rest.append(candidate)
            }
        }
        return pinned.compactMap { $0 } + rest
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
