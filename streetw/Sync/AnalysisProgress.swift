// How much of the photograph analysis is left, so a screen can say so.
//
// `ImageTagger` is the slowest visible thing the app does — per garment it fetches a
// photograph, decodes it, and runs four Vision requests (human rectangles to find the
// packshot, the foreground mask for the cutout, text recognition, a feature print) — and
// it was entirely silent while doing it. The result is a collection whose tiles are drawn
// to a *guessed* aspect ratio and a fit canvas with no stickers on it, both of which
// resolve on their own a minute later and neither of which says it is going to.
//
// That is the same failure this project keeps writing down in other places: a thing that
// is working and invisible is indistinguishable from a thing that is broken. The wall
// reflowing under you with no explanation is worse than a wall that says it is still
// reading.
//
// Deliberately a count and not a fraction. A fraction needs a stable denominator, and the
// denominator here genuinely moves: `SharedSaveImporter.repair` fills in real photographs
// on some later foreground and every one of those rows becomes due again. Counting what is
// left is honest about that, where a progress bar sliding backwards is not.

import Foundation
import Observation

/// Observable state for the analysis pass. One instance, owned by `ImageTagger`.
@MainActor
@Observable
final class AnalysisProgress {
    /// Photographs still to get through, or nil when nothing is running.
    private(set) var remaining: Int?

    /// True while there is work in flight. The screens read this rather than
    /// `remaining != nil` so the intent at the call site says what it means.
    var isRunning: Bool { remaining != nil }

    func begin(_ count: Int) {
        // A drain that finds nothing due must not flash a line saying so. This is called on
        // every foreground of two different tabs and the overwhelmingly common answer is
        // that there is no work.
        remaining = count > 0 ? count : nil
    }

    func advance(to count: Int) {
        guard remaining != nil else { return }
        remaining = count > 0 ? count : nil
    }

    func finish() {
        remaining = nil
    }
}
