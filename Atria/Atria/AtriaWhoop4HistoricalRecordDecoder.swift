/// A lossless, side-effect-free decoder for an inner WHOOP 4.0 historical-data
/// payload. The input starts at packet type `0x2f`; transport framing and CRC
/// validation belong to the frame reassembler.
///
/// Protocol facts used here are independently documented by the MIT-licensed
/// OpenStrap protocol project:
/// https://github.com/OpenStrap/protocol/blob/main/lib/src/records.dart
/// Its v18 offset is also described independently at:
/// https://www.rusheelraj.com/blog/whoop/
/// This is an original Swift implementation; no source code was copied.
enum AtriaWhoop4HistoricalRecordDecoder {
    static let packetType: UInt8 = 0x2F

    static func decode(_ bytes: [UInt8],
                       origin: String = "whoop4.0-0x2f-inner") -> AtriaWhoop4HistoricalDecodeResult {
        let provenance = AtriaWhoop4HistoricalProvenance(origin: origin,
                                                         rawBytes: bytes)
        guard bytes.count >= 2 else {
            return .failure(.init(reason: .tooShort(actual: bytes.count, required: 2),
                                  provenance: provenance))
        }
        guard bytes[0] == packetType else {
            return .failure(.init(reason: .unexpectedPacketType(bytes[0]),
                                  provenance: provenance))
        }
        guard let layout = AtriaWhoop4HistoricalLayout(rawValue: bytes[1]) else {
            return .failure(.init(reason: .unsupportedVersion(bytes[1]),
                                  provenance: provenance))
        }

        switch layout {
        case .v25:
            return decodeV25(bytes, layout: layout, provenance: provenance)
        case .v7, .v9, .v12, .v18, .v24:
            return decodeFixedLayout(bytes, layout: layout, provenance: provenance)
        }
    }

    private static func decodeFixedLayout(
        _ bytes: [UInt8],
        layout: AtriaWhoop4HistoricalLayout,
        provenance: AtriaWhoop4HistoricalProvenance
    ) -> AtriaWhoop4HistoricalDecodeResult {
        // Gravity Z ends at byte 48. Requiring the complete fixed block prevents
        // truncated records from being partially promoted to physiology.
        guard bytes.count >= 48 else {
            return .failure(.init(reason: .tooShort(actual: bytes.count, required: 48),
                                  provenance: provenance))
        }

        let rrCount = Int(bytes[18])
        guard (0...4).contains(rrCount) else {
            return .failure(.init(reason: .invalidRRCount(rrCount),
                                  provenance: provenance))
        }
        guard let counter = u32LE(bytes, at: 3),
              let timestamp = u32LE(bytes, at: 7),
              let subsecond = u16LE(bytes, at: 11),
              let gx = f32LE(bytes, at: 36),
              let gy = f32LE(bytes, at: 40),
              let gz = f32LE(bytes, at: 44) else {
            return .failure(.init(reason: .malformedFixedFields,
                                  provenance: provenance))
        }
        let gravity = AtriaWhoop4HistoricalGravity(x: gx, y: gy, z: gz)
        guard gravity.isFinite else {
            return .failure(.init(reason: .nonFiniteGravity,
                                  provenance: provenance))
        }

        let rawRR = (0..<rrCount).compactMap { index in
            i16LE(bytes, at: 19 + index * 2).map(Int.init)
        }
        guard rawRR.count == rrCount else {
            return .failure(.init(reason: .malformedFixedFields,
                                  provenance: provenance))
        }

        let rawHeartRate = Int(bytes[layout.heartRateOffset])
        let physiology = AtriaWhoop4HistoricalPhysiology(
            decodedHeartRateBPM: rawHeartRate,
            decodedRRIntervalsMilliseconds: rawRR,
            gate: physiologyGate(heartRate: rawHeartRate,
                                 rrIntervals: rawRR,
                                 gravity: gravity,
                                 requiresGravityPlausibility: layout.isLegacyHROnlyLayout)
        )
        let record = AtriaWhoop4HistoricalRecord(
            layout: layout,
            timestampSeconds: timestamp,
            subsecond: subsecond,
            counter: counter,
            gravity: gravity,
            physiology: physiology,
            provenance: provenance
        )
        return .record(record)
    }

    private static func decodeV25(
        _ bytes: [UInt8],
        layout: AtriaWhoop4HistoricalLayout,
        provenance: AtriaWhoop4HistoricalProvenance
    ) -> AtriaWhoop4HistoricalDecodeResult {
        guard bytes.count >= 75 else {
            return .failure(.init(reason: .tooShort(actual: bytes.count, required: 75),
                                  provenance: provenance))
        }
        guard let counter = u32LE(bytes, at: 3),
              let timestamp = u32LE(bytes, at: 7),
              let rawGX = i16LE(bytes, at: 69),
              let rawGY = i16LE(bytes, at: 71),
              let rawGZ = i16LE(bytes, at: 73) else {
            return .failure(.init(reason: .malformedFixedFields,
                                  provenance: provenance))
        }

        let scale = 16_384.0
        let gravity = AtriaWhoop4HistoricalGravity(x: Double(rawGX) / scale,
                                                   y: Double(rawGY) / scale,
                                                   z: Double(rawGZ) / scale)
        // The only decoded sensor value in v25 is gravity. With no plausible
        // vector there is no safe decoded value to publish, so reject the row
        // while retaining every raw byte in the failure provenance.
        guard gravity.isFinite, (0.5...1.5).contains(gravity.magnitude) else {
            return .failure(.init(reason: .gravityMagnitudeOutOfRange(gravity.magnitude),
                                  provenance: provenance))
        }

        return .record(.init(layout: layout,
                             timestampSeconds: timestamp,
                             subsecond: nil,
                             counter: counter,
                             gravity: gravity,
                             physiology: nil,
                             provenance: provenance))
    }

