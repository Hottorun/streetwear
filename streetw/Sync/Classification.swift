// Classification.swift
// Bringing stored verdicts up to the current classifier, in the background, a few at a time.
//
// `BrandUpdate.gender` is stored beside the revision that produced it and **re-derived on
// the spot when the two disagree** — which is exactly right for correctness and quietly
// expensive as a steady state. The mismatch is not the exception: the server stamps its own
// revision on every feed row, so the moment the phone ships a better classifier than the
// deployment, every server-supplied row in the store is stale and stays stale. `gender` has
// no memory, so each read re-runs `GenderClassifier` over the title, the product type, the
// tags and the URL handle.
//
// That is a few microseconds nobody would notice, multiplied by every unseen update of every
// followed brand, on every evaluation of a view body — and SwiftUI evaluates bodies for
// reasons that have nothing to do with this data. Marking one brand read writes a row per
// update, invalidates the `@Query`, and re-renders the feed, which re-classified the entire
// store before it could draw a frame. That is the lag.
//
// The fix is not to stop re-deriving — a stale verdict is worse than none, which is the
// whole reason the version exists. It is to let the re-derivation *stick*: `refreshGender`
// writes the local classifier's answer with the local revision beside it, which is honest
// (this build did produce that answer) and is precisely what the warning in CLAUDE.md
// forbids doing to a **server-supplied** raw value. Nothing here adopts somebody else's
// verdict; it recomputes and records its own.
//
// Bounded per pass and run off the render path, so a store with ten thousand rows converges
// over a few foregrounds instead of blocking one.

import Foundation
import OSLog
import StreetwCore
import SwiftData

@MainActor
enum Classification {
    private static let log = Logger(subsystem: "com.kern.functional.streetw", category: "classify")

    /// How many stale rows to settle per pass.
    ///
    /// Large enough that a normal store converges in one go, small enough that a store built
    /// up over months does not stall a foreground. Each row is pure string work over fields
    /// already faulted in — there is no network and no image decoding here.
    private static let batch = 500

    /// Rewrites the gender of rows classified by an older revision. Returns how many.
    @discardableResult
    static func settleGenders(in context: ModelContext, limit: Int = batch) -> Int {
        let current = GenderClassifier.version
        var descriptor = FetchDescriptor<BrandUpdate>(
            predicate: #Predicate { $0.genderVersion != current }
        )
        descriptor.fetchLimit = limit

        let stale = (try? context.fetch(descriptor)) ?? []
        guard !stale.isEmpty else { return 0 }

        for update in stale { update.refreshGender() }
        try? context.save()
        log.info("settled gender on \(stale.count) rows at revision \(current)")
        return stale.count
    }
}
