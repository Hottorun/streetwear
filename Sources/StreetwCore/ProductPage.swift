// ProductPage.swift
// What a product's own page says about it, read from the structured data it publishes for
// search engines.
//
// A sitemap names a product and at best gives it a photograph. Everything the rest of the
// app runs on — the price, the size run, what is sold out — is on the product's page, and
// nearly every storefront writes it there twice: once for people, and once as schema.org
// `Product` JSON-LD so that Google can print a price under the search result. The second
// copy is meant to be read by machines, which is what makes reading it honest.
//
// Checked against the pages behind the three sitemaps this was built for: Hollister renders
// a `Product` with a sale price and a list price side by side in `priceSpecification` and
// spells its SKU `"SKU"`; Subdued writes its offer's type as a full IRI and its price as a
// bare number. Neither publishes a size per offer — schema.org has two ways to (offers that
// each name an `itemOffered` or `sku`, and a `ProductGroup` with `hasVariant`), and both are
// read when they are there, because they are what turns a row into a size run somebody can
// watch.
//
// **Once per new product, never per poll.** A page is the heaviest request this package
// makes — Hollister's is 968 KB — so it is made behind the politeness budget, a few per
// pass (`Poller.enrichmentBudget`), and only again for something somebody is watching.
//
// Parsing is pure and lives here because both ends need the same answer: the server enriches
// for everybody, and the phone does the same for itself under `-standalone YES`.

import Foundation

public struct ProductPage: Sendable, Hashable {
    public var name: String?
    public var summary: String?
    public var imageURLs: [String]
    public var sku: String?
    public var color: String?
    public var category: String?
    public var currency: String?
    /// The lowest *selling* price across the offers. A list price ("was £45.95") is never
    /// taken for it — Hollister publishes both in one offer.
    public var price: Double?
    /// Nil when the page declared nothing about stock, which is not the same as in stock.
    public var isAvailable: Bool?
    /// One per size or colour the page names, when it names any.
    public var variants: [VariantInfo]

    public init(
        name: String? = nil,
        summary: String? = nil,
        imageURLs: [String] = [],
        sku: String? = nil,
        color: String? = nil,
        category: String? = nil,
        currency: String? = nil,
        price: Double? = nil,
        isAvailable: Bool? = nil,
        variants: [VariantInfo] = []
    ) {
        self.name = name
        self.summary = summary
        self.imageURLs = imageURLs
        self.sku = sku
        self.color = color
        self.category = category
        self.currency = currency
        self.price = price
        self.isAvailable = isAvailable
        self.variants = variants
    }

    /// What reading one page came to.
    public enum Outcome: Sendable, Hashable {
        case product(ProductPage)
        /// The page loaded and says it is not a product — no `Product` data, no Open Graph
        /// product. For a URL only the page could confirm, that is the answer.
        case notAProduct
        /// The page could not be read. `retryable` only for our own congestion
        /// (`SourceError.hostBusy`): a 404, a bot wall or a timeout is stamped and left, the
        /// rule every one-shot enrichment here follows, or a dead URL is re-fetched forever.
        case unreachable(retryable: Bool)
    }

    public static func read(_ url: URL, http: any HTTPFetching = Net.live) async -> Outcome {
        await reading(url, http: http).outcome
    }

    /// The same, with the page itself whenever it loaded — so a page with no structured data
    /// can still be read some other way (the server's model reading, once, for a new product)
    /// without being fetched a second time.
    public static func reading(_ url: URL, http: any HTTPFetching = Net.live) async -> (outcome: Outcome, html: String?) {
        let response: HTTPResponse
        do {
            response = try await http.get(url)
        } catch SourceError.hostBusy {
            return (.unreachable(retryable: true), nil)
        } catch {
            return (.unreachable(retryable: false), nil)
        }
        guard response.status == 200,
              let html = String(data: response.data, encoding: .utf8)
                ?? String(data: response.data, encoding: .isoLatin1)
        else { return (.unreachable(retryable: false), nil) }

        return (parse(html, base: response.finalURL ?? url).map(Outcome.product) ?? .notAProduct, html)
    }

