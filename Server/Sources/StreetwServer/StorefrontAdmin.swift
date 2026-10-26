// StorefrontAdmin.swift
// What the storefront admin routes share: reading the countries they were sent, finding a
// shop by a country it serves, and writing a set back in a reply. See `routes.swift`.

import Fluent
import Foundation
import Vapor

enum StorefrontAdmin {
    struct CountriesBody: Content { var countries: [String] }

    /// The countries a storefront route names, however they were sent: `?countries=DE,FR`,
    /// the older `?country=GB`, or a JSON body `{"countries": ["DE", "FR"]}`.
    static func requested(_ req: Request) -> Storefronts.Requested {
        var raws = [
            try? req.query.get(String.self, at: "countries"),
            try? req.query.get(String.self, at: "country"),
        ].compactMap { $0 }
        if req.headers.contentType == .json, let body = try? req.content.decode(CountriesBody.self) {
            raws += body.countries
        }
        return Storefronts.requested(raws)
    }

    /// "GB", or "DE,FR,IT" — or, past a dozen, the first dozen and a count, so a 48-country
    /// reply stays one line.
    static func codes(_ countries: some Collection<String>) -> String {
        let sorted = countries.sorted()
        guard sorted.count > 12 else { return sorted.joined(separator: ",") }
        return sorted.prefix(12).joined(separator: ",") + ",… (\(sorted.count))"
    }

    /// The brand's shop that serves `country`, with its countries loaded.
    static func storefront(of brandID: UUID, serving country: String, on db: any Database) async throws -> StorefrontModel? {
        guard let membership = try await StorefrontCountryModel.query(on: db)
            .filter(\.$brandID == brandID).filter(\.$country == country).first()
        else { return nil }
        return try await StorefrontModel.query(on: db)
            .filter(\.$id == membership.$storefront.id).with(\.$countries).first()
    }

    /// The part of a reply that says which of these countries nothing will read yet.
    static func notSwitchedOn(_ countries: Set<String>, _ app: Application) -> String {
        let off = countries.subtracting(app.storefrontCountries)
        guard !off.isEmpty else { return "" }
        return off == countries
            ? ". None of them is in STOREFRONT_COUNTRIES, so nothing is read yet"
            : ". \(codes(off)) not in STOREFRONT_COUNTRIES, so served from here only once switched on"
    }
}
