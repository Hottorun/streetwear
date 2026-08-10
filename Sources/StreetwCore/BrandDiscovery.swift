// BrandDiscovery.swift
// Given just a website URL, work out what we can actually watch.

import Foundation

public struct DiscoveredSources: Sendable {
    public var sources: [BrandSource] = []
    public var suggestedName: String?
    /// The brand's own mark, taken from the icon the site publishes for home screens.
    public var logoURL: URL?

    public init() {}

    public var summary: String {
        guard !sources.isEmpty else { return "No automatic sources found" }
        return sources.map(\.kind.label).joined(separator: " · ")
    }
}

public enum BrandDiscovery {
    /// Probes a domain for a Shopify catalog and a feed, and always falls back to
    /// watching the page itself so every brand yields at least one signal.
    public static func discover(
        website raw: String,
        instagramHandle: String?,
        http: any HTTPFetching = Net.live
    ) async -> DiscoveredSources {
        var result = DiscoveredSources()

        if let base = normalizedURL(raw) {
            result.suggestedName = suggestName(from: base)

            if await ShopifySource.detect(at: base, http: http) {
                result.sources.append(BrandSource(kind: .shopify, url: base))
            }
            if let feed = await FeedSource.detect(at: base, http: http) {
                result.sources.append(BrandSource(kind: .feed, url: feed))
            }
            // Page watching is only worth it when there's no structured source;
            // otherwise it just fires on every marketing banner swap.
            if result.sources.isEmpty {
                result.sources.append(BrandSource(kind: .page, url: base))
            }

            // One extra request, once, when a brand is added — never on a poll.
            result.logoURL = await BrandMark.discover(at: base, http: http)
        }

        if let handle = normalizedHandle(instagramHandle),
           let url = URL(string: "https://instagram.com/\(handle)") {
            result.sources.append(BrandSource(kind: .instagram, url: url))
        }

        return result
    }

    /// Accepts "kith.com", "kith.com/", "https://kith.com/collections/new".
    /// Reduces to the scheme + host, which is what the probes need.
    public static func normalizedURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard var components = URLComponents(string: withScheme), let host = components.host else { return nil }
        components.scheme = "https"
        components.host = host
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }

    public static func normalizedHandle(_ raw: String?) -> String? {
        guard var handle = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !handle.isEmpty else { return nil }
        if let url = URL(string: handle), url.host?.contains("instagram.com") == true {
            handle = url.lastPathComponent
        }
        handle = handle.trimmingCharacters(in: CharacterSet(charactersIn: "@/ "))
        return handle.isEmpty ? nil : handle
    }

    /// "shop.bbcicecream.com" -> "Bbcicecream". A starting point the user can edit.
    private static func suggestName(from url: URL) -> String? {
        guard let host = url.host() else { return nil }
        let parts = host
            .replacingOccurrences(of: "www.", with: "")
            .replacingOccurrences(of: "shop.", with: "")
            .split(separator: ".")
        guard let first = parts.first else { return nil }
        return first.capitalized
    }
}
