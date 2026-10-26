// FeedTimeline.swift
// The feed as one list of events, newest first across every brand, with a line where the
// last visit ended.
//
// It lives here rather than beside the view for the reason `FeedPager` does: the app has no
// test target, and what belongs on one card, which card goes first and which side of the
// line it falls are the whole of the screen's correctness. The view turns rows into
// `Entry`s, asks this for cards, and draws them; nothing in here knows SwiftData exists.

import Foundation

/// How the feed's rows become cards, and in what order.
///
/// **The unit is the event, and a card is one event or one moment.** 1.0 grouped the feed by
/// brand — a wordmark header, a stack of stories under it, counts and "›" links — and that
/// grouping is what produced the counts nobody could reconcile and the checkmarks somebody
/// had to manage. Phase 1 draws one card per event, newest first across every brand. The rule
/// the grouping protected survives, because it was never really about brands: one busy brand
/// must not flood the feed. So the things that happened *together* still become one card —
///
/// - **a release** (`.collection`) is one card, and the garments that landed with it are its
///   contents rather than cards of their own;
/// - **a burst** — `burstMinimum` or more events of one kind from one brand inside
///   `burstWindow` — is one card: a 24-piece drop, twelve restocks in one pass, a sale rail
///   of eighteen markdowns.
///
/// Everything else is a card of its own.
public enum FeedTimeline {
    /// Events of one kind from one brand this close together were one moment.
    ///
    /// Thirty minutes, anchored at the first event rather than chained from the last. A
    /// storefront publishes a drop in one write — Represent's 250 newest products carry 154
    /// distinct timestamps, mostly seconds apart — and the server stamps a poll's events with
    /// the poll, so a real drop sits well inside it. Chaining would let a brand that trickles
    /// one product every twenty minutes become a single card spanning a week.
    public static let burstWindow: TimeInterval = 30 * 60

    /// Three, because two is a coincidence and a pair of cards is not a flood.
    public static let burstMinimum = 3

    /// How long after a release its own garments are still part of the announcement rather
    /// than news of their own.
    ///
    /// The old spread got this window for free — a release and its garments were unread
    /// together — and a timeline has to say it. Three days covers a brand that shelves a
    /// release's contents over a weekend; a member restocked a month later is a restock, and
    /// is shown as one.
    public static let releaseWindow: TimeInterval = 3 * 86_400

    /// One row of the store, reduced to what placing it needs.
    public struct Entry: Sendable, Hashable, Identifiable {
        /// The row's own key — `BrandUpdate.externalID`. Unique, stable across relaunches,
        /// and the tiebreak in every ordering, for the reason `BrandUpdate.newestFirst`
        /// gives.
        public var id: String
        /// Which brand, as any stable string.
        public var brand: String
        public var kind: UpdateKind
        /// When it happened — `publishedAt`, the event's time.
        public var happenedAt: Date
        /// When it reached this phone as news — `BrandUpdate.arrivedAt`. What decides which
        /// side of the line it falls, and nothing else.
        public var arrivedAt: Date
        /// The garment, as `oncePerProduct` keys one. The row's own id when there is none.
        public var product: String
        /// A restock in a size the reader wears (`SizeProfile.claims`). Such a card is never
        /// folded into anything: it is the most specific thing the feed can say, and a
        /// "BACK IN STOCK · 12 PIECES" mosaic with it somewhere inside would bury it.
        public var isYours: Bool
        /// For a release, the garments in it — what the storefront said, else the word match
        /// (`Brand.members(of:)`'s order). Empty for every other kind.
        public var releaseMembers: Set<String>

        public init(
            id: String,
            brand: String,
            kind: UpdateKind,
            happenedAt: Date,
            arrivedAt: Date,
            product: String? = nil,
            isYours: Bool = false,
            releaseMembers: Set<String> = []
        ) {
            self.id = id
            self.brand = brand
            self.kind = kind
            self.happenedAt = happenedAt
            self.arrivedAt = arrivedAt
            self.product = product ?? id
            self.isYours = isYours
            self.releaseMembers = releaseMembers
        }
    }

