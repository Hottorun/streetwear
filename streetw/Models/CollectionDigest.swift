// CollectionDigest.swift
// One integer that changes when anything a reading of the collection depends on changes.
//
// Two pages derive expensive things from every save — the taste reading on You, and the fit
// row on Saved › Fits — and both hold the answer behind a fingerprint rather than rebuilding it
// per `body` (see `docs/performance.md`). They must agree about what counts as a change, so the
// digest is written once.

import Foundation

enum CollectionDigest {
    /// Everything the derivations read that can actually *change* after a save exists.
    ///
    /// Deliberately shallow. Title, tags and product type are written once when a row arrives
    /// and never edited, so they are covered by the item being present at all; what moves
    /// underneath a standing collection is the photograph analysis, and every field it writes
    /// is stamped by one of these three versions. `savedAt` catches a save being replaced rather
    /// than added, which a count alone would miss.
    ///
    /// `brand` is left out on purpose: reading it here would fault the relationship for every
    /// save on every `body`, which is the cost this exists to avoid. A brand attached after the
    /// fact — `SharedSaveImporter.attachBrands` healing an old row — therefore shows up on the
    /// next change rather than instantly, which is the right trade for a facet nobody is
    /// watching at that moment.
    static func of(_ saves: [SavedItem]) -> Int {
        var hasher = Hasher()
        for save in saves {
            hasher.combine(save.id)
            hasher.combine(save.savedAt)
            hasher.combine(save.type)
            guard let update = save.update else { continue }
            hasher.combine(update.analyzedAt)
            hasher.combine(update.visionVersion)
            hasher.combine(update.cutoutVersion)
        }
        return hasher.finalize()
    }
}