    private static func physiologyGate(
        heartRate: Int,
        rrIntervals: [Int],
        gravity: AtriaWhoop4HistoricalGravity,
        requiresGravityPlausibility: Bool
    ) -> AtriaWhoop4HistoricalPhysiology.Gate {
        if heartRate == 0 { return .withheld(.offWrist) }
        guard (25...230).contains(heartRate) else {
            return .withheld(.heartRateOutOfRange(heartRate))
        }
        if let invalidRR = rrIntervals.first(where: { !(250...2_500).contains($0) }) {
            return .withheld(.rrIntervalOutOfRange(invalidRR))
        }
        if requiresGravityPlausibility,
           !(0.5...1.8).contains(gravity.magnitude) {
            return .withheld(.gravityMagnitudeOutOfRange(gravity.magnitude))
        }
        return .accepted
    }

    private static func u16LE(_ bytes: [UInt8], at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 1 < bytes.count else { return nil }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func i16LE(_ bytes: [UInt8], at offset: Int) -> Int16? {
        u16LE(bytes, at: offset).map { Int16(bitPattern: $0) }
    }

    private static func u32LE(_ bytes: [UInt8], at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 3 < bytes.count else { return nil }
        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    private static func f32LE(_ bytes: [UInt8], at offset: Int) -> Double? {
        u32LE(bytes, at: offset).map { Double(Float(bitPattern: $0)) }
    }
}

enum AtriaWhoop4HistoricalLayout: UInt8, Equatable, Sendable {
    case v7 = 7
    case v9 = 9
    case v12 = 12
    case v18 = 18
    case v24 = 24
    case v25 = 25

    /// The v7/v9/v18 heart-rate offsets are established protocol facts, but the
    /// complete layouts are not treated as trusted. Their metric values must
    /// therefore pass the additional gravity plausibility gate.
    fileprivate var heartRateOffset: Int {
        switch self {
        case .v7: 27
        case .v18: 14
        case .v9, .v12, .v24: 17
        case .v25: preconditionFailure("v25 contains no decoded heart-rate field")
        }
    }

    fileprivate var isLegacyHROnlyLayout: Bool {
        self == .v7 || self == .v9 || self == .v18
    }
}

struct AtriaWhoop4HistoricalRecord: Equatable, Sendable {
    let layout: AtriaWhoop4HistoricalLayout
    let timestampSeconds: UInt32
    let subsecond: UInt16?
    let counter: UInt32
    let gravity: AtriaWhoop4HistoricalGravity
    /// Nil for v25 by design: that layout has no safely decoded HR/RR fields.
    let physiology: AtriaWhoop4HistoricalPhysiology?
    let provenance: AtriaWhoop4HistoricalProvenance
}

struct AtriaWhoop4HistoricalGravity: Equatable, Sendable {
    let x: Double
    let y: Double
    let z: Double

    var magnitude: Double {
        (x * x + y * y + z * z).squareRoot()
    }

    fileprivate var isFinite: Bool {
        x.isFinite && y.isFinite && z.isFinite && magnitude.isFinite
    }
}

struct AtriaWhoop4HistoricalPhysiology: Equatable, Sendable {
    enum Gate: Equatable, Sendable {
        case accepted
        case withheld(WithheldReason)
    }

    enum WithheldReason: Equatable, Sendable {
        case offWrist
        case heartRateOutOfRange(Int)
        case rrIntervalOutOfRange(Int)
        case gravityMagnitudeOutOfRange(Double)
    }

    let decodedHeartRateBPM: Int
    let decodedRRIntervalsMilliseconds: [Int]
    let gate: Gate

    /// The only HR value consumers may use for metrics.
    var acceptedHeartRateBPM: Int? {
        gate == .accepted ? decodedHeartRateBPM : nil
    }

    /// Nil means the complete physiological row was withheld. An empty array is
    /// a valid accepted row containing no beat boundary in this one-second record.
    var acceptedRRIntervalsMilliseconds: [Int]? {
        gate == .accepted ? decodedRRIntervalsMilliseconds : nil
    }
}

struct AtriaWhoop4HistoricalProvenance: Equatable, Sendable {
    let origin: String
    let rawBytes: [UInt8]

    var packetType: UInt8? { rawBytes.first }
    var layoutVersion: UInt8? { rawBytes.count > 1 ? rawBytes[1] : nil }
    var rawHex: String {
        rawBytes.map { String($0, radix: 16).leftPadded(to: 2, with: "0") }.joined()
    }
}

enum AtriaWhoop4HistoricalDecodeResult: Equatable, Sendable {
    case record(AtriaWhoop4HistoricalRecord)
    case failure(AtriaWhoop4HistoricalDecodeFailure)

    var decodedRecord: AtriaWhoop4HistoricalRecord? {
        guard case .record(let record) = self else { return nil }
        return record
    }

    var decodeFailure: AtriaWhoop4HistoricalDecodeFailure? {
        guard case .failure(let failure) = self else { return nil }
        return failure
    }
}

struct AtriaWhoop4HistoricalDecodeFailure: Equatable, Sendable {
    enum Reason: Equatable, Sendable {
        case tooShort(actual: Int, required: Int)
        case unexpectedPacketType(UInt8)
        case unsupportedVersion(UInt8)
        case invalidRRCount(Int)
        case malformedFixedFields
        case nonFiniteGravity
        case gravityMagnitudeOutOfRange(Double)
    }

    let reason: Reason
    let provenance: AtriaWhoop4HistoricalProvenance
}

private extension String {
    func leftPadded(to length: Int, with character: Character) -> String {
        guard count < length else { return self }
        return String(repeating: String(character), count: length - count) + self
    }
}
