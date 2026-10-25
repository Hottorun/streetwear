// AddSaleLedgers.swift
// What a brand-wide sale needs stored: the words of a sale event, and the two ledgers that
// keep a sale from being announced more than once.
//
// - `events.title`, `events.summary` — a `.sale` is about the brand and has no product to
//   take its words from, as a lock has none; "25% OFF EVERYTHING · CODE AUTUMN" has to live
//   somewhere. Nil for every other kind, which keeps drawing from its product.
// - `brands.sale_measured_at`, `brands.sale_since` — the catalogue's state (`CatalogueSale`):
//   when its prices were first measured, which makes that first measurement a baseline, and
//   when the sale now running started. Written only on a transition.
// - `brands.banner_check_at` — when the announcement bar is next due a read, nil for never
//   read, which makes the first read a baseline too. The schedule in the row, like
//   `sources.next_check_at`, so a restart resumes rather than re-reading every homepage.
// - `brands.sale_banner`, `brands.sale_banner_seen_at` — the offer last announced from the
//   bar and when it was last seen there (`SaleBannerLedger`).
//
// All nullable with no backfill: every brand is honestly "never measured, never read", and
// the first look at each is the baseline that stops a deploy announcing every sale already up.
//
// **One column per `update()`.** Fluent renders several `.field`s as one `ALTER TABLE … ADD
// COLUMN a, ADD COLUMN b`, which Postgres accepts and SQLite rejects.

import Fluent

struct AddSaleLedgers: AsyncMigration {
    private static var eventColumns: [(String, DatabaseSchema.DataType)] {
        [("title", .string), ("summary", .string)]
    }

    private static var brandColumns: [(String, DatabaseSchema.DataType)] {
        [
            ("sale_measured_at", .datetime),
            ("sale_since", .datetime),
            ("banner_check_at", .datetime),
            ("sale_banner", .string),
            ("sale_banner_seen_at", .datetime),
        ]
    }

    func prepare(on database: any Database) async throws {
        for (name, type) in Self.eventColumns {
            try await database.schema(EventModel.schema).field(.string(name), type).update()
        }
        for (name, type) in Self.brandColumns {
            try await database.schema(BrandModel.schema).field(.string(name), type).update()
        }
    }

    func revert(on database: any Database) async throws {
        for (name, _) in Self.brandColumns.reversed() {
            try await database.schema(BrandModel.schema).deleteField(.string(name)).update()
        }
        for (name, _) in Self.eventColumns.reversed() {
            try await database.schema(EventModel.schema).deleteField(.string(name)).update()
        }
    }
}
