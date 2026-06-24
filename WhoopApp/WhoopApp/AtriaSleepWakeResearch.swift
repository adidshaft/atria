import Foundation

enum AtriaSleepWakeResearch {
    struct Result: Equatable {
        let state: String
        let confidence: String
        let reason: String
    }

    static func classify(duration: TimeInterval,
                         averageHR: Int,
                         restingHR: Int,
                         imuStillnessRatio: Double?,
                         imuMovementIntensity: Double?,
                         strapSteps: Int?) -> Result {
        guard duration >= 20 * 60 else {
            return Result(state: "learning", confidence: "none", reason: "short_window")
        }
        guard let imuStillnessRatio, let imuMovementIntensity else {
            return Result(state: "learning", confidence: "none", reason: "imu_missing")
        }
        let lowMotion = imuStillnessRatio >= 0.72 && imuMovementIntensity <= 0.18
        let lowHR = averageHR <= restingHR + 18
        let lowSteps = (strapSteps ?? 0) <= max(8, Int(duration / 600))
        if lowMotion && lowHR && lowSteps {
            return Result(state: "sleep_research", confidence: "research", reason: "low_motion_low_hr")
        }
        return Result(state: "wake_research", confidence: "research", reason: "motion_or_hr_active")
    }
}
