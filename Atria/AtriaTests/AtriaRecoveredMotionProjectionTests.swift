import XCTest
@testable import Atria

final class AtriaRecoveredMotionProjectionTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)

    func testValidatedStillWindowProducesLowMotionEvidenceWithoutSyntheticActivity() {
        let window = makeWindow(duration: 30 * 60)
        let samples = stride(from: 0, through: 30 * 60, by: 6).enumerated().map { index, offset in
            sample(offset: TimeInterval(offset), sequence: index, x: 0, y: 0, z: 1)
        }

        let evidence = AtriaRecoveredMotionProjection.project(samples: samples, window: window)

        XCTAssertTrue(evidence.measurementValidated)
        XCTAssertTrue(evidence.lowMotionQualified)
        XCTAssertEqual(evidence.stillnessRatio, 1)
        XCTAssertEqual(evidence.movementIntensity, 0)
        XCTAssertEqual(evidence.savedSessionFields.motionEvidenceValidated, true)
        XCTAssertEqual(evidence.savedSessionFields.imuValidationState,
                       "historical_gravity_measurement_validated")
        XCTAssertNil(evidence.savedSessionFields.imuSampleCount,
                     "archive rows are frames, not decoded native IMU samples")
        XCTAssertEqual(evidence.savedSessionFields.imuFrameCount, evidence.validatedRows)
        XCTAssertNil(evidence.savedSessionFields.imuActivityBursts)
        XCTAssertNil(evidence.savedSessionFields.strapStepResearchCount)
    }

    func testValidatedMovementRemainsUsableEvidenceButCannotValidateSleepStillness() {
        let window = makeWindow(duration: 30 * 60)
        let samples = stride(from: 0, through: 30 * 60, by: 6).enumerated().map { index, offset in
            let phase = index.isMultiple(of: 2) ? 0.8 : -0.8
            return sample(offset: TimeInterval(offset), sequence: index, x: phase, y: 0, z: 0.6)
        }

        let evidence = AtriaRecoveredMotionProjection.project(samples: samples, window: window)

        XCTAssertTrue(evidence.measurementValidated)
        XCTAssertFalse(evidence.lowMotionQualified)
        XCTAssertGreaterThan(evidence.movementIntensity ?? 0, 1)
        XCTAssertEqual(evidence.savedSessionFields.motionEvidenceValidated, false,
                       "SavedSession's existing boolean is a low-motion sleep gate")
        XCTAssertNotNil(evidence.savedSessionFields.imuMovementIntensity,
                        "validated high motion remains available to activity logic")
        XCTAssertNil(evidence.savedSessionFields.strapStepResearchCount)
    }

    func testUnvalidatedRowsNeverPopulateClassifierFeatures() {
        let window = makeWindow(duration: 30 * 60)
        let samples = stride(from: 0, through: 30 * 60, by: 6).enumerated().map { index, offset in
            sample(offset: TimeInterval(offset), sequence: index, validated: false)
        }

        let evidence = AtriaRecoveredMotionProjection.project(samples: samples, window: window)

        XCTAssertFalse(evidence.measurementValidated)
        XCTAssertFalse(evidence.lowMotionQualified)
        XCTAssertEqual(evidence.validatedRows, 0)
        XCTAssertEqual(evidence.rejectedRows, samples.count)
        XCTAssertNil(evidence.savedSessionFields.imuStillnessRatio)
        XCTAssertNil(evidence.savedSessionFields.imuMovementIntensity)
        XCTAssertNil(evidence.savedSessionFields.imuValidationState)
    }

    func testAllowedDiagnosticNoiseCannotChangeValidatedMotionFeatures() {
        let window = makeWindow(duration: 30 * 60)
        var samples = stride(from: 0, through: 30 * 60, by: 6).enumerated().map { index, offset in
            sample(offset: TimeInterval(offset), sequence: index)
        }
        // Less than the 5% fail-closed tolerance, but deliberately extreme.
        // These rows remain countable provenance and never enter vector deltas.
        for index in 0..<10 {
            samples.append(sample(offset: TimeInterval(index * 60),
                                  sequence: 10_000 + index,
                                  x: index.isMultiple(of: 2) ? 0.8 : -0.8,
                                  z: 0.6,
                                  validated: false))
        }

        let evidence = AtriaRecoveredMotionProjection.project(samples: samples, window: window)

        XCTAssertTrue(evidence.measurementValidated)
        XCTAssertTrue(evidence.lowMotionQualified)
        XCTAssertEqual(evidence.rejectedRows, 10)
        XCTAssertEqual(evidence.stillnessRatio, 1)
        XCTAssertEqual(evidence.movementIntensity, 0)
    }

    func testValidatedFlagDoesNotOverrideImplausibleOrNonFiniteGravity() {
        let window = makeWindow(duration: 30 * 60)
        var samples = stride(from: 0, through: 30 * 60, by: 4).enumerated().map { index, offset in
            sample(offset: TimeInterval(offset), sequence: index)
        }
        for index in 0..<30 {
            samples[index] = sample(offset: TimeInterval(index * 4), sequence: index, z: 4)
        }
        samples[30] = sample(offset: 120, sequence: 30, x: .nan)

        let evidence = AtriaRecoveredMotionProjection.project(samples: samples, window: window)

        XCTAssertFalse(evidence.measurementValidated)
        XCTAssertEqual(evidence.rejectedRows, 31)
        XCTAssertEqual(evidence.reason, "unvalidated_row_fraction")
    }

    func testUnprovenWallClockRowsCannotProveWindowMotion() {
        let window = makeWindow(duration: 30 * 60)
        let samples = stride(from: 0, through: 30 * 60, by: 6).enumerated().map { index, offset in
            sample(offset: TimeInterval(offset),
                   sequence: index,
                   timestampValidated: false)
        }

        let evidence = AtriaRecoveredMotionProjection.project(samples: samples, window: window)

        XCTAssertFalse(evidence.measurementValidated)
        XCTAssertFalse(evidence.lowMotionQualified)
        XCTAssertEqual(evidence.validatedRows, 0)
        XCTAssertNil(evidence.savedSessionFields.imuStillnessRatio)
    }

    func testMiddleSampleIslandCannotClaimWholeWindow() {
        let window = makeWindow(duration: 2 * 60 * 60)
        let samples = stride(from: 45 * 60, through: 75 * 60, by: 6).enumerated().map { index, offset in
            sample(offset: TimeInterval(offset), sequence: index)
        }

        let evidence = AtriaRecoveredMotionProjection.project(samples: samples, window: window)

        XCTAssertFalse(evidence.measurementValidated)
        XCTAssertEqual(evidence.reason, "window_or_internal_gap")
        XCTAssertEqual(evidence.maximumGapSeconds, 45 * 60)
    }

    func testReconnectGapIsNotUsedAsMovementDelta() {
        var config = AtriaRecoveredMotionProjection.Configuration.production
        config.minimumValidatedRows = 4
        config.minimumCoverageSeconds = 0
        config.maximumGapSeconds = 20
        let window = makeWindow(duration: 60)
        let samples = [
            sample(offset: 0, sequence: 0, x: 0, z: 1),
            sample(offset: 10, sequence: 1, x: 0, z: 1),
            sample(offset: 50, sequence: 2, x: 0.8, z: 0.6),
            sample(offset: 60, sequence: 3, x: 0.8, z: 0.6)
        ]

        let evidence = AtriaRecoveredMotionProjection.project(samples: samples,
                                                               window: window,
                                                               configuration: config)

        XCTAssertFalse(evidence.measurementValidated, "the 40-second hole must fail continuity")
        XCTAssertEqual(evidence.maximumGapSeconds, 40)
        XCTAssertEqual(evidence.movementIntensity, 0,
                       "the orientation jump across the reconnect hole is not a motion sample")
    }

    func testProjectionIsStrictlyWindowBoundedAndRejectsOversizedWindow() {
        let window = makeWindow(duration: 30 * 60)
        var samples = stride(from: 0, through: 30 * 60, by: 6).enumerated().map { index, offset in
            sample(offset: TimeInterval(offset), sequence: index)
        }
        samples.append(sample(offset: -1, sequence: 10_000, x: 0.8, z: 0.6))
        samples.append(sample(offset: 30 * 60 + 1, sequence: 10_001, x: 0.8, z: 0.6))

        let evidence = AtriaRecoveredMotionProjection.project(samples: samples, window: window)
        XCTAssertEqual(evidence.rows, 301)
        XCTAssertTrue(evidence.lowMotionQualified)

        let oversized = makeWindow(duration: 12 * 60 * 60 + 1)
        let rejected = AtriaRecoveredMotionProjection.project(samples: samples, window: oversized)
        XCTAssertFalse(rejected.measurementValidated)
        XCTAssertEqual(rejected.reason, "window_exceeds_bound")
    }

    func testEpochBoundaryFrameIsAssignedExactlyOnce() {
        let samples = stride(from: 0, through: 60, by: 10).enumerated().map { index, offset in
            sample(offset: TimeInterval(offset), sequence: index)
        }

        let epochs = AtriaRecoveredMotionProjection.epochFeatures(
            samples: samples,
            start: origin,
            end: origin.addingTimeInterval(60),
            epochDuration: 30
        )

        XCTAssertEqual(epochs.map(\.rows), [3, 4])
        XCTAssertEqual(epochs.reduce(0) { $0 + $1.rows }, samples.count,
                       "the frame at 30s belongs only to the second half-open epoch")
    }

    func testMotionProjectionAndEpochAttachmentAbortAtBoundedCheckpoints() {
        var config = AtriaRecoveredMotionProjection.Configuration.production
        config.maximumWindowSeconds = 24 * 60 * 60
        let window = makeWindow(duration: 20_000)
        let samples = (0..<20_000).map {
            sample(offset: TimeInterval($0), sequence: $0)
        }
        var projectionChecks = 0
        XCTAssertNil(AtriaRecoveredMotionProjection.projectCancellable(
            samples: samples,
            window: window,
            configuration: config,
            shouldContinue: {
                projectionChecks += 1
                return projectionChecks < 6
            }
        ))
        XCTAssertLessThanOrEqual(projectionChecks, 6)

        var epochChecks = 0
        XCTAssertNil(AtriaRecoveredMotionProjection.epochFeaturesCancellable(
            samples: samples,
            windows: [window],
            shouldContinue: {
                epochChecks += 1
                return epochChecks < 6
            }
        ))
        XCTAssertLessThanOrEqual(epochChecks, 6)
    }

    func testMotionOrderingRevokesDuringCancellableMergeSort() {
        var config = AtriaRecoveredMotionProjection.Configuration.production
        config.maximumWindowSeconds = 24 * 60 * 60
        let window = makeWindow(duration: 20_000)
        let samples = (0..<20_000).reversed().map {
            sample(offset: TimeInterval($0), sequence: $0)
        }
        var checks = 0
        XCTAssertNil(AtriaRecoveredMotionProjection.projectCancellable(
            samples: samples,
            window: window,
            configuration: config,
            shouldContinue: {
                checks += 1
                return checks < 90
            }
        ))
        XCTAssertEqual(checks, 90)
    }

    private func makeWindow(duration: TimeInterval) -> AtriaRecoveredMotionProjection.Window {
        .init(id: "window", start: origin, end: origin.addingTimeInterval(duration))
    }

    private func sample(offset: TimeInterval,
                        sequence: Int,
                        x: Double = 0,
                        y: Double = 0,
                        z: Double = 1,
                        timestampValidated: Bool = true,
                        validated: Bool = true) -> AtriaRecoveredMotionProjection.Sample {
        .init(timestamp: origin.addingTimeInterval(offset),
              sequence: sequence,
              x: x,
              y: y,
              z: z,
              timestampValidated: timestampValidated,
              gravityValidated: validated)
    }
}
