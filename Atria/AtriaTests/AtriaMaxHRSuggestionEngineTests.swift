import XCTest
@testable import Atria

/// The max-HR suggestion is a learning input to zones and strain, so it may
/// only learn from evidence that could be a real heartbeat.
final class AtriaMaxHRSuggestionEngineTests: XCTestCase {
    private func steady(_ bpm: Int, seconds: Int, from t0: Double = 0) -> [(t: Double, bpm: Int)] {
        (0..<seconds).map { (t: t0 + Double($0), bpm: bpm) }
    }

    func testSingleSampleSpikeDoesNotBecomeThePeak() {
        var points = steady(150, seconds: 300)
        points[120] = (t: 120, bpm: 212)   // a one-second wrist knock
        XCTAssertEqual(AtriaMaxHRSuggestionEngine.sustainedPeak(points: points), 150,
                       "a reading held for one second is not a peak the heart reached")
    }

    func testHalfMinutePlateauCountsAsThePeak() {
        var points = steady(150, seconds: 120)
        points += steady(190, seconds: 35, from: 120)
        points += steady(150, seconds: 120, from: 155)
        XCTAssertEqual(AtriaMaxHRSuggestionEngine.sustainedPeak(points: points), 190)
    }

    func testShortPlateauIsFloorOfItsWindow() {
        // Twenty seconds at 190 inside a 150 session: every 30s window that
        // contains it also contains 150, so the plateau does not qualify.
        var points = steady(150, seconds: 120)
        points += steady(190, seconds: 20, from: 120)
        points += steady(150, seconds: 120, from: 140)
        XCTAssertEqual(AtriaMaxHRSuggestionEngine.sustainedPeak(points: points), 150)
    }

    func testTooFewSamplesGiveNoPeak() {
        XCTAssertNil(AtriaMaxHRSuggestionEngine.sustainedPeak(points: [(t: 0, bpm: 180), (t: 40, bpm: 181)]))
    }

    func testFewerThanThreeSessionsCannotSuggest() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertNil(AtriaMaxHRSuggestionEngine.suggestion(sessionPeaks: [195, 196],
                                                           currentMaxHR: 180, now: now),
                     "two sessions is one session's opinion")
        XCTAssertNotNil(AtriaMaxHRSuggestionEngine.suggestion(sessionPeaks: [195, 196, 194],
                                                              currentMaxHR: 180, now: now))
    }

    func testImplausiblePeaksAreDroppedNotRanked() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let suggestion = AtriaMaxHRSuggestionEngine.suggestion(sessionPeaks: [170, 172, 174, 240, 250],
                                                               currentMaxHR: 180, now: now)
        XCTAssertNil(suggestion, "240 and 250 are artifacts; the real peaks do not clear 180 + 3")
    }
}
