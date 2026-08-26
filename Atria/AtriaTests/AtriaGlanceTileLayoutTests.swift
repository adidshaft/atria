import XCTest
@testable import Atria

/// Owner feedback on the At a Glance grid (2026-08-26, device screenshot):
/// make every card the same size, fix the cropped line on the stress card, and
/// give each card a small chart in its top-right corner.
///
/// These are source-scan assertions because the grid is SwiftUI and the three
/// facts are structural — a height, a line limit, and a gate on drawing a chart
/// at all. Each pins the *property*, not the formatting.
final class AtriaGlanceTileLayoutTests: XCTestCase {

    private func todayScreen() throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Atria/AtriaTodayScreen.swift"),
            encoding: .utf8
        )
    }

    // MARK: - Equal cards

    func testEveryGlanceTileIsTheSameHeight() throws {
        // The sizes used to return 94 for wide and 74 for compact, so a row of
        // tall tiles sat beside a row of short ones and the grid read ragged.
        let source = try todayScreen()
        XCTAssertTrue(source.contains("var minHeight: CGFloat { 100 }"),
                      "one height for every tile")
        XCTAssertFalse(source.contains("case .wide: return 94"),
                       "the per-size heights must be gone, not shadowed")
    }

    func testTilesAlignToTheTopSoEqualHeightsLookEqual() throws {
        // With a uniform height, centring the content would make cards with
        // shorter details float and defeat the point.
        let source = try todayScreen()
        XCTAssertTrue(
            source.contains("minHeight: item.layoutSize.minHeight, alignment: .topLeading"),
            "content pins to the top of the fixed box"
        )
    }

    // MARK: - The cropped stress line

    func testTheDetailLineWrapsInsteadOfCropping() throws {
        // "Calm · HR-only estimate · lower confidence" cropped to
        // "…lower con…" on device, hiding the confidence qualifier that makes
        // the reading honest.
        // Bounded by the block's own structural end, not by a character count.
        // A fixed-size window fails the moment someone writes a longer comment,
        // which is pinning formatting rather than behaviour.
        let source = try todayScreen()
        let marker = "item.detail.isEmpty && item.layoutSize != .wideShort"
        let start = try XCTUnwrap(source.range(of: marker))
        let end = try XCTUnwrap(
            source.range(of: ".frame(maxWidth: .infinity, minHeight:",
                         range: start.upperBound..<source.endIndex)
        )
        let window = String(source[start.upperBound..<end.lowerBound])
        XCTAssertTrue(window.contains(".lineLimit(2)"),
                      "the detail line must be allowed a second line")
        XCTAssertTrue(window.contains("fixedSize(horizontal: false, vertical: true)"),
                      "and must be allowed to take the height it needs")
    }

    // MARK: - Corner sparkline

    func testASparklineNeedsRealReadingsBeforeItDrawsAnything() throws {
        let source = try todayScreen()
        XCTAssertTrue(source.contains("static let minimumPoints = 3"))
        XCTAssertTrue(
            source.contains("item.trend.count >= AtriaGlanceSparkline.minimumPoints"),
            "a metric with too little history must draw no chart at all"
        )
    }

    func testMissingDaysAreSkippedRatherThanZeroFilled() throws {
        // A gap in the record must never render as a value. Every series is
        // built with compactMap over optionals, so a day with no reading
        // contributes nothing instead of a zero or an interpolation.
        let source = try todayScreen()
        let start = try XCTUnwrap(source.range(of: "private func glanceTrend(for metric:"))
        let body = String(source[start.lowerBound...].prefix(1_400))
        XCTAssertFalse(body.contains("?? 0"),
                       "a missing day must not become a zero reading")
        XCTAssertFalse(body.contains("map { $0 ?? "),
                       "and must not be filled from a neighbour")
        for series in ["$0.recovery.map(Double.init)",
                       "compactMap(\\.strain)",
                       "compactMap(\\.lnRMSSD)",
                       "$0.rhr.map(Double.init)"] {
            XCTAssertTrue(body.contains(series), "missing series: \(series)")
        }
    }

    func testTheTrendFieldDefaultsToEmptySoExistingTilesDrawNoChart() throws {
        // ~20 construction sites exist; a metric with no series must compile
        // and simply show nothing rather than be forced to invent one.
        let source = try todayScreen()
        XCTAssertTrue(source.contains("var trend: [Double] = []"),
                      "the field must default to empty")
    }

    func testTheSparklineIsBoundedSoItCannotCrowdTheTile() throws {
        // The frame is a layout fact with no API to read, so it stays a source
        // check. The bar bound is NOT — it is a value, and asserting on the
        // text "private static let maximumBars = 7" broke the moment the
        // declaration lost `private` to become testable. Pin the value.
        let source = try todayScreen()
        XCTAssertTrue(source.contains(".frame(width: 34, height: 16)"),
                      "the corner chart is a fixed, small size")
        XCTAssertEqual(AtriaGlanceSparkline.maximumBars, 7,
                       "and shows a bounded number of days")
    }

    // MARK: - Sparkline geometry
    //
    // A corner chart is exactly the kind of thing that silently draws nothing,
    // draws upside down, or divides by zero — none of which shows up in a green
    // build, and none of which I could confirm by rendering (the simulator has
    // no rollup history in its default state). So the maths is tested directly.

    private typealias Spark = AtriaGlanceSparkline

    func testTheHighestReadingIsTheTallestAndTheLowestIsTheShortest() {
        let low = Spark.barFraction(value: 54, low: 54, high: 58)
        let mid = Spark.barFraction(value: 56, low: 54, high: 58)
        let high = Spark.barFraction(value: 58, low: 54, high: 58)
        XCTAssertLessThan(low, mid)
        XCTAssertLessThan(mid, high)
    }

    func testEvenTheSeriesMinimumStillDrawsAVisibleBar() {
        // Scaling straight to zero would erase the lowest day entirely, which
        // reads as "no data" rather than "the lowest reading".
        XCTAssertGreaterThanOrEqual(
            Spark.barFraction(value: 54, low: 54, high: 58), 0.25
        )
    }

    func testTheHighestReadingNeverOverflowsTheChart() {
        XCTAssertLessThanOrEqual(
            Spark.barFraction(value: 58, low: 54, high: 58), 1.0
        )
    }

    func testAFlatSeriesDrawsEvenBarsRatherThanDividingByZero() {
        let a = Spark.barFraction(value: 60, low: 60, high: 60)
        let b = Spark.barFraction(value: 60, low: 60, high: 60)
        XCTAssertEqual(a, b)
        XCTAssertTrue(a.isFinite, "a flat series must not divide by zero")
        XCTAssertLessThan(a, 0.7, "and must not imply a rise that is not there")
    }

    func testAValueOutsideTheRangeIsClampedRatherThanDrawnOffChart() {
        XCTAssertLessThanOrEqual(
            Spark.barFraction(value: 999, low: 54, high: 58), 1.0
        )
        XCTAssertGreaterThanOrEqual(
            Spark.barFraction(value: -999, low: 54, high: 58), 0
        )
    }

    func testASmallRealRangeStillSeparatesVisibly() {
        // Resting heart rate moves 54-58 across a week. If those four bpm
        // collapsed into near-identical bars the chart would say nothing.
        let lowest = Spark.barFraction(value: 54, low: 54, high: 58)
        let highest = Spark.barFraction(value: 58, low: 54, high: 58)
        XCTAssertGreaterThan(highest - lowest, 0.5,
                             "a real weekly spread must be legible at 16pt tall")
    }

    func testTheStressSeriesIsMemoisedRatherThanRebuiltEveryRender() throws {
        // glanceItem(for:) runs on every SwiftUI body evaluation. The stress
        // archive is bounded at 2,880 points (48h), so filtering + sorting it
        // per render is the exact per-frame recompute AtriaTodayGlanceMemo was
        // added to prevent — six other glance values already use it.
        let source = try todayScreen()
        let start = try XCTUnwrap(source.range(of: "private func stressIntradaySeries()"))
        let body = String(source[start.lowerBound...].prefix(1_400))
        XCTAssertTrue(body.contains("glanceMemo.stressSeriesValue"),
                      "the series must come from the memo on a repeat render")
        XCTAssertTrue(body.contains("stressMonitorStore.historyRevision"),
                      "keyed on the store's published revision")
        XCTAssertTrue(body.contains("glanceMemo.stressSeriesCycleStart == cycleStart"),
                      "and on the cycle start — a wake rotates the window "
                          + "without the history changing, which a "
                          + "revision-only key would miss")
    }

    func testTheChartShowsABoundedNumberOfDays() {
        XCTAssertEqual(Spark.maximumBars, 7)
        XCTAssertEqual(Spark.minimumPoints, 3)
    }

    // MARK: - Shape follows sampling
    //
    // Owner's rule (2026-08-26): one chart type per card. A once-a-day value
    // (sleep, steps, recovery, strain, the nightly measures) is bars. A
    // quantity that travels through the day (stress) is a line.

    func testOnceADayMetricsUseBarsAndIntraDayMetricsUseALine() throws {
        let source = try todayScreen()
        let start = try XCTUnwrap(
            source.range(of: "private func glanceSparklineStyle(")
        )
        let body = String(source[start.lowerBound...].prefix(600))
        XCTAssertTrue(body.contains("case .stress:"),
                      "stress moves through the day")
        XCTAssertTrue(body.contains("return .line"))
        XCTAssertTrue(body.contains("default:\n            return .bars"),
                      "everything once-a-day stays bars")
    }

    func testTheLineIsFedAnIntraDaySeriesNotDailyAverages() throws {
        // Drawing seven daily averages as a line would render a shape the day
        // never had — the same dishonesty as smoothing a sparse daily trend.
        let source = try todayScreen()
        XCTAssertTrue(source.contains("case .stress:\n            // Intra-day"),
                      "stress must not fall through to the daily rollup lane")
        XCTAssertTrue(source.contains("return stressIntradaySeries()"))
        // Bounded by the function's own end, not by a character count. A
        // fixed-size window broke the moment the body grew a memo — the fifth
        // time today a distance-based slice failed on a change that did not
        // touch the behaviour being asserted.
        let start = try XCTUnwrap(
            source.range(of: "private func stressIntradaySeries()")
        )
        let end = try XCTUnwrap(
            source.range(of: "\n    private func",
                         range: start.upperBound..<source.endIndex)
        )
        let body = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("$0.t >= cycleStart"),
                      "the line must be bounded to the current cycle, not "
                          + "reach back into yesterday")
        XCTAssertTrue(body.contains("stressMonitorStore.history"),
                      "and must read the same archive the Stress monitor draws")
    }

    // MARK: - Resampling a day into 34 points

    func testAShortSeriesIsReturnedUntouchedRatherThanPadded() {
        // A padded point is a reading that did not happen.
        let short = [1.0, 2.0, 3.0]
        XCTAssertEqual(Spark.resampled(short, to: Spark.maximumLinePoints), short)
    }

    func testALongDayIsSampledDownToTheCap() {
        let day = (0..<600).map(Double.init)
        let sampled = Spark.resampled(day, to: Spark.maximumLinePoints)
        XCTAssertEqual(sampled.count, Spark.maximumLinePoints)
    }

    func testResamplingKeepsBothEndsSoTheLineStartsAndEndsWhereTheDayDid() {
        let day = (0..<600).map(Double.init)
        let sampled = Spark.resampled(day, to: Spark.maximumLinePoints)
        XCTAssertEqual(sampled.first, day.first,
                       "the day's first reading must survive")
        XCTAssertEqual(sampled.last, day.last,
                       "and its most recent one must be the line's endpoint")
    }

    func testResamplingPreservesOrderSoTheLineCannotRunBackwards() {
        let rising = (0..<300).map(Double.init)
        let sampled = Spark.resampled(rising, to: Spark.maximumLinePoints)
        XCTAssertEqual(sampled, sampled.sorted(),
                       "an ascending day must stay ascending")
    }

    func testResamplingNeverInventsAValueThatWasNotMeasured() {
        let day = (0..<200).map { Double($0) * 3 }
        let measured = Set(day)
        for value in Spark.resampled(day, to: Spark.maximumLinePoints) {
            XCTAssertTrue(measured.contains(value),
                          "\(value) was never a reading — resampling must pick "
                              + "real points, not interpolate between them")
        }
    }

    func testDegenerateCapsDoNotCrashOrEmptyTheLine() {
        let day = (0..<50).map(Double.init)
        XCTAssertEqual(Spark.resampled(day, to: 1), day)
        XCTAssertEqual(Spark.resampled(day, to: 0), day)
        XCTAssertEqual(Spark.resampled([], to: 24), [])
    }
}
