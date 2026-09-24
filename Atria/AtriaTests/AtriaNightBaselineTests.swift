import XCTest
@testable import Atria

final class AtriaNightBaselineTests: XCTestCase {
    typealias B = AtriaNightBaseline

    private let calendar = Calendar.current

    private func date(day: Int, _ hour: Int, _ minute: Int) -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = 9; c.day = day; c.hour = hour; c.minute = minute
        return calendar.date(from: c)!
    }

    /// A night starting on `day` at hh:mm with a 7.5 h window.
    private func night(day: Int, onset: (Int, Int), hr: Double = 60, rmssd: Double = 50,
                       disturbed: Double = 30, coverage: Double = 1) -> AtriaNightSummary {
        let start = date(day: day, onset.0, onset.1)
        let wake = start.addingTimeInterval(7.5 * 3_600)
        return AtriaNightSummary(night: start, onset: start, wake: wake,
                                 asleepMinutes: 450 - disturbed, disturbedMinutes: disturbed,
                                 interruptions: 2, ups: 1, sleepingHeartRate: hr, sleepingRMSSD: rmssd,
                                 coverage: coverage)
    }

    private func history(onsets: [(Int, Int)], hr: [Double]? = nil) -> [AtriaNightSummary] {
        onsets.enumerated().map { i, o in night(day: 1 + i, onset: o, hr: hr?[i] ?? 60) }
    }

    private func comparisons(_ outcome: B.Outcome) -> [B.Metric: B.Comparison] {
        guard case let .compared(list) = outcome else { XCTFail("expected comparisons"); return [:] }
        return Dictionary(uniqueKeysWithValues: list.map { ($0.metric, $0) })
    }

    func testLearningUntilFiveQualifyingNights() {
        let h = history(onsets: [(23, 0), (23, 10), (23, 5), (23, 0)])
        XCTAssertEqual(B.compare(tonight: night(day: 20, onset: (23, 0)), history: h),
                       .learning(nightsCollected: 4, nightsNeeded: 5))
    }

    func testLowCoverageNightsDoNotCountTowardTheBaseline() {
        var h = history(onsets: [(23, 0), (23, 10), (23, 5), (23, 0), (23, 5)])
        h[0].coverage = 0.5
        XCTAssertEqual(B.compare(tonight: night(day: 20, onset: (23, 0)), history: h),
                       .learning(nightsCollected: 4, nightsNeeded: 5))
    }

    func testTypicalNightIsTypicalEverywhere() {
        let h = history(onsets: [(23, 0), (23, 10), (22, 55), (23, 5), (23, 0), (23, 15)],
                        hr: [60, 61, 59, 60, 62, 60])
        let c = comparisons(B.compare(tonight: night(day: 20, onset: (23, 5), hr: 61), history: h))
        XCTAssertTrue(c.values.allSatisfy { $0.severity == .typical }, "\(c.values.map(\.sentence))")
    }

    func testClearlyHigherSleepingHeartRateIsUnusual() {
        let h = history(onsets: Array(repeating: (23, 0), count: 8), hr: [60, 61, 59, 60, 62, 60, 61, 59])
        let c = comparisons(B.compare(tonight: night(day: 20, onset: (23, 0), hr: 70), history: h))
        let hr = c[.sleepingHeartRate]!
        XCTAssertEqual(hr.severity, .unusual)
        XCTAssertEqual(hr.direction, .higher)
        XCTAssertTrue(hr.sentence.contains("unusually higher") || hr.sentence.contains("higher"))
    }

    func testSmallWobbleIsNotFlaggedEvenForVeryConsistentPeople() {
        let h = history(onsets: Array(repeating: (23, 0), count: 8), hr: Array(repeating: 60, count: 8))
        let c = comparisons(B.compare(tonight: night(day: 20, onset: (23, 0), hr: 62), history: h))
        XCTAssertEqual(c[.sleepingHeartRate]!.severity, .typical, "2 bpm is below the minimum effect")
    }

    func testBedtimeAcrossMidnightUsesCircularStatistics() {
        let h = [night(day: 1, onset: (23, 50)), night(day: 3, onset: (0, 5)), night(day: 4, onset: (23, 55)),
                 night(day: 6, onset: (0, 10)), night(day: 7, onset: (23, 45)), night(day: 9, onset: (0, 0))]
        let c = comparisons(B.compare(tonight: night(day: 20, onset: (0, 5)), history: h))
        let bed = c[.bedtime]!
        XCTAssertEqual(bed.severity, .typical)
        XCTAssertLessThan(abs(bed.delta), 20, "00:05 vs a ~23:58 usual is minutes apart, not ~12 h")
    }

    func testAfternoonSleeperIsHandled() {
        let h = history(onsets: [(13, 15), (13, 30), (13, 0), (13, 20), (13, 10), (13, 25)])
        let c = comparisons(B.compare(tonight: night(day: 20, onset: (13, 20)), history: h))
        XCTAssertEqual(c[.bedtime]!.severity, .typical)
        let late = comparisons(B.compare(tonight: night(day: 20, onset: (16, 30)), history: h))[.bedtime]!
        XCTAssertEqual(late.severity, .unusual)
        XCTAssertEqual(late.direction, .later)
    }

    func testCircularHelpers() {
        XCTAssertEqual(B.circularDelta(5, 1_435), 10, accuracy: 1e-9)
        XCTAssertEqual(B.circularDelta(1_435, 5), -10, accuracy: 1e-9)
        XCTAssertEqual(B.circularDelta(B.circularMean([1_430, 10]), 0), 0, accuracy: 0.5)
        XCTAssertEqual(B.circularMean([1_380, 1_400]), 1_390, accuracy: 0.5)
    }

    func testGoldenNightSummaryIsPlausible() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("Atria/AtriaTests/Fixtures/whoop4-night-2026-09-23-minutes.json")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("private fixture absent") }
        struct F: Decodable {
            struct M: Decodable { let t: Double; let hr: Double?; let motion: Double?; let steps: Int; let rr: [Int]; let off_wrist: Bool }
            let lights_off: Double
            let minutes: [M]
        }
        let f = try JSONDecoder().decode(F.self, from: Data(contentsOf: url))
        let minutes = f.minutes.map {
            AtriaNightTimelineAnalyzer.Minute(start: Date(timeIntervalSince1970: $0.t), heartRate: $0.hr,
                                              motion: $0.motion, steps: $0.steps, rrIntervals: $0.rr,
                                              offWrist: $0.off_wrist)
        }
        let result = AtriaNightTimelineAnalyzer.analyze(minutes, lightsOff: Date(timeIntervalSince1970: f.lights_off))
        let s = try XCTUnwrap(AtriaNightSummary.from(result, minutes: minutes))
        XCTAssertGreaterThan(s.coverage, 0.95)
        XCTAssertEqual(s.ups, 1)
        XCTAssertGreaterThan(s.asleepMinutes, 5 * 60)
        XCTAssertLessThan(s.asleepMinutes, 8.5 * 60)
        XCTAssertNotNil(s.sleepingRMSSD)
        XCTAssertEqual(s.sleepingHeartRate ?? 0, 64, accuracy: 5)
    }
}
