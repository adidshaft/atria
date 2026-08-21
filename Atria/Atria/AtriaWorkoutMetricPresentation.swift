import Foundation

/// Presentation-only confidence gate for workout-derived metrics. The saved
/// workout and its recorded window remain intact; this only prevents a tiny HR
/// fragment from being rendered with false numeric precision.
enum AtriaWorkoutMetricPresentation {
    /// Keep every workout surface aligned with the activity monitor and
    /// detector qualification gate. Coverage below 75% is useful evidence,
    /// but it is not a complete workout and must not publish precise derived
    /// strain, zone, average-HR, peak-HR, or energy metrics as if it were.
    static let minimumNumericCoveragePercent = 75

    enum HeartRatePresentationState: Equatable {
        case unavailable
        case incomplete
        case complete
    }

    /// The concrete evidence gap that turns accumulated strain into a lower
    /// bound. Keep this structured so Today, Vitals, the detail sheet, and
    /// accessibility all describe the same cause instead of inferring it from
    /// a generic confidence string.
    enum StrainLimitation: Equatable {
        case workoutHeartRate(label: String, coveragePercent: Int)
        case dayWear(coveragePercent: Int)
        case incompleteEvidence

        var compactState: String {
            switch self {
            case .workoutHeartRate: return "Workout HR incomplete"
            case .dayWear: return "Day HR incomplete"
            case .incompleteEvidence: return "Strain data incomplete"
            }
        }

        var explanation: String {
            switch self {
            case .workoutHeartRate(let label, let coveragePercent):
                return "\(label) captured \(coveragePercent)% of workout heart rate. Today's strain is a lower bound."
            case .dayWear(let coveragePercent):
                return "Heart-rate coverage is \(coveragePercent)% for this physiological day. Today's strain is a lower bound."
            case .incompleteEvidence:
                return "Some heart-rate evidence is incomplete. Today's strain is a lower bound."
            }
        }

        var improvementHint: String {
            switch self {
            case .workoutHeartRate:
                return "Keep the strap connected through the full workout."
            case .dayWear:
                return "Keep the strap connected for more of the day."
            case .incompleteEvidence:
                return "Keep the strap connected while Atria records heart rate."
            }
        }

        var accessibilityText: String {
            switch self {
            case .workoutHeartRate(let label, let coveragePercent):
                return "\(label) workout heart rate \(coveragePercent) percent."
            case .dayWear(let coveragePercent):
                return "Physiological day heart-rate coverage \(coveragePercent) percent."
            case .incompleteEvidence:
                return "Heart-rate evidence is incomplete."
            }
        }
    }

    /// One shared, pure UI contract for every partial-Strain surface. Partial
    /// evidence does not prove that a sync is queued or still running, so none
    /// of this copy promises that finishing sync will change the score.
    struct StrainLimitationPresentation: Equatable {
        let compactState: String
        let explanation: String
        let improvementHint: String

        var detailText: String {
            "\(explanation) \(improvementHint)"
        }

        var targetContext: String {
            "lower-bound strain"
        }

        var accessibilityText: String {
            "\(compactState). \(detailText)"
        }
    }

    static func strainLimitationPresentation(
        _ limitation: StrainLimitation
    ) -> StrainLimitationPresentation {
        StrainLimitationPresentation(
            compactState: limitation.compactState,
            explanation: limitation.explanation,
            improvementHint: limitation.improvementHint
        )
    }

    struct ShareMetrics: Equatable {
        let strain: String
        let peakHeartRate: String
        let averageHeartRate: String?
        let includesZoneMinutes: Bool
    }

    /// Presentation-only fragment gate (2026-07-31, device review): a manual
    /// live workout the user started and stopped within one minute is an
    /// accidental tap, not a training session. Rendering it produced rows like
    /// "Walking · 0.0 strain · 54", which read as broken data. The stored
    /// record is untouched (analytics, export, and recovery still see it);
    /// only list/summary surfaces drop it.
    static let minimumPresentableLiveWorkoutSeconds: TimeInterval = 60

    static func isAccidentalLiveFragment(_ workout: UserConfirmedWorkout) -> Bool {
        workout.source == "live_workout_window"
            && workout.duration < minimumPresentableLiveWorkoutSeconds
    }

    /// Shared list filter for every workout list/summary surface (Activity
    /// list, overview workout rows, History day sheets, chart markers).
    static func presentableWorkouts(
        _ workouts: [UserConfirmedWorkout]
    ) -> [UserConfirmedWorkout] {
        workouts.filter { !isAccidentalLiveFragment($0) }
    }

    static func heartRateState(_ workout: UserConfirmedWorkout) -> HeartRatePresentationState {
        guard workout.samples > 0, workout.avgHR > 0 else { return .unavailable }
        guard workout.samples >= 2,
              workout.peakHR > 0,
              workout.streamCoveragePercent >= minimumNumericCoveragePercent,
              !hasMaterialStreamGap(workout) else {
            return .incomplete
        }
        return .complete
    }

    /// Coverage percentage alone can hide one long continuous outage. The
    /// detector records that condition explicitly; presentation must preserve
    /// it even when the remaining samples happen to exceed the numeric gate.
    static func hasMaterialStreamGap(_ workout: UserConfirmedWorkout) -> Bool {
        workout.reason.localizedCaseInsensitiveContains("stream_gap")
    }

    static func hasHeartRateData(_ workout: UserConfirmedWorkout) -> Bool {
        heartRateState(workout) != .unavailable
    }

    static func metricsAreIncomplete(_ workout: UserConfirmedWorkout) -> Bool {
        heartRateState(workout) != .complete
    }

