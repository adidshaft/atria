import XCTest
@testable import Atria

final class AtriaTodayHRZoneRefreshTests: XCTestCase {
    func testContinuousArchiveUpdatesKeepPendingRefreshAndRequestTrailingRun() {
        XCTAssertFalse(SessionStore.historicalArchiveRefreshNeedsTrailingRun(
            hasPendingRefresh: false
        ))
        XCTAssertTrue(SessionStore.historicalArchiveRefreshNeedsTrailingRun(
            hasPendingRefresh: true
        ))
    }

    func testCheckpointRefreshCadenceIsImmediateThenOncePerMinute() {
        let first = Date(timeIntervalSince1970: 10_000)

        XCTAssertTrue(SessionStore.shouldRefreshTodayHRZoneMinutesOnCheckpoint(
            lastRefreshAt: nil,
            now: first
        ))
        XCTAssertFalse(SessionStore.shouldRefreshTodayHRZoneMinutesOnCheckpoint(
            lastRefreshAt: first,
            now: first.addingTimeInterval(59.999)
        ))
        XCTAssertTrue(SessionStore.shouldRefreshTodayHRZoneMinutesOnCheckpoint(
            lastRefreshAt: first,
            now: first.addingTimeInterval(60)
        ))
    }

    func testCrossMidnightSessionUsesOnlyTodayPointsAndIgnoresArrayOrder() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Kolkata"))
        let today = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 7, day: 10, hour: 12
        )))
        let crossMidnightStart = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 7, day: 9, hour: 23, minute: 50
        )))
        let oldStart = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 7, day: 8, hour: 10
        )))
        let futureStart = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 7, day: 11, hour: 10
        )))
        let crossMidnight = session(
            start: crossMidnightStart,
            duration: 40 * 60,
            points: stride(from: 0, through: 40 * 60, by: 60).map {
                SavedSession.Point(t: Double($0), bpm: 140)
            }
        )
        let old = session(start: oldStart, duration: 10 * 60,
                          points: [SavedSession.Point(t: 0, bpm: 90)])
        let future = session(start: futureStart, duration: 10 * 60,
                             points: [SavedSession.Point(t: 0, bpm: 90)])

        let summary = SessionStore.makeTodayHRZoneMinutes(
            sessions: [future, crossMidnight, old],
            maxHR: 200,
            now: today,
            calendar: calendar
        )

        XCTAssertTrue(summary.hasSamples)
        XCTAssertGreaterThan(summary.activeMinutes, 0)
        XCTAssertLessThanOrEqual(summary.activeMinutes, 30)
    }

    func testTodayZonesDoNotBridgeExplicitShortPause() {
        let start = Date(timeIntervalSince1970: 1_800_200_000)
        let workout = SavedSession(
            id: UUID(),
            start: start,
            end: start.addingTimeInterval(70),
            label: "Paused workout",
            points: [0.0, 10, 20, 50, 60, 70].map { SavedSession.Point(t: $0, bpm: 160) },
            excludedIntervals: [ExcludedInterval(start: start.addingTimeInterval(20),
                                                 end: start.addingTimeInterval(50))]
        )

        let summary = SessionStore.makeTodayHRZoneMinutes(sessions: [workout],
                                                           maxHR: 190,
                                                           now: start)

        XCTAssertEqual(summary.activeMinutes, 0,
                       "Two 10-second segments round to zero; the pause must not be counted or bridged")
    }

    private func session(start: Date,
                         duration: TimeInterval,
                         points: [SavedSession.Point]) -> SavedSession {
        SavedSession(
            id: UUID(),
            start: start,
            end: start.addingTimeInterval(duration),
            label: "All-day wear",
            points: points,
            hrv: nil,
            activeCalories: nil,
            caloriesConfidence: "estimate"
        )
    }
}
