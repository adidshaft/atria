import XCTest
@testable import Atria

final class AtriaWhoop4MotionTickStepModelTests: XCTestCase {
    func testGravityEstimatorPublishesPhysicallyCalibratedV13Only() {
        XCTAssertEqual(
            AtriaWhoop4GravityCadenceStepModel.algorithmVersion,
            "whoop4-impact-gait-ensemble-v13"
        )
    }

    func testFitRequiresExactWalkAndRestEvidence() {
        XCTAssertNil(AtriaWhoop4MotionTickStepModel.fit(training: [
            point("walk", .walk, ticks: 110, steps: 100, exact: false),
            point("rest", .rest, ticks: 0, steps: 0),
        ]))
        XCTAssertNil(AtriaWhoop4MotionTickStepModel.fit(training: [
            point("walk", .walk, ticks: 110, steps: 100),
        ]))
        XCTAssertNil(AtriaWhoop4MotionTickStepModel.fit(training: [
            point("walk", .walk, ticks: 110, steps: 100),
            point("rest", .rest, ticks: 1, steps: 0),
        ]))
    }

    func testUnvalidatedFitCanNeverPublishSteps() throws {
        let model = try XCTUnwrap(AtriaWhoop4MotionTickStepModel.fit(training: [
            point("train-walk", .walk, ticks: 110, steps: 100),
            point("train-rest", .rest, ticks: 0, steps: 0),
        ]))
        XCTAssertEqual(model.ticksPerStep, 1.1, accuracy: 0.000_001)
        XCTAssertNil(AtriaWhoop4MotionTickStepModel.publishedSteps(
            motionTicks: 1_100,
            validation: nil
        ))
    }

    func testIndependentHeldOutWalkEnablesPublicationWithinFivePercent() throws {
        let model = try XCTUnwrap(AtriaWhoop4MotionTickStepModel.fit(training: [
            point("train-walk", .walk, ticks: 110, steps: 100),
            point("train-rest", .rest, ticks: 0, steps: 0),
        ]))
        let validation = try XCTUnwrap(AtriaWhoop4MotionTickStepModel.validate(
            model: model,
            heldOut: [
                point("holdout-walk", .walk, ticks: 222, steps: 200),
                point("holdout-rest", .rest, ticks: 0, steps: 0),
            ]
        ))
        XCTAssertTrue(validation.passed)
        XCTAssertEqual(
            AtriaWhoop4MotionTickStepModel.publishedSteps(
                motionTicks: 1_100,
                validation: validation
            ),
            1_000
        )
    }

    func testFailedOrReusedHoldoutNeverPublishes() throws {
        let training = [
            point("train-walk", .walk, ticks: 110, steps: 100),
            point("train-rest", .rest, ticks: 0, steps: 0),
        ]
        let model = try XCTUnwrap(
            AtriaWhoop4MotionTickStepModel.fit(training: training)
        )
        XCTAssertNil(AtriaWhoop4MotionTickStepModel.validate(
            model: model,
            heldOut: [
                point("train-walk", .walk, ticks: 110, steps: 100),
                point("other-rest", .rest, ticks: 0, steps: 0),
            ]
        ))

        let failed = try XCTUnwrap(AtriaWhoop4MotionTickStepModel.validate(
            model: model,
            heldOut: [
                point("holdout-walk", .walk, ticks: 150, steps: 100),
                point("holdout-rest", .rest, ticks: 0, steps: 0),
            ]
        ))
        XCTAssertFalse(failed.passed)
        XCTAssertNil(AtriaWhoop4MotionTickStepModel.publishedSteps(
            motionTicks: 1_100,
            validation: failed
        ))
    }

