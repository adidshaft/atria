import XCTest
@testable import Atria

/// The missed-data banner must never over-promise recovery. It used to show the
/// gap's AGE ("Data gap · 85.4 h") as if that were missing data AND imply a sync
/// would bring it back, when only what is still on the strap ring buffer is
/// actually recoverable. These pin the honest copy mapping.
final class AtriaMissedDataBannerPresentationTests: XCTestCase {
    private func copy(pending: Int,
                      protectsLive: Bool,
                      secondsSinceLastFlush: TimeInterval? = nil,
                      leaseActive: Bool = false) -> AtriaMissedDataBannerPresentation.Copy {
        AtriaMissedDataBannerPresentation.copy(strapPendingRecords: pending,
                                               protectsLiveStream: protectsLive,
                                               secondsSinceLastFlush: secondsSinceLastFlush,
                                               backgroundLeaseActive: leaseActive)
    }

    func testLargeOldGapWithNothingLeftOnStrapIsHonestlyUnrecoverable() {
        // The exact 85.4h-age case: the strap has essentially nothing bankable
        // left, so the banner must NOT offer a (futile) sync and must say it
        // cannot be recovered rather than dangling a scary hours number.
        let c = copy(pending: 90, protectsLive: false) // ~1.5 min on strap
        XCTAssertFalse(c.offersRecovery)
        XCTAssertEqual(c.title, "Some earlier data wasn't recorded")
        // Reassuring, not alarming: it does not affect new data.
        XCTAssertTrue(c.subtitle.lowercased().contains("unaffected"))
        // No misleading number (e.g. the 85.4h gap-age) anywhere in the copy.
        XCTAssertNil(c.title.rangeOfCharacter(from: .decimalDigits))
        XCTAssertNil(c.subtitle.rangeOfCharacter(from: .decimalDigits))
    }

    func testRealBankedBacklogOffersHonestRecoverableAmount() {
        // >= ~5 min still on the strap is genuinely recoverable: offer sync and
        // state the real recoverable amount, not the gap age.
        let c = copy(pending: 20 * 60, protectsLive: false) // 20 min bankable
        XCTAssertTrue(c.offersRecovery)
        XCTAssertEqual(c.title, "Catching up history")
        XCTAssertTrue(c.subtitle.contains("~20 min"))
    }

    func testBoundaryAtRecoverableFloor() {
        let floor = AtriaMissedDataBannerPresentation.recoverableRecordFloor
        XCTAssertTrue(copy(pending: floor, protectsLive: false).offersRecovery)
        XCTAssertFalse(copy(pending: floor - 1, protectsLive: false).offersRecovery)
    }

    func testProtectedLiveStreamNeverReadsAsLost() {
        // Recoverability gates the message even while live HR is protected:
        // with a genuine banked backlog on the strap, live-protected reads as a
        // deferred catch-up (recoverable), never as loss.
        let recoverable = copy(pending: 20 * 60, protectsLive: true)
        XCTAssertTrue(recoverable.offersRecovery)
        XCTAssertEqual(recoverable.title, "Live HR protected")
        // But an OLD gap that is gone stays honestly "wasn't recorded" even while
        // live HR streams — live being fine does not make the old data recoverable.
        let goneWhileLive = copy(pending: 90, protectsLive: true)
        XCTAssertFalse(goneWhileLive.offersRecovery)
        XCTAssertEqual(goneWhileLive.title, "Some earlier data wasn't recorded")
    }

    func testNegativeOrZeroPendingIsClamped() {
        let c = copy(pending: -50, protectsLive: false)
        XCTAssertFalse(c.offersRecovery) // clamps to 0 → unrecoverable branch
    }

    // MARK: - Live drain progress (2026-08-03 device forensics)

    func testRecentDurableFlushReadsAsActivelyDrainingNotStuck() {
        // The bug: a 28-min-stale "~8 min on the strap" read as frozen while the
        // drain was flushing every ~2 min. A recent durable flush must lead with
        // the fresh signal, not the stale pending count.
        let c = copy(pending: 8 * 60, protectsLive: false, secondsSinceLastFlush: 120)
        XCTAssertTrue(c.offersRecovery)
        XCTAssertEqual(c.title, "Catching up history")
        XCTAssertTrue(c.subtitle.contains("synced"))
        XCTAssertTrue(c.subtitle.contains("2m ago"))
        // The stale minutes count is NOT what leads the line anymore.
        XCTAssertFalse(c.subtitle.contains("~8 min"))
    }

    func testActiveDrainOverridesLiveProtectedIdleCopy() {
        // Even while live HR is streaming, a recent flush proves the background
        // lane is draining underneath — so it must say "catching up", not the
        // "when idle" deferral copy that implied nothing was happening.
        let c = copy(pending: 8 * 60, protectsLive: true, secondsSinceLastFlush: 60)
        XCTAssertEqual(c.title, "Catching up history")
        XCTAssertTrue(c.subtitle.lowercased().contains("catching up"))
        XCTAssertFalse(c.subtitle.lowercased().contains("when idle"))
    }

    func testActiveBackgroundLeaseCountsAsDrainingWithoutAFlushTime() {
        let c = copy(pending: 8 * 60, protectsLive: false, secondsSinceLastFlush: nil, leaseActive: true)
        XCTAssertTrue(c.offersRecovery)
        XCTAssertEqual(c.subtitle, "Catching up now")
    }

    func testStaleFlushFallsBackToDeferredCopy() {
        // A flush older than the active window is NOT "actively draining"; with no
        // lease, recoverable-but-idle copy applies.
        let stale = AtriaMissedDataBannerPresentation.activeDrainRecencyWindow + 60
        let c = copy(pending: 8 * 60, protectsLive: false, secondsSinceLastFlush: stale)
        XCTAssertTrue(c.offersRecovery)
        XCTAssertFalse(c.subtitle.contains("synced"))
        XCTAssertTrue(c.subtitle.contains("~8 min"))
    }

    func testRelativeAgoFormatting() {
        XCTAssertEqual(AtriaMissedDataBannerPresentation.relativeAgo(30), "just now")
        XCTAssertEqual(AtriaMissedDataBannerPresentation.relativeAgo(120), "2m ago")
        XCTAssertEqual(AtriaMissedDataBannerPresentation.relativeAgo(3 * 3600), "3h ago")
    }
}
