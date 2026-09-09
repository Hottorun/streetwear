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
        try response.requireOK()
        guard let payload = try? JSONDecoder().decode(Payload.self, from: response.data) else {
            throw SourceError.emptyPayload
        }

        let store = source.url
        let candidates: [(handle: String, item: FetchedItem)] = payload.collections
            .compactMap { collection in
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

                return (
                    collection.handle,
                    FetchedItem(
                        externalID: "collection:\(collection.id)",
                        title: collection.title,
                        summary: collection.description.map(ShopifySource.plainText(from:)),
                        linkURL: link?.url,
                        imageURLStrings: [collection.image?.src].compactMap { $0 },
                        publishedAt: published,
                        kind: .collection
                    )
                )
            }

        // **A baseline poll announces nothing, so nothing needs verifying.** `since == nil`
        // is a brand's first sync, where the whole catalogue is stored pre-marked seen; the
        // membership below is a request per collection, and on a storefront like Amiri's —
        // 250 of them — spending 250 requests to qualify events no one will ever be shown
        // is the most expensive way in this file to achieve nothing.
        guard since != nil else {
            return FetchResult(items: candidates.map(\.item), etag: response.etag)
        }

        var items: [FetchedItem] = []
        var budget = Self.membershipBudget
        for candidate in candidates.sorted(by: { $0.item.publishedAt > $1.item.publishedAt }) {
            // **Past the budget a poll stops looking and stops announcing.** More than a
            // handful of collections published between two polls is a theme touching them
            // all — a merchandiser does not launch seven seasons in an hour — and the old
            // behaviour of announcing whatever was left unverified is exactly the failure
            // this is here to end. Dropping one real release to a re-stamp is a card nobody
            // sees; keeping the re-stamp is a screenful of furniture presented as news.
            guard budget > 0 else { break }
            budget -= 1

            guard let membership = try? await Self.membership(
                of: candidate.handle,
                in: store,
                http: http
            ) else {
                // The storefront did not answer. Announce it as before rather than losing a
                // real drop to one failed request — an unverified card is the *old*
                // behaviour, and it degrades to the client's word match, which is what rows
                // written before this shipped fall back to anyway.
                items.append(candidate.item)
                continue
            }
            guard Release.isAnnouncement(
                publishedAt: candidate.item.publishedAt,
                members: membership.publishedAt
            ) else { continue }

            var item = candidate.item
            item.memberExternalIDs = membership.externalIDs
            items.append(item)
        }

        return FetchResult(items: Self.withoutSubsets(items), etag: response.etag)
    }

    /// Drops a collection whose contents sit wholly inside another the same poll is
    /// announcing.
    ///
    /// One launch is routinely merchandised as several overlapping rails. Amiri's bags
    /// arrived as BISCOTTO BAG (8 pieces), BABY BISCOTTO BAG (4) and BISCOTTO SHOULDER BAG
    /// (4), where both fours are subsets of the eight — three announcements, one release,
    /// and the reader has to open all three to find that out. Each passes the freshness
    /// test on its own merits, correctly: they are new stock. They are just not three
    /// pieces of news.
    ///
    /// Subset rather than similar names, because the names are exactly what cannot be
    /// trusted here and the membership is now a fact. A tie between two identical sets goes
    /// to the earlier item, which is the newer one — the loop above sorts newest first.
    static func withoutSubsets(_ items: [FetchedItem]) -> [FetchedItem] {
        let sets = items.map { Set($0.memberExternalIDs) }
        return items.enumerated().filter { index, _ in
            let mine = sets[index]
            // Nothing known about the contents is not evidence of containment.
            guard !mine.isEmpty else { return true }
            return !sets.enumerated().contains { other, theirs in
                other != index
                    && mine.isSubset(of: theirs)
                    && (theirs.count > mine.count || other < index)
            }
        }
        .map(\.element)
    }

    /// How many freshly published collections one poll will look inside.
    ///
    /// The realistic number is nought or one. The cap is there for the storefront that
    /// re-stamps `published_at` across its whole collection list when a theme is deployed,
    /// which is a single request answering for hundreds of rows — see the loop above for
    /// why the remainder is dropped rather than trusted.
    static let membershipBudget = 6

    /// What the storefront says is actually **in** a collection.
    ///
    /// `/collections.json` names a release and does not list it, and for a long time the two
    /// were joined by guessing: a distinctive word from the title, falling back to whatever
    /// published within a day and a half. Shopify has always served the answer one path
    /// along, and the guess was wrong on every brand it was checked against — Corteiz's
    /// ISLAND PUFF PRINT TRUCKER HAT page listed five board shorts and a bag, where the
    /// collection holds six colourways of the hat.
    ///
    /// Ids are formatted exactly as `ShopifySource` writes them, because that is what the
    /// stored garment is keyed on and a member list that cannot be joined to anything is
    /// worse than none — it would read as a release whose every piece is missing.
    public static func membership(
        of handle: String,
        in store: URL,
        http: any HTTPFetching = Net.live
    ) async throws -> (externalIDs: [String], publishedAt: [Date]) {
        var components = URLComponents(url: store, resolvingAgainstBaseURL: false)
        components?.path = "/collections/\(handle)/products.json"
        components?.queryItems = [URLQueryItem(name: "limit", value: "250")]
        guard let url = components?.url else { throw SourceError.notThisKind }

        let response = try await http.get(url)
        try response.requireOK()
        guard let payload = try? JSONDecoder().decode(Membership.self, from: response.data) else {
            throw SourceError.emptyPayload
        }

        return (
            payload.products.map { "shopify:\($0.id)" },
            payload.products.compactMap { $0.publishedAt.flatMap(DateParsing.iso8601) }
        )
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

    /// Only the two fields the membership question needs. `/collections/<handle>/products.json`
    /// returns the full product objects — images, variants, body copy — and decoding all of
    /// that to count publication dates would be the expensive half of a cheap request.
    private struct Membership: Decodable {
        var products: [Member]

        struct Member: Decodable {
            var id: Int
            var publishedAt: String?

            enum CodingKeys: String, CodingKey {
                case id
                case publishedAt = "published_at"
            }
        }
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
