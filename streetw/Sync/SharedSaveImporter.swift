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
    /// `route` is how a sold-out share becomes an offer to watch it. The extension cannot
    /// make that offer itself — it does no networking, so at share time nobody knows
    /// whether the thing is in stock — and by the time we do know, the share sheet is long
    /// gone. So the question is asked here, on the next foreground, which is within
    /// seconds of the share in the usual "share from Safari, switch back" flow.
    @discardableResult
    static func drain(into context: ModelContext, route: PushRoute? = nil) async -> Int {
        let pending = SharedInbox.pending()
        log.info("inbox: container \(SharedInbox.isAvailable ? "ok" : "MISSING"), \(pending.count) pending")
        guard !pending.isEmpty else { return 0 }

        var imported = 0
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
                if let landed { offerWatch(for: landed, in: context, route: route) }
            } catch {
                log.error("could not store \(item.save.url.absoluteString, privacy: .public): \(error)")
            }
        }
        return imported
    }

    /// Asks about a watch when — and only when — the storefront actually said the thing is
    /// gone. Saving something that is in stock needs no question, and a page that declared
    /// nothing about stock must not be guessed at: a prompt about a jacket you could have
    /// bought is the kind of interruption that gets an app's notifications turned off.
    private static func offerWatch(for externalID: String, in context: ModelContext, route: PushRoute?) {
        guard let route else { return }
        var descriptor = FetchDescriptor<BrandUpdate>(
            predicate: #Predicate { $0.externalID == externalID }
        )
        descriptor.fetchLimit = 1
        guard let update = try? context.fetch(descriptor).first,
              update.isAvailable == false,
              update.activeWatches.isEmpty
        else { return }
        route.offerWatch(update)
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

        let existing = (try? context.fetch(FetchDescriptor<BrandUpdate>()))?
            .first { $0.externalID == externalID }

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
        // Saved deliberately, so it is never "news" — it must not turn up in the feed
        // as an unread item the user has to dismiss.
        update.isSeen = true
        update.refreshGender()

        context.insert(update)
        context.insert(SavedItem(update: update, type: .inspiration, note: nil))
        return externalID
    }

    /// Refreshes a row we already hold with what the storefront says now. Sizes sell out
    /// between one share and the next, and a stale variant list is what a watch would be
    /// evaluated against.
    private static func apply(_ product: FetchedItem, to update: BrandUpdate) {
        if !product.variants.isEmpty { update.variants = product.variants }
        if update.imageURLStrings.isEmpty { update.imageURLStrings = product.imageURLStrings }
        update.isAvailable = product.isAvailable
        update.priceText = product.priceText ?? update.priceText
        update.priceAmount = product.priceAmount ?? update.priceAmount
    }

    /// Attaches the save to a brand already being watched, when the host matches.
    ///
    /// Deliberately does *not* create a brand for an unknown host: adding a link from
    /// some blog should not start watching that blog, and it would quietly fill the
    /// Brands tab with things the user never chose to follow.
    private static func matchingBrand(for link: URL, in context: ModelContext) -> Brand? {
        guard let host = link.host()?.replacingOccurrences(of: "www.", with: "") else { return nil }
        let brands = (try? context.fetch(FetchDescriptor<Brand>())) ?? []
        return brands.first { brand in
            guard let brandHost = brand.websiteURL?.host()?.replacingOccurrences(of: "www.", with: "") else {
                return false
            }
            return host == brandHost || host.hasSuffix(".\(brandHost)")
        }
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