    /// One thing on the screen.
    public struct Card: Sendable, Hashable, Identifiable {
        public enum Shape: Sendable, Hashable {
            /// One event.
            case single
            /// Several events of one kind that happened together — `entries` are the pieces.
            case group
            /// A release: `entries` is the collection's own row, then the garments it
            /// absorbed. The page behind it lists the release's whole membership.
            case release
        }

        public var id: String
        public var shape: Shape
        public var kind: UpdateKind
        public var brand: String
        /// The rows it stands for, newest first. See `Shape` for what the first one is.
        public var entries: [String]
        /// Where it sits: its newest event.
        public var happenedAt: Date
        /// Which side of the line: its latest arrival. A drop that grew since the last visit
        /// is news again, because the pieces that landed since are.
        public var arrivedAt: Date
        /// Above the line.
        public var isNew: Bool
    }

    public struct Result: Sendable, Equatable {
        /// Arrived since the last visit, newest event first.
        public var fresh: [Card] = []
        /// Everything before it, in the same order.
        public var earlier: [Card] = []

        public init(fresh: [Card] = [], earlier: [Card] = []) {
            self.fresh = fresh
            self.earlier = earlier
        }

        public var isEmpty: Bool { fresh.isEmpty && earlier.isEmpty }

        /// Narrowed by the filter row. Filtering cards rather than rows is the same answer —
        /// a card is one kind and one brand — and spares rebuilding on every tap.
        public func narrowed(to filter: FeedFilter, brand: String? = nil) -> Result {
            func keeps(_ card: Card) -> Bool {
                filter.admits(card.kind) && (brand.map { $0 == card.brand } ?? true)
            }
            return Result(fresh: fresh.filter(keeps), earlier: earlier.filter(keeps))
        }
    }

    /// The feed.
    ///
    /// - Parameters:
    ///   - boundary: when the last visit ended (`FeedVisit`). Nil means there has been none,
    ///     and everything is new — which is also what a phone coming from 1.0 sees: what it
    ///     had not read is exactly what is new to it.
    ///   - now: anything that happens after it is a date ahead, not an event, and belongs to
    ///     Upcoming.
    ///
    /// **The order is fixed by two stored dates and nothing a reader does.** Cards are ordered
    /// by when their newest event happened, ties broken on the id; the line is placed by when
    /// they arrived. Reading writes neither, so nothing on this screen moves under a thumb —
    /// the property 1.0's brand ordering had to be argued for. A sync can still put a card
    /// above the line or grow a drop, which is the feed being told something.
    public static func build(_ entries: [Entry], since boundary: Date?, now: Date) -> Result {
        // A lock is a state of the storefront, not a moment: it is said by the line above
        // the feed and under Upcoming for as long as it is true, and a card saying "drop
        // imminent" a week after the shop reopened would be a false statement at rest. A
        // date ahead is Upcoming's too.
        let events = oncePerProduct(entries.filter { $0.kind != .dropLock && $0.happenedAt <= now })

        // Releases first, because they decide what is left to group.
        var absorbed: [String: [Entry]] = [:]
        var claimed = Set<String>()
        let releases = events.filter { $0.kind == .collection }
        for release in releases where !release.releaseMembers.isEmpty {
            for entry in events where !claimed.contains(entry.id) && entry.brand == release.brand {
                guard entry.kind == .product || entry.kind == .restock, !entry.isYours,
                      release.releaseMembers.contains(entry.product),
                      abs(entry.happenedAt.timeIntervalSince(release.happenedAt)) <= releaseWindow
                else { continue }
                absorbed[release.id, default: []].append(entry)
                claimed.insert(entry.id)
            }
        }

        var cards: [Card] = releases.map { release in
            let members = absorbed[release.id] ?? []
            return card(.release, id: release.id, of: [release] + members, kind: .collection)
        }

        var groupable: [String: [Entry]] = [:]
        for entry in events where entry.kind != .collection && !claimed.contains(entry.id) {
            if isGroupable(entry) {
                groupable["\(entry.kind.rawValue)|\(entry.brand)", default: []].append(entry)
            } else {
                cards.append(card(.single, id: entry.id, of: [entry], kind: entry.kind))
            }
        }

        for (_, run) in groupable {
            for cluster in clusters(run) {
                if cluster.count >= burstMinimum, let anchor = cluster.first {
                    let id = "\(anchor.kind.rawValue)·\(anchor.brand)·\(anchor.id)"
                    cards.append(card(.group, id: id, of: cluster, kind: anchor.kind))
                } else {
                    cards += cluster.map { card(.single, id: $0.id, of: [$0], kind: $0.kind) }
                }
            }
        }

        cards.sort { $0.happenedAt == $1.happenedAt ? $0.id > $1.id : $0.happenedAt > $1.happenedAt }
        for index in cards.indices {
            cards[index].isNew = boundary.map { cards[index].arrivedAt > $0 } ?? true
        }
        return Result(fresh: cards.filter(\.isNew), earlier: cards.filter { !$0.isNew })
    }

