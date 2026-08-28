import XCTest
@testable import Atria

final class AtriaStrainTruthUIBatchTests: XCTestCase {
    private let cycleStart = Date(timeIntervalSince1970: 1_800_000_000)

    private func workout(
        label: String = "Strength",
        coverage: Int,
        reason: String,
        startOffset: TimeInterval = 600
    ) -> UserConfirmedWorkout {
        let start = cycleStart.addingTimeInterval(startOffset)
        return UserConfirmedWorkout(
            id: "\(label)-\(coverage)",
            createdAt: start,
            start: start,
            end: start.addingTimeInterval(3_210),
            label: label,
            source: "live_workout_window",
            confidence: "high",
            sessions: 1,
            samples: 2_563,
            avgHR: 118,
            peakHR: 157,
            p95HR: 151,
            p99HR: 156,
            thresholdHR: 124,
            streamCoveragePercent: coverage,
            observedDuration: 2_696,
            reason: reason,
            strain: 4.3,
            zoneSeconds: [:]
        )
    }

    func testWorkoutGapExplainsPartialStrainEvenWithCompleteDayWear() {
        let limitation = AtriaWorkoutMetricPresentation.strainLimitation(
            start: cycleStart,
            end: cycleStart.addingTimeInterval(8_000),
            workouts: [workout(coverage: 84, reason: "stream_gaps")],
            dayWearCoverageFraction: 1
        )

        XCTAssertEqual(limitation,
                       .workoutHeartRate(label: "Strength", coveragePercent: 84))
        XCTAssertEqual(limitation?.compactState, "Workout HR incomplete")
        XCTAssertEqual(
            limitation?.explanation,
            "Strength captured 84% of workout heart rate. Today's strain is a lower bound."
        )
    }

    func testCleanWorkoutHasNoLimitationAndLowDayWearNamesDayCoverage() {
        let end = cycleStart.addingTimeInterval(8_000)
        XCTAssertNil(AtriaWorkoutMetricPresentation.strainLimitation(
            start: cycleStart,
            end: end,
            workouts: [workout(coverage: 100, reason: "complete")],
            dayWearCoverageFraction: 1
        ))
        XCTAssertEqual(AtriaWorkoutMetricPresentation.strainLimitation(
            start: cycleStart,
            end: end,
            workouts: [],
            dayWearCoverageFraction: 0.72
        ), .dayWear(coveragePercent: 72))
    }

    func testWorkoutLimitationOverridesGenericPartDayProvenanceCopy() {
        let provenance = AtriaMetricProvenance(
            displayValue: "≥ 6.3",
            level: .limited,
            isLowerBound: true,
            usesHRV: nil,
            hrCoverageFraction: 1,
            sourceLabel: "Strap heart rate",
            observedAt: nil,
            strainLimitation: .workoutHeartRate(
                label: "Strength",
                coveragePercent: 84
            )
        )

        XCTAssertEqual(
            provenance.reducedConfidenceReason,
            "Strength captured 84% of workout heart rate. Today's strain is a lower bound."
        )
        XCTAssertFalse(provenance.reducedConfidenceReason?.contains("part of the day") == true)
        XCTAssertEqual(provenance.improvementHint,
                       "Keep the strap connected through the full workout.")
    }

    func testStructuredLimitationPresentationNeverInventsPendingSync() {
        let limitations: [AtriaWorkoutMetricPresentation.StrainLimitation] = [
            .workoutHeartRate(label: "Strength", coveragePercent: 84),
            .dayWear(coveragePercent: 72),
            .incompleteEvidence
        ]
        let presentations = limitations.map(
            AtriaWorkoutMetricPresentation.strainLimitationPresentation
        )

        XCTAssertEqual(presentations[0].compactState, "Workout HR incomplete")
        XCTAssertEqual(
            presentations[0].explanation,
            "Strength captured 84% of workout heart rate. Today's strain is a lower bound."
        )
        XCTAssertEqual(presentations[0].improvementHint,
                       "Keep the strap connected through the full workout.")
        XCTAssertEqual(presentations[1].compactState, "Day HR incomplete")
        XCTAssertEqual(
            presentations[1].explanation,
            "Heart-rate coverage is 72% for this physiological day. Today's strain is a lower bound."
        )
        XCTAssertEqual(presentations[1].improvementHint,
                       "Keep the strap connected for more of the day.")
        XCTAssertEqual(presentations[2].compactState, "Strain data incomplete")
        XCTAssertEqual(
            presentations[2].explanation,
            "Some heart-rate evidence is incomplete. Today's strain is a lower bound."
        )
        XCTAssertEqual(presentations[2].improvementHint,
                       "Keep the strap connected while Atria records heart rate.")

        for (limitation, presentation) in zip(limitations, presentations) {
            XCTAssertEqual(presentation.compactState, limitation.compactState)
            XCTAssertEqual(presentation.explanation, limitation.explanation)
            XCTAssertEqual(presentation.improvementHint, limitation.improvementHint)
            XCTAssertEqual(presentation.detailText,
                           "\(limitation.explanation) \(limitation.improvementHint)")
            XCTAssertEqual(presentation.targetContext, "lower-bound strain")
            XCTAssertEqual(presentation.accessibilityText,
                           "\(limitation.compactState). \(presentation.detailText)")
            XCTAssertFalse(
                [presentation.compactState,
                 presentation.detailText,
                 presentation.targetContext,
                 presentation.accessibilityText]
                    .joined(separator: " ")
                    .localizedCaseInsensitiveContains("sync")
            )
        }
    }

