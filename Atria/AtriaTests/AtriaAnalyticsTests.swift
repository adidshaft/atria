import XCTest
@testable import Atria

final class AtriaAnalyticsTests: XCTestCase {
    func testCalibrationExamplesRemainInRange() {
        for check in AtriaAnalytics.CalibrationExamples.numericChecks {
            XCTAssertTrue(check.passed,
                          "\(check.name) expected \(check.expected) +/- \(check.tolerance), got \(check.actual)")
        }

        for check in AtriaAnalytics.CalibrationExamples.labelChecks {
            XCTAssertTrue(check.passed,
                          "\(check.name) expected \(check.expected), got \(check.actual)")
        }
    }

    func testSleepStagesIncludeREMInUserFacingOrder() {
        XCTAssertTrue(SleepStageKind.allCases.contains(.rem))
        XCTAssertEqual(SleepStageKind.rem.label, "REM")
        XCTAssertEqual(SleepStageKind.allCases.map(\.label), ["Awake", "Light", "REM", "SWS", "Deep"])
    }

    func testBiologicalAgeIsLocalEstimateAndClamped() {
        let factors = [
            AtriaAnalytics.BiologicalAge.factor(id: "vo2",
                                                label: "VO2max",
                                                ageEquivalent: 18,
                                                chronologicalAge: 45,
                                                weight: 0.50,
                                                detail: "strong aerobic base"),
            AtriaAnalytics.BiologicalAge.factor(id: "sleep",
                                                label: "Sleep",
                                                ageEquivalent: 20,
                                                chronologicalAge: 45,
                                                weight: 0.50,
                                                detail: "stable sleep")
        ]

        let summary = AtriaAnalytics.BiologicalAge.summary(chronologicalAge: 45, factors: factors)
        XCTAssertEqual(summary.biologicalAge, 25)
        XCTAssertEqual(summary.ageDelta, -20)
        XCTAssertEqual(summary.agingPaceText, "Younger pace")
        XCTAssertTrue(summary.footnote.lowercased().contains("estimate"))
    }

    func testHRVAnalyzerRequiresContinuousCleanRRWindow() {
        let now = Date()
        let cleanRR = (0...300).map { index in
            RRInterval(t: now.addingTimeInterval(Double(index - 300)),
                       ms: index.isMultiple(of: 2) ? 1_000 : 1_020,
                       expectedHR: 60)
        }

        let clean = HRVAnalyzer.analyze(cleanRR, now: now, includeTachogram: false).0
        XCTAssertEqual(clean?.readinessReason, "ready")
        XCTAssertEqual(clean?.kept, 301)
        XCTAssertEqual(clean?.rejectedOutOfRange, 0)
        XCTAssertEqual(clean?.rejectedHRMismatch, 0)
        XCTAssertTrue(clean?.isReady == true)

        let sparseRR = stride(from: 0, through: 300, by: 5).map { index in
            RRInterval(t: now.addingTimeInterval(Double(index - 300)),
                       ms: 1_000,
                       expectedHR: 60)
        }

        let sparse = HRVAnalyzer.analyze(sparseRR, now: now, includeTachogram: false).0
        XCTAssertEqual(sparse?.readinessReason, "gap")
        XCTAssertFalse(sparse?.isReady ?? true)
        XCTAssertGreaterThan(sparse?.maxRRGapSeconds ?? 0, HRVSnapshot.maxReadyRRGapSeconds)
    }

    func testHRVAnalyzerRejectsOutOfRangeAndHeartRateMismatch() {
        let now = Date()
        var samples = (0...300).map { index in
            RRInterval(t: now.addingTimeInterval(Double(index - 300)),
                       ms: 1_000,
                       expectedHR: 60)
        }
        samples[20] = RRInterval(t: samples[20].t, ms: 250, expectedHR: 60)
        samples[40] = RRInterval(t: samples[40].t, ms: 2_100, expectedHR: 60)
        samples[60] = RRInterval(t: samples[60].t, ms: 1_000, expectedHR: 120)

        let snapshot = HRVAnalyzer.analyze(samples, now: now, includeTachogram: false).0
        XCTAssertEqual(snapshot?.rejectedOutOfRange, 2)
        XCTAssertEqual(snapshot?.rejectedHRMismatch, 1)
        XCTAssertEqual(snapshot?.kept, 298)
        XCTAssertTrue(snapshot?.isReady == true)
    }

