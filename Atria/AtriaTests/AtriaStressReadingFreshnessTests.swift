import XCTest
@testable import Atria

final class AtriaStressReadingFreshnessTests: XCTestCase {
    func testFreshScoredReadingIsLive() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        XCTAssertEqual(AtriaStressReadingFreshness.resolve(
            isScored: true,
            updatedAt: now.addingTimeInterval(-30),
            now: now
        ), .live)
    }

    func testOldScoredReadingIsStaleInsteadOfLive() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        XCTAssertEqual(AtriaStressReadingFreshness.resolve(
            isScored: true,
            updatedAt: now.addingTimeInterval(-91),
            now: now
        ), .stale)
    }

    func testScoredReadingWithoutClockIsUntimedInsteadOfLive() {
        XCTAssertEqual(AtriaStressReadingFreshness.resolve(
            isScored: true,
            updatedAt: nil
        ), .untimed)
    }

    func testUnscoredStateNeverClaimsLive() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        XCTAssertEqual(AtriaStressReadingFreshness.resolve(
            isScored: false,
            updatedAt: now,
            now: now
        ), .untimed)
    }
}
