// BrandSource.swift
// A single place we watch for a brand: a Shopify catalog, a feed, a page, a profile.
import Foundation

public struct BrandSource: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case shopify
        case feed
        case page
        case instagram

        public var label: String {
            switch self {
            case .shopify: "Catalog"
            case .feed: "Feed"
            case .page: "Page watch"
            case .instagram: "Instagram"
            }
        }

        public var symbol: String {
            switch self {
            case .shopify: "bag"
            case .feed: "dot.radiowaves.up.forward"
            case .page: "eye"
            case .instagram: "camera"
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

    /// Backs off 2^failures minutes, capped at 6 hours.
    public func isReadyToCheck(now: Date = Date()) -> Bool {
        guard failureCount > 0, let lastCheckedAt else { return true }
        let delay = min(pow(2.0, Double(failureCount)) * 60, 6 * 3600)
        return now.timeIntervalSince(lastCheckedAt) >= delay
    }

    public var isReadyToCheck: Bool { isReadyToCheck() }
}
