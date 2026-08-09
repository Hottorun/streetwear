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
        guard first.status == 200 else { throw SourceError.badResponse(first.status) }

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
        guard let response = try? await http.get(catalogURL(for: base, page: 1)), response.status == 200 else {
            return false
        }
        guard let catalog = try? JSONDecoder().decode(Catalog.self, from: response.data) else { return false }
        return !catalog.products.isEmpty
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

    private static func item(from product: Product, storeURL: URL, currency: String) -> FetchedItem {
        let sizeAxis = product.axis(named: ["size", "shoe size", "sizes"])
        let colorAxis = product.axis(named: ["color", "colour", "colorway"])

        let variants = (product.variants ?? []).map { variant in
            VariantInfo(
                id: String(variant.id ?? 0),
                title: variant.title ?? "",
                available: variant.available ?? false,
                price: variant.price.map { formatPrice($0, currency: currency) },
                size: sizeAxis.flatMap(variant.option(at:)),
                color: colorAxis.flatMap(variant.option(at:))
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
            kind: .product,
            priceText: variants.compactMap(\.price).first,
            isAvailable: variants.contains { $0.available },
            tags: product.tags ?? [],
            productType: product.productType,
            variants: variants
        )
    }

    public nonisolated static func formatPrice(_ raw: String, currency: String) -> String {
        guard let value = Double(raw) else { return raw }
        return value.formatted(.currency(code: currency).precision(.fractionLength(0)))
    }

    /// Shopify descriptions are HTML. Strip tags for a one-line summary.
    public nonisolated static func plainText(from html: String) -> String {
        html
            .replacingOccurrences(of: "<br>", with: " ")
            .replacingOccurrences(of: "</p>", with: " ")
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Wire format

private extension ShopifySource {
    struct Meta: Decodable {
        var name: String?
        var currency: String?
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
