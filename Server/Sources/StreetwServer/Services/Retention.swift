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
//   eligible — and for a Shopify catalog the daily scan sees all of them, so there it is
//   products two complete scans no longer found (`unlisted_at`), six months on.
// - **The server is the archive, the phone is the window.** These bounds are deliberately
//   generous; the client keeps far less (400 per brand) and pages the rest from here.
//
// `usage_counts` is deliberately not swept. It is a dozen rows a day of totals that describe
// nobody, so a year of it is a few thousand rows, and the history is the only thing it is
// for — "did anybody use the Style tab before the redesign" is a question about last year.
// `devices.active_on` needs no sweep either: it is one day per device, overwritten.

import Fluent
import Foundation
import SQLKit
import StreetwCore
import Vapor

struct ReapResult: Sendable, Equatable {
    var events = 0
    var products = 0
    var pollHints = 0
    var checks = 0
    var pickReasons = 0
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
            //
            // **Gone for six months, by whichever reading knows.** A product the daily scan
            // reads is judged by `unlisted_at` — two complete scans in a row did not find it —
            // and counted from then, because the scan does not stamp `last_seen_at` (that
            // would rewrite the whole catalogue a day) and a product it still finds must
            // never age out. Everything else — a source no scan has completed within the
            // window, a sitemap, a feed — keeps the old reading, unseen for six months. A
            // listed product deleted here would come back as a new row on the next read;
            // that is why this asks the scan rather than the clock.
            //
            // **And never a product somebody is still waiting on.** `watches.product_id`
            // cascades, so pruning a watched product deleted the watch with it, silently — and a
            // product only its own page re-reads (`Poller.watchedRechecks`) can sit unseen by
            // any catalogue for months while being watched the whole time.
            let eligible: SQLQueryString = """
                NOT EXISTS (SELECT 1 FROM events WHERE events.product_id = products.id) \
                AND NOT EXISTS (SELECT 1 FROM watches \
                    WHERE watches.product_id = products.id AND watches.fired_at IS NULL) \
                AND ( \
                    (unlisted_at IS NOT NULL AND unlisted_at < \(bind: productCutoff)) \
                    OR (unlisted_at IS NULL AND last_seen_at < \(bind: productCutoff) \
                        AND NOT EXISTS (SELECT 1 FROM catalogue_scans \
                            WHERE catalogue_scans.source_id = products.source_id \
                            AND catalogue_scans.completed_at >= \(bind: productCutoff))) \
                )
                """
            result.products = try await sql.raw(
                "SELECT COUNT(*) AS count FROM products WHERE \(eligible)"
            ).first(decodingColumn: "count", as: Int.self) ?? 0

            if result.products > 0 {
                try await sql.raw("DELETE FROM products WHERE \(eligible)").run()

                // Belt and braces. Variants cascade from products *if* foreign keys are
                // enforced, which is a driver-level setting rather than something this
                // code controls — orphaned variants would otherwise accumulate silently.
                try await sql.raw("DELETE FROM variants WHERE product_id NOT IN (SELECT id FROM products)").run()
            }

            // A poll hint whose window has closed is spent. Nothing reads it — the queue
            // asks `PollHintPolicy.activeRange`, which a past release date can never fall
            // into again — so leaving it is a row that accumulates forever and slows the
            // one query the poller runs on every tick. Pruned on the sweep rather than at
            // the moment it expires, because "which hints are dead" is a table scan and
            // this is the pass that already owns those.
            //
            // A day's grace past the window, so a device that has been offline sees its own
            // hints on `GET /v1/poll-hints` for a while after the fact rather than finding
            // them silently gone.
            let hintCutoff = Date()
                .addingTimeInterval(-PollHintPolicy.windowAfter)
                .addingTimeInterval(-86_400)
            result.pollHints = try await PollHintModel.query(on: app.db)
                .filter(\.$releaseAt < hintCutoff)
                .count()
            if result.pollHints > 0 {
                try await PollHintModel.query(on: app.db)
                    .filter(\.$releaseAt < hintCutoff)
                    .delete()
            }

            // A brand check answers for its shop for minutes (`BrandChecks.reuseFor`), and a
            // day is far past anything still waiting on one. Its watchers cascade with it.
            let checkCutoff = Date().addingTimeInterval(-86_400)
            result.checks = try await BrandCheckModel.query(on: app.db)
                .filter(\.$createdAt < checkCutoff)
                .count()
            if result.checks > 0 {
                try await BrandCheckModel.query(on: app.db)
                    .filter(\.$createdAt < checkCutoff)
                    .delete()
                // Belt and braces, for the reason given for variants above.
                try await sql.raw(
                    "DELETE FROM brand_check_watchers WHERE check_id NOT IN (SELECT id FROM brand_checks)"
                ).run()
            }

            // A pick's cached sentence is believed for a month (`AILimits.pickReasonLifetime`)
            // and never read after; past that it is a row nobody will ask for.
            let reasonCutoff = Date().addingTimeInterval(-AILimits.pickReasonLifetime)
            result.pickReasons = try await AIPickReasonModel.query(on: app.db)
                .filter(\.$createdAt < reasonCutoff)
                .count()
            if result.pickReasons > 0 {
                try await AIPickReasonModel.query(on: app.db)
                    .filter(\.$createdAt < reasonCutoff)
                    .delete()
            }

            if result.events > 0 || result.products > 0 || result.pollHints > 0 || result.checks > 0 || result.pickReasons > 0 {
                app.logger.info(
                    "retention: pruned \(result.events) events, \(result.products) products, \(result.pollHints) poll hints, \(result.checks) brand checks, \(result.pickReasons) pick reasons"
                )
            }
        } catch {
            app.logger.error("retention: sweep failed: \(error)")
        }
        return result
    }
}
