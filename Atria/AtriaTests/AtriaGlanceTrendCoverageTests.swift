import XCTest
@testable import Atria

/// Which glance tiles get a corner chart, and why the rest must not.
///
/// Device report 2026-08-26: "i dont see any bar chart in steps, vo2 max, etc."
/// `glanceTrend` handled seven metrics and returned `[]` from a `default:` for
/// the other fifteen, so most tiles silently had no chart at all.
///
/// Four more are now wired from data that genuinely exists. The rest stay empty
/// ON PURPOSE: VO2max, calories and blood oxygen have no stored per-day series
/// anywhere in the app, so a chart for them could only be invented.
final class AtriaGlanceTrendCoverageTests: XCTestCase {

    private func source(_ name: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Atria/\(name)"),
            encoding: .utf8
        )
    }

    /// The body of `glanceTrend(for:)`, bounded by the next declaration.
    private func glanceTrendBody() throws -> String {
        let text = try source("AtriaTodayScreen.swift")
        guard let start = text.range(of: "private func glanceTrend(for metric:") else {
            XCTFail("glanceTrend is gone — this test has no subject")
            return ""
        }
        let rest = text[start.upperBound...]
        let end = rest.range(of: "\n    /// ")?.lowerBound ?? rest.endIndex
        return String(rest[..<end])
    }

    func testTheNewlyWiredMetricsReadRealStoredFields() throws {
        let body = try glanceTrendBody()
        // Each of these is an actual field on DailyRollupStoreEntry.
        for expected in ["case .respiratoryRate", "case .bodyTemp", "case .bioAge", "case .steps"] {
            XCTAssertTrue(body.contains(expected), "\(expected) must have a trend")
        }
        let rollup = try source("DailyRollupStore.swift")
        for field in ["var respiratoryRate: Double?",
                      "var skinTemperatureDeviationCelsius: Double?",
                      "var fitnessAgeDelta: Int?"] {
            XCTAssertTrue(rollup.contains(field),
                          "the trend reads \(field), which must still exist")
        }
    }

    func testMetricsWithNoStoredSeriesStayBlank() throws {
        // The honest half. If someone later "fixes" these by inventing a
        // series, this is the test that should stop them.
        let rollup = try source("DailyRollupStore.swift")
        for absent in ["var vo2max", "var activeCalories", "var bloodOxygen"] {
            XCTAssertFalse(rollup.contains(absent),
                           "\(absent) does not exist; if it is added, wire the "
                               + "tile deliberately rather than by accident")
        }
    }

    // MARK: - One authority for daily strap steps

    func testBothStepSurfacesFoldDaysThroughTheSameFunction() throws {
        let today = try source("AtriaTodayScreen.swift")
        let overview = try source("AtriaOverviewSections.swift")
        XCTAssertTrue(today.contains("AtriaStepsWeekChart.dailyStepTotals"),
                      "the Today sparkline must use the shared rule")
        XCTAssertTrue(overview.contains("AtriaStepsWeekChart.dailyStepTotals"),
                      "and so must the Overview week chart")
        XCTAssertFalse(overview.contains("map[day, default: 0] += receipt.steps"),
                       "the second copy of the folding rule must be gone — two "
                           + "copies is how the card and its own chart came to "
                           + "disagree")
    }

    func testTheOpenCycleIsPinnedToTodayAndClosedOnesSum() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_756_080_000)
        let today = calendar.startOfDay(for: now)

        func receipt(startOffset: TimeInterval,
                     endOffset: TimeInterval,
                     steps: Int) -> HistoricalArchive.MotionTickDayEvidence {
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

        // Two CLOSED cycles that both land on the same civil day, plus the
        // still-running one. `now` is exactly midnight UTC here, so an offset
        // of -Nh lands N hours before the start of today: -20h and -14h are
        // both inside YESTERDAY, and -6h..0 is the open cycle. (An earlier
        // version of this fixture used -40h/-29h, which is two days back, and
        // the test caught my arithmetic rather than a defect.)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let totals = AtriaStepsWeekChart.dailyStepTotals(
            receipts: [
                receipt(startOffset: -20 * 3600, endOffset: -16 * 3600, steps: 1_458),
                receipt(startOffset: -14 * 3600, endOffset: -10 * 3600, steps: 900),
                receipt(startOffset: -6 * 3600, endOffset: 0, steps: 5_878),
            ],
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(totals[today], 5_878,
                       "the open cycle is today's, and matches the card")
        XCTAssertEqual(totals[yesterday], 2_358,
                       "two closed cycles on one day SUM (1458 + 900); max "
                           + "would have silently dropped the smaller")
    }
}
