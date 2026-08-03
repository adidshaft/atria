import XCTest
@testable import Atria

/// The missed-data banner must never over-promise recovery. It used to show the
/// gap's AGE ("Data gap · 85.4 h") as if that were missing data AND imply a sync
/// would bring it back, when only what is still on the strap ring buffer is
/// actually recoverable. These pin the honest copy mapping.
final class AtriaMissedDataBannerPresentationTests: XCTestCase {
    private func copy(pending: Int, protectsLive: Bool) -> AtriaMissedDataBannerPresentation.Copy {
        AtriaMissedDataBannerPresentation.copy(strapPendingRecords: pending,
                                               protectsLiveStream: protectsLive)
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
        // While live HR is being protected, catch-up is deferred, not lost —
        // never tell the user their data is gone in this state.
        let withData = copy(pending: 90, protectsLive: true)
        XCTAssertTrue(withData.offersRecovery)
        XCTAssertEqual(withData.title, "Live HR protected")
        let caughtUp = copy(pending: 0, protectsLive: true)
        XCTAssertTrue(caughtUp.offersRecovery)
        XCTAssertTrue(caughtUp.subtitle.lowercased().contains("up to date"))
    }

    func testNegativeOrZeroPendingIsClamped() {
        let c = copy(pending: -50, protectsLive: false)
        XCTAssertFalse(c.offersRecovery) // clamps to 0 → unrecoverable branch
    }
}
