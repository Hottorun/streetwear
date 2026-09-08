// PushGrouping.swift
// The one string that decides how Dropwall's notifications stack, read by both ends.
//
// iOS groups notifications by thread identifier *within* an app. That makes this value a
// contract rather than a detail: every path that can raise an alert has to use the same
// string, or the app produces two piles on the lock screen and neither is wrong on its own.
//
// It lives here for the reason `WatchTarget` does — both ends need it and there is no way
// to notice that they have stopped agreeing. Three paths raise alerts and they are in three
// different targets: the server's APNs sender, the drop-calendar reminders, and the local
// stock-watch notifier that fires with no server involved. Two of them once said "streetw"
// and the third threaded by brand id, with a comment claiming it matched the server. It did
// not, and had not for as long as the constant existed:
//
// - a push about a restock landed in the app's stack
// - a *locally* fired watch about the same restock landed in a stack of that brand's own
//
// which is precisely the per-brand split the single-thread rule was written to end, arriving
// by the one route nobody had checked. A shared constant makes that failure impossible to
// reintroduce without deleting this file.
//
// **Grouping is not throttling.** Stopping one brand from shouting is `collapseID`, which
// stays per brand and is a different knob; these two were confused for each other once
// already. Changing the value here is safe — iOS only uses it to decide what stacks with
// what — but change it in one place and every path moves together, which is the point.

import Foundation

public enum PushGrouping {
    /// The notification thread every Dropwall alert belongs to.
    public static let threadID = "Dropwall"
}
