import CryptoKit
import Foundation

/// Pure coverage evaluator for a WHOOP 4 full-history drain.
///
/// A successful transport, a frame count, or a HISTORY_COMPLETE notification
/// is never coverage evidence. Only decoded, metric-usable timestamps that are
/// bound to the final durable raw/identity snapshots can satisfy this policy.
enum AtriaHistoricalFullDrainCoveragePolicy {
    /// Transport evidence required before a full-flash drain may be associated
    /// with one locally-selected closed gap.  The command still requests the
    /// complete flash contents; this type never represents an exact-range
    /// selector or a no-data attestation.
    struct TransportAuthority: Codable, Equatable, Sendable {
        let peripheralIdentifier: String
        let strapIdentity: String
        let transportNonce: String
        let transportGeneration: UInt64
        let clockCommandSequence: UInt8
        let clockCommandRequestedAtUnix: TimeInterval
        let clockWriteCompletedAtUnix: TimeInterval
        let clockResponseSequence: UInt8
        let deviceClockUnix: UInt32
        let clockWallUnix: UInt32
        let clockResponseReceivedAtUnix: TimeInterval
        let fullDrainCommandSequence: UInt8
        let fullDrainCommandRequestedAtUnix: TimeInterval
        let fullDrainWriteCompletedAtUnix: TimeInterval
        let historyStartSequence: UInt8
        let historyStartReceivedAtUnix: TimeInterval

        var isValid: Bool {
            let drift = abs(TimeInterval(clockWallUnix) - TimeInterval(deviceClockUnix))
            return !peripheralIdentifier.isEmpty
                && !strapIdentity.isEmpty
                && !transportNonce.isEmpty
                && transportGeneration > 0
                && clockCommandSequence == clockResponseSequence
                && deviceClockUnix > 0
                && clockWallUnix > 0
                && clockWriteCompletedAtUnix.isFinite
                && clockCommandRequestedAtUnix.isFinite
                && clockResponseReceivedAtUnix.isFinite
                && fullDrainWriteCompletedAtUnix.isFinite
                && fullDrainCommandRequestedAtUnix.isFinite
                && historyStartReceivedAtUnix.isFinite
                && clockResponseReceivedAtUnix >= clockCommandRequestedAtUnix
                && abs(clockResponseReceivedAtUnix - TimeInterval(clockWallUnix)) <= 2
                && clockWriteCompletedAtUnix >= clockCommandRequestedAtUnix
                && fullDrainCommandRequestedAtUnix >= clockWriteCompletedAtUnix
                && fullDrainCommandRequestedAtUnix >= clockResponseReceivedAtUnix
                && fullDrainWriteCompletedAtUnix >= fullDrainCommandRequestedAtUnix
                && historyStartReceivedAtUnix >= fullDrainCommandRequestedAtUnix
                && fullDrainCommandSequence != clockCommandSequence
                && drift <= 24 * 60 * 60
        }
    }

    enum TransportRejection: Error, Equatable, Sendable {
        case identityMissing
        case clockSequenceMismatch
        case clockResponseInsane
        case eventOrderInvalid
        case fullDrainWriteMissing
        case historyStartMissing
    }

