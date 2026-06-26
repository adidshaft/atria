import Foundation

enum AtriaStrapStepResearch {
    struct Result: Equatable {
        let steps: Int
        let peaks: Int
        let state: String
    }

    static func estimate(samples: [AtriaIMUDecoder.Sample], sampleRateHz: Double?) -> Result {
        guard samples.count >= 3 else {
            return Result(steps: 0, peaks: 0, state: "research_unvalidated")
        }
        let refractorySamples = max(2, Int(((sampleRateHz ?? 25) * 0.25).rounded()))
        var lastPeakIndex = -refractorySamples
        var peaks = 0
        for index in 1..<(samples.count - 1) {
            let previous = samples[index - 1].magnitudeG
            let current = samples[index].magnitudeG
            let next = samples[index + 1].magnitudeG
            guard current >= 1.12,
                  current >= previous,
                  current > next,
                  index - lastPeakIndex >= refractorySamples else {
                continue
            }
            peaks += 1
            lastPeakIndex = index
        }
        return Result(steps: peaks, peaks: peaks, state: "research_unvalidated")
    }

    static func agreement(strapSteps: Int, phoneSteps: Int?) -> Double? {
        guard strapSteps > 0, let phoneSteps, phoneSteps > 0 else { return nil }
        let denominator = Double(max(strapSteps, phoneSteps))
        return 1.0 - (abs(Double(strapSteps - phoneSteps)) / denominator)
    }
}
