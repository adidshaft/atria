import XCTest
@testable import Atria

final class AtriaBiologicalAgeZoneTruthTests: XCTestCase {
    func testWeeklyZoneCreditRequiresConfirmedWorkoutZoneEvidence() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)

        XCTAssertNil(SessionStore.confirmedWorkoutZone2PlusMinutes(workouts: [], now: now),
                     "Raw strap sessions and detector candidates are not confirmed exercise")
        XCTAssertNil(SessionStore.confirmedWorkoutZone2PlusMinutes(
            workouts: [workout(endingAt: now.addingTimeInterval(-60), zones: nil)],
            now: now
        ), "A confirmed window without a real zone breakdown must fail closed")
        XCTAssertNil(SessionStore.confirmedWorkoutZone2PlusMinutes(
            workouts: [workout(endingAt: now.addingTimeInterval(-60),
                               zones: ["aerobic": .nan])],
            now: now
        ), "Non-finite zone values are not usable physiological evidence")
    }

    func testWeeklyZoneCreditCountsOnlyZoneTwoAndAbove() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let zones: [String: TimeInterval] = [
            "rest": 180,
            "warmup": 240,
            "fatBurn": 300,
            "aerobic": 240,
            "anaerobic": 120,
            "max": 60
        ]

        let minutes = try XCTUnwrap(SessionStore.confirmedWorkoutZone2PlusMinutes(
            workouts: [workout(endingAt: now.addingTimeInterval(-60), zones: zones)],
            now: now
        ))

        XCTAssertEqual(minutes, 12, accuracy: 0.001)
    }

    func testWeeklyZoneCreditRejectsStaleFutureAndInvalidEvidence() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let valid = workout(endingAt: now.addingTimeInterval(-60),
                            zones: ["fatBurn": 600, "aerobic": .nan])
        let stale = workout(endingAt: now.addingTimeInterval(-8 * 24 * 60 * 60),
                            zones: ["aerobic": 3_600])
        let future = workout(endingAt: now.addingTimeInterval(20 * 60),
                             zones: ["aerobic": 3_600])

        let minutes = try XCTUnwrap(SessionStore.confirmedWorkoutZone2PlusMinutes(
            workouts: [stale, valid, future],
            now: now
        ))

        XCTAssertEqual(minutes, 10, accuracy: 0.001)
    }

    private func workout(endingAt end: Date,
                         duration: TimeInterval = 30 * 60,
                         zones: [String: TimeInterval]?) -> UserConfirmedWorkout {
        let start = end.addingTimeInterval(-duration)
        return UserConfirmedWorkout(
            id: UUID().uuidString,
            createdAt: end,
            start: start,
            end: end,
            label: "Confirmed workout",
            source: "test",
            confidence: "user_confirmed",
            sessions: 1,
            samples: 100,
            avgHR: 120,
            peakHR: 150,
            p95HR: 145,
            p99HR: 149,
            thresholdHR: 110,
            streamCoveragePercent: 95,
            observedDuration: duration,
            reason: "test",
            zoneSeconds: zones
        )
    }
}
