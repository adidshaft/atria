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

/// Issue #41 — the centre must live on the 24h clock. A fixed noon cut split
/// an afternoon sleeper's nights across two days and the arithmetic mean of a
/// bimodal set named a bedtime nobody had. These pin the circular engine.
final class AtriaSleepConsistencyCircularClockTests: XCTestCase {
    private let newYork = TimeZone(identifier: "America/New_York")!

    private func night(_ id: String, day: Int, bedHour: Int, bedMinute: Int, hours: Double = 6) -> UserConfirmedSleep {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = newYork
        let start = DateComponents(calendar: calendar, timeZone: newYork,
                                   year: 2026, month: 8, day: day,
                                   hour: bedHour, minute: bedMinute).date!
        return UserConfirmedSleep(id: id, createdAt: start, start: start,
                                  end: start.addingTimeInterval(hours * 3_600),
                                  source: "manual_sleep", confidence: "manual_user_entered",
                                  sessions: 1, samples: 100, avgHR: 52, peakHR: 60, restingHR: 50,
                                  hrv: 60, hrvWindowCount: 4, duration: hours * 3_600, span: hours * 3_600,
                                  reason: "test", motionSource: "manual", motionValidated: false,
                                  stageSegments: nil, eventTimeZoneIdentifier: "America/New_York")
    }

    private func result(_ sleeps: [UserConfirmedSleep]) -> AtriaSleepConsistency {
        AtriaSleepConsistency.result(from: SleepHistorySnapshot(rollups: [], confirmedSleeps: sleeps).nights)
    }

    func testAfternoonMainSleepGetsAnAfternoonCentreAndAPlottableAxis() {
        // The owner's real shape: main sleep starting early afternoon.
        let sleeps = [(13, 15), (13, 55), (12, 40), (14, 5), (13, 30)].enumerated().map { index, time in
            night("pm-\(index)", day: index + 1, bedHour: time.0, bedMinute: time.1)
        }
        let result = result(sleeps)

        let typical = try! XCTUnwrap(result.typicalBedtimeMinutes)
        XCTAssertTrue((12 * 60 + 40...14 * 60 + 5).contains(typical),
                      "the centre must sit inside the cluster, got \(AtriaSleepConsistency.clockText(typical))")
        XCTAssertGreaterThanOrEqual(result.combinedPercent ?? 0, 70,
                                    "a 85-minute-wide cluster is a steady schedule, not 0%")
        XCTAssertEqual(result.scheduleAxisStartMinutes, 8 * 60,
                       "axis starts five hours before the centre, on the hour")
        for deviation in result.deviations {
            XCTAssertGreaterThanOrEqual(deviation.bedtimeMinutes, result.scheduleAxisStartMinutes)
            XCTAssertLessThanOrEqual(deviation.wakeMinutes, result.scheduleAxisStartMinutes + 18 * 60,
                                     "every qualified night must fit the strip's 18h axis")
        }
    }

    func testNightsFortyMinutesApartAcrossNoonAreNotADayApart() {
        // 11:28 and 12:08 used to land 23.3 hours apart.
        let sleeps = [(11, 28), (12, 8), (11, 50), (12, 20), (11, 40)].enumerated().map { index, time in
            night("noon-\(index)", day: index + 1, bedHour: time.0, bedMinute: time.1)
        }
        let result = result(sleeps)

        let typical = try! XCTUnwrap(result.typicalBedtimeMinutes)
        XCTAssertTrue((11 * 60 + 28...12 * 60 + 20).contains(typical))
        XCTAssertGreaterThanOrEqual(result.combinedPercent ?? 0, 80)
        XCTAssertLessThanOrEqual(result.bedtimeVariationMinutes ?? 999, 30,
                                 "a 52-minute-wide cluster deviates by minutes, not hours")
    }

    func testBimodalBedtimesWithholdTheTypicalTimeInsteadOfNamingTheGap() {
        // Three afternoon nights and three night nights, twelve hours apart.
        let sleeps = [(13, 5), (13, 20), (13, 10), (1, 5), (1, 20), (1, 10)].enumerated().map { index, time in
            night("bi-\(index)", day: index + 1, bedHour: time.0, bedMinute: time.1)
        }
        let result = result(sleeps)

        XCTAssertNotNil(result.combinedPercent, "six qualified nights still score")
        XCTAssertNil(result.typicalBedtimeMinutes, "no single centre exists — do not invent one")
        XCTAssertNil(result.typicalWakeTimeMinutes)
        XCTAssertNil(result.typicalWindowText)
        XCTAssertTrue(result.footnote.contains("more than one cluster"), result.footnote)
        XCTAssertEqual(result.deviations.count, 6)
    }

    func testEveningSleeperKeepsTheEighteenHundredAxisAndLinearDeviations() {
        let sleeps = [(23, 0), (23, 30), (22, 45), (23, 10), (23, 20)].enumerated().map { index, time in
            night("pm-\(index)", day: index + 1, bedHour: time.0, bedMinute: time.1, hours: 7)
        }
        let result = result(sleeps)

        XCTAssertEqual(result.scheduleAxisStartMinutes, 18 * 60)
        let typical = try! XCTUnwrap(result.typicalBedtimeMinutes)
        XCTAssertTrue((22 * 60 + 45...23 * 60 + 30).contains(typical))
        for deviation in result.deviations {
            XCTAssertEqual(deviation.bedtimeDeviationMinutes, abs(deviation.bedtimeMinutes - typical),
                           "inside one cluster the circular distance is the plain distance")
        }
        XCTAssertEqual(AtriaSleepConsistency.axisHourText(18 * 60), "6 PM")
        XCTAssertEqual(AtriaSleepConsistency.axisHourText(24 * 60), "12 AM")
        XCTAssertEqual(AtriaSleepConsistency.axisHourText(8 * 60), "8 AM")
    }
}
