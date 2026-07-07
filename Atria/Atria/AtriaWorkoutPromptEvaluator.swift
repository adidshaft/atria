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
        let zoneStart = referenceDate.addingTimeInterval(-zoneLookbackSeconds)

        // Perf (2026-07-07, device-reported lag): this runs on the main thread
        // every ~750ms while connected on the home tab, and `samples` is the
        // whole live session — ~80k after a 13.8h wear day. Only the trailing
        // ~8 min ever matter (samples are time-ascending, as `referenceDate =
        // samples.last?.t` already assumes), so walk the tail and stop at the
        // earliest cutoff instead of two full-array scans. Counts are
        // order-independent, so this is byte-identical to the old filters;
        // if a tail were ever out of order it could only under-count -> a
        // missed prompt, never a false workout (fail closed).
        let earliestCutoff = min(sustainedStart, zoneStart)
        var elevatedSamples = 0
        var zoneSamples = 0
        for sample in samples.reversed() {
            if sample.t < earliestCutoff { break }
            if sample.t >= sustainedStart, sample.bpm - restingHeartRate >= minimumBPMOverRest {
                elevatedSamples += 1
            }
            if sample.t >= zoneStart,
               let zone = Metrics.heartRateZone(bpm: sample.bpm,
                                                rest: restingHeartRate,
                                                max: maxHeartRate),
               zone.index >= zoneMinimumIndex {
                zoneSamples += 1
            }
        }
        let currentElevated = currentHeartRate - restingHeartRate >= minimumBPMOverRest
        let sustainedPath = elevatedSamples >= minimumSustainedSamples && currentElevated
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
