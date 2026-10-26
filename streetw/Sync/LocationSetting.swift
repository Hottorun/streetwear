// LocationSetting.swift
// Which country somebody shops in: the phone's region, unless they chose another.
//
// **All it ever does is choose between a brand's own shops.** Big retailers run a shop per
// country, and the server serves each person the one for their country where a brand runs
// one and it is being read — otherwise the brand's main shop, exactly as before. It never
// converts a price, never hides a brand and never filters a feed. See
// `docs/design-decisions.md`.
//
// Held on the server (`users.country`, sent beside the sizes on `PATCH /v1/devices/me`),
// because the server decides which shop's events and pushes reach a person. Standalone has no
// server and no storefronts, so there it is kept and changes nothing.
//
// UserDefaults rather than SwiftData, like the size profile: one small value, and keeping it
// out of the schema avoids a migration for a setting.

import Foundation
import Observation
import StreetwCore

@MainActor
@Observable
final class LocationSetting {
    private static let key = "locationCountry"

    /// What somebody picked, or nil to follow the phone. Kept apart from the answer so that a
    /// phone moved to another region follows it, until somebody says otherwise.
    private(set) var chosen: String? {
        didSet { UserDefaults.standard.set(chosen, forKey: Self.key) }
    }

    init() {
        chosen = CountryCode.normalized(UserDefaults.standard.string(forKey: Self.key))
    }

    /// The country in use: the one chosen, else the phone's region. Nil when neither says —
    /// a phone set to a region that is not a country — which is the main shop everywhere.
    var country: String? { chosen ?? Self.phoneRegion }

    /// Whether this is the phone's own region rather than a choice.
    var followsPhone: Bool { chosen == nil }

    /// Picks a country; the phone's own region, or nil, goes back to following the phone.
    func choose(_ code: String?) {
        let code = CountryCode.normalized(code)
        chosen = code == Self.phoneRegion ? nil : code
    }

    /// What the server is told: the code, or empty for "the main shop".
    ///
    /// Never absent. Absent means "not telling you" on the wire, and this setting always has
    /// an answer — sending it on every launch is also what heals a server that lost it.
    var wireValue: String { country ?? "" }

    /// The region the phone is set to, as a country code.
    nonisolated static var phoneRegion: String? {
        CountryCode.normalized(Locale.current.region?.identifier)
    }

    /// "United Kingdom", in the reader's language. Falls back to the code.
    nonisolated static func name(of code: String) -> String {
        Locale.current.localizedString(forRegionCode: code) ?? code
    }

    /// The name as it sits in a sentence — "the United Kingdom", "Germany". The article only
    /// in English, which is the language every other line in the app is written in; a name the
    /// phone gave in another language is used as it came.
    nonisolated static func inSentence(_ code: String) -> String {
        let name = name(of: code)
        guard Locale.current.language.languageCode == .english, takesArticle.contains(code) else { return name }
        return "the " + name
    }

    private nonisolated static let takesArticle: Set<String> = [
        "AE", "BS", "CD", "CF", "CG", "DO", "FK", "FO", "GB", "GM", "KM", "KY", "MH", "MP",
        "MV", "NL", "PH", "SB", "TC", "US", "VA", "VG", "VI"
    ]

    /// Every country a phone can name, by name. Continents and the other numeric groupings
    /// `Locale.Region` also lists are not countries and are left out by `CountryCode`.
    nonisolated static let countries: [(code: String, name: String)] = Locale.Region.isoRegions
        .compactMap { CountryCode.normalized($0.identifier) }
        .map { (code: $0, name: name(of: $0)) }
        .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
}
