import XCTest
@testable import Atria

/// P4 percent-basis unification (2026-08-20): the sleep review sheet's
/// per-stage distribution rows read the same largest-remainder
/// shares-of-classified-time legend as the hypnogram card
/// (`AtriaSleepStagePresentation.shares` via
/// `AtriaSleepHypnogramPresentation.legend`). The former fraction-of-span
/// basis let unscored gap time silently dilute every percent and the row
/// percents never summed to 100 on gap-y nights. Durations stay real
/// minutes — never re-derived from percent.
final class AtriaSleepStagePercentBasisTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "GMT")!
        return calendar
    }

    /// Post-2026-08-06 fixture time base (2026-08-18/19 overnight).
    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 8, day: day,
                                           hour: hour, minute: minute))!
    }

    private func segment(_ id: String,
                         _ stage: SleepStageKind,
                         from start: Date,
                         to end: Date) -> SleepStageSegment {
        SleepStageSegment(id: id, start: start, end: end, stage: stage)
    }

    /// A gap-y night: an 8h window (10p–6a) with only 6h of classified time —
    /// a 2h unscored hole from 1a to 3a (no interpolation, ever).
    private func gapNightSegments() -> [SleepStageSegment] {
        [
            segment("light", .light, from: date(18, 22), to: date(19, 1)),   // 3h
            segment("deep", .deep, from: date(19, 3), to: date(19, 5)),      // 2h
            segment("rem", .rem, from: date(19, 5), to: date(19, 6))         // 1h
        ]
    }

    // MARK: - The shares basis is the one percent authority

    func testLegendPercentsEqualSharesAndSumTo100OnAGapyNight() {
        let segments = gapNightSegments()
        let legend = AtriaSleepHypnogramPresentation.legend(for: segments)
        let shares = AtriaSleepStagePresentation.shares(for: segments)

        XCTAssertEqual(legend.reduce(0) { $0 + $1.percent }, 100)
        XCTAssertEqual(shares.reduce(0) { $0 + $1.percent }, 100)
        for entry in legend {
            XCTAssertEqual(entry.percent,
                           shares.first(where: { $0.stage == entry.stage })?.percent,
                           "\(entry.stage): the legend and the editor shares are one basis")
        }
        // Classified-time proportions with largest-remainder rounding:
        // light 3/6 → 50, deep 2/6 → 33, rem 1/6 → 17.
        XCTAssertEqual(legend.first { $0.stage == .light }?.percent, 50)
        XCTAssertEqual(legend.first { $0.stage == .deep }?.percent, 33)
        XCTAssertEqual(legend.first { $0.stage == .rem }?.percent, 17)
    }

    func testUnscoredGapTimeNoLongerDilutesThePercents() {
        let segments = gapNightSegments()
        let spanSeconds = date(19, 6).timeIntervalSince(date(18, 22)) // 8h window

        // The retired fraction-of-span basis: 38 + 25 + 13 = 76 — the rows
        // could never account for themselves on a night with unscored holes.
        let spanBasisTotal = segments.reduce(0) { total, segment in
            total + Int((segment.duration / spanSeconds * 100).rounded())
        }
        XCTAssertEqual(spanBasisTotal, 76,
                       "the fixture must exercise a genuinely diluted span basis")

        let legend = AtriaSleepHypnogramPresentation.legend(for: segments)
        XCTAssertEqual(legend.reduce(0) { $0 + $1.percent }, 100,
                       "shares of classified time always account for the whole")
    }

    // MARK: - Durations stay real minutes

    func testLegendMinutesAreRealDurationsNeverDerivedFromPercent() {
        let legend = AtriaSleepHypnogramPresentation.legend(for: gapNightSegments())

        XCTAssertEqual(legend.first { $0.stage == .light }?.minutes, 180)
        XCTAssertEqual(legend.first { $0.stage == .deep }?.minutes, 120)
        XCTAssertEqual(legend.first { $0.stage == .rem }?.minutes, 60)
        // 360 real classified minutes — not 480 window minutes, and not a
        // percent-times-span reconstruction.
        XCTAssertEqual(legend.reduce(0) { $0 + $1.minutes }, 360)
    }

    func testSWSMinutesFoldIntoTheDeepRow() {
        let segments = [
            segment("sws", .sws, from: date(18, 23), to: date(19, 0)),   // 1h
            segment("deep", .deep, from: date(19, 0), to: date(19, 1)),  // 1h
            segment("light", .light, from: date(19, 1), to: date(19, 3)) // 2h
        ]
        let legend = AtriaSleepHypnogramPresentation.legend(for: segments)

        XCTAssertEqual(legend.map(\.stage), [.light, .deep],
                       "SWS never surfaces as its own row")
        XCTAssertEqual(legend.first { $0.stage == .deep }?.minutes, 120)
        XCTAssertEqual(legend.first { $0.stage == .deep }?.percent, 50)
    }

    func testLargestRemainderResolvesAnEqualThreeWaySplit() {
        let segments = [
            segment("a", .light, from: date(18, 22), to: date(18, 23)),
            segment("b", .rem, from: date(18, 23), to: date(19, 0)),
            segment("c", .deep, from: date(19, 0), to: date(19, 1))
        ]
        let legend = AtriaSleepHypnogramPresentation.legend(for: segments)

        XCTAssertEqual(legend.reduce(0) { $0 + $1.percent }, 100)
        XCTAssertEqual(legend.map(\.percent).sorted(), [33, 33, 34])
    }

    func testEmptySegmentsYieldNoRows() {
        XCTAssertTrue(AtriaSleepHypnogramPresentation.legend(for: []).isEmpty)
    }

    // MARK: - The night feed the review sheet consumes

    func testValidatedNightDisplaySegmentsLegendSumsTo100() {
        let start = date(18, 22, 30)
        let end = date(19, 6, 15)
        let third = end.timeIntervalSince(start) / 3
        let night = SleepHistorySnapshot.Night(
            id: "p4-basis",
            day: calendar.startOfDay(for: end),
            start: start,
            end: end,
            duration: end.timeIntervalSince(start),
            restingHR: 51,
            hrv: 62,
            respiratoryRate: 14.1,
            sleepEfficiency: 0.93,
            confidence: "ready",
            source: "sleep",
            confirmed: true,
            stageSegments: [
                segment("a", .light, from: start, to: start.addingTimeInterval(third)),
                segment("b", .sws, from: start.addingTimeInterval(third),
                        to: start.addingTimeInterval(2 * third)),
                segment("c", .rem, from: start.addingTimeInterval(2 * third), to: end)
            ],
            motionValidated: true
        )

        let legend = AtriaSleepHypnogramPresentation.legend(for: night.displayStageSegments)
        XCTAssertFalse(legend.isEmpty)
        XCTAssertEqual(legend.reduce(0) { $0 + $1.percent }, 100)
        XCTAssertTrue(legend.contains { $0.stage == .deep },
                      "the stored SWS band reaches the rows as Deep")
    }

    // MARK: - Source pins: the review sheet reads the legend basis

    func testReviewSheetStageRowsReadTheLegendNotFractionOfSpan() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaActivityMonitor.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "struct AtriaSleepActivityReviewSheet: View"))
        let end = try XCTUnwrap(source.range(of: "private var nightVitals: some View",
                                             range: start.lowerBound..<source.endIndex))
        let sheet = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(sheet.contains("AtriaSleepHypnogramPresentation.legend(for: night.displayStageSegments)"),
                      "the rows must read the shared legend authority")
        XCTAssertTrue(sheet.contains("let fraction = Double(row.percent) / 100"),
                      "the bar pixels mirror the displayed percent exactly")
        XCTAssertFalse(sheet.contains("row.seconds / spanSeconds"),
                       "the fraction-of-span basis is retired")
        XCTAssertFalse(sheet.contains("private var spanSeconds"),
                       "no span denominator survives in the review sheet")
    }
}
