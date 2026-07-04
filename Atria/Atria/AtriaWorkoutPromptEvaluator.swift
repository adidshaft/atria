import Foundation

enum AtriaWorkoutPromptEvaluator {
    static let minimumSustainedSamples = 480
    static let minimumBPMOverRest = 25
    static let zoneLookbackSeconds: TimeInterval = 6 * 60
    static let zoneMinimumSamples = 240
    static let zoneMinimumIndex = 3
    static let cooldown: TimeInterval = 45 * 60

    struct Result: Equatable {
        let shouldPrompt: Bool
        let sustainedPath: Bool
        let zonePath: Bool
        let elevatedSamples: Int
        let zoneSamples: Int
    }

    static func evaluate(samples: [HRSample],
                         currentHeartRate: Int,
                         restingHeartRate: Int,
                         maxHeartRate: Int,
                         now: Date = Date()) -> Result {
        let referenceDate = samples.last?.t ?? now
        let sustainedStart = referenceDate.addingTimeInterval(-TimeInterval(minimumSustainedSamples))
        let elevatedSamples = samples.filter {
            $0.t >= sustainedStart && $0.bpm - restingHeartRate >= minimumBPMOverRest
        }.count
        let currentElevated = currentHeartRate - restingHeartRate >= minimumBPMOverRest
        let sustainedPath = elevatedSamples >= minimumSustainedSamples && currentElevated

        let zoneStart = referenceDate.addingTimeInterval(-zoneLookbackSeconds)
        let zoneSamples = samples.filter { sample in
            guard sample.t >= zoneStart,
                  let zone = Metrics.heartRateZone(bpm: sample.bpm,
                                                   rest: restingHeartRate,
                                                   max: maxHeartRate) else {
                return false
            }
            return zone.index >= zoneMinimumIndex
        }.count
        let zonePath = zoneSamples >= zoneMinimumSamples

        return Result(shouldPrompt: sustainedPath || zonePath,
                      sustainedPath: sustainedPath,
                      zonePath: zonePath,
                      elevatedSamples: elevatedSamples,
                      zoneSamples: zoneSamples)
    }

    static func isInCooldown(dismissedUntil: Date?, now: Date = Date()) -> Bool {
        guard let dismissedUntil else { return false }
        return dismissedUntil > now
    }
}
