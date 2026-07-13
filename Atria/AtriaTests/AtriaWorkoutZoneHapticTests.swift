import XCTest
@testable import Atria

final class AtriaWorkoutZoneHapticTests: XCTestCase {
    func testBoundaryTransitionsProduceRequestedPulseCounts() {
        var detector = AtriaWorkoutZoneHapticTransition()

        XCTAssertNil(detector.accept(bpm: 110, lowerBPM: 120, upperBPM: 150))
        XCTAssertEqual(detector.accept(bpm: 120, lowerBPM: 120, upperBPM: 150), 1)
        XCTAssertNil(detector.accept(bpm: 149, lowerBPM: 120, upperBPM: 150))
        XCTAssertEqual(detector.accept(bpm: 153, lowerBPM: 120, upperBPM: 150), 3)
        XCTAssertEqual(detector.accept(bpm: 150, lowerBPM: 120, upperBPM: 150), 2)
        XCTAssertEqual(detector.accept(bpm: 117, lowerBPM: 120, upperBPM: 150), 1)
    }

    func testHysteresisPreventsBoundaryChatter() {
        var detector = AtriaWorkoutZoneHapticTransition()
        XCTAssertNil(detector.accept(bpm: 130, lowerBPM: 120, upperBPM: 150))
        XCTAssertNil(detector.accept(bpm: 151, lowerBPM: 120, upperBPM: 150))
        XCTAssertNil(detector.accept(bpm: 119, lowerBPM: 120, upperBPM: 150))
        XCTAssertEqual(detector.accept(bpm: 117, lowerBPM: 120, upperBPM: 150), 1)
    }

    func testStartConfigurationNormalizesReversedZoneRange() {
        let configuration = AtriaWorkoutStartConfiguration(activityType: .running,
                                                            lowerTargetZone: 4,
                                                            upperTargetZone: 2)
        XCTAssertEqual(configuration.normalizedZoneRange, 2...4)
    }

    func testPendingIntentDecodesPayloadWrittenBeforeZoneTargetsExisted() throws {
        let json = #"{"startedAt":0,"activityType":"Walking","strengthSets":[],"excludedIntervals":[],"startingStepCount":0,"startingDayStrain":0}"#.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let intent = try decoder.decode(AtriaPendingWorkoutIntent.self, from: json)
        XCTAssertNil(intent.lowerTargetZone)
        XCTAssertNil(intent.upperTargetZone)
    }
}
