import XCTest
@testable import Atria

/// Chart backlog P1 (2026-08-04): the About-sheet last-30-days mini-trend.
///
/// Contracts: (1) the honesty gate — under 5 real readings the trend is nil and
/// the sheet shows no plot at all; (2) the value transforms match the metric
/// detail charts exactly (HRV = e^lnRMSSD, sleep in hours); (3) only the last
/// 30 days count; (4) metrics with no persisted daily history (stress, blood
/// oxygen) never produce a trend.
final class AtriaAboutMetricTrendTests: XCTestCase {
    private let calendar = Calendar.current
    private let reference = Date(timeIntervalSince1970: 1_785_000_000) // fixed

    private func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: -offset,
                      to: calendar.startOfDay(for: reference))!
    }

    private func rollup(daysAgo: Int,
                        recovery: Int? = nil,
                        lnRMSSD: Double? = nil,
                        sleepSeconds: TimeInterval? = nil) -> DailyRollupStoreEntry {
        DailyRollupStoreEntry(day: day(daysAgo),
                              recovery: recovery,
                              lnRMSSD: lnRMSSD,
                              sleepSeconds: sleepSeconds,
                              calendar: calendar)
    }

    func testUnderFiveReadingsProducesNoTrend() {
        let rollups = (0..<4).map { rollup(daysAgo: $0, recovery: 60 + $0) }
        XCTAssertNil(AtriaAboutMetricTrend.make(for: .recovery,
                                                rollups: rollups,
                                                referenceDate: reference,
                                                calendar: calendar))
    }

    func testFiveReadingsProduceATrendWithHonestCaption() {
        let rollups = (0..<5).map { rollup(daysAgo: $0, recovery: 60 + $0) }
        let trend = AtriaAboutMetricTrend.make(for: .recovery,
                                               rollups: rollups,
                                               referenceDate: reference,
                                               calendar: calendar)
        XCTAssertEqual(trend?.points.count, 5)
        XCTAssertEqual(trend?.caption, "5 nights · 60–64%")
    }

    func testHRVUsesTheSameTransformAsTheDetailChart() {
        let rollups = (0..<5).map { rollup(daysAgo: $0, lnRMSSD: log(64.0)) }
        let trend = AtriaAboutMetricTrend.make(for: .hrv,
                                               rollups: rollups,
                                               referenceDate: reference,
                                               calendar: calendar)
        XCTAssertEqual(trend?.points.first?.value, 64.0)
        XCTAssertEqual(trend?.caption, "5 nights · steady at 64 ms")
    }

    func testSleepIsReportedInHoursAndZeroDurationNightsAreExcluded() {
        var rollups = (0..<5).map { rollup(daysAgo: $0, sleepSeconds: 7.5 * 3_600) }
        rollups.append(rollup(daysAgo: 5, sleepSeconds: 0))
        let trend = AtriaAboutMetricTrend.make(for: .sleep,
                                               rollups: rollups,
                                               referenceDate: reference,
                                               calendar: calendar)
        XCTAssertEqual(trend?.points.count, 5)
        XCTAssertEqual(trend?.caption, "5 nights · steady at 7.5 h")
    }

    func testReadingsOlderThanThirtyDaysDoNotCount() {
        // 5 readings exist, but only 3 fall inside the window → no trend.
        let rollups = [0, 1, 2, 35, 40].map { rollup(daysAgo: $0, recovery: 70) }
        XCTAssertNil(AtriaAboutMetricTrend.make(for: .recovery,
                                                rollups: rollups,
                                                referenceDate: reference,
                                                calendar: calendar))
    }

    func testMetricsWithoutDailyHistoryNeverProduceATrend() {
        let rollups = (0..<10).map {
            rollup(daysAgo: $0, recovery: 70, lnRMSSD: log(60.0), sleepSeconds: 8 * 3_600)
        }
        for metric in [AtriaAboutMetric.stress, .bloodOxygen] {
            XCTAssertNil(AtriaAboutMetricTrend.make(for: metric,
                                                    rollups: rollups,
                                                    referenceDate: reference,
                                                    calendar: calendar),
                         "\(metric) has no persisted daily history; a trend here would be fabricated")
        }
    }

    func testPointsAreChronologicalAndClippedToTheWindow() {
        let rollups = [3, 0, 7, 1, 2, 31].map { rollup(daysAgo: $0, recovery: 70) }
        let trend = AtriaAboutMetricTrend.make(for: .recovery,
                                               rollups: rollups,
                                               referenceDate: reference,
                                               calendar: calendar)
        let days = trend?.points.map(\.day) ?? []
        XCTAssertEqual(days, days.sorted())
        XCTAssertEqual(days.count, 5)
        XCTAssertTrue(days.allSatisfy { trend!.window.contains($0) })
    }
}
