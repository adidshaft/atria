import Foundation

enum AtriaStrapStepResearch {
    // Peak detection remains useful for decoder research, but it must not become
    // a user metric until a fixed strap-generation layout is reference-validated.
    static let validatedDecoderAvailable = false

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
        return Result(steps: validatedDecoderAvailable ? peaks : 0,
                      peaks: peaks,
                      state: validatedDecoderAvailable ? "validated" : "research_unvalidated")
    }
}
