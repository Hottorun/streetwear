// PreviewData.swift
// In-memory fixtures so previews render without hitting the network.

import Foundation
import StreetwCore
import SwiftData
import SwiftUI

@MainActor
enum PreviewData {
    static let container: ModelContainer = {
        let container = try! ModelContainer(
            for: Brand.self, BrandUpdate.self, SavedItem.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        seed(into: container.mainContext)
        return container
    }()

    static let engine = SyncEngine(context: container.mainContext)

    private static func seed(into context: ModelContext) {
        let kith = Brand(
            name: "Kith",
            websiteURL: URL(string: "https://kith.com"),
            instagramHandle: "kith",
            styleDescription: "Elevated basics, monogram everything",
            myRating: 4
        )
        kith.sources = [BrandSource(kind: .shopify, url: URL(string: "https://kith.com")!)]

        let bbc = Brand(
            name: "Billionaire Boys Club",
            websiteURL: URL(string: "https://bbcicecream.com"),
            instagramHandle: "bbcicecream",
            styleDescription: "Graphic, colourful streetwear",
            myRating: 5
        )
        bbc.sources = [BrandSource(kind: .shopify, url: URL(string: "https://bbcicecream.com")!)]

        context.insert(kith)
        context.insert(bbc)

        let samples: [(Brand, String, BrandUpdate.Kind, String, [String])] = [
            (kith, "Kith Oversized Hoodie - Black", .product, "$180", ["black", "hoodie", "oversized"]),
            (kith, "Kith Relaxed Denim - Indigo", .product, "$220", ["indigo", "denim", "relaxed"]),
            (kith, "Kith Cream Knit Crewneck", .restock, "$150", ["cream", "knit"]),
            (bbc, "BBC Arch Logo Tee - Navy", .product, "$70", ["navy", "tee", "boxy"]),
            (bbc, "BBC Astro Puffer Jacket", .product, "$450", ["black", "jacket", "oversized"])
        ]

        var saves: [BrandUpdate] = []
        for (index, sample) in samples.enumerated() {
            let (brand, title, kind, price, tags) = sample
            let update = BrandUpdate(
                externalID: "preview:\(index)",
                brand: brand,
                title: title,
                summary: "Preview item",
                linkURL: brand.websiteURL,
                publishedAt: Date().addingTimeInterval(-3600 * Double(index * 6)),
                kind: kind,
                priceText: price,
                isAvailable: true,
                tags: tags
            )
            context.insert(update)
            if index % 2 == 0 { saves.append(update) }
        }

        for update in saves {
            context.insert(SavedItem(update: update, type: .inspiration))
        }
        try? context.save()
    }
}
