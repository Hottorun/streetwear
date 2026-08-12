// SharedSaveImporter.swift
// Turns links shared from elsewhere into saved items.
//
// This is what makes streetw an archive rather than a feed reader: the collection stops
// being limited to brands we happen to watch. A link from any storefront, any blog, any
// resale listing becomes a card on the wall.
//
// The enrichment happens here rather than in the extension because the app has time and
// memory the extension doesn't. If the fetch fails the save still lands — with the URL
// and whatever title the share sheet gave us — because losing someone's save to a flaky
// network would be far worse than an ugly card.

import Foundation
import OSLog
import StreetwCore
import SwiftData

@MainActor
enum SharedSaveImporter {
    /// This path runs without anyone watching — a share arrives while the app is closed
    /// and is filed on the next launch. When it goes wrong there is nothing on screen to
    /// see, so it says what it did.
    private static let log = Logger(subsystem: "com.kern.functional.streetw", category: "share")
    /// How long to wait for a page's own description before giving up on it.
    ///
    /// A storefront product page is heavy and occasionally just hangs. The save must not
    /// hang with it: a card with no photograph is a poor card, but a save that never
    /// arrives is a lost one, so the fetch is capped and the item is filed regardless.
    private static let metadataTimeout: Duration = .seconds(12)

    /// Files everything waiting in the inbox into the store. Returns how many landed.
    ///
    /// Everything the extension could not ask is asked here, because here is the first
    /// moment anyone knows the answer.
    ///
    /// The extension does no networking, so at share time nobody knows what the thing is
    /// called, what sizes it comes in or whether any of them are left — and by the time we
    /// do, the share sheet is long gone. So a share lands silently and the questions are
    /// put on the next foreground, which in the usual share-from-Safari-and-switch-back
    /// flow is seconds later.
    ///
    /// Two questions, and which one is asked depends on the answer to the third:
    ///
    /// - **Sold out** → `route`, which raises a sheet. Deliberately the heavier control:
    ///   this is the one case where the offer is genuinely urgent and where you may not be
    ///   looking at the screen when it arrives.
    /// - **Anything else** → `confirm`, the same amendable confirmation an in-app save
    ///   gets, so a shared link can be filed on a board or watched without hunting for the
    ///   item afterwards. Until this, a share simply appeared in the collection with no
    ///   acknowledgement at all and no way to act on it in the moment.
    @discardableResult
    static func drain(
        into context: ModelContext,
        route: PushRoute? = nil,
        confirm: SaveConfirmation? = nil
    ) async -> Int {
        let pending = SharedInbox.pending()
        log.info("inbox: container \(SharedInbox.isAvailable ? "ok" : "MISSING"), \(pending.count) pending")
        guard !pending.isEmpty else { return 0 }

        var imported = 0
        var landedUpdates: [BrandUpdate] = []
        for item in pending {
            // One at a time on purpose: sharing happens a link at a time, and a burst of
            // parallel requests to one storefront is exactly what `PoliteFetcher`
            // exists to prevent elsewhere.
            let product = await catalogProduct(for: item.save.url)
            let metadata = product == nil ? await metadata(for: item.save.url) : PageMetadata()
            let landed = importOne(item.save, metadata: metadata, product: product, into: context)
            if landed != nil { imported += 1 }
            do {
                // Only once it is genuinely committed is the file dropped. A failed save
                // leaves the item in the inbox to be retried, which is the whole reason
                // reading and deleting are separate steps.
                try context.save()
                SharedInbox.remove(item.id)
                log.info("imported \(item.save.url.absoluteString, privacy: .public) (new: \(landed != nil))")
                if let landed, let update = row(for: landed, in: context) {
                    landedUpdates.append(update)
                }
            } catch {
                log.error("could not store \(item.save.url.absoluteString, privacy: .public): \(error)")
            }
        }

        announce(landedUpdates, route: route, confirm: confirm)
        return imported
    }

    /// The revision of enrichment that `repair` stamps. Bump it when this file learns to
    /// find something it previously couldn't, and every thin save gets one more look.
    static let enrichmentVersion = 1

