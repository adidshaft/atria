import XCTest
@testable import Atria

/// Vitals must show what the strap recorded, and must not call it settled.
///
/// Device report 2026-08-26: "there are some insights which do not show any
/// value." Every sleep row on the Health screen read the CONFIRMED-cycle
/// authority — `AtriaOverviewCurrentSleep.resolve`, which starts from
/// `latestMainSleep`, i.e. `nights.first { $0.confirmed && !$0.isNapEvidence }`.
///
/// A measured-but-unconfirmed night (a degraded HR-only strap can stay
/// unconfirmed for days, as the Today screen's own comment notes) therefore made
/// Vitals say "No sleep recorded this cycle", Efficiency "--", Respiration "--"
/// and draw no hypnogram, while Today showed that same night's duration with a
/// "Review sleep" prompt. One snapshot, two answers.
///
/// The split is measurement versus claim: duration, respiration, efficiency and
/// stages are RECORDINGS and follow the display resolver; Sufficiency and the
/// composite score are CLAIMS about the night and stay behind confirmation.
final class AtriaVitalsUnconfirmedSleepTests: XCTestCase {

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day,
                                           hour: hour, minute: minute))!
    }

    private func night(id: String,
                       wake: Date,
                       confirmed: Bool) -> SleepHistorySnapshot.Night {
        let start = wake.addingTimeInterval(-(7 * 3_600 + 12 * 60))
        return SleepHistorySnapshot.Night(id: id,
                                          day: calendar.startOfDay(for: wake),
                                          start: start,
                                          end: wake,
                                          duration: wake.timeIntervalSince(start),
                                          restingHR: 54,
                                          hrv: 47,
                                          respiratoryRate: 14.2,
                                          sleepEfficiency: 0.91,
                                          confidence: confirmed ? "user_confirmed" : "auto_candidate",
                                          source: confirmed ? "manual_sleep" : "strap_hr_only",
                                          confirmed: confirmed,
                                          stageSegments: [],
                                          eventTimeZoneIdentifier: "Asia/Kolkata")
    }

    private func source(_ name: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Atria/\(name)"),
            encoding: .utf8
        )
    }

    // MARK: - The defect

    func testAMeasuredUnconfirmedNightIsInvisibleToTheConfirmedResolver() {
        let wake = date(2026, 8, 26, 9, 30)
        let now = date(2026, 8, 26, 11, 0)
        let snapshot = SleepHistorySnapshot(
            nights: [night(id: "candidate", wake: wake, confirmed: false)],
            confirmedCount: 0,
            candidateCount: 1
        )

        XCTAssertNil(AtriaHealthCurrentSleepEvidence.resolve(from: snapshot,
                                                             now: now,
                                                             calendar: calendar),
                     "this nil is what blanked every sleep row on Vitals")
    }

    func testTheDisplayResolverShowsThatSameRecordedNight() {
        let wake = date(2026, 8, 26, 9, 30)
        let now = date(2026, 8, 26, 11, 0)
        let snapshot = SleepHistorySnapshot(
            nights: [night(id: "candidate", wake: wake, confirmed: false)],
            confirmedCount: 0,
            candidateCount: 1
        )

        let shown = AtriaHealthCurrentSleepEvidence.resolveDisplay(from: snapshot,
                                                                    now: now,
                                                                    calendar: calendar)
        XCTAssertEqual(shown?.id, "candidate")
        XCTAssertEqual(shown?.respiratoryRate, 14.2, "respiration was there all along")
        XCTAssertFalse(shown?.confirmed ?? true, "and it is still not confirmed")
    }

    // MARK: - Strictly additive

    func testWithNoCandidateTheDisplayResolverMatchesTheConfirmedOne() {
        let wake = date(2026, 8, 26, 9, 30)
        let now = date(2026, 8, 26, 11, 0)
        let snapshot = SleepHistorySnapshot(
            nights: [night(id: "settled", wake: wake, confirmed: true)],
            confirmedCount: 1,
            candidateCount: 0
        )

        XCTAssertEqual(AtriaHealthCurrentSleepEvidence.resolveDisplay(from: snapshot,
                                                                       now: now,
                                                                       calendar: calendar)?.id,
                       AtriaHealthCurrentSleepEvidence.resolve(from: snapshot,
                                                                now: now,
                                                                calendar: calendar)?.id)
    }

    func testAGenuinelyEmptyCycleStaysEmptyOnBothResolvers() {
        let now = date(2026, 8, 26, 11, 0)
        let empty = SleepHistorySnapshot(nights: [], confirmedCount: 0, candidateCount: 0)

        XCTAssertNil(AtriaHealthCurrentSleepEvidence.resolve(from: empty, now: now, calendar: calendar))
        XCTAssertNil(AtriaHealthCurrentSleepEvidence.resolveDisplay(from: empty, now: now, calendar: calendar),
                     "no data must still read as no data — the fix only ever "
                         + "adds a night that was actually recorded")
    }

    func testAStaleCandidateIsNotResurrectedDaysLater() {
        // The 48h pin exists so a never-opened app cannot resurface an old
        // window. Widening display evidence must not have widened that.
        let wake = date(2026, 8, 20, 9, 30)
        let now = date(2026, 8, 26, 11, 0)
        let snapshot = SleepHistorySnapshot(
            nights: [night(id: "stale", wake: wake, confirmed: false)],
            confirmedCount: 0,
            candidateCount: 1
        )

        XCTAssertNil(AtriaHealthCurrentSleepEvidence.resolveDisplay(from: snapshot,
                                                                     now: now,
                                                                     calendar: calendar))
    }

    // MARK: - Measurement vs claim, and the label

    func testDerivedNumbersStayBehindConfirmation() throws {
        let health = try source("AtriaHealthScreen.swift")
        XCTAssertTrue(health.contains("guard let currentMainSleep else { return nil }"),
                      "Sufficiency must keep requiring a confirmed night")
        XCTAssertTrue(health.contains("guard let currentSleep = currentMainSleep else { return nil }"),
                      "and so must the composite score")
    }

    func testMeasuredRowsFollowTheDisplayResolver() throws {
        let health = try source("AtriaHealthScreen.swift")
        for measured in ["guard let seconds = currentDisplaySleep?.duration",
                         "guard let value = currentDisplaySleep?.respiratoryRate",
                         "let currentSleep = currentDisplaySleep"] {
            XCTAssertTrue(health.contains(measured), "missing: \(measured)")
        }
    }

    func testAnUnconfirmedNightIsLabelledRatherThanPresentedAsSettled() throws {
        let health = try source("AtriaHealthScreen.swift")
        XCTAssertTrue(health.contains("if let currentSleep, !currentSleep.confirmed"),
                      "showing the night without saying it is unconfirmed would "
                          + "be the opposite error from hiding it")
        XCTAssertTrue(health.contains("\"Review sleep\""))
    }

    func testTheScreenStillCannotReachTheRawConfirmedOnlyAccessor() throws {
        // The pre-existing invariant: Vitals must not read `.latestMainSleep`
        // directly, or a retained older night leaks in after a rollover.
        let health = try source("AtriaHealthScreen.swift")
        XCTAssertFalse(health.contains(".latestMainSleep"))
    }
}
