import Combine
import XCTest
@testable import Atria

@MainActor
final class AtriaTrendProjectionStoreTests: XCTestCase {
    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ year: Int,
                      _ month: Int,
                      _ day: Int,
                      _ hour: Int = 0) -> Date {
        utcCalendar.date(from: DateComponents(year: year,
                                              month: month,
                                              day: day,
                                              hour: hour))!
    }

    private func trendSession(id: String,
                              start: Date,
                              bpm: Int,
                              persistedHRV: Int? = nil) -> SavedSession {
        let end = start.addingTimeInterval(10 * 60)
        return SavedSession(
            id: UUID(uuidString: id)!,
            start: start,
            end: end,
            label: "Trend fixture",
            points: (0...10).map {
                SavedSession.Point(t: Double($0 * 60), bpm: bpm)
            },
            hrv: persistedHRV,
            eventTimeZoneIdentifier: "UTC"
        )
    }

    private func state(points: [AtriaTrendPoint] = [],
                       revision: Int = 0,
                       restingHR: Int? = nil,
                       events: [AtriaChartEvent] = []) -> AtriaTrendChartProjectionState {
        AtriaTrendChartProjectionState(points: points,
                                       pointsRevision: revision,
                                       baselineRestingHR: restingHR,
                                       events: events)
    }

    func testEqualTrendProjectionDoesNotPublish() {
        let initial = state()
        let projection = AtriaTrendChartProjectionStore(state: initial)
        var publications = 0
        let cancellable = projection.objectWillChange.sink { publications += 1 }

        XCTAssertFalse(projection.refresh(initial))
        XCTAssertEqual(publications, 0)
        withExtendedLifetime(cancellable) {}
    }

    func testRelevantTrendProjectionPublishesExactlyOnce() {
        let projection = AtriaTrendChartProjectionStore(state: state())
        var publications = 0
        let cancellable = projection.objectWillChange.sink { publications += 1 }
        let points = [AtriaTrendPoint(id: UUID(),
                                      date: Date(timeIntervalSinceReferenceDate: 800_000_000),
                                      restingHR: 58,
                                      strain: 8.2,
                                      hrv: 61)]

        XCTAssertTrue(projection.refresh(state(points: points, revision: 1, restingHR: 58)))
        XCTAssertEqual(publications, 1)
        withExtendedLifetime(cancellable) {}
    }

    func testOverviewTrendPointsAggregateSessionsIntoDeterministicCivilDays() throws {
        let firstDayMorning = trendSession(
            id: "00000000-0000-4000-8000-000000000001",
            start: date(2026, 7, 27, 8),
            bpm: 62
        )
        let firstDayEvening = trendSession(
            id: "00000000-0000-4000-8000-000000000002",
            start: date(2026, 7, 27, 18),
            bpm: 64,
            persistedHRV: 88
        )
        let secondDay = trendSession(
            id: "00000000-0000-4000-8000-000000000003",
            start: date(2026, 7, 28, 9),
            bpm: 66
        )
        let sessions = [secondDay, firstDayEvening, firstDayMorning]

        let points = SessionStore.makeOverviewTrendPoints(
            sessions: sessions,
            rest: 60,
            maxHR: 190,
            now: date(2026, 7, 29, 12),
            calendar: utcCalendar
        )
        let reversed = SessionStore.makeOverviewTrendPoints(
            sessions: Array(sessions.reversed()),
            rest: 60,
            maxHR: 190,
            now: date(2026, 7, 29, 12),
            calendar: utcCalendar
        )

        XCTAssertEqual(points, reversed)
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points.map(\.date), [
            date(2026, 7, 27),
            date(2026, 7, 28),
        ])
        XCTAssertEqual(points[0].id, firstDayMorning.id)
        XCTAssertEqual(points[0].restingHR, 62)
        XCTAssertNil(points[0].hrv)
        XCTAssertEqual(
            try XCTUnwrap(points[0].strain),
            Metrics.strain(
                fromTRIMP:
                    firstDayMorning.trimp(rest: 60, max: 190)
                    + firstDayEvening.trimp(rest: 60, max: 190)
            ),
            accuracy: 0.000_001
        )
        XCTAssertEqual(points[1].restingHR, 66)
    }

    func testCompactTrendXAxisUsesDistinctObservedDays() {
        let twoDays = [
            date(2026, 7, 27),
            date(2026, 7, 28),
        ]
        XCTAssertEqual(
            AtriaTrendChartCard.compactXAxisDates(twoDays),
            twoDays
        )

        let month = (0..<30).map {
            utcCalendar.date(
                byAdding: .day,
                value: $0,
                to: date(2026, 7, 1)
            )!
        }
        let compact = AtriaTrendChartCard.compactXAxisDates(month)
        XCTAssertEqual(compact.count, 4)
        XCTAssertEqual(compact.first, month.first)
        XCTAssertEqual(compact.last, month.last)
        XCTAssertEqual(Set(compact).count, compact.count)
    }

    // 2026-08-01 migration: the parallel Spacer-based label HStack (guessed
    // 34pt inset, equal spacing) is gone — it rendered duplicated/misaligned
    // date labels under true-position gridlines on gappy series (History
    // audit, 2026-07-31). Labels now ride the SAME AxisMarks values as the
    // gridlines, so this pin asserts the axis-attached pattern instead.
    func testCompactTrendXAxisKeepsEdgeLabelsInsideClippedChart() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaTrendChart.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(
            source.contains(
                ".chartXScale(range: .plotDimension(startPadding: 18, endPadding: 18))"
            )
        )
        XCTAssertTrue(source.contains("AxisMarks(preset: .aligned, values: chartXAxisDates)"))
        XCTAssertTrue(source.contains("chartXAxisLabels[date]"))
        XCTAssertFalse(source.contains("private var compactXAxisLabelRow"))
        XCTAssertFalse(
            source.contains(
                "AxisValueLabel(format: .dateTime.month(.abbreviated).day())"
            )
        )
    }

    func testCompactTrendXAxisLabelTextsDedupSameLabelTicks() {
        // Four real instants inside one civil day format to one visible label:
        // the map keeps the first tick's label and drops the repeats, so the
        // chart can never render "Jul 27 Jul 27 Jul 27" (nor the Vitals
        // timeline's duplicated "11a"-style variant of the same defect).
        // Midday-UTC instants so every zone within UTC-10...UTC+10 keeps all
        // four on the same civil day (the formatter runs in device-local time).
        let sameDay = [
            date(2026, 7, 27, 10),
            date(2026, 7, 27, 11),
            date(2026, 7, 27, 12),
            date(2026, 7, 27, 13),
        ]
        let deduped = AtriaTrendChartCard.compactXAxisLabelTexts(sameDay)
        XCTAssertEqual(deduped.count, 1)
        XCTAssertEqual(deduped.keys.first, sameDay.first)

        // Distinct days keep one label per tick, all distinct.
        let distinct = [date(2026, 7, 27, 12), date(2026, 7, 28, 12), date(2026, 7, 30, 12)]
        let labels = AtriaTrendChartCard.compactXAxisLabelTexts(distinct)
        XCTAssertEqual(labels.count, distinct.count)
        XCTAssertEqual(Set(labels.values).count, distinct.count)
    }

    func testPriorTrendComparisonRequiresQualifiedEvidenceOnBothSides() {
        XCTAssertFalse(
            AtriaTrendComparisonPolicy.isAvailable(
                currentCount: 3,
                priorCount: 7,
                range: .week
            ),
            "A full prior week must not make a sparse current week comparable"
        )
        XCTAssertFalse(
            AtriaTrendComparisonPolicy.isAvailable(
                currentCount: 7,
                priorCount: 3,
                range: .week
            ),
            "A few old readings must not become a dotted comparison line"
        )
        XCTAssertTrue(
            AtriaTrendComparisonPolicy.isAvailable(
                currentCount: 4,
                priorCount: 4,
                range: .week
            )
        )
        XCTAssertFalse(
            AtriaTrendComparisonPolicy.isAvailable(
                currentCount: 11,
                priorCount: 30,
                range: .month
            )
        )
        XCTAssertTrue(
            AtriaTrendComparisonPolicy.isAvailable(
                currentCount: 12,
                priorCount: 12,
                range: .month
            )
        )
        XCTAssertFalse(
            AtriaTrendComparisonPolicy.isAvailable(
                currentCount: 100,
                priorCount: 100,
                range: .all
            )
        )
    }

    func testHiddenPriorValuesDoNotFlattenCurrentTrendScale() {
        let currentOnly = AtriaTrendComparisonPolicy.domain(
            currentValues: [58, 60, 62],
            priorValues: [120],
            includesPrior: false
        )
        let comparison = AtriaTrendComparisonPolicy.domain(
            currentValues: [58, 60, 62],
            priorValues: [120],
            includesPrior: true
        )

        XCTAssertLessThan(currentOnly.upperBound, 70)
        XCTAssertGreaterThan(comparison.upperBound, 120)
        XCTAssertLessThanOrEqual(comparison.lowerBound, 58)
    }

    func testDailyTrendSegmentationBreaksAtMissingCivilDays() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let start = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 1, hour: 8
        )))
        let samples = [0, 1, 3, 4].map { offset in
            AtriaTrendPoint.Sample(
                date: calendar.date(byAdding: .day, value: offset, to: start)!,
                value: Double(60 + offset)
            )
        }

        let segmented = AtriaTrendGapPolicy.assigningSegments(
            to: Array(samples.reversed()),
            calendar: calendar
        )

        XCTAssertEqual(segmented.map(\.date), samples.map(\.date),
                       "segmentation should restore chronological order once, before render")
        XCTAssertEqual(segmented.map(\.segment), [0, 0, 1, 1],
                       "the absent August 3 reading must break both trend lines")
        XCTAssertEqual(segmented.map(\.value), samples.map(\.value),
                       "gap handling must not average or synthesize values")
    }

    func testSparseGrammarWithholdsAreaFillUntilFiveContiguousObservationsAndCoverageTarget() {
        // A contiguous run of 0-4 observed days never draws an area fill: a couple
        // of real points must not read as a filled "mountain".
        for run in 0...4 {
            XCTAssertFalse(AtriaTrendSparseGrammar.areaAllowed(longestContiguousRun: run,
                                                               confidenceTargetPoints: 4))
        }
        // A contiguous run of 5+ with the week coverage target (4) met -> fill.
        XCTAssertTrue(AtriaTrendSparseGrammar.areaAllowed(longestContiguousRun: 5,
                                                          confidenceTargetPoints: 4))
        // 5+ contiguous but below a higher (month) coverage target stays fill-free.
        XCTAssertFalse(AtriaTrendSparseGrammar.areaAllowed(longestContiguousRun: 6,
                                                           confidenceTargetPoints: 12))
        XCTAssertTrue(AtriaTrendSparseGrammar.areaAllowed(longestContiguousRun: 12,
                                                          confidenceTargetPoints: 12))
    }

    func testSparseGrammarLongestContiguousRunGatesFillOnGaps() {
        // Five total observations but split by a gap into a lone day + a 4-day run
        // must NOT fill: the longest contiguous run is 4. Gating on the raw total
        // would draw a mountain across a day that was never worn.
        let gappy = [0, 1, 1, 1, 1]
        XCTAssertEqual(AtriaTrendSparseGrammar.longestContiguousRun(gappy), 4)
        XCTAssertFalse(AtriaTrendSparseGrammar.areaAllowed(
            longestContiguousRun: AtriaTrendSparseGrammar.longestContiguousRun(gappy),
            confidenceTargetPoints: 4
        ))
        // A genuinely contiguous 5-day run fills.
        let contiguous = [0, 0, 0, 0, 0]
        XCTAssertEqual(AtriaTrendSparseGrammar.longestContiguousRun(contiguous), 5)
        XCTAssertTrue(AtriaTrendSparseGrammar.areaAllowed(
            longestContiguousRun: AtriaTrendSparseGrammar.longestContiguousRun(contiguous),
            confidenceTargetPoints: 4
        ))
        XCTAssertEqual(AtriaTrendSparseGrammar.longestContiguousRun([]), 0)
    }

    func testSparseGrammarMarksEveryDayOnlyWhenSparse() {
        for count in 1...4 {
            XCTAssertTrue(AtriaTrendSparseGrammar.marksEveryPoint(observedCount: count))
        }
        for count in 5...9 {
            XCTAssertFalse(AtriaTrendSparseGrammar.marksEveryPoint(observedCount: count))
        }
    }

    func testSparseGrammarFlagsEveryLoneDaySegmentForAVisiblePoint() {
        // Two observations separated by a missing civil day -> two singleton
        // segments -> BOTH must be flagged so neither becomes invisible.
        let segments = AtriaTrendGapPolicy.assigningSegments(
            to: [
                AtriaTrendPoint.Sample(date: date(2026, 7, 1), value: 60, segment: 0),
                AtriaTrendPoint.Sample(date: date(2026, 7, 3), value: 64, segment: 0),
            ],
            calendar: utcCalendar
        ).map(\.segment)
        XCTAssertEqual(segments, [0, 1])
        XCTAssertEqual(AtriaTrendSparseGrammar.singletonSegments(segments), Set([0, 1]))
        // A contiguous run of two shares one non-singleton segment.
        XCTAssertEqual(AtriaTrendSparseGrammar.singletonSegments([0, 0, 1]), Set([1]))
    }

    func testSparseGrammarShrinksCardHeightForSparseWindows() {
        XCTAssertEqual(AtriaTrendSparseGrammar.chartHeight(observedCount: 1), 132)
        XCTAssertEqual(AtriaTrendSparseGrammar.chartHeight(observedCount: 3), 164)
        XCTAssertEqual(AtriaTrendSparseGrammar.chartHeight(observedCount: 8), 210)
    }

    func testTrendCardGatesAreaFillAndMarksEveryObservedDay() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaTrendChart.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let cardStart = try XCTUnwrap(source.range(of: "struct AtriaTrendChartCard: View"))
        let cardEnd = try XCTUnwrap(source.range(of: "private struct AtriaTrendPeriodReadout",
                                                 range: cardStart.lowerBound..<source.endIndex))
        let card = String(source[cardStart.lowerBound..<cardEnd.lowerBound])
        XCTAssertTrue(card.contains("if trendAreaAllowed {"),
                      "the area fill must be gated behind the density policy")
        XCTAssertTrue(card.contains("if trendPointMarkVisible(sample) {"),
                      "every qualifying observed day gets a PointMark, not only the last")
        XCTAssertFalse(card.contains("if let latest = prepared.series.last {"),
                      "the last-point-only PointMark must be gone")
    }

    func testTrendChartHasNoAutomaticBaselineRuleAndLabelsOptInComparison() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaTrendChart.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let cardStart = try XCTUnwrap(source.range(of: "struct AtriaTrendChartCard: View"))
        let cardEnd = try XCTUnwrap(
            source.range(
                of: "private struct AtriaTrendPeriodReadout",
                range: cardStart.lowerBound..<source.endIndex
            )
        )
        let card = String(source[cardStart.lowerBound..<cardEnd.lowerBound])

        XCTAssertFalse(card.contains("RuleMark(y: .value(\"Baseline\""))
        XCTAssertTrue(card.contains("Compare prior \\(range.narrativeLabel)"))
        XCTAssertTrue(card.contains("showsPriorPeriod && priorComparisonIsAvailable"))
        XCTAssertTrue(card.contains("current-line-\\(sample.segment)"))
        XCTAssertTrue(card.contains("prior-\\(ghostSample.segment)"))
        XCTAssertTrue(card.contains("segment: $0.segment"),
                      "the expanded chart must preserve the compact chart's observed-run breaks")

        let expanded = try String(
            contentsOf: sourceURL
                .deletingLastPathComponent()
                .appendingPathComponent("AtriaExpandedChart.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(expanded.contains("current-\\(point.segment)"))
        XCTAssertTrue(expanded.contains("current-fill-\\(point.segment)"))
        XCTAssertTrue(expanded.contains("segment: point.segment"),
                      "rescaling an overlay must not erase its real collection gaps")

        let insights = try String(
            contentsOf: sourceURL.deletingLastPathComponent().appendingPathComponent("Insights.swift"),
            encoding: .utf8
        )
        let restingStart = try XCTUnwrap(insights.range(of: "struct RestingTrendChart: View"))
        let restingEnd = try XCTUnwrap(
            insights.range(
                of: "// MARK: - Session time-in-zone breakdown",
                range: restingStart.lowerBound..<insights.endIndex
            )
        )
        let restingChart = String(insights[restingStart.lowerBound..<restingEnd.lowerBound])
        XCTAssertFalse(restingChart.contains("RuleMark(y: .value(\"Baseline\""))
        XCTAssertTrue(restingChart.contains("resting-\\(sample.segment)"))
        XCTAssertTrue(restingChart.contains("subtitle: baseline.map { \"Baseline \\($0) bpm\" }"))
    }

    func testTrendHostUsesNarrowProjectionInsteadOfWholeSessionStoreObservation() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaTrendChart.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let hostStart = try XCTUnwrap(source.range(of: "struct AtriaOverviewTrendChartHost: View"))
        let hostEnd = try XCTUnwrap(source.range(of: "enum AtriaTrendRange", range: hostStart.lowerBound..<source.endIndex))
        let host = String(source[hostStart.lowerBound..<hostEnd.lowerBound])

        XCTAssertTrue(host.contains("let store: SessionStore"))
        XCTAssertTrue(host.contains("@StateObject private var projectionStore: AtriaTrendChartProjectionStore"))
        XCTAssertFalse(host.contains("@ObservedObject var store"))
        XCTAssertTrue(host.contains("store.$overviewTrendPoints"))
        XCTAssertTrue(host.contains("store.$baseline"))
        XCTAssertTrue(host.contains("store.$sleepHistorySnapshot"))
        XCTAssertTrue(host.contains("store.confirmedWorkoutsRevision != self.confirmedWorkoutsRevision"))
    }
}
