// CreateStorefrontCountries.swift
// `storefront_countries` — the countries a storefront serves, now that one shop can serve many.
//
// A join table rather than a `TEXT[]` on `storefronts`: an array column has to be `TEXT[]` on
// Postgres and cannot be reproduced on SQLite (`FixPostgresArrayColumns`), so every rule about
// who is served what would be exercised by no local test. A row per country is one shape on
// both, and its unique constraint is the rule itself.
//
// **Unique on (brand_id, country)**, the constraint `storefronts` had, moved to where the
// countries now live: one shop per brand per country, or which one a person there is served is
// undecided. `brand_id` is copied from the storefront so the constraint can see it. `.cascade`
// from the storefront, so `Storefronts.remove` takes its countries with it, and from the brand,
// as `storefronts` has.
//
// **Existing shops are copied across, and nothing else is touched.** Each storefront's own
// country becomes its one entry, so everybody is served exactly what they were. No source,
// product or event is written, so nothing is re-polled and no baseline is re-spent: a shop's
// sources still carry its `baselined_at` and `last_checked_at`, which is all the poller asks.
// Copied row by row through Fluent rather than with `INSERT … SELECT`, because neither database
// mints a UUID the other's SQL can — and there is one row per attached shop, which is a handful.
//
// `storefronts.country` stays: see `StorefrontModel.homeCountry` for why, and why it is
// harmless. Which also makes the revert exact.

import Fluent

struct CreateStorefrontCountries: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(StorefrontCountryModel.schema)
            .id()
            .field(
                "storefront_id", .uuid, .required,
                .references(StorefrontModel.schema, "id", onDelete: .cascade)
            )
            .field("brand_id", .uuid, .required, .references(BrandModel.schema, "id", onDelete: .cascade))
            .field("country", .string, .required)
            .unique(on: "brand_id", "country")
            .create()

        for storefront in try await StorefrontModel.query(on: database).all() {
            try await StorefrontCountryModel(
                storefrontID: try storefront.requireID(),
                brandID: storefront.$brand.id,
                country: storefront.homeCountry
            ).create(on: database)
        }
    }

    func revert(on database: any Database) async throws {
        try await database.schema(StorefrontCountryModel.schema).delete()
    }
}
