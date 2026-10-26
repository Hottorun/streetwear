// CatalogueSale.swift
// Telling a brand going on sale apart from a brand marking a few things down.
//
// A markdown is a fact about one garment and is worth as much next week — that is what the
// markdowns list is for, and why a `.priceDrop` never wakes anybody. A sale is a fact about
// the brand: it starts at a moment, the sizes go first, and it is the one thing somebody
// following H&M in *Sales only* mode is waiting to hear. So it is its own event, `.sale`,
// said once when it starts — never once per markdown.
//
// Shared rather than living in the poller because the rule is a pure function of numbers and
// is easier to hold still with tests here; the server is its only caller today.

import Foundation

public enum CatalogueSale {
    /// The share of a pass's priced products that has to be marked down before the brand is
    /// "on sale".
    ///
    /// **Thirty per cent, and measured over what the pass read.** A Shopify poll reads the
    /// newest 250 products, which during a seasonal sale is mostly the marked-down stock
    /// moving back to the front plus whatever is new, so a real sale clears this comfortably
    /// — Motel Rocks' "up to 50% off dresses" rail is every product on it — while a brand
    /// that keeps an outlet corner of last season's leftovers sits well under it. It is a
    /// share of the *read*, not of the stored catalogue: between scans most stored products
    /// are at whatever price something last read them at, and a share over stored prices
    /// would describe yesterday.
    ///
    /// **The daily scan measures the same thirty per cent over the whole catalogue, of what
    /// can be bought** (`decideScan`). Only buyable stock, because a full catalogue is mostly
    /// history: years of sold-out products, many still carrying the compare-at of a sale that
    /// ended long ago. Counted in, they hold the share wherever last season left it — and a
    /// brand that sits over the line for good can never be seen going on sale again, since a
    /// start is a transition — while none of them can be bought anyway. Of what *is* on the
    /// shelf, thirty per cent cut is a sale on any measure, and it is what a sale on older
    /// stock looks like: exactly the sale the newest 250 cannot see.
    public static let startShare = 0.30

    /// …and the share it has to fall back under before the sale counts as over and the
    /// next one can be announced. Well below the start, so a sale hovering around the line
    /// cannot be announced every other poll.
    public static let endShare = 0.10

    /// The fewest marked-down products that can ever be a sale, whatever the share.
    ///
    /// **A tiny shop is not a tiny sale.** Two of five products discounted is 40% and is two
    /// markdowns; a brand with a dozen pieces on its whole storefront cannot be "on sale" in
    /// any sense worth waking somebody for. Twelve is two rows of the feed's grid.
    public static let minimumMarkedDown = 12

    /// The shortest a sale can be before it may end.
    ///
    /// A storefront that publishes no original price can only show a markdown as a fall
    /// between two polls, so the pass after a mass markdown reads 0% and would end the sale
    /// at once — and a markdown taken in waves would then be announced once per wave, a
    /// day apart. Three days is long enough that "further reductions" a week later is news
    /// again and short enough that the next season's sale always is.
    public static let minimumLength: TimeInterval = 3 * 86_400

    /// How long a scan's measurement speaks for the catalogue. A scan that has not finished
    /// for this long — a failing source, a storefront that stopped being read — says nothing,
    /// rather than holding a sale open on a share from last week.
    public static let catalogueFresh: TimeInterval = 3 * 86_400

    /// What one pass saw of a brand's prices.
    public struct Reading: Sendable, Equatable {
        /// Products in the pass with a price at all. A sitemap or a collections source reads
        /// none, which is not a measurement of anything.
        public var priced = 0
        /// Of those, how many are a real cut from the brand's original or from the price
        /// the last poll saw.
        public var markedDown = 0
        /// The deepest of those cuts, in whole per cent — the "up to".
        public var deepest: Int?

        public init() {}

        /// Counts one product.
        /// - Parameters:
        ///   - now: its price in this pass.
        ///   - original: what the brand says it cost before (`FetchedItem.originalPriceAmount`).
        ///   - previous: the price stored before this pass, nil for a product first seen now.
        public mutating func count(now: Double?, original: Double?, previous: Double?) {
            guard let now, now > 0 else { return }
            priced += 1
            guard let cut = PriceChange.percentOff(previous: previous, original: original, now: now) else { return }
            markedDown += 1
            deepest = max(deepest ?? 0, cut)
        }

        public var share: Double { priced == 0 ? 0 : Double(markedDown) / Double(priced) }

        public var isSale: Bool {
            markedDown >= CatalogueSale.minimumMarkedDown && share >= CatalogueSale.startShare
        }
    }

