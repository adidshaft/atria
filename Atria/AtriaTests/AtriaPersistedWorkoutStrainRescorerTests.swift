import XCTest
@testable import Atria

final class AtriaPersistedWorkoutStrainRescorerTests: XCTestCase {
    func testRescoresOnlyExactPersistedMeasuredTRIMPAndIsIdempotent() {
        let workout = makeWorkout(id: "verified", strain: 4.85)
        let audit = makeAudit(workout: workout, rawTRIMP: 65.6, score: 4.85)

        let first = AtriaPersistedWorkoutStrainRescorer.rescore(workouts: [workout], audits: [audit])

        XCTAssertEqual(first.rescoredWorkoutIDs, ["verified"])
        XCTAssertEqual(try XCTUnwrap(first.workouts[0].strain),
                       Metrics.strain(fromTRIMP: 65.6),
                       accuracy: 0.000_001)
        XCTAssertEqual(first.workouts[0].strainCalibrationVersion,
                       AtriaAnalytics.Strain.displayCalibrationVersion)

        let second = AtriaPersistedWorkoutStrainRescorer.rescore(workouts: first.workouts, audits: [audit])
        XCTAssertFalse(second.changed)
        XCTAssertEqual(second.workouts, first.workouts)
    }

    func testLeavesWorkoutsWithoutExactVerifiedTRIMPEvidenceUntouched() {
        let verified = makeWorkout(id: "verified", strain: 4.85)
        let missingAudit = makeWorkout(id: "missing", strain: 4.2)
        let changedWindow = makeWorkout(id: "changed-window", strain: 4.1, coverage: 80)
        let invalidAudit = makeWorkout(id: "invalid", strain: 4.0)
        let audits = [
            makeAudit(workout: verified, rawTRIMP: 65.6, score: 4.85),
            makeAudit(workout: changedWindow, rawTRIMP: 55, score: 4.1, coverage: 81),
            makeAudit(workout: invalidAudit, rawTRIMP: 0, score: 4.0)
        ]

        let result = AtriaPersistedWorkoutStrainRescorer.rescore(
            workouts: [verified, missingAudit, changedWindow, invalidAudit],
            audits: audits
        )

        XCTAssertEqual(result.rescoredWorkoutIDs, ["verified"])
        XCTAssertEqual(result.workouts[1], missingAudit)
        XCTAssertEqual(result.workouts[2], changedWindow)
        XCTAssertEqual(result.workouts[3], invalidAudit)
    }

    private func makeWorkout(id: String,
                             strain: Double,
                             coverage: Int = 92) -> UserConfirmedWorkout {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        return UserConfirmedWorkout(id: id,
                                    createdAt: start,
                                    start: start,
                                    end: start.addingTimeInterval(3_600),
                                    label: "Verified workout",
                                    source: "live_workout_window",
                                    confidence: "live_window_user_confirmed",
                                    sessions: 1,
                                    samples: 240,
                                    avgHR: 131,
                                    peakHR: 170,
                                    p95HR: 160,
                                    p99HR: 169,
                                    thresholdHR: 110,
                                    streamCoveragePercent: coverage,
                                    observedDuration: 3_420,
                                    reason: "verified",
                                    strain: strain)
    }

    private func makeAudit(workout: UserConfirmedWorkout,
                           rawTRIMP: Double,
                           score: Double,
                           coverage: Int? = nil) -> AtriaStrainConfirmationAuditRecord {
        AtriaStrainConfirmationAuditRecord(workoutID: workout.id,
                                           recordedAt: workout.createdAt,
                                           rawTRIMP: rawTRIMP,
                                           integratedObservedSeconds: 3_420,
                                           droppedGapSeconds: 180,
                                           restingHR: 60,
                                           maxHR: 190,
                                           strainScore: score,
                                           result: "score_persisted",
                                           coveragePercent: coverage ?? workout.streamCoveragePercent)
    }
}
