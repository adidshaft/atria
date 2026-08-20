import XCTest
@testable import Atria

/// P5 row strip (2026-08-20 sleep-stage design, Track 2 §2.1/2.2): one row
/// per display stage in `SleepStageKind.displayOrder` with the shares percent
/// basis, real durations, occurrence spans from the hypnogram's pure span
/// math, the mandatory estimate-label co-render, and the Deep hedge caption
/// on estimate nights. Pure presentation tests — no store, no defaults.
final class AtriaSleepStageRowStripTests: XCTestCase {
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

    private var windowStart: Date { date(18, 22) }
    private var windowEnd: Date { date(19, 6) }

    /// A gap-y night: an 8h window with 6h classified across all four display
    /// stages (including a folded SWS band) and a 1h unscored hole 1a–2a.
    private func fixtureSegments() -> [SleepStageSegment] {
        [
            segment("awake", .awake, from: date(18, 22), to: date(18, 22, 30)),   // 30m
            segment("light-1", .light, from: date(18, 22, 30), to: date(19, 0)),  // 1h30
            segment("sws", .sws, from: date(19, 0), to: date(19, 1)),             // 1h → deep
            segment("deep", .deep, from: date(19, 2), to: date(19, 3, 30)),       // 1h30
            segment("rem", .rem, from: date(19, 3, 30), to: date(19, 4, 30)),     // 1h
            segment("light-2", .light, from: date(19, 4, 30), to: date(19, 5))    // 30m
        ]
    }

    private func rows(_ segments: [SleepStageSegment],
                      isEstimated: Bool = false,
                      tier: SleepStageEstimateConfidenceTier = .standard)
        -> [AtriaSleepStageRowStripPresentation.Row] {
        AtriaSleepStageRowStripPresentation.rows(for: segments,
                                                 windowStart: windowStart,
                                                 windowEnd: windowEnd,
                                                 isEstimated: isEstimated,
                                                 tier: tier)
    }

    // MARK: - Row order and presence

    func testEveryDisplayOrderStageIsAlwaysARowInOrder() {
        let rows = rows(fixtureSegments())
        XCTAssertEqual(rows.map(\.stage), SleepStageKind.displayOrder)
        XCTAssertEqual(rows.map(\.stage), [.awake, .light, .rem, .deep])
        XCTAssertEqual(rows.map(\.name), ["Awake", "Light", "REM", "Deep"])
    }

    func testAwakeRowStaysPresentWhenTheNightHasNoAwakeTime() {
        let rows = rows([
            segment("light", .light, from: date(18, 22), to: date(19, 2)),
            segment("deep", .deep, from: date(19, 2), to: date(19, 6))
        ])
        let awake = rows.first { $0.stage == .awake }
        XCTAssertEqual(rows.count, 4, "all displayOrder rows render, present or not")
        XCTAssertEqual(awake?.percent, 0)
        XCTAssertEqual(awake?.minutes, 0)
        XCTAssertEqual(awake?.spans, [])
    }

    func testEmptySegmentsStillYieldAllFourHonestZeroRows() {
        let rows = rows([])
        XCTAssertEqual(rows.map(\.stage), SleepStageKind.displayOrder)
        XCTAssertTrue(rows.allSatisfy { $0.percent == 0 && $0.minutes == 0 && $0.spans.isEmpty })
    }

    // MARK: - Percent authority: the shares basis, summing 100

    func testRowPercentsEqualSharesAndSumTo100() {
        let segments = fixtureSegments()
        let rows = rows(segments)
        let shares = AtriaSleepStagePresentation.shares(for: segments)

        XCTAssertEqual(rows.reduce(0) { $0 + $1.percent }, 100)
        for row in rows {
            XCTAssertEqual(row.percent,
                           shares.first(where: { $0.stage == row.stage })?.percent ?? 0,
                           "\(row.stage): the strip and the shares are one percent basis")
        }
    }

    func testUnscoredGapTimeDoesNotDiluteTheRowPercents() {
        // 6h classified inside an 8h window — shares of classified time must
        // still account for the whole, never a fraction-of-span 75%.
        let rows = rows(fixtureSegments())
        XCTAssertEqual(rows.reduce(0) { $0 + $1.percent }, 100)
    }

