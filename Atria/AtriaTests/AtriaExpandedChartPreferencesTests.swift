import XCTest
@testable import Atria

/// Remembering what the reader chose last time they opened a chart.
///
/// Owner ask: "more customisable full screen ones". Every control in the
/// expanded chart was `@State`, so time range, compare, chart form and journal
/// markers were discarded on close and the same four adjustments had to be
/// re-made on every open.
///
/// The whole risk in this feature is a stored convenience quietly becoming
/// authoritative — a remembered range showing an empty chart, a remembered form
/// outliving the metric it was chosen for, or a corrupt entry breaking the
/// sheet. These test that it always degrades to a default view instead.
final class AtriaExpandedChartPreferencesTests: XCTestCase {

    private typealias Store = AtriaExpandedChartPreferences

    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(
            suiteName: "atria.expandedChartPreferences.tests.\(UUID().uuidString)"
        )
    }

    override func tearDown() {
        defaults = nil
        super.tearDown()
    }

    // MARK: - Round trip

    func testAChoiceSurvivesBeingClosedAndReopened() {
        Store.save(.init(visibleDays: 42,
                         compareOn: true,
                         compareMode: "samePeriodLastYear",
                         chartType: "bars",
                         markJournalEvents: false),
                   metric: "Sleep", defaults: defaults)

        let restored = Store.load(metric: "Sleep", defaults: defaults)
        XCTAssertEqual(restored.visibleDays, 42)
        XCTAssertEqual(restored.compareOn, true)
        XCTAssertEqual(restored.compareMode, "samePeriodLastYear")
        XCTAssertEqual(restored.chartType, "bars")
        XCTAssertEqual(restored.markJournalEvents, false)
    }

    // MARK: - Per metric, not global

    func testOneMetricsChoiceNeverLeaksOntoAnother() {
        // Bars are right for a once-a-day score and wrong for a continuous one,
        // so a global preference would drag a choice made for Sleep onto
        // Blood oxygen.
        Store.save(.init(chartType: "bars"), metric: "Sleep", defaults: defaults)
        Store.save(.init(chartType: "line"), metric: "Blood oxygen", defaults: defaults)

        XCTAssertEqual(Store.load(metric: "Sleep", defaults: defaults).chartType, "bars")
        XCTAssertEqual(Store.load(metric: "Blood oxygen", defaults: defaults).chartType, "line")
    }

    func testSavingOneMetricDoesNotDisturbAnother() {
        Store.save(.init(visibleDays: 7), metric: "Strain", defaults: defaults)
        Store.save(.init(visibleDays: 90), metric: "Recovery", defaults: defaults)
        Store.save(.init(visibleDays: 14), metric: "Strain", defaults: defaults)

        XCTAssertEqual(Store.load(metric: "Strain", defaults: defaults).visibleDays, 14)
        XCTAssertEqual(Store.load(metric: "Recovery", defaults: defaults).visibleDays, 90)
    }

    // MARK: - A convenience must never become authoritative

    func testAnUnknownMetricReturnsDefaultsRatherThanSomeoneElsesChoice() {
        Store.save(.init(visibleDays: 90), metric: "Sleep", defaults: defaults)
        let fresh = Store.load(metric: "Wrist temp", defaults: defaults)
        XCTAssertNil(fresh.visibleDays)
        XCTAssertNil(fresh.chartType)
    }

    func testAnEmptyStoreReturnsDefaults() {
        let fresh = Store.load(metric: "Sleep", defaults: defaults)
        XCTAssertNil(fresh.visibleDays)
        XCTAssertNil(fresh.compareOn)
        XCTAssertNil(fresh.chartType)
    }

    func testCorruptStoredDataDegradesToDefaultsInsteadOfThrowing() {
        // A preference file is not data. Losing it must cost a default view and
        // nothing more.
        defaults.set(Data("not json".utf8),
                     forKey: "atria.expandedChart.preferences.v1")
        let fresh = Store.load(metric: "Sleep", defaults: defaults)
        XCTAssertNil(fresh.visibleDays)
        XCTAssertNil(fresh.chartType)
    }

    func testAnEmptyMetricNameIsNeitherStoredNorRead() {
        XCTAssertFalse(Store.save(.init(visibleDays: 30), metric: "", defaults: defaults))
        XCTAssertNil(Store.load(metric: "", defaults: defaults).visibleDays)
    }

    // MARK: - Bounded

    func testTheStoreStaysBoundedAcrossALongLivedInstall() {
        for index in 0..<(Store.maximumRememberedMetrics + 25) {
            Store.save(.init(visibleDays: index + 1),
                       metric: "metric-\(String(format: "%03d", index))",
                       defaults: defaults)
        }
        let data = defaults.data(forKey: "atria.expandedChart.preferences.v1")
        let all = try? JSONDecoder().decode(
            [String: Store.Stored].self, from: data ?? Data()
        )
        XCTAssertNotNil(all)
        XCTAssertLessThanOrEqual(all?.count ?? .max,
                                 Store.maximumRememberedMetrics + 1,
                                 "an install that has seen every metric title "
                                     + "must not grow without bound")
    }

    func testTheMostRecentlySavedMetricSurvivesTrimming() {
        for index in 0..<(Store.maximumRememberedMetrics + 5) {
            Store.save(.init(visibleDays: 10),
                       metric: "zz-filler-\(index)", defaults: defaults)
        }
        Store.save(.init(visibleDays: 21), metric: "Sleep", defaults: defaults)
        XCTAssertEqual(Store.load(metric: "Sleep", defaults: defaults).visibleDays, 21,
                       "the chart just customised must never be the one trimmed")
    }

    func testResetClearsEverything() {
        Store.save(.init(visibleDays: 30), metric: "Sleep", defaults: defaults)
        Store.reset(defaults: defaults)
        XCTAssertNil(Store.load(metric: "Sleep", defaults: defaults).visibleDays)
    }

    // MARK: - Wiring

    func testStoredFormOutranksTheDefaultButAnOverlongRangeIsIgnored() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Atria/AtriaExpandedChart.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("restoreReaderPreferences()"))
        XCTAssertTrue(source.contains("days > 0, days <= spanDays"),
                      "a remembered range wider than the data must not open "
                          + "onto empty space")
        XCTAssertTrue(source.contains("chartTypeOptions.contains(type)"),
                      "a remembered form must still be offered for this metric")
        // Written through per change, not on dismiss, so a choice survives the
        // app being killed from the sheet.
        XCTAssertGreaterThanOrEqual(
            source.components(separatedBy: "persistReaderPreferences()").count - 1, 5
        )
    }
}
