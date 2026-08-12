import XCTest
@testable import Atria

/// Segment→lane mapping, duration-legend math, and axis-tick derivation for
/// the shared sleep-stages hypnogram — plus the honesty gate (2026-08-12):
/// confirmed HR-only nights render a reconciled timeline only under the
/// mandatory `AtriaSleepStageEstimateLabel`; everything else falls closed to
/// the generic estimated-asleep window with no stage precision.
final class AtriaSleepHypnogramPresentationTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "GMT")!
        return calendar
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 7, day: day,
                                           hour: hour, minute: minute))!
    }

    private func segment(_ id: String,
                         _ stage: SleepStageKind,
                         from start: Date,
                         to end: Date) -> SleepStageSegment {
        SleepStageSegment(id: id, start: start, end: end, stage: stage)
    }

    // MARK: - Lane mapping

    func testLaneOrderMatchesDesignTopToBottom() {
        XCTAssertEqual(AtriaSleepHypnogramPresentation.lanes, [.awake, .rem, .light, .deep])
        XCTAssertEqual(AtriaSleepHypnogramPresentation.laneIndex(for: .awake), 0)
        XCTAssertEqual(AtriaSleepHypnogramPresentation.laneIndex(for: .rem), 1)
        XCTAssertEqual(AtriaSleepHypnogramPresentation.laneIndex(for: .light), 2)
        XCTAssertEqual(AtriaSleepHypnogramPresentation.laneIndex(for: .deep), 3)
        // SWS is N3/deep sleep — it must land on the Deep lane, never a fifth lane.
        XCTAssertEqual(AtriaSleepHypnogramPresentation.laneIndex(for: .sws), 3)
    }

    // MARK: - Spans

    func testSpansUseRealWallClockFractionsOfTheWindow() {
        let windowStart = date(24, 22)          // 10p
        let windowEnd = date(25, 6)             // 6a — 8h window
        let spans = AtriaSleepHypnogramPresentation.spans(
            for: [
                segment("a", .light, from: date(24, 22), to: date(24, 23)),
                segment("b", .sws, from: date(24, 23), to: date(25, 1)),
                segment("c", .rem, from: date(25, 4), to: date(25, 5))
            ],
            windowStart: windowStart,
            windowEnd: windowEnd
        )

        XCTAssertEqual(spans.count, 3)
        XCTAssertEqual(spans[0].laneIndex, 2)
        XCTAssertEqual(spans[0].startFraction, 0, accuracy: 1e-9)
        XCTAssertEqual(spans[0].endFraction, 0.125, accuracy: 1e-9)
        // SWS renders on the Deep lane with deep identity.
        XCTAssertEqual(spans[1].laneIndex, 3)
        XCTAssertEqual(spans[1].stage, .deep)
        XCTAssertEqual(spans[1].startFraction, 0.125, accuracy: 1e-9)
        XCTAssertEqual(spans[1].endFraction, 0.375, accuracy: 1e-9)
        // A late REM segment stays late — position comes from the wall clock,
        // not from cumulative elapsed coverage.
        XCTAssertEqual(spans[2].startFraction, 0.75, accuracy: 1e-9)
        XCTAssertEqual(spans[2].endFraction, 0.875, accuracy: 1e-9)
    }

    func testSpansClipToWindowAndDropOutOfWindowSegments() {
        let windowStart = date(24, 23)
        let windowEnd = date(25, 6)
        let spans = AtriaSleepHypnogramPresentation.spans(
            for: [
                segment("pre", .light, from: date(24, 22), to: date(24, 23, 30)),
                segment("out", .deep, from: date(25, 7), to: date(25, 8)),
                segment("zero", .rem, from: date(25, 2), to: date(25, 2))
            ],
            windowStart: windowStart,
            windowEnd: windowEnd
        )

        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].startFraction, 0, accuracy: 1e-9)
        XCTAssertEqual(spans[0].endFraction, 0.5 / 7.0, accuracy: 1e-9)
    }

    func testSpansEmptyForInvalidWindow() {
        let segments = [segment("a", .light, from: date(24, 22), to: date(24, 23))]
        XCTAssertTrue(AtriaSleepHypnogramPresentation.spans(for: segments,
                                                            windowStart: date(24, 23),
                                                            windowEnd: date(24, 23)).isEmpty)
        XCTAssertTrue(AtriaSleepHypnogramPresentation.spans(for: segments,
                                                            windowStart: date(25, 1),
                                                            windowEnd: date(24, 23)).isEmpty)
    }

    // MARK: - Legend math

    func testLegendReportsRealMinutesInLaneOrder() {
        // The design fixture night: light 4h05m, rem 1h51m, deep 1h34m, awake 12m.
        let onset = date(24, 23, 18)
        var cursor = onset
        func advance(_ minutes: Int) -> (Date, Date) {
            let start = cursor
            cursor = calendar.date(byAdding: .minute, value: minutes, to: cursor)!
            return (start, cursor)
        }
        var segments: [SleepStageSegment] = []
        var index = 0
        func append(_ stage: SleepStageKind, _ minutes: Int) {
            let (start, end) = advance(minutes)
            segments.append(segment("s\(index)", stage, from: start, to: end))
            index += 1
        }
        append(.light, 125)
        append(.deep, 60)      // deep splits across .deep and .sws bands
        append(.sws, 34)
        append(.awake, 12)
        append(.light, 120)
        append(.rem, 111)

        let legend = AtriaSleepHypnogramPresentation.legend(for: segments)

        XCTAssertEqual(legend.map(\.stage), [.awake, .rem, .light, .deep])
        XCTAssertEqual(legend.first { $0.stage == .awake }?.minutes, 12)
        XCTAssertEqual(legend.first { $0.stage == .rem }?.minutes, 111)
        XCTAssertEqual(legend.first { $0.stage == .light }?.minutes, 245)
        // SWS minutes fold into Deep — 60 + 34.
        XCTAssertEqual(legend.first { $0.stage == .deep }?.minutes, 94)
        XCTAssertEqual(legend.reduce(0) { $0 + $1.percent }, 100)
    }

    func testLegendOmitsAbsentStagesAndEmptyInput() {
        let legend = AtriaSleepHypnogramPresentation.legend(for: [
            segment("a", .light, from: date(24, 23), to: date(25, 1))
        ])
        XCTAssertEqual(legend.map(\.stage), [.light])
        XCTAssertEqual(legend[0].minutes, 120)
        XCTAssertEqual(legend[0].percent, 100)
        XCTAssertTrue(AtriaSleepHypnogramPresentation.legend(for: []).isEmpty)
    }

    func testDurationTextMatchesDesignFormat() {
        XCTAssertEqual(AtriaSleepHypnogramPresentation.durationText(minutes: 94), "1h 34m")
        XCTAssertEqual(AtriaSleepHypnogramPresentation.durationText(minutes: 12), "12m")
        XCTAssertEqual(AtriaSleepHypnogramPresentation.durationText(minutes: 245), "4h 5m")
    }

    // MARK: - Axis ticks

    func testAxisTicksExactEndpointsWithWholeHoursBetween() {
        let start = date(24, 23, 42)
        let end = date(25, 7, 24)
        let ticks = AtriaSleepHypnogramPresentation.axisTicks(windowStart: start,
                                                              windowEnd: end,
                                                              calendar: calendar)

        XCTAssertGreaterThanOrEqual(ticks.count, 3)
        XCTAssertEqual(ticks.first?.fraction, 0)
        XCTAssertEqual(ticks.first?.label, "11:42p")
        XCTAssertEqual(ticks.last?.fraction, 1)
        XCTAssertEqual(ticks.last?.label, "7:24a")

        let interior = ticks.dropFirst().dropLast()
        XCTAssertFalse(interior.isEmpty)
        XCTAssertLessThanOrEqual(interior.count, 3)
        for tick in interior {
            // Whole hours only — no minutes component in interior labels.
            XCTAssertFalse(tick.label.contains(":"), "interior tick \(tick.label)")
            XCTAssertTrue(tick.label.hasSuffix("a"))
            XCTAssertGreaterThan(tick.fraction, 0.12)
            XCTAssertLessThan(tick.fraction, 0.88)
        }
        // Ascending along the axis.
        XCTAssertEqual(ticks.map(\.fraction), ticks.map(\.fraction).sorted())
    }

    func testAxisTickClockLabelFormat() {
        XCTAssertEqual(AtriaSleepHypnogramPresentation.clockLabel(date(25, 2), calendar: calendar), "2a")
        XCTAssertEqual(AtriaSleepHypnogramPresentation.clockLabel(date(25, 0), calendar: calendar), "12a")
        XCTAssertEqual(AtriaSleepHypnogramPresentation.clockLabel(date(25, 12), calendar: calendar), "12p")
        XCTAssertEqual(AtriaSleepHypnogramPresentation.clockLabel(date(25, 14, 5), calendar: calendar), "2:05p")
    }

    func testAxisTicksEmptyForInvalidWindow() {
        XCTAssertTrue(AtriaSleepHypnogramPresentation.axisTicks(windowStart: date(25, 7),
                                                                windowEnd: date(25, 7),
                                                                calendar: calendar).isEmpty)
    }

    func testShortNapWindowTicks() {
        // A whole hour well inside the nap window earns an interior tick...
        let withInterior = AtriaSleepHypnogramPresentation.axisTicks(windowStart: date(25, 13, 50),
                                                                     windowEnd: date(25, 14, 30),
                                                                     calendar: calendar)
        XCTAssertEqual(withInterior.map(\.label), ["1:50p", "2p", "2:30p"])
        // ...but one crowding an endpoint (fraction ≈ 0.11) is dropped, so
        // only the exact endpoint clocks remain.
        let endpointOnly = AtriaSleepHypnogramPresentation.axisTicks(windowStart: date(25, 13, 55),
                                                                     windowEnd: date(25, 14, 40),
                                                                     calendar: calendar)
        XCTAssertEqual(endpointOnly.map(\.label), ["1:55p", "2:40p"])
    }

    // MARK: - Honesty gate

    private func night(motionValidated: Bool?,
                       confidence: String,
                       segments: [SleepStageSegment],
                       start: Date,
                       end: Date) -> SleepHistorySnapshot.Night {
        SleepHistorySnapshot.Night(id: "n1",
                                   day: calendar.startOfDay(for: end),
                                   start: start,
                                   end: end,
                                   duration: end.timeIntervalSince(start),
                                   restingHR: 52,
                                   hrv: 60,
                                   respiratoryRate: 14.2,
                                   sleepEfficiency: 0.94,
                                   confidence: confidence,
                                   source: "sleep",
                                   confirmed: true,
                                   stageSegments: segments,
                                   motionValidated: motionValidated)
    }

    private func fullNightSegments(start: Date, end: Date) -> [SleepStageSegment] {
        // Continuous coverage so stage integrity passes and only the motion
        // gate decides whether the hypnogram may render.
        let third = end.timeIntervalSince(start) / 3
        return [
            segment("a", .light, from: start, to: start.addingTimeInterval(third)),
            segment("b", .deep, from: start.addingTimeInterval(third), to: start.addingTimeInterval(2 * third)),
            segment("c", .rem, from: start.addingTimeInterval(2 * third), to: end)
        ]
    }

    func testHrOnlyNightRendersLabeledEstimateTimeline() {
        let start = date(24, 23)
        let end = date(25, 6)
        let hrOnly = night(motionValidated: false,
                           confidence: "settled",
                           segments: fullNightSegments(start: start, end: end),
                           start: start,
                           end: end)

        XCTAssertEqual(hrOnly.stageEvidence, .hrOnlyEstimate)
        // 2026-08-12 labeled-estimate product: an integrity-valid confirmed
        // HR-only night renders reconciled bars — under the mandatory label.
        XCTAssertFalse(hrOnly.displayStageSegments.isEmpty)
        XCTAssertTrue(hrOnly.isEstimatedStageDisplay)
        XCTAssertEqual(hrOnly.stageDisplayLabel, AtriaSleepStageEstimateLabel.title)
        XCTAssertEqual(AtriaSleepHypnogramCard.displayState(segments: hrOnly.displayStageSegments,
                                                            stageEvidence: hrOnly.stageEvidence,
                                                            start: hrOnly.start,
                                                            end: hrOnly.end),
                       .estimatedTimeline)
        // Without reconciled display segments the same evidence still falls
        // closed to the generic estimated-asleep window.
        XCTAssertEqual(AtriaSleepHypnogramCard.displayState(segments: [],
                                                            stageEvidence: hrOnly.stageEvidence,
                                                            start: hrOnly.start,
                                                            end: hrOnly.end),
                       .estimate)
    }

    func testHrOnlyCardFeedsReconciledSegmentsAndKeepsMeasuredHRContext() {
        let start = date(24, 23)
        let end = date(25, 6)
        let hrOnly = night(motionValidated: false,
                           confidence: "settled",
                           segments: fullNightSegments(start: start, end: end),
                           start: start,
                           end: end)
        let card = AtriaSleepHypnogramCard(night: hrOnly)

        XCTAssertFalse(hrOnly.stageSegments.isEmpty,
                       "the regression fixture must contain raw HR-derived stages")
        XCTAssertEqual(card.segments, hrOnly.displayStageSegments,
                       "the HR-only card feeds only the reconciled display segments")
        XCTAssertFalse(AtriaSleepHypnogramPresentation.legend(for: card.segments).isEmpty,
                       "the labeled estimate publishes its legend under the estimate title")
        XCTAssertEqual(card.measuredHeartRate, 52)
        XCTAssertEqual(AtriaSleepHypnogramCard.measuredHeartRateText(card.measuredHeartRate),
                       "Measured resting HR · 52 bpm")
        XCTAssertEqual(AtriaSleepHypnogramCard.displayState(segments: card.segments,
                                                            stageEvidence: hrOnly.stageEvidence,
                                                            start: hrOnly.start,
                                                            end: hrOnly.end),
                       .estimatedTimeline)
    }

    func testHrOnlyEstimateWithoutAUsableWindowFallsBackToNeedsMotion() {
        XCTAssertEqual(AtriaSleepHypnogramCard.displayState(segments: [],
                                                            stageEvidence: .hrOnlyEstimate,
                                                            start: nil,
                                                            end: nil),
                       .needsMotion)
        XCTAssertNil(AtriaSleepHypnogramCard.measuredHeartRateText(nil))
        XCTAssertNil(AtriaSleepHypnogramCard.measuredHeartRateText(0))
    }

    func testMotionValidatedNightRendersTimeline() {
        let start = date(24, 23)
        let end = date(25, 6)
        let validated = night(motionValidated: true,
                              confidence: "ready",
                              segments: fullNightSegments(start: start, end: end),
                              start: start,
                              end: end)

        XCTAssertEqual(validated.stageEvidence, .sensorResearch)
        XCTAssertFalse(validated.displayStageSegments.isEmpty)
        XCTAssertEqual(AtriaSleepHypnogramCard(night: validated).segments,
                       validated.displayStageSegments,
                       "motion-backed stage rendering must remain unchanged")
        XCTAssertEqual(AtriaSleepHypnogramCard.displayState(segments: validated.displayStageSegments,
                                                            stageEvidence: validated.stageEvidence,
                                                            start: validated.start,
                                                            end: validated.end),
                       .timeline)
    }

    func testHrOnlyNightPublishesDistributionOnlyUnderEstimateLabel() {
        let start = date(24, 23)
        let end = date(25, 6)
        // Real, integrity-valid stage segments exist without motion: the
        // distribution now publishes, but strictly as the labeled estimate
        // and never exceeding the credited effective sleep.
        let hrOnly = night(motionValidated: false,
                           confidence: "learning",
                           segments: fullNightSegments(start: start, end: end),
                           start: start,
                           end: end)
        XCTAssertEqual(hrOnly.stageEvidence, .hrOnlyEstimate)
        XCTAssertTrue(hrOnly.isEstimatedStageDisplay,
                      "durations may only publish when the estimate label is mandatory")
        XCTAssertEqual(hrOnly.stageDisplayLabel, AtriaSleepStageEstimateLabel.title)
        let nonAwake = SleepStageKind.allCases
            .filter { $0 != .awake }
            .reduce(0.0) { $0 + hrOnly.stageDuration($1) }
        XCTAssertEqual(nonAwake, hrOnly.duration, accuracy: 1,
                       "the reconciled estimate matches the credited effective sleep")
        XCTAssertLessThanOrEqual(nonAwake, hrOnly.duration + 1,
                                 "the reconciled estimate never exceeds effective sleep")
    }

    func testMotionValidatedNightStageDurationsNeverExceedObservedSleep() {
        let start = date(24, 23)
        let end = date(25, 6)
        let validated = night(motionValidated: true,
                              confidence: "ready",
                              segments: fullNightSegments(start: start, end: end),
                              start: start,
                              end: end)
        XCTAssertFalse(validated.displayStageSegments.isEmpty)
        let observed = end.timeIntervalSince(start)
        let nonAwake = SleepStageKind.allCases
            .filter { $0 != .awake }
            .reduce(0.0) { $0 + validated.stageDuration($1) }
        XCTAssertLessThanOrEqual(nonAwake, observed + 1,
                                 "credited sleep stages must never exceed the observed sleep window")
    }

    func testSegmentlessOrWindowlessNightRendersBuildingState() {
        XCTAssertEqual(AtriaSleepHypnogramCard.displayState(segments: [],
                                                            stageEvidence: .none,
                                                            start: date(24, 23),
                                                            end: date(25, 6)),
                       .building)
        let start = date(24, 23)
        let end = date(25, 6)
        XCTAssertEqual(AtriaSleepHypnogramCard.displayState(segments: fullNightSegments(start: start, end: end),
                                                            stageEvidence: .sensorResearch,
                                                            start: nil,
                                                            end: nil),
                       .building)
    }

    // MARK: - History day-sheet feed

    func testConfirmedNightsFilterConfirmsAndDay() {
        let start = date(24, 23)
        let end = date(25, 6, 30)
        let confirmed = night(motionValidated: true,
                              confidence: "ready",
                              segments: fullNightSegments(start: start, end: end),
                              start: start,
                              end: end)
        let candidate = SleepHistorySnapshot.Night(id: "cand",
                                                   day: calendar.startOfDay(for: end),
                                                   start: start,
                                                   end: end,
                                                   duration: end.timeIntervalSince(start),
                                                   restingHR: nil,
                                                   hrv: nil,
                                                   respiratoryRate: nil,
                                                   sleepEfficiency: nil,
                                                   confidence: "settled",
                                                   source: "sleep_candidate",
                                                   confirmed: false,
                                                   stageSegments: [])
        let snapshot = SleepHistorySnapshot(nights: [confirmed, candidate],
                                            confirmedCount: 1,
                                            candidateCount: 1)

        let sameDay = snapshot.confirmedNights(on: date(25, 12), calendar: calendar)
        XCTAssertEqual(sameDay.map(\.id), ["n1"],
                       "candidates must not surface a hypnogram from History")
        XCTAssertTrue(snapshot.confirmedNights(on: date(24, 12), calendar: calendar).isEmpty)
    }
    // MARK: - Stepped timeline runs + display compositor (handoff-7 CP2A)

    private func seg(_ stage: SleepStageKind,
                     _ startMinute: Double,
                     _ endMinute: Double,
                     id: String = UUID().uuidString) -> SleepStageSegment {
        SleepStageSegment(id: id,
                          start: base.addingTimeInterval(startMinute * 60),
                          end: base.addingTimeInterval(endMinute * 60),
                          stage: stage)
    }

    private var base: Date { Date(timeIntervalSinceReferenceDate: 800_000_000) }

    func testAdjacentSameStageRunsMergeLosslessly() {
        let window = (base, base.addingTimeInterval(4 * 3_600))
        let timeline = AtriaSleepHypnogramPresentation.timelineRuns(
            for: [seg(.light, 0, 30), seg(.light, 30, 60), seg(.deep, 60, 90),
                  seg(.light, 100, 120)],
            windowStart: window.0,
            windowEnd: window.1
        )
        XCTAssertFalse(timeline.composited)
        XCTAssertEqual(timeline.runs.map(\.stage), [.light, .deep, .light])
        XCTAssertEqual(timeline.runs[0].start, base)
        XCTAssertEqual(timeline.runs[0].end, base.addingTimeInterval(3_600),
                       "abutting same-stage spans merge without losing a second")
        XCTAssertEqual(timeline.runs[2].start,
                       base.addingTimeInterval(100 * 60),
                       "a real gap always starts a new run — never bridged")
    }

    func testRunsClipToTheExactSleepWindow() {
        let windowStart = base.addingTimeInterval(600)
        let windowEnd = base.addingTimeInterval(3_000)
        let timeline = AtriaSleepHypnogramPresentation.timelineRuns(
            for: [seg(.rem, -10, 20), seg(.deep, 20, 70)],
            windowStart: windowStart,
            windowEnd: windowEnd
        )
        XCTAssertEqual(timeline.runs.first?.start, windowStart)
        XCTAssertEqual(timeline.runs.last?.end, windowEnd)
    }

    func testRunIdentityDerivesFromStageAndBoundsNotArrayOffsets() {
        let timeline = AtriaSleepHypnogramPresentation.timelineRuns(
            for: [seg(.rem, 0, 30), seg(.deep, 30, 60)],
            windowStart: base,
            windowEnd: base.addingTimeInterval(3_600)
        )
        let expected = "rem-\(Int(base.timeIntervalSince1970))-\(Int(base.addingTimeInterval(1_800).timeIntervalSince1970))"
        XCTAssertEqual(timeline.runs.first?.id, expected)
    }

    func testSWSFoldsIntoDeepAtTheRunLevel() {
        let timeline = AtriaSleepHypnogramPresentation.timelineRuns(
            for: [seg(.sws, 0, 30), seg(.deep, 30, 60)],
            windowStart: base,
            windowEnd: base.addingTimeInterval(3_600)
        )
        XCTAssertEqual(timeline.runs.count, 1,
                       "SWS and Deep are one display level; abutting spans merge")
        XCTAssertEqual(timeline.runs.first?.stage, .deep)
    }

    func testCompositorBoundsMarksPreservesEndpointsAndLongRuns() {
        // 480 alternating 30s spans (4h) with one solid 1h deep block.
        var segments: [SleepStageSegment] = []
        for index in 0..<480 {
            segments.append(seg(index.isMultiple(of: 2) ? .light : .rem,
                                Double(index) * 0.5,
                                Double(index + 1) * 0.5,
                                id: "run-\(index)"))
        }
        segments.append(seg(.deep, 240, 300, id: "long-deep"))
        let windowEnd = base.addingTimeInterval(300 * 60)
        let timeline = AtriaSleepHypnogramPresentation.timelineRuns(
            for: segments,
            windowStart: base,
            windowEnd: windowEnd,
            maximumMarks: 96
        )
        XCTAssertTrue(timeline.composited,
                      "sub-pixel runs collapse into a width-aware display composite")
        XCTAssertLessThanOrEqual(timeline.runs.count, 96)
        XCTAssertEqual(timeline.runs.first?.start, base,
                       "the first boundary is preserved exactly")
        XCTAssertEqual(timeline.runs.last?.end, windowEnd,
                       "the last boundary is preserved exactly")
        let deepCenter = base.addingTimeInterval(270 * 60)
        XCTAssertEqual(
            timeline.runs.first { $0.start <= deepCenter && deepCenter < $0.end }?.stage,
            .deep,
            "a long visible run survives compositing by dominance"
        )
        // Legend totals derive from the RAW segments and are untouched by the
        // display compositor.
        let legend = AtriaSleepHypnogramPresentation.legend(for: segments)
        XCTAssertEqual(legend.first { $0.stage == .deep }?.minutes, 60)
        XCTAssertEqual(legend.first { $0.stage == .light }?.minutes, 120)
        XCTAssertEqual(legend.first { $0.stage == .rem }?.minutes, 120)
    }

    func testDegenerateWindowsProduceNoRuns() {
        XCTAssertTrue(AtriaSleepHypnogramPresentation.timelineRuns(
            for: [seg(.deep, 0, 30)],
            windowStart: base,
            windowEnd: base
        ).runs.isEmpty)
        XCTAssertTrue(AtriaSleepHypnogramPresentation.timelineRuns(
            for: [],
            windowStart: base,
            windowEnd: base.addingTimeInterval(3_600)
        ).runs.isEmpty)
    }

}
