import XCTest
@testable import Atria

/// Which civil day a physiological cycle belongs to on the weekly steps chart.
///
/// Receipts are keyed by a WAKE boundary, not by midnight, so every cycle
/// straddles two dates. The chart used to bucket on
/// `startOfDay(receipt.windowStart)` — the day the cycle woke — which for a
/// late-evening wake drew nearly all of a day's steps under the previous day's
/// letter. Replayed against the owner's real sleeps, the bar labelled "Sun" was
/// the cycle Sun 20:26 → Mon 20:56: 24.5 hours that are almost entirely Monday.
///
/// Owner's decision (2026-08-26): label by the day the cycle predominantly
/// covers.
final class AtriaStepsWeekChartDayLabellingTests: XCTestCase {

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 8, day: day,
                                           hour: hour, minute: minute))!
    }

    private func label(_ start: Date, _ end: Date) -> Date {
        AtriaStepsWeekChart.predominantCivilDay(windowStart: start,
                                                windowEnd: end,
                                                calendar: calendar)
    }

    // MARK: - The owner's real shape

    func testTheOwnersEveningWakeCycleLabelsAsTheDayItActuallyCovers() {
        // Sun 20:26 → Mon 20:56. Under the old rule this drew on SUNDAY.
        XCTAssertEqual(label(at(23, 20, 26), at(24, 20, 56)),
                       calendar.startOfDay(for: at(24, 12)),
                       "3.5h of Sunday against 20.9h of Monday — it is Monday's")
    }

    func testAMorningWakeCycleStillLabelsAsItsOwnDay() {
        // The conventional case must not regress: wake 07:00, next wake 07:00.
        XCTAssertEqual(label(at(10, 7), at(11, 7)),
                       calendar.startOfDay(for: at(10, 12)),
                       "17h of the 10th against 7h of the 11th")
    }

    // MARK: - Boundaries

    func testACycleInsideOneDayLabelsAsThatDay() {
        XCTAssertEqual(label(at(12, 2), at(12, 22)),
                       calendar.startOfDay(for: at(12, 2)))
    }

    func testAnEvenSplitAcrossMidnightKeepsTheEarlierDay() {
        // Deterministic tie-break rather than iteration order.
        XCTAssertEqual(label(at(14, 12), at(15, 12)),
                       calendar.startOfDay(for: at(14, 12)))
    }

    func testAJustPastMidnightMajorityFlipsToTheLaterDay() {
        // 11h59m of the 14th, 12h01m of the 15th.
        XCTAssertEqual(label(at(14, 12, 1), at(15, 12, 2)),
                       calendar.startOfDay(for: at(15, 12)))
    }

    func testACycleLongerThanTwoDaysPicksTheDayItMostlyOccupies() {
        // A missed sleep can stretch a cycle past 24h.
        XCTAssertEqual(label(at(18, 22), at(20, 3)),
                       calendar.startOfDay(for: at(19, 12)),
                       "the 19th is the only whole day inside it")
    }

    // MARK: - Degenerate input

    func testAZeroLengthWindowFallsBackToItsStartDay() {
        XCTAssertEqual(label(at(16, 9), at(16, 9)),
                       calendar.startOfDay(for: at(16, 9)))
    }

    func testAnInvertedWindowDoesNotLoopOrCrash() {
        XCTAssertEqual(label(at(16, 9), at(15, 9)),
                       calendar.startOfDay(for: at(16, 9)))
    }

    // MARK: - Wiring

    func testTheSheetLabelsByCoverageAndSumsCyclesSharingADay() throws {
        // Was a source scan over AtriaOverviewSections looking for the folding
        // keywords inline. The rule now lives in AtriaStepsWeekChart so the
        // Today sparkline can share it — one authority instead of two copies,
        // which is exactly what the card-vs-chart mismatch came from. Assert
        // the behaviour and the single home, not where the keywords sit.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_756_080_000)
        let yesterday = calendar.date(byAdding: .day,
                                      value: -1,
                                      to: calendar.startOfDay(for: now))!

        func receipt(_ startOffset: TimeInterval,
                     _ endOffset: TimeInterval,
                     _ steps: Int) -> HistoricalArchive.MotionTickDayEvidence {
            HistoricalArchive.MotionTickDayEvidence(
                windowStart: now.addingTimeInterval(startOffset),
                windowEnd: now.addingTimeInterval(endOffset),
                motionTicks: steps * 2,
                steps: steps,
                knownCoverageSeconds: Int(endOffset - startOffset),
                missingCoverageSeconds: 0,
                decodedRows: 1_000,
                capturedThrough: now.addingTimeInterval(endOffset)
            )
        }

        let totals = AtriaStepsWeekChart.dailyStepTotals(
            receipts: [receipt(-20 * 3600, -16 * 3600, 1_458),
                       receipt(-14 * 3600, -10 * 3600, 900)],
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(totals[yesterday], 2_358,
                       "two cycles predominantly on one date are two real "
                           + "cycles; max used to drop the smaller")

        // And the wake-date bucketing must be gone, not shadowed.
        let overview = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Atria/AtriaOverviewSections.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(
            overview.contains("calendar.startOfDay(for: receipt.windowStart)"),
            "the wake-date bucketing must be gone, not shadowed"
        )
        XCTAssertTrue(
            overview.contains("AtriaStepsWeekChart.dailyStepTotals"),
            "the week chart must fold days through the shared rule"
        )
    }
}