    /// What is stored about a brand's sale between passes — two columns, written only when
    /// they change, because a brand row rewritten every poll is the volume problem
    /// `Poller.refresh` exists to avoid.
    public struct State: Sendable, Equatable {
        /// When the brand's prices were first measured. Nil until then, and that first
        /// measurement is a **baseline**: a brand already halfway through a sale when this
        /// shipped, or when somebody first followed it, did not just start one.
        public var measuredAt: Date?
        /// When the sale now running started, or nil when there is none.
        public var since: Date?
        /// The share the last complete scan measured over the buyable catalogue, and when.
        /// Nil until a scan has finished. The poll may not end a sale this still holds open —
        /// see `decide`.
        public var catalogueShare: Double?
        public var catalogueMeasuredAt: Date?

        public init(
            measuredAt: Date? = nil,
            since: Date? = nil,
            catalogueShare: Double? = nil,
            catalogueMeasuredAt: Date? = nil
        ) {
            self.measuredAt = measuredAt
            self.since = since
            self.catalogueShare = catalogueShare
            self.catalogueMeasuredAt = catalogueMeasuredAt
        }

        /// Whether a recent scan says the catalogue is still marked down past `endShare`.
        public func catalogueHolds(now: Date) -> Bool {
            guard let share = catalogueShare, let at = catalogueMeasuredAt,
                  now.timeIntervalSince(at) < CatalogueSale.catalogueFresh
            else { return false }
            return share >= CatalogueSale.endShare
        }
    }

    public enum Decision: Sendable, Equatable {
        /// Nothing to write.
        case unchanged
        /// Record what was seen, announce nothing.
        case record(State)
        /// A sale started: record it, and say so.
        case started(State)
    }

    /// The one rule, for a poll. Announces on the transition into a sale and never otherwise,
    /// re-arming only once the share has fallen back under `endShare` and the sale is at least
    /// `minimumLength` old.
    ///
    /// **Two measurements feed one state, and only agreement ends a sale.** The poll reads the
    /// newest 250 and the daily scan the whole catalogue, and they can disagree for weeks: a
    /// brand marking down only last season's stock reads 40% to the scan and 5% to the poll.
    /// Had either been allowed to end a sale the other was holding, it would end after three
    /// days, the other would start it again on its next read, and the brand would be announced
    /// on sale every few days for as long as it lasted. So either may *start* one, and the
    /// poll ends it only when its own read and a fresh scan are both under the line.
    ///
    /// - Parameter isBaseline: whether the pass itself is a baseline (a source's first poll),
    ///   which settles state and announces nothing, like everything else on a first sight.
    public static func decide(
        _ reading: Reading,
        state: State,
        isBaseline: Bool,
        now: Date = Date()
    ) -> Decision {
        guard reading.priced > 0 else { return .unchanged }
        let held = state.catalogueHolds(now: now)

        if state.measuredAt == nil || isBaseline {
            var settled = state
            settled.measuredAt = state.measuredAt ?? now
            settled.since = reading.isSale ? (state.since ?? now) : (isBaseline || held ? state.since : nil)
            return settled == state ? .unchanged : .record(settled)
        }

        guard let since = state.since else {
            guard reading.isSale else { return .unchanged }
            var started = state
            started.since = now
            return .started(started)
        }
        let over = reading.share < endShare && !held && now.timeIntervalSince(since) >= minimumLength
        guard over else { return .unchanged }
        var ended = state
        ended.since = nil
        return .record(ended)
    }

    /// The same rule, for a daily scan over the brand's buyable catalogue.
    ///
    /// **It may start a sale and never ends one** — see `decide` for why ending belongs to the
    /// poll alone. It always records its share, which is the one write a scan makes to the
    /// brand row: a day's measurement is worth one tuple a day.
    ///
    /// The first scan is a **baseline** whatever it sees, like every first sight here: a brand
    /// whose older stock has been on sale for a month when the scan first reached it did not
    /// just go on sale. So is a scan after a lapse (`isBaseline`), whose prices are not news. A
    /// baseline that finds a sale records it as running, silently, so the poll cannot announce
    /// it either.
    public static func decideScan(
        _ reading: Reading,
        state: State,
        isBaseline: Bool,
        now: Date = Date()
    ) -> Decision {
        guard reading.priced > 0 else { return .unchanged }
        var next = state
        next.catalogueShare = (reading.share * 1000).rounded() / 1000
        next.catalogueMeasuredAt = now

        if isBaseline || state.catalogueMeasuredAt == nil {
            if reading.isSale, next.since == nil { next.since = now }
            return .record(next)
        }
        if reading.isSale, state.since == nil {
            next.since = now
            return .started(next)
        }
        return .record(next)
    }

    /// How the sale is said, in the feed and on the lock screen.
    ///
    /// Caps, like the label the roadmap's feed card uses ("SALE 25% OFF · CODE AUTUMN"), and
    /// the same shape as a banner's so the two read as one kind of news.
    public static func announcement(for reading: Reading) -> (title: String, summary: String) {
        let title = reading.deepest.map { "SALE · UP TO \($0)% OFF" } ?? "SALE"
        let pieces = reading.priced == 1 ? "piece" : "pieces"
        return (title, "\(reading.markedDown) of the \(reading.priced) \(pieces) just checked are marked down.")
    }
}