    func testPhysicalWhoop4ReceiptPublishesHeldOutWalkAndRejectsRest() {
        let receipt = AtriaWhoop4MotionTickStepModel.physicallyValidatedWhoop4V24
        XCTAssertTrue(receipt.passed)
        XCTAssertEqual(receipt.maximumRelativeError, 0)
        XCTAssertEqual(receipt.restFalseSteps, 0)
        XCTAssertEqual(
            AtriaWhoop4MotionTickStepModel.publishedSteps(
                motionTicks: 160,
                validation: receipt
            ),
            136
        )
        XCTAssertEqual(
            AtriaWhoop4MotionTickStepModel.publishedSteps(
                motionTicks: 0,
                validation: receipt
            ),
            0
        )
    }

    func testGravityAliasCadenceCountsSustainedStrapWalkWithoutPhone() throws {
        let duration = 92.3
        let sampleCount = 97
        let sampleRate = Double(sampleCount - 1) / duration
        let aliasFrequency = 0.42
        let points = cadencePoints(
            count: sampleCount,
            duration: duration,
            aliasFrequency: aliasFrequency,
            moving: true
        )
        let estimate = try XCTUnwrap(
            AtriaWhoop4GravityCadenceStepModel.estimateWindow(points: points)
        )
        let cadenceOnlyExpected = Int(
            ((sampleRate + aliasFrequency) * duration).rounded()
        )
        XCTAssertEqual(estimate.cadenceOnlySteps, cadenceOnlyExpected)
        XCTAssertEqual(estimate.cadenceOnlySteps, 135)
        XCTAssertEqual(estimate.motionVolumeSteps, 128)
        XCTAssertEqual(estimate.steps, 133)
        XCTAssertGreaterThanOrEqual(estimate.peakDominance, 1.25)
        XCTAssertGreaterThan(estimate.motionTicks, 0)
        XCTAssertEqual(estimate.unresolvedMotionSeconds, 0)
    }

    func testGravityAliasCadenceReturnsZeroForStrapProvenRest() throws {
        let points = cadencePoints(
            count: 70,
            duration: 66,
            aliasFrequency: 0.42,
            moving: false
        )
        let estimate = try XCTUnwrap(
            AtriaWhoop4GravityCadenceStepModel.estimateWindow(points: points)
        )
        XCTAssertEqual(estimate.steps, 0)
        XCTAssertEqual(estimate.motionTicks, 0)
        XCTAssertEqual(estimate.unresolvedMotionSeconds, 0)
    }

    func testGravityAliasCadenceRejectsRhythmicArmMotionWithoutGaitTexture() {
        let count = 126
        let duration = 120.16
        let sampleRate = Double(count - 1) / duration
        let points = (0..<count).map { index in
            let timestamp = Double(index) / sampleRate
            let phase = 2 * Double.pi * 0.43 * timestamp
            return AtriaWhoop4GravityCadenceStepModel.Point(
                timestamp: timestamp,
                flash: UInt32(index),
                tick: Int((Double(index) * 0.8).rounded()),
                gravityX: 0.064 * sin(phase),
                gravityY: 0.064 * cos(phase),
                gravityZ: 1,
                unknownMotionScalar32: 0.04,
                identity: "arm-\(index)"
            )
        }
        XCTAssertNil(
            AtriaWhoop4GravityCadenceStepModel.estimateWindow(points: points)
        )
    }

