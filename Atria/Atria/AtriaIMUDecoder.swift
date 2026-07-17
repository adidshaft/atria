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
    private static let candidateEndians: [Endian] = [.little, .big]

    private struct CandidateSummary {
        let offset: Int
        let endian: Endian
        let scale: Double
        let meanMagnitudeG: Double
        let stillnessRatio: Double
        let movementIntensity: Double
        let activityBursts: Int
        let gravityValidated: Bool
    }

    static func decode(payload: [UInt8]) -> DecodeResult? {
        guard payload.first == 0x33 else { return nil }
        return decodeBody(bytes: payload, bodyStart: 1)
    }

    static func decodeBody(_ body: [UInt8]) -> DecodeResult? {
        decodeBody(bytes: body, bodyStart: 0)
    }

    private static func decodeBody(bytes: [UInt8], bodyStart: Int) -> DecodeResult? {
        guard bodyStart <= bytes.count else { return nil }
        let bodyCount = bytes.count - bodyStart
        guard bodyCount >= 6 else { return nil }
        var best: CandidateSummary?
        for offset in 0...min(5, bodyCount - 6) {
            for endian in candidateEndians {
                for scale in candidateScales {
                    guard let result = summarizeCandidate(in: bytes,
                                                          bodyStart: bodyStart,
                                                          bodyCount: bodyCount,
                                                          offset: offset,
                                                          endian: endian,
                                                          scale: scale) else { continue }
                    if better(result, than: best) {
                        best = result
                    }
                }
            }
        }
        guard let best else { return nil }
        let samples = samples(in: bytes,
                              bodyStart: bodyStart,
                              bodyCount: bodyCount,
                              offset: best.offset,
                              endian: best.endian,
                              scale: best.scale)
        return DecodeResult(samples: samples,
                            offset: best.offset,
                            endian: best.endian,
                            scale: best.scale,
                            meanMagnitudeG: best.meanMagnitudeG,
                            stillnessRatio: best.stillnessRatio,
                            movementIntensity: best.movementIntensity,
                            activityBursts: best.activityBursts,
                            gravityValidated: best.gravityValidated)
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

    private static func samples(in bytes: [UInt8],
                                bodyStart: Int,
                                bodyCount: Int,
                                offset: Int,
                                endian: Endian,
                                scale: Double) -> [Sample] {
        var output: [Sample] = []
        output.reserveCapacity(max(0, (bodyCount - offset) / 6))
        var index = offset
        while index + 5 < bodyCount {
            let absoluteIndex = bodyStart + index
            let x = Double(readInt16(bytes, absoluteIndex, endian: endian)) / scale
            let y = Double(readInt16(bytes, absoluteIndex + 2, endian: endian)) / scale
            let z = Double(readInt16(bytes, absoluteIndex + 4, endian: endian)) / scale
            output.append(Sample(xG: x, yG: y, zG: z))
            index += 6
        }
        return output
    }

    private static func summarizeCandidate(in bytes: [UInt8],
                                           bodyStart: Int,
                                           bodyCount: Int,
                                           offset: Int,
                                           endian: Endian,
                                           scale: Double) -> CandidateSummary? {
        var index = offset
        var sampleCount = 0
        var magnitudeSum = 0.0
        var stillCount = 0
        var movementSum = 0.0
        var bursts = 0
        while index + 5 < bodyCount {
            let absoluteIndex = bodyStart + index
            let x = Double(readInt16(bytes, absoluteIndex, endian: endian)) / scale
            let y = Double(readInt16(bytes, absoluteIndex + 2, endian: endian)) / scale
            let z = Double(readInt16(bytes, absoluteIndex + 4, endian: endian)) / scale
            let magnitude = sqrt(x * x + y * y + z * z)
            let movement = abs(magnitude - 1.0)
            sampleCount += 1
            magnitudeSum += magnitude
            movementSum += movement
            if movement <= 0.08 {
                stillCount += 1
            }
            if magnitude >= 1.35 {
                bursts += 1
            }
            index += 6
        }
        guard sampleCount > 0 else { return nil }
        let count = Double(sampleCount)
        let mean = magnitudeSum / count
        let stillness = Double(stillCount) / count
        return CandidateSummary(offset: offset,
                                endian: endian,
                                scale: scale,
                                meanMagnitudeG: mean,
                                stillnessRatio: stillness,
                                movementIntensity: movementSum / count,
                                activityBursts: bursts,
                                gravityValidated: mean >= 0.85 && mean <= 1.15 && stillness >= 0.60)
    }

    private static func better(_ candidate: CandidateSummary, than current: CandidateSummary?) -> Bool {
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