    /// The product a page describes, or nil when it describes none.
    ///
    /// JSON-LD first. Open Graph is the fallback, and only when it prints a price — the same
    /// tags `PageMetadataParser` reads for a shared link, and less than JSON-LD carries, but
    /// still the page's own statement.
    public static func parse(_ html: String, base: URL) -> ProductPage? {
        let nodes = blocks(in: html).flatMap(productNodes(in:))
        if let node = primary(of: nodes) {
            return reading(node, base: base)
        }
        return openGraph(PageMetadataParser.parse(html, base: base))
    }

    /// The same reading over a page somebody else already took apart: the raw text of each
    /// JSON-LD block and the page's tags, as the share sheet reads them out of the page Safari
    /// loaded. One parser for both, so a share read in the browser and a page the app fetched
    /// itself cannot come to different answers about the same product.
    public static func parse(jsonLD: [String], metadata: PageMetadata, base: URL) -> ProductPage? {
        let nodes = jsonLD.compactMap(decodedBlock).flatMap(productNodes(in:))
        if let node = primary(of: nodes) {
            return reading(node, base: base)
        }
        return openGraph(metadata)
    }

    /// This page's facts laid over what the sitemap knew, under the same identity.
    ///
    /// The page's name replaces the sitemap's — a slug or an `<image:title>` was always the
    /// stand-in for it — and its photographs replace the sitemap's single frame only when
    /// there are more of them, never fewer. Price, stock and variants are the page's
    /// outright: the sitemap never had any.
    public func applied(to item: FetchedItem) -> FetchedItem {
        var item = item
        if let name, !name.isEmpty { item.title = name }
        if item.summary == nil { item.summary = summary }
        if imageURLs.count > item.imageURLStrings.count { item.imageURLStrings = imageURLs }
        if item.productType == nil { item.productType = category }
        if item.tags.isEmpty, let color { item.tags = [color] }
        if let price, let currency {
            item.priceText = ShopifySource.formatPrice(String(price), currency: currency)
            item.currency = CurrencyCode.normalized(currency)
        }
        item.priceAmount = price ?? item.priceAmount
        item.isAvailable = isAvailable ?? item.isAvailable
        if !variants.isEmpty { item.variants = variants }
        return item
    }

    // MARK: - Finding the product

    /// Every JSON-LD block on the page, decoded. A block that will not decode is retried with
    /// raw line breaks flattened — the commonest way a template breaks its own JSON is an
    /// unescaped newline inside a description — and otherwise skipped.
    static func blocks(in html: String) -> [Any] {
        guard let pattern = try? NSRegularExpression(
            pattern: "<script[^>]*type\\s*=\\s*[\"']?application/ld\\+json[\"']?[^>]*>(.*?)</script>",
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return [] }

        var decoded: [Any] = []
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        for match in pattern.matches(in: html, range: range) {
            guard let bodyRange = Range(match.range(at: 1), in: html) else { continue }
            if let value = decodedBlock(String(html[bodyRange])) {
                decoded.append(value)
            }
        }
        return decoded
    }

    /// One block's text, decoded — with the comment and CDATA wrappers templates put around
    /// it removed first.
    static func decodedBlock(_ text: String) -> Any? {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for wrapper in ["<!--", "-->", "<![CDATA[", "]]>", "//<![CDATA[", "//]]>"] {
            body = body.replacingOccurrences(of: wrapper, with: "")
        }
        return json(body) ?? json(body.components(separatedBy: .newlines).joined(separator: " "))
    }

    private static func json(_ text: String) -> Any? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// Every `Product` or `ProductGroup` node in a decoded block, wherever it is nested —
    /// top level, in an array, under `@graph` or `mainEntity`, or as the `itemOffered` of a
    /// lone `Offer`. A variant is not collected here: it belongs to its group.
    static func productNodes(in value: Any) -> [[String: Any]] {
        if let array = value as? [Any] {
            return array.flatMap(productNodes(in:))
        }
        guard let object = value as? [String: Any] else { return [] }
        if isProduct(object) { return [object] }
        var found: [[String: Any]] = []
        for key in ["@graph", "mainEntity", "mainEntityOfPage", "itemOffered", "about"] {
            if let nested = object[key] { found += productNodes(in: nested) }
        }
        return found
    }

