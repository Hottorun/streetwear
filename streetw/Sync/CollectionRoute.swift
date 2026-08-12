// CollectionRoute.swift
// Opening the collection *at* something, from somewhere else in the app.
//
// The Style tab's taste block reads "Black, Brown, Burgundy, Green" — the app's own
// account of what you like — and until now that was where it ended. A statement with
// nothing to do about it, on a page whose whole subject is you.
//
// A facet is really a query over the collection, so tapping one should run it. That needs
// a way for one tab to ask another to open somewhere, which is what this is: the same
// shape as `PushRoute`, built in `streetwApp.init` for the same reason — a view that reads
// it appears before anything could have set it, and creating it asynchronously would race
// with the `.task` that consumes it.

import Foundation
import SwiftUI

@MainActor
@Observable
final class CollectionRoute {
    /// What the collection is narrowed to, or nil for the whole thing.
    ///
    /// Read *and cleared* by `SavedView`, which owns the display of it. Left set, a
    /// second tap on the same facet would be a no-op — the value would not change, so
    /// nothing would observe it — which is exactly the sort of control that feels broken
    /// the second time you use it.
    var facet: CollectionFacet?

    /// Bumped on every request, so asking for the facet you are already looking at still
    /// switches tabs. The facet alone cannot do that job: it is unchanged, and an
    /// unchanged value publishes nothing.
    private(set) var requests = 0

    func open(_ facet: CollectionFacet) {
        self.facet = facet
        requests += 1
    }

    func clear() {
        facet = nil
    }
}
