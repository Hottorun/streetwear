// UCPSource.swift
// The catalogue, for storefronts that have switched their catalogue off.
//
// **The problem this exists for, measured rather than assumed.** Supreme is a Shopify store
// — `us.supreme.com` resolves to `eu-production.myshopify.com` — and the merchant has turned
// off every machine-readable surface Shopify normally exposes. Probed directly:
//
// ```
//   /products.json                 403 Access denied
//   /collections.json              403 Access denied
//   /collections/all.atom          403 Access denied
//   /products/<handle>.js|.json    403 Access denied
//   /sitemap.xml                   404
//   /meta.json                     200   ← the only one that answers
//   /collections/all               200   ← HTML, and client-rendered: no product links in it
// ```
//
// So `ShopifySource`, `CollectionsSource`, `FeedSource` and `SitemapSource` all decline, and
// discovery falls through to `PageWatchSource` — which hashes the visible text of a page
// whose products are drawn by JavaScript. The hash never moves. The brand row says
// "WATCHING", the source reports no error, and the app delivers nothing, ever. That is the
// exact failure mode this codebase keeps a list of: every layer reporting healthy while the
// feature does not exist.
//
// **What answers instead.** The same robots.txt that fronts those 403s says:
//
// ```
//   # Shopify storefront. Public product, collection, page, blog, policy, cart, and
//   # localized HTML is crawlable.
//   # UCP discovery: https://eu.supreme.com/.well-known/ucp
//   # UCP/MCP endpoint: https://eu.supreme.com/api/ucp/mcp
//   # Agents should use UCP/MCP for catalog, cart, and checkout.
// ```
//
// The merchant has not closed the door; it has moved it and put up a sign. The Universal
// Commerce Protocol is the sanctioned route, `search_catalog` is its read operation, and
// `get_product` promises "exact pricing, and real-time availability" — which is more than a
// sitemap gives and roughly what `/products.json` gives. Using the interface a site
// advertises for machines is the same bargain the rest of this package already makes with
// Open Graph and `/products.json`, and it is the opposite of working around a block: the
// 403s are a *redirection*, and `Net.userAgent` stays honest either way.
//
// Three things about the implementation are load-bearing:
//
// - **Discovery every poll, not a stored endpoint.** `/.well-known/ucp` is the documented
//   way to find the endpoint and it is a small cacheable document; pinning the endpoint we
//   saw on the day a brand was added means silently polling a dead URL the day it moves.
// - **`search_catalog` is a search, not an enumeration.** There is no "sort by newest" and
//   no publication date anywhere in the UCP product model, so this pages through a bounded
//   window and lets the merge decide what is new — dedupe is on `externalID`, which is what
//   makes that safe. It is also why `since` cannot narrow the request.
// - **Prices arrive in minor units.** `{"amount": 29900, "currency": "USD"}` is $299.00.
//   Reading that as an amount would put a £14,800 hoodie in the feed.
//
// Read-only by construction: this calls `search_catalog` and nothing else. The same endpoint
// exposes `create_cart`, `create_checkout` and `complete_checkout`, and none of them appear
// in this file or in the capabilities `UCPAgent` declares.

import Foundation

public struct UCPSource: SourceAdapter {
    public let kind: BrandSource.Kind = .ucp
    private let http: any HTTPFetching

    public init(http: any HTTPFetching = Net.live) {
        self.http = http
    }

    /// How many pages of the catalogue one poll walks.
    ///
    /// The protocol offers no ordering, so this is a *sample* rather than a sweep and there
    /// is no page at which we know we have seen everything new. Five pages of fifty is 250
    /// products, which is the whole of a Supreme season several times over and comparable to
    /// what `ShopifySource` reads in its first sweep. A brand with a genuinely enormous
    /// catalogue is better served by `/products.json`, which it will have left switched on.
    static let maxPages = 5
    static let pageSize = 50

    /// Where a business publishes what it can do. Fixed by the spec, and read every poll
    /// rather than resolved once — see the note at the top.
    public static let discoveryPath = "/.well-known/ucp"

