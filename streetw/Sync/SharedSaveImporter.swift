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
    @discardableResult
    static func drain(into context: ModelContext) async -> Int {
        let pending = SharedInbox.pending()
        log.info("inbox: container \(SharedInbox.isAvailable ? "ok" : "MISSING"), \(pending.count) pending")
        guard !pending.isEmpty else { return 0 }

        var imported = 0
        for item in pending {
            // One at a time on purpose: sharing happens a link at a time, and a burst of
            // parallel requests to one storefront is exactly what `PoliteFetcher`
            // exists to prevent elsewhere.
            let metadata = await metadata(for: item.save.url)
            let landed = importOne(item.save, metadata: metadata, into: context)
            if landed { imported += 1 }
            do {
                // Only once it is genuinely committed is the file dropped. A failed save
                // leaves the item in the inbox to be retried, which is the whole reason
                // reading and deleting are separate steps.
                try context.save()
                SharedInbox.remove(item.id)
                log.info("imported \(item.save.url.absoluteString, privacy: .public) (new: \(landed))")
            } catch {
                log.error("could not store \(item.save.url.absoluteString, privacy: .public): \(error)")
            }
        }
        return imported
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
    @discardableResult
    static func importOne(
        _ save: SharedSave,
        metadata: PageMetadata,
        into context: ModelContext
    ) -> Bool {
        // The canonical URL is what dedupes: a share sheet hands over links carrying
        // whatever tracking parameters the referring app added, so the same product
        // shared twice arrives as two different URLs.
        let link = metadata.canonicalURL ?? save.url
        let externalID = "shared:\(link.absoluteString)"

        let existing = (try? context.fetch(FetchDescriptor<BrandUpdate>()))?
            .first { $0.externalID == externalID }

        if let existing {
            // Already here. Re-sharing something is a request to keep it, not a
            // request for a duplicate card.
            if existing.save == nil {
                context.insert(SavedItem(update: existing, type: .inspiration))
                return true
            }
            return false
        }

        let update = BrandUpdate(
            externalID: externalID,
            brand: matchingBrand(for: link, in: context),
            title: title(for: save, metadata: metadata, link: link),
            summary: nil,
            linkURL: link,
            imageURLStrings: metadata.imageURL.map { [$0.absoluteString] } ?? [],
            publishedAt: save.sharedAt,
            kind: .product,
            priceText: metadata.price
        )
        // Saved deliberately, so it is never "news" — it must not turn up in the feed
        // as an unread item the user has to dismiss.
        update.isSeen = true

        context.insert(update)
        context.insert(SavedItem(update: update, type: .inspiration, note: nil))
        return true
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