    /// Fail-closed construction is kept pure so callback-order and stale
    /// sequence failures are testable without CoreBluetooth.
    static func validateTransportAuthority(
        peripheralIdentifier: String,
        strapIdentity: String,
        transportNonce: String,
        transportGeneration: UInt64,
        clockCommandSequence: UInt8?,
        clockCommandRequestedAtUnix: TimeInterval?,
        clockWriteCompletedAtUnix: TimeInterval?,
        clockResponseSequence: UInt8?,
        deviceClockUnix: UInt32?,
        clockWallUnix: UInt32?,
        clockResponseReceivedAtUnix: TimeInterval?,
        fullDrainCommandSequence: UInt8?,
        fullDrainCommandRequestedAtUnix: TimeInterval?,
        fullDrainWriteCompletedAtUnix: TimeInterval?,
        historyStartSequence: UInt8?,
        historyStartReceivedAtUnix: TimeInterval?
    ) throws -> TransportAuthority {
        guard !peripheralIdentifier.isEmpty,
              !strapIdentity.isEmpty,
              !transportNonce.isEmpty,
              transportGeneration > 0 else {
            throw TransportRejection.identityMissing
        }
        guard let clockCommandSequence,
              let clockResponseSequence,
              clockCommandSequence == clockResponseSequence else {
            throw TransportRejection.clockSequenceMismatch
        }
        guard let clockCommandRequestedAtUnix,
              let clockWriteCompletedAtUnix,
              let deviceClockUnix,
              let clockWallUnix,
              let clockResponseReceivedAtUnix,
              deviceClockUnix > 0,
              clockWallUnix > 0,
              abs(clockResponseReceivedAtUnix - TimeInterval(clockWallUnix)) <= 2,
              abs(TimeInterval(clockWallUnix) - TimeInterval(deviceClockUnix))
                <= 24 * 60 * 60 else {
            throw TransportRejection.clockResponseInsane
        }
        guard let fullDrainCommandSequence,
              let fullDrainCommandRequestedAtUnix,
              let fullDrainWriteCompletedAtUnix else {
            throw TransportRejection.fullDrainWriteMissing
        }
        guard let historyStartSequence,
              let historyStartReceivedAtUnix else {
            throw TransportRejection.historyStartMissing
        }
        guard clockCommandRequestedAtUnix.isFinite,
              clockWriteCompletedAtUnix.isFinite,
              clockResponseReceivedAtUnix.isFinite,
              fullDrainWriteCompletedAtUnix.isFinite,
              historyStartReceivedAtUnix.isFinite,
              fullDrainCommandRequestedAtUnix.isFinite,
              clockResponseReceivedAtUnix >= clockCommandRequestedAtUnix,
              clockWriteCompletedAtUnix >= clockCommandRequestedAtUnix,
              fullDrainCommandRequestedAtUnix >= clockWriteCompletedAtUnix,
              fullDrainCommandRequestedAtUnix >= clockResponseReceivedAtUnix,
              fullDrainWriteCompletedAtUnix >= fullDrainCommandRequestedAtUnix,
              historyStartReceivedAtUnix >= fullDrainCommandRequestedAtUnix,
              fullDrainCommandSequence != clockCommandSequence else {
            throw TransportRejection.eventOrderInvalid
        }
        let authority = TransportAuthority(
            peripheralIdentifier: peripheralIdentifier,
            strapIdentity: strapIdentity,
            transportNonce: transportNonce,
            transportGeneration: transportGeneration,
            clockCommandSequence: clockCommandSequence,
            clockCommandRequestedAtUnix: clockCommandRequestedAtUnix,
            clockWriteCompletedAtUnix: clockWriteCompletedAtUnix,
            clockResponseSequence: clockResponseSequence,
            deviceClockUnix: deviceClockUnix,
            clockWallUnix: clockWallUnix,
            clockResponseReceivedAtUnix: clockResponseReceivedAtUnix,
            fullDrainCommandSequence: fullDrainCommandSequence,
            fullDrainCommandRequestedAtUnix: fullDrainCommandRequestedAtUnix,
            fullDrainWriteCompletedAtUnix: fullDrainWriteCompletedAtUnix,
            historyStartSequence: historyStartSequence,
            historyStartReceivedAtUnix: historyStartReceivedAtUnix
        )
        guard authority.isValid else { throw TransportRejection.eventOrderInvalid }
        return authority
    }

    struct Configuration: Codable, Equatable, Sendable {
        let cadenceSeconds: Int
        let minimumDensityPercent: Int
        let maximumGapSeconds: Int
        let maximumP95GapSeconds: Int
        let maximumGapDurationSeconds: Int
        let requiredConsumerKinds: [String]

        static let production = Configuration(
            cadenceSeconds: 1,
            minimumDensityPercent: 90,
            maximumGapSeconds: 3,
            maximumP95GapSeconds: 1,
            maximumGapDurationSeconds: 13 * 24 * 60 * 60,
            requiredConsumerKinds: [
                "activity",
                "daily_metrics",
                "sleep",
                "steps",
                "workout",
            ]
        )