    public func fetch(_ source: BrandSource, since: Date?) async throws -> FetchResult {
        let origin = source.url
        guard let discovery = try await discover(at: origin) else {
            // Not a UCP storefront, or no longer one. `notThisKind` rather than a bad
            // response: nothing failed, this simply is not the right adapter any more, and
            // the brand page should say so rather than counting failures against a site
            // that answered perfectly well.
            throw SourceError.notThisKind
        }

        var products: [UCPProduct] = []
        var cursor: String?
        var seenCursors: Set<String> = []

        for _ in 0..<Self.maxPages {
            let page = try await search(endpoint: discovery.endpoint, cursor: cursor)
            products.append(contentsOf: page.products ?? [])

            guard let next = page.pagination?.cursor, !next.isEmpty else { break }
            // A merchant that returns the cursor it was handed would otherwise page for
            // ever inside the loop bound, re-reading one page five times.
            guard seenCursors.insert(next).inserted else { break }
            cursor = next
        }

        guard !products.isEmpty else {
            // An empty catalogue is a real answer — Supreme's is empty between seasons —
            // and must not read as a failure, or the source backs off out of the window it
            // most needs to be polling in.
            return FetchResult(items: [])
        }

        let now = Date()
        return FetchResult(
            items: products.compactMap { Self.item(from: $0, origin: origin, seenAt: now) }
        )
    }

    // MARK: - Discovery

    struct Discovery: Sendable, Hashable {
        var endpoint: URL
    }

    /// Reads `/.well-known/ucp` and picks the MCP shopping endpoint, if the business
    /// advertises one *and* says it can answer a catalogue search.
    ///
    /// Both halves are checked. A storefront that publishes a profile for checkout alone
    /// would otherwise be attached as a catalogue source and then return nothing on every
    /// poll — a source that reports healthy and produces no drops, which is the failure this
    /// whole adapter exists to remove rather than to reproduce.
    static func endpoint(inProfile data: Data) -> Discovery? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let ucp = root["ucp"] as? [String: Any]
        else { return nil }

        let capabilities = ucp["capabilities"] as? [String: Any] ?? [:]
        guard capabilities[catalogSearchCapability] != nil else { return nil }

        let services = ucp["services"] as? [String: Any] ?? [:]
        guard let shopping = services["dev.ucp.shopping"] as? [[String: Any]] else { return nil }

