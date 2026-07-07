import XCTest
@testable import Atria

/// Workout onset detection (2026-07-07, early-boundary fix). At rest 66 /
/// max 190 the elevated threshold is 128 bpm, so getting-ready HR (~105) is
/// sub-threshold and must be trimmed; the real workout onset is the first
/// sustained >=128 run. These lock the honesty guards (never fabricate a
/// boundary; fail closed to nil).
final class AtriaWorkoutOnsetTests: XCTestCase {
    private func samples(_ segments: [(seconds: Int, bpm: Int)], start: Date) -> [(t: Date, bpm: Int)] {
        var out: [(t: Date, bpm: Int)] = []
        var offset = 0
        for segment in segments {
            for _ in 0..<segment.seconds {
                out.append((start.addingTimeInterval(TimeInterval(offset)), segment.bpm))
                offset += 1
            }
        }
        return out
    }

    func testTrimsSubThresholdLeadInToFirstSustainedRun() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        // 26 min getting-ready (~105 bpm) + 45 min workout (~140 bpm).
        let s = samples([(1_560, 105), (2_700, 140)], start: start)
        let onset = AtriaWorkoutOnset.firstSustainedElevatedOnset(samples: s, rest: 66, maxHR: 190)
        XCTAssertNotNil(onset)
        XCTAssertEqual(onset!.timeIntervalSince(start), 1_560, accuracy: 2)
    }

    func testNoElevatedRunReturnsNil() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertNil(AtriaWorkoutOnset.firstSustainedElevatedOnset(
            samples: samples([(3_600, 100)], start: start), rest: 66, maxHR: 190))
    }

    func testBriefSpikeBelowMinimumOnsetReturnsNil() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        // 60s elevated (< 90s minimum) between rest — not a sustained onset.
        XCTAssertNil(AtriaWorkoutOnset.firstSustainedElevatedOnset(
            samples: samples([(600, 100), (60, 140), (600, 100)], start: start), rest: 66, maxHR: 190))
    }

    func testHardGapResetsTheBout() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var s = samples([(50, 140)], start: start)
        s += samples([(50, 140)], start: start.addingTimeInterval(50 + 30)) // 30s gap > 15s limit
        XCTAssertNil(AtriaWorkoutOnset.firstSustainedElevatedOnset(samples: s, rest: 66, maxHR: 190))
    }

    func testMicroGapReconnectBlipDoesNotSeedOnset() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var s = samples([(600, 100)], start: start)
        s.append((start.addingTimeInterval(604), 140)) // 4s gap + 40 bpm jump = unverified blip
        s += samples([(600, 100)], start: start.addingTimeInterval(605))
        XCTAssertNil(AtriaWorkoutOnset.firstSustainedElevatedOnset(samples: s, rest: 66, maxHR: 190))
    }
}