    func testPartialPresentationKeepsMeasuredArcAndWithholdsTargets() throws {
        XCTAssertFalse(AtriaCompactMetricPresentation.isPendingValue("≥ 11.9"))
        let lowerBoundFill = try XCTUnwrap(
            AtriaRingMetricProjection.strainFill(strain: 11.9, isPending: false)
        )
        XCTAssertEqual(lowerBoundFill, 11.9 / 21, accuracy: 0.0001)
        XCTAssertEqual(
            AtriaRingMetricProjection.strainTintHex(
                targetProgress: nil,
                actualFill: lowerBoundFill
            ),
            AtriaRingMetricProjection.strainIdentityTintHex
        )

        let sources = try sourceText()
        XCTAssertTrue(sources.today.contains("isPending: pending"))
        XCTAssertTrue(sources.today.contains("if let fill = slot.metric.fill"),
                      "the compact Today ring must retain the measured partial arc")
        XCTAssertTrue(sources.today.contains("fill: strainMetric.fill"),
                      "the Today share projection must retain the same measured arc")
        // 2026-08-28: the Daily Brief left Today for the Journal tab, taking
        // its target line (and the presentation wrapper that fed it) with it.
        // The disclosure itself did NOT leave — the strain ring's own detail
        // still names the limitation, which is the assertion that matters:
        // an incomplete day must say WHY its target is withheld.
        XCTAssertTrue(sources.today.contains("currentStrainLimitation?.compactState"),
                      "the strain ring must still name the limitation")
        XCTAssertTrue(sources.today.contains("?? \"Strain data incomplete\""),
                      "and must fall back to an honest phrase, never a blank")
        XCTAssertFalse(sources.today.localizedCaseInsensitiveContains("compare after sync"))
        XCTAssertFalse(sources.today.contains("\"Finish sync\""))
        XCTAssertTrue(sources.today.contains("guard !dayStrainIsIncomplete else { return nil }"))
        XCTAssertTrue(sources.overview.contains("Text(displayValue)"))
        XCTAssertTrue(sources.overview.contains("overviewStrainLimitation?.compactState"))
        XCTAssertFalse(sources.overview.contains("Partial · limited wear"))
        XCTAssertTrue(sources.overview.contains("private var strainMeasuredFraction: Double?"))
        XCTAssertTrue(sources.overview.contains("let fill = strainMeasuredFraction"),
                      "the main Overview tri-ring must retain measured partial Strain")
        XCTAssertTrue(sources.overview.contains("ringFraction: strainMeasuredFraction"),
                      "the Overview glance marker must retain measured partial Strain")
        XCTAssertTrue(sources.overview.contains("? strainMeasuredFraction"),
                      "the optional Daily Focus rail must retain measured partial Strain")
        XCTAssertFalse(sources.overview.contains(
            "metricIsPending(hero.strainValue) || strainIsPartial\n                                        ? nil"
        ))
        XCTAssertTrue(sources.triRing.contains("fraction: content.metric.fill"),
                      "the separate-ring layout must receive the same non-nil fill")
        XCTAssertTrue(sources.overview.contains("value: currentCycleStrainTruth.exactTrendValue"),
                      "partial strain must remain excluded from exact trends")
    }

    func testUnavailableRingHasOneDashTrackAndVitalsUsesTruthAwareRail() throws {
        let sources = try sourceText()
        XCTAssertFalse(sources.triRing.contains("dash: [2, lineWidth * 1.4]"))
        XCTAssertEqual(sources.triRing.components(separatedBy: "dash: [4, 16]").count - 1,
                       1)
        // 2026-08-26: this assertion's subject lived in the orphaned Vitals
        // tab tree (AtriaVitalsTabContent, zero construction sites), removed
        // in that change. AtriaHomeView mounts AtriaHealthScreen for the
        // Vitals tab and always has, so this was guarding UI nobody could
        // open. Recorded rather than silently deleted: it means this behaviour
        // was BUILT AND TESTED but never reached the live screen.
        //
        // UNMIGRATED, and this is the most substantial of the three: the entire
        // truth-aware strain rail — AtriaStrainScaleRail with its limitation
        // explanation, improvement hint, and partial-strain suppression — lived
        // in AtriaRecoveryStrainCard inside the dead tree. The live Vitals tab
        // has no strain rail at all. That is a real feature gap, not a
        // regression from the removal: it was never reachable.
        XCTAssertFalse(sources.vitals.contains("AtriaStrainScaleRail("),
                       "the dead card must stay removed")
        XCTAssertFalse(sources.vitals.contains("AtriaStrainBandGauge("),
                       "and the gauge it replaced must not come back either")
    }

    private func sourceText() throws -> (
        today: String,
        overview: String,
        vitals: String,
        triRing: String
    ) {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let app = tests.deletingLastPathComponent().appendingPathComponent("Atria")
        return (
            try String(contentsOf: app.appendingPathComponent("AtriaTodayScreen.swift"),
                       encoding: .utf8),
            try String(contentsOf: app.appendingPathComponent("AtriaOverviewSections.swift"),
                       encoding: .utf8),
            try String(contentsOf: app.appendingPathComponent("AtriaVitalsCollectionSections.swift"),
                       encoding: .utf8),
            try String(contentsOf: app.appendingPathComponent("AtriaTriRing.swift"),
                       encoding: .utf8)
        )
    }
}