        for binding in shopping {
            guard binding["transport"] as? String == "mcp",
                  let raw = binding["endpoint"] as? String,
                  let url = URL(string: raw),
                  url.scheme == "https"
            else { continue }
            return Discovery(endpoint: url)
        }
        return nil
    }

    static let catalogSearchCapability = "dev.ucp.shopping.catalog.search"

    private func discover(at origin: URL) async throws -> Discovery? {
        guard var components = URLComponents(url: origin, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.path = Self.discoveryPath
        components.query = nil
        guard let url = components.url else { return nil }

        let response = try await http.get(url)
        guard response.status == 200 else {
            // A challenge here is worth surfacing as itself: the endpoint is fine and an
            // edge is in the way, which is a different fix from a store that never had one.
            if response.isChallenged { throw SourceError.blockedByEdge }
            return nil
        }
        return Self.endpoint(inProfile: response.data)
    }

    /// Whether a storefront can be watched this way. Used by discovery, which needs the
    /// answer before a `BrandSource` exists to fetch with.
    public static func detect(at base: URL, http: any HTTPFetching = Net.live) async -> URL? {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.path = discoveryPath
        components.query = nil
        guard let url = components.url,
              let response = try? await http.get(url),
              response.status == 200,
              endpoint(inProfile: response.data) != nil
        else { return nil }
        // The **storefront origin** is what gets stored, not the MCP endpoint: the endpoint
        // is discovered fresh each poll, and the origin is the thing a person recognises on
        // the brand page.
        return base
    }

    // MARK: - The call

    private func search(endpoint: URL, cursor: String?) async throws -> UCPCatalogResponse {
        var pagination: [String: Any] = ["limit": Self.pageSize]
        if let cursor { pagination["cursor"] = cursor }

        // `search_catalog` requires at least one of query or filters, and there is no
        // "everything" query — so the filter *is* the query. `available: false` turns off
        // the default narrowing to sale-ready items, which matters more here than anywhere
        // else in the app: a sold-out drop is precisely what somebody wants to be told
        // about, and the restock that follows is the thing this app exists to catch.
        let arguments: [String: Any] = [
            "meta": UCPAgent.meta(),
            "catalog": [
                "filters": ["available": false],
                "pagination": pagination
            ]
        ]
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": ["name": "search_catalog", "arguments": arguments]
        ]

        // Slashes unescaped: `https:\/\/…` is valid JSON and perfectly readable to a
        // parser, but the one field a merchant will quote back at us in an error is the
        // profile URI, and it should be legible in their logs and ours.
        let payload = try JSONSerialization.data(withJSONObject: body, options: [.withoutEscapingSlashes])
        // Both content types offered, because an MCP server picks its transport off this
        // header and the ones defaulting to an event stream are unreadable here.
        let response = try await http.post(endpoint, json: payload, accept: "application/json, text/event-stream")

        // **The status is not the message.** A UCP refusal arrives as 422 with the reason
        // in a JSON-RPC error body — "Unable to fetch agent profile: Missing ucp version",
        // which names the fix — and calling `requireOK()` first threw all of that away and
        // reported "Server returned 422". Verified against Supreme: the useful sentence is
        // in the body of the very response the status was hiding. So the body is read
        // first, and the status only speaks when there is nothing in it that can.
        if response.isChallenged { throw SourceError.blockedByEdge }
        do {
            return try Self.decode(response.data)
        } catch SourceError.emptyPayload {
            // Nothing readable in the body, so now the status is all there is — and a
            // non-200 with an unreadable body is a plain transport failure.
            throw response.status == 200
                ? SourceError.emptyPayload
                : SourceError.badResponse(response.status)
        }
    }

    /// JSON-RPC out, UCP in.
    ///
    /// The payload is reachable two ways and both are in the wild: `structuredContent`
    /// holds it as an object, and `content[0].text` holds the same thing as a JSON string
    /// for clients that only render text. Preferring the structured form and falling back
    /// to parsing the text costs a few lines and removes an entire class of "works against
    /// one server, silent against the next".
    static func decode(_ data: Data) throws -> UCPCatalogResponse {
        // Every unreadable shape becomes `emptyPayload`, so the caller has one case to
        // catch when it wants to fall back to the status code.
        guard let envelope = try? JSONDecoder().decode(RPCEnvelope.self, from: data) else {
            throw SourceError.emptyPayload
        }
        if let error = envelope.error {
            throw SourceError.ucp(error.detail)
        }
        guard let result = envelope.result else { throw SourceError.emptyPayload }

        if let structured = result.structuredContent { return structured }
        guard let text = result.content?.first(where: { $0.text != nil })?.text,
              let nested = text.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(UCPCatalogResponse.self, from: nested)
        else { throw SourceError.emptyPayload }
        return parsed
    }

    // MARK: - Mapping

    /// One UCP product as the rest of the app understands products.
    ///
    /// `seenAt` rather than a publication date, and the protocol is why: UCP's product model
    /// has no `published_at` and no `created_at` — it describes what is *for sale*, not when
    /// it went up. So the honest stamp is when this row was first seen, and it is only ever
    /// applied to a product nothing has seen before: dedupe is on `externalID`, so the
    /// merge writes a row once and never restamps it. The consequence worth knowing is that
    /// `Reshelving` can say nothing here — with no creation date it answers `false`, which
    /// is its documented safe default, so a re-published old item reads as a drop. That is
    /// the wrong side to err on in general and the right side here: a storefront that
    /// publishes nothing about dates gives us no way to tell, and suppressing a real drop is
    /// the failure this app cannot afford.
    static func item(from product: UCPProduct, origin: URL, seenAt: Date) -> FetchedItem? {
        guard !product.id.isEmpty, !product.title.isEmpty else { return nil }

        let images = (product.media ?? [])
            .filter { ($0.type ?? "image") == "image" }
            .map(\.url)
        let variants = (product.variants ?? []).map { variant in
            VariantInfo(
                id: variant.id,
                title: variant.title ?? "",
                available: variant.availability?.available ?? true,
                price: variant.price.map { money($0) },
                size: option(named: sizeNames, in: variant.options),
                color: option(named: colorNames, in: variant.options),
                imageIndex: imageIndex(for: variant, in: images)
            )
        }

        let price = product.price_range?.min ?? product.variants?.first?.price

        return FetchedItem(
            externalID: "ucp:\(product.id)",
            title: product.title,
            summary: product.description?.plain,
            linkURL: link(for: product, origin: origin),
            imageURLStrings: images,
            publishedAt: seenAt,
            createdAt: nil,
            kind: .product,
            priceText: price.map { money($0) },
            priceAmount: price.map(major(of:)),
            isAvailable: variants.isEmpty ? nil : variants.contains(where: \.available),
            tags: product.tags ?? [],
            productType: product.categories?.first?.name,
            variants: variants
        )
    }

    /// Which photograph shows this variant, when the merchant said.
    ///
    /// An index into the product's own media array rather than a URL, exactly as
    /// `ShopifySource` does and for the same reason: the URLs are already on the wire once,
    /// and sending a second copy per variant would multiply a product's payload by its
    /// colourway count. Nil is normal and must leave the gallery alone.
    static func imageIndex(for variant: UCPVariant, in images: [String]) -> Int? {
        guard let featured = variant.media?.first?.url else { return nil }
        return images.firstIndex(of: featured)
    }

    private static let sizeNames: Set<String> = ["size", "sizes", "shoe size", "waist"]
    private static let colorNames: Set<String> = ["color", "colour", "colorway", "colourway"]

    static func option(named wanted: Set<String>, in options: [UCPSelectedOption]?) -> String? {
        guard let options else { return nil }
        for option in options where wanted.contains(option.name.lowercased()) {
            let label = option.label.trimmingCharacters(in: .whitespaces)
            if !label.isEmpty { return label }
        }
        return nil
    }

    /// The product page, which UCP gives outright when it can.
    ///
    /// Falls back to the handle against the storefront origin, because a card with no way
    /// through to the shop is the one thing worse than a card with no price. Nil only when
    /// there is neither, which no real storefront produces.
    static func link(for product: UCPProduct, origin: URL) -> URL? {
        if let raw = product.url, let url = URL(string: raw), url.scheme?.hasPrefix("http") == true {
            return url
        }
        guard let handle = product.handle, !handle.isEmpty else { return nil }
        return URL(string: "/products/\(handle)", relativeTo: origin)?.absoluteURL
    }

    // MARK: - Money

    /// **Minor units.** `{"amount": 29900, "currency": "USD"}` is $299.00, and reading the
    /// integer as an amount would put a £14,800 hoodie in a feed of streetwear.
    ///
    /// Zero-decimal currencies are already whole units and must not be divided — a ¥29,900
    /// jacket becoming ¥299 is the same bug in the other direction, and JPY is not exotic
    /// for the brands this app watches.
    static func major(of price: UCPPrice) -> Double {
        let divisor = zeroDecimal.contains(price.currency.uppercased()) ? 1.0 : 100.0
        return Double(price.amount) / divisor
    }

    static func money(_ price: UCPPrice) -> String {
        ShopifySource.formatPrice(String(major(of: price)), currency: price.currency)
    }

    /// The ISO 4217 currencies with no minor unit. Short and standard.
    static let zeroDecimal: Set<String> = [
        "BIF", "CLP", "DJF", "GNF", "ISK", "JPY", "KMF", "KRW",
        "PYG", "RWF", "UGX", "UYI", "VND", "VUV", "XAF", "XOF", "XPF"
    ]
}

