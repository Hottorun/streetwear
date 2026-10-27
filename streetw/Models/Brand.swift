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
    /// 1.0's mute, kept only so it can be carried over once. Nothing reads it but that.
    ///
    /// It was the right instinct in the wrong place: a phone-only flag, consulted when a push
    /// arrived in the foreground, about a push the server had already composed and sent —
    /// and in the background iOS showed it anyway, so "muted" meant "muted while you are
    /// looking at the app". The mode that replaced it lives on the server beside the follow
    /// (`followMode`), where `Notifier` can decide before anything is sent.
    ///
    /// The first sync of a build that knows modes turns a muted brand into a **quiet** one
    /// and clears this. Quiet rather than Everything because the promise somebody asked for
    /// was silence, and breaking it is worse than the brand also leaving the feed — which is
    /// the one thing that changes, and the brand stays on the rail and its own page. A stored
    /// property still, because a SwiftData attribute that disappears takes the old value with
    /// it before anything could read it.
    var isMuted: Bool = false
    /// How much of this brand reaches the feed and the lock screen, as a `FollowMode` raw
    /// value — a string rather than the enum for the reason `genderRaw` is one.
    ///
    /// In server mode a mirror of the follow row: `RemoteSync` writes it from
    /// `GET /v1/follows` and never decides it alone. Standalone it is the only copy.
    var followModeRaw: String = FollowMode.everything.rawValue
    /// Which part of this brand reaches the feed and the lock screen (`FollowFilter`), as JSON
    /// text, or nil for all of it. Optional and new, so a lightweight migration adds it to any
    /// earlier store as nil — *All*, which is what every follow was.
    ///
    /// Like the mode: in server mode a mirror of the follow row (`GET /v1/follows`), changed
    /// there first; standalone the only copy.
    var followFilterJSON: String?
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
    /// Last time the user left this brand's page. Not what the feed's "since you were last
    /// here" reads — that is one line for every brand, see `FeedVisit`.
    var lastOpenedAt: Date?

    /// From the storefront's /meta.json — the currency of the shop that serves this phone,
    /// which in server mode can be a country's shop rather than the main one.
    ///
    /// **Never used to print a row's price.** Once somebody changes country it names a
    /// different shop from the one an older row came from, and a dollar price would print with
    /// a pound sign; a row carries its own (`BrandUpdate.currencyCode`).
    var currencyCode: String?

    /// The country shop the server serves this phone for this brand, or nil for the brand's
    /// main shop — `BrandDTO.storefront`. Only ever set in server mode; it is what lets the
    /// brand page say which shop it is showing.
    var storefrontCountry: String?
    var storefrontURLString: String?
    /// Every country that shop serves (`StorefrontDTO.servedCountries`) — one for a country's
    /// shop, several for a regional one like `eu.kith.com`. Optional because it was added after
    /// stores were written; nil reads as `storefrontCountry` alone.
    var storefrontCountries: [String]?

    /// Who the shop serving this phone serves, or nil for the main shop.
    var storefrontReach: ShopReach? {
        guard let storefrontCountry else { return nil }
        return ShopReach(countries: storefrontCountries ?? [storefrontCountry])
    }

    /// The shop to send somebody to: the country's that serves this phone, else the brand's
    /// own site.
    var shopURL: URL? { storefrontURLString.flatMap(URL.init(string:)) ?? websiteURL }

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

    /// Whether the feed should *say* the storefront is locked: locked, and followed in a mode
    /// that lets a lock through. The brand's own page and the brand list still print it — it
    /// is a fact about the shop — but the rail's dot, the calendar's accent and the lock story
    /// at the head of a spread are the feed talking, and a quiet brand asked it not to.
    var isAnnouncingLock: Bool { isLockedForDrop && followMode.admits(.dropLock) }

    @Relationship(deleteRule: .cascade, inverse: \BrandUpdate.brand)
    var updates: [BrandUpdate] = []

    /// Deleted, or detached from its context — see `BrandUpdate.isGone`.
    var isGone: Bool { isDeleted || modelContext == nil }

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

    var followMode: FollowMode { FollowMode(lenient: followModeRaw) }

    /// Sets the mode, and takes out of the feed whatever it no longer lets through.
    ///
    /// **The mode is decided where a row is written, not where the feed is drawn.** A row the
    /// mode does not admit arrives already seen and with no arrival (`RemoteSync.merge`,
    /// `SyncEngine.insert`), so the feed and every unread count agree without each learning
    /// the rule — the alternative was a filter in five places and an unread queue that grew
    /// for ever, since retention never drops anything unread. That leaves the rows that were
    /// already news when the mode changed, which is this: going quiet takes the kinds that
    /// will no longer arrive out of the feed's timeline as well as out of the unread queue.
    /// Nothing is deleted — every row stays in the brand's catalogue — and nothing comes back
    /// on the way to *Everything*: what happened while a brand was quiet is the brand's
    /// history, not news.
    ///
    /// Walks `updates`, which faults the brand's catalogue. That is the right cost for a tap
    /// somebody makes once and for a sync that sees the mode change, and both callers only
    /// get here when it does.
    func apply(_ mode: FollowMode) {
        guard followModeRaw != mode.rawValue else { return }
        followModeRaw = mode.rawValue
        for update in updates where (!update.isSeen || update.arrivedAt != nil) && !mode.admits(update.kind) {
            update.isSeen = true
            update.arrivedAt = nil
        }
    }

    /// Which part of the brand is followed, or nil for all of it — see `FollowFilter`.
    var followFilter: FollowFilter? {
        followFilterJSON.flatMap { try? JSONDecoder().decode(FollowFilter.self, from: Data($0.utf8)) }
    }

    /// The filter, read once for deciding many rows. Hoist it out of a loop: it parses the
    /// reader's words each time it is built.
    var followFilterMatcher: FollowFilter.Matcher { FollowFilter.Matcher(followFilter) }

    /// **Whether a row of this kind, about this garment, reaches the feed** — the mode and
    /// the filter, both of which only take away. The one question every place that writes a
    /// row as news asks (`RemoteSync.merge`, `SyncEngine.insert` and `refresh`); a watch never
    /// asks it.
    func admits(_ kind: UpdateKind, _ item: FollowFilter.Item, filter: FollowFilter.Matcher? = nil) -> Bool {
        followMode.admits(kind) && (filter ?? followFilterMatcher).admits(kind, item)
    }

    /// Sets the filter, and takes out of the feed whatever it no longer lets through — the
    /// same rule `apply(_:)` keeps for a mode, for the same reasons.
    ///
    /// **Tightening takes rows out; loosening brings nothing back.** A row the old filter kept
    /// out was stored read and with no arrival, so it is the brand's history, and turning the
    /// filter off does not make last week's tees news today. Nothing is deleted: the brand's
    /// page is its whole catalogue whatever the follow lets through.
    func apply(_ filter: FollowFilter?) {
        let stored = filter?.normalized
        let json = stored.flatMap { try? JSONEncoder().encode($0) }.map { String(decoding: $0, as: UTF8.self) }
        guard followFilterJSON != json else { return }
        followFilterJSON = json
        let matcher = FollowFilter.Matcher(stored)
        guard !matcher.isEmpty else { return }
        for update in updates where (!update.isSeen || update.arrivedAt != nil)
            && !matcher.admits(update.kind, update.followItem) {
            update.isSeen = true
            update.arrivedAt = nil
        }
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
    /// contents of prints no contents — the feed's release card and `CollectionReleaseView`
    /// both draw nothing rather than something wrong, which is the honest shape for a
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

    /// Detaches everything the person kept, so deleting the brand cannot take it with them.
    ///
    /// **`Brand.updates` cascades to `BrandUpdate`, which cascades to `SavedItem`.** So
    /// `context.delete(brand)` used to destroy the whole collection from that brand —
    /// notes, board filings, size notes — and quietly gut every fit those pieces were in.
    /// Two ordinary actions reached it and neither said so: swipe-to-delete in the brands
    /// sheet, and "Stop following", which does not delete anything itself but leaves the
    /// row absent from the next follow list, where the prune removes it minutes later. A
    /// row offering "Follow again" reads as reversible, and it was not.
    ///
    /// A save is something the person made; a `BrandUpdate` is something the app fetched.
    /// The first must outlive the second. So a kept row is *detached* rather than deleted:
    /// `BrandUpdate.brand` is already optional, because a link shared from a storefront
    /// nobody follows lands in exactly that state and the whole app already draws it.
    ///
    /// `siteName` carries the name forward, because `brandLabel` reads the brand first and
    /// the site second — without it a detached save would lose its wordmark and fall back
    /// to a bare hostname, which is a worse answer than the one we already had. Only when
    /// the site said nothing itself, so a real `og:site_name` is never overwritten.
    ///
    /// Call this **before** `context.delete(brand)`, always, on every path that removes a
    /// brand. Following the brand again re-creates the row and re-fetches its catalogue;
    /// the detached saves stay where they are, which is the collection.
    func releaseKeepsakes() {
        // Snapshotted: assigning `brand = nil` removes the row from `updates`, and
        // mutating a relationship while iterating it is how this goes wrong quietly.
        for update in Array(updates) where !update.saves.isEmpty {
            if update.siteName?.isEmpty != false { update.siteName = name }
            update.brand = nil
        }
    }
}
