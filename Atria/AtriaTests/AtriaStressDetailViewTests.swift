import XCTest
@testable import Atria

final class AtriaStressDetailViewTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testInputSortsMeasuredReadingsAndClampsOnlyToDisplayDomain() {
        let readings = [
            AtriaStressDetailReading(date: now.addingTimeInterval(60), score: 4.2),
            AtriaStressDetailReading(date: now, score: -0.5)
        ]

        let input = AtriaStressDetailInput(state: scoredState(activation: 0.6),
                                           readings: readings,
                                           updatedAt: now)

        XCTAssertEqual(input.readings.map(\.date), [now, now.addingTimeInterval(60)])
        XCTAssertEqual(input.readings.map(\.score), [0, 3])
        XCTAssertEqual(try XCTUnwrap(input.score), 1.8, accuracy: 0.0001)
    }

    func testInputFramesRestoredHistoryToTheSameTwentyFourHoursItAnalyzes() {
        let staleElevated = (0..<20).map { index in
            AtriaStressDetailReading(
                date: now.addingTimeInterval(-47 * 3_600 + Double(index) * 30),
                score: 2.7
            )
        }
        let recentCalm = (0..<21).map { index in
            AtriaStressDetailReading(
                date: now.addingTimeInterval(-Double(20 - index) * 30),
                score: 0.4
            )
        }

        let input = AtriaStressDetailInput(state: scoredState(activation: 0.2),
                                           readings: staleElevated + recentCalm,
                                           updatedAt: now)

        XCTAssertEqual(input.readings, recentCalm)
        XCTAssertEqual(input.elevatedEvidence.readingCount, recentCalm.count)
        XCTAssertTrue(input.elevatedEvidence.windows.isEmpty,
                      "Old restored peaks outside the visible 24h must not enter its count or overlays")
    }

    func testNonScoredStateNeverDisplaysNumericScore() {
        let state = AtriaStressState(level: nil,
                                     label: "Warming up",
                                     detail: "Building a live read",
                                     kind: .warmingUp,
                                     confidence: 0,
                                     rawActivation: 0.9,
                                     hrvAvailable: false)

        let input = AtriaStressDetailInput(state: state, readings: [], updatedAt: nil)

        XCTAssertNil(input.score)
    }

    func testHROnlyInputUsesContinuousScaleWithHonestLowerConfidenceCopy() {
        let input = AtriaStressDetailInput(
            state: scoredState(activation: AtriaStressMonitor.mediumUpperBound,
                               hrvAvailable: false),
            readings: [],
            updatedAt: now
        )

        XCTAssertEqual(try XCTUnwrap(input.score),
                       AtriaStressMonitor.mediumUpperBound * 3,
                       accuracy: 1e-12)
        XCTAssertEqual(input.presentation.evidenceMode, .physiologicalStress)
        XCTAssertEqual(input.presentation.metricTitle, "Physiological stress")
        XCTAssertTrue(input.presentation.detail.contains("HR-only estimate"))
    }

    func testHeroVoiceOverUsesMinuteFactHROnlyProvenanceNotPresentationMode() throws {
        let hrOnly = scoredState(activation: 0.6, hrvAvailable: false)
        let fullCardiac = scoredState(activation: 0.6, hrvAvailable: true)
        let hrOnlyInput = AtriaStressDetailInput(state: hrOnly,
                                                 readings: [],
                                                 updatedAt: now)

        XCTAssertEqual(hrOnlyInput.presentation.evidenceMode, .physiologicalStress,
                       "v3 presentation mode intentionally does not encode HRV provenance")
        XCTAssertTrue(try XCTUnwrap(hrOnly.minuteFact).isHROnly)
        XCTAssertTrue(AtriaStressAccessibilityCopy.heroLabel(
            state: hrOnly,
            score: hrOnlyInput.score
        ).contains("HR-only estimate, lower confidence"))
        XCTAssertFalse(AtriaStressAccessibilityCopy.heroLabel(
            state: fullCardiac,
            score: AtriaStressDetailInput(state: fullCardiac,
                                          readings: [],
                                          updatedAt: now).score
        ).contains("HR-only estimate"))
    }

    func testTimelineLeavesRealGapInsteadOfConnectingIt() {
        let readings = [
            AtriaStressDetailReading(date: now, score: 0.4),
            AtriaStressDetailReading(date: now.addingTimeInterval(60), score: 0.8),
            AtriaStressDetailReading(date: now.addingTimeInterval(6 * 60 + 1), score: 1.5)
        ]

        let points = AtriaStressTimelinePoint.segment(readings)

        XCTAssertEqual(points.map(\.segment), [0, 0, 1])
    }

    func testTimelineUsesSingleSegmentAtGapBoundary() {
        let readings = [
            AtriaStressDetailReading(date: now, score: 0.4),
            AtriaStressDetailReading(date: now.addingTimeInterval(90), score: 0.8)
        ]

        XCTAssertEqual(AtriaStressTimelinePoint.segment(readings).map(\.segment), [0, 0])
    }

    func testTimelineKeepsHROnlyEstimateOnTheContinuousScale() {
        let readings = [
            AtriaStressDetailReading(date: now, score: 0.7),
            AtriaStressDetailReading(date: now.addingTimeInterval(30),
                                     score: 2.1,
                                     evidenceMode: .cardiacArousal),
            AtriaStressDetailReading(date: now.addingTimeInterval(60), score: 1.4),
        ]

        let points = AtriaStressTimelinePoint.segment(readings)

        XCTAssertEqual(points.map(\.reading.date),
                       [now, now.addingTimeInterval(30), now.addingTimeInterval(60)])
        XCTAssertEqual(points.map(\.segment), [0, 0, 0])
    }

    func testHROnlyHistoryProjectsToContinuousPhysiologicalStressTimeline() {
        let readings = [
            AtriaStressDetailReading(date: now,
                                     score: 0,
                                     evidenceMode: .cardiacArousal),
            AtriaStressDetailReading(date: now.addingTimeInterval(30),
                                     score: 0.9,
                                     evidenceMode: .cardiacArousal),
            AtriaStressDetailReading(date: now.addingTimeInterval(60),
                                     score: AtriaStressEvidenceProjection.highStartsAt,
                                     evidenceMode: .cardiacArousal,
                                     level: .high),
        ]

        let projection = AtriaStressTimelineEvidenceProjection.make(readings: readings)

        XCTAssertEqual(projection.presentation, .physiologicalStress)
        XCTAssertEqual(projection.stressPoints.count, 3)
        XCTAssertEqual(projection.cardiacArousalPoints.count, 3)
        XCTAssertEqual(projection.cardiacArousalPoints.map(\.level),
                       [.calm, .calm, .medium])
        XCTAssertEqual(projection.displayedReadings, readings)
    }

    func testFullAndHROnlyEvidenceShareOneContinuousCoordinate() {
        let readings = [
            AtriaStressDetailReading(date: now,
                                     score: 1.2,
                                     evidenceMode: .cardiacArousal),
            AtriaStressDetailReading(date: now.addingTimeInterval(30),
                                     score: 1.4,
                                     evidenceMode: .physiologicalStress),
        ]

        let projection = AtriaStressTimelineEvidenceProjection.make(readings: readings)

        XCTAssertEqual(projection.presentation, .physiologicalStress)
        XCTAssertEqual(projection.stressPoints.map(\.reading.date),
                       [now, now.addingTimeInterval(30)])
        XCTAssertEqual(projection.cardiacArousalPoints.map(\.reading.date), [now])
    }

    func testElevatedEvidenceFindsOnlyMeasuredSustainedWindows() {
        let readings = stride(from: 0.0, through: 20 * 60.0, by: 30).map { offset in
            let minute = offset / 60
            let elevated = (5...9).contains(minute) || (14...18).contains(minute)
            return AtriaStressDetailReading(date: now.addingTimeInterval(offset),
                                             score: elevated ? 2.2 : 0.7)
        }

        let evidence = AtriaStressElevatedEvidence.analyze(readings)

        XCTAssertTrue(evidence.isSupported)
        XCTAssertEqual(evidence.windows.count, 2)
        XCTAssertEqual(evidence.countText, "2 elevated windows")
        XCTAssertEqual(evidence.windows.map(\.duration), [4 * 60, 4 * 60])
        XCTAssertTrue(evidence.windows.allSatisfy {
            $0.readingCount >= AtriaStressElevatedEvidence.minimumWindowReadings
        })
    }

    func testSparseElevatedReadingsSuppressWindowOverlayAndCount() {
        let readings = (0..<6).map { index in
            AtriaStressDetailReading(date: now.addingTimeInterval(Double(index) * 30),
                                     score: 2.5)
        }

        let evidence = AtriaStressElevatedEvidence.analyze(readings)

        XCTAssertFalse(evidence.isSupported)
        XCTAssertTrue(evidence.windows.isEmpty)
        XCTAssertNil(evidence.countText)
        XCTAssertNil(evidence.interventionDetail(state: scoredState(activation: 0.8),
                                                  updatedAt: readings.last?.date))
    }

    func testElevatedStressEvidenceIgnoresCardiacArousalPoints() {
        let readings = (0..<30).map { index in
            AtriaStressDetailReading(date: now.addingTimeInterval(Double(index) * 30),
                                     score: 3,
                                     evidenceMode: .cardiacArousal)
        }

        let evidence = AtriaStressElevatedEvidence.analyze(readings)

        XCTAssertEqual(evidence.readingCount, 0)
        XCTAssertFalse(evidence.isSupported)
        XCTAssertTrue(evidence.windows.isEmpty)
        XCTAssertNil(evidence.interventionDetail(
            state: scoredState(activation: 0.8, hrvAvailable: false),
            updatedAt: readings.last?.date
        ))
    }

    func testElevatedWindowAnalysisNeverBridgesARealTelemetryGap() {
        var readings = stride(from: 0.0, through: 2 * 60.0, by: 30).map {
            AtriaStressDetailReading(date: now.addingTimeInterval($0), score: 2.4)
        }
        readings += stride(from: 4 * 60.0, through: 6 * 60.0, by: 30).map {
            AtriaStressDetailReading(date: now.addingTimeInterval($0), score: 2.4)
        }
        readings += stride(from: 6.5 * 60.0, through: 17 * 60.0, by: 30).map {
            AtriaStressDetailReading(date: now.addingTimeInterval($0), score: 0.6)
        }

        let evidence = AtriaStressElevatedEvidence.analyze(readings)

        XCTAssertTrue(evidence.isSupported)
        XCTAssertTrue(evidence.windows.isEmpty)
        XCTAssertEqual(evidence.countText, "No elevated windows")
    }

    func testInterventionDetailUsesActiveMeasuredDurationAndScoringReason() throws {
        let readings = stride(from: 0.0, through: 15 * 60.0, by: 30).map { offset in
            AtriaStressDetailReading(date: now.addingTimeInterval(offset),
                                     score: offset >= 11 * 60 ? 2.3 : 0.6)
        }
        let evidence = AtriaStressElevatedEvidence.analyze(readings)
        let last = try XCTUnwrap(readings.last?.date)

        XCTAssertEqual(evidence.interventionDetail(state: scoredState(activation: 0.8),
                                                    updatedAt: last),
                       "4 min elevated · Physiological stress · HR + HRV")
        XCTAssertNil(evidence.interventionDetail(state: scoredState(activation: 0.8),
                                                  updatedAt: last.addingTimeInterval(91)))
        XCTAssertNil(evidence.interventionDetail(state: AtriaStressState(
            level: .low,
            label: "Low",
            detail: "HR + HRV vs your baseline",
            kind: .scored,
            confidence: 0.85,
            rawActivation: 0.3,
            hrvAvailable: true
        ), updatedAt: last))
    }

    func testRelaxActionStatesItsThreeMinuteDuration() {
        XCTAssertEqual(AtriaStressDetailCopy.relaxButtonTitle, "Relax · 3 min")
    }

    func testContextIntervalsCoalesceContiguousAsleepFactsIntoOneBand() {
        let readings = (0..<6).map { index in
            AtriaStressDetailReading(date: now.addingTimeInterval(Double(index) * 60),
                                     score: 0.4,
                                     sleepContext: .asleep)
        }
        let intervals = AtriaStressContextInterval.intervals(from: readings) {
            $0.sleepContext == .asleep
        }
        // Six consecutive asleep minutes coalesce into ONE band, not six stripes.
        XCTAssertEqual(intervals.count, 1)
        XCTAssertEqual(intervals[0].readingCount, 6)
        XCTAssertEqual(intervals[0].start, now)
        XCTAssertEqual(intervals[0].end, now.addingTimeInterval(300))
    }

    func testContextIntervalsBreakAtATelemetryGapAndAtNonMembers() {
        let readings = [
            AtriaStressDetailReading(date: now, score: 0.4, sleepContext: .asleep),
            AtriaStressDetailReading(date: now.addingTimeInterval(60), score: 0.4, sleepContext: .asleep),
            AtriaStressDetailReading(date: now.addingTimeInterval(60 + 10 * 60), score: 0.4, sleepContext: .asleep),
            AtriaStressDetailReading(date: now.addingTimeInterval(60 + 10 * 60 + 60), score: 0.4, sleepContext: .awake),
            AtriaStressDetailReading(date: now.addingTimeInterval(60 + 10 * 60 + 120), score: 0.4, sleepContext: .asleep),
        ]
        let intervals = AtriaStressContextInterval.intervals(from: readings) {
            $0.sleepContext == .asleep
        }
        // Run 1 = [0, 60] (2 facts); a > threshold gap breaks it; a lone asleep
        // fact; an awake fact breaks the run; a final lone asleep fact.
        XCTAssertEqual(intervals.count, 3)
        XCTAssertEqual(intervals[0].readingCount, 2)
        XCTAssertEqual(intervals[0].start, now)
        XCTAssertEqual(intervals[0].end, now.addingTimeInterval(60))
        XCTAssertEqual(intervals[1].readingCount, 1)
        // A lone member gets one minute-fact of visible width, never bridging.
        XCTAssertEqual(intervals[1].duration, 60, accuracy: 0.001)
        XCTAssertEqual(intervals[2].readingCount, 1)
        // No band bridges the telemetry gap.
        XCTAssertLessThan(intervals[0].end, intervals[1].start)
    }

    func testActivityContextIntervalsRequireQualifiedActivityFacts() {
        let qualified = AtriaPhysiologicalStressModel.MotionContext.qualifiedActivity(intensity: 0.5)
        let still = AtriaPhysiologicalStressModel.MotionContext.qualifiedStill
        let readings = [
            AtriaStressDetailReading(date: now, score: 1.0, motionContext: qualified),
            AtriaStressDetailReading(date: now.addingTimeInterval(60), score: 1.0, motionContext: qualified),
            AtriaStressDetailReading(date: now.addingTimeInterval(120), score: 1.0, motionContext: still),
        ]
        let intervals = AtriaStressContextInterval.intervals(from: readings) {
            $0.motionContext.qualified && $0.motionContext.kind == .activity
        }
        // Only the two qualified-activity facts coalesce; qualified-still is not
        // an activity band.
        XCTAssertEqual(intervals.count, 1)
        XCTAssertEqual(intervals[0].readingCount, 2)
    }

    func testStressContextBandsAreNotPerMinuteBarcode() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceDirectory = testsDirectory.deletingLastPathComponent().appendingPathComponent("Atria")
        for file in ["AtriaStressDetailView.swift", "AtriaVitalsCollectionSections.swift"] {
            let source = try String(contentsOf: sourceDirectory.appendingPathComponent(file), encoding: .utf8)
            XCTAssertFalse(
                source.contains(".value(\"Sleep start\", point.reading.date.addingTimeInterval(-30))"),
                "\(file) still draws a per-minute sleep barcode"
            )
            XCTAssertFalse(
                source.contains(".value(\"Activity start\", point.reading.date.addingTimeInterval(-30))"),
                "\(file) still draws a per-minute activity barcode"
            )
            XCTAssertTrue(
                source.contains("AtriaStressContextInterval.intervals(from: points.map(\\.reading))"),
                "\(file) must render coalesced context intervals"
            )
        }
    }

    func testStressHistoryCopyDoesNotRegressToSessionOnlyClaims() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceDirectory = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria")
        let files = [
            "AtriaActivityMonitor.swift",
            "AtriaOverviewSections.swift",
            "AtriaStressDetailView.swift",
            "AtriaVitalsCollectionSections.swift",
        ]
        let corpus = try files.map {
            try String(contentsOf: sourceDirectory.appendingPathComponent($0), encoding: .utf8)
        }.joined(separator: "\n").lowercased()

        for staleClaim in [
            "stress history is session-only",
            "doesn't yet save a daily stress history",
            "not a saved daily trend",
            "doesn't save a day-by-day stress history",
            "continuous stress timeline",
            "gaps mean the strap was not collecting",
        ] {
            XCTAssertFalse(corpus.contains(staleClaim), "stale stress copy: \(staleClaim)")
        }
        XCTAssertTrue(corpus.contains("first complete five-minute estimate"))
        XCTAssertTrue(corpus.contains("gaps remain blank"))
    }

    func testContinuousChartHasZonesInspectionRealHRAndNoCategoricalPicketFence() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaStressDetailView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let vitals = try String(
            contentsOf: testsDirectory
                .deletingLastPathComponent()
                .appendingPathComponent("Atria/AtriaVitalsCollectionSections.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains(".lineStyle(AtriaChartVisualGrammar.traceLine)"),
                      "the expanded traces must use the shared thin-line grammar")
        XCTAssertTrue(source.contains("Calm floor"))
        XCTAssertTrue(source.contains("Moderate floor"))
        XCTAssertTrue(source.contains("High floor"))
        XCTAssertTrue(source.contains(".chartOverlay { proxy in"))
        XCTAssertTrue(source.contains("HR-only estimate"))
        XCTAssertTrue(source.contains("AtriaStressHeartRateTimelineChart"))
        XCTAssertFalse(source.contains(".interpolationMethod(.stepCenter)"))
        XCTAssertFalse(source.contains("dash: [4, 4]"))
        XCTAssertFalse(source.contains("Calm + Low"))
        XCTAssertFalse(source.contains("percent calm or low"))
        XCTAssertFalse(source.contains("percent medium"))
        XCTAssertFalse(source.contains("label: \"Medium\""))
        XCTAssertTrue(source.contains("label: \"Moderate\""))
        for obsolete in ["0.60", "1.35", "2.16", "dash: [3, 3]"] {
            XCTAssertFalse(vitals.contains(obsolete),
                           "Vitals must not restore the categorical picket fence: \(obsolete)")
        }
    }

    func testStressAccessibilityAndCopyDisclosePhysiologyEvidenceAndHROnlyFallback() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceDirectory = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria")
        let detail = try String(
            contentsOf: sourceDirectory.appendingPathComponent("AtriaStressDetailView.swift"),
            encoding: .utf8
        )
        let monitor = try String(
            contentsOf: sourceDirectory.appendingPathComponent("AtriaStressMonitor.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(detail.contains("Physiological stress timeline"))
        XCTAssertTrue(detail.contains("Drag across the chart to inspect time, score, heart rate, HRV, motion context, and confidence"))
        XCTAssertTrue(detail.contains("state.minuteFact?.isHROnly == true"))
        XCTAssertTrue(monitor.contains("HR-only estimate · lower confidence"))
        XCTAssertTrue(monitor.contains("not a psychological diagnosis"))
    }

    private func scoredState(activation: Double,
                             hrvAvailable: Bool = true) -> AtriaStressState {
        let score = min(max(activation * 3, 0), 3)
        let confidence: AtriaPhysiologicalStressModel.Confidence = hrvAvailable
            ? .medium
            : .low
        let fact = AtriaPhysiologicalStressModel.MinuteFact(
            date: now,
            score: score,
            unsmoothedScore: score,
            meanHeartRate: 80,
            rmssd: hrvAvailable ? 50 : nil,
            hrStress: activation,
            hrvStress: hrvAvailable ? activation : nil,
            heartRateWeight: hrvAvailable ? 0.75 : 1,
            motionContext: .unavailable,
            sleepContext: .unavailable,
            confidence: confidence,
            baselineLearning: false
        )
        return AtriaStressState(level: .medium,
                         label: "Moderate",
                         detail: hrvAvailable
                            ? "Physiological stress · HR + HRV"
                            : "HR-only estimate · lower confidence",
                         kind: .scored,
                         confidence: confidence.numericValue,
                         rawActivation: activation,
                         hrvAvailable: hrvAvailable,
                         minuteFact: fact)
    }
}
