// AddVariantImageIndex.swift
// `variants.image_index` — which of the product's photographs shows this variant.
//
// Nullable with no backfill, and it needs none: the association is published by the
// storefront and re-read on every poll, so each product picks its indices up the next time
// it is checked. Until then a colourway simply doesn't move the gallery, which is exactly
// the behaviour it had before this column existed.
//
// Not derivable after the fact. The catalogue expresses it as `variant_ids` on each image
// (or `featured_image.position` on each variant); by the time a product row exists, the
// images are a bare array of URLs and the link is gone.

import Fluent

struct AddVariantImageIndex: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(VariantModel.schema)
            .field("image_index", .int)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(VariantModel.schema)
            .deleteField("image_index")
            .update()
    }
}
