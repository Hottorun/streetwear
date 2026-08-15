// PreviewImages.swift
// Choosing which of a brand's photographs are worth showing to someone who has never
// seen the brand.
//
// Storefronts publish policy graphics, size charts, delivery banners and gift-card art in
// the same product feed as the clothes — they are "products" as far as `/products.json` is
// concerned, with a title, a price and an image. One of them led Represent's recommendation
// card: a truck icon captioned "Worry-Free Purchase", as the first and only impression of a
// fashion brand.
//
// Two signals, and the **title is the reliable one**. A file name is often a hash or a
// generic `icon_1024x.png`, but a merchandiser has to name the thing, and they name it what
// it is. The file name is kept as a second pass because some storefronts do the opposite.
//
// Shared rather than living in the app, because both ends need the same answer: the server
// picks which images to put on the wire, and the client filters again over whatever a
// server too old to know about this sent.

import Foundation

public enum PreviewImages {
    /// Words that mark a "product" which is not a garment.
    ///
    /// Whole-token matching, not `contains`: "gift" would otherwise take a gift-wrap
    /// jacket, and "case" would take a phone case, which is a real product a brand sells.
    /// Multi-word phrases are matched as substrings, since they cannot collide by accident.
    private static let phrases = [
        "worry free", "worry-free", "gift card", "gift certificate", "e-gift",
        "size chart", "size guide", "sizing guide", "shipping", "delivery",
        "returns policy", "return policy", "store credit", "donation", "sample sale",
        "coming soon", "placeholder", "test product", "do not buy", "klarna", "afterpay",
        "newsletter", "subscription", "loyalty", "warranty", "protection plan"
    ]

    /// Single tokens that are never a garment on their own.
    private static let tokens: Set<String> = [
        "giftcard", "egiftcard", "shipping", "delivery", "returns", "sizechart",
        "sizeguide", "banner", "promo", "policy", "placeholder", "voucher"
    ]

    /// Whether a catalogue row is something worth photographing on a discovery card.
    ///
    /// **Two conditions, and the second one is the guard rail.** A row is refused only when
    /// the promotional vocabulary matches *and* `GarmentClassifier` cannot place it on the
    /// body. On its own the vocabulary is far too eager: "Delivery Driver Jacket" and
    /// "Policy Tee" are real clothes that a word list rejects, and a filter that hides real
    /// product is the failure this whole layer exists to avoid — a brand's card would show
    /// the wrong three photographs and nobody would ever know why. Both were caught by the
    /// test rather than by inspection, which is the argument for having it.
    ///
    /// - Parameters:
    ///   - title: the product's own name — the signal that actually works.
    ///   - imageURL: its lead photograph, checked as a fallback.
    public static func isGarment(title: String, imageURL: String? = nil) -> Bool {
        // Anything the classifier can place is a garment, whatever it happens to be
        // called. This is the same vocabulary the fit canvas and the wardrobe already
        // trust, so there is no second list to keep in step.
        guard GarmentClassifier.classify(title: title) == .unknown else { return true }

        if matches(title) { return false }
        // The file name, minus any query string — CDNs append `?v=` cache busters, and a
        // resize suffix like `_1024x` sits inside the name rather than after it.
        if let imageURL,
           let name = URL(string: imageURL)?.lastPathComponent,
           matches(name.replacingOccurrences(of: "_", with: " ")) {
            return false
        }
        return true
    }

    private static func matches(_ text: String) -> Bool {
        let lowered = text.lowercased()
        if phrases.contains(where: { lowered.contains($0) }) { return true }
        let words = lowered
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
        return words.contains { tokens.contains($0) }
    }

    /// The lead photographs to show for a brand, in catalogue order.
    ///
    /// Falls back to the unfiltered set only when filtering left no *photograph* — a brand
    /// whose entire recent catalogue reads as promotional is more likely to be one this
    /// vocabulary has misjudged than one with nothing to show.
    ///
    /// The image is picked out **before** the fallback is decided, not after. Written the
    /// other way round, a brand whose garments are all imageless — perfectly ordinary for a
    /// sitemap-sourced storefront — counts as "filtering removed nothing", skips the
    /// fallback, and then returns an empty list from rows that had pictures on them. The
    /// question this is answering is which photographs to show, so a row with no photograph
    /// cannot be evidence either way.
    public static func pick(
        from rows: [(title: String, imageURL: String?)],
        limit: Int
    ) -> [String] {
        let garments = rows
            .filter { isGarment(title: $0.title, imageURL: $0.imageURL) }
            .compactMap(\.imageURL)
        let source = garments.isEmpty ? rows.compactMap(\.imageURL) : garments
        return Array(source.prefix(limit))
    }
}
