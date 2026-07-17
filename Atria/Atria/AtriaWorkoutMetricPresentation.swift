import Foundation

/// Presentation-only confidence gate for workout-derived metrics. The saved
/// workout and its recorded window remain intact; this only prevents a tiny HR
/// fragment from being rendered with false numeric precision.
enum AtriaWorkoutMetricPresentation {
    static let minimumNumericCoveragePercent = 25

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

    static func heartRateState(_ workout: UserConfirmedWorkout) -> HeartRatePresentationState {
        guard workout.samples > 0, workout.avgHR > 0 else { return .unavailable }
        guard workout.samples >= 2,
              workout.peakHR > 0,
              workout.streamCoveragePercent >= minimumNumericCoveragePercent else {
            return .incomplete
        }
        return .complete
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
        // A substantial day score may include useful non-workout wear. Only
        // suppress tiny day-strain precision when its sole visible activity
        // evidence is one or more severely sparse confirmed workouts.
        guard strain < 1 else { return false }
        let dayStart = calendar.startOfDay(for: day)
        let sameDay = workouts.filter { workout in
            EventCivilTime.day(containing: workout.start,
                               eventTimeZoneIdentifier: workout.eventTimeZoneIdentifier,
                               outputCalendar: calendar) == dayStart
        }
        return !sameDay.isEmpty && sameDay.allSatisfy(metricsAreIncomplete)
    }

    static func strainText(_ workout: UserConfirmedWorkout) -> String {
        guard !metricsAreIncomplete(workout) else { return "Incomplete" }
        return workout.strain.map { String(format: "%.1f", $0) } ?? "--"
    }

    static func averageHeartRateText(_ workout: UserConfirmedWorkout) -> String {
        switch heartRateState(workout) {
        case .unavailable: return "No HR data"
        case .incomplete: return "Incomplete"
        case .complete: return "\(workout.avgHR)"
        }
    }

    static func peakHeartRateText(_ workout: UserConfirmedWorkout) -> String {
        switch heartRateState(workout) {
        case .unavailable: return "No HR data"
        case .incomplete: return "Incomplete"
        case .complete: return "\(workout.peakHR)"
        }
    }

    static func heartRateSummaryText(_ workout: UserConfirmedWorkout) -> String {
        switch heartRateState(workout) {
        case .unavailable: return "No HR data"
        case .incomplete: return "\(workout.streamCoveragePercent)% HR · Incomplete"
        case .complete: return "\(workout.avgHR) avg · \(workout.peakHR) peak"
        }
    }

    static func energyText(_ workout: UserConfirmedWorkout) -> String {
        guard !metricsAreIncomplete(workout) else { return "Incomplete" }
        return workout.activeEnergyKilocalories.map { "\(Int($0.rounded()))" } ?? "--"
    }

    static func compactStatus(_ workout: UserConfirmedWorkout) -> String {
        switch heartRateState(workout) {
        case .unavailable: return "No HR data"
        case .incomplete: return "\(workout.streamCoveragePercent)% HR · Incomplete"
        case .complete: return "\(workout.streamCoveragePercent)% HR"
        }
    }

    static func shareMetrics(_ workout: UserConfirmedWorkout) -> ShareMetrics {
        let incomplete = metricsAreIncomplete(workout)
        return ShareMetrics(strain: strainText(workout),
                            peakHeartRate: !incomplete && workout.peakHR > 0 ? "\(workout.peakHR)" : "--",
                            averageHeartRate: !incomplete && workout.avgHR > 0 ? "\(workout.avgHR)" : nil,
                            includesZoneMinutes: !incomplete)
    }
}
