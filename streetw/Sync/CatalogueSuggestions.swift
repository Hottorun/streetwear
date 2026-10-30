// CatalogueSuggestions.swift
// A save from a shop the catalogue lacks tells the catalogue about the shop.
//
// Search can only recommend from shops the server reads, and the shops somebody saves from
// without following are exactly the ones it is missing. So the first time something is saved
// from a shop that is not a brand on this phone, the shop's **domain** is sent as a
// catalogue-only check (`RemoteSync.suggestShop`); the server adds it if it finds a shop whose
// products it can read, follows nobody, and keeps nothing about who asked. There is no follow
// and no switch: what leaves the phone is `https://<host>` — never the product, the page, or the
// fact that something was saved from it — which is what the privacy policy says.
//
// - **Server mode only.** Standalone, nothing is noted and nothing is sent.
// - **Once per shop per install**, by registrable domain, so Palace's four hosts are one shop.
//   The ledger is the phone's, not a person's: it records what this install has already said,
//   and a second profile saving from the same shop has nothing new to tell the server.
// - **Only when the shop is not a brand here** (`update.brand == nil`). Whether the catalogue
//   has it already is answered by the server's own first step, `BrandCatalog.existing`, before
//   anything is fetched — one request either way, and the same domain the brand search would
//   have sent.
// - Kept until the server has taken it, so a share made offline is told later.

import Foundation
import OSLog
import StreetwCore

@MainActor
enum CatalogueSuggestions {
    private static let log = Logger(subsystem: "com.kern.functional.streetw", category: "share")
    /// Domains already told, and domains waiting to be. Phone keys, not `ProfileScope` ones.
    static let sentKey = "catalogueSuggestedDomains"
    static let pendingKey = "catalogueSuggestionsPending"

    /// Remembers the shop a new save came from, if it is one this install has not told.
    static func note(_ link: URL?) {
        guard let host = link?.host(), host.contains(".") else { return }
        let domain = BrandDiscovery.registrableDomain(of: host)
        let defaults = UserDefaults.standard
        let sent = Set(defaults.stringArray(forKey: sentKey) ?? [])
        var pending = defaults.stringArray(forKey: pendingKey) ?? []
        guard !sent.contains(domain), !pending.contains(domain) else { return }
        pending.append(domain)
        defaults.set(pending, forKey: pendingKey)
    }

    /// Sends what is waiting. A refusal from the server is still an answer — the shop was
    /// told — so only a failure to reach it keeps a domain waiting.
    static func send(via remote: RemoteSync) async {
        guard remote.isServerBacked else { return }
        let defaults = UserDefaults.standard
        var pending = defaults.stringArray(forKey: pendingKey) ?? []
        guard !pending.isEmpty else { return }
        var sent = defaults.stringArray(forKey: sentKey) ?? []
        for domain in pending {
            do {
                try await remote.suggestShop(origin: "https://\(domain)")
            } catch APIError.server(let status, _) where status != 429 && status < 500 {
                // Told, and refused for a reason asking again will not change — an address
                // the server will not read, say.
            } catch {
                log.info("could not suggest a shop yet: \(error)")
                break
            }
            sent.append(domain)
            pending.removeAll { $0 == domain }
        }
        defaults.set(sent, forKey: sentKey)
        defaults.set(pending, forKey: pendingKey)
    }
}
