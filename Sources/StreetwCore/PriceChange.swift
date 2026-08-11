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

    /// How much came off, as a whole-number percentage — for "30% OFF" on a card.
    public static func dropPercentage(from old: Double?, to new: Double?) -> Int? {
        guard isDrop(from: old, to: new), let old, let new else { return nil }
        return Int(((old - new) / old * 100).rounded())
    }
}
