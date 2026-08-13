// Brand.swift
// Model for a fashion brand
import Foundation
import StreetwCore
import SwiftData

@Model
final class Brand {
    var id: UUID = UUID()
    var name: String = ""
    var websiteURL: URL?
    /// The brand's mark, taken from the icon its site publishes for home screens.
    /// A string rather than a URL for the same reason the image lists are.
    var logoURLString: String?
    var instagramHandle: String?
    var styleDescription: String?
    var myRating: Int?
    var followed: Bool = true
    /// Still watched, still in the feed — just silent.
    ///
    /// A different knob from `followed`, and the app had only the second one. A brand that
    /// posts forty times a week is not one you want to stop watching; it is one you want to
    /// stop being woken by, and the only control offered was to remove it entirely. The
    /// icon said as much: "Stop following" carried a `bell.slash`, which is what a mute
    /// looks like everywhere else, so the row was already promising this.
    ///
    /// Local, and read at notification time. The server decides *who* to notify, so a
    /// muted brand is filtered on arrival rather than at the source — a device-level
    /// preference does not belong in a catalog the whole app shares.
    var isMuted: Bool = false
    var addedAt: Date = Date()

    var sources: [BrandSource] = []

    var lastSyncedAt: Date?
    /// Last time the user actually looked at this brand's updates. Drives "new since".
    var lastOpenedAt: Date?

    /// From the storefront's /meta.json. Prices are meaningless without it.
    var currencyCode: String?

    /// Server-side brand id when this brand came from a synced account. Nil for brands
    /// added in standalone mode, which is what keeps both modes working side by side.
    var remoteID: UUID?

    /// True while `name` is still the hostname-derived guess ("Bbcicecream"), so the
    /// first sync may replace it with the real one from /meta.json ("Billionaire Boys
    /// Club"). Cleared once a real name lands or the user edits it.
    var usesGeneratedName: Bool = false

    /// Set when the storefront looks locked down — Shopify password page, 401/403.
    /// Brands do this right before a drop, which is itself the signal.
    var isLockedForDrop: Bool = false

    @Relationship(deleteRule: .cascade, inverse: \BrandUpdate.brand)
    var updates: [BrandUpdate] = []

    init(
        name: String,
        websiteURL: URL? = nil,
        instagramHandle: String? = nil,
        styleDescription: String? = nil,
        myRating: Int? = nil,
        followed: Bool = true
    ) {
        self.id = UUID()
        self.name = name
        self.websiteURL = websiteURL
        self.instagramHandle = instagramHandle
        self.styleDescription = styleDescription
        self.myRating = myRating
        self.followed = followed
        self.addedAt = Date()
    }

    var unseenCount: Int {
        updates.count { !$0.isSeen }
    }

    /// Stored as a string like the image lists, for the same SwiftData reason.
    var logoURL: URL? {
        logoURLString.flatMap(URL.init(string:))
    }

    var instagramURL: URL? {
        guard let handle = instagramHandle?.trimmingCharacters(in: CharacterSet(charactersIn: "@ ")),
              !handle.isEmpty else { return nil }
        return URL(string: "https://instagram.com/\(handle)")
    }

    /// Newest updates first, capped — the feed never wants all 250 products.
    func recentUpdates(limit: Int = 12) -> [BrandUpdate] {
        updates.sorted { $0.publishedAt > $1.publishedAt }.prefix(limit).map { $0 }
    }

    /// The garments that landed with a collection announcement.
    ///
    /// A collection is the one kind of update that is *about* other updates. `/collections.json`
    /// says a release exists and names it; it does not list what is in it, and the products
    /// arrive separately down `/products.json`. So the membership is reconstructed here,
    /// from two signals that agree in practice and cost no network:
    ///
    /// - **A distinctive word.** Brands tag and title their releases — "FW26", "Denim
    ///   Tears x …" — so a product carrying a rare word from the collection's name is
    ///   almost certainly in it. Common words are useless for this and are skipped, or
    ///   "The Collection" would match the entire catalogue.
    /// - **Landing at the same time.** Failing that, a release and its products publish
    ///   together. The window is generous because storefronts stagger a drop across a day.
    ///
    /// Deliberately a heuristic. The alternative is fetching `/collections/<handle>/products.json`
    /// per collection, which is a network call per card in a scrolling feed, and being
    /// wrong here costs a page with a few extra garments on it — not a missed drop.
    func members(of collection: BrandUpdate, window: TimeInterval = 48 * 3_600) -> [BrandUpdate] {
        let words = BrandUpdate.distinctiveWords(in: collection.title)
        let start = collection.publishedAt.addingTimeInterval(-window)
        let end = collection.publishedAt.addingTimeInterval(window)

        return updates
            .filter { update in
                guard update.kind != .collection, update.id != collection.id else { return false }
                if !words.isEmpty, update.mentionsAny(of: words) { return true }
                return (start...end).contains(update.publishedAt)
            }
            .sorted { $0.publishedAt > $1.publishedAt }
    }
}