// MARK: - Wire types

/// Decoded leniently throughout: this is somebody else's evolving spec, and a field added
/// to it must not take a brand's whole catalogue down. Everything optional except the two
/// things a product cannot be without.
struct RPCEnvelope: Decodable {
    struct Failure: Decodable {
        /// The part worth reading. `message` is the category ("UCP discovery failed");
        /// `data.content` is the sentence that names the fix ("Unable to fetch agent
        /// profile: Missing ucp version"). Reporting only the former is how a fault on our
        /// side reads as a fault on theirs.
        struct Detail: Decodable {
            var code: String?
            var content: String?
        }

        var code: Int?
        var message: String
        var data: Detail?

        var detail: String {
            guard let content = data?.content, !content.isEmpty else { return message }
            return "\(message) — \(content)"
        }
    }

    struct Result: Decodable {
        struct Content: Decodable {
            var type: String?
            var text: String?
        }

        var structuredContent: UCPCatalogResponse?
        var content: [Content]?
    }

    var result: Result?
    var error: Failure?
}

public struct UCPCatalogResponse: Decodable, Sendable {
    public struct Pagination: Decodable, Sendable {
        public var cursor: String?
    }

    public var products: [UCPProduct]?
    public var pagination: Pagination?
}

public struct UCPProduct: Decodable, Sendable {
    public struct Description: Decodable, Sendable {
        public var plain: String?
    }

    public struct Category: Decodable, Sendable {
        public var name: String?
    }

    public struct PriceRange: Decodable, Sendable {
        public var min: UCPPrice?
        public var max: UCPPrice?
    }

    public var id: String
    public var handle: String?
    public var title: String
    public var url: String?
    public var description: Description?
    public var categories: [Category]?
    public var price_range: PriceRange?
    public var media: [UCPMedia]?
    public var tags: [String]?
    public var variants: [UCPVariant]?
}

public struct UCPMedia: Decodable, Sendable {
    public var type: String?
    public var url: String
}

public struct UCPVariant: Decodable, Sendable {
    public struct Availability: Decodable, Sendable {
        public var available: Bool?
    }

    public var id: String
    public var title: String?
    public var price: UCPPrice?
    public var availability: Availability?
    public var options: [UCPSelectedOption]?
    public var media: [UCPMedia]?
}

public struct UCPSelectedOption: Decodable, Sendable {
    public var name: String
    public var label: String
}

public struct UCPPrice: Decodable, Sendable {
    public var amount: Int
    public var currency: String
}
