// BrandSource.swift
// A single place we watch for a brand: a Shopify catalog, a feed, a page, a profile.
import Foundation

public struct BrandSource: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case shopify
        case feed
        case page
        case instagram
        /// Shopify's `/collections.json` — releases as named events rather than as
        /// dozens of unrelated products.
        case collections
        /// `/sitemap.xml` — the fallback for brands that are neither Shopify nor
        /// publishing a feed. Strictly better than watching a page for any change.
        case sitemap

        public var label: String {
            switch self {
            case .shopify: "Catalog"
            case .feed: "Feed"
            case .page: "Page watch"
            case .instagram: "Instagram"
            case .collections: "Collections"
            case .sitemap: "Sitemap"
            }
        }

        public var symbol: String {
            switch self {
            case .shopify: "bag"
            case .feed: "dot.radiowaves.up.forward"
            case .page: "eye"
            case .instagram: "camera"
            case .collections: "square.grid.2x2"
            case .sitemap: "list.bullet.rectangle"
            }
        }

        /// Instagram is a link-out only. We never scrape it — see `SourceAdapter`.
        public var isAutomatic: Bool { self != .instagram }
    }

    public var id: UUID
    public var kind: Kind
    public var url: URL
    public var enabled: Bool

    /// Content hash of the last successful fetch, used by `.page` to detect changes.
    public var fingerprint: String?
    /// Last `ETag`, replayed as `If-None-Match` to turn unchanged polls into cheap 304s.
    public var etag: String?
    public var lastCheckedAt: Date?
    public var lastError: String?

    /// Consecutive failures. Drives exponential backoff so a dead source isn't
    /// hammered on every sync.
    public var failureCount: Int

    public init(
        id: UUID = UUID(),
        kind: Kind,
        url: URL,
        enabled: Bool = true,
        fingerprint: String? = nil,
        etag: String? = nil,
        lastCheckedAt: Date? = nil,
        lastError: String? = nil,
        failureCount: Int = 0
    ) {
        self.id = id
        self.kind = kind
        self.url = url
        self.enabled = enabled
        self.fingerprint = fingerprint
        self.etag = etag
        self.lastCheckedAt = lastCheckedAt
        self.lastError = lastError
        self.failureCount = failureCount
    }

    /// Decoded leniently: every field except `kind` and `url` falls back to its default.
    ///
    /// `Brand.sources` is a Codable array persisted inside SwiftData, and SwiftData
    /// decodes those with an internal `try!` — so a key added to this struct after a
    /// store was written is not a migration problem, it is a **crash on launch** for
    /// anyone holding the older data (this happened with `failureCount`). None of these
    /// fields carry meaning worth refusing to load a brand over: a missing fingerprint
    /// or etag costs one extra fetch, a missing failure count restarts the backoff.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try container.decode(Kind.self, forKey: .kind)
        url = try container.decode(URL.self, forKey: .url)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        fingerprint = try container.decodeIfPresent(String.self, forKey: .fingerprint)
        etag = try container.decodeIfPresent(String.self, forKey: .etag)
        lastCheckedAt = try container.decodeIfPresent(Date.self, forKey: .lastCheckedAt)
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        failureCount = try container.decodeIfPresent(Int.self, forKey: .failureCount) ?? 0
    }

    /// Backs off 2^failures minutes, capped at 6 hours.
    public func isReadyToCheck(now: Date = Date()) -> Bool {
        guard failureCount > 0, let lastCheckedAt else { return true }
        let delay = min(pow(2.0, Double(failureCount)) * 60, 6 * 3600)
        return now.timeIntervalSince(lastCheckedAt) >= delay
    }

    public var isReadyToCheck: Bool { isReadyToCheck() }
}
