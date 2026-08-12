import XCTest
@testable import Atria

final class AtriaSleepStageFallbackPerformanceTests: XCTestCase {
    private final class StepClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UInt64 = 0

        func next() -> UInt64 {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }
    }

    func testDenseFallbackPreservesConstantLowHRStageAndFullCoverage() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let end = start.addingTimeInterval(8 * 60 * 60)
        let samples = stride(from: 0, through: 8 * 60 * 60, by: 5).map {
            AtriaSleepWakeResearch.HeartSample(t: start.addingTimeInterval(TimeInterval($0)),
                                               bpm: 62)
        }

        let result = AtriaSleepWakeResearch.fallbackStageDiagnostics(samples: samples,
                                                                     start: start,
                                                                     end: end,
                                                                     restingHR: 60,
                                                                     isNap: false,
                                                                     motionValidated: true,
                                                                     motionEpochs: motionEpochs(start: start,
                                                                                                end: end))

        XCTAssertEqual(result.segments.count, 1)
        XCTAssertEqual(result.segments.first?.start, start)
        XCTAssertEqual(result.segments.first?.end, end)
        XCTAssertEqual(result.segments.first?.stage, .deep)
    }

    func testSparseFirstHourNeverExpandsToFullNightStages() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let end = start.addingTimeInterval(8 * 60 * 60)
        // Twelve points satisfy the legacy count gate but are intentionally
        // confined to the first hour. They cannot support the other seven.
        let samples = stride(from: 0, through: 55 * 60, by: 5 * 60).map {
            AtriaSleepWakeResearch.HeartSample(t: start.addingTimeInterval(TimeInterval($0)),
                                               bpm: 62)
        }

        let result = AtriaSleepWakeResearch.fallbackStageDiagnostics(samples: samples,
                                                                     start: start,
                                                                     end: end,
                                                                     restingHR: 60,
                                                                     isNap: false,
                                                                     motionValidated: true,
                                                                     motionEpochs: motionEpochs(start: start,
                                                                                                end: end))

        XCTAssertEqual(samples.count, 12)
        XCTAssertTrue(result.segments.isEmpty)
    }

    func testFallbackSampleWorkScalesWithWindowLengthRatherThanEpochsTimesNightSamples() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func diagnostics(hours: Int) -> AtriaSleepWakeResearch.FallbackStageDiagnostics {
            let seconds = hours * 60 * 60
            let samples = (0...seconds).map {
                AtriaSleepWakeResearch.HeartSample(t: start.addingTimeInterval(TimeInterval($0)),
                                                   bpm: 61 + (($0 / 60).isMultiple(of: 7) ? 1 : 0))
            }
            return AtriaSleepWakeResearch.fallbackStageDiagnostics(
                samples: samples,
                start: start,
                end: start.addingTimeInterval(TimeInterval(seconds)),
                restingHR: 60,
                isNap: false,
                motionValidated: true,
                motionEpochs: motionEpochs(
                    start: start,
                    end: start.addingTimeInterval(TimeInterval(seconds))
                ))
        }

        let fourHours = diagnostics(hours: 4)
        let eightHours = diagnostics(hours: 8)
        let repeatedFourHours = diagnostics(hours: 4)

        XCTAssertFalse(fourHours.segments.isEmpty)
        XCTAssertFalse(eightHours.segments.isEmpty)
        let fourHourInputRows = 4 * 60 * 60 + 1 + (4 * 60 * 60 / 30)
        XCTAssertGreaterThan(fourHours.sampleVisits, fourHourInputRows * 10,
                             "diagnostics must count epoch-local smoothing/motion inspections, not just inputs")
        XCTAssertEqual(repeatedFourHours.sampleVisits, fourHours.sampleVisits,
                       "the complexity receipt must be deterministic")
        // Doubling both epochs and samples made the old filter-per-epoch path
        // roughly 4x. The real inner-visit receipt, including motion alignment
        // and HR smoothing ranges, must stay close to 2x.
        XCTAssertLessThan(Double(eightHours.sampleVisits),
                          Double(fourHours.sampleVisits) * 2.2)
    }

    func testMotionGapLongerThanReceiptLimitDemotesToEstimateProvenance() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let end = start.addingTimeInterval(60 * 60)
        let samples = stride(from: 0, through: 60 * 60, by: 5).map {
            AtriaSleepWakeResearch.HeartSample(
                t: start.addingTimeInterval(TimeInterval($0)),
                bpm: 62
            )
        }
        let epochs = motionEpochs(start: start, end: end).filter {
            $0.start < start.addingTimeInterval(20 * 60)
                || $0.start >= start.addingTimeInterval(22 * 60)
        }

        // Hot callers (no opt-in) keep the fail-closed, near-zero-cost path.
        let withheld = AtriaSleepWakeResearch.stageSegments(
            samples: samples,
            start: start,
            end: end,
            restingHR: 60,
            isNap: false,
            motionValidated: true,
            motionEpochs: epochs
        )
        XCTAssertTrue(withheld.isEmpty,
                      "without the opt-in a gapped motion timeline fails closed")

        let stages = AtriaSleepWakeResearch.stageSegments(
            samples: samples,
            start: start,
            end: end,
            restingHR: 60,
            isNap: false,
            motionValidated: true,
            motionEpochs: epochs,
            allowHROnlyEstimate: true
        )

        // 2026-08-12: a motion timeline with a hole beyond the receipt limit
        // can never claim the motion receipt; on the deliberate lanes dense
        // HR still stages a labeled estimate. The receipt demotion is what
        // this test protects.
        XCTAssertFalse(stages.isEmpty,
                       "dense HR must still stage an estimate timeline")
        XCTAssertTrue(stages.allSatisfy {
            $0.id.hasPrefix(SleepStageSegment.hrEstimateIDPrefix)
        }, "insufficient motion must demote every segment to estimate provenance")
        XCTAssertFalse(stages.contains {
            $0.id.hasPrefix(SleepStageSegment.motionReceiptIDPrefix)
        }, "a gapped motion timeline must never mint the motion receipt")
    }

    func testFourSamplesPerMinuteFailsEvenWhenGapIsAtLimit() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let end = start.addingTimeInterval(60 * 60)
        let samples = stride(from: 0, through: 60 * 60, by: 15).map {
            AtriaSleepWakeResearch.HeartSample(
                t: start.addingTimeInterval(TimeInterval($0)),
                bpm: 62
            )
        }

        let stages = AtriaSleepWakeResearch.stageSegments(
            samples: samples,
            start: start,
            end: end,
            restingHR: 60,
            isNap: false,
            motionValidated: true,
            motionEpochs: motionEpochs(start: start, end: end)
        )

        XCTAssertTrue(stages.isEmpty)
    }

    func testCheckedStagesExactlyMatchLegacyForDenseMainNapAndIrregularEqualTimestamps()
        throws
    {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let duration = 2 * 60 * 60
        let end = start.addingTimeInterval(TimeInterval(duration))
        var samples = stride(from: 0, through: duration, by: 5).map { offset in
            AtriaSleepWakeResearch.HeartSample(
                t: start.addingTimeInterval(
                    Double(offset) + (offset.isMultiple(of: 4) ? 0.25 : 0)
                ),
                bpm: 58 + ((offset / 150) % 12)
            )
        }
        // Stable equal-key ordering is part of checked/legacy parity even when
        // the two values would land on opposite sides of a stage threshold.
        let duplicateTime = start.addingTimeInterval(45 * 60)
        samples.append(.init(t: duplicateTime, bpm: 51))
        samples.append(.init(t: duplicateTime, bpm: 91))
        samples.append(.init(t: start.addingTimeInterval(-30), bpm: 180))
        samples.reverse()

        var motion = motionEpochs(start: start, end: end)
        motion.append(motion[37])
        motion.reverse()
        for isNap in [false, true] {
            let legacy = AtriaSleepWakeResearch.stageSegments(
                samples: samples,
                start: start,
                end: end,
                restingHR: 60,
                isNap: isNap,
                motionValidated: true,
                motionEpochs: motion
            )
            let checked = try AtriaSleepWakeResearch.stageSegments(
                samples: samples,
                start: start,
                end: end,
                restingHR: 60,
                isNap: isNap,
                motionValidated: true,
                motionEpochs: motion,
                cooperativeDeadline: .init(
                    uptimeNanoseconds: .max,
                    monotonicNow: { 0 }
                )
            )

            XCTAssertFalse(legacy.isEmpty)
            XCTAssertEqual(checked, legacy)
        }

        let gappedMotion = motion.filter {
            $0.start < start.addingTimeInterval(60 * 60)
                || $0.start >= start.addingTimeInterval(62 * 60)
        }
        let legacyGap = AtriaSleepWakeResearch.stageSegments(
            samples: samples,
            start: start,
            end: end,
            restingHR: 60,
            isNap: false,
            motionValidated: true,
            motionEpochs: gappedMotion
        )
        let checkedGap = try AtriaSleepWakeResearch.stageSegments(
            samples: samples,
            start: start,
            end: end,
            restingHR: 60,
            isNap: false,
            motionValidated: true,
            motionEpochs: gappedMotion,
            cooperativeDeadline: .init(
                uptimeNanoseconds: .max,
                monotonicNow: { 0 }
            )
        )
        XCTAssertEqual(checkedGap, legacyGap)
        XCTAssertTrue(checkedGap.isEmpty)
    }

    func testCheckedStableSortAbortsMidPass() {
        var values = Array((0..<20_000).reversed())
        let clock = StepClock()
        XCTAssertThrowsError(try AtriaSleepCooperativeAlgorithms.stableSort(
            &values,
            cooperativeDeadline: .init(
                uptimeNanoseconds: 10,
                monotonicNow: { clock.next() }
            ),
            areInIncreasingOrder: <
        )) {
            XCTAssertEqual(
                $0 as? AtriaSleepSettlementAbort,
                .deadlineExceeded
            )
        }
    }

    func testCheckedGaussianSmoothingAbortsInsideDenseWindow() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let samples = (0..<10_000).map {
            AtriaSleepWakeResearch.HeartSample(
                t: start.addingTimeInterval(Double($0)),
                bpm: 60 + ($0 % 5)
            )
        }
        let clock = StepClock()
        XCTAssertThrowsError(try AtriaSleepWakeResearch
            .checkedGaussianSmoothingForTesting(
                samples: samples,
                center: start.addingTimeInterval(5_000),
                sigma: 600,
                cooperativeDeadline: .init(
                    uptimeNanoseconds: 6,
                    monotonicNow: { clock.next() }
                )
            )) {
            XCTAssertEqual(
                $0 as? AtriaSleepSettlementAbort,
                .deadlineExceeded
            )
        }
    }

    private func motionEpochs(start: Date, end: Date) -> [AtriaRecoveredMotionEpoch] {
        let count = Int(ceil(end.timeIntervalSince(start) / 30))
        return (0..<count).map { index in
            let epochStart = start.addingTimeInterval(Double(index) * 30)
            return AtriaRecoveredMotionEpoch(
                start: epochStart,
                end: min(end, epochStart.addingTimeInterval(30)),
                rows: 15,
                validatedRows: 15,
                stillnessRatio: 1,
                movementIntensity: 0,
                p95VectorDelta: 0,
                maximumGapSeconds: 2,
                measurementValidated: true,
                lowMotionQualified: true,
                reason: "stage-test"
            )
        }
    }
}