        var isValid: Bool {
            cadenceSeconds > 0
                && minimumDensityPercent > 0
                && minimumDensityPercent <= 100
                && maximumGapSeconds >= cadenceSeconds
                && maximumP95GapSeconds >= cadenceSeconds
                && maximumGapDurationSeconds >= cadenceSeconds
                && !requiredConsumerKinds.isEmpty
                && requiredConsumerKinds.allSatisfy { !$0.isEmpty }
                && Set(requiredConsumerKinds).count == requiredConsumerKinds.count
        }
    }

    struct DurableStoreSeal: Codable, Equatable, Sendable {
        let storeIdentifier: String
        let snapshotSHA256: String
        let durableSequence: UInt64
        let batchKeysSHA256: String
        let byteCount: UInt64
        let recordCount: UInt64
        let observedIdentityCount: UInt64
        let fsyncedAtUnix: TimeInterval

        var isValid: Bool {
            !storeIdentifier.isEmpty
                && Self.isSHA256(snapshotSHA256)
                && Self.isSHA256(batchKeysSHA256)
                && durableSequence > 0
                && fsyncedAtUnix.isFinite
                && fsyncedAtUnix > 0
        }

        fileprivate static func isSHA256(_ value: String) -> Bool {
            value.count == 64 && value.utf8.allSatisfy { byte in
                (48...57).contains(byte) || (97...102).contains(byte)
            }
        }
    }

    struct DurableStorePair: Codable, Equatable, Sendable {
        let raw: DurableStoreSeal
        let identity: DurableStoreSeal
        let admission: DurableStoreSeal
        let admissionReceipt: AtriaWhoop4HistoryAdmissionLedger.PrefixDurabilityReceipt

        var isValid: Bool {
            raw.isValid
                && identity.isValid
                && admission.isValid
                && raw.storeIdentifier != identity.storeIdentifier
                && raw.storeIdentifier != admission.storeIdentifier
                && identity.storeIdentifier != admission.storeIdentifier
                && raw.durableSequence == identity.durableSequence
                && raw.durableSequence == admission.durableSequence
                && raw.batchKeysSHA256 == identity.batchKeysSHA256
                && raw.observedIdentityCount == identity.observedIdentityCount
                && admission.snapshotSHA256 == admissionReceipt.snapshotSHA256
                && admission.durableSequence == admissionReceipt.durableSequence
                && admission.recordCount == admissionReceipt.recordCount
                && admission.byteCount == admissionReceipt.byteCount
                && admission.fsyncedAtUnix == admissionReceipt.fsyncedAtUnix
                && raw.snapshotSHA256 == admissionReceipt.rawArchiveSnapshotSHA256
                && identity.snapshotSHA256 == admissionReceipt.identityIndexSnapshotSHA256
                && DurableStoreSeal.isSHA256(
                    admissionReceipt.archiveReceiptChainSHA256
                )
        }

        func isAtLeastAsDurable(as prior: Self) -> Bool {
            raw.storeIdentifier == prior.raw.storeIdentifier
                && identity.storeIdentifier == prior.identity.storeIdentifier
                && admission.storeIdentifier == prior.admission.storeIdentifier
                && raw.durableSequence >= prior.raw.durableSequence
                && identity.durableSequence >= prior.identity.durableSequence
                && admission.durableSequence >= prior.admission.durableSequence
                && raw.fsyncedAtUnix >= prior.raw.fsyncedAtUnix
                && identity.fsyncedAtUnix >= prior.identity.fsyncedAtUnix
                && admission.fsyncedAtUnix >= prior.admission.fsyncedAtUnix
        }
    }

    struct CoverageProof: Codable, Equatable, Sendable {
        static let currentVersion = 1

        let version: Int
        let gapIdentifier: String
        let attemptIdentifier: String
        let transportNonce: String
        let transportGeneration: UInt64
        let rawSnapshotSHA256: String
        let identitySnapshotSHA256: String
        let admissionSnapshotSHA256: String
        let decoderIdentifier: String
        let decoderVersion: Int
        /// Compact exact coverage evidence. Each bit is one configured cadence
        /// bucket relative to the bound gap start; it is not a row count.
        let coveredBucketBits: Data
        let timestampSetSHA256: String
        let observedBuckets: Int
        let expectedBuckets: Int
        let densityPercent: Int
        let maximumGapSeconds: Int
        let p95GapSeconds: Int
        let firstTimestampUnix: TimeInterval
        let lastTimestampUnix: TimeInterval
    }

