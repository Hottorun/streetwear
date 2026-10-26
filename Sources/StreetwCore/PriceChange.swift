// PriceChange.swift
// Deciding whether a price moved enough to be worth someone's attention.
//
// Storefront prices jiggle for reasons that are not sales: multi-currency stores
// recompute from an exchange rate several times a day, tax settings change by region,
// and rounding moves the last digit either way. Treating every difference as a markdown
// would fill the feed with noise and make the one real 30%-off announcement invisible.
//
// So a drop has to clear a threshold, and only downward movement counts at all — a brand
// raising a price is a fact nobody wants pushed to their phone.

import Foundation

public enum PriceChange {
    /// A markdown has to be at least this large a share of the old price. 5% clears
    /// exchange-rate drift and rounding while still catching a genuine sale, which
    /// essentially never starts below 10%.
    public static let minimumDropShare = 0.05

    public static func isDrop(from old: Double?, to new: Double?) -> Bool {
        guard let old, let new, old > 0, new > 0, new < old else { return false }
        return (old - new) / old >= minimumDropShare
    }

    /// The same, for two reads that each say what currency they were in.
    ///
    /// **Two numbers in two currencies are not a markdown.** A shop that moves its prices from
    /// dollars to pounds has not cut anything by a fifth, and nothing here converts. A side
    /// that does not say — a row stored before currencies were — is taken to be the same
    /// currency, which is what every comparison assumed until it could know.
    public static func isDrop(from old: Double?, in oldCurrency: String?, to new: Double?, in newCurrency: String?) -> Bool {
        if let oldCurrency, let newCurrency, oldCurrency != newCurrency { return false }
        return isDrop(from: old, to: new)
    }

    /// How much came off, as a whole-number percentage — for "30% OFF" on a card.
    public static func dropPercentage(from old: Double?, to new: Double?) -> Int? {
        guard isDrop(from: old, to: new), let old, let new else { return nil }
        return Int(((old - new) / old * 100).rounded())
    }

    /// What a markdown is measured *from*: the larger of the brand's own original price and
    /// the price the last poll saw, of the two that are a real cut to `now`.
    ///
    /// **The brand's original wins when it is higher**, because "−33%" from the price on the
    /// tag is the claim a shopper can check on the storefront itself, and the poll-to-poll
    /// fall is often only the last step of a markdown taken in two — 180, then 150 for a
    /// week, then 120 reads "−20%" against the poll and "−33%" against the brand. The poll's
    /// price stays the answer for every storefront that publishes no original, which is all
    /// of them but Shopify.
    public static func base(previous: Double?, original: Double?, now: Double?) -> Double? {
        [previous, original]
            .compactMap { $0 }
            .filter { isDrop(from: $0, to: now) }
            .max()
    }

    /// What a price-drop alert says: "Down 33% to €120 — Nathan Cargo Pant".
    ///
    /// Here rather than in either sender, because two send it — the server for something
    /// watched, the phone for something saved — and the same markdown must read the same
    /// whichever path delivered it, the rule `WatchNotifier` keeps with the server's restock
    /// copy.
    public static func alert(title: String, priceText: String?, percent: Int?) -> String {
        switch (percent, priceText) {
        case let (percent?, price?): "Down \(percent)% to \(price) — \(title)"
        case let (percent?, nil): "Down \(percent)% — \(title)"
        case let (nil, price?): "Now \(price) — \(title)"
        case (nil, nil): "Price drop — \(title)"
        }
    }

    /// The same cut as a whole-number percentage, measured from `base`.
    public static func percentOff(previous: Double?, original: Double?, now: Double?) -> Int? {
        dropPercentage(from: base(previous: previous, original: original, now: now), to: now)
    }
}
