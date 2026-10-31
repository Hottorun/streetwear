// ClearProductShots.swift
// Forgets every `products.shot_index` written under the first reading rule.
//
// The first rule took "no person in it" for "product shot", and on a gallery with a fabric
// close-up that handed the cover to the swatch (`ProductReading`, the file header). The rule is
// now the second (`ZeroShot.version` 2) and the backfill reads every product again under it —
// but that takes hours on Railway, and until a product is reached its old answer would go on
// being served on every feed row, Discover card and `/v1/products/readings` it is on. A wrong
// stand-in is worse than none, so the old answers go at once: nil is "keep the shop's first
// photograph", which is the new rule's default, and the stand-ins it does find come back as
// the backfill reaches them. The style words are left — the same prompts read them, and
// search needs them meanwhile. The ledger (`product_readings`) keeps its old method key, which
// is what makes every product due.
//
// Not reverted: the old answers are not worth having back.

import Fluent
import SQLKit

struct ClearProductShots: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("UPDATE products SET shot_index = NULL WHERE shot_index IS NOT NULL").run()
    }

    func revert(on database: any Database) async throws {}
}
