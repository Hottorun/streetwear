// DiscoverSave.swift
// Keeping something from a brand you don't follow.
//
// This is the one place the discovery feed is allowed to write to the store, and it is
// narrow on purpose. Cards live in memory — `DiscoverDeck` holds pages and persists none of
// them — because the feed's supply is *other people's catalogues*, and `FeedView` queries
// `#Predicate<BrandUpdate> { !$0.isSeen }`. Persisting a page would empty several thousand
// products from brands nobody follows into somebody's unread feed.
//
// So a row is minted at the moment somebody keeps something, and it is minted **already
// seen**. That is not a detail: a saved discovery card is a thing you went and got, not news
// that arrived, and there is nothing about it left to catch up on.
//
// The other half is dedupe. A discovery card is keyed the way the poller keys a product —
// `shopify:<id>` — and carries `productExternalID` besides, so following the brand later
// merges onto the row that already exists instead of minting a second card for the same
// jacket. That failure is not hypothetical: `SharedSaveImporter` shipped with a dedupe that
// worked in standalone and nowhere else, because it looked for a key a server-backed row
// never has.

import Foundation
import StreetwCore
import SwiftData

@MainActor
enum DiscoverSave {
    /// Files a discovery card into the wardrobe and returns the row, or nil if it could not
    /// be written.
    ///
    /// - Parameter type: `.inspiration`, matching every other one-tap save in the app. The
    ///   wardrobe/inspiration split is a decision people make later, if at all, and taxing a
    ///   reflexive save with it turns one tap into a question.
    @discardableResult
    static func save(
        _ card: DiscoverCard,
        type: SavedItem.SaveType = .inspiration,
        in context: ModelContext
    ) -> BrandUpdate? {
        let update = existingRow(for: card, in: context) ?? mint(card, in: context)

        // Already kept. Saving twice is a no-op rather than a second card — and returning
        // the row still lets the caller raise the confirmation, so the tap is acknowledged
        // instead of appearing to do nothing.
        if update.saves.isEmpty {
            context.insert(SavedItem(update: update, type: type))
        }
        try? context.save()
        return update
    }

    /// A row for this garment that the store already holds.
    ///
    /// Matched on the product key rather than the event key, for the reason
    /// `SharedSaveImporter.existingRow` is: a feed row is `event:<uuid>` because one garment
    /// produces several events over its life — a drop, a markdown, a restock — and that is
    /// right for a feed and useless for asking whether two things are the same jacket.
    ///
    /// Where several events describe one garment, a row that is **already saved** wins: that
    /// is the one carrying somebody's note and board. Otherwise the most recent.
    private static func existingRow(for card: DiscoverCard, in context: ModelContext) -> BrandUpdate? {
        let key = card.productExternalID

        let exact = FetchDescriptor<BrandUpdate>(
            predicate: #Predicate { $0.externalID == key }
        )
        if let hit = (try? context.fetch(exact))?.first { return hit }

        let byProduct = FetchDescriptor<BrandUpdate>(
            predicate: #Predicate { $0.productExternalID == key }
        )
        let candidates = (try? context.fetch(byProduct)) ?? []
        return candidates.first { !$0.saves.isEmpty }
            ?? candidates.max { $0.publishedAt < $1.publishedAt }
    }

    private static func mint(_ card: DiscoverCard, in context: ModelContext) -> BrandUpdate {
        let update = BrandUpdate(
            externalID: card.productExternalID,
            // Deliberately unattached. The brand is not followed — that is what put this card
            // on the screen — so there is no local `Brand` row to point at, and inserting one
            // would put an unfollowed shop in the Brands tab as a side effect of keeping a
            // t-shirt. `brandLabel` falls through to the declared site name, which is why the
            // wall still prints a wordmark over it.
            brand: nil,
            title: card.title,
            linkURL: card.linkURL.flatMap(URL.init(string:)),
            imageURLStrings: card.imageURLs,
            publishedAt: card.publishedAt,
            kind: .product,
            priceText: card.priceText,
            priceAmount: card.priceAmount,
            isAvailable: card.isAvailable,
            tags: card.tags,
            productType: card.productType,
            variants: card.variants ?? []
        )

        // **Seen, always.** See the file header — this is the rule the whole feed depends on.
        update.isSeen = true
        // The garment key beside the event key, so a later follow of this brand merges onto
        // this row rather than minting a second card for the same product.
        update.productExternalID = card.productExternalID
        // What the wall prints where a followed brand's name would go.
        update.siteName = card.brand.name
        update.siteLogoURLString = card.brand.logoURL

        context.insert(update)
        return update
    }
}