    // MARK: - Durations are real minutes, never re-derived from percent

    func testRowMinutesAreRealDurations() {
        let rows = rows(fixtureSegments())
        XCTAssertEqual(rows.first { $0.stage == .awake }?.minutes, 30)
        XCTAssertEqual(rows.first { $0.stage == .light }?.minutes, 120)
        XCTAssertEqual(rows.first { $0.stage == .rem }?.minutes, 60)
        // SWS folds into the Deep row: 60 + 90.
        XCTAssertEqual(rows.first { $0.stage == .deep }?.minutes, 150)
        XCTAssertEqual(rows.reduce(0) { $0 + $1.minutes }, 360,
                       "real classified minutes — not window minutes")
    }

    func testDurationTextReadsZeroMinutesNotUnknown() {
        XCTAssertEqual(AtriaSleepStageRowStripPresentation.durationText(minutes: 0), "0m")
        XCTAssertEqual(AtriaSleepStageRowStripPresentation.durationText(minutes: 94), "1h 34m")
    }

    // MARK: - Occurrence spans == spans(for:) filtered per stage

    func testOccurrenceSpansAreTheHypnogramSpansFilteredPerStage() {
        let segments = fixtureSegments()
        let rows = rows(segments)
        let spans = AtriaSleepHypnogramPresentation.spans(for: segments,
                                                          windowStart: windowStart,
                                                          windowEnd: windowEnd)
        for row in rows {
            XCTAssertEqual(row.spans, spans.filter { $0.stage == row.stage },
                           "\(row.stage): one pure span math, no second grammar")
        }
        // The folded SWS band occurs on the Deep row's lane.
        XCTAssertEqual(rows.first { $0.stage == .deep }?.spans.count, 2)
        // Fractions are real wall-clock positions inside the window.
        let awakeSpan = rows.first { $0.stage == .awake }?.spans.first
        XCTAssertEqual(awakeSpan?.startFraction ?? -1, 0, accuracy: 0.0001)
        XCTAssertEqual(awakeSpan?.endFraction ?? -1, 0.0625, accuracy: 0.0001)
    }

    // MARK: - Estimate label co-render (2.0 invariant)

    func testEstimateNightsCoRenderTheMandatoryEstimateTitle() {
        XCTAssertEqual(AtriaSleepStageRowStripPresentation.headerTitle(isEstimated: true),
                       AtriaSleepStageEstimateLabel.title)
        XCTAssertEqual(AtriaSleepStageRowStripPresentation.headerTitle(isEstimated: true),
                       "Estimated stages · HR-only")
        XCTAssertEqual(AtriaSleepStageRowStripPresentation.headerTitle(isEstimated: false),
                       "Stages")
    }

    // MARK: - Per-stage hedge captions (design §1.4)

    func testDeepGetsTheHedgeCaptionOnEstimateNightsOnly() {
        let estimated = rows(fixtureSegments(), isEstimated: true)
        XCTAssertEqual(estimated.first { $0.stage == .deep }?.hedgeCaption,
                       "Hardest to detect from HR alone")
        XCTAssertNil(estimated.first { $0.stage == .rem }?.hedgeCaption,
                     "REM is the strongest HR-only call — no hedge")
        XCTAssertNil(estimated.first { $0.stage == .light }?.hedgeCaption)
        XCTAssertNil(estimated.first { $0.stage == .awake }?.hedgeCaption)

        let validated = rows(fixtureSegments(), isEstimated: false)
        XCTAssertTrue(validated.allSatisfy { $0.hedgeCaption == nil },
                      "validated nights carry no hedge captions")
    }

    func testStrongRRTierIsAcceptedWithoutSignatureChurn() {
        // Deep stays the least reliable HR-only call in either tier, so
        // `.strongRR` keeps the hedge; the tier input exists so
        // tier-differentiated per-stage copy never changes a call site.
        let strong = rows(fixtureSegments(), isEstimated: true, tier: .strongRR)
        XCTAssertEqual(strong.first { $0.stage == .deep }?.hedgeCaption,
                       AtriaSleepStageRowStripPresentation.deepEstimateHedgeCaption)
        XCTAssertNil(AtriaSleepStageRowStripPresentation.hedgeCaption(for: .deep,
                                                                      isEstimated: false,
                                                                      tier: .strongRR),
                     "no estimate, no hedge — regardless of tier")
    }

