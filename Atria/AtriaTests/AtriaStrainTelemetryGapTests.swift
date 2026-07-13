import XCTest
@testable import Atria

final class AtriaStrainTelemetryGapTests: XCTestCase {
    func testTRIMPDoesNotBackfillLongTelemetryGapAtLaterHighHeartRate() {
        let result = Metrics.trimp([(t: 0, bpm: 60), (t: 299, bpm: 180)],
                                   rest: 60,
                                   max: 190)

        XCTAssertEqual(result, 0)
    }

    func testTRIMPInterpolatesAcrossShortAcceptedGap() {
        let interpolated = Metrics.trimp([(t: 0, bpm: 60), (t: 15, bpm: 180)],
                                         rest: 60,
                                         max: 190)
        let heldAtHigh = 0.25 * ((180.0 - 60.0) / (190.0 - 60.0))
            * 0.64 * exp(1.92 * ((180.0 - 60.0) / (190.0 - 60.0)))

        XCTAssertGreaterThan(interpolated, 0)
        XCTAssertLessThan(interpolated, heldAtHigh)
    }

    func testTRIMPFifteenSecondBoundaryIsInclusive() {
        XCTAssertGreaterThan(Metrics.trimp([(t: 0, bpm: 120), (t: 15, bpm: 120)],
                                           rest: 60,
                                           max: 190), 0)
        XCTAssertEqual(Metrics.trimp([(t: 0, bpm: 120), (t: 15.001, bpm: 120)],
                                     rest: 60,
                                     max: 190), 0)
    }

    func testZonesUseTheSameFifteenSecondEvidenceBoundaryAsTRIMP() {
        let accepted = AtriaAnalytics.Strain.maxHeartRateZoneSeconds(
            [(t: 0, bpm: 120), (t: 15, bpm: 120)],
            maxHR: 190
        )
        let rejected = AtriaAnalytics.Strain.maxHeartRateZoneSeconds(
            [(t: 0, bpm: 120), (t: 15.001, bpm: 120)],
            maxHR: 190
        )

        XCTAssertEqual(accepted.storage.values.reduce(0, +), 15, accuracy: 0.000_001)
        XCTAssertTrue(rejected.isEmpty)
        XCTAssertEqual(rejected.droppedGapSeconds, 15.001, accuracy: 0.000_001)
    }

    func testEdwardsAuditUsesTheSameFifteenSecondEvidenceBoundary() {
        let rest = 60
        let maxHR = 180
        let accepted = [(t: 0.0, bpm: 120), (t: 15.0, bpm: 150)]
        let rejected = [(t: 0.0, bpm: 120), (t: 15.001, bpm: 150)]

        XCTAssertGreaterThan(AtriaAnalytics.Strain.edwardsLoad(accepted, rest: rest, max: maxHR), 0)
        XCTAssertEqual(AtriaAnalytics.Strain.edwardsLoad(rejected, rest: rest, max: maxHR), 0)
    }

    func testExplicitThirtyAndSixtySecondPausesSplitEveryLoadIntegrator() {
        let start = Date(timeIntervalSince1970: 1_800_100_000)
        let profile = AthleteProfile(age: 30,
                                     measuredMaxHR: 190,
                                     maxHRSource: .measured,
                                     biologicalSex: .male,
                                     weightKg: 78,
                                     heightCm: 178,
                                     updated: start,
                                     hasCompletedOnboarding: true)

        for pauseDuration in [30.0, 60.0] {
            let pauseStart = 20.0
            let pauseEnd = pauseStart + pauseDuration
            let postStart = pauseEnd + 10
            let offsets = [0.0, 10.0, pauseStart, pauseEnd, postStart, postStart + 10]
            let points = offsets.map { SavedSession.Point(t: $0, bpm: 150) }
            let session = SavedSession(id: UUID(),
                                       start: start,
                                       end: start.addingTimeInterval(postStart + 10),
                                       label: "Paused",
                                       points: points,
                                       excludedIntervals: [
                                           ExcludedInterval(start: start.addingTimeInterval(pauseStart),
                                                            end: start.addingTimeInterval(pauseEnd))
                                       ])

            let expectedSegments = [
                [(t: 0.0, bpm: 150), (t: 10.0, bpm: 150)],
                [(t: postStart, bpm: 150), (t: postStart + 10, bpm: 150)],
            ]
            let expectedTRIMP = expectedSegments.reduce(0.0) {
                $0 + Metrics.trimp($1, rest: 60, max: 190)
            }
            let expectedZoneSeconds = expectedSegments.reduce(0.0) {
                $0 + AtriaAnalytics.Strain.maxHeartRateZoneSeconds($1, maxHR: 190)
                    .storage.values.reduce(0, +)
            }
            let expectedCalories = expectedSegments.compactMap { segment -> Double? in
                Metrics.activeCalories(segment.map {
                    HRSample(t: start.addingTimeInterval($0.t), bpm: $0.bpm)
                }, rest: 60, profile: profile)
            }.reduce(0, +)

            XCTAssertEqual(session.trimp(rest: 60, max: 190), expectedTRIMP, accuracy: 0.000_001)
            XCTAssertEqual(session.timeInZone(maxHR: 190).values.reduce(0, +),
                           expectedZoneSeconds,
                           accuracy: 0.000_001)
            XCTAssertEqual(session.activeCalories(rest: 60, profile: profile) ?? -1,
                           expectedCalories,
                           accuracy: 0.000_001)

            let flattened = points
                .filter { $0.t < pauseStart || $0.t > pauseEnd }
                .map { (t: $0.t, bpm: $0.bpm) }
            XCTAssertGreaterThan(Metrics.trimp(flattened, rest: 60, max: 190), expectedTRIMP)
            XCTAssertGreaterThan(AtriaAnalytics.Strain.maxHeartRateZoneSeconds(flattened, maxHR: 190)
                .storage.values.reduce(0, +), expectedZoneSeconds)
        }
    }

    func testOverlappingPauseWindowsProduceOneBoundaryWithoutLosingSurvivors() {
        let start = Date(timeIntervalSince1970: 1_800_100_000)
        let samples = [0.0, 10, 30, 40, 60, 70].map {
            HRSample(t: start.addingTimeInterval($0), bpm: 140)
        }
        let segments = AtriaAnalytics.Strain.contiguousSegments(samples, excluding: [
            ExcludedInterval(start: start.addingTimeInterval(20), end: start.addingTimeInterval(45)),
            ExcludedInterval(start: start.addingTimeInterval(35), end: start.addingTimeInterval(55)),
        ])

        XCTAssertEqual(segments.map { $0.map(\.t) }, [
            [start, start.addingTimeInterval(10)],
            [start.addingTimeInterval(60), start.addingTimeInterval(70)],
        ])
    }
}
