// UCPAgent.swift
// Who streetw says it is, to a storefront that asks.
//
// The Universal Commerce Protocol is a negotiation: before a business will answer a
// catalogue query it fetches the caller's **agent profile** — a small JSON document at an
// HTTPS URL — and intersects the caller's declared capabilities with its own. Skip it and
// the answer is `UCP discovery failed: missing ucp version` and nothing else, which is
// exactly what a first attempt against Supreme returns.
//
// Two things follow from that, and both shape this file.
//
// **The profile has to be somewhere public.** A phone cannot host one, so the URI is always
// the streetw server's, in both modes — the merchant fetches it, not the client, and it says
// nothing about any particular device or person. It is a statement about the software.
//
// **The profile has to be honest.** Capability negotiation is not decoration: a business
// reads this to decide what it is allowed to send back and what it may expect us to handle.
// So it declares the two catalogue capabilities and **nothing else**. streetw does not have
// a cart, cannot check out and holds no payment instrument; declaring `checkout` or
// `payment_handlers` to widen the response would be claiming to be a shop. Supreme's own
// robots.txt is blunt about the line here — "Checkouts are for humans" — and the
// corresponding line in this codebase is that the poller is a reader.
//
// The document lives in `StreetwCore` rather than in the server target because both ends
// need it: the server serves it at `/.well-known/ucp`, and `UCPSource` names its URI on
// every request. Two copies would drift, and a profile that disagrees with the URI it is
// served from is a negotiation failure nobody could read.

import Foundation

public enum UCPAgent {
    /// The protocol revision this client speaks.
    ///
    /// A date, per the spec. Bumping it means having read the changelog: a business that
    /// does not support the version answers `version_unsupported` and refuses outright,
    /// which is a cleaner failure than a silently different payload shape.
    public static let version = "2026-04-08"

    /// Where the profile is served from.
    ///
    /// Overridable by environment for a staging deployment, because the URI has to resolve
    /// *from the merchant's network* — a localhost URL here does not fail loudly, it fails
    /// as a 422 on every catalogue call with no clue as to why.
    public static var profileURL: URL {
        let base = ProcessInfo.processInfo.environment["PUBLIC_BASE_URL"]
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? defaultBase
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        return URL(string: "\(withScheme)/.well-known/ucp") ?? URL(string: "https://\(defaultBase)/.well-known/ucp")!
    }

    /// The deployed server. Same host the app ships pointing at; kept as a literal rather
    /// than read from `ServerSettings`, which lives in the app target and does not exist on
    /// the server side.
    public static let defaultBase = "selfless-exploration-production-86b2.up.railway.app"

    /// The document itself, as JSON.
    ///
    /// Built by hand rather than encoded from a struct: it is a fixed literal that has to
    /// match a published schema exactly, and a `Codable` round trip would add key-order and
    /// optionality questions to something with neither.
    public static var profile: [String: Any] {
        let catalogCapability: [[String: String]] = [[
            "version": version,
            "spec": "https://ucp.dev/\(version)/specification/catalog"
        ]]

        return [
            "ucp": [
                "version": version,
                "services": [
                    "dev.ucp.shopping": [[
                        "version": version,
                        "spec": "https://ucp.dev/\(version)/specification/overview",
                        "transport": "mcp",
                        "schema": "https://ucp.dev/\(version)/services/shopping/mcp.openrpc.json"
                    ]]
                ],
                // Read-only, and that is the whole point — see the note at the top.
                "capabilities": [
                    "dev.ucp.shopping.catalog.search": catalogCapability,
                    "dev.ucp.shopping.catalog.lookup": catalogCapability
                ]
            ]
        ]
    }

    /// Serialised, for a route to hand straight back.
    public static func profileJSON() throws -> Data {
        try JSONSerialization.data(withJSONObject: profile, options: [.sortedKeys])
    }

    /// The `meta` block every UCP tool call has to carry.
    static func meta() -> [String: Any] {
        ["ucp-agent": ["profile": profileURL.absoluteString]]
    }
}
