import XCTest
@testable import Atria

final class AtriaInsightEvidenceContinuityTests: XCTestCase {
    func testRespiratoryEstimateExpiresWhenRRStreamStops() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let samples: [(t: Date, ms: Double)] = (0...89).map { second in
            (start.addingTimeInterval(Double(second)),
             900 + 70 * sin(2 * .pi * 0.25 * Double(second)))
        }
        let end = samples.last!.t
        XCTAssertNotNil(AtriaAnalytics.RespRateRsa.estimate(samples: samples, now: end))
        XCTAssertNotNil(AtriaAnalytics.RespRateRsa.estimateCancellable(samples: samples, now: end, shouldContinue: { true }))
        XCTAssertNil(AtriaAnalytics.RespRateRsa.estimate(samples: samples, now: end.addingTimeInterval(6)))
        XCTAssertNil(AtriaAnalytics.RespRateRsa.estimateCancellable(samples: samples, now: end.addingTimeInterval(6), shouldContinue: { true }))
    }

    func testRespiratoryEstimateRejectsInvalidRRWithoutBridgingIt() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for invalid in [0.0, 299, 2001, .nan, .infinity] {
            var samples: [(t: Date, ms: Double)] = (0...89).map { second in
                (start.addingTimeInterval(Double(second)),
                 900 + 70 * sin(2 * .pi * 0.25 * Double(second)))
            }
            samples[40].ms = invalid
            let end = samples.last!.t
            XCTAssertNil(AtriaAnalytics.RespRateRsa.estimate(samples: samples, now: end))
            XCTAssertNil(AtriaAnalytics.RespRateRsa.estimateCancellable(samples: samples, now: end, shouldContinue: { true }))
        }
    }

    func testInvalidHeartRateBreaksCoverageAndLoadAtBothEndpoints() throws {
        for invalid in [0, 34, 241, 65_535] {
            let series: [(t: Double, bpm: Int)] = [
                (0, 150), (1, invalid), (2, 150), (3, 150)
            ]
            let valid: [(t: Double, bpm: Int)] = [(2, 150), (3, 150)]
            let zones = AtriaAnalytics.Strain.maxHeartRateZoneSeconds(series, maxHR: 200)
            XCTAssertEqual(zones.aerobic, 1, "Invalid BPM: \(invalid)")
            XCTAssertEqual(zones.droppedGapSeconds, 2)
            XCTAssertEqual(zones.rest, 0)
            XCTAssertEqual(zones.max, 0)
            let cancellable = try XCTUnwrap(AtriaAnalytics.Strain.maxHeartRateZoneSeconds(
                series, maxHR: 200, shouldContinue: { true }
            ))
            XCTAssertEqual(cancellable, zones)

            let summary = AtriaAnalytics.Strain.zoneSummary(series, rest: 60, max: 200)
            XCTAssertEqual(summary.totalSeconds, 1)
            XCTAssertEqual(summary.droppedGapSeconds, 2)
            XCTAssertEqual(summary.samples, 1)
            XCTAssertEqual(AtriaAnalytics.Strain.edwardsLoad(series, rest: 60, max: 200),
                           AtriaAnalytics.Strain.edwardsLoad(valid, rest: 60, max: 200))
            XCTAssertEqual(AtriaAnalytics.Strain.trimp(series, rest: 60, max: 200),
                           AtriaAnalytics.Strain.trimp(valid, rest: 60, max: 200))

            let profile = AthleteProfile(age: 35, measuredMaxHR: 200,
                                         maxHRSource: .measured, biologicalSex: .male,
                                         weightKg: 75, heightCm: 178, updated: nil,
                                         hasCompletedOnboarding: true)
            func calories(_ points: [(t: Double, bpm: Int)]) -> Double? {
                AtriaAnalytics.Daily.dayCalories(points.map {
                    .init(t: Date(timeIntervalSince1970: $0.t), bpm: $0.bpm)
                }, rest: 60, profile: profile)
            }
            XCTAssertEqual(try XCTUnwrap(calories(series)), try XCTUnwrap(calories(valid)), accuracy: 0.000_001)
        }
    }

    func testNonFiniteTimestampCannotCreateInfiniteZoneCoverage() throws {
        let series: [(t: Double, bpm: Int)] = [(0, 150), (.infinity, 150)]
        XCTAssertEqual(AtriaAnalytics.Strain.maxHeartRateZoneSeconds(series, maxHR: 200), .empty)
        XCTAssertEqual(try XCTUnwrap(AtriaAnalytics.Strain.maxHeartRateZoneSeconds(
            series, maxHR: 200, shouldContinue: { true }
        )), .empty)
        XCTAssertEqual(AtriaAnalytics.Strain.zoneSummary(series, rest: 60, max: 200), .empty)
        XCTAssertEqual(AtriaAnalytics.Strain.edwardsLoad(series, rest: 60, max: 200), 0)
    }

    func testPlausibilityBoundariesRetainActualMeasuredCoverage() {
        let zones = AtriaAnalytics.Strain.maxHeartRateZoneSeconds([(0, 35), (1, 35), (2, 240)], maxHR: 200)
        XCTAssertEqual(zones.rest, 1)
        XCTAssertEqual(zones.max, 1)
        XCTAssertEqual(zones.droppedGapSeconds, 0)
    }
}
