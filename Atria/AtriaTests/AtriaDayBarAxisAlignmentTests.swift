import XCTest
@testable import Atria

/// Where a weekday letter sits under a daily bar, and which day an open cycle
/// belongs to.
///
/// Reported from device 2026-08-26 against the weekly steps chart: "the bar
/// chart number and what it shows does not match … the bars right above the
/// numbers". Two separate defects behind that, both of which recur elsewhere.
final class AtriaDayBarAxisAlignmentTests: XCTestCase {

    private func source(_ name: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Atria/\(name)"),
            encoding: .utf8
        )
    }

    // MARK: - A day-unit bar owns its whole day, so its label must be centred

    func testEveryDayUnitBarChartCentresItsAxisLabel() throws {
        // A `BarMark(x:unit:.day)` is drawn across the whole day, i.e. centred
        // at noon. An axis tick sits at midnight. Without `centered: true` the
        // weekday letter lands half a day left of its own bar.
        for name in ["AtriaStepsWeekChart.swift",
                     "AtriaStressDetailView.swift"] {
            let text = try source(name)
            guard text.contains("unit: .day") else {
                return XCTFail("\(name) no longer draws day-unit bars")
            }
            XCTAssertTrue(text.contains("centered: true"),
                          "\(name) draws day-unit bars and must centre its "
                              + "axis labels")
        }
    }

    // MARK: - ...but ONLY when it is actually drawing bars

    func testChartsThatSwitchShapeMarkDayCentresInsteadOfCentringTheLabel() throws {
        // CORRECTED 2026-08-26, same day the conditional `centered:` shipped.
        //
        // `AxisValueLabel(centered:)` centres a label within the step to the
        // NEXT mark — not within the bar's `unit`. Those coincide only at a
        // one-day stride, which is why `centered: true` is right on the steps
        // week chart (marks = the seven days) and wrong on these two, which
        // pick marks with `.automatic(desiredCount:)`: the stride follows the
        // window width, so at four marks across a month each label was thrown
        // about three and a half days right, onto a different bar entirely.
        // The earlier version of this test pinned that behaviour as correct.
        //
        // Marking noon puts the label at the bar's middle at ANY stride,
        // because it no longer depends on where the next mark falls.
        for name in ["AtriaOverviewSections.swift", "AtriaExpandedChart.swift"] {
            let text = try source(name)
            XCTAssertTrue(text.contains("dayCentreMarks("),
                          "\(name) must mark day centres when drawing day bars")
            XCTAssertFalse(text.contains("centered: rendersAsDailyBar"),
                           "\(name) must not reintroduce step-relative centring")
            XCTAssertFalse(text.contains("centered: effectiveChartType == .bars"),
                           "\(name) must not reintroduce step-relative centring")
        }
    }

    func testTheScrollableChartKeepsItsLabelDensityAcrossTheWholeDomain() {
        // Explicit marks do not recompute as you scroll the way `.automatic`
        // does, so a flat request would leave most screens of a long domain
        // with no label at all.
        let sparse = AtriaChartVisualGrammar.scrollableDayMarkCount(
            totalDays: 90, visibleDays: 7, labelsPerScreen: 6)
        XCTAssertGreaterThan(sparse, 6,
                             "90 days shown 7 at a time needs far more than "
                                 + "six marks to put six on each screen")

        let whole = AtriaChartVisualGrammar.scrollableDayMarkCount(
            totalDays: 30, visibleDays: 30, labelsPerScreen: 6)
        XCTAssertEqual(whole, 6, "a fully visible domain wants exactly the "
                           + "requested density")

        XCTAssertLessThanOrEqual(
            AtriaChartVisualGrammar.scrollableDayMarkCount(
                totalDays: 10, visibleDays: 1, labelsPerScreen: 6),
            10,
            "never more marks than there are days")
    }

    func testNoDayBarChartCentresUnconditionallyWhereALineIsAlsoPossible() throws {
        // Guards the specific wrong fix: hard-coding `centered: true` in a
        // chart that can render a line.
        let expanded = try source("AtriaExpandedChart.swift")
        XCTAssertFalse(expanded.contains("AxisValueLabel(centered: true)"),
                       "the expanded chart must not centre unconditionally")
    }

    // MARK: - An open cycle belongs to today, not to whichever day it currently covers

    func testTheOpenCycleIsPinnedToTodayRatherThanItsPredominantDay() throws {
        // Predominant-day labelling is only stable once a window CLOSES. An
        // open cycle that began yesterday morning reads as yesterday's now and
        // would flip to today's a few hours later — a bar that migrates
        // between days while the user watches.
        //
        // On device this also made the headline vanish: the card read 5,878
        // while the chart folded it into a 7,336 bar on the previous day
        // (5,878 + a prior 1,458), so the number shown at the top appeared
        // nowhere on its own chart.
        let source = try source("AtriaOverviewSections.swift")
        let start = try XCTUnwrap(source.range(of: "private func loadWeekSteps()"))
        let body = String(source[start.lowerBound...].prefix(2_000))
        XCTAssertTrue(body.contains("let isOpenCycle"),
                      "the open cycle must be identified")
        XCTAssertTrue(body.contains("? today"),
                      "and pinned to today rather than its predominant day")
        XCTAssertTrue(body.contains("predominantCivilDay("),
                      "while CLOSED cycles keep predominant-day labelling")
    }

    func testClosedCyclesStillSumSoATwoSleepDayIsNotUnderReported() throws {
        let source = try source("AtriaOverviewSections.swift")
        XCTAssertTrue(source.contains("map[day, default: 0] += receipt.steps"),
                      "two closed cycles sharing a date are two real cycles")
        XCTAssertFalse(source.contains("max(map[day] ?? 0, receipt.steps)"),
                       "the max merge silently dropped the smaller of two")
    }

    // MARK: - The chart spans its plot

    func testTheWeekChartUsesTheFullWidthInsteadOfPaddingBothEnds() throws {
        let text = try source("AtriaStepsWeekChart.swift")
        XCTAssertFalse(text.contains("value: -18, to: start"),
                       "the ±18h padding inset every bar from the plot edges")
        XCTAssertTrue(text.contains("let axisLo = start"),
                      "the domain starts at the first day")
        XCTAssertTrue(text.contains("byAdding: .day, value: 1, to: end"),
                      "and ends at the close of the last day, so seven "
                          + "day-slots fill the width exactly")
    }
}
