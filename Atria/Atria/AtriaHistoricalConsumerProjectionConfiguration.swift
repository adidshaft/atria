import Foundation

/// One configuration value shared by historical receipt publication and the
/// verified consumer reader. Keeping both sides on the exact same value type
/// prevents otherwise-identical production call sites from drifting and
/// invalidating the configuration-bound receipt digest.
struct AtriaHistoricalConsumerProjectionConfiguration: Sendable {
    let activity: AtriaHistoricalActivityProjection.Configuration
    let daily: AtriaHistoricalDailyConsumerProjection.Configuration
    let sleep: AtriaHistoricalSleepProjection.Configuration
    let workout: AtriaHistoricalWorkoutProjection.Configuration

    /// Canonical production policy. Callers provide only athlete- and
    /// locale-specific inputs; all algorithm thresholds live here.
    static func production(
        restingHeartRate: Int,
        maximumHeartRate: Int,
        timeZoneIdentifier: String
    ) -> Self {
        .init(
            activity: .init(restingHeartRate: restingHeartRate,
                            maximumHeartRate: maximumHeartRate,
                            timeZoneIdentifier: timeZoneIdentifier),
            daily: .init(timeZoneIdentifier: timeZoneIdentifier,
                         dayBoundaryPolicyVersion: "gregorian-civil-midnight-v1"),
            sleep: .init(timeZoneIdentifier: timeZoneIdentifier,
                         minimumDurationSeconds: 2 * 60 * 60,
                         minimumValidatedMotionCoverage: 0.80,
                         stillnessThreshold: 0.80,
                         maximumMovementIntensity: 0.08),
            workout: .init(restingHeartRate: restingHeartRate,
                           maximumHeartRate: maximumHeartRate,
                           timeZoneIdentifier: timeZoneIdentifier,
                           minimumDurationMinutes: 10,
                           minimumHeartRateCoverage: 0.80)
        )
    }
}
