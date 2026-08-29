import XCTest
@testable import Atria

/// Insight-detail navigation directive (2026-08-29): every stored insight is
/// reachable through its detail sheet across past days/weeks/months, and the
/// textual About copy is visible at the bottom of each sheet — not behind a
/// reveal.
final class AtriaInsightDetailNavigationTests: XCTestCase {
    private func overviewSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaOverviewSections.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func todaySource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaTodayScreen.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func historySource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaHistorySection.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Strain day view keeps the range selector

    /// The live-day strain provenance card must render INSIDE chartSlot (which
    /// carries the D/W/M selector and the prev/next period chevrons). Returning
    /// the card in place of chartSlot left the sheet with no way to reach past
    /// days.
    func testStrainDayDetailKeepsRangeSelectorAroundProvenanceCard() throws {
        let source = try overviewSource()
        let detailTemplate = try XCTUnwrap(source.range(of: "private var detailTemplate: some View"))
        let strainStart = try XCTUnwrap(
            source.range(of: "case .strain:", range: detailTemplate.upperBound..<source.endIndex)
        )
        let strainEnd = try XCTUnwrap(
            source.range(of: "case .sleepPerformance:", range: strainStart.upperBound..<source.endIndex)
        )
        let strainDetail = String(source[strainStart.lowerBound..<strainEnd.lowerBound])

        let chartStart = try XCTUnwrap(strainDetail.range(of: "} chart: {"))
        let chartEnd = try XCTUnwrap(
            strainDetail.range(of: "} about: {", range: chartStart.upperBound..<strainDetail.endIndex)
        )
        let chart = String(strainDetail[chartStart.lowerBound..<chartEnd.lowerBound])

        let slot = try XCTUnwrap(chart.range(of: "chartSlot {"),
                                 "the strain chart slot must exist for every range")
        let provenance = try XCTUnwrap(
            chart.range(of: "AtriaMetricProvenanceCard(provenance: currentCycleStrainProvenance)"),
            "the live-day provenance card must still render"
        )
        XCTAssertTrue(slot.lowerBound < provenance.lowerBound,
                      "the provenance card must render inside chartSlot so the range selector and period chevrons survive the live day")
        // The week/month chart also stays inside the same slot.
        let metricChart = try XCTUnwrap(chart.range(of: "metricChart(title: \"Strain\""))
        XCTAssertTrue(slot.lowerBound < metricChart.lowerBound)
        // Fail if the pre-fix shape returns: a provenance/honest-partial branch
        // that bypasses chartSlot entirely.
        let beforeSlot = String(chart[chart.startIndex..<slot.lowerBound])
        XCTAssertFalse(beforeSlot.contains("if range == .day"),
                       "no day-range branch may run before (outside) chartSlot")
    }

    // MARK: - About is bottom-visible on every metric detail sheet

    func testAboutSectionIsAlwaysVisibleAtSheetBottom() throws {
        let source = try overviewSource()

        // The About block itself is expanded static text, never a disclosure.
        let aboutStart = try XCTUnwrap(source.range(of: "private var aboutSection: some View"))
        let aboutEnd = try XCTUnwrap(
            source.range(of: "private var", range: aboutStart.upperBound..<source.endIndex)
        )
        let about = String(source[aboutStart.lowerBound..<aboutEnd.lowerBound])
        XCTAssertTrue(about.contains("AtriaMetricMeaningInline(metric: metric"))
        XCTAssertFalse(about.contains("DisclosureGroup"),
                       "About must be readable without a reveal tap")

        // Template body: `about` sits after (outside) the showDetails reveal.
        let templateStart = try XCTUnwrap(
            source.range(of: "private struct AtriaMetricDetailTemplate")
        )
        let bodyStart = try XCTUnwrap(
            source.range(of: "var body: some View {", range: templateStart.upperBound..<source.endIndex)
        )
        let animationEnd = try XCTUnwrap(
            source.range(of: ", value: showDetails)", range: bodyStart.upperBound..<source.endIndex)
        )
        let body = String(source[bodyStart.lowerBound..<animationEnd.lowerBound])
        let reveal = try XCTUnwrap(body.range(of: "if showDetails {"))
        let aboutUse = try XCTUnwrap(
            body.range(of: "\n            about\n"),
            "the template body must render `about` unconditionally"
        )
        XCTAssertTrue(aboutUse.lowerBound > reveal.upperBound,
                      "About renders at the bottom, after the reveal block")

        // And the collapsed panel no longer owns it.
        let panelStart = try XCTUnwrap(source.range(of: "private var detailPanel: some View"))
        let panelEnd = try XCTUnwrap(
            source.range(of: ".atriaInsetCard(tint: tint)", range: panelStart.upperBound..<source.endIndex)
        )
        let panel = String(source[panelStart.lowerBound..<panelEnd.lowerBound])
        XCTAssertTrue(panel.contains("contributors"))
        XCTAssertFalse(panel.contains("\n            about\n"),
                       "About must not be gated behind the Show-details reveal")
    }

    // MARK: - History day sheet steps across days

