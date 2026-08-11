// StockWatch.swift
// "Tell me when this comes back."
//
// The one thing a drop tracker can do that a bookmark cannot. A save says *I like this*;
// a watch says *I would buy this, in this size, in this colour, and it is not for sale
// right now*. That is a far more specific statement, and it is the only one that
// justifies waking someone's phone.
//
// Scoped deliberately narrowly. Watching "this product" is close to useless on a garment
// that runs XS–XXL in four colourways: it fires on someone else's size and trains you to
// ignore it. The watch is therefore a *predicate over variants* — optionally pinned to a
// size, a colour, or both — and fires only when a variant satisfying all of it goes from
// sold out to buyable.

import Foundation
import StreetwCore
import SwiftData

@Model
final class StockWatch {
    var id: UUID = UUID()
    var update: BrandUpdate?
    var createdAt: Date = Date()

    /// Nil means "any size". Stored as the raw catalogue string rather than a normalised
    /// token so the UI can echo back exactly what the storefront calls it — a brand's
    /// "9.5W" is not ours to rewrite — while matching still goes through `SizeNormalizer`.
    var size: String?
    /// Nil means "any colour".
    var color: String?

    /// Set once the watch has fired, so it can be shown as satisfied and stop matching.
    /// A watch is not deleted when it fires: seeing that the thing you waited for came
    /// back is the point, and a row that vanishes at the moment it succeeds is a worse
    /// experience than one that says so.
    var firedAt: Date?
    /// What was actually back when it fired, for the notification and the row.
    var firedSizes: [String] = []

    /// Mirrored on the server so the poller can push without the app being open. Nil in
    /// standalone mode, and nil until the create call returns.
    var remoteID: UUID?

    /// The availability this watch last observed, so firing is edge-triggered rather than
    /// level-triggered. Without it, every sync while the item is in stock is another
    /// alert about the same restock.
    var wasAvailable: Bool = false

    init(update: BrandUpdate?, size: String? = nil, color: String? = nil) {
        self.id = UUID()
        self.update = update
        self.size = size
        self.color = color
        self.createdAt = Date()
        // Anything already buyable is the *baseline*, not news — the same rule that stops
        // a brand's first sync dumping its back catalogue into the feed. Watching
        // something in stock and being told immediately that it is in stock is noise.
        self.wasAvailable = WatchTarget(size: size, color: color)
            .isSatisfied(by: update?.variants ?? [])
    }

    var isActive: Bool { firedAt == nil }

    /// The pins, in the shared form both the app and the server evaluate.
    var target: WatchTarget { WatchTarget(size: size, color: color) }

    /// How the watch reads in a list: "M · Black", "US 9", "Any size or colour".
    var summary: String { target.summary }

    /// Variants this watch is about — the ones matching its size and colour pins.
    func matching(_ variants: [VariantInfo]) -> [VariantInfo] { target.matching(variants) }

    /// Whether anything this watch cares about is buyable right now.
    func isSatisfied(by variants: [VariantInfo]) -> Bool { target.isSatisfied(by: variants) }
}