    func testRecoveryRefusesThinAndStaleBaselines() {
        let now = Date()
        let thinBaseline = PersonalBaseline(restingHR: 60,
                                            hrvEMA: 50,
                                            sessions: 3,
                                            updated: now,
                                            samples: baselineSamples(count: 3, now: now))

        let thin = AtriaAnalytics.Recovery.estimate(hrvSnapshot: nil,
                                                    fallbackRMSSD: 55,
                                                    restingNow: 58,
                                                    baseline: thinBaseline,
                                                    sleepEfficiency: 0.90,
                                                    sleepDurationHours: 7.5)
        XCTAssertNil(thin.percent)
        XCTAssertEqual(thin.confidence, .learning)
        XCTAssertFalse(thin.usesHRV)

        let staleDate = now.addingTimeInterval(-(PersonalBaseline.staleAfter + 86_400))
        let staleBaseline = PersonalBaseline(restingHR: 60,
                                             hrvEMA: 50,
                                             sessions: PersonalBaseline.trustedMinimumSamples,
                                             updated: staleDate,
                                             samples: baselineSamples(count: PersonalBaseline.trustedMinimumSamples,
                                                                      now: staleDate))
        let stale = AtriaAnalytics.Recovery.estimate(hrvSnapshot: nil,
                                                     fallbackRMSSD: 55,
                                                     restingNow: 58,
                                                     baseline: staleBaseline,
                                                     sleepEfficiency: 0.90,
                                                     sleepDurationHours: 7.5)
        XCTAssertNil(stale.percent)
        XCTAssertEqual(stale.confidence, .learning)
    }

    func testRecoveryUsesTrustedBaselineAndSleepEvidence() {
        let now = Date()
        let baseline = PersonalBaseline(restingHR: 60,
                                        hrvEMA: 50,
                                        sessions: PersonalBaseline.trustedMinimumSamples,
                                        updated: now,
                                        samples: baselineSamples(count: PersonalBaseline.trustedMinimumSamples,
                                                                 now: now))

        let estimate = AtriaAnalytics.Recovery.estimate(hrvSnapshot: nil,
                                                        fallbackRMSSD: 56,
                                                        restingNow: 58,
                                                        baseline: baseline,
                                                        hrvReferenceValidated: false,
                                                        sleepEfficiency: 0.91,
                                                        sleepDurationHours: 7.6)

        XCTAssertNotNil(estimate.percent)
        XCTAssertEqual(estimate.confidence, .personalBaseline)
        XCTAssertTrue(estimate.usesHRV)
        XCTAssertTrue((1...99).contains(estimate.percent ?? 0))
        XCTAssertTrue(estimate.detail.contains("lnRMSSD z"))
    }

    func testTrainingLoadFlagsUnsafeSpikesAndBalancedLoad() {
        let spike = AtriaAnalytics.TrainingLoad.summary(dailyStrains: Array(repeating: 16.0, count: 7)
                                                        + Array(repeating: 8.0, count: 21))
        XCTAssertEqual(spike.confidence, "local")
        XCTAssertEqual(spike.acwrSignal, "bad")
        XCTAssertEqual(spike.readiness, "rundown")

        let balancedHistory = [9.0, 10.0, 11.0, 9.5, 10.5, 11.0, 9.0]
            + Array(repeating: 10.0, count: 21)
        let balanced = AtriaAnalytics.TrainingLoad.summary(dailyStrains: balancedHistory)
        XCTAssertEqual(balanced.confidence, "local")
        XCTAssertEqual(balanced.acwrSignal, "good")
        XCTAssertEqual(balanced.monotonySignal, "good")
        XCTAssertEqual(balanced.readiness, "balanced")
        XCTAssertNotNil(balanced.targetBand)
    }

    private func baselineSamples(count: Int, now: Date) -> [PersonalBaseline.BaselineSample] {
        (0..<count).map { index in
            PersonalBaseline.BaselineSample(date: now.addingTimeInterval(Double(-index * 86_400)),
                                            restingHR: [58.0, 60.0, 62.0][index % 3],
                                            rmssd: [48.0, 52.0, 56.0][index % 3])
        }
    }
}
