import XCTest
@testable import Atria

final class AtriaWorkoutGyroStepSourceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    func testOnlyFreshAmbulatoryStartFreezesGyroSource() {
        let fresh = coordinate(count: 900, capturedAt: now)
        XCTAssertEqual(AtriaWorkoutStepSourceVersion.frozen(for: .walking,
                                                            gyroCoordinate: fresh),
                       .strapGyroCadenceAmbulatoryV1)
        XCTAssertEqual(AtriaWorkoutStepSourceVersion.frozen(for: .running,
                                                            gyroCoordinate: fresh),
                       .strapGyroCadenceAmbulatoryV1)
        XCTAssertEqual(AtriaWorkoutStepSourceVersion.frozen(for: .hiking,
                                                            gyroCoordinate: fresh),
                       .strapGyroCadenceAmbulatoryV1)

        let stale = coordinate(count: 900, capturedAt: now.addingTimeInterval(-3))
        XCTAssertEqual(AtriaWorkoutStepSourceVersion.frozen(for: .walking,
                                                            gyroCoordinate: stale),
                       .strapAccelerometerV1)
    }

    func testNonAmbulatoryWorkoutNeverPromotesGyro() {
        let fresh = coordinate(count: 900, capturedAt: now)
        for type in [AtriaWorkoutActivityType.strength, .cycling, .cardio, .other] {
            XCTAssertEqual(AtriaWorkoutStepSourceVersion.frozen(for: type,
                                                                gyroCoordinate: fresh),
                           .strapAccelerometerV1)
        }
    }

    func testPersistedSourceSurvivesRestartAndActivityTypeEdit() throws {
        var intent = makeIntent(source: .strapGyroCadenceAmbulatoryV1)
        intent.activityType = AtriaWorkoutActivityType.strength.rawValue
        let restored = try JSONDecoder().decode(
            AtriaPendingWorkoutIntent.self,
            from: JSONEncoder().encode(intent)
        )
        XCTAssertEqual(restored.stepSourceVersion, .strapGyroCadenceAmbulatoryV1)
        XCTAssertEqual(restored.resolvedActivityType, .strength)
    }

    func testLegacyIntentDecodesToOriginalAccelerometerCoordinate() throws {
        let encoded = try JSONEncoder().encode(
            makeIntent(source: .strapGyroCadenceAmbulatoryV1)
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "stepSourceVersion")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        XCTAssertEqual(
            try JSONDecoder().decode(AtriaPendingWorkoutIntent.self,
                                     from: legacy).stepSourceVersion,
            .strapAccelerometerV1
        )
    }

    func testPauseResumeAndEndRetainFrozenSourceAndCoordinate() throws {
        var intent = makeIntent(source: .strapGyroCadenceAmbulatoryV1)
        intent = try XCTUnwrap(AtriaWorkoutCommandTransaction.applying(
            .pause,
            to: intent,
            at: now.addingTimeInterval(60),
            currentStepCount: 1_040,
            hasCurrentStepEvidence: true,
            currentStepsAreEstimated: true,
            currentStepsCapturedAt: now.addingTimeInterval(60)
        ))
        intent = try XCTUnwrap(AtriaWorkoutCommandTransaction.applying(
            .resume,
            to: intent,
            at: now.addingTimeInterval(120),
            currentStepCount: 1_060,
            hasCurrentStepEvidence: true
        ))
        intent = try XCTUnwrap(AtriaWorkoutCommandTransaction.applying(
            .end,
            to: intent,
            at: now.addingTimeInterval(300),
            currentStepCount: 1_200,
            hasCurrentStepEvidence: true,
            currentStepsAreEstimated: true,
            currentStepsCapturedAt: now.addingTimeInterval(300)
        ))
        XCTAssertEqual(intent.stepSourceVersion, .strapGyroCadenceAmbulatoryV1)
        XCTAssertEqual(intent.completedStepCount, 180)
        XCTAssertEqual(intent.completedStepsAreEstimated, true)
    }

    func testCumulativeCoordinateRemainsMonotonicAcrossLedgerBoundaryArithmetic() throws {
        let before = try XCTUnwrap(AtriaWorkoutStepCoordinate.makeCumulative(
            savedPrefixHydrated: true,
            cumulativeCount: 2_000 + 125,
            hasEvidence: true,
            capturedAt: now,
            isConnected: true,
            reconnectPending: false,
            rangeLossBackfillPending: false,
            now: now
        ))
        let after = try XCTUnwrap(AtriaWorkoutStepCoordinate.makeCumulative(
            savedPrefixHydrated: true,
            cumulativeCount: 2_125 + 30,
            hasEvidence: true,
            capturedAt: now,
            isConnected: true,
            reconnectPending: false,
            rangeLossBackfillPending: false,
            now: now
        ))
        XCTAssertEqual(before.cumulativeCount, 2_125)
        XCTAssertEqual(after.cumulativeCount, 2_155)
        XCTAssertGreaterThan(after.cumulativeCount, before.cumulativeCount)
        XCTAssertTrue(after.isEstimated)
    }

    private func coordinate(count: Int, capturedAt: Date) -> AtriaWorkoutStepCoordinate {
        AtriaWorkoutStepCoordinate.makeCumulative(
            savedPrefixHydrated: true,
            cumulativeCount: count,
            hasEvidence: true,
            capturedAt: capturedAt,
            isConnected: true,
            reconnectPending: false,
            rangeLossBackfillPending: false,
            now: now
        )!
    }

    private func makeIntent(
        source: AtriaWorkoutStepSourceVersion
    ) -> AtriaPendingWorkoutIntent {
        AtriaPendingWorkoutIntent(
            startedAt: now,
            endedAt: nil,
            activityType: AtriaWorkoutActivityType.walking.rawValue,
            strengthSets: [],
            excludedIntervals: [],
            startingStepCount: 1_000,
            stepSourceVersion: source,
            startingDayStrain: 0
        )
    }
}
