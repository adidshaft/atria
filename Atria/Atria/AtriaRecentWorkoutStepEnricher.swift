import CoreMotion
import Foundation

/// Pure selection policy for the opportunistic phone-step enrichment. Keeping
/// the policy separate from CMPedometer makes the three-day/query-count bounds
/// and locomotion-only rule directly testable.
enum AtriaRecentWorkoutStepEnrichmentPolicy {
    static let maximumQueries = 6
    static let maximumWorkoutDuration: TimeInterval = 6 * 60 * 60

    static func candidates(
        from workouts: [UserConfirmedWorkout],
        now: Date,
        calendar: Calendar = .current
    ) -> [UserConfirmedWorkout] {
        let today = calendar.startOfDay(for: now)
        let cutoff = calendar.date(byAdding: .day, value: -2, to: today) ?? today
        return Array(workouts.lazy.filter { workout in
            guard workout.workoutSteps == nil || workout.workoutStepsAreEstimated != false,
                  workout.end > workout.start,
                  workout.end <= now,
                  workout.end >= cutoff,
                  workout.duration <= maximumWorkoutDuration else {
                return false
            }
            let activity = AtriaWorkoutActivityType.resolved(
                activityType: workout.activityType,
                subtype: workout.activitySubtype,
                label: workout.label
            )
            return [.walking, .running, .hiking].contains(activity)
        }
        .sorted { $0.end > $1.end }
        .prefix(maximumQueries))
    }
}

/// Queries only a few completed intervals and commits each result after the
/// asynchronous callback. It never participates in the workout save path.
@MainActor
final class AtriaRecentWorkoutStepEnricher {
    static let shared = AtriaRecentWorkoutStepEnricher()
    private static let queryTimeout: Duration = .seconds(3)

    private let pedometer = CMPedometer()
    private var runID: UUID?
    private var pendingQueryID: UUID?

    func enrich(store: SessionStore, now: Date = Date()) {
        guard runID == nil, CMPedometer.isStepCountingAvailable() else { return }
        let candidates = AtriaRecentWorkoutStepEnrichmentPolicy.candidates(
            from: store.confirmedWorkouts,
            now: now
        )
        guard !candidates.isEmpty else { return }
        let id = UUID()
        runID = id
        AtriaDebugLog("ATRIADBG workout_phone_step_enrichment status=started candidates=%d",
                      candidates.count)
        query(candidates, index: 0, runID: id, store: store)
    }

    private func query(
        _ candidates: [UserConfirmedWorkout],
        index: Int,
        runID: UUID,
        store: SessionStore
    ) {
        guard self.runID == runID else { return }
        guard candidates.indices.contains(index) else {
            self.runID = nil
            pendingQueryID = nil
            AtriaDebugLog("ATRIADBG workout_phone_step_enrichment status=finished candidates=%d",
                          candidates.count)
            return
        }
        let workout = candidates[index]
        let queryID = UUID()
        pendingQueryID = queryID
        pedometer.queryPedometerData(from: workout.start, to: workout.end) {
            [weak self, weak store] data, error in
            Task { @MainActor [weak self, weak store] in
                self?.finishQuery(queryID: queryID,
                                  data: error == nil ? data : nil,
                                  workout: workout,
                                  candidates: candidates,
                                  index: index,
                                  runID: runID,
                                  store: store)
            }
        }
        Task { @MainActor [weak self, weak store] in
            try? await Task.sleep(for: Self.queryTimeout)
            self?.finishQuery(queryID: queryID,
                              data: nil,
                              workout: workout,
                              candidates: candidates,
                              index: index,
                              runID: runID,
                              store: store)
        }
    }

    private func finishQuery(
        queryID: UUID,
        data: CMPedometerData?,
        workout: UserConfirmedWorkout,
        candidates: [UserConfirmedWorkout],
        index: Int,
        runID: UUID,
        store: SessionStore?
    ) {
        guard self.runID == runID, pendingQueryID == queryID else { return }
        pendingQueryID = nil
        if let data, data.numberOfSteps.intValue > 0, let store {
            let saved = store.enrichConfirmedWorkoutWithEstimatedPhoneSteps(
                id: workout.id,
                expectedStart: workout.start,
                expectedEnd: workout.end,
                count: max(0, data.numberOfSteps.intValue),
                capturedAt: data.endDate
            )
            AtriaDebugLog("ATRIADBG workout_phone_step_enrichment status=%@ workout=%@ steps=%d",
                          saved ? "saved" : "superseded",
                          workout.id,
                          max(0, data.numberOfSteps.intValue))
        } else {
            AtriaDebugLog("ATRIADBG workout_phone_step_enrichment status=query_unavailable workout=%@",
                          workout.id)
        }
        guard let store else {
            self.runID = nil
            return
        }
        query(candidates, index: index + 1, runID: runID, store: store)
    }
}
