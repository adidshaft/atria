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

    // End-bound counterpart (2026-07-31 physical case): the last sustained
    // elevated bout's end, so a mildly-elevated evening tail can never keep
    // a candidate open until sleep-onset HR decay.
    func testLastSustainedBoutEndIgnoresMildlyElevatedTail() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        // 45 min real effort (~140) then 3 h mild non-exertion (~95 < 128).
        let s = samples([(2_700, 140), (3 * 3_600, 95)], start: start)
        let boutEnd = AtriaWorkoutOnset.lastSustainedElevatedBoutEnd(samples: s, rest: 66, maxHR: 190)
        XCTAssertNotNil(boutEnd)
        XCTAssertEqual(boutEnd!.timeIntervalSince(start), 2_700, accuracy: 3)
    }

    func testLastSustainedBoutEndPicksTheLastQualifyingBout() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        // Two real bouts separated by a sub-threshold rest; a later 60 s spike
        // (< 90 s minimum) must not extend the boundary.
        let s = samples([(600, 140), (600, 100), (600, 141), (900, 100), (60, 150), (600, 100)],
                        start: start)
        let boutEnd = AtriaWorkoutOnset.lastSustainedElevatedBoutEnd(samples: s, rest: 66, maxHR: 190)
        XCTAssertNotNil(boutEnd)
        XCTAssertEqual(boutEnd!.timeIntervalSince(start), 1_800, accuracy: 3)
    }

    func testLastSustainedBoutEndFailsClosedWithoutASustainedBout() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertNil(AtriaWorkoutOnset.lastSustainedElevatedBoutEnd(
            samples: samples([(3_600, 100), (60, 140), (600, 95)], start: start),
            rest: 66,
            maxHR: 190))
    }

    // windowStats: the trimmed-window HR stats must reflect ONLY the given
    // (trimmed) samples — the honesty bug the self-review caught was avg being
    // computed over the untrimmed window.
    func testWindowStatsAveragesOnlyTheGivenSamples() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let s = samples([(39 * 60, 150)], start: start) // 39 min of real effort at 150
        let stats = AtriaWorkoutOnset.windowStats(samples: s, windowSeconds: 39 * 60)
        XCTAssertNotNil(stats)
        XCTAssertEqual(stats!.avgHR, 150)
        XCTAssertEqual(stats!.peakHR, 150)
        XCTAssertEqual(stats!.streamCoveragePercent, 100)
    }

    func testWindowStatsCoverageExcludesGaps() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var s = samples([(75, 140)], start: start)
        s += samples([(75, 140)], start: start.addingTimeInterval(225)) // 150s gap in a 300s window
        let stats = AtriaWorkoutOnset.windowStats(samples: s, windowSeconds: 300)
        XCTAssertNotNil(stats)
        XCTAssertLessThan(stats!.streamCoveragePercent, 60)
        XCTAssertGreaterThan(stats!.streamCoveragePercent, 40)
    }

    func testWindowStatsPercentiles() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let s: [(t: Date, bpm: Int)] = (0..<100).map { (start.addingTimeInterval(TimeInterval($0)), 100 + $0) }
        let stats = AtriaWorkoutOnset.windowStats(samples: s, windowSeconds: 100)
        XCTAssertNotNil(stats)
        XCTAssertEqual(stats!.peakHR, 199)
        XCTAssertGreaterThanOrEqual(stats!.p95HR, 190)
    }
}
