// StockRefresh.swift
// Asking the storefront what is actually left, at the moment somebody is deciding.
//
// **A feed row is a record of an event, and its variants are a photograph of the shelf on
// the day that event fired.** That is correct and deliberate everywhere else in the app: an
// event says what happened, `restockedSizes` names the sizes that came back *then*, and the
// price a markdown quotes is the price it dropped from. Nothing in the client ever went back
// and re-read a product, because the server owns the polling and the client owns the record.
//
// The consequence only shows up on one screen, and it is the screen that matters most. A
// product page is not a record of anything — it is where somebody decides whether to buy
// something — and it was printing a size run from whenever the event happened to fire. A
// hoodie that dropped on Friday and sold out on Saturday still showed a full run of ticks on
// Sunday, with "IN YOUR SIZE" over it and a buy button underneath. The app was confidently
// wrong about the one fact it exists to get right.
//
// Three things keep this honest:
//
// - **Only where a decision is being made.** The two detail pages, on appearance. Never the
//   feed, which draws dozens of cards and would turn a scroll into dozens of requests.
// - **Only what stock is.** Variants and whole-product availability, never the price. A
//   markdown event says "was £180, now £120", and rewriting `priceText` underneath that
//   would leave a card comparing today's price against a "was" from another week. The
//   shelf changes hourly; what the event *said* does not change at all.
// - **Only when it could have moved.** `stockCheckedAt` throttles it, so paging back and
//   forth between a product and the feed is one request, not one per visit.
//
// It fetches from the phone in both modes, which is the one place this steps outside "go
// over the server when one is configured". There is no route for it and the question is
// about a single product being looked at right now; `SharedSaveImporter` already reads
// storefronts directly for exactly the same reason, through the same adapter and the same
// politeness. A route would be the better answer the day this needs to happen in bulk.

import Foundation
import OSLog
import StreetwCore
import SwiftData

@MainActor
enum StockRefresh {
    private static let log = Logger(subsystem: "com.kern.functional.streetw", category: "stock")

    /// How long an answer is trusted for.
    ///
    /// Ten minutes: long enough that opening a product, going back and opening it again is
    /// free, short enough that it is a genuinely current answer during a drop — which is the
    /// only time the difference is worth anything.
    static let freshness: TimeInterval = 10 * 60

    /// A storefront that hangs must not hold the page. The size run already on screen is a
    /// reasonable thing to keep looking at while this runs, and the alternative — a spinner
    /// over the whole product — would be worse than the staleness it is fixing.
    private static let timeout: Duration = .seconds(8)

    /// Re-reads one product's stock, if it is worth re-reading. Returns whether anything
    /// changed, so a caller can decide whether to animate.
    @discardableResult
    static func refresh(_ update: BrandUpdate, in context: ModelContext) async -> Bool {
        guard let link = update.linkURL else { return false }
        // Costs nothing to ask and saves a request against every non-Shopify link in the
        // collection: `product(at:)` needs a `/products/<handle>` path and returns nil
        // without one, but only after this check does it return nil for *free*.
        guard ShopifySource.productHandle(in: link) != nil else { return false }
        if let checked = update.stockCheckedAt,
           Date().timeIntervalSince(checked) < freshness {
            return false
        }

        // Stamped before the fetch, not after. A storefront that is refusing us should be
        // asked once every ten minutes like any other, not on every appearance of the page
        // because the failure left no record.
        update.stockCheckedAt = Date()

        guard let fresh = await fetch(link, currency: update.brand?.currencyCode) else {
            try? context.save()
            return false
        }

        var changed = false
        if !fresh.variants.isEmpty, fresh.variants != update.variants {
            update.variants = fresh.variants
            changed = true
        }
        if update.isAvailable != fresh.isAvailable {
            update.isAvailable = fresh.isAvailable
            changed = true
        }
        // The garment's identity, not its price — see the note at the top. Filled only when
        // missing, which is how a server-backed row that never carried variants also picks
        // up the key a share would match it by.
        if update.productExternalID == nil { update.productExternalID = fresh.externalID }

        try? context.save()
        if changed {
            log.info("stock moved on \(link.absoluteString, privacy: .public)")
        }
        return changed
    }

    private static func fetch(_ link: URL, currency: String?) async -> FetchedItem? {
        await withTaskGroup(of: FetchedItem?.self) { group in
            group.addTask { await ShopifySource.product(at: link, currency: currency) }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
