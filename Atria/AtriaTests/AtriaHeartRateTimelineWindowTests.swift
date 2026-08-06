import XCTest
@testable import Atria

/// HR-timeline time-window zoom (2026-07-10, user request: 6h default, zoom
/// in to 1 min, out to 24h). Locks the windowing math and that the merge no
/// longer pre-downsamples away the resolution the tight zoom needs.
final class AtriaHeartRateTimelineWindowTests: XCTestCase {
    private func points(spanHours: Double, count: Int, endingAt end: Date) -> [AtriaHomeModel.HeartRateChartPoint] {
        let span = spanHours * 3600
        return (0..<count).map { index in
            let t = end.addingTimeInterval(-span + span * Double(index) / Double(max(count - 1, 1)))
            return AtriaHomeModel.HeartRateChartPoint(t: t, bpm: 70)
        }
    }

    func testDefaultWindowIsSixHours() {
        XCTAssertEqual(AtriaVitalsHeartRateTimeline.Window.defaultWindow, .hour6)
        XCTAssertEqual(AtriaVitalsHeartRateTimeline.Window.hour6.seconds, 6 * 3600, accuracy: 0.5)
        XCTAssertEqual(AtriaVitalsHeartRateTimeline.Window.hour12.seconds, 12 * 3600, accuracy: 0.5)
        XCTAssertEqual(AtriaVitalsHeartRateTimeline.Window.min1.seconds, 60, accuracy: 0.5)
        XCTAssertEqual(AtriaVitalsHeartRateTimeline.Window.hour24.seconds, 24 * 3600, accuracy: 0.5)
    }

    // 2026-08-01 axis-label fix: `.automatic(desiredCount: 4)` placed
    // sub-hour ticks on short series while the label kept hour precision, so
    // the Vitals timeline rendered duplicated "11a"-style labels. Ticks are
    // now generated + labelled + deduped in one place.
    func testHourAlignedAxisTicksNeverRepeatConsecutiveLabels() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let base = calendar.date(from: DateComponents(year: 2026, month: 7, day: 31, hour: 10, minute: 40))!

        // The defect shape: a short (~80 min) live series around one hour.
        let short = AtriaVitalsHeartRateTimeline.hourAlignedAxisTicks(
            from: base,
            to: base.addingTimeInterval(80 * 60),
            calendar: calendar
        )
        XCTAssertFalse(short.isEmpty)
        for (previous, next) in zip(short, short.dropFirst()) {
            XCTAssertNotEqual(previous.label, next.label,
                              "Adjacent ticks must never carry the same visible label")
            XCTAssertLessThan(previous.date, next.date)
        }

        // A full six-hour window keeps whole-hour ticks with distinct labels.
        let sixHours = AtriaVitalsHeartRateTimeline.hourAlignedAxisTicks(
            from: base,
            to: base.addingTimeInterval(6 * 3_600),
            calendar: calendar
        )
        XCTAssertGreaterThanOrEqual(sixHours.count, 3)
        XCTAssertEqual(Set(sixHours.map(\.label)).count, sixHours.count)
        for tick in sixHours {
            XCTAssertEqual(calendar.component(.minute, from: tick.date), 0,
                           "Hour-labelled ticks must sit on whole-hour boundaries")
        }

        // Scrollable 24h series with a 1-minute visible window: the tick
        // count stays bounded instead of emitting one mark per minute.
        let scrollable = AtriaVitalsHeartRateTimeline.hourAlignedAxisTicks(
            from: base,
            to: base.addingTimeInterval(24 * 3_600),
            visibleDomain: 60,
            calendar: calendar
        )
        XCTAssertFalse(scrollable.isEmpty)
        XCTAssertLessThanOrEqual(scrollable.count, 241)

