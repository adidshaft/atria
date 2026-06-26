import Foundation

enum AtriaIMUDecoder {
    enum Endian: String, Equatable {
        case little
        case big
    }

    struct Sample: Equatable {
        let xG: Double
        let yG: Double
        let zG: Double

        var magnitudeG: Double {
            sqrt(xG * xG + yG * yG + zG * zG)
        }
    }

    struct DecodeResult: Equatable {
        let samples: [Sample]
        let offset: Int
        let endian: Endian
        let scale: Double
        let meanMagnitudeG: Double
        let stillnessRatio: Double
        let movementIntensity: Double
        let activityBursts: Int
        let gravityValidated: Bool

        var validationState: String {
            gravityValidated ? "gravity_validated" : "research_unvalidated"
        }
    }

    private static let candidateScales: [Double] = [16_384, 8_192, 4_096, 2_048, 1_024]

    static func decode(payload: [UInt8]) -> DecodeResult? {
        guard payload.first == 0x33 else { return nil }
        return decodeBody(Array(payload.dropFirst()))
    }

    static func decodeBody(_ body: [UInt8]) -> DecodeResult? {
        guard body.count >= 6 else { return nil }
        var best: DecodeResult?
        for offset in 0...min(5, body.count - 6) {
            for endian in [Endian.little, .big] {
                for scale in candidateScales {
                    let samples = samples(in: body, offset: offset, endian: endian, scale: scale)
                    guard !samples.isEmpty else { continue }
                    let result = summarize(samples: samples, offset: offset, endian: endian, scale: scale)
                    if better(result, than: best) {
                        best = result
                    }
                }
            }
        }
        return best
    }

    static func syntheticRestPayload(scale: Int = 16_384) -> [UInt8] {
        [0x33] + int16LE(0) + int16LE(0) + int16LE(scale)
    }

    static func syntheticShakePayload(scale: Int = 16_384) -> [UInt8] {
        [0x33] + int16LE(scale * 2) + int16LE(0) + int16LE(0)
    }

    static func selfTestPassed() -> Bool {
        guard let rest = decode(payload: syntheticRestPayload()),
              let shake = decode(payload: syntheticShakePayload()) else {
            return false
        }
        return abs(rest.meanMagnitudeG - 1.0) <= 0.05
            && abs(shake.meanMagnitudeG - 2.0) <= 0.10
            && rest.gravityValidated
            && !shake.gravityValidated
    }

    private static func samples(in body: [UInt8],
                                offset: Int,
                                endian: Endian,
                                scale: Double) -> [Sample] {
        var output: [Sample] = []
        var index = offset
        while index + 5 < body.count {
            let x = Double(readInt16(body, index, endian: endian)) / scale
            let y = Double(readInt16(body, index + 2, endian: endian)) / scale
            let z = Double(readInt16(body, index + 4, endian: endian)) / scale
            output.append(Sample(xG: x, yG: y, zG: z))
            index += 6
        }
        return output
    }

    private static func summarize(samples: [Sample],
                                  offset: Int,
                                  endian: Endian,
                                  scale: Double) -> DecodeResult {
        let magnitudes = samples.map(\.magnitudeG)
        let mean = magnitudes.reduce(0, +) / Double(magnitudes.count)
        let still = magnitudes.filter { abs($0 - 1.0) <= 0.08 }.count
        let movement = magnitudes.map { abs($0 - 1.0) }.reduce(0, +) / Double(magnitudes.count)
        let bursts = magnitudes.filter { $0 >= 1.35 }.count
        return DecodeResult(samples: samples,
                            offset: offset,
                            endian: endian,
                            scale: scale,
                            meanMagnitudeG: mean,
                            stillnessRatio: Double(still) / Double(magnitudes.count),
                            movementIntensity: movement,
                            activityBursts: bursts,
                            gravityValidated: mean >= 0.85 && mean <= 1.15 && Double(still) / Double(magnitudes.count) >= 0.60)
    }

    private static func better(_ candidate: DecodeResult, than current: DecodeResult?) -> Bool {
        guard let current else { return true }
        let candidateScore = abs(candidate.meanMagnitudeG - 1.0) + (1.0 - candidate.stillnessRatio)
        let currentScore = abs(current.meanMagnitudeG - 1.0) + (1.0 - current.stillnessRatio)
        return candidateScore < currentScore
    }

    private static func readInt16(_ bytes: [UInt8], _ offset: Int, endian: Endian) -> Int16 {
        let value: UInt16
        switch endian {
        case .little:
            value = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
        case .big:
            value = (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
        }
        return Int16(bitPattern: value)
    }

    private static func int16LE(_ value: Int) -> [UInt8] {
        let clamped = Int16(max(Int(Int16.min), min(Int(Int16.max), value)))
        let bitPattern = UInt16(bitPattern: clamped)
        return [UInt8(bitPattern & 0xff), UInt8((bitPattern >> 8) & 0xff)]
    }
}
