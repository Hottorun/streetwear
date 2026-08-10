// Retention.swift
// Keeps the catalog from growing without bound.
//
// Three constraints shape the rules, and each of them has a way to bite:
//
// - **`events.product_id` is `ON DELETE CASCADE`.** Deleting a product silently deletes
//   its feed history, including rows a client may not have synced yet. So products are
//   only ever considered *after* their events have aged out, and only when none remain.
// - **Deleting a product the source still lists re-creates it as new.** The next poll
//   would see an unknown `external_id` and write a `.product` event — retention would be
//   manufacturing fake drops. Only products the poller hasn't seen for a long time are
//   eligible, which for a Shopify catalog means they have fallen out of the incremental
//   window entirely.
// - **The server is the archive, the phone is the window.** These bounds are deliberately
//   generous; the client keeps far less (400 per brand) and pages the rest from here.

import Fluent
import Foundation
import SQLKit
import Vapor

struct ReapResult: Sendable, Equatable {
    var events = 0
    var products = 0
}

actor Reaper {
    private let app: Application
    private let eventDays: Int
    private let productDays: Int
    private var isRunning = false

    init(app: Application, eventDays: Int? = nil, productDays: Int? = nil) {
        self.app = app
        self.eventDays = eventDays
            ?? Environment.get("EVENT_RETENTION_DAYS").flatMap(Int.init)
            ?? 30
        self.productDays = productDays
            ?? Environment.get("PRODUCT_RETENTION_DAYS").flatMap(Int.init)
            ?? 180
    }

    @discardableResult
    func sweep() async -> ReapResult {
        guard !isRunning else { return ReapResult() }
        isRunning = true
        defer { isRunning = false }

        var result = ReapResult()
        guard let sql = app.db as? any SQLDatabase else { return result }

        let eventCutoff = Date().addingTimeInterval(-Double(eventDays) * 86_400)
        let productCutoff = Date().addingTimeInterval(-Double(productDays) * 86_400)

        do {
            // Events first — this is what frees products to be considered at all.
            // Unnotified events are spared regardless of age: the notifier's own
            // freshness window decides whether they are worth sending, and deleting
            // them here would leave that ledger with a hole rather than a decision.
            result.events = try await EventModel.query(on: app.db)
                .filter(\.$createdAt < eventCutoff)
                .filter(\.$notifiedAt != nil)
                .count()
            if result.events > 0 {
                try await EventModel.query(on: app.db)
                    .filter(\.$createdAt < eventCutoff)
                    .filter(\.$notifiedAt != nil)
                    .delete()
            }

            // `NOT EXISTS` rather than `NOT IN`: it is index-friendly, and it does not
            // choke on the NULL `product_id` a lock event carries.
            result.products = try await sql.raw("""
                SELECT COUNT(*) AS count FROM products \
                WHERE last_seen_at < \(bind: productCutoff) \
                AND NOT EXISTS (SELECT 1 FROM events WHERE events.product_id = products.id)
                """).first(decodingColumn: "count", as: Int.self) ?? 0

            if result.products > 0 {
                try await sql.raw("""
                    DELETE FROM products \
                    WHERE last_seen_at < \(bind: productCutoff) \
                    AND NOT EXISTS (SELECT 1 FROM events WHERE events.product_id = products.id)
                    """).run()

                // Belt and braces. Variants cascade from products *if* foreign keys are
                // enforced, which is a driver-level setting rather than something this
                // code controls — orphaned variants would otherwise accumulate silently.
                try await sql.raw("DELETE FROM variants WHERE product_id NOT IN (SELECT id FROM products)").run()
            }

            if result.events > 0 || result.products > 0 {
                app.logger.info("retention: pruned \(result.events) events, \(result.products) products")
            }
        } catch {
            app.logger.error("retention: sweep failed: \(error)")
        }
        return result
    }
}