        // Degenerate inputs stay empty rather than fabricating ticks.
        XCTAssertTrue(AtriaVitalsHeartRateTimeline.hourAlignedAxisTicks(
            from: base, to: base, calendar: calendar
        ).isEmpty)
    }

    func testExpandedChartAnchorsLatestSampleAtRightEdge() {
        let latest = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(AtriaHeartRateExplorer.leadingScrollPosition(latest: latest,
                                                                    visibleDomain: 6 * 3_600),
                       latest.addingTimeInterval(-6 * 3_600))
    }

    func testExpandedChartDoesNotForceSixHourScrollOnShortSeries() {
        let end = Date(timeIntervalSince1970: 1_800_000_000)
        let short = points(spanHours: 0.1, count: 20, endingAt: end)
        let long = points(spanHours: 12, count: 20, endingAt: end)

        XCTAssertFalse(AtriaHeartRateAxisChart.shouldEnableHorizontalScrolling(
            points: short,
            visibleDomain: 6 * 3_600
        ))
        XCTAssertTrue(AtriaHeartRateAxisChart.shouldEnableHorizontalScrolling(
            points: long,
            visibleDomain: 6 * 3_600
        ))
    }

    func testExplorerLandscapeLayoutKeepsMostWidthForChart() {
        let layout = AtriaHeartRateExplorerLayout(size: CGSize(width: 852, height: 393))

        XCTAssertTrue(layout.isLandscape)
        XCTAssertLessThanOrEqual(layout.controlRailHeight, 48)
        XCTAssertGreaterThan(layout.estimatedChartWidth, 820)
        XCTAssertGreaterThan(layout.estimatedChartWidth / 852, 0.96)
        XCTAssertGreaterThanOrEqual(layout.minimumChartHeight, 300)
    }

    func testExplorerPortraitFallbackUsesRenderedGeometry() {
        let layout = AtriaHeartRateExplorerLayout(size: CGSize(width: 393, height: 852))

        XCTAssertFalse(layout.isLandscape)
        XCTAssertEqual(layout.estimatedChartWidth, 369, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(layout.minimumChartHeight, 400)
    }

    func testExplorerPresentationHasOneLandscapeOrientationContract() {
        XCTAssertEqual(AtriaHeartRateExplorerOrientationPolicy.transitionMask, .allButUpsideDown)
        XCTAssertEqual(AtriaHeartRateExplorerOrientationPolicy.presentedMask, .landscape)
        XCTAssertEqual(AtriaHeartRateExplorerOrientationPolicy.preferredOrientation, .landscapeRight)
    }

    func testExplorerUsesSwappedLandscapeStageWhenPortraitWindowCannotRotate() {
        let stage = AtriaHeartRateExplorerStageLayout(
            containerSize: CGSize(width: 393, height: 852),
            usesRotatedPortraitFallback: true
        )

        XCTAssertEqual(stage.mode, .rotatedLandscapeFallback)
        XCTAssertEqual(stage.stageSize, CGSize(width: 852, height: 393))
        XCTAssertEqual(stage.rotationDegrees, 90)
        XCTAssertTrue(AtriaHeartRateExplorerLayout(size: stage.stageSize).isLandscape)
    }

    func testExplorerNeverDoubleRotatesAnActualLandscapeWindow() {
        let stage = AtriaHeartRateExplorerStageLayout(
            containerSize: CGSize(width: 852, height: 393),
            usesRotatedPortraitFallback: true
        )

        XCTAssertEqual(stage.mode, .landscape)
        XCTAssertEqual(stage.stageSize, CGSize(width: 852, height: 393))
        XCTAssertEqual(stage.rotationDegrees, 0)
    }

    func testExplorerRequestsLandscapeGeometryAndUsesOneGlassCloseCircle() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let source = try String(
            contentsOf: testsDirectory
                .deletingLastPathComponent()
                .appendingPathComponent("Atria/AtriaVitalsCollectionSections.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("AtriaHeartRateOrientation.ensureLandscapeAfterPresentation()"))
        XCTAssertTrue(source.contains("requestSceneOrientation(AtriaHeartRateExplorerOrientationPolicy.presentedMask"))
        XCTAssertTrue(source.contains("AtriaHeartRateOrientation.landscapeFallbackNotification"))
        XCTAssertTrue(source.contains("case .rotatedLandscapeFallback:"))
        XCTAssertTrue(source.contains(".rotationEffect(.degrees(stage.rotationDegrees))"))
        XCTAssertTrue(source.contains("nsError.code == 101"))

        let closeStart = try XCTUnwrap(source.range(of: "private var closeButton: some View"))
        let closeEnd = try XCTUnwrap(source.range(of: "private var selectionSummary: some View",
                                                  range: closeStart.upperBound..<source.endIndex))
        let close = String(source[closeStart.lowerBound..<closeEnd.lowerBound])
        XCTAssertEqual(close.components(separatedBy: ".glassEffect(").count - 1, 1)
        XCTAssertTrue(close.contains(".buttonStyle(.plain)"))
        XCTAssertFalse(close.contains(".atriaGlassIconAction"))
        XCTAssertFalse(close.contains(".buttonStyle(.glass)"))
    }

    func testExplorerLandscapeUsesFullWidthPlotBelowCompactControls() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let source = try String(
            contentsOf: testsDirectory
                .deletingLastPathComponent()
                .appendingPathComponent("Atria/AtriaVitalsCollectionSections.swift"),
            encoding: .utf8
        )

        let contentStart = try XCTUnwrap(source.range(of: "private func landscapeContent"))
        let contentEnd = try XCTUnwrap(source.range(of: "private func portraitContent",
                                                    range: contentStart.upperBound..<source.endIndex))
        let content = String(source[contentStart.lowerBound..<contentEnd.lowerBound])
        XCTAssertTrue(content.contains("VStack"))
        XCTAssertTrue(content.contains("landscapeControlRail"))
        XCTAssertTrue(content.contains("heartRateChart"))
        XCTAssertFalse(content.contains("inspector("))
    }

    func testWindowedKeepsOnlyLastTwelveHoursOfDay() {
        let end = Date(timeIntervalSince1970: 1_800_000_000)
        let pts = points(spanHours: 24, count: 1440, endingAt: end)
        let windowed = AtriaVitalsHeartRateTimeline.windowed(pts, window: .hour12, displayBudget: 10_000)
        XCTAssertTrue(windowed.allSatisfy { $0.t >= end.addingTimeInterval(-12 * 3600) })
        XCTAssertLessThan(windowed.count, pts.count)
        XCTAssertGreaterThan(windowed.count, 600)
    }

    func testWindowedOneMinuteKeepsOnlyLastMinute() {
        let end = Date(timeIntervalSince1970: 1_800_000_000)
        let pts = points(spanHours: 2, count: 7200, endingAt: end)
        let windowed = AtriaVitalsHeartRateTimeline.windowed(pts, window: .min1, displayBudget: 10_000)
        XCTAssertTrue(windowed.allSatisfy { $0.t >= end.addingTimeInterval(-60) })
        XCTAssertLessThanOrEqual(windowed.count, 62)
        XCTAssertGreaterThan(windowed.count, 0)
    }

    func testWindowedDownsamplesToBudget() {
        let end = Date(timeIntervalSince1970: 1_800_000_000)
        let pts = points(spanHours: 12, count: 5000, endingAt: end)
        XCTAssertEqual(AtriaVitalsHeartRateTimeline.windowed(pts, window: .hour12, displayBudget: 200).count, 200)
    }

    func testWindowedLargeSortedInputMatchesFilterSemantics() {
        let end = Date(timeIntervalSince1970: 1_800_000_000)
        let pts = points(spanHours: 24, count: 6000, endingAt: end)
        let cutoff = end.addingTimeInterval(-12 * 3600)
        let visible = pts.filter { $0.t >= cutoff }

        let exact = AtriaVitalsHeartRateTimeline.windowed(pts, window: .hour12, displayBudget: 10_000)
        XCTAssertEqual(exact, visible)

        let downsampled = AtriaVitalsHeartRateTimeline.windowed(pts, window: .hour12, displayBudget: 200)
        XCTAssertEqual(downsampled.count, 200)
        XCTAssertEqual(downsampled.first, visible.first)
        XCTAssertEqual(downsampled.last, visible.last)
    }

    func testMergedKeepsFullResolution() {
        let end = Date(timeIntervalSince1970: 1_800_000_000)
        let historical = points(spanHours: 12, count: 720, endingAt: end.addingTimeInterval(-3600))
        let live = points(spanHours: 1, count: 300, endingAt: end)
        let merged = AtriaVitalsHeartRateTimeline.mergedHeartRatePoints(live: live, historical: historical)
        XCTAssertGreaterThan(merged.count, 180, "must not pre-downsample to 180 or the 1-min zoom loses detail")
        XCTAssertEqual(merged, merged.sorted { $0.t < $1.t })
    }

    func testSortedMergePreservesRoundedSecondDeduplicationAndLivePrecedence() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let historical = [
            AtriaHomeModel.HeartRateChartPoint(t: start.addingTimeInterval(0.1), bpm: 60),
            AtriaHomeModel.HeartRateChartPoint(t: start.addingTimeInterval(0.4), bpm: 61),
            AtriaHomeModel.HeartRateChartPoint(t: start.addingTimeInterval(1.1), bpm: 62),
            AtriaHomeModel.HeartRateChartPoint(t: start.addingTimeInterval(2.1), bpm: 0),
        ]
        let live = [
            AtriaHomeModel.HeartRateChartPoint(t: start.addingTimeInterval(0.2), bpm: 90),
            AtriaHomeModel.HeartRateChartPoint(t: start.addingTimeInterval(1.4), bpm: 91),
            AtriaHomeModel.HeartRateChartPoint(t: start.addingTimeInterval(3), bpm: 92),
        ]

        let merged = AtriaVitalsHeartRateTimeline.mergedHeartRatePoints(live: live,
                                                                        historical: historical)

        XCTAssertEqual(merged.map(\.bpm), [90, 91, 92])
        XCTAssertEqual(merged.map(\.t), [live[0].t, live[1].t, live[2].t])
    }

    func testUnsortedMergeRetainsDictionaryFallbackSemantics() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let historical = [
            AtriaHomeModel.HeartRateChartPoint(t: start.addingTimeInterval(2), bpm: 62),
            AtriaHomeModel.HeartRateChartPoint(t: start, bpm: 60),
        ]
        let live = [
            AtriaHomeModel.HeartRateChartPoint(t: start.addingTimeInterval(1), bpm: 91),
            AtriaHomeModel.HeartRateChartPoint(t: start.addingTimeInterval(2.1), bpm: 92),
        ]

        let merged = AtriaVitalsHeartRateTimeline.mergedHeartRatePoints(live: live,
                                                                        historical: historical)

        XCTAssertEqual(merged.map(\.bpm), [60, 91, 92])
        XCTAssertEqual(merged, merged.sorted { $0.t < $1.t })
    }

    func testPulsePresentationIgnoresUnusedRRSamples() {
        let state = AtriaHomeModel.PulseLiveState(heartRate: 72,
                                                  hasContact: true,
                                                  sensorHasContact: true,
                                                  averageHeartRate: 68,
                                                  peakHeartRate: 104,
                                                  heartRateZone: nil)
        var rrOnlyChange = state
        rrOnlyChange.recentRRSamples = [
            AtriaBreathworkSession.RRSample(date: Date(timeIntervalSince1970: 1_800_000_000),
                                            ms: 833),
        ]

        XCTAssertNotEqual(state, rrOnlyChange, "the source state still carries RR data for breathwork")
        XCTAssertEqual(AtriaVitalsPulsePresentationState(state),
                       AtriaVitalsPulsePresentationState(rrOnlyChange))
    }

    func testPulsePresentationTracksRenderedValueChanges() {
        let state = AtriaHomeModel.PulseLiveState(heartRate: 72,
                                                  hasContact: true,
                                                  sensorHasContact: true,
                                                  averageHeartRate: 68,
                                                  peakHeartRate: 104,
                                                  heartRateZone: nil)
        var changed = state
        changed.averageHeartRate = 69

        XCTAssertNotEqual(AtriaVitalsPulsePresentationState(state),
                          AtriaVitalsPulsePresentationState(changed))
    }

    func testChartSeriesPrecomputesDenseSmoothingBuckets() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let dense = (0..<180).map { index in
            AtriaHomeModel.HeartRateChartPoint(t: start.addingTimeInterval(TimeInterval(index)),
                                               bpm: 60 + index)
        }

        let buckets = try XCTUnwrap(AtriaHeartRateChartSeries.smoothedBuckets(points: dense, targetBuckets: 3))

        XCTAssertEqual(buckets.count, 3)
        XCTAssertEqual(buckets[0].minBPM, 60)
        XCTAssertEqual(buckets[0].maxBPM, 119)
        XCTAssertEqual(buckets[0].average, 89.5, accuracy: 1e-9)
        XCTAssertEqual(buckets[1].minBPM, 120)
        XCTAssertEqual(buckets[1].maxBPM, 179)
        XCTAssertEqual(buckets[1].average, 149.5, accuracy: 1e-9)
        XCTAssertEqual(buckets[2].minBPM, 180)
        XCTAssertEqual(buckets[2].maxBPM, 239)
        XCTAssertEqual(buckets[2].average, 209.5, accuracy: 1e-9)
        XCTAssertNil(AtriaHeartRateChartSeries.smoothedBuckets(points: Array(dense.prefix(150)), targetBuckets: 3))
    }

    func testRangeSummaryUsesOnlySamplesInsideSelection() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let points = [60, 70, 90, 80].enumerated().map { index, bpm in
            AtriaHomeModel.HeartRateChartPoint(t: start.addingTimeInterval(Double(index * 60)), bpm: bpm)
        }

        let summary = try XCTUnwrap(AtriaHeartRateRangeSummary.make(
            points: points,
            range: start.addingTimeInterval(60)...start.addingTimeInterval(180)
        ))

        XCTAssertEqual(summary.average, 80)
        XCTAssertEqual(summary.minimum, 70)
        XCTAssertEqual(summary.maximum, 90)
        XCTAssertEqual(summary.change, 10)
        XCTAssertEqual(summary.durationText, "2 min")
    }

    func testPinchOutZoomsIn() {
        // anchor 12h (index 7), pinch out 2x -> ~2 steps shorter window (6h, index 5).
        let idx = AtriaVitalsHeartRateTimeline.windowIndex(fromPinchAnchor: 7, magnification: 2, maxIndex: 8)
        XCTAssertEqual(idx, 5, accuracy: 0.5)
    }

    func testPinchInZoomsOutAndClamps() {
        // anchor 12h, pinch in to 0.5 -> ~2 steps wider (24h, clamped to 8).
        let idx = AtriaVitalsHeartRateTimeline.windowIndex(fromPinchAnchor: 7, magnification: 0.5, maxIndex: 8)
        XCTAssertEqual(idx, 8, accuracy: 0.01)
    }

    func testPinchClampsAtFloor() {
        let idx = AtriaVitalsHeartRateTimeline.windowIndex(fromPinchAnchor: 0, magnification: 8, maxIndex: 8)
        XCTAssertEqual(idx, 0, accuracy: 0.01)
    }

    func testNoPinchKeepsAnchor() {
        let idx = AtriaVitalsHeartRateTimeline.windowIndex(fromPinchAnchor: 4, magnification: 1, maxIndex: 8)
        XCTAssertEqual(idx, 4, accuracy: 0.01)
    }

    // downsampledSpan bounds the point count while PRESERVING the time span, so
    // the "last 12h/24h" windows can actually fill (2026-07-08 fix: historical
    // was capped to ~6000 raw ~1 Hz samples ≈ 100 min, so 12h showed ~1.7h).
    func testDownsampledSpanPreservesEndpointsAndBounds() {
        let end = Date(timeIntervalSince1970: 1_800_000_000)
        let dense = points(spanHours: 24, count: 50_000, endingAt: end)
        let thinned = AtriaVitalsHeartRateTimeline.downsampledSpan(dense, maxPoints: 2_500)
        XCTAssertEqual(thinned.count, 2_500)
        XCTAssertEqual(thinned.first?.t, dense.first?.t, "first sample (span start) must be preserved")
        XCTAssertEqual(thinned.last?.t, dense.last?.t, "last sample (span end) must be preserved")
        XCTAssertEqual(thinned, thinned.sorted { $0.t < $1.t }, "must stay time-ordered")
    }

    func testDownsampledSpanIsNoOpWhenAlreadyUnderBudget() {
        let end = Date(timeIntervalSince1970: 1_800_000_000)
        let sparse = points(spanHours: 3, count: 200, endingAt: end)
        XCTAssertEqual(AtriaVitalsHeartRateTimeline.downsampledSpan(sparse, maxPoints: 2_500), sparse)
    }

    // Regression for the actual complaint: 24h of history thinned to 2500 must
    // still let the 12h window reach ~12h back (not the old ~1.7h).
    func testDownsampledSpanStillFillsTwelveHourWindow() {
        let end = Date(timeIntervalSince1970: 1_800_000_000)
        let dense = points(spanHours: 24, count: 50_000, endingAt: end)
        let thinned = AtriaVitalsHeartRateTimeline.downsampledSpan(dense, maxPoints: 2_500)
        let windowed = AtriaVitalsHeartRateTimeline.windowed(thinned, window: .hour12, displayBudget: 400)
        let earliest = windowed.first?.t ?? end
        XCTAssertLessThanOrEqual(earliest.timeIntervalSince(end.addingTimeInterval(-12 * 3600)), 40,
                                 "12h window must reach ~12h back, within one downsample step")
        XCTAssertGreaterThan(windowed.count, 200)
    }
}