    // MARK: - The night feed (consumes only display segments + stageDuration)

    private func hrOnlyEstimateNight() -> SleepHistorySnapshot.Night {
        SleepHistorySnapshot.Night(
            id: "p5-strip-estimate",
            day: calendar.startOfDay(for: windowEnd),
            start: windowStart,
            end: windowEnd,
            duration: windowEnd.timeIntervalSince(windowStart),
            restingHR: 54,
            hrv: 48,
            respiratoryRate: 13.2,
            sleepEfficiency: 0.9,
            confidence: "user_confirmed_hr_only",
            source: "aggregate_sleep",
            confirmed: true,
            stageSegments: [
                segment("light-1", .light, from: date(18, 22), to: date(19, 0)),
                segment("deep", .deep, from: date(19, 0), to: date(19, 2)),
                segment("awake", .awake, from: date(19, 2), to: date(19, 3)),
                segment("rem", .rem, from: date(19, 3), to: date(19, 4, 30)),
                segment("light-2", .light, from: date(19, 4, 30), to: date(19, 6))
            ],
            motionValidated: false
        )
    }

    func testEstimateNightRowsMatchTheNightStageDurations() {
        let night = hrOnlyEstimateNight()
        XCTAssertTrue(night.isEstimatedStageDisplay,
                      "fixture must exercise the labeled-estimate lane")

        let rows = AtriaSleepStageRowStripPresentation.rows(
            for: night.displayStageSegments,
            windowStart: windowStart,
            windowEnd: windowEnd,
            isEstimated: night.isEstimatedStageDisplay
        )
        for row in rows {
            XCTAssertEqual(row.minutes,
                           Int((night.stageDuration(row.stage) / 60).rounded()),
                           "\(row.stage): strip minutes == the night's stage-duration authority")
        }
        XCTAssertEqual(rows.reduce(0) { $0 + $1.percent }, 100)
        XCTAssertEqual(rows.first { $0.stage == .deep }?.hedgeCaption,
                       AtriaSleepStageRowStripPresentation.deepEstimateHedgeCaption)
    }

    // MARK: - Source pin: the review sheet mounts the strip honestly

    func testReviewSheetMountsTheStripOnDisplaySegmentsAndEstimateState() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaActivityMonitor.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "struct AtriaSleepActivityReviewSheet: View"))
        let end = try XCTUnwrap(source.range(of: "private var nightVitals: some View",
                                             range: start.lowerBound..<source.endIndex))
        let sheet = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(sheet.contains("AtriaSleepStageRowStrip(segments: night.displayStageSegments"),
                      "the strip consumes only the honesty-gated display segments")
        XCTAssertTrue(sheet.contains("isEstimated: night.isEstimatedStageDisplay"),
                      "the estimate co-render is driven by the night's own state")
        XCTAssertTrue(sheet.contains("confidenceTier: night.estimateConfidenceTier"),
                      "the strip reads P2's prefix-derived display tier, never a stored flag")
        XCTAssertTrue(sheet.contains("eventTimeZoneIdentifier: night.eventTimeZoneIdentifier"),
                      "clock-edge labels render in the night's recorded zone (GAP-07)")
        XCTAssertFalse(sheet.contains("night.stageSegments"),
                       "raw engine segments never reach the review sheet's strip")
    }

    // MARK: - Container pin: inset card + design tokens only

    func testStripKeepsTheHouseContainerAndTokens() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let stripURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaSleepStageRows.swift")
        let strip = try String(contentsOf: stripURL, encoding: .utf8)

        XCTAssertTrue(strip.contains(".atriaInsetCard(tint: Metrics.electricSleep)"))
        XCTAssertTrue(strip.contains("AtriaDesignTokens.Spacing"))
        XCTAssertTrue(strip.contains("AtriaSleepStageRowStripPresentation.headerTitle(isEstimated: isEstimated)"),
                      "the view renders the mandatory header from the tested pure authority")
    }
}
