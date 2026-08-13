// BrandDismissal.swift
// "Not this one" — the only negative signal in the app.
//
// Everything else streetw knows about taste is positive: what you followed, what you
// saved. That is a real gap, and not only because the same wrong brand kept coming back
// every time the list refreshed. A recommender with no way to be told it is wrong can only
// ever be corrected by *not* acting, which is indistinguishable from not having looked.
//
// A dismissal does two things, and the second is the one worth having:
//
// 1. The brand never appears in the block again.
// 2. Brands that *resemble* it are demoted — see `Recommender.repulsion(from:)`. One tap
//    on a technical-outdoor label should quiet the other four, or the feature is just a
//    hide button and the user has to press it five times.
//
// Local, and deliberately so. This is the same rule the taste vector already follows: the
// server ships candidates with their vectors and the comparison happens on the phone, so
// nothing about what somebody rejected is ever uploaded. A dismissal is a more revealing
// statement than a follow, not a less revealing one.
//
// Keyed by `remoteID` rather than by a relationship: a dismissed brand is by definition one
// that was never followed, so there is no local `Brand` row to point at.

import Foundation
import StreetwCore
import SwiftData

@Model
final class BrandDismissal {
    /// The catalog id. The only stable handle on a brand this device does not store.
    var remoteID: UUID = UUID()
    /// Kept so the vector can be re-read if the shape of `BrandVector` changes, and so a
    /// dismissal list can be shown as words rather than as ids.
    var name: String = ""
    var dismissedAt: Date = Date()

    /// The brand's vector as it stood when it was refused, JSON-encoded.
    ///
    /// Stored rather than re-fetched because the whole point is to keep working after the
    /// brand has dropped off the candidate list — which is exactly what dismissing it
    /// causes. Encoded to `Data` rather than held as a Codable struct: SwiftData decodes a
    /// stored Codable with an internal `try!`, so a field added to `BrandVector` later
    /// would be a crash on launch rather than a migration. Decoding by hand means a shape
    /// this build cannot read is one dismissal that stops steering, not a dead app.
    var vectorData: Data?

    init(remoteID: UUID, name: String, vector: BrandVector? = nil) {
        self.remoteID = remoteID
        self.name = name
        self.dismissedAt = Date()
        self.vectorData = vector.flatMap { try? JSONEncoder().encode($0) }
    }

    var vector: BrandVector? {
        vectorData.flatMap { try? JSONDecoder().decode(BrandVector.self, from: $0) }
    }
}
