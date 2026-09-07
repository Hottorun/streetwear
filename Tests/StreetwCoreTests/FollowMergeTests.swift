import Foundation
import Testing

@testable import StreetwCore

/// The one decision in `RemoteSync.mergeBrands` that can destroy data, pinned here because
/// the app has no test target of its own.
@Suite("Follow merge")
struct FollowMergeTests {
    /// The failure this exists to stop: a 403 at the edge spends the device token,
    /// `POST /v1/devices` mints an identity with no follows, `GET /v1/follows` correctly
    /// answers `[]`, and the deletion pass reads that as "you unfollowed everything" — every
    /// brand gone and every `BrandUpdate` cascaded away behind it. One refused request.
    @Test("An empty complete list deletes nothing")
    func emptyCompleteListIsRefused() {
        #expect(!FollowMerge.mayPruneAbsent(remoteCount: 0, isCompleteList: true))
    }

    @Test("A complete list with brands in it still prunes")
    func populatedCompleteListPrunes() {
        #expect(FollowMerge.mayPruneAbsent(remoteCount: 1, isCompleteList: true))
    }

    /// A partial batch never speaks for what is absent. `followExisting` calls the merge with
    /// a *single* brand, and reading that as the whole list deleted every other one.
    @Test("A partial batch never prunes, however many brands it holds")
    func partialBatchNeverPrunes() {
        #expect(!FollowMerge.mayPruneAbsent(remoteCount: 1, isCompleteList: false))
        #expect(!FollowMerge.mayPruneAbsent(remoteCount: 40, isCompleteList: false))
    }
}
