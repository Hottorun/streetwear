// ShopifySource.swift
// Reads a Shopify storefront's public /products.json catalog.
//
// This is the workhorse. A large share of streetwear brands run Shopify, and the
// endpoint is public, structured, and free: title, images, price, tags, availability
// and published_at — everything needed for "12 new products" and "restocked".

import Foundation

public struct ShopifySource: SourceAdapter {
    public var kind: BrandSource.Kind { .shopify }

    private let http: any HTTPFetching

    public init(http: any HTTPFetching = Net.live) {
        self.http = http
    }

    /// 250 is Shopify's per-page maximum.
    public static let pageSize = 250
    /// Ceiling on a single sync. Page 1 covers roughly four days for a busy brand, so
    /// this is a wide net for anything but a first run.
    public static let maxPages = 10

    public func fetch(_ source: BrandSource, since: Date?) async throws -> FetchResult {
        // Page 1 carries the validator: if it 304s, the newest products are unchanged
        // and there is nothing further back that could have moved.
        let first = try await http.get(Self.catalogURL(for: source.url, page: 1), etag: source.etag)

        if first.isLocked {
            return FetchResult(isLocked: true)
        }
        if first.notModified {
            return FetchResult(etag: source.etag, notModified: true)
        }
        try first.requireOK()

        guard let firstPage = try? JSONDecoder().decode(Catalog.self, from: first.data) else {
            // Not a Shopify store (HTML error page, or a different platform).
            throw SourceError.notThisKind
        }

        var products = firstPage.products
        var page = 1

        // products.json is sorted by published_at descending, so we can stop as soon as
        // a page ends older than what we've already seen. Without this we only ever saw
        // the newest 250 products — and a restocked older item never re-enters that
        // window, because restocking doesn't change published_at.
        while page < Self.maxPages,
              products.count == page * Self.pageSize,
              Self.shouldContinue(after: products.last, since: since) {
            page += 1
            let next = try await http.get(Self.catalogURL(for: source.url, page: page))
            guard next.status == 200,
                  let decoded = try? JSONDecoder().decode(Catalog.self, from: next.data),
                  !decoded.products.isEmpty
            else { break }
            products.append(contentsOf: decoded.products)
        }

        let shop = await Self.shopInfo(for: source.url, http: http)
        let currency = shop?.currency ?? "USD"
        let items = products.map { Self.item(from: $0, storeURL: source.url, currency: currency) }

        return FetchResult(
            items: items,
            isLocked: false,
            etag: first.etag,
            shopCurrency: shop?.currency,
            shopName: shop?.name
        )
    }

    private static func shouldContinue(after last: Product?, since: Date?) -> Bool {
        guard let since else { return true } // first sync: take the full net
        guard let oldest = last?.publishedAt ?? last?.createdAt else { return true }
        return oldest > since
    }

    /// Probe used when adding a brand: does this domain serve a Shopify catalog?
    public static func detect(at base: URL, http: any HTTPFetching = Net.live) async -> Bool {
        await resolve(at: base, http: http) != nil
    }

    /// Which host actually serves the catalog — the one asked about, or its `www.`
    /// sibling — or nil when neither does.
    ///
    /// The apex and the `www.` host are not interchangeable on a store that has moved its
    /// storefront to Hydrogen: the new front end answers on the apex and knows nothing
    /// about `/products.json`, while the classic Shopify origin still serves the full
    /// catalog on `www.`. Palace does exactly this, and probing only the apex demoted a
    /// storefront with titles, prices, images and stock all the way down to a sitemap —
    /// which is how a feed ended up full of randomised handles over empty tiles.
    public static func resolve(at base: URL, http: any HTTPFetching = Net.live) async -> URL? {
        for candidate in [base, wwwVariant(of: base)].compactMap({ $0 }) {
            guard let response = try? await http.get(catalogURL(for: candidate, page: 1)),
                  response.status == 200,
                  let catalog = try? JSONDecoder().decode(Catalog.self, from: response.data),
                  !catalog.products.isEmpty
            else { continue }
            return candidate
        }
        return nil
    }