    func testAlignedWindowUsesClockSupportWithoutInspectingMotion() throws {
        let duration = 92.3
        let strong = cadencePoints(
            count: 97,
            duration: duration,
            aliasFrequency: 0.42,
            moving: true
        ).enumerated().map { index, point in
            AtriaWhoop4GravityCadenceStepModel.Point(
                timestamp: point.timestamp + 100,
                flash: point.flash,
                tick: index * 2,
                gravityX: point.gravityX,
                gravityY: point.gravityY,
                gravityZ: point.gravityZ,
                unknownMotionScalar32: point.unknownMotionScalar32,
                identity: "strong-\(point.identity)"
            )
        }
        let weaker = cadencePoints(
            count: 97,
            duration: duration,
            aliasFrequency: 0.42,
            moving: true
        ).enumerated().map { index, point in
            AtriaWhoop4GravityCadenceStepModel.Point(
                timestamp: point.timestamp + 300,
                flash: point.flash + 1_000,
                tick: index,
                gravityX: point.gravityX,
                gravityY: point.gravityY,
                gravityZ: point.gravityZ,
                unknownMotionScalar32: point.unknownMotionScalar32,
                identity: "weak-\(point.identity)"
            )
        }
        let selected = try XCTUnwrap(
            AtriaWhoop4GravityCadenceStepModel.estimateAlignedWindow(
                points: strong + weaker,
                requestedStart: 300,
                requestedEnd: 300 + duration,
                clockOffsetByIdentity: Dictionary(
                    uniqueKeysWithValues:
                        weaker.enumerated().map {
                            ($0.element.identity, $0.offset < 20 ? 0 : -500)
                        }
                        + strong.map { ($0.identity, 200) }
                )
            )
        )
        XCTAssertEqual(selected.clockOffsetSeconds, 200)
        XCTAssertEqual(selected.estimate.motionTicks, 192)
        XCTAssertEqual(selected.estimate.steps, 133)
        XCTAssertEqual(selected.coverageFraction, 1, accuracy: 0.000_001)
    }

    func testAlignedWindowFailsClosedWhenClockSupportAndBoundariesTie() {
        let duration = 92.3
        let first = cadencePoints(
            count: 97,
            duration: duration,
            aliasFrequency: 0.42,
            moving: true
        )
        let second = first.map {
            AtriaWhoop4GravityCadenceStepModel.Point(
                timestamp: $0.timestamp + 300,
                flash: $0.flash + 1_000,
                tick: $0.tick,
                gravityX: $0.gravityX,
                gravityY: $0.gravityY,
                gravityZ: $0.gravityZ,
                unknownMotionScalar32: $0.unknownMotionScalar32,
                identity: "second-\($0.identity)"
            )
        }
        XCTAssertNil(
            AtriaWhoop4GravityCadenceStepModel.estimateAlignedWindow(
                points: first + second,
                requestedStart: 300,
                requestedEnd: 300 + duration,
                clockOffsetByIdentity: Dictionary(
                    uniqueKeysWithValues:
                        first.map { ($0.identity, 300) }
                        + second.map { ($0.identity, 0) }
                )
            )
        )
    }

    func testGravityAliasCadenceRejectsShortOrSparseMotion() {
        XCTAssertNil(AtriaWhoop4GravityCadenceStepModel.estimateWindow(
            points: cadencePoints(
                count: 20,
                duration: 18,
                aliasFrequency: 0.42,
                moving: true
            )
        ))
        XCTAssertNil(AtriaWhoop4GravityCadenceStepModel.estimateWindow(
            points: cadencePoints(
                count: 35,
                duration: 60,
                aliasFrequency: 0.42,
                moving: true
            )
        ))
    }

    func testGravityAliasCadenceKeepsDominantWalkAfterMinorSetupMotion() throws {
        let setup = cadencePoints(
            count: 4,
            duration: 3,
            aliasFrequency: 0.42,
            moving: true
        )
        let idle = (4..<24).map { index in
            AtriaWhoop4GravityCadenceStepModel.Point(
                timestamp: Double(index),
                flash: UInt32(index),
                tick: 6,
                gravityX: 0,
                gravityY: 0,
                gravityZ: 1,
                unknownMotionScalar32: 0.02,
                identity: "idle-\(index)"
            )
        }
        let walk = cadencePoints(
            count: 82,
            duration: 77.9,
            aliasFrequency: 0.42,
            moving: true
        ).map {
            AtriaWhoop4GravityCadenceStepModel.Point(
                timestamp: $0.timestamp + 24,
                flash: $0.flash + 24,
                tick: $0.tick + 6,
                gravityX: $0.gravityX,
                gravityY: $0.gravityY,
                gravityZ: $0.gravityZ,
                unknownMotionScalar32: $0.unknownMotionScalar32,
                identity: "walk-\($0.identity)"
            )
        }

        let estimate = try XCTUnwrap(
            AtriaWhoop4GravityCadenceStepModel.estimateWindow(
                points: setup + idle + walk
            )
        )

        XCTAssertGreaterThan(estimate.steps, 0)
        XCTAssertGreaterThan(estimate.durationSeconds, 77)
        XCTAssertLessThan(estimate.durationSeconds, 90)
        XCTAssertEqual(estimate.motionTicks, 162)
    }

