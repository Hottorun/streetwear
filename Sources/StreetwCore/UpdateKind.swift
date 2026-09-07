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

    /// What happened, in words, for `count` events of this kind.
    ///
    /// The line the feed's spread is built around — "12 new products", not "PRODUCT" — and
    /// it lives here rather than in the view because **two screens now print it**: the story
    /// headline in the feed, and the heading of the page that headline opens onto, which is
    /// that same story at full size. The one is a promise about the other, so a sentence that
    /// could differ between them is a screen that appears to have taken you somewhere else.
    ///
    /// `pageChange` and `dropLock` ignore the count on purpose: a hash moving twice is not
    /// two pieces of news, and a storefront is locked or it is not.
    public func headline(count: Int) -> String {
        switch self {
        case .product: count == 1 ? "A new product" : "\(count) new products"
        case .restock: count == 1 ? "One thing is back" : "\(count) things are back"
        case .priceDrop: count == 1 ? "A price cut" : "\(count) price cuts"
        case .post: count == 1 ? "A new post" : "\(count) new posts"
        case .pageChange: "Something on the site changed"
        case .dropLock: "Locked — a drop is imminent"
        case .collection: count == 1 ? "A new collection" : "\(count) new collections"
        }
    }

    /// Whether an event of this kind is **sudden**: worth acting on within minutes, and
    /// findable no other way.
    ///
    /// This is the line the server has always drawn to decide what is worth interrupting
    /// somebody for — `Notifier.isWorthWaking` is now this property, and its doc comment
    /// carries the argument for each case. It lives here because the *feed* asks the same
    /// question and must not answer it differently: a screen that gives its largest slot to
    /// the thing a push deliberately stayed silent about is the app contradicting itself,
    /// and two switches over the same seven cases in two modules is how that happens.
    ///
    /// Nothing is hidden by a `false` here. A restock, a markdown, a page hash moving and a
    /// brand's own marketing all still land in the feed, still count as unread, still reach
    /// the markdowns list. This decides only what leads.
    public var isSudden: Bool {
        switch self {
        case .product, .collection, .dropLock: true
        case .restock, .priceDrop, .pageChange, .post: false
        }
    }

    /// Where an event of this kind sits when a brand's spread is read as **news**.
    ///
    /// The feed leads each brand with what *happened* and demotes the garments to its
    /// contents, so something has to decide which of a brand's events is the headline. It is
    /// not the count and it is not the newest timestamp: it is `isSudden` above, refined
    /// into a total order so that two sudden kinds landing in the same poll — a storefront
    /// locking while a season is announced — still have a settled answer between them.
    ///
    /// The lock comes first because it is about the next few minutes; a release outranks the
    /// garments because it is *about* them.
    ///
    /// Fixed rather than derived from how many of each landed. A rank computed from counts
    /// would reorder a brand's spread as its items are read, which is precisely the
    /// property the feed's brand ordering exists to protect.
    public var newsRank: Int {
        switch self {
        case .dropLock: 0
        case .collection: 1
        case .product: 2
        case .restock: 3
        case .priceDrop: 4
        case .post: 5
        case .pageChange: 6
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