    /// The `www.` sibling of an apex host, or the apex of a `www.` host. Nil for anything
    /// else.
    ///
    /// Deliberately narrow. Any other subdomain a brand runs — `usa.`, `eu.`, `shop.` —
    /// is a *choice*, usually a region with its own currency and its own catalogue, and
    /// quietly swapping someone onto a different one would change every price in their
    /// feed. `www.` is the one prefix that is conventionally the same store. This also
    /// avoids needing a public-suffix list, which guessing the registrable domain of
    /// "brand.co.uk" would otherwise require.
    static func wwwVariant(of base: URL) -> URL? {
        guard let host = base.host() else { return nil }
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        if host.hasPrefix("www.") {
            components?.host = String(host.dropFirst(4))
        } else if host.split(separator: ".").count == 2 {
            components?.host = "www." + host
        } else {
            return nil
        }
        return components?.url
    }

    public static func catalogURL(for base: URL, page: Int) -> URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.path = "/products.json"
        components?.queryItems = [
            URLQueryItem(name: "limit", value: String(pageSize)),
            URLQueryItem(name: "page", value: String(page))
        ]
        return components?.url ?? base
    }

    // MARK: - Shop metadata

    public struct ShopInfo: Sendable {
        public var name: String?
        public var currency: String?
    }

    /// `/meta.json` gives the storefront's real display name and currency — the
    /// alternative was assuming USD and guessing the name from the hostname
    /// ("bbcicecream.com" -> "Bbcicecream" rather than "Billionaire Boys Club").
    public static func shopInfo(for base: URL, http: any HTTPFetching = Net.live) async -> ShopInfo? {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.path = "/meta.json"
        components?.query = nil
        guard let url = components?.url,
              let response = try? await http.get(url), response.status == 200,
              let meta = try? JSONDecoder().decode(Meta.self, from: response.data)
        else { return nil }
        return ShopInfo(name: meta.name, currency: meta.currency)
    }

    // MARK: - One product, by its page

    /// Everything a storefront knows about a single product, from its own page URL.
    ///
    /// This is what turns a shared link into something the app can act on. Open Graph —
    /// all `SharedSaveImporter` had — gives a title, a photograph and a price, and that is
    /// a bookmark. It cannot say what sizes exist, which of them are gone, or what
    /// colourways there are, so "tell me when it's back in a medium" was unanswerable for
    /// anything shared in from outside.
    ///
    /// Uses `/products/<handle>.js` rather than the `.json` beside it, and the difference
    /// is the entire point: **`.json` omits `available`**. It is otherwise the nicer
    /// payload — identical in shape to `products.json`, so it would need no new decoding —
    /// but a variant list with no stock in it answers none of the questions being asked
    /// here. The cost is that `.js` quotes prices in minor units, which is why they are
    /// divided rather than parsed.
    ///
    /// Returns nil for anything that isn't a Shopify product page, which the caller treats
    /// as "fall back to Open Graph" rather than as a failure.
    ///
    /// Two routes to the same answer, because **not every Shopify storefront serves
    /// `.js`**. Palace 404s it on all three of its hosts while answering `.json` and
    /// `/products.json` perfectly well, so the single-product endpoint alone meant every
    /// Palace share fell through to Open Graph — no size run, no colourways, and no stock,
    /// which is why a sold-out Palace product never produced an offer to watch it. The
    /// storefront's own page cannot stand in either: it advertises schema.org `inStock` for
    /// products whose every variant reads `available: false`.
    public static func product(
        at page: URL,
        currency: String? = nil,
        http: any HTTPFetching = Net.live
    ) async -> FetchedItem? {
        guard let handle = productHandle(in: page) else { return nil }

        // Only asked for when we don't already know it, and only once the storefront has
        // confirmed this is a Shopify store at all — so a shared link to anything else
        // costs exactly one request.
        //
        // Asked of *the host that answered*, which is not always the host that was shared.
        // Palace's apex and its `www.` are two regional stores — USD and GBP — so pricing
        // a product read out of one against the currency of the other prints a British
        // price with a dollar sign on it. The link stays the one that was shared, because
        // that is the page the person was looking at.
        func currencyCode(from origin: URL) async -> String {
            if let currency { return currency }
            return await shopInfo(for: origin, http: http)?.currency ?? "USD"
        }

        if let live = await liveProduct(handle: handle, at: page, http: http) {
            return await live.asItem(storeURL: page, currency: currencyCode(from: page))
        }
        if let listed = await listedProduct(handle: handle, at: page, http: http) {
            return await item(
                from: listed.product,
                storeURL: page,
                currency: currencyCode(from: listed.origin)
            )
        }
        return nil
    }

    /// `/products/<handle>.js` — the good one, when the storefront serves it.
    private static func liveProduct(
        handle: String,
        at page: URL,
        http: any HTTPFetching
    ) async -> LiveProduct? {
        var components = URLComponents(url: page, resolvingAgainstBaseURL: false)
        components?.path = "/products/\(handle).js"
        components?.query = nil
        components?.fragment = nil

        guard let url = components?.url,
              let response = try? await http.get(url), response.status == 200
        else { return nil }
        return try? JSONDecoder().decode(LiveProduct.self, from: response.data)
    }

    /// The same product found in the catalogue listing instead.
    ///
    /// Deliberately **not** `/products/<handle>.json`, which is the obvious sibling and is
    /// served where `.js` is not — because it omits `available` exactly as the list
    /// endpoint's absence of it is documented elsewhere, and stock is the entire question
    /// being asked. `/products.json` carries `available` per variant and is the same
    /// `Product` shape the poller already decodes, so the answer arrives complete.
    ///
    /// The cost is paging until the handle turns up. Bounded hard: the listing is newest
    /// first and a shared link is overwhelmingly something current, so a few pages either
    /// find it or it isn't worth more requests to a storefront on someone's behalf.
    /// Returns the product and the host it was actually found on, because the two can
    /// differ and the currency has to follow the second.
    private static func listedProduct(
        handle: String,
        at page: URL,
        http: any HTTPFetching
    ) async -> (product: Product, origin: URL)? {
        // The catalog may not answer on the host that was shared — Palace's apex 404s
        // `/products.json` while `www.` serves it — and this is the same `www.`-only swap
        // `resolve` makes, for the same reason.
        for host in [page, wwwVariant(of: page)].compactMap({ $0 }) {
            for index in 1...maxListedPages {
                guard let response = try? await http.get(catalogURL(for: host, page: index)),
                      response.status == 200,
                      let catalog = try? JSONDecoder().decode(Catalog.self, from: response.data),
                      !catalog.products.isEmpty
                else { break }

                if let match = catalog.products.first(where: { $0.handle == handle }) {
                    return (match, host)
                }
                if catalog.products.count < pageSize { break }
            }
        }
        return nil
    }

    /// Far short of `maxPages`: this runs while somebody waits for a share to land, and a
    /// product old enough to be past a thousand listings is not what was just shared.
    static let maxListedPages = 4

    /// The handle out of `https://kith.com/products/foo?variant=1` — nil when the path
    /// isn't a product page at all.
    public static func productHandle(in url: URL) -> String? {
        let parts = url.pathComponents.filter { $0 != "/" }
        guard let index = parts.firstIndex(where: { $0.lowercased() == "products" }),
              parts.count > index + 1
        else { return nil }
        let handle = parts[index + 1]
        return handle.isEmpty ? nil : handle
    }

    private static func item(from product: Product, storeURL: URL, currency: String) -> FetchedItem {
        let sizeAxis = product.axis(named: ["size", "shoe size", "sizes"])
        let colorAxis = product.axis(named: ["color", "colour", "colorway"])
        let imageForVariant = imageIndices(in: product.images ?? [])

        let variants = (product.variants ?? []).map { variant in
            VariantInfo(
                id: String(variant.id ?? 0),
                title: variant.title ?? "",
                available: variant.available ?? false,
                price: variant.price.map { formatPrice($0, currency: currency) },
                size: sizeAxis.flatMap(variant.option(at:)),
                color: colorAxis.flatMap(variant.option(at:)),
                imageIndex: variant.id.flatMap { imageForVariant[$0] }
            )
        }

        var link = URLComponents(url: storeURL, resolvingAgainstBaseURL: false)
        link?.path = "/products/\(product.handle)"
        link?.query = nil

        return FetchedItem(
            externalID: "shopify:\(product.id)",
            title: product.title,
            summary: product.bodyHTML.map(Self.plainText(from:)),
            linkURL: link?.url,
            imageURLStrings: product.images?.compactMap { $0.src } ?? [],
            publishedAt: product.publishedAt ?? product.createdAt ?? Date(),
            // Carried so `Reshelving` can tell a launch from a re-merchandising sweep —
            // this is the only source that publishes it, and the whole rule turns on it.
            createdAt: product.createdAt,
            kind: .product,
            priceText: variants.compactMap(\.price).first,
            // The lowest variant price, not the first: a product whose S is on sale and
            // whose XL is not should read as the sale price, which is what a shopper
            // sees on the storefront too.
            priceAmount: (product.variants ?? []).compactMap { $0.price.flatMap(Double.init) }.min(),
            isAvailable: variants.contains { $0.available },
            tags: product.tags ?? [],
            productType: product.productType,
            variants: variants
        )
    }

    /// Variant id → the position of the photograph that shows it.
    ///
    /// Built from the images array rather than from each variant's `featured_image`,
    /// because the index has to be a position in *the array the app will draw* — a
    /// featured image carries its own id and position and there is no guarantee the two
    /// agree once anything is filtered. First photograph wins where several list the same
    /// variant: that is the one the storefront leads with.
    private static func imageIndices(in images: [ProductImage]) -> [Int: Int] {
        var indices: [Int: Int] = [:]
        for (position, image) in images.enumerated() {
            for variantID in image.variantIDs ?? [] where indices[variantID] == nil {
                indices[variantID] = position
            }
        }
        return indices
    }

    public nonisolated static func formatPrice(_ raw: String, currency: String) -> String {
        guard let value = Double(raw) else { return raw }
        return value.formatted(.currency(code: currency).precision(.fractionLength(0)))
    }

    /// Shopify descriptions are HTML. Strip tags for a one-line summary.
    ///
    /// **A list item is not a sentence boundary — it is a stronger one.** Most storefronts
    /// write their spec as `<ul><li>`, and deleting the tags without putting anything in
    /// their place glues the whole thing into one 60-word sentence: "Ava Rover silhouette
    /// Textile upper Padded collar Perforated toecap and tongue Reinforced eyelets…". That
    /// is the largest block of text on the product page and it read as corrupt. `</li>`
    /// becomes a middot, which is the same separator the rest of the app uses for a run of
    /// short facts, and which survives being shown on one line.
    ///
    /// `<br>` and the block tags stay spaces: they are used inside prose as often as
    /// between items, and a middot in the middle of a sentence is worse than a run-on.
    ///
    /// `&amp;` is decoded **last**, or `&amp;lt;` would arrive as `<` and a description
    /// could inject markup into anything that later treats this as rich text.
    public nonisolated static func plainText(from html: String) -> String {
        html
            .replacingOccurrences(of: "</li>", with: " · ", options: .caseInsensitive)
            .replacingOccurrences(of: "<br\\s*/?>", with: " ", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(
                of: "</(p|div|h[1-6]|tr|blockquote)>",
                with: " ",
                options: [.regularExpression, .caseInsensitive]
            )
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&rsquo;", with: "’")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            // An empty `<li>`, or the last one in the list, leaves a separator with
            // nothing after it.
            .replacingOccurrences(of: "(\\s*·\\s*)+", with: " · ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " ·\n\t"))
    }
}

// MARK: - Wire format

private extension ShopifySource {
    struct Meta: Decodable {
        var name: String?
        var currency: String?
    }

    /// `/products/<handle>.js`. A different payload from `products.json` and given its own
    /// type rather than bent into `Product`: prices are integers in minor units, images
    /// are bare strings, and `available` exists — three incompatibilities that a shared
    /// decoder would have to paper over with optionals on both sides.
    struct LiveProduct: Decodable {
        var id: Int
        var title: String
        var handle: String
        var description: String?
        var published_at: Date?
        var type: String?
        var tags: [String]?
        var images: [String]?
        var options: [Option]?
        var variants: [LiveVariant]?

        struct Option: Decodable {
            var name: String
            var position: Int
        }

        struct LiveVariant: Decodable {
            var id: Int
            var title: String?
            var available: Bool?
            /// Minor units — 5500 is 55.00.
            var price: Int?
            var option1: String?
            var option2: String?
            var option3: String?
            /// `/products/<handle>.js` gives each variant its photograph inline, with a
            /// 1-based `position` into the same `images` array this decodes. The list
            /// endpoint expresses the identical fact the other way round — `variant_ids`
            /// on each image — so the two paths need different arithmetic for one answer.
            var featured_image: FeaturedImage?

            struct FeaturedImage: Decodable {
                var position: Int?
            }

            /// Zero-based, because `images` is an array and `position` is not.
            var imageIndex: Int? {
                guard let position = featured_image?.position, position > 0 else { return nil }
                return position - 1
            }

            func option(at position: Int) -> String? {
                switch position {
                case 1: option1
                case 2: option2
                case 3: option3
                default: nil
                }
            }
        }

        func axis(named candidates: [String]) -> Int? {
            options?.first { candidates.contains($0.name.lowercased()) }?.position
        }

        func asItem(storeURL: URL, currency: String) -> FetchedItem {
            let sizeAxis = axis(named: ["size", "shoe size", "sizes"])
            let colorAxis = axis(named: ["color", "colour", "colorway"])

            let mapped = (variants ?? []).map { variant in
                VariantInfo(
                    id: String(variant.id),
                    title: variant.title ?? "",
                    available: variant.available ?? false,
                    price: variant.price.map { formatPrice(String(Double($0) / 100), currency: currency) },
                    size: sizeAxis.flatMap(variant.option(at:)),
                    color: colorAxis.flatMap(variant.option(at:)),
                    imageIndex: variant.imageIndex
                )
            }

            var link = URLComponents(url: storeURL, resolvingAgainstBaseURL: false)
            link?.path = "/products/\(handle)"
            link?.query = nil
            link?.fragment = nil

            return FetchedItem(
                // Keyed the same way the poller keys it, so a link shared for a brand the
                // app already follows lands on the row that already exists instead of
                // becoming a second card for the same product.
                externalID: "shopify:\(id)",
                title: title,
                summary: description.map(ShopifySource.plainText(from:)),
                linkURL: link?.url,
                // Protocol-relative — "//cdn.shopify.com/…" — is what this endpoint
                // returns, and it is not a URL an image loader can open.
                imageURLStrings: (images ?? []).map { $0.hasPrefix("//") ? "https:\($0)" : $0 },
                publishedAt: published_at ?? Date(),
                kind: .product,
                priceText: mapped.compactMap(\.price).first,
                priceAmount: (variants ?? []).compactMap(\.price).min().map { Double($0) / 100 },
                isAvailable: mapped.contains { $0.available },
                tags: tags ?? [],
                productType: type,
                variants: mapped
            )
        }
    }

    struct Catalog: Decodable {
        var products: [Product]
    }

    struct Product: Decodable {
        var id: Int
        var title: String
        var handle: String
        var bodyHTML: String?
        var publishedAt: Date?
        var createdAt: Date?
        var productType: String?
        var tags: [String]?
        var variants: [Variant]?
        var images: [ProductImage]?
        var options: [ProductOption]?

        /// Which option position (1-3) holds sizes. Products vary: Kith ships
        /// `[Size]`, BBC ships `[Color, Size]`, so position is not fixed.
        func axis(named candidates: [String]) -> Int? {
            options?.first { candidates.contains($0.name.lowercased()) }?.position
        }

        enum CodingKeys: String, CodingKey {
            case id, title, handle, tags, variants, images, options
            case bodyHTML = "body_html"
            case publishedAt = "published_at"
            case createdAt = "created_at"
            case productType = "product_type"
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(Int.self, forKey: .id)
            title = try c.decode(String.self, forKey: .title)
            handle = try c.decode(String.self, forKey: .handle)
            bodyHTML = try c.decodeIfPresent(String.self, forKey: .bodyHTML)
            productType = try c.decodeIfPresent(String.self, forKey: .productType)
            tags = try c.decodeIfPresent([String].self, forKey: .tags)
            variants = try c.decodeIfPresent([Variant].self, forKey: .variants)
            images = try c.decodeIfPresent([ProductImage].self, forKey: .images)
            options = try c.decodeIfPresent([ProductOption].self, forKey: .options)
            publishedAt = Self.date(in: c, at: .publishedAt)
            createdAt = Self.date(in: c, at: .createdAt)
        }

        /// Shopify emits ISO8601 with an offset, sometimes with fractional seconds.
        private static func date(in c: KeyedDecodingContainer<CodingKeys>, at key: CodingKeys) -> Date? {
            guard let raw = try? c.decodeIfPresent(String.self, forKey: key) else { return nil }
            return DateParsing.iso8601(raw)
        }
    }

    struct ProductOption: Decodable {
        var name: String
        var position: Int
    }

    struct Variant: Decodable {
        var id: Int?
        var title: String?
        var available: Bool?
        var price: String?
        var option1: String?
        var option2: String?
        var option3: String?

        func option(at position: Int) -> String? {
            switch position {
            case 1: option1
            case 2: option2
            case 3: option3
            default: nil
            }
        }
    }

    struct ProductImage: Decodable {
        var src: String?
        /// Which variants this photograph is *of*. Shopify has always published it; the
        /// adapter used to decode only `src` and throw the association away.
        var variantIDs: [Int]?

        enum CodingKeys: String, CodingKey {
            case src
            case variantIDs = "variant_ids"
        }
    }
}

/// Date formatters are reference types with mutable internal state and are *not*
/// thread-safe, so sharing them across the sync engine's concurrent task group was a
/// real (if rarely-observed) data race — Swift 6 language mode is what surfaced it.
/// Serialising access keeps the parsing behaviour identical, which matters because it's
/// been validated against live Shopify and Atom payloads.
private final class DateFormatters: @unchecked Sendable {
    private let lock = NSLock()

    private let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// RFC822, as used by RSS `<pubDate>`.
    private let rfc822: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f
    }()

    func iso8601(_ raw: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return withFraction.date(from: raw) ?? plain.date(from: raw)
    }

    func rfc822(_ raw: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return rfc822.date(from: raw)
    }
}

public enum DateParsing {
    private static let formatters = DateFormatters()

    public static func iso8601(_ raw: String) -> Date? {
        formatters.iso8601(raw)
    }

    public static func any(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return iso8601(trimmed) ?? formatters.rfc822(trimmed)
    }
}
