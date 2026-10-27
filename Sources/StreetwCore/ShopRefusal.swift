// ShopRefusal.swift
// Why a site nobody can watch cannot be watched.
//
// A refused check used to say one thing about every shop: "Dropwall couldn't read anything
// from this site … It may be down, or blocking us." That sentence is true of three different
// shops and useful about none of them, because each has a different answer:
//
// - **The shop refuses machines.** Bershka, Stradivarius, Pull&Bear and Chanel answer every
//   request — robots.txt included — with Akamai's 403 "Access Denied"; lululemon.de's sitemap,
//   homepage and products are a Cloudflare 403; ASOS drops the connection. The shop is up and
//   will not be read by a program. The answer is the share sheet: somebody's own Safari gets
//   in, so saving from it still works. **Never worked around** — no browser User-Agent, no
//   proxies, no retry dressed as a person. That is a product rule (`ROADMAP.md`, *Decided*),
//   and `Net.userAgent` stays honest.
// - **The brand sells no clothes online.** Chanel sells fragrance, beauty and eyewear on its
//   site and its ready-to-wear only in its boutiques, so even a readable catalogue would hold
//   nothing a follow is for. Not detectable from outside; a short curated list.
// - **Nothing answered, and nothing said why** — a dead domain, a site with no catalogue, feed,
//   sitemap or readable page. The one worth trying again later.
//
// The evidence is what the check's own requests came back with (`ProbeLog`): it observes, it
// changes nothing about how they are made.

import Foundation
import Synchronization
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum ShopRefusal {
    /// Brands whose own site sells no clothes, by registrable domain. Curated by hand and
    /// deliberately short: a wrong entry would refuse a shop that has a catalogue, so a brand
    /// earns a place only when its site plainly sells no garments at all.
    ///
    /// - `chanel.com`: fragrance, beauty, eyewear and some leather goods online; ready-to-wear
    ///   and handbags in boutiques only (checked 2026-10-27).
    public static let sellsNoClothes: Set<String> = ["chanel.com"]

    /// Whether this host belongs to a brand on the curated list — asked before anything is
    /// fetched, since no request could change the answer.
    public static func sellsNoClothes(host: String) -> Bool {
        sellsNoClothes.contains(BrandDiscovery.registrableDomain(of: host))
    }

    /// The reason a check found nothing watchable, read off what its requests came back with.
    ///
    /// **Blocked only when nothing got through at all.** One ordinary answer — a 404 for
    /// `/products.json`, a homepage that loads — means the shop does talk to us and simply
    /// publishes nothing we can read, which is the generic refusal. And a site whose name
    /// does not resolve or refuses the connection outright is not "blocking readers"; it is
    /// not there. What counts as a block is a bot-protection page, a connection dropped
    /// mid-request or a request that never got an answer, and a robots.txt that disallows us —
    /// which is the shop saying in so many words that it does not want to be read.
    public static func classify(_ outcomes: [ProbeOutcome]) -> BrandCheck.Refusal {
        let verdicts = outcomes.filter { $0 != .busy }
        guard !verdicts.isEmpty else { return .nothingAnswered }
        return verdicts.allSatisfy(\.isBlock) ? .blocksReaders : .nothingAnswered
    }
}

/// What one request made during a check came back with.
public enum ProbeOutcome: Sendable, Hashable {
    /// The site answered as itself, with any status.
    case answered(Int)
    /// An edge's bot-protection page — `HTTPResponse.isChallenged`.
    case challenged
    /// The connection was dropped, or no answer came before the timeout.
    case dropped
    /// robots.txt disallows the path for our user agent.
    case disallowed
    /// Our own politeness queue for the host was full — says nothing about the site.
    case busy
    /// Anything else: a name that does not resolve, a refused connection, an address we
    /// will not fetch.
    case unreachable

    var isBlock: Bool {
        switch self {
        case .challenged, .dropped, .disallowed: true
        case .answered, .busy, .unreachable: false
        }
    }

    public init(_ response: HTTPResponse) {
        self = response.isChallenged ? .challenged : .answered(response.status)
    }

    public init(_ error: any Error) {
        if let source = error as? SourceError {
            switch source {
            case .disallowedByRobots: self = .disallowed
            case .hostBusy: self = .busy
            case .blockedByEdge: self = .challenged
            default: self = .unreachable
            }
            return
        }
        if let url = error as? URLError {
            switch url.code {
            case .networkConnectionLost, .timedOut, .secureConnectionFailed:
                self = .dropped
            default:
                self = .unreachable
            }
            return
        }
        // A reset reported by the socket rather than the URL loading system: ECONNRESET is 54
        // on Darwin and 104 on Linux.
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain, ns.code == 54 || ns.code == 104 {
            self = .dropped
            return
        }
        self = .unreachable
    }
}

/// Passes every request through unchanged and remembers what each came back with.
///
/// Wraps the shared fetcher for the length of one check — above `PoliteFetcher`, so robots.txt,
/// spacing and the host check all still apply and nothing about any request changes. It sees
/// a refusal by robots.txt as the error that fetcher throws; robots.txt's own fetch is inside
/// it, and a shop that blocks that blocks the request after it the same way.
public final class ProbeLog: HTTPFetching, Sendable {
    private let base: any HTTPFetching
    private let recorded = Mutex<[ProbeOutcome]>([])

    public init(wrapping base: any HTTPFetching) {
        self.base = base
    }

    public var outcomes: [ProbeOutcome] {
        recorded.withLock { $0 }
    }

    public func get(_ url: URL, etag: String?) async throws -> HTTPResponse {
        try await record { try await base.get(url, etag: etag) }
    }

    public func post(_ url: URL, json body: Data, accept: String) async throws -> HTTPResponse {
        try await record { try await base.post(url, json: body, accept: accept) }
    }

    private func record(_ request: () async throws -> HTTPResponse) async throws -> HTTPResponse {
        do {
            let response = try await request()
            recorded.withLock { $0.append(ProbeOutcome(response)) }
            return response
        } catch {
            recorded.withLock { $0.append(ProbeOutcome(error)) }
            throw error
        }
    }
}
