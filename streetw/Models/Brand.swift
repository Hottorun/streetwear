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

    /// Everything unread, whatever it is. Only for callers that genuinely mean *everything*
    /// — which, on screen, is none of them.
    var unseenCount: Int {
        updates.count { !$0.isSeen }
    }

    /// Unread, counted the way the feed counts.
    ///
    /// **The number a person sees must be the number of things they can see.** The feed
    /// filters with `BrandUpdate.passes`; this did not, so somebody on Menswear cleared
    /// their feed and then found the brands list still claiming 40 unread and the brand page
    /// still saying UNREAD in vermilion — about womenswear it had just decided not to show
    /// them. Two screens describing the same queue and disagreeing about how big it is reads
    /// as the count being broken, which is worse than either number alone.
    ///
    /// The same argument as `passes` itself: one rule, called from everywhere that counts or
    /// lists a brand's output, rather than a copy per screen.
    /// Counted in **garments**, matching what the feed draws. One product can hold several
    /// unread events — it dropped, then it restocked — and the feed prints one card for it,
    /// so counting rows would say 40 above a page showing 25. Distinct keys rather than
    /// `oncePerProduct`, which sorts: a count does not care about the order.
    func unseenCount(matching profile: SizeProfile) -> Int {
        var seen = Set<String>()
        for update in updates where !update.isSeen && update.passes(profile) {
            seen.insert(update.productExternalID ?? update.externalID)
        }
        return seen.count
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
    ///
    /// Deduplicated, because a list of a brand's output is a list of *garments* and one
    /// garment produces several rows — see `BrandUpdate.oncePerProduct`.
    func recentUpdates(limit: Int = 12) -> [BrandUpdate] {
        BrandUpdate.oncePerProduct(updates).prefix(limit).map { $0 }
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
    func members(
        of collection: BrandUpdate,
        window: TimeInterval = 36 * 3_600,
        cap: Int = 60
    ) -> [BrandUpdate] {
        // **Only things that dropped.** This filtered on `kind != .collection`, which admits
        // every other kind of event a brand produces — and a release lands in the middle of
        // ordinary trading, so the window swept up restocks of last season's stock, price
        // drops on the sale rail and page changes, and printed them as the contents of a new
        // collection. A restock is by definition *not* part of something that has only just
        // been announced: it is a garment that already existed coming back. The word match
        // is no protection either, since a re-shelved item from the same season carries the
        // same season code.
        //
        // Deduplicated for the same reason `recentUpdates` is: one garment, one tile.
        let candidates = BrandUpdate.oncePerProduct(
            updates.filter { $0.kind == .product && $0.id != collection.id }
        )
        let words = BrandUpdate.distinctiveWords(in: collection.title)

        // A word match is evidence; a timestamp is only an absence of evidence to the
        // contrary. So the two are tried in order rather than OR'd together — OR'ing them
        // was wrong in the one case that matters most: on a brand's **first sync** the
        // whole back catalogue is stored at once and shares a publication time, so a
        // release announced in the same batch swallowed all of it and the page announced
        // "292 PIECES IN THIS RELEASE".
        if !words.isEmpty {
            let named = candidates.filter { $0.mentionsAny(of: words) }
            if !named.isEmpty { return named.sorted(by: BrandUpdate.newestFirst) }
        }

        // Nothing in the name to go on. Fall back to what landed alongside it, capped —
        // a release is a release and not a catalogue, and a page of sixty is already
        // generous enough to be wrong without being absurd.
        let start = collection.publishedAt.addingTimeInterval(-window)
        let end = collection.publishedAt.addingTimeInterval(window)
        return candidates
            .filter { (start...end).contains($0.publishedAt) }
            .sorted(by: BrandUpdate.newestFirst)
            .prefix(cap)
            .map { $0 }
    }
}
