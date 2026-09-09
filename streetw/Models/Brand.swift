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

    /// The newest thing this brand has published, read or not.
    ///
    /// Stored rather than derived, for two reasons that turned out to be the same reason.
    /// It is what the feed orders brands by — a key computed from *unread* items changes as
    /// you read them, which slid a whole spread down the page under brands you had already
    /// dealt with. And computing it meant walking every update of every brand on each
    /// evaluation of the feed's body, which measured 44–426ms per rebuild on a real store
    /// and 1.4s on the first.
    ///
    /// Maintained by whatever writes updates. Nil on rows written before this existed;
    /// `Brand.activityKey` falls back to walking that one brand, so an old row sorts
    /// correctly and pays the cost once rather than the whole store paying it always.
    var lastActivityAt: Date?

    /// What the feed sorts on. Never derived from unread items — see `lastActivityAt`.
    var activityKey: Date {
        if let lastActivityAt { return lastActivityAt }
        return updates.max { $0.publishedAt < $1.publishedAt }?.publishedAt ?? addedAt
    }

    /// Records a batch's newest publication date. Only ever moves forward: an event is a
    /// record of something that happened, and a late-arriving old row does not make the
    /// brand less recently active.
    func noteActivity(_ date: Date) {
        if date > (lastActivityAt ?? .distantPast) { lastActivityAt = date }
    }
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

    /// The garments in a collection.
    ///
    /// A collection is the one kind of update that is *about* other updates, and
    /// `/collections.json` names a release without listing it. This used to reconstruct the
    /// membership from two guesses — a distinctive word from the title, then, failing that,
    /// anything published within a day and a half of it — on the argument that reading the
    /// real list would be a network call per card in a scrolling feed, and that being wrong
    /// costs a few extra garments rather than a missed drop.
    ///
    /// **Both halves of that were wrong.** The call does not belong in a scrolling feed and
    /// never did: it belongs in the poll, once, when the collection is first seen, which is
    /// where `CollectionsSource` now makes it. And the cost was not a few extra garments.
    /// Corteiz announced ISLAND PUFF PRINT TRUCKER HAT, whose six colourways of that hat
    /// share no word with any of them; the word match found nothing, the window swept up
    /// whatever else had landed, and the release page printed five ALWEIZ board shorts, a
    /// ripstop bag and a bucket hat under "5 PIECES". Not one of them was in the collection.
    /// A page that states what is in a release is making a claim about stock, and it was
    /// false on every brand it was checked against.
    ///
    /// So: the storefront's own answer when we have it, the word match for rows written
    /// before we did, and **nothing at all** otherwise. A release we cannot name the
    /// contents of prints no contents — `CollectionCard` and `CollectionReleaseView` both
    /// draw an empty strip rather than a wrong one, which is the honest shape for a
    /// collection page a brand has announced and not yet filled.
    func members(
        of collection: BrandUpdate,
        cap: Int = 60
    ) -> [BrandUpdate] {
        // **What the storefront said, whenever it said anything.**
        //
        // Matched on the garment's key rather than the event's, the same one
        // `oncePerProduct` folds on: a feed row is `event:<uuid>` in server mode and one
        // garment produces several over its life, so joining on `externalID` would match
        // nothing on the mode the app ships in.
        //
        // **And it admits any kind of row, which the guess below must not.** The rule here
        // used to be `.product` only, everywhere, on the argument that a release lands in
        // the middle of ordinary trading and a restock is by definition not part of
        // something only just announced. That is an argument about a *guess* — it was
        // protecting a 36-hour window that would otherwise sweep up last season's stock —
        // and it is simply false against a list the shop published. Billionaire Boys Club
        // is the proof: its Yankees collection is 29 garments, 14 of them shelved in the
        // last fortnight, and every one of those 14 has a product record 181 days older
        // than its shelving. `Reshelving` reads that correctly and files all fourteen as
        // `.restock`, so the `.product` filter left the release with nothing in it — a card
        // that could never fill, for a collection sitting on the storefront in plain sight.
        // A re-merchandised collection is most of what a brand announces; refusing to draw
        // one is refusing to draw the common case.
        //
        // Nothing that is not a garment can slip in, because the join is on the id list:
        // a page change or a lock carries no `shopify:<id>` and matches no member.
        if !collection.memberExternalIDs.isEmpty {
            let wanted = Set(collection.memberExternalIDs)
            let named = updates.filter {
                $0.id != collection.id && wanted.contains($0.productExternalID ?? $0.externalID)
            }
            return BrandUpdate.oncePerProduct(named)
                .prefix(cap)
                .map { $0 }
        }

        // Rows written before the membership was carried, and sources that never carry it.
        // Brands tag and title their releases, so a product holding a rare word from the
        // collection's name is usually in it — good enough to keep an old card populated,
        // and not good enough to have ever been the primary answer.
        //
        // **`.product` only, here and only here.** This is the guess, and the objection
        // above is the right one for a guess: a re-shelved item from the same season
        // carries the same season code, so admitting restocks would let the sale rail into
        // a page announcing a new season. Deduplicated for the same reason `recentUpdates`
        // is: one garment, one tile.
        let words = BrandUpdate.distinctiveWords(in: collection.title)
        guard !words.isEmpty else { return [] }
        let candidates = BrandUpdate.oncePerProduct(
            updates.filter { $0.kind == .product && $0.id != collection.id }
        )
        return candidates
            .filter { $0.mentionsAny(of: words) }
            .sorted(by: BrandUpdate.newestFirst)
            .prefix(cap)
            .map { $0 }
    }
}
