import XCTest
@testable import Atria

final class AtriaTodayWorkoutZoneSummaryTests: XCTestCase {
    func testSummaryBuildsCountHighZonesAndHistogramOnce() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Kolkata"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 7, day: 10, hour: 12
        )))
        let todayStart = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 7, day: 10, hour: 8
        )))
        let oldStart = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: todayStart))
        let today = workout(id: "today", start: todayStart,
                            zones: ["fatBurn": 600, "aerobic": 300, "max": 60])
        let old = workout(id: "old", start: oldStart,
                          zones: ["anaerobic": 3_600])

        let summary = AtriaTodayWorkoutZoneSummary.make(
            workouts: [old, today],
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(summary.workoutCount, 1)
        XCTAssertEqual(summary.highZoneSeconds, 360)
        XCTAssertEqual(summary.histogram.map(\.zone), [.fatBurn, .aerobic, .max])
        XCTAssertEqual(summary.histogram.map(\.minutes), [10, 5, 1])
    }

    private func workout(id: String,
                         start: Date,
                         zones: [String: TimeInterval]) -> UserConfirmedWorkout {
        UserConfirmedWorkout(
            id: id,
            createdAt: start,
            start: start,
            end: start.addingTimeInterval(60 * 60),
            label: "Workout",
            source: "test",
            confidence: "high",
            sessions: 1,
            samples: 60,
            avgHR: 130,
            peakHR: 160,
            p95HR: 155,
            p99HR: 160,
            thresholdHR: 120,
            streamCoveragePercent: 100,
            observedDuration: 60 * 60,
            reason: "test",
            zoneSeconds: zones,
            eventTimeZoneIdentifier: "Asia/Kolkata"
        )
    }
}
