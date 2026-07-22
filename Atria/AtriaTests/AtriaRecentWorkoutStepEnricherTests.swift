import XCTest
@testable import Atria

@MainActor
final class AtriaRecentWorkoutStepEnricherTests: XCTestCase {
    func testPolicySelectsOnlyRecentMissingLocomotionAndCapsNewestFirst() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let today = calendar.startOfDay(for: now)
        let eligible = (0..<8).map { offset in
            workout(
                id: "walk-\(offset)",
                start: now.addingTimeInterval(-Double(offset + 1) * 1_800),
                activity: .walking
            )
        }
        var alreadyFilled = workout(id: "filled",
                                    start: now.addingTimeInterval(-900),
                                    activity: .running)
        alreadyFilled.workoutSteps = 100
        alreadyFilled.workoutStepsAreEstimated = false
        let tooOld = workout(id: "old",
                             start: today.addingTimeInterval(-2 * 86_400 - 3_600),
                             activity: .hiking)
        let strength = workout(id: "strength",
                               start: now.addingTimeInterval(-1_200),
                               activity: .strength)
        let future = workout(id: "future",
                             start: now.addingTimeInterval(60),
                             activity: .walking)

        let selected = AtriaRecentWorkoutStepEnrichmentPolicy.candidates(
            from: eligible + [alreadyFilled, tooOld, strength, future],
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(selected.map(\.id), Array(eligible.prefix(6)).map(\.id))
    }

    func testAtomicEnrichmentMarksPhoneEstimateAndOnlyMovesWeakEvidenceForward() throws {
        let store = SessionStore()
        let marker = "historic-phone-steps-\(UUID().uuidString)"
        let start = Date(timeIntervalSince1970: 2_100_000_000)
        let end = start.addingTimeInterval(20 * 60)
        let saved = try XCTUnwrap(store.confirmWorkoutWindowForUI(
            start: start,
            end: end,
            rest: 60,
            maxHR: 190,
            source: marker,
            preserveUserDeclaredActivityWithoutHeartRate: true,
            activityType: AtriaWorkoutActivityType.walking.rawValue,
            reviewSource: marker
        ))
        defer {
            for workout in store.confirmedWorkouts where workout.reviewSource == marker {
                _ = store.deleteConfirmedWorkout(id: workout.id)
            }
        }

        XCTAssertTrue(store.enrichConfirmedWorkoutWithEstimatedPhoneSteps(
            id: saved.id,
            expectedStart: start,
            expectedEnd: end,
            count: 1_423,
            capturedAt: end
        ))
        let enriched = try XCTUnwrap(store.confirmedWorkouts.first { $0.id == saved.id })
        XCTAssertEqual(enriched.workoutSteps, 1_423)
        XCTAssertEqual(enriched.workoutStepsAreEstimated, true)
        XCTAssertEqual(enriched.workoutStepsCapturedAt, end)

        XCTAssertFalse(store.enrichConfirmedWorkoutWithEstimatedPhoneSteps(
            id: saved.id,
            expectedStart: start,
            expectedEnd: end,
            count: 1_200,
            capturedAt: end
        ))
        XCTAssertTrue(store.enrichConfirmedWorkoutWithEstimatedPhoneSteps(
            id: saved.id,
            expectedStart: start,
            expectedEnd: end,
            count: 1_500,
            capturedAt: end
        ))
        XCTAssertFalse(store.enrichConfirmedWorkoutWithEstimatedPhoneSteps(
            id: saved.id,
            expectedStart: start,
            expectedEnd: end,
            count: 0,
            capturedAt: end
        ))
        XCTAssertEqual(store.confirmedWorkouts.first { $0.id == saved.id }?.workoutSteps, 1_500)
    }

    func testAtomicEnrichmentNeverOverwritesExactStepEvidence() throws {
        let store = SessionStore()
        let marker = "exact-strap-steps-\(UUID().uuidString)"
        let start = Date(timeIntervalSince1970: 2_105_000_000)
        let end = start.addingTimeInterval(20 * 60)
        let saved = try XCTUnwrap(store.confirmWorkoutWindowForUI(
            start: start,
            end: end,
            rest: 60,
            maxHR: 190,
            source: marker,
            preserveUserDeclaredActivityWithoutHeartRate: true,
            activityType: AtriaWorkoutActivityType.walking.rawValue,
            reviewSource: marker,
            workoutSteps: 612,
            workoutStepsAreEstimated: false,
            workoutStepsCapturedAt: end
        ))
        defer {
            for workout in store.confirmedWorkouts where workout.reviewSource == marker {
                _ = store.deleteConfirmedWorkout(id: workout.id)
            }
        }

        XCTAssertFalse(store.enrichConfirmedWorkoutWithEstimatedPhoneSteps(
            id: saved.id,
            expectedStart: start,
            expectedEnd: end,
            count: 1_500,
            capturedAt: end
        ))
        XCTAssertEqual(store.confirmedWorkouts.first { $0.id == saved.id }?.workoutSteps, 612)
        XCTAssertEqual(store.confirmedWorkouts.first { $0.id == saved.id }?.workoutStepsAreEstimated,
                       false)
    }

    func testPolicyIncludesEstimatedCountsForStrictlyHigherRepair() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        var estimated = workout(id: "estimated", start: now.addingTimeInterval(-900), activity: .walking)
        estimated.workoutSteps = 612
        estimated.workoutStepsAreEstimated = true
        var exact = workout(id: "exact", start: now.addingTimeInterval(-1_200), activity: .walking)
        exact.workoutSteps = 500
        exact.workoutStepsAreEstimated = false

        XCTAssertEqual(
            AtriaRecentWorkoutStepEnrichmentPolicy.candidates(from: [exact, estimated], now: now)
                .map(\.id),
            [estimated.id]
        )
    }

    func testAtomicEnrichmentRejectsStaleWindowIdentity() throws {
        let store = SessionStore()
        let marker = "stale-phone-steps-\(UUID().uuidString)"
        let start = Date(timeIntervalSince1970: 2_110_000_000)
        let end = start.addingTimeInterval(15 * 60)
        let saved = try XCTUnwrap(store.confirmWorkoutWindowForUI(
            start: start,
            end: end,
            rest: 60,
            maxHR: 190,
            source: marker,
            preserveUserDeclaredActivityWithoutHeartRate: true,
            activityType: AtriaWorkoutActivityType.walking.rawValue,
            reviewSource: marker
        ))
        defer {
            for workout in store.confirmedWorkouts where workout.reviewSource == marker {
                _ = store.deleteConfirmedWorkout(id: workout.id)
            }
        }

        XCTAssertFalse(store.enrichConfirmedWorkoutWithEstimatedPhoneSteps(
            id: saved.id,
            expectedStart: start.addingTimeInterval(60),
            expectedEnd: end,
            count: 500,
            capturedAt: end
        ))
        XCTAssertNil(store.confirmedWorkouts.first { $0.id == saved.id }?.workoutSteps)
    }

    private func workout(id: String,
                         start: Date,
                         activity: AtriaWorkoutActivityType) -> UserConfirmedWorkout {
        UserConfirmedWorkout(
            id: id,
            createdAt: start,
            start: start,
            end: start.addingTimeInterval(600),
            label: activity.rawValue,
            source: "test",
            confidence: "test",
            sessions: 0,
            samples: 0,
            avgHR: 0,
            peakHR: 0,
            p95HR: 0,
            p99HR: 0,
            thresholdHR: 0,
            streamCoveragePercent: 0,
            observedDuration: 0,
            reason: "test",
            activityType: activity.rawValue
        )
    }
}
