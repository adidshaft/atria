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

    func testPostMidnightWorkoutRemainsInTodayUntilConfirmedWake() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Kolkata"))
        let priorWake = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 7, day: 10, hour: 7
        )))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 7, day: 11, hour: 2
        )))
        let afterMidnight = workout(id: "after-midnight",
                                    start: now.addingTimeInterval(-3_600),
                                    zones: ["aerobic": 600])
        let main = confirmedSleep(id: "prior", start: priorWake.addingTimeInterval(-8 * 3_600), end: priorWake)

        let summary = AtriaTodayWorkoutZoneSummary.make(workouts: [afterMidnight],
                                                        confirmedSleeps: [main],
                                                        now: now,
                                                        calendar: calendar)

        XCTAssertEqual(summary.workoutCount, 1)
    }

    func testConfirmedWakeStartsFreshWorkoutSummary() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Kolkata"))
        let wake = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 7, day: 11, hour: 7
        )))
        let beforeWake = workout(id: "before-wake",
                                 start: wake.addingTimeInterval(-5 * 3_600),
                                 zones: ["aerobic": 600])
        let main = confirmedSleep(id: "main", start: wake.addingTimeInterval(-8 * 3_600), end: wake)

        let summary = AtriaTodayWorkoutZoneSummary.make(workouts: [beforeWake],
                                                        confirmedSleeps: [main],
                                                        now: wake.addingTimeInterval(600),
                                                        calendar: calendar)

        XCTAssertEqual(summary.workoutCount, 0)
    }

    private func confirmedSleep(id: String, start: Date, end: Date) -> UserConfirmedSleep {
        UserConfirmedSleep(id: id,
                           createdAt: end,
                           start: start,
                           end: end,
                           source: "manual_sleep",
                           confidence: "user",
                           sessions: 1,
                           samples: 100,
                           avgHR: 52,
                           peakHR: 60,
                           restingHR: 48,
                           hrv: 60,
                           hrvWindowCount: 4,
                           duration: end.timeIntervalSince(start),
                           span: end.timeIntervalSince(start),
                           reason: "test",
                           motionSource: "test",
                           motionValidated: true,
                           stageSegments: nil,
                           eventTimeZoneIdentifier: "Asia/Kolkata")
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
