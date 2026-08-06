import Foundation

/// Re-applies the current display curve to a confirmed workout only when the
/// exact measured TRIMP used at confirmation is still durably available.
///
/// The audit record is deliberately a stricter requirement than a workout's
/// summary HR fields: those fields cannot reconstruct the time integral and
/// must never be used to invent a new score.  This makes the operation safe to
/// run at every launch. Once a record has been rescored, its stored strain no
/// longer matches the pre-rescore audit score, so the operation is naturally
/// idempotent without writing a migration marker that could strand a failed
/// persistence attempt.
enum AtriaPersistedWorkoutStrainRescorer {
    struct Result: Equatable {
        let workouts: [UserConfirmedWorkout]
        let rescoredWorkoutIDs: [String]

        var changed: Bool { !rescoredWorkoutIDs.isEmpty }
    }

    static func rescore(workouts: [UserConfirmedWorkout],
                        audits: [AtriaStrainConfirmationAuditRecord]) -> Result {
        var rescoredIDs: [String] = []
        let updated = workouts.map { workout -> UserConfirmedWorkout in
            guard let audit = matchingVerifiedAudit(for: workout, audits: audits) else {
                return workout
            }

            let recalculated = Metrics.strain(fromTRIMP: audit.rawTRIMP)
            guard recalculated.isFinite,
                  abs(recalculated - (workout.strain ?? .nan)) > 0.000_001 else {
                return workout
            }

            var rescored = workout
            rescored.strain = recalculated
            // A later source-session fallback must not overwrite this exact
            // persisted TRIMP result with a wider/changed in-memory window.
            rescored.strainCalibrationVersion = AtriaAnalytics.Strain.displayCalibrationVersion
            rescoredIDs.append(workout.id)
            return rescored
        }
        return Result(workouts: updated, rescoredWorkoutIDs: rescoredIDs)
    }

    private static func matchingVerifiedAudit(
        for workout: UserConfirmedWorkout,
        audits: [AtriaStrainConfirmationAuditRecord]
    ) -> AtriaStrainConfirmationAuditRecord? {
        guard let storedStrain = workout.strain,
              storedStrain.isFinite,
              workout.end > workout.start,
              workout.samples >= 2,
              workout.observedDuration > 0,
              workout.streamCoveragePercent > 0 else {
            return nil
        }

        return audits
            .filter { audit in
                audit.workoutID == workout.id
                    && audit.result == "score_persisted"
                    && audit.rawTRIMP.isFinite
                    && audit.rawTRIMP > 0
                    && audit.integratedObservedSeconds.isFinite
                    && audit.integratedObservedSeconds > 0
                    && audit.droppedGapSeconds.isFinite
                    && audit.droppedGapSeconds >= 0
                    && audit.restingHR > 0
                    && audit.maxHR > audit.restingHR
                    && audit.coveragePercent == workout.streamCoveragePercent
                    && audit.strainScore?.isFinite == true
                    && abs((audit.strainScore ?? .nan) - storedStrain) <= 0.000_001
            }
            .max { $0.recordedAt < $1.recordedAt }
    }
}
