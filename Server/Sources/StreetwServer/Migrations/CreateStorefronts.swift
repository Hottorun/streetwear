// CreateStorefronts.swift
// `storefronts` — a brand's shop in one country, when it runs one apart from its main shop.
//
// Created empty. The main shop is the brand row and every source whose `storefront_id` is
// null, so nothing existing needs a storefront and none is minted here — see `StorefrontModel`
// for why that is what keeps every brand in the catalogue working unchanged.
//
// `.cascade` from the brand, for the reason `poll_hints` has it: a storefront nobody can reach
// through a brand is a shop polled for nobody. Unique on (brand_id, country), because a person
// is served one shop per brand, and two for one country would leave which one undecided.

import Fluent

struct CreateStorefronts: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(StorefrontModel.schema)
            .id()
            .field("brand_id", .uuid, .required, .references(BrandModel.schema, "id", onDelete: .cascade))
            .field("country", .string, .required)
            .field("url", .string, .required)
            .field("currency", .string)
            .field("created_at", .datetime)
            .unique(on: "brand_id", "country")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(StorefrontModel.schema).delete()
    }
}
