import XCTest
@testable import Atria

/// WP-2 / GAP-02 — one canonical Sleep Consistency engine: recorded-timezone
/// civil times, fail-closed qualification, and a single result object that the
/// score, schedule visual, and copy all consume.
final class AtriaSleepConsistencyEngineTests: XCTestCase {
    private let newYork = TimeZone(identifier: "America/New_York")!

    /// A confirmed 7h main sleep whose *New York* civil bedtime is 23:00 on
    /// the given date, regardless of the machine's current timezone.
    private func newYorkNight(id: String,
                              year: Int, month: Int, day: Int,
                              bedHour: Int = 23, bedMinute: Int = 0,
                              hours: Double = 7,
                              timeZoneIdentifier: String? = "America/New_York") -> UserConfirmedSleep {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = newYork
        let start = DateComponents(calendar: calendar,
                                   timeZone: newYork,
                                   year: year, month: month, day: day,
                                   hour: bedHour, minute: bedMinute).date!
        return UserConfirmedSleep(id: id,
                                  createdAt: start,
                                  start: start,
                                  end: start.addingTimeInterval(hours * 3_600),
                                  source: "manual_sleep",
                                  confidence: "manual_user_entered",
                                  sessions: 1,
                                  samples: 100,
                                  avgHR: 52,
                                  peakHR: 60,
                                  restingHR: 50,
                                  hrv: 60,
                                  hrvWindowCount: 4,
                                  duration: hours * 3_600,
                                  span: hours * 3_600,
                                  reason: "test",
                                  motionSource: "manual",
                                  motionValidated: false,
                                  stageSegments: nil,
                                  eventTimeZoneIdentifier: timeZoneIdentifier)
    }

    private func nights(from sleeps: [UserConfirmedSleep]) -> [SleepHistorySnapshot.Night] {
        SleepHistorySnapshot(rollups: [], confirmedSleeps: sleeps).nights
    }

    func testRecordedTimezoneKeepsCivilTimesWhereverThePhoneIs() {
        // Five identical New York nights. The machine running this test is NOT
        // in New York — if the engine ever fell back to the current timezone,
        // the civil bedtime would shift away from 23:00.
        let sleeps = (1...5).map { newYorkNight(id: "ny-\($0)", year: 2026, month: 8, day: $0) }
        let result = AtriaSleepConsistency.result(from: nights(from: sleeps))

        XCTAssertEqual(result.qualifiedNightCount, 5)
        XCTAssertEqual(result.typicalBedtimeMinutes, 23 * 60,
                       "bedtime must be read in the event's recorded zone, not the phone's")
        XCTAssertEqual(result.typicalWakeTimeMinutes, 6 * 60 + 24 * 60,
                       "a 6 AM New York wake anchors to next-day civil minutes")
        XCTAssertEqual(result.combinedPercent, 100,
                       "identical schedules are perfectly regular")
    }

    func testNightWithoutRecordedTimezoneDoesNotQualify() {
        var sleeps = (1...4).map { newYorkNight(id: "tz-\($0)", year: 2026, month: 8, day: $0) }
        sleeps.append(newYorkNight(id: "legacy-nil-tz", year: 2026, month: 8, day: 5,
                                   timeZoneIdentifier: nil))
        let result = AtriaSleepConsistency.result(from: nights(from: sleeps))

        XCTAssertEqual(result.qualifiedNightCount, 4,
                       "a legacy night with no recorded zone cannot prove its civil times and must not qualify")
        XCTAssertNil(result.combinedPercent)
        XCTAssertFalse(result.deviations.contains { $0.id == "legacy-nil-tz" })
    }

    func testQualificationBoundaryIsExactlyMinimumQualifiedNights() {
        let four = (1...4).map { newYorkNight(id: "b-\($0)", year: 2026, month: 8, day: $0) }
        let fourResult = AtriaSleepConsistency.result(from: nights(from: four))
        XCTAssertNil(fourResult.combinedPercent)
        XCTAssertEqual(fourResult.qualifiedNightCount, 4)
        XCTAssertTrue(fourResult.deviations.isEmpty)
        XCTAssertTrue(fourResult.footnote.contains("\(AtriaSleepConsistency.minimumQualifiedNights)"))

        let five = (1...5).map { newYorkNight(id: "b-\($0)", year: 2026, month: 8, day: $0) }
        let fiveResult = AtriaSleepConsistency.result(from: nights(from: five))
        XCTAssertNotNil(fiveResult.combinedPercent)
        XCTAssertEqual(fiveResult.deviations.count, 5)
    }

    func testDeviationsCarryDaysAndLatestNightIsTheNewest() {
        let sleeps = (1...6).map { newYorkNight(id: "d-\($0)", year: 2026, month: 8, day: $0) }
        let result = AtriaSleepConsistency.result(from: nights(from: sleeps))

        XCTAssertEqual(result.latestNight?.id, "d-6",
                       "latestNight must be the newest qualified night by wake day")
        let days = Set(result.deviations.map(\.day))
        XCTAssertEqual(days.count, 6, "every deviation carries its own wake day")
    }

    func testRecommendedWindowIsMedianWakeMinusClampedTarget() {
        let sleeps = (1...5).map { newYorkNight(id: "r-\($0)", year: 2026, month: 8, day: $0) }
        let result = AtriaSleepConsistency.result(from: nights(from: sleeps),
                                                  targetSleepHours: 8)
        let medianWake = 6 * 60 + 24 * 60   // identical nights → median = 6 AM anchored
        XCTAssertEqual(result.recommendedWindow,
                       .init(bedtimeMinutes: medianWake - 8 * 60, wakeMinutes: medianWake))

        let unclamped = AtriaSleepConsistency.result(from: nights(from: sleeps),
                                                     targetSleepHours: 14)
        XCTAssertEqual(unclamped.recommendedWindow?.bedtimeMinutes, medianWake - 10 * 60,
                       "target clamps to the 6–10h band the ledger uses")

        XCTAssertNil(AtriaSleepConsistency.result(from: nights(from: sleeps)).recommendedWindow,
                     "no configured target → no invented window")
    }

    /// The schedule visual and the glance copy must keep consuming the one
    /// engine — these pins fail if a parallel calculation sneaks back in.
    func testConsumersStayOnTheCanonicalEngine() throws {
        let appDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria")

        let health = try String(contentsOf: appDirectory.appendingPathComponent("AtriaHealthScreen.swift"),
                                encoding: .utf8)
        XCTAssertTrue(health.contains("return consistency.deviations"),
                      "strip rows must come from the engine's qualified deviations")
        XCTAssertFalse(health.contains("nights.prefix(14).compactMap"),
                       "the strip must not re-filter nights in parallel with the engine")
        XCTAssertTrue(health.contains("night.id == latestID"),
                      "the latest qualified night must be visually identifiable")

        let today = try String(contentsOf: appDirectory.appendingPathComponent("AtriaTodayScreen.swift"),
                               encoding: .utf8)
        XCTAssertTrue(today.contains("Needs \\(AtriaSleepConsistency.minimumQualifiedNights) nights"),
                      "glance empty-state copy must quote the engine's real minimum")
        XCTAssertFalse(today.contains("Needs 2 nights"))
    }
}