    /// How many thin saves to re-fetch per pass.
    ///
    /// Small on purpose. This runs on a foreground with nobody asking for it, against
    /// storefronts that owe us nothing, and there is no hurry: a save that has been a bare
    /// bookmark for a month can be a bare bookmark for another minute. Several passes
    /// drain a backlog.
    private static let repairBatch = 4

    /// Files saved items under a brand they were never attributed to.
    ///
    /// Costs no network and is idempotent, so it needs no version stamp: it looks only at
    /// rows that have no brand at all, and the answer either exists in the store now or it
    /// doesn't. Rows land brandless for two reasons and both heal here — the host match
    /// used to be exact, so anything from a brand's other storefronts missed; and a link
    /// can simply be shared before its brand is followed, which is the ordinary way round
    /// for somebody who finds a label and then decides to watch it.
    @discardableResult
    static func attachBrands(in context: ModelContext) -> Int {
        var descriptor = FetchDescriptor<BrandUpdate>(
            predicate: #Predicate { $0.brand == nil && !$0.saves.isEmpty }
        )
        descriptor.fetchLimit = 200

        let orphans = (try? context.fetch(descriptor)) ?? []
        guard !orphans.isEmpty else { return 0 }

        let brands = (try? context.fetch(FetchDescriptor<Brand>())) ?? []
        guard !brands.isEmpty else { return 0 }

        var attached = 0
        for update in orphans {
            guard let link = update.linkURL,
                  let brand = brands.first(where: { BrandDiscovery.isSameBrandHost(link, $0.websiteURL) })
            else { continue }
            update.brand = brand
            attached += 1
        }
        if attached > 0 {
            try? context.save()
            log.info("attached \(attached) saved items to a brand")
        }
        return attached
    }

    /// Gives shares that landed as bare bookmarks another chance at the catalogue.
    ///
    /// This is the repair path the importer never had. A share is enriched exactly once,
    /// at import, and the inbox file is deleted immediately afterwards — so a link that
    /// failed to match a catalogue record kept a title and a single Open Graph photograph
    /// permanently, with no size run, no colourways, no stock and therefore no way to
    /// watch it. Which is most of what a saved product page is *for*.
    ///
    /// Only `shared:` rows with no variants are candidates: a `shopify:` key means the
    /// catalogue already answered, and a row with variants has everything this could add.
    @discardableResult
    static func repair(in context: ModelContext) async -> Int {
        let version = enrichmentVersion
        var descriptor = FetchDescriptor<BrandUpdate>(
            predicate: #Predicate { $0.enrichmentVersion != version && !$0.saves.isEmpty }
        )
        descriptor.fetchLimit = repairBatch * 4

        let thin = ((try? context.fetch(descriptor)) ?? [])
            .filter { $0.externalID.hasPrefix("shared:") && $0.variants.isEmpty }
            .prefix(repairBatch)
        guard !thin.isEmpty else { return 0 }

        var upgraded = 0
        for update in thin {
            // Stamped whatever happens. A link whose storefront publishes no catalogue —
            // a regional subdomain, a blog, a resale listing — must not be re-fetched on
            // every foreground for the rest of its life.
            update.enrichmentVersion = version

            guard let link = update.linkURL,
                  let product = await catalogProduct(for: link)
            else { continue }

            apply(product, to: update)
            // The rest of what a catalogue record knows and Open Graph doesn't. Only ever
            // filling gaps: a title someone has been looking at for a month should not
            // change under them, but an empty summary or a missing product type is
            // strictly better filled in.
            if update.summary == nil { update.summary = product.summary }
            if update.productType == nil { update.productType = product.productType }
            if update.tags.isEmpty { update.tags = product.tags }
            update.refreshGender()
            upgraded += 1

            log.info("repaired \(link.absoluteString, privacy: .public) with \(product.variants.count) variants")
        }

        try? context.save()
        return upgraded
    }