    static func dayStrainIsIncomplete(day: Date,
                                      strain: Double,
                                      workouts: [UserConfirmedWorkout],
                                      calendar: Calendar = .current) -> Bool {
        // A day score can include useful all-day wear, but any contributing
        // workout with sparse HR makes the accumulated load a lower bound.
        // One dense workout cannot prove the load missing from another sparse
        // workout. Preserve the number as `≥ n.n`; do not turn mixed-quality
        // evidence into apparent precision.
        _ = strain
        let dayStart = calendar.startOfDay(for: day)
        let sameDay = workouts.filter { workout in
            EventCivilTime.day(containing: workout.start,
                               eventTimeZoneIdentifier: workout.eventTimeZoneIdentifier,
                               outputCalendar: calendar) == dayStart
        }
        return sameDay.contains(where: metricsAreIncomplete)
    }

    /// Current strain is accumulated over a physiological wake-to-wake window,
    /// which can cross civil midnight. Qualify that value against every workout
    /// that contributed time to the same window; the civil-day helper above
    /// remains the authority for dated history.
    static func cycleStrainIsIncomplete(start: Date,
                                        end: Date,
                                        strain: Double,
                                        workouts: [UserConfirmedWorkout]) -> Bool {
        _ = strain
        return cycleStrainLimitation(start: start,
                                     end: end,
                                     workouts: workouts) != nil
    }

    /// Prefer a workout-specific cause over generic day wear because it is the
    /// actionable source of the lower bound even when all-day HR coverage is
    /// otherwise complete. The lowest-coverage overlapping workout is selected
    /// deterministically when more than one workout is incomplete.
    static func cycleStrainLimitation(
        start: Date,
        end: Date,
        workouts: [UserConfirmedWorkout]
    ) -> StrainLimitation? {
        guard end > start else { return nil }
        let incomplete = workouts
            .filter { workout in
                workout.end > start
                    && workout.start < end
                    && metricsAreIncomplete(workout)
            }
            .sorted { lhs, rhs in
                if lhs.streamCoveragePercent != rhs.streamCoveragePercent {
                    return lhs.streamCoveragePercent < rhs.streamCoveragePercent
                }
                if lhs.start != rhs.start { return lhs.start < rhs.start }
                return lhs.id < rhs.id
            }
        guard let workout = incomplete.first else { return nil }
        return .workoutHeartRate(
            label: workout.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Workout"
                : workout.label,
            coveragePercent: min(max(workout.streamCoveragePercent, 0), 100)
        )
    }

    /// Resolves the one explanation shown for a partial current-cycle score.
    /// Workout gaps win over day wear so 100% day coverage never produces the
    /// false claim that the strap was worn for only part of the day.
    static func strainLimitation(
        start: Date,
        end: Date,
        workouts: [UserConfirmedWorkout],
        dayWearCoverageFraction: Double?
    ) -> StrainLimitation? {
        if let workout = cycleStrainLimitation(start: start,
                                               end: end,
                                               workouts: workouts) {
            return workout
        }
        guard let dayWearCoverageFraction,
              dayWearCoverageFraction.isFinite,
              dayWearCoverageFraction < 0.95 else {
            return nil
        }
        return .dayWear(
            coveragePercent: min(max(Int((dayWearCoverageFraction * 100).rounded()), 0), 100)
        )
    }

    // 2026-08-21 user directive ("no need to say honest things — do the best
    // with what we have"): show the measured value rather than gating workout
    // metrics to "Incomplete"/"≥ observed". Partial-coverage numbers are still a
    // lower bound, and they upgrade automatically as buffered strap history
    // drains and the workout is re-scored (confirmedWorkoutNeedsHeartRateArchive
    // Rehydration). Only a genuine absence of heart rate still says "No HR data".
    static func strainText(_ workout: UserConfirmedWorkout) -> String {
        workout.strain.map { String(format: "%.1f", $0) } ?? "--"
    }

    static func averageHeartRateText(_ workout: UserConfirmedWorkout) -> String {
        switch heartRateState(workout) {
        case .unavailable: return "No HR data"
        case .incomplete, .complete: return "\(workout.avgHR)"
        }
    }

    static func peakHeartRateText(_ workout: UserConfirmedWorkout) -> String {
        // A zero peak alongside a real average is corrupt evidence, not a low
        // reading — never surface "0" as a peak.
        guard workout.peakHR > 0 else { return "No HR data" }
        switch heartRateState(workout) {
        case .unavailable: return "No HR data"
        case .incomplete, .complete: return "\(workout.peakHR)"
        }
    }

    static func heartRateSummaryText(_ workout: UserConfirmedWorkout) -> String {
        switch heartRateState(workout) {
        case .unavailable: return "No HR data"
        case .incomplete, .complete:
            return workout.peakHR > 0
                ? "\(workout.avgHR) avg · \(workout.peakHR) peak"
                : "\(workout.avgHR) avg"
        }
    }

    static func energyText(_ workout: UserConfirmedWorkout) -> String {
        workout.activeEnergyKilocalories.map { "\(Int($0.rounded()))" } ?? "--"
    }

    static func compactStatus(_ workout: UserConfirmedWorkout) -> String {
        switch heartRateState(workout) {
        case .unavailable: return "No HR data"
        case .incomplete, .complete: return "\(workout.streamCoveragePercent)% HR"
        }
    }

    static func shareMetrics(_ workout: UserConfirmedWorkout) -> ShareMetrics {
        ShareMetrics(strain: strainText(workout),
                     peakHeartRate: workout.peakHR > 0 ? "\(workout.peakHR)" : "--",
                     averageHeartRate: workout.avgHR > 0 ? "\(workout.avgHR)" : nil,
                     // Zone-minute breakdowns still need dense coverage to be
                     // meaningful, so keep those gated to a complete stream.
                     includesZoneMinutes: heartRateState(workout) == .complete)
    }
}
