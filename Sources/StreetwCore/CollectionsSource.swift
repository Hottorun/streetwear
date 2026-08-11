// CollectionsSource.swift
// Shopify's other public endpoint: `/collections.json`.
//
// `products.json` tells you a hoodie appeared. It cannot tell you that *a collection
// dropped* — which is the thing brands actually announce, plan around and sell out. A
// 60-piece release arrives through the product endpoint as 60 unrelated rows; through
// this one it is a single named event, which is both what the user wants to hear and far
// less to say.
//
// A separate source rather than a second request inside `ShopifySource`, because that is
// what the architecture already assumes everywhere else: one source is one URL with its
// own ETag, its own failure count and its own place in the poll queue. Folding it in
// would double every catalogue poll's request count and give the two endpoints a shared
// ETag that fits neither.

import Foundation

public struct CollectionsSource: SourceAdapter {
    public let kind: BrandSource.Kind = .collections

    private let http: any HTTPFetching

    public init(http: any HTTPFetching = Net.live) {
        self.http = http
    }

    public func fetch(_ source: BrandSource, since: Date?) async throws -> FetchResult {
        let response = try await http.get(source.url, etag: source.etag)

        if response.status == 304 {
            return FetchResult(items: [], etag: source.etag, notModified: true)
        }
        if response.isLocked {
            return FetchResult(items: [], isLocked: true, etag: source.etag)
        }
        guard response.status == 200 else {
            throw SourceError.badResponse(response.status)
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: response.data) else {
            throw SourceError.emptyPayload
        }

        let store = source.url
        let items = payload.collections.compactMap { collection -> FetchedItem? in
            guard let published = collection.publishedAt.flatMap(DateParsing.iso8601) else { return nil }
            // Every storefront has an always-present "all"/"frontpage" collection that
            // is a navigation aid, not a release. Announcing those would be wrong on the
            // very first poll and wrong again whenever a theme touches them.
            guard !Self.isStructural(collection.handle) else { return nil }
            // An empty collection is a page a merchandiser has created but not filled —
            // it appears days before the release and is not itself the release.
            if let count = collection.productsCount, count == 0 { return nil }
            if let since, published <= since { return nil }

            var link = URLComponents(url: store, resolvingAgainstBaseURL: false)
            link?.path = "/collections/\(collection.handle)"
            link?.query = nil

            return FetchedItem(
                externalID: "collection:\(collection.id)",
                title: collection.title,
                summary: collection.description.map(ShopifySource.plainText(from:)),
                linkURL: link?.url,
                imageURLStrings: [collection.image?.src].compactMap { $0 },
                publishedAt: published,
                kind: .collection
            )
        }

        return FetchResult(items: items, etag: response.etag)
    }

    /// Handles that exist on essentially every Shopify store for navigation.
    static func isStructural(_ handle: String) -> Bool {
        let structural: Set<String> = [
            "all", "frontpage", "home", "shop-all", "new", "new-arrivals",
            "sale", "featured", "best-sellers", "gift-cards"
        ]
        return structural.contains(handle.lowercased())
    }

    public static func detect(at base: URL, http: any HTTPFetching = Net.live) async -> URL? {
        let url = collectionsURL(for: base)
        guard let response = try? await http.get(url), response.status == 200 else { return nil }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: response.data) else { return nil }
        // A store with nothing but its structural collections has no release programme
        // worth watching, and adding the source would only cost requests.
        return payload.collections.contains { !isStructural($0.handle) } ? url : nil
    }

    public static func collectionsURL(for base: URL) -> URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.path = "/collections.json"
        components?.queryItems = [URLQueryItem(name: "limit", value: "250")]
        return components?.url ?? base
    }

    // MARK: - Wire format

    private struct Payload: Decodable {
        var collections: [Collection]
    }

    private struct Collection: Decodable {
        var id: Int
        var handle: String
        var title: String
        /// `/collections.json` calls this `description`, unlike `/products.json` which
        /// calls the equivalent field `body_html`. Verified against a live storefront —
        /// decoding the wrong key silently loses every summary rather than failing.
        var description: String?
        var publishedAt: String?
        var image: Image?
        var productsCount: Int?

        enum CodingKeys: String, CodingKey {
            case id, handle, title, image, description
            case publishedAt = "published_at"
            case productsCount = "products_count"
        }
    }

    private struct Image: Decodable {
        var src: String?
    }
}