    func testGravityAliasCadenceRejectsBalancedSeparatedMotionBursts() {
        let first = cadencePoints(
            count: 38,
            duration: 36,
            aliasFrequency: 0.42,
            moving: true
        )
        let idle = (38..<59).map { index in
            AtriaWhoop4GravityCadenceStepModel.Point(
                timestamp: Double(index - 1),
                flash: UInt32(index),
                tick: 74,
                gravityX: 0,
                gravityY: 0,
                gravityZ: 1,
                unknownMotionScalar32: 0.02,
                identity: "idle-\(index)"
            )
        }
        let second = cadencePoints(
            count: 38,
            duration: 36,
            aliasFrequency: 0.42,
            moving: true
        ).map {
            AtriaWhoop4GravityCadenceStepModel.Point(
                timestamp: $0.timestamp + 58,
                flash: $0.flash + 59,
                tick: $0.tick + 74,
                gravityX: $0.gravityX,
                gravityY: $0.gravityY,
                gravityZ: $0.gravityZ,
                unknownMotionScalar32: $0.unknownMotionScalar32,
                identity: "second-\($0.identity)"
            )
        }

        XCTAssertNil(
            AtriaWhoop4GravityCadenceStepModel.estimateWindow(
                points: first + idle + second
            )
        )
    }

    func testFirmwareResumeBatchBridgesObservedElevenSecondPauseOnly() {
        let base = cadencePoints(
            count: 97,
            duration: 92.3,
            aliasFrequency: 0.42,
            moving: true
        )
        var tick = 0
        let resumed = base.enumerated().map { index, point in
            if index > 0 {
                if index < 36 || index > 46 {
                    tick += 2
                } else if index == 46 {
                    tick += 12
                }
            }
            return pointWithTick(point, tick: tick, suffix: "resume")
        }
        XCTAssertNotNil(
            AtriaWhoop4GravityCadenceStepModel.estimateWindow(points: resumed)
        )

        tick = 0
        let ordinaryAfterPause = base.enumerated().map { index, point in
            if index > 0, index < 36 || index >= 46 {
                tick += 2
            }
            return pointWithTick(point, tick: tick, suffix: "ordinary")
        }
        XCTAssertNil(
            AtriaWhoop4GravityCadenceStepModel.estimateWindow(
                points: ordinaryAfterPause
            )
        )
    }

    func testFirmwareIncrementTextureRejectsArmLikeCounterMean() {
        let base = cadencePoints(
            count: 97,
            duration: 92.3,
            aliasFrequency: 0.42,
            moving: true
        )
        var tick = 0
        let armLike = base.enumerated().map { index, point in
            if index > 0 {
                tick += index.isMultiple(of: 2) ? 1 : 2
            }
            return pointWithTick(point, tick: tick, suffix: "arm-like")
        }
        XCTAssertNil(
            AtriaWhoop4GravityCadenceStepModel.estimateWindow(points: armLike)
        )
    }

    func testHighImpactGaitUsesLowerAliasWithoutRewardingAmplitude() throws {
        let points = cadencePoints(
            count: 98,
            duration: 93.25,
            aliasFrequency: 0.16,
            moving: true
        ).map {
            AtriaWhoop4GravityCadenceStepModel.Point(
                timestamp: $0.timestamp,
                flash: $0.flash,
                tick: $0.tick,
                gravityX: $0.gravityX * 1.5,
                gravityY: $0.gravityY * 1.5,
                gravityZ: 1 + ($0.gravityZ - 1) * 1.5,
                unknownMotionScalar32: 0.18,
                identity: $0.identity
            )
        }
        let estimate = try XCTUnwrap(
            AtriaWhoop4GravityCadenceStepModel.estimateWindow(points: points)
        )

        XCTAssertEqual(estimate.steps, estimate.cadenceOnlySteps)
        XCTAssertNotEqual(estimate.steps, estimate.motionVolumeSteps)
        XCTAssertGreaterThanOrEqual(estimate.aliasFrequencyHz, 0.08)
        XCTAssertLessThanOrEqual(estimate.aliasFrequencyHz, 0.20)
    }