    /// The kinds that arrive in quantity. A sale is one event per sale by construction, a
    /// release is already one card, and a post or a page change is a single statement.
    private static func isGroupable(_ entry: Entry) -> Bool {
        switch entry.kind {
        case .product, .priceDrop: true
        case .restock: !entry.isYours
        case .collection, .post, .pageChange, .dropLock, .sale: false
        }
    }

    /// Consecutive runs inside `burstWindow` of their first event, oldest first — so a card
    /// keeps its id as a drop grows forward in time.
    private static func clusters(_ run: [Entry]) -> [[Entry]] {
        let ordered = run.sorted { $0.happenedAt == $1.happenedAt ? $0.id < $1.id : $0.happenedAt < $1.happenedAt }
        var result: [[Entry]] = []
        for entry in ordered {
            if let anchor = result.last?.first,
               entry.happenedAt.timeIntervalSince(anchor.happenedAt) <= burstWindow {
                result[result.count - 1].append(entry)
            } else {
                result.append([entry])
            }
        }
        return result
    }

    private static func card(_ shape: Card.Shape, id: String, of members: [Entry], kind: UpdateKind) -> Card {
        // A release's own row stays first — it is what the card is about — and the garments
        // follow newest first, the order every list of a brand's output reads in.
        let head = shape == .release ? Array(members.prefix(1)) : []
        let rest = (shape == .release ? Array(members.dropFirst()) : members).sorted(by: newestFirst)
        let all = head + rest
        return Card(
            id: id,
            shape: shape,
            kind: kind,
            brand: members.first?.brand ?? "",
            entries: all.map(\.id),
            happenedAt: members.map(\.happenedAt).max() ?? .distantPast,
            arrivedAt: members.map(\.arrivedAt).max() ?? .distantPast,
            isNew: false
        )
    }

    /// One garment, one card: the newest event for each product, by `newestFirst`. The same
    /// rule and the same survivor as `BrandUpdate.oncePerProduct`, so a jacket that dropped on
    /// Monday and came back in an L on Thursday is Thursday's restock and nothing else.
    ///
    /// Keyed on the brand as well. `oncePerProduct` is only ever asked about one brand's
    /// output; this list is every brand's, and two shops' keys are not promised apart.
    static func oncePerProduct(_ entries: [Entry]) -> [Entry] {
        var seen = Set<String>()
        return entries.sorted(by: newestFirst).filter { seen.insert("\($0.brand)|\($0.product)").inserted }
    }

    private static func newestFirst(_ a: Entry, _ b: Entry) -> Bool {
        a.happenedAt == b.happenedAt ? a.id > b.id : a.happenedAt > b.happenedAt
    }
}

/// The feed's one row of filters: All · Drops · Restocks · Sales · Upcoming.
///
/// Brand is the sixth control and is not a case here — it narrows any of these to one shop.
public enum FeedFilter: String, CaseIterable, Sendable, Identifiable {
    case all, drops, restocks, sales, upcoming

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .all: "All"
        case .drops: "Drops"
        case .restocks: "Restocks"
        case .sales: "Sales"
        case .upcoming: "Upcoming"
        }
    }

    /// Whether a card of this kind is shown under this filter.
    ///
    /// Upcoming admits nothing from the timeline: it is a different list, of dates ahead
    /// rather than things that happened.
    public func admits(_ kind: UpdateKind) -> Bool {
        switch self {
        case .all: true
        case .upcoming: false
        case .drops, .restocks, .sales: Self.home(of: kind) == self
        }
    }

    /// Which narrowed filter a kind belongs under, or nil for All alone.
    ///
    /// A switch over every kind, the `UpdateKind.isSale` discipline: a kind added later has
    /// to be placed here and cannot land under the wrong filter by default. **A page change
    /// is a drop** — on a storefront nothing structured can read, a page watch moving is the
    /// drop, and it reached a follower of Supreme before the brand's own email did. A post is
    /// a brand's own words about anything, and stays under All.
    public static func home(of kind: UpdateKind) -> FeedFilter? {
        switch kind {
        case .product, .collection, .pageChange, .dropLock: .drops
        case .restock: .restocks
        case .priceDrop, .sale: .sales
        case .post: nil
        }
    }
}

