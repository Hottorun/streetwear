// PageWatchSource.swift
// Generic "did this page change?" watcher, for brands with no catalog and no feed.
// Also the detector for the drop-lock signal: storefronts that go behind a password
// page right before a release.

// swift-crypto: re-exports CryptoKit on Apple, provides it natively on Linux, so this
// file compiles unchanged in the server image.
import Crypto
import Foundation

public struct PageWatchSource: SourceAdapter {
    public var kind: BrandSource.Kind { .page }

    private let http: any HTTPFetching

    public init(http: any HTTPFetching = Net.live) {
        self.http = http
    }

    public func fetch(_ source: BrandSource, since: Date?) async throws -> FetchResult {
        let response = try await http.get(source.url, etag: source.etag)
        if response.notModified {
            return FetchResult(fingerprint: source.fingerprint, etag: source.etag, notModified: true)
        }

        // A lock the status code can see, or one the page admits to in its own markup.
        // The second kind is how a storefront usually gates a drop — the shop stays up and
        // answers 200 while Locksmith turns you away from the thing you came for — and
        // reading only the status left those looking wide open.
        let body = String(data: response.data, encoding: .utf8)
        let declaresLock = body.map(StorefrontLock.isLocked(html:)) ?? false

        if response.isLocked || declaresLock {
            // The fingerprint doubles as the lock flag, so a lock is reported on the
            // unlocked -> locked *transition* only. Polling every minute through a drop
            // must not append a row each time; but a later drop, after the store has
            // reopened (which replaces the fingerprint with a content hash), must fire
            // again. Keying the id on the source alone made a lock a once-ever event.
            guard source.fingerprint != Self.lockedFingerprint else {
                return FetchResult(fingerprint: Self.lockedFingerprint, isLocked: true)
            }
            // A locked page sometimes still says *when*. Most don't — the countdown is
            // usually JavaScript — but when the markup labels a start time explicitly,
            // that turns "a drop is close" into an actual entry in the calendar.
            let announced = body.flatMap { DropDateParser.find(in: $0) }

            let item = FetchedItem(
                externalID: "lock:\(source.id.uuidString):\(Int(Date().timeIntervalSince1970))",
                title: "Storefront locked",
                summary: announced == nil
                    ? "The page is password protected or refusing requests — usually a drop is close."
                    : "The page is locked and names a start time.",
                linkURL: source.url,
                publishedAt: Date(),
                kind: .dropLock,
                releaseDate: announced
            )
            return FetchResult(items: [item], fingerprint: Self.lockedFingerprint, isLocked: true)
        }

        try response.requireOK()
        guard let html = String(data: response.data, encoding: .utf8)
                ?? String(data: response.data, encoding: .isoLatin1) else {
            throw SourceError.emptyPayload
        }

        let signature = Self.fingerprint(of: html)

        // First sight of a page is the baseline, not a change worth surfacing.
        guard let previous = source.fingerprint else {
            return FetchResult(items: [], fingerprint: signature, isLocked: false, etag: response.etag)
        }
        guard previous != signature else {
            return FetchResult(items: [], fingerprint: signature, isLocked: false, etag: response.etag)
        }

        let item = FetchedItem(
            externalID: "page:\(signature)",
            title: "Page updated",
            summary: Self.pageTitle(in: html) ?? source.url.host(),
            linkURL: source.url,
            publishedAt: Date(),
            kind: .pageChange
        )
        return FetchResult(items: [item], fingerprint: signature, isLocked: false, etag: response.etag)
    }

    /// Sentinel stored in place of a content hash while a storefront is locked. Not a
    /// valid SHA-256, so it can never collide with a real page fingerprint.
    static let lockedFingerprint = "locked"

    /// Hash the visible text only. Raw HTML changes on every load thanks to CSRF
    /// tokens, cache-busting query strings and session IDs, which would make every
    /// single check look like a change.
    public static func fingerprint(of html: String) -> String {
        var text = html
        for pattern in [
            "(?s)<script.*?</script>",
            "(?s)<style.*?</style>",
            "(?s)<!--.*?-->",
            "<[^>]+>"
        ] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        text = text
            .replacingOccurrences(of: "[0-9a-f]{16,}", with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func pageTitle(in html: String) -> String? {
        guard let range = html.range(of: #"(?<=<title>)[^<]+"#, options: [.regularExpression, .caseInsensitive]) else {
            return nil
        }
        return String(html[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
