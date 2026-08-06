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

    /// A mostly observed workout with one material gap still has useful
    /// measured values. Render them as lower bounds/observations rather than
    /// either claiming false precision or throwing the measurements away.
    private static func mayShowObservedLowerBound(
        _ workout: UserConfirmedWorkout
    ) -> Bool {
        hasMaterialStreamGap(workout)
            && workout.samples >= 2
            && workout.avgHR > 0
            && workout.peakHR > 0
            && workout.streamCoveragePercent >= minimumNumericCoveragePercent
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
        guard end > start else { return false }
        _ = strain
        return workouts.contains { workout in
            workout.end > start
                && workout.start < end
                && metricsAreIncomplete(workout)
        }
    }

    static func strainText(_ workout: UserConfirmedWorkout) -> String {
        if metricsAreIncomplete(workout) {
            guard mayShowObservedLowerBound(workout), let strain = workout.strain else {
                return "Incomplete"
            }
            return "≥ \(String(format: "%.1f", strain))"
        }
        return workout.strain.map { String(format: "%.1f", $0) } ?? "--"
    }

    static func averageHeartRateText(_ workout: UserConfirmedWorkout) -> String {
        switch heartRateState(workout) {
        case .unavailable: return "No HR data"
        case .incomplete:
            return mayShowObservedLowerBound(workout)
                ? "\(workout.avgHR) observed"
                : "Incomplete"
        case .complete: return "\(workout.avgHR)"
        }
    }

    static func peakHeartRateText(_ workout: UserConfirmedWorkout) -> String {
        switch heartRateState(workout) {
        case .unavailable: return "No HR data"
        case .incomplete:
            return mayShowObservedLowerBound(workout)
                ? "\(workout.peakHR) observed"
                : "Incomplete"
        case .complete: return "\(workout.peakHR)"
        }
    }

    static func heartRateSummaryText(_ workout: UserConfirmedWorkout) -> String {
        switch heartRateState(workout) {
        case .unavailable: return "No HR data"
        case .incomplete:
            return mayShowObservedLowerBound(workout)
                ? "\(workout.streamCoveragePercent)% HR · Partial"
                : "\(workout.streamCoveragePercent)% HR · Incomplete"
        case .complete: return "\(workout.avgHR) avg · \(workout.peakHR) peak"
        }
    }

    static func energyText(_ workout: UserConfirmedWorkout) -> String {
        if metricsAreIncomplete(workout) {
            guard mayShowObservedLowerBound(workout),
                  let energy = workout.activeEnergyKilocalories else {
                return "Incomplete"
            }
            return "≥ \(Int(energy.rounded()))"
        }
        return workout.activeEnergyKilocalories.map { "\(Int($0.rounded()))" } ?? "--"
    }

    static func compactStatus(_ workout: UserConfirmedWorkout) -> String {
        switch heartRateState(workout) {
        case .unavailable: return "No HR data"
        case .incomplete:
            return mayShowObservedLowerBound(workout)
                ? "\(workout.streamCoveragePercent)% HR · Partial"
                : "\(workout.streamCoveragePercent)% HR · Incomplete"
        case .complete: return "\(workout.streamCoveragePercent)% HR"
        }
    }

    static func shareMetrics(_ workout: UserConfirmedWorkout) -> ShareMetrics {
        let incomplete = metricsAreIncomplete(workout)
        let observed = incomplete && mayShowObservedLowerBound(workout)
        return ShareMetrics(strain: strainText(workout),
                            peakHeartRate: (!incomplete || observed) && workout.peakHR > 0
                                ? (observed ? "\(workout.peakHR) observed" : "\(workout.peakHR)")
                                : "--",
                            averageHeartRate: (!incomplete || observed) && workout.avgHR > 0
                                ? (observed ? "\(workout.avgHR) observed" : "\(workout.avgHR)")
                                : nil,
                            includesZoneMinutes: !incomplete)
    }
}
