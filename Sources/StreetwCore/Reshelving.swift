// Reshelving.swift
// Telling a drop apart from a product being put back on the shelf.
//
// `published_at` is not "when this was made" — it is *when it was last put out*, and
// storefronts rewrite it constantly. Kith runs Shopify Flow automations that unpublish and
// republish stock in sweeps (its own tags say so: `081126NIKEremerch`,
// `102825unpublishrequestRTV`, `shopifyflow:removedtag`), and every sweep restamps
// `published_at` to now. The catalogue then presents a three-year-old sneaker as today's
// newest product, at the top of the page, indistinguishable from a real drop.
//
// Measured on Kith's 250 most recent products, the split is not subtle:
//
// ```
//   created ≤7 days before publication   195      a launch
//   8–30 days                              6      a launch, sat on for a while
//   31–180 days                            6
//   ≥180 days                             43      re-shelved: a 1,015-day-old Air Max 1,
//                                                 a 2,392-day-old bottle of CDG incense
// ```
//
// Forty-nine of two hundred and fifty — a fifth of the feed — and ten of them entirely sold
// out. That is the reported bug: a sweep landed as "many new clothes, all sold out", which
// is both false and the least useful thing the app could have said. Nothing dropped, and
// there was nothing to buy.
//
// Shared rather than living in either client, because the phone decides this under
// `-standalone YES` and the server decides it for everybody else, and a rule that fires on
// one path and not the other is the worst outcome available.

import Foundation

public enum Reshelving {
    /// How much older than its publication a product must be before the publication reads
    /// as a re-shelving rather than a launch.
    ///
    /// Ninety days, chosen to sit inside the gap in the data above rather than on a
    /// boundary. A brand does build a product record before it drops — a seasonal piece
    /// entered in May for an August launch is ordinary — so the threshold has to clear that
    /// comfortably, and it does: nothing in the sample sits between one month and six.
    /// Being wrong in the cautious direction costs one over-announced drop; being wrong the
    /// other way suppresses a real one, which is the failure this app cannot afford.
    public static let age: TimeInterval = 90 * 86_400

    /// Whether this publication is a shelf decision rather than a launch.
    ///
    /// Unknown creation dates answer `false`. Only Shopify publishes one; a feed, a sitemap
    /// and a page watch do not, and "we don't know" must never suppress an event.
    public static func isReshelved(createdAt: Date?, publishedAt: Date) -> Bool {
        guard let createdAt else { return false }
        return publishedAt.timeIntervalSince(createdAt) >= age
    }

    /// What a product nobody has seen before is worth saying — **nil for nothing at all**.
    ///
    /// Three answers, and the middle one is the point:
    ///
    /// - A genuinely new product keeps whatever kind its adapter gave it. This is the
    ///   overwhelmingly common case and nothing about it changes.
    /// - A re-shelved product you can buy is a `.restock`. It is not new and it is not a
    ///   discovery; it is stock that is on the shelf now and wasn't, which is exactly what
    ///   that kind already means and exactly what somebody would want to hear.
    /// - A re-shelved product with nothing buyable in it is **silent**. Nobody did
    ///   anything, nothing is for sale, and there is no version of this an alert improves.
    ///   The row is still stored — so a watch can be set on it and a real restock later
    ///   fires normally — it simply is not announced.
    ///
    /// Availability is read as `isAvailable`, which the adapter derives from the variants,
    /// so a source with no variant data reports nil and is treated as buyable. That is the
    /// right default: the only thing we would be doing with a firmer reading is hiding
    /// something on a guess.
    public static func firstSighting(of item: FetchedItem) -> UpdateKind? {
        guard isReshelved(createdAt: item.createdAt, publishedAt: item.publishedAt) else {
            return item.kind
        }
        return item.isAvailable == false ? nil : .restock
    }
}
