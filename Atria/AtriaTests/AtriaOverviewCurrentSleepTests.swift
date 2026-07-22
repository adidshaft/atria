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

    func testActiveTodayRingUsesCurrentCycleResolver() throws {
        let testsURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let todayURL = testsURL.deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaTodayScreen.swift")
        let source = try String(contentsOf: todayURL, encoding: .utf8)

        XCTAssertTrue(source.contains("AtriaOverviewCurrentSleep.resolve("))
        XCTAssertTrue(source.contains("AtriaOverviewCurrentSleep.resolveDisplayEvidence("))
        XCTAssertTrue(source.contains("let latest = latestSleep"))
        XCTAssertTrue(source.contains("latest == nil, latestDisplaySleep != nil"),
                      "review-only sleep must not inherit an older night's need/performance")
        XCTAssertTrue(source.contains("let value = latestDisplaySleep?.durationText"),
                      "fresh first-night evidence should render its measured duration")
        XCTAssertTrue(source.contains("evidence.isNapEvidence ? \"Review nap\" : \"Review sleep\""))
        XCTAssertFalse(source.contains("let latest = sleepHistory.latestMainSleep"))
    }

    func testFreshCandidateCanDisplayDurationWithoutBecomingCurrentMainSleep() {
        let now = date(2026, 7, 18, 9, 0)
        let start = date(2026, 7, 18, 2, 0)
        let end = date(2026, 7, 18, 8, 0)
        let candidate = SleepHistorySnapshot.Night(id: "review",
                                                   day: calendar.startOfDay(for: end),
                                                   start: start,
                                                   end: end,
                                                   duration: end.timeIntervalSince(start),
                                                   restingHR: 55,
                                                   hrv: nil,
                                                   respiratoryRate: nil,
                                                   sleepEfficiency: 1,
                                                   confidence: "review_needed",
                                                   source: "sleep_candidate",
                                                   confirmed: false,
                                                   stageSegments: [])
        let snapshot = SleepHistorySnapshot(nights: [candidate],
                                            confirmedCount: 0,
                                            candidateCount: 1)

        XCTAssertNil(AtriaOverviewCurrentSleep.resolve(from: snapshot,
                                                       now: now,
                                                       calendar: calendar))
        XCTAssertEqual(AtriaOverviewCurrentSleep.resolveDisplayEvidence(from: snapshot,
                                                                        now: now,
                                                                        calendar: calendar)?.id,
                       candidate.id)
    }

    func testResidentReviewDisplaysWhenDailySnapshotIsEmptyWithoutBecomingCurrentSleep() {
        let now = date(2026, 7, 18, 9, 0)
        let start = date(2026, 7, 18, 2, 15)
        let end = date(2026, 7, 18, 8, 20)
        let pending = SleepHistorySnapshot.Night(id: "resident-review",
                                                 day: calendar.startOfDay(for: end),
                                                 start: start,
                                                 end: end,
                                                 duration: end.timeIntervalSince(start),
                                                 restingHR: 55,
                                                 hrv: nil,
                                                 respiratoryRate: nil,
                                                 sleepEfficiency: 1,
                                                 confidence: "review_needed",
                                                 source: "sleep_candidate",
                                                 confirmed: false,
                                                 stageSegments: [])

        XCTAssertNil(AtriaOverviewCurrentSleep.resolve(from: .empty,
                                                       now: now,
                                                       calendar: calendar))
        let displayed = AtriaOverviewCurrentSleep.resolveDisplayEvidence(from: .empty,
                                                                          pendingReview: pending,
                                                                          now: now,
                                                                          calendar: calendar)
        XCTAssertEqual(displayed?.id, pending.id)
        XCTAssertEqual(displayed?.durationText, pending.durationText)
        XCTAssertFalse(displayed?.confirmed ?? true,
                       "overview projection must not confirm a pending review")
    }

    func testFreshResidentReviewOutranksStaleDailyCandidateForDisplay() {
        let now = date(2026, 7, 18, 9, 0)
        let staleEnd = date(2026, 7, 16, 8, 0)
        let stale = SleepHistorySnapshot.Night(id: "stale-snapshot-review",
                                               day: calendar.startOfDay(for: staleEnd),
                                               start: staleEnd.addingTimeInterval(-6 * 3_600),
                                               end: staleEnd,
                                               duration: 6 * 3_600,
                                               restingHR: 55,
                                               hrv: nil,
                                               respiratoryRate: nil,
                                               sleepEfficiency: 1,
                                               confidence: "review_needed",
                                               source: "sleep_candidate",
                                               confirmed: false,
                                               stageSegments: [])
        let freshEnd = date(2026, 7, 18, 8, 10)
        let fresh = SleepHistorySnapshot.Night(id: "fresh-resident-review",
                                               day: calendar.startOfDay(for: freshEnd),
                                               start: freshEnd.addingTimeInterval(-5 * 3_600),
                                               end: freshEnd,
                                               duration: 5 * 3_600,
                                               restingHR: 56,
                                               hrv: nil,
                                               respiratoryRate: nil,
                                               sleepEfficiency: 1,
                                               confidence: "review_needed",
                                               source: "sleep_candidate",
                                               confirmed: false,
                                               stageSegments: [])
        let staleSnapshot = SleepHistorySnapshot(nights: [stale],
                                                 confirmedCount: 0,
                                                 candidateCount: 1)

        XCTAssertEqual(AtriaOverviewCurrentSleep.resolveDisplayEvidence(from: staleSnapshot,
                                                                         pendingReview: fresh,
                                                                         now: now,
                                                                         calendar: calendar)?.id,
                       fresh.id)
    }

    func testStaleCandidateCannotLeakIntoCurrentOverview() {
        let now = date(2026, 7, 18, 9, 0)
        let end = date(2026, 7, 16, 8, 0)
        let candidate = SleepHistorySnapshot.Night(id: "stale-review",
                                                   day: calendar.startOfDay(for: end),
                                                   start: end.addingTimeInterval(-6 * 3_600),
                                                   end: end,
                                                   duration: 6 * 3_600,
                                                   restingHR: 55,
                                                   hrv: nil,
                                                   respiratoryRate: nil,
                                                   sleepEfficiency: 1,
                                                   confidence: "review_needed",
                                                   source: "sleep_candidate",
                                                   confirmed: false,
                                                   stageSegments: [])
        let snapshot = SleepHistorySnapshot(nights: [candidate],
                                            confirmedCount: 0,
                                            candidateCount: 1)

        XCTAssertNil(AtriaOverviewCurrentSleep.resolveDisplayEvidence(from: snapshot,
                                                                      now: now,
                                                                      calendar: calendar))
    }
}
