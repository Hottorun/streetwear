// CountryShops.swift
// A brand's country shops, found where the brand itself says they are.
//
// Storefronts used to be attached by hand only (`POST /admin/brands/:id/storefronts`), on the
// argument that finding them would mean probing every brand's every plausible host for every
// country — a crawl, not a poll. The brand already publishes the answer: its homepage's
// `<link rel="alternate" hreflang="en-US" href="https://us.subdued.com">` names the shop it
// runs for each country, for search engines that will send real shoppers there, so a wrong
// one costs the brand its own customers. That is trustworthy enough to act on, and it costs no
// guess: the homepage is the one discovery already reads (`DiscoveredSources.alternates`).
//
// So during a brand check, and during the rediscovery pass, each **switched-on** country whose
// alternate points at a **separately readable shop** is verified the way a brand check
// verifies a shop and attached through the same `Storefronts.attach` the admin route uses. The
// rules, in the order they are applied (`plan`):
//
// - **Only countries in `STOREFRONT_COUNTRIES`.** A country that is off records nothing — not
//   even an offer: nothing would read the shop, and the alternate will still be there the day
//   the country is switched on and the pass's version moves.
// - **`x-default` and language-only codes (`en`, `fr`) are not countries**, and a code naming
//   one country twice (`de-DE`, `en-DE`) takes the English one, the language every copy here
//   is read in — `LocalePreference`'s default — else the first.
// - **A country another shop of the brand already serves is left alone.** Attaching never
//   takes a country off a shop somebody put there.
// - **The main shop again is not a country's shop**: an alternate at the main shop's own URL
//   (Kith's `en-US` is kith.com), and **a market subfolder** — a path on the host the main
//   shop's catalogue is read from by host (Shopify, UCP). Shopify Markets serves `/en-gb/` from
//   the same catalogue in another currency, and every product read from it would be the main
//   shop's under a second id; nothing is fetched for one. A path on a host read by path — a
//   Magento store view, `/de_en` — is a shop of its own if it verifies with its own source.
// - **Verified, or not attached.** The alternate is discovered like a brand being added, through
//   the shared fetcher, and must yield a source that reads products (`readsProducts`); a host
//   that answers only bot walls, or nothing, is not attached (`ShopRefusal`), and a source the
//   brand already reads refuses it (`Storefronts.attach`). Nothing is retried another way.

import Fluent
import Foundation
import StreetwCore
import Vapor

enum CountryShops {
    /// A shop to verify, for the switched-on countries whose alternate names it.
    struct Candidate: Equatable {
        var url: URL
        var countries: Set<String>
    }

    enum Skip: String, Equatable {
        case served = "another shop of the brand serves it"
        case mainShop = "the main shop"
        case marketSubfolder = "a market subfolder of the main shop's catalogue"
    }

    struct Plan: Equatable {
        var candidates: [Candidate] = []
        var skipped: [Skipped] = []

        struct Skipped: Equatable {
            var country: String
            var url: URL
            var reason: Skip
        }
    }

    /// Which alternates are worth verifying — the whole rule, without a request or a database.
    ///
    /// - Parameters:
    ///   - main: the brand's website.
    ///   - mainSources: the main shop's sources, kind and URL.
    ///   - served: countries a shop of the brand already serves.
    static func plan(
        alternates: [LanguageAlternate],
        enabled: Set<String>,
        main: URL,
        mainSources: [(kind: BrandSource.Kind, url: URL)],
        served: Set<String>
    ) -> Plan {
        var plan = Plan()
        var chosen: [String: LanguageAlternate] = [:]
        var order: [String] = []
        for alternate in alternates where !alternate.isDefault {
            guard let country = alternate.country, enabled.contains(country) else { continue }
            if let held = chosen[country] {
                if held.language != "en", alternate.language == "en" { chosen[country] = alternate }
            } else {
                chosen[country] = alternate
                order.append(country)
            }
        }

        let hostReads = Set(
            mainSources
                .filter { [.shopify, .ucp, .collections].contains($0.kind) }
                .compactMap { $0.url.host().map(bareHost) }
        )
        var byURL: [String: Candidate] = [:]
        var urls: [String] = []
        for country in order {
            guard let alternate = chosen[country] else { continue }
            let url = alternate.url
            if served.contains(country) {
                plan.skipped.append(.init(country: country, url: url, reason: .served))
                continue
            }
            if key(url) == key(main) || isHome(url) && sameHost(url, main) {
                plan.skipped.append(.init(country: country, url: url, reason: .mainShop))
                continue
            }
            if let host = url.host(), hostReads.contains(bareHost(host)) {
                plan.skipped.append(.init(country: country, url: url, reason: isHome(url) ? .mainShop : .marketSubfolder))
                continue
            }
            let k = key(url)
            if byURL[k] == nil {
                byURL[k] = Candidate(url: pinned(url), countries: [])
                urls.append(k)
            }
            byURL[k]?.countries.insert(country)
        }
        plan.candidates = urls.compactMap { byURL[$0] }
        return plan
    }

