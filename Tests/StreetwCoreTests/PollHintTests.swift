import Foundation
import Testing

@testable import StreetwCore

@Suite("Poll hints")
struct PollHintTests {
    /// The instant the window opens and the instant it closes both count. Off-by-one at
    /// either end is a hint that is silently a minute short of what it claims.
    @Test func windowIncludesItsOwnEdges() {
        let release = Date()
        #expect(PollHintPolicy.isActive(
            releaseAt: release,
            now: release.addingTimeInterval(-PollHintPolicy.windowBefore)
        ))
        #expect(PollHintPolicy.isActive(
            releaseAt: release,
            now: release.addingTimeInterval(PollHintPolicy.windowAfter)
        ))
        #expect(PollHintPolicy.isActive(releaseAt: release, now: release))
    }

    @Test func windowExcludesEitherSideOfItself() {
        let release = Date()
        #expect(!PollHintPolicy.isActive(
            releaseAt: release,
            now: release.addingTimeInterval(-PollHintPolicy.windowBefore - 1)
        ))
        #expect(!PollHintPolicy.isActive(
            releaseAt: release,
            now: release.addingTimeInterval(PollHintPolicy.windowAfter + 1)
        ))
    }

    /// The whole point of the bound: one hint is an hour of fast polling and can never be
    /// more, because the client cannot name a window at all.
    @Test func oneHintIsAtMostAnHour() {
        #expect(PollHintPolicy.windowLength <= 3600)
    }

    /// A drop somebody is writing down as it happens is still worth hinting — its window is
    /// open. One that finished this morning is not.
    @Test func aDropInProgressIsStillAcceptable() {
        let now = Date()
        #expect(PollHintPolicy.isAcceptable(releaseAt: now.addingTimeInterval(-60), now: now))
        #expect(!PollHintPolicy.isAcceptable(
            releaseAt: now.addingTimeInterval(-PollHintPolicy.windowAfter - 60),
            now: now
        ))
    }

    @Test func aDateBeyondTheLeadTimeIsRefused() {
        let now = Date()
        #expect(PollHintPolicy.isAcceptable(
            releaseAt: now.addingTimeInterval(PollHintPolicy.maxLeadTime - 86_400),
            now: now
        ))
        #expect(!PollHintPolicy.isAcceptable(
            releaseAt: now.addingTimeInterval(PollHintPolicy.maxLeadTime + 86_400),
            now: now
        ))
    }

    /// `activeRange` is what the poll queue actually filters on — a range over the stored
    /// column rather than arithmetic per row — so it has to agree with `isActive` exactly.
    /// If these two ever disagree, the poller reads a different window from the one this
    /// file documents and nothing anywhere would say so.
    @Test func theQueryRangeAgreesWithTheWindow() {
        let now = Date()
        let range = PollHintPolicy.activeRange(at: now)

        for offset in stride(from: -7200.0, through: 7200.0, by: 60) {
            let release = now.addingTimeInterval(offset)
            #expect(
                range.contains(release) == PollHintPolicy.isActive(releaseAt: release, now: now),
                "disagreed at offset \(offset)"
            )
        }
    }

    /// A refusal names a fix. Empty strings here would leave the client with "rejected" and
    /// nothing to do about it, which is the failure this whole shape exists to avoid.
    @Test func everyRefusalSaysSomething() {
        for reason in [
            PollHintPolicy.Rejection.notFollowing,
            .unknownBrand,
            .outOfRange,
            .tooMany
        ] {
            #expect(!reason.reason.isEmpty)
            #expect(!reason.rawValue.isEmpty)
        }
    }
}
