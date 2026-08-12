// UpdateKind.swift
// Standalone so the whole core stays free of SwiftData and can be lifted into the
// server target unchanged. Previously nested inside the `@Model` BrandUpdate, which
// coupled every adapter to the persistence layer.

import Foundation

public enum UpdateKind: String, Codable, Sendable, CaseIterable {
    case product
    case restock
    case collection
    case post
    case pageChange
    case dropLock
    /// A price cut on something already in the catalogue.
    ///
    /// Only *drops* exist as a case, deliberately. A brand raising a price is a fact
    /// nobody wants pushed to their phone, and treating every edit as an event would
    /// turn the feed into a changelog — the thing this app is trying not to be.
    case priceDrop

    public var label: String {
        switch self {
        case .product: "New product"
        case .restock: "Restocked"
        case .collection: "New collection"
        case .post: "Post"
        case .pageChange: "Page changed"
        case .dropLock: "Locked for drop"
        case .priceDrop: "Price drop"
        }
    }

    /// SF Symbol name. Presentation detail, but small enough to keep alongside the
    /// case list rather than duplicating the switch in every client.
    public var symbol: String {
        switch self {
        case .product: "sparkles"
        case .restock: "arrow.clockwise"
        case .collection: "square.grid.2x2"
        case .post: "camera"
        case .pageChange: "eye"
        case .dropLock: "lock"
        case .priceDrop: "arrow.down.right"
        }
    }
}

/// One purchasable variant. Tracking these individually is what makes
/// "restocked in your size" possible — collapsing to "any variant available"
/// loses exactly the information that matters.
public struct VariantInfo: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var available: Bool
    public var price: String?

    /// Pulled from the option axis actually named "Size", not parsed out of `title` —
    /// which for multi-axis products reads "WHITE/OWHITE/CBROWN / 5".
    public var size: String?
    public var color: String?

    /// Which of the product's photographs shows this variant, as an index into
    /// `imageURLStrings`.
    ///
    /// An index rather than a URL, deliberately. The URL is already in the images array —
    /// sending it again would put a second copy of every photograph on the wire, once per
    /// variant, for a product that runs six sizes in four colours. An index is four bytes
    /// and is what a gallery needs anyway.
    ///
    /// Shopify has always published this and the adapter always discarded it, so selecting
    /// a colourway filtered the size run while the photograph stayed on whatever colour was
    /// first. You tapped Aqua and went on looking at the black one, which reads as the
    /// control being broken rather than as a missing feature.
    public var imageIndex: Int?

    public init(
        id: String,
        title: String,
        available: Bool,
        price: String? = nil,
        size: String? = nil,
        color: String? = nil,
        imageIndex: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.available = available
        self.price = price
        self.size = size
        self.color = color
        self.imageIndex = imageIndex
    }

    /// Shopify uses "Default Title" for products with no real options.
    public var isMeaningfulSize: Bool {
        let value = size ?? title
        return value != "Default Title" && !value.isEmpty
    }

    /// What to show the user: the size axis if there is one, else the whole title.
    public var displaySize: String { size ?? title }
}
