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

    // MARK: - Minimalism reveal (owner directive 2026-08-29, supersedes the
    // same-day About-always-visible directive): About and the heavy cards sit
    // INSIDE the single "Show details" reveal; the summary strip is gone.

    func testAboutLivesInsideTheRevealAndSummaryStripIsGone() throws {
        let source = try overviewSource()

        // The About block itself is plain text, never a disclosure or card.
        let aboutStart = try XCTUnwrap(source.range(of: "private var aboutSection: some View"))
        let aboutEnd = try XCTUnwrap(
            source.range(of: "private var", range: aboutStart.upperBound..<source.endIndex)
        )
        let about = String(source[aboutStart.lowerBound..<aboutEnd.lowerBound])
        XCTAssertTrue(about.contains("AtriaMetricMeaningInline(metric: metric"))
        XCTAssertFalse(about.contains("DisclosureGroup"))
        XCTAssertFalse(about.contains("atriaInsetCard"),
                       "About is plain secondary text, not a card")
        XCTAssertFalse(about.contains("Label("),
                       "About carries no header — a hairline divider precedes it")

        // Template body: no unconditional `about` render — the reveal owns it.
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
        XCTAssertTrue(body.contains("if showDetails {"))
        XCTAssertFalse(body.contains("\n            about\n"),
                       "About must not render outside the Show-details reveal")

        // The panel owns contributors AND About, separated by a divider.
        let panelStart = try XCTUnwrap(source.range(of: "private var detailPanel: some View"))
        let panelEnd = try XCTUnwrap(
            source.range(of: "private var heroIsUncertain", range: panelStart.upperBound..<source.endIndex)
        )
        let panel = String(source[panelStart.lowerBound..<panelEnd.lowerBound])
        XCTAssertTrue(panel.contains("contributors"))
        XCTAssertTrue(panel.contains("Divider()"))
        XCTAssertTrue(panel.contains("about"),
                      "About renders inside the reveal panel")
        XCTAssertFalse(panel.contains("atriaInsetCard"),
                       "the panel must not wrap cards in another card")

        // The tinted period summary strip stayed deleted; the neutral
        // one-line row replaced it.
        XCTAssertFalse(source.contains("private struct AtriaDetailPeriodSummaryStrip"),
                       "the tinted summary strip must stay deleted")
        XCTAssertTrue(source.contains("private struct AtriaDetailPeriodSummaryLine"))
        XCTAssertTrue(source.contains("AtriaDetailPeriodSummaryLine(summary: summary)"))
    }

    // MARK: - Sleep sheet above-fold block budget

    /// Above the fold the sleep sheet is exactly: hero → chart slot →
    /// hypnogram → neutral 4-up stat row → reveal. The plan card and need
    /// ledger live behind the reveal; the debt-trend mount stays deleted.
    func testSleepDetailAboveFoldIsFiveBlocks() throws {
        let source = try overviewSource()
        let detailTemplate = try XCTUnwrap(source.range(of: "private var detailTemplate: some View"))
        let start = try XCTUnwrap(
            source.range(of: "case .sleep:", range: detailTemplate.upperBound..<source.endIndex)
        )
        let end = try XCTUnwrap(
            source.range(of: "case .strain:", range: start.upperBound..<source.endIndex)
        )
        let sleepDetail = String(source[start.lowerBound..<end.lowerBound])

        let contributorsStart = try XCTUnwrap(sleepDetail.range(of: "} contributors: {"))
        let chartStart = try XCTUnwrap(
            sleepDetail.range(of: "} chart:", range: contributorsStart.upperBound..<sleepDetail.endIndex)
        )
        let aboveFold = String(sleepDetail[sleepDetail.startIndex..<contributorsStart.lowerBound])
        let revealed = String(sleepDetail[contributorsStart.lowerBound..<chartStart.lowerBound])

        XCTAssertTrue(aboveFold.contains("AtriaSleepHypnogramCard(night: latest"))
        XCTAssertTrue(aboveFold.contains("sleepStatSummaryRow"))
        for heavy in ["AtriaSleepPlanCard(", "sleepNeedLedgerCard("] {
            XCTAssertFalse(aboveFold.contains(heavy),
                           "\(heavy) must live behind the Show-details reveal")
            XCTAssertTrue(revealed.contains(heavy))
        }
        XCTAssertFalse(source.contains("sleepDebtTrendCard"),
                       "the debt-trend mount duplicates the W/M chart and stays deleted")

        // The 4-up row is label + value only — no icons, no color — and reads
        // from the same rows the revealed detail uses, so numbers cannot drift.
        let rowStart = try XCTUnwrap(source.range(of: "private var sleepStatSummaryRow: some View"))
        let rowEnd = try XCTUnwrap(
            source.range(of: "private func sleepNeedLedgerCard", range: rowStart.upperBound..<source.endIndex)
        )
        let row = String(source[rowStart.lowerBound..<rowEnd.lowerBound])
        XCTAssertTrue(row.contains("ForEach(sleepContributorRows)"))
        XCTAssertFalse(row.contains("Image(systemName:"))
        XCTAssertFalse(row.contains("foregroundStyle(Metrics."))
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
