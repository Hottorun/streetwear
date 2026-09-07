// FollowMerge.swift
// The one decision in merging a follow list that can destroy data.

import Foundation

/// Whether a batch of brands from the server may be treated as authority over what is
/// *absent*.
///
/// `RemoteSync.mergeBrands` deletes any local brand the server did not mention, which is
/// correct for `GET /v1/follows` and cascades away every `BrandUpdate` behind it. The rule
/// lives here rather than inline because it is the difference between a sync and a wipe,
/// and because the app has no test target — this way the guard can be pinned.
public enum FollowMerge {
    /// - Parameters:
    ///   - remoteCount: how many brands the server named.
    ///   - isCompleteList: whether the batch claims to be the *whole* follow list.
    ///
    /// An empty complete list is refused. It is indistinguishable from a failure that
    /// produced no rows — a 403 at the edge, a device row the server has forgotten and
    /// silently re-issued, a deploy answering with an empty body — and the two readings
    /// have wildly asymmetric costs: refusing costs one stale brand until the next sync,
    /// obeying costs the user everything they were watching and every event behind it.
    /// Somebody who genuinely unfollows their last brand sees it disappear the moment they
    /// do it locally, so nothing here is what makes that work.
    public static func mayPruneAbsent(remoteCount: Int, isCompleteList: Bool) -> Bool {
        isCompleteList && remoteCount > 0
    }
}