    /// A group beats a product, because it carries the variants; otherwise the first product
    /// that has offers, because a page often also describes "related products" without them.
    private static func primary(of nodes: [[String: Any]]) -> [String: Any]? {
        nodes.first { types(of: $0).contains("productgroup") }
            ?? nodes.first { $0["offers"] != nil }
            ?? nodes.first
    }

    private static func isProduct(_ object: [String: Any]) -> Bool {
        let kinds = types(of: object)
        return kinds.contains("product") || kinds.contains("productgroup")
            || kinds.contains("individualproduct") || kinds.contains("productmodel")
    }

    /// `@type` lowered to its local name: "Product", "http://schema.org/Product" and
    /// `["Product", "Clothing"]` all contain "product". Subdued writes its offer's type as
    /// a full IRI.
    static func types(of object: [String: Any]) -> [String] {
        let raw: [String]
        switch object["@type"] {
        case let one as String: raw = [one]
        case let many as [Any]: raw = many.compactMap { $0 as? String }
        default: raw = []
        }
        return raw.map { type in
            let lowered = type.lowercased()
            let local = lowered.split(whereSeparator: { $0 == "/" || $0 == ":" || $0 == "#" }).last
            return local.map(String.init) ?? lowered
        }
    }

    // MARK: - Reading the product

    private static func reading(_ node: [String: Any], base: URL) -> ProductPage {
        var page = ProductPage()
        page.name = text(node["name"]).flatMap(cleaned)
        page.summary = text(node["description"]).map(ShopifySource.plainText(from:)).flatMap(cleaned)
        page.imageURLs = images(node["image"], base: base)
        page.sku = text(value(node, "sku") ?? value(node, "mpn") ?? value(node, "productID"))
        page.color = text(node["color"]).flatMap(cleaned)
        page.category = text(node["category"]).flatMap(cleaned)

        let offers = self.offers(in: node["offers"])
        page.variants = variants(of: node, offers: offers, productName: page.name)

        // The lowest, the way the Shopify adapter reads a product whose S is on sale and
        // whose XL is not: that is the price a shopper sees first.
        page.price = offers.compactMap(\.price).filter { $0 > 0 }.min() ?? groupPrices(of: node).min()
        page.currency = offers.compactMap(\.currency).first ?? groupCurrency(of: node)

        let stock = page.variants.isEmpty
            ? offers.compactMap(\.isAvailable)
            : page.variants.map(\.available)
        page.isAvailable = stock.isEmpty ? nil : stock.contains(true)

        // A group's images are often only on its variants.
        if page.imageURLs.isEmpty {
            page.imageURLs = hasVariant(node).flatMap { images($0["image"], base: base) }.uniqued()
        }
        return page
    }

    /// One offer, reduced to what is used.
    struct Offer {
        var price: Double?
        var currency: String?
        var isAvailable: Bool?
        var sku: String?
        var name: String?
        var size: String?
        var color: String?
    }

    /// `Offer`, `[Offer]` or an `AggregateOffer` holding either — flattened.
    static func offers(in value: Any?) -> [Offer] {
        if let array = value as? [Any] { return array.flatMap { offers(in: $0) } }
        guard let object = value as? [String: Any] else { return [] }
        if types(of: object).contains("aggregateoffer") {
            if let nested = object["offers"] { return offers(in: nested) }
            let low = number(object["lowPrice"]) ?? number(object["price"])
            return [Offer(
                price: low,
                currency: text(object["priceCurrency"]),
                isAvailable: text(object["availability"]).flatMap(PageMetadataParser.availability(from:))
            )]
        }

        let item = object["itemOffered"] as? [String: Any]
        return [Offer(
            price: sellingPrice(of: object),
            currency: text(object["priceCurrency"]) ?? specifications(of: object).compactMap { text($0["priceCurrency"]) }.first,
            isAvailable: text(object["availability"]).flatMap(PageMetadataParser.availability(from:)),
            sku: text(Self.value(object, "sku") ?? item.flatMap { Self.value($0, "sku") }),
            name: text(object["name"] ?? item?["name"]).flatMap(cleaned),
            size: text(item?["size"] ?? object["size"]).flatMap(cleaned),
            color: text(item?["color"] ?? object["color"]).flatMap(cleaned)
        )]
    }

