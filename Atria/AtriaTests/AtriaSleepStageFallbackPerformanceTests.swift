import XCTest
@testable import Atria

final class AtriaSleepStageFallbackPerformanceTests: XCTestCase {
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

    func testMotionGapLongerThanReceiptLimitFailsClosed() {
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

        let stages = AtriaSleepWakeResearch.stageSegments(
            samples: samples,
            start: start,
            end: end,
            restingHR: 60,
            isNap: false,
            motionValidated: true,
            motionEpochs: epochs
        )

        XCTAssertTrue(stages.isEmpty)
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
