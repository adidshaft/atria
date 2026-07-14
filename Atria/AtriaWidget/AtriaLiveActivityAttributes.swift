import ActivityKit
import Foundation

enum AtriaLiveSensorAvailability: String, Codable, Hashable {
    case live
    case reconnecting
    case stale
    case unavailable
}

struct AtriaLiveActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var heartRate: Int
        var strain: Double
        var batteryLevel: Int
        var batteryChargeStatus: String
        var batteryChargeText: String
        var readingCount: Int
        var updatedAt: Date
        // Sensor-source freshness must not be re-stamped by unrelated battery,
        // UI or timer updates. Optional for activities from older builds.
        var heartRateCapturedAt: Date? = nil
        var sensorHasContact: Bool? = nil
        var heartRateAvailability: AtriaLiveSensorAvailability? = nil
        // Optional for in-flight activities created by an older app build.
        var activityName: String? = nil
        var activitySystemImage: String? = nil
        var heartRateZoneIndex: Int? = nil
        var heartRateZoneName: String? = nil
        var steps: Int? = nil
        var stepsAreEstimated: Bool? = nil
        var stepsCapturedAt: Date? = nil
        var stepsAvailability: AtriaLiveSensorAvailability? = nil
        // Daily strap steps are separate from workout-local steps. Keeping both
        // avoids comparing a session delta with the user's all-day goal.
        var dailySteps: Int? = nil
        var dailyStepsAreEstimated: Bool? = nil
        var dailyStepGoal: Int? = nil
        var workoutStrain: Double? = nil
        var targetWorkoutStrain: Double? = nil
        // Active energy is an optional, cumulative workout estimate. Keeping
        // it optional avoids inventing calories when the athlete profile is
        // incomplete and preserves decoding for activities from older builds.
        var activeEnergyKilocalories: Double? = nil
        // Optional for activities created before workout target zones were
        // surfaced on the Lock Screen and Dynamic Island.
        var targetLowerHeartRateZone: Int? = nil
        var targetUpperHeartRateZone: Int? = nil
        // Optional for Live Activities created before pause-aware timing.
        var isPaused: Bool? = nil
        var isEnding: Bool? = nil
        var timerAnchor: Date? = nil
        var elapsedDuration: TimeInterval? = nil
    }

    var startedAt: Date
}
