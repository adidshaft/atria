import Foundation

/// Versioned long-term facts derived from one immutable raw history chunk.
///
/// This is deliberately an aggregate truth model, not reconstructed telemetry.
/// Readers must never manufacture raw samples from these rows. A future edit
/// that needs expired raw input reports `raw_expired` unless a materialized,
/// versioned projection receipt already proves that result.
struct AtriaHistoricalAggregateChunk: Codable, Equatable, Sendable {
    static let currentSchema = 2

    struct Source: Codable, Equatable, Sendable {
        let chunkID: String
        let rawSHA256: String
        let rawByteCount: UInt64
        let rawRowCount: Int
        let firstTimestamp: Date
        let lastTimestamp: Date
        let decoderSchema: Int
        let validatedLayouts: [String]
    }

    struct HeartRateMinute: Codable, Equatable, Sendable {
        let minuteStart: Date
        let sampleCount: Int
        let sumBPM: Int64
        let minimumBPM: Int
        let maximumBPM: Int
        /// Exact distribution for averages and percentiles after raw expiry.
        let samplesByBPM: [Int: Int]
        /// Existing zone/Edwards integration assigns each accepted interval to
        /// its terminal BPM. Keeping seconds by BPM permits profile changes.
        let terminalBPMSeconds: [Int: Double]
        /// Key is previousBPM + currentBPM (twice the trapezoidal mean). This
        /// preserves exact Banister TRIMP under future rest/max/sex changes.
        let transitionHalfBPMSeconds: [Int: Double]
        let coveredSeconds: Double
        let droppedGapSeconds: Double
        let firstSampleUnix: Double?
        let firstSampleBPM: Int?
        let lastSampleUnix: Double?
        let lastSampleBPM: Int?
    }

    struct RREpoch: Codable, Equatable, Sendable {
        let start: Date
        let end: Date
        let sourceRecordCount: Int
        let acceptedBeatCount: Int
        let rejectedBeatCount: Int
        let sumNNMilliseconds: Int64
        let sumNNSquaredMilliseconds: Double
        let adjacentDifferenceCount: Int
        let sumAdjacentDifferenceSquaredMilliseconds: Double
        /// Strictly greater than 50 ms, matching the app's pNN50 definition.
        let adjacentDifferenceOver50Count: Int
        /// Bridges allow exact adjacent-difference composition across epochs.
        let firstNNMilliseconds: Int?
        let lastNNMilliseconds: Int?
        let coverageSeconds: Double
        let maximumGapSeconds: Double
        let projectionFingerprint: String
        let provenance: String
    }

    struct MotionEpoch: Codable, Equatable, Sendable {
        let start: Date
        let end: Date
        let rows: Int
        let validatedRows: Int
        let rejectedRows: Int
        let coverageSeconds: Int
        let maximumGapSeconds: Int
        let stillnessRatio: Double?
        let movementIntensity: Double?
        let p95VectorDelta: Double?
        let activityBursts: Int?
        let stepDelta: Int?
        let measurementValidated: Bool
        let lowMotionQualified: Bool
        let sleepStage: String?
        let sleepStageConfidence: Double?
        let algorithmVersion: String
        let provenance: String
    }

    struct MaterializedProjection: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Equatable, Sendable {
            case sleep
            case workout
            case activity
            case dailyMetrics
            case steps
            case replayIdentity
        }