    /// What became of one candidate, as a line of the brand's report.
    enum Result: Equatable {
        case attached(countries: [String], shop: String, kinds: [String])
        case refused(countries: [String], shop: String, why: String)

        var line: String {
            switch self {
            case let .attached(countries, shop, kinds):
                "+storefront \(countries.joined(separator: ",")) \(shop) (\(kinds.joined(separator: "+")))"
            case let .refused(countries, shop, why):
                "storefront \(countries.joined(separator: ",")) \(shop) not attached: \(why)"
            }
        }

        var isAttached: Bool {
            if case .attached = self { return true }
            return false
        }
    }

    /// Verifies and attaches the brand's country shops its alternates name. Every request goes
    /// through `http` — the shared `PoliteFetcher` — one candidate after another.
    ///
    /// Returns at once, with nothing fetched, while no country is switched on.
    static func attach(
        brandID: UUID,
        alternates: [LanguageAlternate],
        enabled: Set<String>,
        http: any HTTPFetching,
        on db: any Database
    ) async throws -> [Result] {
        guard !enabled.isEmpty, !alternates.isEmpty,
              let brand = try await brand(brandID, on: db)
        else { return [] }
        let main = brand.website.flatMap(URL.init(string:)) ?? URL(string: "https://\(brand.slug)")!
        let plan = plan(
            alternates: alternates,
            enabled: enabled,
            main: main,
            mainSources: brand.sources.filter { $0.$storefront.id == nil }.compactMap { source in
                guard let kind = BrandSource.Kind(rawValue: source.kind), let url = URL(string: source.url)
                else { return nil }
                return (kind, url)
            },
            served: try await served(brandID, on: db)
        )

        var results: [Result] = []
        for candidate in plan.candidates {
            let countries = candidate.countries.sorted()
            let shop = display(candidate.url)
            let log = ProbeLog(wrapping: http)
            let found = await BrandDiscovery.discover(
                website: candidate.url.absoluteString, instagramHandle: nil, http: log
            )
            guard found.readsProducts else {
                let why = switch ShopRefusal.classify(log.outcomes) {
                case .blocksReaders: "it blocks automated readers"
                case .sellsNoClothes, .nothingAnswered:
                    found.sources.isEmpty ? "nothing there answered" : "nothing there reads its products"
                }
                results.append(.refused(countries: countries, shop: shop, why: why))
                continue
            }
            // Read again for each: the one before may have attached a shop.
            guard let current = try await Self.brand(brandID, on: db) else { break }
            switch try await Storefronts.attach(
                brand: current, base: candidate.url, found: found,
                countries: candidate.countries, force: false, on: db
            ) {
            case let .attached(_, sources, _):
                results.append(.attached(countries: countries, shop: shop, kinds: sources.map(\.kind.rawValue)))
            case .refused(let why):
                let reason = why.hasPrefix("refused: ") ? String(why.dropFirst("refused: ".count)) : why
                results.append(.refused(countries: countries, shop: shop, why: reason))
            }
        }
        return results
    }

    private static func brand(_ id: UUID, on db: any Database) async throws -> BrandModel? {
        try await BrandModel.query(on: db).filter(\.$id == id).with(\.$sources).first()
    }

    private static func served(_ brandID: UUID, on db: any Database) async throws -> Set<String> {
        Set(try await StorefrontCountryModel.query(on: db).filter(\.$brandID == brandID).all().map(\.country))
    }

    /// `www.subdued.com/de_en`, `us.subdued.com` — what a report line names the shop by.
    static func display(_ url: URL) -> String {
        let path = url.path
        return (url.host() ?? url.absoluteString) + (path == "/" ? "" : path)
    }

    /// https, the host and the path, without a trailing slash — what a shop is stored as.
    private static func pinned(_ url: URL) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = url.host()?.lowercased()
        let path = url.path
        components.path = path == "/" ? "" : path
        return components.url ?? url
    }

    private static func key(_ url: URL) -> String {
        pinned(url).absoluteString.lowercased()
    }

    private static func isHome(_ url: URL) -> Bool {
        url.path.isEmpty || url.path == "/"
    }

    private static func sameHost(_ a: URL, _ b: URL) -> Bool {
        guard let x = a.host(), let y = b.host() else { return false }
        return bareHost(x) == bareHost(y)
    }

    private static func bareHost(_ host: String) -> String {
        let lowered = host.lowercased()
        return lowered.hasPrefix("www.") ? String(lowered.dropFirst(4)) : lowered
    }
}