    private func historyDay(_ dayOffset: Int) -> AtriaHistoryDay {
        let base = Calendar.current.startOfDay(for: Date(timeIntervalSinceReferenceDate: 800_000_000))
        let date = Calendar.current.date(byAdding: .day, value: dayOffset, to: base)!
        return AtriaHistoryDay(date: date,
                               strain: nil,
                               recovery: nil,
                               rhrInt: nil,
                               hrvMs: nil,
                               sleepSeconds: nil,
                               sleepPerformance: nil,
                               confirmedWorkoutCount: 0,
                               confirmedSleepCount: 0,
                               savedDurationSeconds: 0,
                               reviewPending: 0,
                               state: .none)
    }

    func testHistoryDaySteppingIsChronologicalAndEndsHonestly() {
        // Newest-first, with a hole at offset 2 — exactly how
        // AtriaHistoryModel.make emits days (only days with data exist).
        let days = [historyDay(3), historyDay(1), historyDay(0)]

        // Older neighbour skips the missing day 2.
        XCTAssertEqual(
            AtriaHistoryDayStepping.adjacentDay(to: days[0].date, in: days, offset: -1)?.date,
            days[1].date
        )
        // Newer neighbour from the oldest day.
        XCTAssertEqual(
            AtriaHistoryDayStepping.adjacentDay(to: days[2].date, in: days, offset: 1)?.date,
            days[1].date
        )
        // Ends return nil so the chevrons disable instead of wrapping.
        XCTAssertNil(AtriaHistoryDayStepping.adjacentDay(to: days[0].date, in: days, offset: 1))
        XCTAssertNil(AtriaHistoryDayStepping.adjacentDay(to: days[2].date, in: days, offset: -1))
        // Unknown anchors and zero offsets step nowhere.
        XCTAssertNil(AtriaHistoryDayStepping.adjacentDay(to: historyDay(2).date, in: days, offset: -1))
        XCTAssertNil(AtriaHistoryDayStepping.adjacentDay(to: days[1].date, in: days, offset: 0))
        // Order-agnostic: oldest-first input steps identically.
        XCTAssertEqual(
            AtriaHistoryDayStepping.adjacentDay(to: days[1].date, in: Array(days.reversed()), offset: 1)?.date,
            days[0].date
        )
    }

    func testHistoryDaySheetCarriesPrevNextChevrons() throws {
        let source = try historySource()
        let sheetStart = try XCTUnwrap(source.range(of: "struct AtriaHistoryDayDetailSheet: View"))
        let sheetEnd = try XCTUnwrap(
            source.range(of: "extension SleepHistorySnapshot", range: sheetStart.upperBound..<source.endIndex)
        )
        let sheet = String(source[sheetStart.lowerBound..<sheetEnd.lowerBound])

        // Same affordance grammar as AtriaMetricDetailSheet's period chevrons.
        for needle in [
            "Image(systemName: \"chevron.left\")",
            "Image(systemName: \"chevron.right\")",
            ".frame(width: 32, height: 32)",
            ".accessibilityLabel(\"Previous day\")",
            ".accessibilityLabel(\"Next day\")",
            "AtriaHistoryDayStepping.adjacentDay(",
        ] {
            XCTAssertTrue(sheet.contains(needle), "missing: \(needle)")
        }
        // Both call sites feed the day list so stepping actually works.
        XCTAssertTrue(source.contains("allDays: model.days"))
        let overview = try overviewSource()
        XCTAssertTrue(overview.contains("allDays: historyModel.days"))
    }

    // MARK: - Today stress tile lands on information

    func testTodayStressTileOpensStressDetailWithBreathworkReachable() throws {
        let source = try todaySource()

        let branchStart = try XCTUnwrap(source.range(of: "if metric == .stress {"))
        let branchEnd = try XCTUnwrap(
            source.range(of: "} else if metric == .insights {", range: branchStart.upperBound..<source.endIndex)
        )
        let stressBranch = String(source[branchStart.lowerBound..<branchEnd.lowerBound])
        XCTAssertTrue(stressBranch.contains("showStressDetail = true"),
                      "the stress tile opens the stress detail, not an exercise")
        XCTAssertFalse(stressBranch.contains("showBreathworkSession = true"),
                       "the tile must not jump straight into breathwork")

        // The detail is the real measured surface, presented like
        // AtriaHealthScreen presents it, with Relax handing off to breathwork.
        let coverStart = try XCTUnwrap(
            source.range(of: ".fullScreenCover(isPresented: $showStressDetail) {")
        )
        let coverEnd = try XCTUnwrap(
            source.range(of: "// Refreshed whenever a step receipt publishes", range: coverStart.upperBound..<source.endIndex)
        )
        let cover = String(source[coverStart.lowerBound..<coverEnd.lowerBound])
        XCTAssertTrue(cover.contains("AtriaStressDetailView("))
        XCTAssertTrue(cover.contains("onRelax: {"))
        XCTAssertTrue(cover.contains("showBreathworkSession = true"),
                      "breathwork stays one tap away from the stress detail")
    }
}
