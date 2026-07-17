import Foundation

/// Presentation-only confidence gate for workout-derived metrics. The saved
/// workout and its recorded window remain intact; this only prevents a tiny HR
/// fragment from being rendered with false numeric precision.
enum AtriaWorkoutMetricPresentation {
    static let minimumNumericCoveragePercent = 25

    struct ShareMetrics: Equatable {
        let strain: String
        let peakHeartRate: String
        let averageHeartRate: String?
        let includesZoneMinutes: Bool
    }

    static func metricsAreIncomplete(_ workout: UserConfirmedWorkout) -> Bool {
        workout.samples < 2
            || workout.avgHR <= 0
            || workout.streamCoveragePercent < minimumNumericCoveragePercent
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
        metricsAreIncomplete(workout) ? "Incomplete" : "\(workout.avgHR)"
    }

    static func energyText(_ workout: UserConfirmedWorkout) -> String {
        guard !metricsAreIncomplete(workout) else { return "Incomplete" }
        return workout.activeEnergyKilocalories.map { "\(Int($0.rounded()))" } ?? "--"
    }

    static func compactStatus(_ workout: UserConfirmedWorkout) -> String {
        "\(workout.streamCoveragePercent)% HR · Incomplete"
    }

    static func shareMetrics(_ workout: UserConfirmedWorkout) -> ShareMetrics {
        let incomplete = metricsAreIncomplete(workout)
        return ShareMetrics(strain: strainText(workout),
                            peakHeartRate: !incomplete && workout.peakHR > 0 ? "\(workout.peakHR)" : "--",
                            averageHeartRate: !incomplete && workout.avgHR > 0 ? "\(workout.avgHR)" : nil,
                            includesZoneMinutes: !incomplete)
    }
}