    /// The price somebody would pay. `priceSpecification` can hold several — Hollister's
    /// holds the sale price and, beside it, a `ListPrice` that is what it *was* — and only
    /// a specification that is not a list, strikethrough or suggested price counts.
    private static func sellingPrice(of offer: [String: Any]) -> Double? {
        let specifications = specifications(of: offer)
        let selling = specifications.filter { spec in
            let type = text(spec["priceType"])?.lowercased() ?? ""
            return !["listprice", "strikethroughprice", "msrp", "suggestedretailprice"].contains { type.hasSuffix($0) }
        }
        return selling.compactMap { number($0["price"]) }.min()
            ?? number(offer["price"])
            ?? number(offer["lowPrice"])
    }

    private static func specifications(of offer: [String: Any]) -> [[String: Any]] {
        switch offer["priceSpecification"] {
        case let one as [String: Any]: [one]
        case let many as [Any]: many.compactMap { $0 as? [String: Any] }
        default: []
        }
    }

    /// The size run, from whichever of schema.org's two shapes the page uses.
    ///
    /// A `ProductGroup` lists its variants as products of their own, each with a size, a
    /// colour and an offer. Otherwise a product whose offers each name a size — through
    /// `itemOffered`, or an offer `name` that reads as one — has one variant per offer. A
    /// single offer is the product's price and stock, not a size run.
    static func variants(of node: [String: Any], offers: [Offer], productName: String?) -> [VariantInfo] {
        let members = hasVariant(node)
        if !members.isEmpty {
            return members.enumerated().map { index, member in
                let offer = self.offers(in: member["offers"]).first
                let size = text(member["size"]).flatMap(cleaned) ?? offer?.size
                let color = text(member["color"]).flatMap(cleaned) ?? offer?.color
                let id = text(value(member, "sku") ?? member["@id"] ?? member["url"]) ?? offer?.sku ?? "variant-\(index)"
                return VariantInfo(
                    id: id,
                    title: [color, size].compactMap { $0 }.joined(separator: " / ").nonEmpty
                        ?? text(member["name"]) ?? id,
                    // A variant that says nothing about stock is shown as buyable: the
                    // cautious reading is the one that hides nothing.
                    available: offer?.isAvailable ?? true,
                    price: offer.flatMap(formatted),
                    size: size,
                    color: color
                )
            }
        }

        guard offers.count > 1 else { return [] }
        let sized: [(Offer, String?)] = offers.map { offer in
            (offer, offer.size ?? offer.name.flatMap { name in
                name != productName && SizeNormalizer.normalize(name).map { $0.kind != .other } == true ? name : nil
            })
        }
        // Several offers with nothing to tell them apart are several sellers or currencies
        // of one thing, not a size run.
        guard sized.contains(where: { $0.1 != nil || $0.0.color != nil }) else { return [] }
        return sized.enumerated().map { index, pair in
            let (offer, size) = pair
            let id = offer.sku ?? "offer-\(index)"
            return VariantInfo(
                id: id,
                title: [offer.color, size].compactMap { $0 }.joined(separator: " / ").nonEmpty ?? id,
                available: offer.isAvailable ?? true,
                price: formatted(offer),
                size: size,
                color: offer.color
            )
        }
    }

    private static func hasVariant(_ node: [String: Any]) -> [[String: Any]] {
        switch node["hasVariant"] {
        case let one as [String: Any]: [one]
        case let many as [Any]: many.compactMap { $0 as? [String: Any] }
        default: []
        }
    }

    private static func groupPrices(of node: [String: Any]) -> [Double] {
        hasVariant(node).flatMap { offers(in: $0["offers"]).compactMap(\.price) }.filter { $0 > 0 }
    }

    private static func groupCurrency(of node: [String: Any]) -> String? {
        hasVariant(node).lazy.compactMap { offers(in: $0["offers"]).compactMap(\.currency).first }.first
    }

    private static func formatted(_ offer: Offer) -> String? {
        guard let price = offer.price, price > 0, let currency = offer.currency else { return nil }
        return ShopifySource.formatPrice(String(price), currency: currency)
    }

    // MARK: - Open Graph