    func testDominantLowAliasUsesCadenceAndCounterWithoutAmplitude() throws {
        XCTAssertTrue(
            AtriaWhoop4GravityCadenceStepModel.shouldUseLowAlias(
                lowPower: 21.384,
                ordinaryPower: 14.090
            )
        )
        XCTAssertFalse(
            AtriaWhoop4GravityCadenceStepModel.shouldUseLowAlias(
                lowPower: 10.8,
                ordinaryPower: 10
            )
        )
        XCTAssertEqual(
            AtriaWhoop4GravityCadenceStepModel.spectralLowAliasSteps(
                cadenceSteps: 108,
                motionTicks: 109
            ),
            103
        )
        XCTAssertEqual(
            AtriaWhoop4GravityCadenceStepModel.spectralLowAliasSteps(
                cadenceSteps: 110,
                motionTicks: 155
            ),
            132
        )
        XCTAssertEqual(
            AtriaWhoop4GravityCadenceStepModel.spectralLowAliasSteps(
                cadenceSteps: 110,
                motionTicks: 146
            ),
            115
        )
        XCTAssertTrue(
            AtriaWhoop4GravityCadenceStepModel
                .shouldUseLowAliasForCounterConsistency(
                    ordinaryCadenceSteps: 129,
                    motionVolumeSteps: 117,
                    motionTicks: 121
                )
        )
        XCTAssertFalse(
            AtriaWhoop4GravityCadenceStepModel
                .shouldUseLowAliasForCounterConsistency(
                    ordinaryCadenceSteps: 139,
                    motionVolumeSteps: 104,
                    motionTicks: 132
                )
        )
        XCTAssertTrue(
            AtriaWhoop4GravityCadenceStepModel
                .shouldUseLowAliasForHighRateSubharmonic(
                    lowPower: 6.88,
                    ordinaryPower: 10,
                    gaitTickRate: 1.998
                )
        )
        XCTAssertFalse(
            AtriaWhoop4GravityCadenceStepModel
                .shouldUseLowAliasForHighRateSubharmonic(
                    lowPower: 9.83,
                    ordinaryPower: 10,
                    gaitTickRate: 1.853
                )
        )
        XCTAssertFalse(
            AtriaWhoop4GravityCadenceStepModel
                .shouldUseLowAliasForHighRateSubharmonic(
                    lowPower: 0.46,
                    ordinaryPower: 10,
                    gaitTickRate: 2.08
                )
        )
        XCTAssertTrue(
            AtriaWhoop4GravityCadenceStepModel.shouldUseLowAliasForSoftGait(
                lowAliasPowerRatio: 1.0485,
                gaitTickRate: 2.0535,
                gravityDeltaMagnitudeMAD: 0.0243,
                ordinaryBandPowerShare: 0.3469,
                meanScalar: 0.0905
            ),
            "the physically recovered 110-step slow walk selects its 113-step lower cadence"
        )
        XCTAssertFalse(
            AtriaWhoop4GravityCadenceStepModel.shouldUseLowAliasForSoftGait(
                lowAliasPowerRatio: 1.0809,
                gaitTickRate: 1.9467,
                gravityDeltaMagnitudeMAD: 0.0379,
                ordinaryBandPowerShare: 0.2303,
                meanScalar: 0.1094
            ),
            "the preserved 150-step ordinary-alias walk must remain on its 148-step estimate"
        )
        XCTAssertFalse(
            AtriaWhoop4GravityCadenceStepModel.shouldUseLowAliasForSoftGait(
                lowAliasPowerRatio: 0.213,
                gaitTickRate: 1.711,
                gravityDeltaMagnitudeMAD: 0.104,
                ordinaryBandPowerShare: 0.40,
                meanScalar: 0.09
            ),
            "an arm-only control cannot enter the soft-gait alias regime"
        )
    }