/// The one line of words a card is allowed — "NEW", "BACK IN YOUR SIZE", "−30%", "SALE 25%
/// OFF · CODE AUTUMN".
///
/// A card is a photograph, a brand, this, and a price. **No product name**: the photograph
/// says what it is, tapping says the rest, and a title under every tile is what made 1.0's
/// first screen five lines of type for every picture.
public struct FeedLabel: Equatable, Sendable {
    public var text: String
    /// Set in vermilion. Only when it is happening now and about the reader — a size of
    /// theirs back, a storefront locking. Everything else is ink: an accent on every card is
    /// an accent on none.
    public var isUrgent: Bool

    public init(_ text: String, isUrgent: Bool = false) {
        self.text = text
        self.isUrgent = isUrgent
    }

    /// One event.
    ///
    /// - Parameters:
    ///   - isYours: a restock in a size the reader wears.
    ///   - percentOff: the cut, where one can be measured (`PriceChange.percentOff`).
    ///   - title: the event's own words — a release's name, a sale's offer.
    public static func single(_ kind: UpdateKind, isYours: Bool = false, percentOff: Int? = nil, title: String = "") -> FeedLabel {
        switch kind {
        case .product: FeedLabel("NEW")
        case .restock: isYours ? FeedLabel("BACK IN YOUR SIZE", isUrgent: true) : FeedLabel("BACK IN STOCK")
        case .priceDrop: FeedLabel(percentOff.map { "−\($0)%" } ?? "PRICE CUT")
        case .collection: release(title: title)
        case .sale: FeedLabel(saleWords(title))
        case .dropLock: FeedLabel("LOCKED · DROP IMMINENT", isUrgent: true)
        case .post: FeedLabel("NEW POST")
        case .pageChange: FeedLabel("THE SITE CHANGED")
        }
    }

    /// Several events of one kind at once. The count is on the price line ("24 PIECES ·
    /// FROM $38"), so the label says only what happened.
    ///
    /// - Parameter deepestCut: the largest measurable cut among the pieces.
    public static func group(_ kind: UpdateKind, deepestCut: Int? = nil) -> FeedLabel {
        switch kind {
        case .product: FeedLabel("NEW")
        case .restock: FeedLabel("BACK IN STOCK")
        case .priceDrop: FeedLabel(deepestCut.map { "UP TO −\($0)%" } ?? "PRICE CUTS")
        case .collection, .sale, .dropLock, .post, .pageChange: single(kind)
        }
    }

    /// "NEW · ALPINE CAPSULE" — a release is the one event with a name of its own, and the
    /// name is the news.
    public static func release(title: String) -> FeedLabel {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return FeedLabel(name.isEmpty ? "NEW COLLECTION" : "NEW · \(name)")
    }

    /// A sale in the brand's own terms, said as a sale: "25% OFF · CODE AUTUMN" becomes
    /// "SALE 25% OFF · CODE AUTUMN", and "END OF SEASON SALE · 20% OFF" is left alone.
    /// The offer and the code are found nowhere else, which is why they are the label.
    static func saleWords(_ title: String) -> String {
        let words = title.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !words.isEmpty else { return "SALE" }
        let tokens = words.split { !$0.isLetter }
        return tokens.contains("SALE") ? words : "SALE \(words)"
    }

    /// The price line of a card that stands for several garments: "24 PIECES · FROM $38".
    public static func pieces(_ count: Int, from cheapest: String? = nil) -> String {
        let pieces = "\(count) \(count == 1 ? "PIECE" : "PIECES")"
        guard let cheapest, !cheapest.isEmpty else { return pieces }
        return "\(pieces) · FROM \(cheapest)"
    }
}
