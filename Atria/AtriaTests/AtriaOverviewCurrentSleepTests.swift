import XCTest
@testable import Atria

final class AtriaOverviewCurrentSleepTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: year,
                                           month: month,
                                           day: day,
                                           hour: hour,
                                           minute: minute))!
    }

    private func snapshot(wake: Date) -> SleepHistorySnapshot {
        let start = wake.addingTimeInterval(-(7 * 3_600 + 48 * 60))
        let night = SleepHistorySnapshot.Night(id: "manual-july-14",
                                               day: calendar.startOfDay(for: wake),
                                               start: start,
                                               end: wake,
                                               duration: wake.timeIntervalSince(start),
                                               restingHR: 55,
                                               hrv: 49,
                                               respiratoryRate: nil,
                                               sleepEfficiency: nil,
                                               confidence: "user_confirmed",
                                               source: "manual_sleep",
                                               confirmed: true,
                                               stageSegments: [],
                                               eventTimeZoneIdentifier: "Asia/Kolkata")
        return SleepHistorySnapshot(nights: [night], confirmedCount: 1, candidateCount: 0)
    }

    func testOverviewDoesNotReuseOlderManualSleepAfterNoSleepBoundary() {
        let july14Wake = date(2026, 7, 14, 11, 38)
        let july18Morning = date(2026, 7, 18, 9, 0)

        XCTAssertNil(AtriaOverviewCurrentSleep.resolve(from: snapshot(wake: july14Wake),
                                                       now: july18Morning,
                                                       calendar: calendar))
    }

    func testOverviewKeepsCompletedSleepDuringItsWakeToWakeCycle() {
        let wake = date(2026, 7, 18, 8, 15)
        let sameMorning = date(2026, 7, 18, 9, 0)

        XCTAssertEqual(AtriaOverviewCurrentSleep.resolve(from: snapshot(wake: wake),
                                                         now: sameMorning,
                                                         calendar: calendar)?.id,
                       "manual-july-14")
    }

    func testOverviewDoesNotShowSleepWhoseWakeIsInTheFuture() {
        let futureWake = date(2026, 7, 18, 10, 0)
        let now = date(2026, 7, 18, 9, 0)

        XCTAssertNil(AtriaOverviewCurrentSleep.resolve(from: snapshot(wake: futureWake),
                                                       now: now,
                                                       calendar: calendar))
    }
}
