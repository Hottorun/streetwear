// Credits.swift
// The two things about credits the phone and the server must agree on: what an action is
// called, and which month a moment falls in.
//
// Everything else about credits is the server's — the balance, the ledger, the packs and what
// each costs — because a balance StoreKit cannot restore has to live somewhere a reinstall
// does not reach (`CreateAccounts`). What is here is only what both ends *read*: the server
// writes "search" into the ledger and the phone prints "23 searches"; the server counts a
// month from the first of it in UTC and the phone says "this month" about the same one.
// Two definitions of either would drift, and the symptom would be a usage line that
// disagrees with the bill.
//
// See `docs/credits.md`.

import Foundation

/// What an AI action is called, in the ledger and on the wire.
///
/// A string rather than an enum, for the reason `UsageCount.event` is one: Phase 4 will add
/// actions, a server that learns one must not fail an older phone's decode of the usage
/// list, and a phone must be able to print a row about an action it has never heard of.
public struct CreditAction: RawRepresentable, Codable, Hashable, Sendable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// "Black suit under €400" in Shop.
    public static let search = CreditAction("search")
    /// More like this, on a product or a save.
    public static let moreLikeThis = CreditAction("more_like_this")
    /// The camera: a garment read off one photograph.
    public static let scan = CreditAction("scan")
    /// A whole fit judged from its photographs.
    public static let fitJudge = CreditAction("fit_judge")
    /// "Show me more": a search's reading asked of the open web.
    public static let webSearch = CreditAction("web_search")
    /// Candidates for a fit, ordered and vetted from their photographs.
    public static let fitSuggest = CreditAction("fit_suggest")

    /// Metered and never charged: work nobody asked for, paid for by the owner — a daily
    /// pick's sentence, a sale banner's fine print, a product page with no structured data.
    /// They have names so `GET /admin/costs` can say what each costs.
    public static let pickReason = CreditAction("pick_reason")
    public static let saleReading = CreditAction("sale_reading")
    public static let pageReading = CreditAction("page_reading")
    /// A product's photographs read by the model instead of the embeddings — the product shot and
    /// its style words — when the owner switches `PRODUCT_READING=haiku` on (Phase 5).
    public static let productReading = CreditAction("product_reading")

    /// The actions the roadmap's Phase 4 names. Not a whitelist — the server records what it
    /// is told — only the ones this build has words for.
    public static let known: [CreditAction] = [.search, .moreLikeThis, .scan, .fitJudge, .webSearch, .fitSuggest]

    /// How "this month: N …" names it. An action this build does not know is still counted,
    /// as "actions", rather than dropped: a usage line that silently omits a row is a bill
    /// that does not add up.
    public func label(count: Int) -> String {
        let one = count == 1
        switch self {
        case .search: return one ? "search" : "searches"
        case .moreLikeThis: return "“more like this”"
        case .scan: return one ? "scan" : "scans"
        case .fitJudge: return one ? "fit judged" : "fits judged"
        case .webSearch: return one ? "web search" : "web searches"
        case .fitSuggest: return one ? "fit suggestion" : "fit suggestions"
        default: return one ? "action" : "actions"
        }
    }
}

/// The calendar month credits are counted in: UTC, so the phone and the server agree on where
/// one ends whatever time zone either is in.
///
/// The free allowance is granted once per month by this key, and "this month" on the phone
/// is read from the same one — see `UsagePolicy.day(of:)`, which settles days the same way.
public enum CreditMonth {
    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// "2026-10". Built from components rather than a shared formatter: a `DateFormatter`
    /// held in a static is shared mutable state, which is exactly the race Swift 6 found in
    /// this package once already.
    public static func key(of date: Date) -> String {
        let parts = utc.dateComponents([.year, .month], from: date)
        let year = parts.year ?? 1970
        let month = parts.month ?? 1
        return String(format: "%04d-%02d", year, month)
    }

    /// Midnight UTC on the first of the month `date` is in.
    public static func start(of date: Date) -> Date {
        let calendar = utc
        let parts = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: parts) ?? date
    }
}
