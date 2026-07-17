import XCTest
@testable import Atria

final class AtriaSleepStageFallbackPerformanceTests: XCTestCase {
    func testDenseFallbackPreservesConstantLowHRStageAndFullCoverage() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let end = start.addingTimeInterval(8 * 60 * 60)
        let samples = stride(from: 0, through: 8 * 60 * 60, by: 30).map {
            AtriaSleepWakeResearch.HeartSample(t: start.addingTimeInterval(TimeInterval($0)),
                                               bpm: 62)
        }

        let result = AtriaSleepWakeResearch.fallbackStageDiagnostics(samples: samples,
                                                                     start: start,
                                                                     end: end,
                                                                     restingHR: 60,
                                                                     isNap: false,
                                                                     motionValidated: true)

        XCTAssertEqual(result.segments.count, 1)
        XCTAssertEqual(result.segments.first?.start, start)
        XCTAssertEqual(result.segments.first?.end, end)
        XCTAssertEqual(result.segments.first?.stage, .deep)
    }

    func testSparseFallbackStillExpandsToFullWindowWithIdenticalStageSemantics() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let end = start.addingTimeInterval(8 * 60 * 60)
        // Enough evidence for the caller, but intentionally confined to the
        // first hour so coarse coverage must use the full-window fallback.
        let samples = stride(from: 0, through: 55 * 60, by: 5 * 60).map {
            AtriaSleepWakeResearch.HeartSample(t: start.addingTimeInterval(TimeInterval($0)),
                                               bpm: 62)
        }

        let result = AtriaSleepWakeResearch.fallbackStageDiagnostics(samples: samples,
                                                                     start: start,
                                                                     end: end,
                                                                     restingHR: 60,
                                                                     isNap: false,
                                                                     motionValidated: true)

        XCTAssertEqual(samples.count, 12)
        XCTAssertEqual(result.segments.count, 1)
        XCTAssertEqual(result.segments.first?.start, start)
        XCTAssertEqual(result.segments.first?.end, end)
        XCTAssertEqual(result.segments.first?.stage, .deep)
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
                motionValidated: true)
        }

        let fourHours = diagnostics(hours: 4)
        let eightHours = diagnostics(hours: 8)

        XCTAssertFalse(fourHours.segments.isEmpty)
        XCTAssertFalse(eightHours.segments.isEmpty)
        // Doubling both epochs and samples made the old filter-per-epoch path
        // roughly 4x. Range-bounded statistics should stay close to 2x.
        XCTAssertLessThan(Double(eightHours.sampleVisits),
                          Double(fourHours.sampleVisits) * 2.2)
    }
}