    /// Says what happened, once for the whole drain.
    ///
    /// Deliberately not once per item. Sharing five things should not stack five sheets or
    /// flash five confirmations that each replace the last unread — and a confirmation
    /// whose buttons act on *one* product has no honest subject when several arrived, which
    /// is the same reason a counted push carries no `eventID`. So a batch is left to speak
    /// for itself in the collection, and only a lone share is offered anything.
    private static func announce(
        _ updates: [BrandUpdate],
        route: PushRoute?,
        confirm: SaveConfirmation?
    ) {
        let soldOut = updates.filter { $0.isAvailable == false && $0.activeWatches.isEmpty }
        // The urgent case first, and it wins outright: something gone is worth a sheet, and
        // raising a toast underneath it as well would be two answers to one share.
        if let first = soldOut.first, let route {
            route.offerWatch(first)
            return
        }
        guard updates.count == 1, let only = updates.first else { return }
        confirm?.confirm(only, destination: only.save?.board?.name ?? only.save?.type.label ?? "Inspiration")
    }

    private static func row(for externalID: String, in context: ModelContext) -> BrandUpdate? {
        var descriptor = FetchDescriptor<BrandUpdate>(
            predicate: #Predicate { $0.externalID == externalID }
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }


    /// The storefront's own record of the product, when the link is a Shopify product
    /// page. Worth trying first and by a distance: Open Graph gives a title, a picture and
    /// a price, while this gives the size run, the colourways and which of them are gone —
    /// which is the difference between a saved link and something you can put a watch on.
    private static func catalogProduct(for url: URL) async -> FetchedItem? {
        await withTaskGroup(of: FetchedItem?.self) { group in
            group.addTask { await ShopifySource.product(at: url) }
            group.addTask {
                try? await Task.sleep(for: metadataTimeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private static func metadata(for url: URL) async -> PageMetadata {
        await withTaskGroup(of: PageMetadata?.self) { group in
            group.addTask { await PageMetadataParser.fetch(url) }
            group.addTask {
                try? await Task.sleep(for: metadataTimeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? PageMetadata()
        }
    }

    /// Separated from the fetch so it is synchronous, testable and easy to reason about.
    ///
    /// Returns the external id of anything newly kept, and nil when the share was a
    /// duplicate of something already in the collection — so the caller can look the row
    /// back up without re-deriving a key that is decided in three different ways here.
    @discardableResult
    static func importOne(
        _ save: SharedSave,
        metadata: PageMetadata,
        product: FetchedItem? = nil,
        into context: ModelContext
    ) -> String? {
        // The canonical URL is what dedupes: a share sheet hands over links carrying
        // whatever tracking parameters the referring app added, so the same product
        // shared twice arrives as two different URLs.
        let link = product?.linkURL ?? metadata.canonicalURL ?? save.url
        // A catalogue hit is keyed the way the poller keys it, so sharing something from a
        // brand the app already follows lands on the row that already exists instead of
        // minting a second card for the same product.
        let externalID = product?.externalID ?? "shared:\(link.absoluteString)"

        let existing = existingRow(for: externalID, in: context)

        if let existing {
            // Already here. Re-sharing something is a request to keep it, not a
            // request for a duplicate card.
            if let product { apply(product, to: existing) }
            if existing.save == nil {
                context.insert(SavedItem(update: existing, type: .inspiration))
                return externalID
            }
            return nil
        }

        let update = BrandUpdate(
            externalID: externalID,
            brand: matchingBrand(for: link, in: context),
            title: product?.title ?? title(for: save, metadata: metadata, link: link),
            summary: product?.summary,
            linkURL: link,
            imageURLStrings: product?.imageURLStrings
                ?? metadata.imageURL.map { [$0.absoluteString] } ?? [],
            publishedAt: save.sharedAt,
            kind: .product,
            priceText: product?.priceText ?? metadata.price,
            priceAmount: product?.priceAmount,
            isAvailable: product?.isAvailable ?? metadata.isAvailable,
            tags: product?.tags ?? [],
            productType: product?.productType
        )
        update.variants = product?.variants ?? []
        update.productExternalID = product?.externalID
        // Saved deliberately, so it is never "news" — it must not turn up in the feed
        // as an unread item the user has to dismiss.
        update.isSeen = true
        update.refreshGender()

        context.insert(update)
        context.insert(SavedItem(update: update, type: .inspiration, note: nil))
        return externalID
    }

    /// The row this share is about, if the collection already holds one.
    ///
    /// Two keys, because there are two ways the same garment can already be here and only
    /// one of them was ever checked:
    ///
    /// - `externalID`, which matches a row the *local* poller wrote (`shopify:<id>`) or an
    ///   earlier share of the same link.
    /// - `productExternalID`, which matches a row the **server** wrote. A feed row is keyed
    ///   `event:<uuid>` and can never equal a catalogue key, so sharing something the app
    ///   was already showing you minted a second card for it — in the only mode the app
    ///   ships in.
    ///
    /// One product legitimately has several event rows — a drop, a markdown, a restock —
    /// so a product match can be ambiguous. A row that is already saved wins, because that
    /// is the one carrying somebody's note and board and the one they would expect to find
    /// again; otherwise the most recent, which is what the feed is currently showing.
    private static func existingRow(for externalID: String, in context: ModelContext) -> BrandUpdate? {
        if let exact = row(for: externalID, in: context) { return exact }

        let descriptor = FetchDescriptor<BrandUpdate>(
            predicate: #Predicate { $0.productExternalID == externalID }
        )
        let candidates = (try? context.fetch(descriptor)) ?? []
        return candidates.first { !$0.saves.isEmpty }
            ?? candidates.max { $0.publishedAt < $1.publishedAt }
    }

    /// Refreshes a row we already hold with what the storefront says now. Sizes sell out
    /// between one share and the next, and a stale variant list is what a watch would be
    /// evaluated against.
    private static func apply(_ product: FetchedItem, to update: BrandUpdate) {
        if !product.variants.isEmpty { update.variants = product.variants }
        // A row that reached the catalogue now knows which garment it is, so the next
        // share of it — or of the same product under a different link — finds it. This is
        // also how a `shared:` row repaired long after the fact becomes matchable.
        if update.productExternalID == nil { update.productExternalID = product.externalID }
        if update.imageURLStrings.isEmpty { update.imageURLStrings = product.imageURLStrings }
        update.isAvailable = product.isAvailable
        update.priceText = product.priceText ?? update.priceText
        update.priceAmount = product.priceAmount ?? update.priceAmount
    }

    /// Attaches the save to a brand already being watched, when it is the same brand.
    ///
    /// Matched on the *registrable domain*, not the hostname. Stripping `www.` and
    /// comparing what is left only works when the brand happens to be stored under the
    /// same host the link came from — and a brand is not one host. Palace answers on the
    /// apex, `www.`, `usa.` and `eu.`; the row holds whichever one it was added with, so
    /// a link from any of the other three matched nothing and the save arrived with no
    /// brand on it. On screen that is a card in the collection with no wordmark over it,
    /// a detail page with no brand in the title, and an item that contributes nothing to
    /// the brand facet of the style profile. Five of eleven saves in the test store were
    /// in exactly this state, all of them Palace.
    ///
    /// Deliberately does *not* create a brand for an unknown host: adding a link from
    /// some blog should not start watching that blog, and it would quietly fill the
    /// Brands tab with things the user never chose to follow.
    private static func matchingBrand(for link: URL, in context: ModelContext) -> Brand? {
        let brands = (try? context.fetch(FetchDescriptor<Brand>())) ?? []
        return brands.first { BrandDiscovery.isSameBrandHost(link, $0.websiteURL) }
    }

    /// Best available name, in descending order of how much it was written *for* this
    /// page. Falls back to the host so a card is never blank.
    private static func title(for save: SharedSave, metadata: PageMetadata, link: URL) -> String {
        for candidate in [metadata.title, save.title] {
            if let candidate, !candidate.trimmingCharacters(in: .whitespaces).isEmpty {
                return cleaned(candidate, siteName: metadata.siteName)
            }
        }
        return link.host() ?? link.absoluteString
    }

    /// Storefront titles are usually "Product Name | Kith" or "Product Name – Kith".
    /// The brand is already on the card, so the suffix is noise.
    private static func cleaned(_ title: String, siteName: String?) -> String {
        guard let siteName, !siteName.isEmpty else { return title }
        for separator in [" | ", " – ", " — ", " - "] {
            let suffix = "\(separator)\(siteName)"
            if title.hasSuffix(suffix) {
                return String(title.dropLast(suffix.count))
            }
        }
        return title
    }
}