    /// The fallback for a page with no JSON-LD product: Open Graph, and only when it prints
    /// a price.
    ///
    /// **`og:type` is not evidence.** Hollister's *homepage* declares `og:type` `product`,
    /// so a page that says so and sells nothing at a price is not taken for one — which
    /// matters most for a URL only the page could confirm. And Subdued prints
    /// `product:price:amount` as `0` on a product it is not selling, so a zero is no price.
    private static func openGraph(_ metadata: PageMetadata) -> ProductPage? {
        let amount = metadata.price
            .flatMap { $0.split(separator: " ").first.map(String.init) }
            .flatMap { number($0) }
            .flatMap { $0 > 0 ? $0 : nil }
        guard amount != nil else { return nil }

        var page = ProductPage()
        page.name = metadata.title.flatMap(cleaned)
        page.imageURLs = metadata.imageURL.map { [$0.absoluteString] } ?? []
        page.price = amount
        page.currency = metadata.price.flatMap { $0.split(separator: " ").dropFirst().first.map(String.init) }
        page.isAvailable = metadata.isAvailable
        return page
    }

    // MARK: - Values

    /// A key looked up case-insensitively — Hollister writes `"SKU"`.
    private static func value(_ object: [String: Any], _ key: String) -> Any? {
        object[key] ?? object.first { $0.key.lowercased() == key.lowercased() }?.value
    }

    /// A string out of whatever schema.org allowed there: a string, a number, the first of
    /// an array, or a `{"name": …}` / `{"@value": …}` object.
    static func text(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let number as NSNumber:
            return number.stringValue
        case let array as [Any]:
            return array.lazy.compactMap { text($0) }.first
        case let object as [String: Any]:
            return text(object["name"] ?? object["@value"])
        default:
            return nil
        }
    }

    /// A price out of a number or a string, in either decimal convention.
    ///
    /// "28.99", 28.99, "1,234.56", "29,95" and "€ 29,95" are all prices storefronts write.
    /// A comma is a decimal point when it is the last separator and two digits follow it.
    static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        guard var string = text(value) else { return nil }
        string = string.filter { $0.isNumber || $0 == "." || $0 == "," }
        guard !string.isEmpty else { return nil }
        if let comma = string.lastIndex(of: ","),
           string.distance(from: comma, to: string.endIndex) == 3,
           string.lastIndex(of: ".").map({ $0 < comma }) ?? true {
            string = string.replacingOccurrences(of: ".", with: "")
            string = string.replacingOccurrences(of: ",", with: ".")
        } else {
            string = string.replacingOccurrences(of: ",", with: "")
        }
        return Double(string)
    }

    /// Image URLs out of a string, an `ImageObject`, or an array of either; resolved
    /// against the page, https only, in order, without repeats.
    static func images(_ value: Any?, base: URL) -> [String] {
        let raw: [String]
        switch value {
        case let string as String: raw = [string]
        case let array as [Any]: raw = array.compactMap(imageLocation)
        case let object as [String: Any]: raw = imageLocation(object).map { [$0] } ?? []
        default: raw = []
        }
        return raw.compactMap { location -> String? in
            // A word is not an address. Intimissimi writes `"image": "not_available"` on every
            // variant, which resolved against the page became a photograph at
            // `/de/product/not_available`.
            guard location.contains("/") || location.contains(".") else { return nil }
            let fixed = location.hasPrefix("//") ? "https:\(location)" : location
            guard let url = URL(string: fixed, relativeTo: base)?.absoluteURL,
                  url.scheme == "https" || url.scheme == "http"
            else { return nil }
            return url.absoluteString
        }.uniqued()
    }

    private static func imageLocation(_ value: Any) -> String? {
        if let string = value as? String { return string }
        guard let object = value as? [String: Any] else { return nil }
        return text(object["url"] ?? object["contentUrl"] ?? object["@id"])
    }

    private static func cleaned(_ text: String) -> String? {
        let decoded = HTMLEntities.decode(text).trimmingCharacters(in: .whitespacesAndNewlines)
        return decoded.isEmpty ? nil : decoded
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

private extension Array where Element == String {
    func uniqued() -> [String] {
        var seen: Set<String> = []
        return filter { seen.insert($0).inserted }
    }
}
