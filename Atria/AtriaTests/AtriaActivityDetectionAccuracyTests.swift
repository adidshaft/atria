import XCTest
@testable import Atria

final class AtriaActivityDetectionAccuracyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testSingleHeartRateSpikeNeverQualifiesAsWorkout() {
        let start = now.addingTimeInterval(-8 * 60)
        let resting = (0..<479).map {
            HRSample(t: start.addingTimeInterval(TimeInterval($0)), bpm: 62)
        }
        let spike = HRSample(t: now, bpm: 155)

        let result = AtriaWorkoutPromptEvaluator.evaluate(samples: resting + [spike],
                                                          currentHeartRate: spike.bpm,
                                                          restingHeartRate: 60,
                                                          maxHeartRate: 190,
                                                          hasContact: true,
                                                          now: now)

        XCTAssertFalse(result.shouldPrompt)
        XCTAssertLessThan(result.longestElevatedBout,
                          AtriaWorkoutPromptEvaluator.minimumContinuousElevatedSamples)
        XCTAssertLessThan(result.recentElevatedSamples,
                          AtriaWorkoutPromptEvaluator.recentConfirmationSamples)
    }

    func testZonePathRequiresCurrentHeartRateToRemainInQualifyingZone() {
        let start = now.addingTimeInterval(-(4 * 60 + 1))
        let zoneThree = (0...240).map {
            HRSample(t: start.addingTimeInterval(TimeInterval($0)), bpm: 151)
        }
        let settledNow = HRSample(t: now, bpm: 62)

        let result = AtriaWorkoutPromptEvaluator.evaluate(samples: zoneThree + [settledNow],
                                                          currentHeartRate: settledNow.bpm,
                                                          restingHeartRate: 60,
                                                          maxHeartRate: 190,
                                                          now: now)

        XCTAssertGreaterThanOrEqual(result.zoneSamples,
                                    AtriaWorkoutPromptEvaluator.zoneMinimumSamples)
        XCTAssertGreaterThanOrEqual(result.recentZoneSamples,
                                    AtriaWorkoutPromptEvaluator.recentConfirmationSamples)
        XCTAssertFalse(result.zonePath,
                       "recent zone history must not keep a prompt alive after current HR leaves the zone")
        XCTAssertFalse(result.shouldPrompt)
    }

    func testLowAcceptedPacketShareFailsClosedEvenWithoutNamedArtifacts() {
        let start = now.addingTimeInterval(-8 * 60)
        let elevated = (0..<480).map {
            HRSample(t: start.addingTimeInterval(TimeInterval($0)), bpm: 95)
        }
        let quality = AtriaWorkoutPromptEvaluator.SignalQuality(rawSamples: 480,
                                                                acceptedSamples: 300,
                                                                zeroSamples: 0,
                                                                heldArtifacts: 0,
                                                                droppedArtifacts: 0,
                                                                acceptedGapCount: 0,
                                                                maxAcceptedGap: 1,
                                                                rrImpliedMedianBPM: nil)

        let result = AtriaWorkoutPromptEvaluator.evaluate(samples: elevated,
                                                          currentHeartRate: 95,
                                                          restingHeartRate: 60,
                                                          maxHeartRate: 190,
                                                          signalQuality: quality,
                                                          now: now)

        XCTAssertFalse(result.shouldPrompt)
    }

    func testAcceptedTwelveSecondCadenceUsesSavedSessionContinuityContract() {
        let start = now.addingTimeInterval(-8 * 60)
        let elevated = stride(from: 0.0, through: 8 * 60.0, by: 12).map {
            HRSample(t: start.addingTimeInterval($0), bpm: 95)
        }
        let quality = AtriaWorkoutPromptEvaluator.SignalQuality(
            rawSamples: elevated.count,
            acceptedSamples: elevated.count,
            zeroSamples: 0,
            heldArtifacts: 0,
            droppedArtifacts: 0,
            acceptedGapCount: 0,
            maxAcceptedGap: 12,
            rrImpliedMedianBPM: nil
        )

        let result = AtriaWorkoutPromptEvaluator.evaluate(samples: elevated,
                                                          currentHeartRate: 95,
                                                          restingHeartRate: 60,
                                                          maxHeartRate: 190,
                                                          hasContact: true,
                                                          signalQuality: quality,
                                                          now: now)

        XCTAssertEqual(AtriaWorkoutPromptEvaluator.maximumPacketGap,
                       SavedSession.workoutContinuityGapLimit)
        XCTAssertTrue(result.shouldPrompt,
                      "CRC-valid 12-second delivery cadence must not fragment a real effort")
        XCTAssertGreaterThanOrEqual(result.longestElevatedBout,
                                    AtriaWorkoutPromptEvaluator.minimumContinuousElevatedSamples)
    }

    func testGapBeyondSavedSessionContinuityCannotBridgeElevatedBout() {
        let gap = SavedSession.workoutContinuityGapLimit + 1
        let start = now.addingTimeInterval(-8 * 60)
        var elevated: [HRSample] = []
        var offset: TimeInterval = 0
        while offset <= 8 * 60 {
            elevated.append(HRSample(t: start.addingTimeInterval(offset), bpm: 95))
            offset += gap
        }
        if elevated.last?.t != now {
            elevated.append(HRSample(t: now, bpm: 95))
        }

        let result = AtriaWorkoutPromptEvaluator.evaluate(samples: elevated,
                                                          currentHeartRate: 95,
                                                          restingHeartRate: 60,
                                                          maxHeartRate: 190,
                                                          hasContact: true,
                                                          now: now)

        XCTAssertFalse(result.shouldPrompt)
        XCTAssertLessThanOrEqual(result.longestElevatedBout,
                                 Int(SavedSession.workoutContinuityGapLimit),
                                 "each hard gap must reset the continuous bout")
        XCTAssertLessThan(result.longestElevatedBout,
                          AtriaWorkoutPromptEvaluator.minimumContinuousElevatedSamples)
    }

    func testRRValuesCannotBridgeMultipleHardGapEffortBouts() {
        let start = now.addingTimeInterval(-400)
        let first = (0..<120).map {
            HRSample(t: start.addingTimeInterval(TimeInterval($0)), bpm: 95)
        }
        let secondStart = start.addingTimeInterval(140)
        let second = (0..<120).map {
            HRSample(t: secondStart.addingTimeInterval(TimeInterval($0)), bpm: 95)
        }
        let thirdStart = secondStart.addingTimeInterval(140)
        let third = (0...120).map {
            HRSample(t: thirdStart.addingTimeInterval(TimeInterval($0)), bpm: 95)
        }
        let samples = first + second + third
        let quality = AtriaWorkoutPromptEvaluator.SignalQuality(
            rawSamples: samples.count,
            acceptedSamples: samples.count,
            zeroSamples: 0,
            heldArtifacts: 0,
            droppedArtifacts: 0,
            acceptedGapCount: 2,
            maxAcceptedGap: 21,
            rrImpliedMedianBPM: 95
        )

        let result = AtriaWorkoutPromptEvaluator.evaluate(samples: samples,
                                                          currentHeartRate: 95,
                                                          restingHeartRate: 60,
                                                          maxHeartRate: 190,
                                                          hasContact: true,
                                                          signalQuality: quality,
                                                          now: now)

        XCTAssertGreaterThanOrEqual(result.elevatedSamples,
                                    AtriaWorkoutPromptEvaluator.minimumSustainedElevatedSamples)
        XCTAssertGreaterThanOrEqual(result.longestElevatedBout,
                                    AtriaWorkoutPromptEvaluator.minimumContinuousElevatedSamples)
        XCTAssertFalse(result.shouldPrompt,
                       "sparse RR corroboration must not bridge hard accepted-HR transport gaps")
    }

    func testRecoveredStreamCanPromptAfterFreshContinuousEffort() {
        let start = now.addingTimeInterval(-8 * 60)
        let beforeDisconnect = (0..<60).map {
            HRSample(t: start.addingTimeInterval(TimeInterval($0)), bpm: 95)
        }
        let recoveredStart = now.addingTimeInterval(-(5 * 60 + 1))
        let recovered = (0...301).map {
            HRSample(t: recoveredStart.addingTimeInterval(TimeInterval($0)), bpm: 95)
        }
        let samples = beforeDisconnect + recovered
        let quality = AtriaWorkoutPromptEvaluator.SignalQuality(
            rawSamples: samples.count,
            acceptedSamples: samples.count,
            zeroSamples: 0,
            heldArtifacts: 0,
            droppedArtifacts: 0,
            acceptedGapCount: 1,
            maxAcceptedGap: recoveredStart.timeIntervalSince(beforeDisconnect.last!.t),
            rrImpliedMedianBPM: nil
        )

        let result = AtriaWorkoutPromptEvaluator.evaluate(samples: samples,
                                                          currentHeartRate: 95,
                                                          restingHeartRate: 60,
                                                          maxHeartRate: 190,
                                                          hasContact: true,
                                                          signalQuality: quality,
                                                          now: now)

        XCTAssertTrue(result.shouldPrompt,
                      "an older disconnect must not suppress a new five-minute continuous effort")
        XCTAssertGreaterThanOrEqual(result.longestElevatedBout,
                                    AtriaWorkoutPromptEvaluator.minimumSustainedElevatedSamples)
    }

    func testSeparatedElevatedBoutsCannotAggregateIntoOneWorkoutPrompt() {
        let start = now.addingTimeInterval(-8 * 60)
        var samples: [HRSample] = []
        for second in 0...480 {
            let cycle = second % 120
            let bpm = cycle < 75 ? 95 : 62
            samples.append(HRSample(t: start.addingTimeInterval(TimeInterval(second)),
                                    bpm: bpm))
        }

        let result = AtriaWorkoutPromptEvaluator.evaluate(samples: samples,
                                                          currentHeartRate: 95,
                                                          restingHeartRate: 60,
                                                          maxHeartRate: 190,
                                                          now: now)

        XCTAssertGreaterThanOrEqual(result.elevatedSamples,
                                    AtriaWorkoutPromptEvaluator.minimumSustainedElevatedSamples)
        XCTAssertLessThan(result.longestElevatedBout,
                          AtriaWorkoutPromptEvaluator.minimumSustainedElevatedSamples)
        XCTAssertFalse(result.shouldPrompt,
                       "separate short bouts must not add up to one continuous workout episode")
    }

    func testReconnectMicrogapJumpCannotSeedLiveEffortEvidence() {
        let start = now.addingTimeInterval(-8 * 60)
        let resting = (0..<180).map {
            HRSample(t: start.addingTimeInterval(TimeInterval($0)), bpm: 62)
        }
        let jumpStart = start.addingTimeInterval(184)
        let elevated = (0...296).map {
            HRSample(t: jumpStart.addingTimeInterval(TimeInterval($0)), bpm: 95)
        }
        let samples = resting + elevated

        let result = AtriaWorkoutPromptEvaluator.evaluate(samples: samples,
                                                          currentHeartRate: 95,
                                                          restingHeartRate: 60,
                                                          maxHeartRate: 190,
                                                          now: now)

        XCTAssertEqual(result.elevatedSamples, 296,
                       "the reconnect interval and first post-gap sample must remain unverified")
        XCTAssertFalse(result.shouldPrompt,
                       "live evaluation must not promote evidence persisted readiness rejects")
    }

    func testDeniedOrUnavailablePhoneContextAbstainsWithoutBlockingStrapWorkout() {
        let subtype = AtriaActivitySubtypeClassifier.evaluate(phone: nil, now: now)
        let motionGate = AtriaMotionActivityGate.evaluate(.unknown, now: now)

        XCTAssertEqual(subtype, .abstain)
        XCTAssertFalse(motionGate.vetoesWorkoutPrompt)
        XCTAssertNil(motionGate.suggestedActivityType)
    }

    func testOnlyFreshSustainedNativeLocomotionCanProduceVisibleSubtype() {
        let expected: [(AtriaMotionActivityContext.Kind, AtriaWorkoutActivityType)] = [
            (.walking, .walking),
            (.running, .running),
            (.cycling, .cycling)
        ]

        for (kind, type) in expected {
            let decision = AtriaActivitySubtypeClassifier.evaluate(
                phone: context(kind: kind,
                               confidence: .high,
                               duration: AtriaMotionActivityGate.minimumSuggestionDuration,
                               age: 1),
                now: now
            )
            XCTAssertEqual(decision.suggestedActivityType, type)
            XCTAssertEqual(decision.confidence, .high)
            XCTAssertEqual(decision.source, .nativePhoneActivity)
            XCTAssertNil(decision.shadowCandidate)
        }
    }

    func testLowConfidenceBriefAndStaleNativeLabelsAbstain() {
        let contexts = [
            context(kind: .walking, confidence: .low, duration: 10 * 60, age: 1),
            context(kind: .running,
                    confidence: .high,
                    duration: AtriaMotionActivityGate.minimumSuggestionDuration - 1,
                    age: 1),
            context(kind: .cycling,
                    confidence: .high,
                    duration: 10 * 60,
                    age: AtriaMotionActivityGate.maximumEvidenceAge + 1)
        ]

        for context in contexts {
            XCTAssertNil(AtriaActivitySubtypeClassifier.evaluate(phone: context,
                                                                  now: now).suggestedActivityType)
        }
    }

    func testPlausibleStrapGaitStaysShadowOnlyUntilLabelledValidation() {
        let gait = AtriaActivitySubtypeClassifier.StrapGaitEvidence(
            contiguousDuration: 60,
            cadenceStepsPerMinute: 112,
            periodicity: 0.78,
            cadenceConsistency: 0.91,
            gyroscopeAgreement: 0.86
        )

        let decision = AtriaActivitySubtypeClassifier.evaluate(phone: nil,
                                                                strapGait: gait,
                                                                now: now)

        XCTAssertNil(decision.suggestedActivityType,
                     "unvalidated wrist gait must not become a user-visible walking label")
        XCTAssertEqual(decision.confidence, .low)
        XCTAssertEqual(decision.source, .strapGaitShadow)
        XCTAssertEqual(decision.shadowCandidate, .walking)
        XCTAssertNotEqual(decision.shadowCandidate, .dance)
        XCTAssertNotEqual(decision.shadowCandidate, .strength)
    }

    func testRhythmicButNonLocomotionStrapEvidenceCannotInventDanceOrStrength() {
        let handling = AtriaActivitySubtypeClassifier.StrapGaitEvidence(
            contiguousDuration: 60,
            cadenceStepsPerMinute: 260,
            periodicity: 0.90,
            cadenceConsistency: 0.95,
            gyroscopeAgreement: 0.90
        )

        let decision = AtriaActivitySubtypeClassifier.evaluate(phone: nil,
                                                                strapGait: handling,
                                                                now: now)

        XCTAssertEqual(decision, .abstain)
        XCTAssertNil(decision.suggestedActivityType)
        XCTAssertNil(decision.shadowCandidate)
    }

    func testNonFiniteOrOutOfRangeGaitQualityAlwaysAbstains() {
        let malformed = [
            AtriaActivitySubtypeClassifier.StrapGaitEvidence(
                contiguousDuration: .infinity,
                cadenceStepsPerMinute: 112,
                periodicity: 0.78,
                cadenceConsistency: 0.91,
                gyroscopeAgreement: 0.86
            ),
            AtriaActivitySubtypeClassifier.StrapGaitEvidence(
                contiguousDuration: 60,
                cadenceStepsPerMinute: 112,
                periodicity: .infinity,
                cadenceConsistency: 0.91,
                gyroscopeAgreement: 0.86
            ),
            AtriaActivitySubtypeClassifier.StrapGaitEvidence(
                contiguousDuration: 60,
                cadenceStepsPerMinute: 112,
                periodicity: 0.78,
                cadenceConsistency: 1.1,
                gyroscopeAgreement: 0.86
            ),
            AtriaActivitySubtypeClassifier.StrapGaitEvidence(
                contiguousDuration: 60,
                cadenceStepsPerMinute: 112,
                periodicity: 0.78,
                cadenceConsistency: 0.91,
                gyroscopeAgreement: .infinity
            )
        ]

        for evidence in malformed {
            XCTAssertEqual(AtriaActivitySubtypeClassifier.evaluate(phone: nil,
                                                                    strapGait: evidence,
                                                                    now: now),
                           .abstain)
        }
    }

    func testAutomotiveVetoNeedsFreshMediumOrHighNativeEvidence() {
        let fresh = context(kind: .automotive,
                            confidence: .medium,
                            duration: 5 * 60,
                            age: 1)
        let low = context(kind: .automotive,
                          confidence: .low,
                          duration: 5 * 60,
                          age: 1)
        let stale = context(kind: .automotive,
                            confidence: .high,
                            duration: 5 * 60,
                            age: AtriaMotionActivityGate.maximumEvidenceAge + 1)

        XCTAssertTrue(AtriaMotionActivityGate.evaluate(fresh, now: now).vetoesWorkoutPrompt)
        XCTAssertFalse(AtriaMotionActivityGate.evaluate(low, now: now).vetoesWorkoutPrompt)
        XCTAssertFalse(AtriaMotionActivityGate.evaluate(stale, now: now).vetoesWorkoutPrompt)
    }

    private func context(kind: AtriaMotionActivityContext.Kind,
                         confidence: AtriaMotionActivityContext.Confidence,
                         duration: TimeInterval,
                         age: TimeInterval) -> AtriaMotionActivityContext {
        AtriaMotionActivityContext(kind: kind,
                                   confidence: confidence,
                                   startedAt: now.addingTimeInterval(-duration),
                                   observedAt: now.addingTimeInterval(-age))
    }
}