    enum Rejection: Error, Equatable, Sendable {
        case invalidConfiguration
        case invalidGap
        case invalidIdentity
        case storeSealMismatch
        case noUsableTimestamps
        case insufficientDensity
        case cadenceGapExceeded
        case p95GapExceeded
        case edgeNotCovered
    }

    static func evaluate(
        gapIdentifier: String,
        gapStartUnix: TimeInterval,
        gapEndUnix: TimeInterval,
        attemptIdentifier: String,
        transportNonce: String,
        transportGeneration: UInt64,
        stores: DurableStorePair,
        decoderIdentifier: String,
        decoderVersion: Int,
        metricTimestampsUnix: [TimeInterval],
        configuration: Configuration = .production
    ) throws -> CoverageProof {
        guard configuration.isValid else { throw Rejection.invalidConfiguration }
        let duration = gapEndUnix - gapStartUnix
        guard !gapIdentifier.isEmpty,
              gapStartUnix.isFinite,
              gapEndUnix.isFinite,
              gapStartUnix > 0,
              duration > 0,
              duration <= Double(configuration.maximumGapDurationSeconds) else {
            throw Rejection.invalidGap
        }
        guard !attemptIdentifier.isEmpty,
              !transportNonce.isEmpty,
              transportGeneration > 0,
              !decoderIdentifier.isEmpty,
              decoderVersion > 0 else {
            throw Rejection.invalidIdentity
        }
        guard stores.isValid else { throw Rejection.storeSealMismatch }

        let cadence = Double(configuration.cadenceSeconds)
        let expected = max(1, Int(ceil(duration / cadence)))
        var indexes = Set<Int>()
        indexes.reserveCapacity(min(expected, metricTimestampsUnix.count))
        for timestamp in metricTimestampsUnix {
            guard timestamp.isFinite,
                  timestamp >= gapStartUnix,
                  timestamp < gapEndUnix else { continue }
            let index = Int(floor((timestamp - gapStartUnix) / cadence))
            guard index >= 0, index < expected else { continue }
            indexes.insert(index)
        }
        let sorted = indexes.sorted()
        guard let first = sorted.first, let last = sorted.last else {
            throw Rejection.noUsableTimestamps
        }

        let density = min(100, Int((Double(sorted.count) / Double(expected) * 100).rounded(.down)))
        guard density >= configuration.minimumDensityPercent else {
            throw Rejection.insufficientDensity
        }
        let internalDeltas = zip(sorted, sorted.dropFirst()).map {
            ($1 - $0) * configuration.cadenceSeconds
        }
        let leading = first * configuration.cadenceSeconds
        let trailing = max(0, expected - 1 - last) * configuration.cadenceSeconds
        let maximumGap = max(max(leading, trailing), internalDeltas.max() ?? 0)
        guard leading <= configuration.maximumGapSeconds,
              trailing <= configuration.maximumGapSeconds else {
            throw Rejection.edgeNotCovered
        }
        guard maximumGap <= configuration.maximumGapSeconds else {
            throw Rejection.cadenceGapExceeded
        }
        let p95 = nearestRankPercentile(
            internalDeltas.isEmpty ? [max(leading, trailing)] : internalDeltas,
            percentile: 0.95
        )
        guard p95 <= configuration.maximumP95GapSeconds else {
            throw Rejection.p95GapExceeded
        }

        var bits = Data(repeating: 0, count: (expected + 7) / 8)
        for index in sorted {
            bits[index / 8] |= UInt8(1 << UInt8(index % 8))
        }
        let timestampSet = sorted.map(String.init).joined(separator: ",")
        return CoverageProof(
            version: CoverageProof.currentVersion,
            gapIdentifier: gapIdentifier,
            attemptIdentifier: attemptIdentifier,
            transportNonce: transportNonce,
            transportGeneration: transportGeneration,
            rawSnapshotSHA256: stores.raw.snapshotSHA256,
            identitySnapshotSHA256: stores.identity.snapshotSHA256,
            admissionSnapshotSHA256: stores.admission.snapshotSHA256,
            decoderIdentifier: decoderIdentifier,
            decoderVersion: decoderVersion,
            coveredBucketBits: bits,
            timestampSetSHA256: sha256(Data(timestampSet.utf8)),
            observedBuckets: sorted.count,
            expectedBuckets: expected,
            densityPercent: density,
            maximumGapSeconds: maximumGap,
            p95GapSeconds: p95,
            firstTimestampUnix: gapStartUnix + Double(first) * cadence,
            lastTimestampUnix: gapStartUnix + Double(last) * cadence
        )
    }