        let kind: Kind
        let identifier: String
        let start: Date
        let end: Date
        let schemaVersion: Int
        let contentSHA256: String
        let settledAt: Date
    }

    struct Parity: Codable, Equatable, Sendable {
        let rawRows: Int
        let decodedRows: Int
        let undecodableRowsRetainedRaw: Int
        let metricUsableRows: Int
        let heartRateSamples: Int
        let heartRateSumBPM: Int64
        let acceptedRRBeats: Int
        let acceptedRRSumMilliseconds: Int64
        let validatedGravityRows: Int
        let motionEpochs: Int
        let projectionReceipts: Int
    }

    let schema: Int
    let createdAt: Date
    let source: Source
    let heartRateMinutes: [HeartRateMinute]
    let rrEpochs: [RREpoch]
    let motionEpochs: [MotionEpoch]
    let materializedProjections: [MaterializedProjection]
    let parity: Parity

    static let rawRetirementRequiredProjectionKinds: Set<MaterializedProjection.Kind> = [
        .sleep,
        .workout,
        .activity,
        .dailyMetrics,
        .steps,
        .replayIdentity,
    ]

    /// Metric facts alone cannot reproduce settled sessions or exact replay
    /// identity. Raw retirement is legal only after every consumer has a
    /// versioned receipt spanning the complete source interval. A receipt may
    /// prove an empty result, but omission is never interpreted as empty.
    var authorizesRawRetirement: Bool {
        // An aggregate can safely index the decoded portion of a legacy source
        // while the immutable source retains rows from an older/unknown
        // envelope. It must never authorize deleting that sole residual copy.
        guard parity.undecodableRowsRetainedRaw == 0 else { return false }
        guard materializedProjections.count == Self.rawRetirementRequiredProjectionKinds.count else {
            return false
        }
        let lowercaseHex = CharacterSet(charactersIn: "0123456789abcdef")
        let coveredKinds: Set<MaterializedProjection.Kind> = Set(
            materializedProjections.compactMap { projection -> MaterializedProjection.Kind? in
            guard projection.start <= source.firstTimestamp,
                  projection.end >= source.lastTimestamp,
                  projection.schemaVersion > 0,
                  projection.identifier.hasPrefix("consumer-receipt-"),
                  projection.contentSHA256.count == 64,
                  projection.contentSHA256.unicodeScalars.allSatisfy(lowercaseHex.contains),
                  projection.settledAt >= projection.end else { return nil }
            return projection.kind
        })
        return coveredKinds == Self.rawRetirementRequiredProjectionKinds
    }

    enum ValidationError: Error, Equatable {
        case unsupportedSchema
        case invalidSourceRange
        case rawRowMismatch
        case undecodableRowsNotRetained
        case heartRateParityMismatch
        case rrParityMismatch
        case motionParityMismatch
        case projectionParityMismatch
        case invalidEpochRange
        case nonFiniteValue
    }

    func validateForCommit() throws {
        guard schema == Self.currentSchema else { throw ValidationError.unsupportedSchema }
        guard source.rawRowCount >= 0,
              source.lastTimestamp >= source.firstTimestamp else {
            throw ValidationError.invalidSourceRange
        }
        guard parity.rawRows == source.rawRowCount,
              parity.decodedRows + parity.undecodableRowsRetainedRaw == parity.rawRows else {
            throw ValidationError.rawRowMismatch
        }
        let hrCount = heartRateMinutes.reduce(0) { $0 + $1.sampleCount }
        let hrSum = heartRateMinutes.reduce(Int64(0)) { $0 + $1.sumBPM }
        guard hrCount == parity.heartRateSamples,
              hrSum == parity.heartRateSumBPM,
              heartRateMinutes.allSatisfy(Self.validHeartRateMinute) else {
            throw ValidationError.heartRateParityMismatch
        }

        let rrCount = rrEpochs.reduce(0) { $0 + $1.acceptedBeatCount }
        let rrSum = rrEpochs.reduce(Int64(0)) { $0 + $1.sumNNMilliseconds }
        guard rrCount == parity.acceptedRRBeats,
              rrSum == parity.acceptedRRSumMilliseconds,
              rrEpochs.allSatisfy(Self.validRREpoch) else {
            throw ValidationError.rrParityMismatch
        }
        guard motionEpochs.count == parity.motionEpochs,
              motionEpochs.reduce(0, { $0 + $1.validatedRows }) == parity.validatedGravityRows,
              motionEpochs.allSatisfy(Self.validMotionEpoch) else {
            throw ValidationError.motionParityMismatch
        }
        guard materializedProjections.count == parity.projectionReceipts,
              materializedProjections.allSatisfy({ projection in
                  projection.end > projection.start
                      && projection.schemaVersion > 0
                      && !projection.identifier.isEmpty
                      && projection.contentSHA256.count == 64
                      && projection.contentSHA256.unicodeScalars.allSatisfy(
                          CharacterSet(charactersIn: "0123456789abcdef").contains
                      )
                      && projection.settledAt >= projection.end
              }) else {
            throw ValidationError.projectionParityMismatch
        }
    }

    private static func validHeartRateMinute(_ value: HeartRateMinute) -> Bool {
        guard value.sampleCount >= 0,
              value.samplesByBPM.values.reduce(0, +) == value.sampleCount,
              value.samplesByBPM.reduce(Int64(0), { $0 + Int64($1.key * $1.value) }) == value.sumBPM,
              value.coveredSeconds.isFinite,
              value.droppedGapSeconds.isFinite,
              value.terminalBPMSeconds.values.allSatisfy({ $0.isFinite && $0 >= 0 }),
              value.transitionHalfBPMSeconds.values.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            return false
        }
        if value.sampleCount == 0 {
            return value.minimumBPM == 0 && value.maximumBPM == 0
        }
        return value.minimumBPM > 0
            && value.maximumBPM >= value.minimumBPM
            && value.samplesByBPM.keys.min() == value.minimumBPM
            && value.samplesByBPM.keys.max() == value.maximumBPM
    }

    private static func validRREpoch(_ value: RREpoch) -> Bool {
        value.end > value.start
            && value.acceptedBeatCount >= 0
            && value.rejectedBeatCount >= 0
            && value.adjacentDifferenceCount >= 0
            && value.adjacentDifferenceOver50Count >= 0
            && value.adjacentDifferenceOver50Count <= value.adjacentDifferenceCount
            && value.sumNNSquaredMilliseconds.isFinite
            && value.sumAdjacentDifferenceSquaredMilliseconds.isFinite
            && value.coverageSeconds.isFinite
            && value.maximumGapSeconds.isFinite
            && !value.projectionFingerprint.isEmpty
            && !value.provenance.isEmpty
    }

    private static func validMotionEpoch(_ value: MotionEpoch) -> Bool {
        value.end > value.start
            && value.rows >= 0
            && value.validatedRows >= 0
            && value.rejectedRows >= 0
            && value.validatedRows + value.rejectedRows == value.rows
            && value.stillnessRatio.map({ $0.isFinite && (0...1).contains($0) }) ?? true
            && value.movementIntensity.map({ $0.isFinite && $0 >= 0 }) ?? true
            && value.p95VectorDelta.map({ $0.isFinite && $0 >= 0 }) ?? true
            && value.sleepStageConfidence.map({ $0.isFinite && (0...1).contains($0) }) ?? true
            && !value.algorithmVersion.isEmpty
            && !value.provenance.isEmpty
    }
}