    func testDailyEstimateKeepsQualifiedWalkAndMarksShortMotionUnresolved() throws {
        let short = cadencePoints(
            count: 6,
            duration: 5,
            aliasFrequency: 0.42,
            moving: true
        )
        let sustained = cadencePoints(
            count: 97,
            duration: 92.3,
            aliasFrequency: 0.42,
            moving: true
        ).map {
            AtriaWhoop4GravityCadenceStepModel.Point(
                timestamp: $0.timestamp + 30,
                flash: $0.flash + 100,
                tick: $0.tick + 20,
                gravityX: $0.gravityX,
                gravityY: $0.gravityY,
                gravityZ: $0.gravityZ,
                unknownMotionScalar32: $0.unknownMotionScalar32,
                identity: "sustained-\($0.identity)"
            )
        }
        let estimate = try XCTUnwrap(
            AtriaWhoop4GravityCadenceStepModel.estimateCoveredActivity(
                points: short + sustained
            )
        )
        XCTAssertEqual(estimate.steps, 133)
        XCTAssertEqual(estimate.cadenceOnlySteps, 135)
        XCTAssertEqual(estimate.motionVolumeSteps, 128)
        XCTAssertEqual(estimate.unresolvedMotionSeconds, 30)
    }

    private func cadencePoints(
        count: Int,
        duration: TimeInterval,
        aliasFrequency: Double,
        moving: Bool
    ) -> [AtriaWhoop4GravityCadenceStepModel.Point] {
        let sampleRate = Double(count - 1) / duration
        return (0..<count).map { index in
            let timestamp = Double(index) / sampleRate
            let phase = 2 * Double.pi * aliasFrequency * timestamp
            let textureScale = 0.55
            return .init(
                timestamp: timestamp,
                flash: UInt32(index),
                tick: moving ? index * 2 : 0,
                gravityX: moving
                    ? textureScale * (
                        0.073 * sin(phase)
                            + 0.16 * pseudoNoise(index, channel: 1)
                    ) : 0,
                gravityY: moving
                    ? textureScale * (
                        0.073 * cos(phase)
                            + 0.16 * pseudoNoise(index, channel: 2)
                    ) : 0,
                gravityZ: moving
                    ? 1 + textureScale * 0.16
                        * pseudoNoise(index, channel: 3)
                    : 1,
                unknownMotionScalar32: moving ? 0.12 : 0.02,
                identity: "point-\(index)"
            )
        }
    }

    private func pseudoNoise(_ index: Int, channel: Int) -> Double {
        let raw = sin(
            Double(index + 1)
                * (12.9898 + Double(channel) * 78.233)
        ) * 43_758.5453
        let fraction = raw - floor(raw)
        return fraction * 2 - 1
    }

    private func pointWithTick(
        _ point: AtriaWhoop4GravityCadenceStepModel.Point,
        tick: Int,
        suffix: String
    ) -> AtriaWhoop4GravityCadenceStepModel.Point {
        .init(
            timestamp: point.timestamp,
            flash: point.flash,
            tick: tick,
            gravityX: point.gravityX,
            gravityY: point.gravityY,
            gravityZ: point.gravityZ,
            unknownMotionScalar32: point.unknownMotionScalar32,
            identity: "\(suffix)-\(point.identity)"
        )
    }

    private func point(
        _ id: String,
        _ kind: AtriaWhoop4MotionTickStepModel.Kind,
        ticks: Int,
        steps: Int,
        exact: Bool = true
    ) -> AtriaWhoop4MotionTickStepModel.Point {
        .init(
            id: id,
            kind: kind,
            durationSeconds: 90,
            motionTicks: ticks,
            countedSteps: steps,
            exactBoundaries: exact
        )
    }
}