    static func validate(
        _ proof: CoverageProof,
        gapIdentifier: String,
        gapStartUnix: TimeInterval,
        gapEndUnix: TimeInterval,
        attemptIdentifier: String,
        transportNonce: String,
        transportGeneration: UInt64,
        stores: DurableStorePair,
        configuration: Configuration = .production
    ) -> Bool {
        guard configuration.isValid,
              proof.version == CoverageProof.currentVersion,
              proof.gapIdentifier == gapIdentifier,
              proof.attemptIdentifier == attemptIdentifier,
              proof.transportNonce == transportNonce,
              proof.transportGeneration == transportGeneration,
              proof.rawSnapshotSHA256 == stores.raw.snapshotSHA256,
              proof.identitySnapshotSHA256 == stores.identity.snapshotSHA256,
              proof.admissionSnapshotSHA256 == stores.admission.snapshotSHA256,
              DurableStoreSeal.isSHA256(proof.timestampSetSHA256),
              !proof.decoderIdentifier.isEmpty,
              proof.decoderVersion > 0,
              gapEndUnix > gapStartUnix else { return false }
        let expected = max(1, Int(ceil((gapEndUnix - gapStartUnix)
            / Double(configuration.cadenceSeconds))))
        guard proof.expectedBuckets == expected,
              proof.coveredBucketBits.count == (expected + 7) / 8 else { return false }
        let indexes = setIndexes(proof.coveredBucketBits, limitedTo: expected)
        guard indexes.count == proof.observedBuckets,
              let first = indexes.first,
              let last = indexes.last else { return false }
        var canonicalBits = Data(repeating: 0, count: (expected + 7) / 8)
        for index in indexes {
            canonicalBits[index / 8] |= UInt8(1 << UInt8(index % 8))
        }
        let timestampSet = indexes.map(String.init).joined(separator: ",")
        guard canonicalBits == proof.coveredBucketBits,
              sha256(Data(timestampSet.utf8)) == proof.timestampSetSHA256 else {
            return false
        }
        let density = min(100, Int((Double(indexes.count) / Double(expected) * 100).rounded(.down)))
        let deltas = zip(indexes, indexes.dropFirst()).map {
            ($1 - $0) * configuration.cadenceSeconds
        }
        let leading = first * configuration.cadenceSeconds
        let trailing = max(0, expected - 1 - last) * configuration.cadenceSeconds
        let maximumGap = max(max(leading, trailing), deltas.max() ?? 0)
        let p95 = nearestRankPercentile(
            deltas.isEmpty ? [max(leading, trailing)] : deltas,
            percentile: 0.95
        )
        return proof.densityPercent == density
            && proof.maximumGapSeconds == maximumGap
            && proof.p95GapSeconds == p95
            && proof.firstTimestampUnix == gapStartUnix + Double(first * configuration.cadenceSeconds)
            && proof.lastTimestampUnix == gapStartUnix + Double(last * configuration.cadenceSeconds)
            && density >= configuration.minimumDensityPercent
            && leading <= configuration.maximumGapSeconds
            && trailing <= configuration.maximumGapSeconds
            && maximumGap <= configuration.maximumGapSeconds
            && p95 <= configuration.maximumP95GapSeconds
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func setIndexes(_ bits: Data, limitedTo count: Int) -> [Int] {
        guard count > 0 else { return [] }
        return (0..<count).filter { index in
            bits[index / 8] & UInt8(1 << UInt8(index % 8)) != 0
        }
    }

    private static func nearestRankPercentile(_ values: [Int], percentile: Double) -> Int {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let rank = max(1, Int(ceil(percentile * Double(sorted.count))))
        return sorted[min(sorted.count - 1, rank - 1)]
    }
}
