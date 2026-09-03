import SwiftUI
import XCTest
@testable import Atria

final class AtriaMetricChartPreparationTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        return calendar
    }

    func testPreparationIncludesEveryStaticDomainInputOnce() {
        let points = [
            point(day: 1, value: 60, lower: 58, upper: 64),
            point(day: 2, value: 70)
        ]
        let prior = [point(day: 1, value: 52)]

        let prepared = AtriaMetricChartPreparedData(
            points: points,
            priorPoints: prior,
            baselineBounds: 55...75,
            priorAverage: 50,
            companionPoints: [],
            calendar: calendar
        )

        XCTAssertEqual(prepared.domain.lowerBound,
                       AtriaTrendChartScale.domain(low: 50, high: 75).lowerBound,
                       accuracy: 0.000_001)
        XCTAssertEqual(prepared.domain.upperBound,
                       AtriaTrendChartScale.domain(low: 50, high: 75).upperBound,
                       accuracy: 0.000_001)
        XCTAssertTrue(prepared.hasMinMaxBand)
        XCTAssertEqual(prepared.minMaxPoints.map(\.day), [points[0].day])
    }

    func testPreparedChartKeepsTheSelectedCalendarWindowAsItsXDomain() {
        let points = [
            point(day: 28, value: 7),
            point(day: 29, value: 9)
        ]
        let monthStart = date(day: 1, hour: 0)
        let monthEnd = calendar.date(byAdding: .month, value: 1, to: monthStart)!
        let prepared = AtriaMetricChartPreparedData(
            points: points,
            priorPoints: [],
            baselineBounds: nil,
            priorAverage: nil,
            companionPoints: [],
            calendar: calendar,
            xDomain: monthStart...monthEnd
        )

        XCTAssertEqual(prepared.xDomain, monthStart...monthEnd)
        XCTAssertNotEqual(prepared.xDomain, points.first!.day...points.last!.day,
                          "A sparse month must not be stretched into the same shape as a week")
    }

    func testDayWeekMonthProjectionUsesPersistedStrainAndReactsToUpdates() throws {
        let referenceDate = date(day: 29)
        let rollups = (1...29).reversed().map { day in
            DailyRollupStoreEntry(
                day: date(day: day),
                strain: Double(day),
                calendar: calendar
            )
        }
        let chronological = Array(rollups.reversed())

        let day = periodProjection(for: chronological,
                                   referenceDate: referenceDate,
                                   range: .day)
        let week = periodProjection(for: chronological,
                                    referenceDate: referenceDate,
                                    range: .week)
        let month = periodProjection(for: chronological,
                                     referenceDate: referenceDate,
                                     range: .month)

        XCTAssertEqual(day.compactMap(\.strain), [29])
        // Week is a TRAILING seven days ending on the anchor (2026-09-02
        // owner report: 29 June is a Monday, and the calendar week containing
        // it held a single day while the strap had weeks of wear — the
        // segment says "7 days", so it shows seven). Month trails thirty, so
        // a 29-day fixture shows all of it.
        XCTAssertEqual(week.compactMap(\.strain), (23...29).map(Double.init))
        XCTAssertEqual(month.compactMap(\.strain), (1...29).map(Double.init))
        XCTAssertNotEqual(week.compactMap(\.strain),
                          month.compactMap(\.strain))

        var changedRollups = rollups
        changedRollups[0] = DailyRollupStoreEntry(
            day: date(day: 29),
            strain: 12.5,
            calendar: calendar
        )
        let changedDay = periodProjection(
            for: Array(changedRollups.reversed()),
            referenceDate: referenceDate,
            range: .day
        )
        XCTAssertEqual(changedDay.compactMap(\.strain), [12.5],
                       "The graph projection must change when persisted rollup input changes")
    }

    func testNearestPointLookupHandlesEdgesAndPreservesEarlierTieBehavior() {
        let points = [point(day: 1, value: 10), point(day: 3, value: 30), point(day: 5, value: 50)]
        let prepared = makePrepared(points: points)

        XCTAssertEqual(prepared.nearestPointIndex(to: date(day: 1).addingTimeInterval(-86_400)), 0)
        XCTAssertEqual(prepared.nearestPointIndex(to: date(day: 6)), 2)
        XCTAssertEqual(prepared.nearestPointIndex(to: date(day: 2)), 0)
        XCTAssertEqual(prepared.nearestPointIndex(to: date(day: 4, hour: 18)), 2)
    }

    func testCompanionLookupUsesPreparedCivilDayIndex() {
        let companions = [[point(day: 2, hour: 23, value: 41), point(day: 4, value: 43)]]
        let prepared = AtriaMetricChartPreparedData(
            points: [point(day: 1, value: 10), point(day: 2, value: 20)],
            priorPoints: [],
            baselineBounds: nil,
            priorAverage: nil,
            companionPoints: companions,
            calendar: calendar
        )

        XCTAssertEqual(prepared.companionPointIndex(at: 0, on: date(day: 2, hour: 1)), 0)
        XCTAssertNil(prepared.companionPointIndex(at: 0, on: date(day: 3)))
        XCTAssertNil(prepared.companionPointIndex(at: 1, on: date(day: 2)))
    }

    func testDynamicCompanionSignatureTracksPresenceAndDayButNotValue() {
        let day29 = date(day: 29)
        let day30 = date(day: 30)
        let absent = AtriaMetricChartDynamicCompanionSignature(
            companionPoints: [[]],
            currentCycleDisplayAnchor: day29,
            calendar: calendar
        )
        let present = AtriaMetricChartDynamicCompanionSignature(
            companionPoints: [[point(day: 29, value: 46)]],
            currentCycleDisplayAnchor: day29,
            calendar: calendar
        )
        let sameDayNewValue = AtriaMetricChartDynamicCompanionSignature(
            companionPoints: [[point(day: 29, value: 59)]],
            currentCycleDisplayAnchor: day29,
            calendar: calendar
        )
        let nextDay = AtriaMetricChartDynamicCompanionSignature(
            companionPoints: [[point(day: 30, value: 59)]],
            currentCycleDisplayAnchor: day30,
            calendar: calendar
        )

        XCTAssertNotEqual(absent, present)
        XCTAssertEqual(present, sameDayNewValue)
        XCTAssertNotEqual(present, nextDay)
    }

    func testCurrentCycleHRVAndRestingHeartRateAppendOrReplaceAcrossDayWeekMonth() {
        let cycleStart = date(day: 29, hour: 14)
        let current = AtriaHealthMetricAuthority.resolve(.currentCycle(.init(
            recoveryPercent: 62,
            recoveryDetail: "provisional",
            restingHeartRateText: "54",
            hrvValue: "47",
            hrvDetail: "personal · provisional",
            cycleStart: cycleStart,
            projectedAt: cycleStart.addingTimeInterval(3_600)
        )))
        let staleSameDay = [
            point(day: 28, value: 41),
            point(day: 29, value: 91)
        ]

        for range in AtriaTrendRange.primarySegments {
            let projection = AtriaHealthMetricAuthority.detailProjection(
                currentCycle: current,
                historicalRecoveryPercent: nil,
                historicalStrain: nil,
                range: range,
                periodAnchor: cycleStart,
                calendar: calendar
            )
            XCTAssertTrue(projection.usesCurrentCycle, "\(range) must include the active cycle")

            for (value, tint) in [(47.0, Metrics.electricHRV),
                                  (54.0, Metrics.electricRHR)] {
                let appended = AtriaMetricDetailCurrentCyclePointPolicy.replacingSameDay(
                    in: [],
                    value: value,
                    displayAnchor: cycleStart,
                    usesCurrentCycle: projection.usesCurrentCycle,
                    tint: tint,
                    calendar: calendar
                )
                XCTAssertEqual(appended.count, 1,
                               "\(range) must show measured current-cycle evidence before a rollup finalizes")
                XCTAssertEqual(appended.first?.value, value)
                XCTAssertTrue(calendar.isDate(appended[0].day, inSameDayAs: cycleStart))

                let replaced = AtriaMetricDetailCurrentCyclePointPolicy.replacingSameDay(
                    in: staleSameDay,
                    value: value,
                    displayAnchor: cycleStart,
                    usesCurrentCycle: projection.usesCurrentCycle,
                    tint: tint,
                    calendar: calendar
                )
                XCTAssertEqual(replaced.count, 2)
                XCTAssertEqual(replaced.filter {
                    calendar.isDate($0.day, inSameDayAs: cycleStart)
                }.map(\.value), [value],
                "\(range) must replace—not duplicate—the stale civil-day point")
            }
        }
    }

    func testCurrentCycleHRVAndRestingHeartRateDoNotLeakIntoPriorPeriods() {
        let cycleStart = date(day: 29, hour: 14)
        let current = AtriaHealthMetricAuthority.resolve(.currentCycle(.init(
            recoveryPercent: 62,
            recoveryDetail: "provisional",
            restingHeartRateText: "54",
            hrvValue: "47",
            hrvDetail: "personal · provisional",
            cycleStart: cycleStart,
            projectedAt: cycleStart.addingTimeInterval(3_600)
        )))

        for range in AtriaTrendRange.primarySegments {
            let priorAnchor = range.adjacentPeriodAnchor(
                from: cycleStart,
                offset: -1,
                calendar: calendar
            )
            let projection = AtriaHealthMetricAuthority.detailProjection(
                currentCycle: current,
                historicalRecoveryPercent: nil,
                historicalStrain: nil,
                range: range,
                periodAnchor: priorAnchor,
                calendar: calendar
            )
            XCTAssertFalse(projection.usesCurrentCycle)

            for value in [47.0, 54.0] {
                let points = AtriaMetricDetailCurrentCyclePointPolicy.replacingSameDay(
                    in: [],
                    value: value,
                    displayAnchor: cycleStart,
                    usesCurrentCycle: projection.usesCurrentCycle,
                    tint: .pink,
                    calendar: calendar
                )
                XCTAssertTrue(points.isEmpty,
                              "\(range) must not inject the active cycle after navigating backward")
            }
        }
    }

    func testMetricDetailWiresCurrentHRVAndRestingHeartRateThroughEveryChartSurface() throws {
        let source = try overviewSource()
        let policyStart = try XCTUnwrap(source.range(
            of: "enum AtriaMetricDetailCurrentCyclePointPolicy"
        ))
        let policyEnd = try XCTUnwrap(source.range(
            of: "private actor AtriaMetricDetailPreparationCache",
            range: policyStart.upperBound..<source.endIndex
        ))
        let policy = String(source[policyStart.lowerBound..<policyEnd.lowerBound])

        XCTAssertTrue(policy.contains("guard usesCurrentCycle, let displayAnchor else { return points }"))
        XCTAssertTrue(policy.contains("!calendar.isDate($0.day, inSameDayAs: currentDay)"))
        XCTAssertFalse(policy.localizedCaseInsensitiveContains("baseline"),
                       "measured/provisional HRV and RHR must not require a trusted baseline to plot")
        for token in [
            "hrvAutoPointsForSelectedPeriod",
            "hrvRawPointsForSelectedPeriod",
            "hrvDisplayPointsForSelectedPeriod",
            "hrvSummaryForSelectedPeriod",
            "hrvComparisonForSelectedPeriod",
            "restingHeartRateAutoPointsForSelectedPeriod",
            "restingHeartRateRawPointsForSelectedPeriod",
            "restingHeartRateDisplayPointsForSelectedPeriod",
            "restingHeartRateSummaryForSelectedPeriod",
            "restingHeartRateComparisonForSelectedPeriod",
        ] {
            XCTAssertTrue(source.contains(token), "missing current-cycle projection: \(token)")
        }
        XCTAssertTrue(source.contains("case .hrv:\n                    return usesCurrentCyclePrimaryRangePoint"))
        XCTAssertTrue(source.contains("case .restingHeartRate:\n                    return usesCurrentCyclePrimaryRangePoint"))
        XCTAssertTrue(source.contains("&& !isPreparingSelectedPeriod"),
                      "current-cycle evidence must wait until the selected period's prepared history is accepted")
        XCTAssertTrue(source.contains("return (\"HRV\", \"ms\", metric.tint,\n                    hrvDisplayPointsForSelectedPeriod"))
        XCTAssertTrue(source.contains("return (\"Resting HR\", \"bpm\", metric.tint,\n                    restingHeartRateDisplayPointsForSelectedPeriod"))
        XCTAssertGreaterThanOrEqual(
            source.components(separatedBy: "hrvAutoPointsForSelectedPeriod").count - 1,
            6,
            "HRV must stay current as a hero/chart value and as a sibling chart companion"
        )
        XCTAssertTrue(source.contains("currentCycleEvidenceCopy(currentCycleAuthority?.hrvDetail"),
                      "the measured/provisional authority copy must remain visible")
        XCTAssertTrue(source.contains("comparison: latest?.displaySleepEfficiency == nil"))
        XCTAssertTrue(source.contains("direction: latest?.displaySleepEfficiency.map"))
        XCTAssertTrue(source.contains("compactMap(\\.displaySleepEfficiency)"),
                      "HR-only span coverage must not enter a displayed efficiency trend or sleep plan")
        XCTAssertFalse(source.contains("compactMap(\\.sleepEfficiency)"))
    }

    func testEmptyPreparationUsesStableFallbacks() {
        let prepared = makePrepared(points: [])
        XCTAssertEqual(prepared.domain, 0...1)
        XCTAssertNil(prepared.xDomain)
        XCTAssertFalse(prepared.hasMinMaxBand)
        XCTAssertNil(prepared.nearestPointIndex(to: date(day: 1)))
    }

    private func makePrepared(points: [AtriaDetailChartPoint]) -> AtriaMetricChartPreparedData {
        AtriaMetricChartPreparedData(points: points,
                                     priorPoints: [],
                                     baselineBounds: nil,
                                     priorAverage: nil,
                                     companionPoints: [],
                                     calendar: calendar)
    }

    private func overviewSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaOverviewSections.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func periodProjection(
        for rollups: [DailyRollupStoreEntry],
        referenceDate: Date,
        range: AtriaTrendRange
    ) -> [DailyRollupStoreEntry] {
        let projection = AtriaMetricPeriodIndexProjection(
            days: rollups.map(\.day),
            referenceDate: referenceDate,
            range: range,
            calendar: calendar
        )
        return projection.currentIndices.map { rollups[$0] }
    }

    private func point(day: Int,
                       hour: Int = 12,
                       value: Double,
                       lower: Double? = nil,
                       upper: Double? = nil) -> AtriaDetailChartPoint {
        AtriaDetailChartPoint(day: date(day: day, hour: hour),
                              value: value,
                              tint: .green,
                              bandLower: lower,
                              bandUpper: upper)
    }

    private func date(day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 6, day: day, hour: hour))!
    }
}
