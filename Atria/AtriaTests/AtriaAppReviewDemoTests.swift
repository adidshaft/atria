import XCTest
@testable import Atria

@MainActor
final class AtriaAppReviewDemoTests: XCTestCase {
    func testReservedReviewerNicknameIgnoresCaseAndWhitespace() {
        XCTAssertTrue(AtriaAppReviewDemo.isRequested(nickname: "App Review"))
        XCTAssertTrue(AtriaAppReviewDemo.isRequested(nickname: "  app review  "))
        XCTAssertFalse(AtriaAppReviewDemo.isRequested(nickname: "AppReviewer"))
        XCTAssertFalse(AtriaAppReviewDemo.isRequested(nickname: "Review"))
    }

    func testFixtureProvidesRollingLocalHistoryAcrossSurfaces() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026,
                                                      month: 8,
                                                      day: 14,
                                                      hour: 12))!

        let sessions = AtriaAppReviewDemo.sessions(now: now, calendar: calendar)
        let metrics = AtriaAppReviewDemo.dailyMetrics(now: now, calendar: calendar)
        let sleeps = AtriaAppReviewDemo.confirmedSleeps(now: now, calendar: calendar)
        let workouts = AtriaAppReviewDemo.confirmedWorkouts(now: now, calendar: calendar)
        let rollups = AtriaAppReviewDemo.rollups(now: now, calendar: calendar)

        XCTAssertEqual(metrics.count, 14)
        XCTAssertEqual(sleeps.count, 14)
        XCTAssertEqual(rollups.count, 14)
        XCTAssertEqual(workouts.count, 4)
        XCTAssertGreaterThan(sessions.count, metrics.count)
        XCTAssertTrue(metrics.allSatisfy {
            $0.recoveryPercent != nil
                && $0.sleepDuration != nil
                && $0.strainEvidenceQuality == .exact
        })
        XCTAssertTrue(sessions.allSatisfy { $0.end <= now })
    }
}
