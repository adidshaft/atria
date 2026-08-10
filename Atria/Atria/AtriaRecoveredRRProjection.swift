import CryptoKit
import Foundation

/// Deterministic projection of verified WHOOP 4 archive RR/IBI records into
/// exact beat-end samples.
///
/// This type is intentionally side-effect free and does not manufacture a
/// `SavedSession.RRPoint` source. Historical R24 data is neither standard
/// Bluetooth Heart Rate Measurement (2A37) nor realtime proprietary data, so
/// assigning a realtime provenance would silently weaken the HRV gate.
/// Consumers map it only to the dedicated
/// `verifiedWhoop4HistoricalV24` persistence provenance.
///
/// No resampling or interpolation occurs. The last interval in a one-second
/// record ends at that record's exact 32,768 Hz RTC timestamp; earlier interval
/// end times are obtained by subtracting only the later, decoded RR intervals.
enum AtriaRecoveredRRProjection {
    static let rtcTicksPerSecond = 32_768

    enum Provenance: String, Codable, Equatable, Sendable {
        case verifiedWhoop4HistoricalV24 = "verified_whoop4_historical_v24"
    }

    enum RejectionReason: String, Codable, CaseIterable, Equatable, Error, Sendable {
        case metricNotUsable = "metric_not_usable"
        case archiveFieldsNotUsable = "archive_fields_not_usable"
        case wrongTransportProvenance = "wrong_transport_provenance"
        case layoutNotValidatedV24 = "layout_not_validated_v24"
        case clockNotVerified = "clock_not_verified"
        case invalidTimestamp = "invalid_timestamp"
        case invalidRawPayload = "invalid_raw_payload"
        case rawPayloadMismatch = "raw_payload_mismatch"
        case physiologyWithheld = "physiology_withheld"
        case rrMetadataMismatch = "rr_metadata_mismatch"
        case noIntervals = "no_intervals"
    }

    struct Beat: Codable, Equatable, Sendable, Identifiable {
        /// Stable across archive replay, input ordering, and process restarts.
        let id: String
        /// Stable identity of the source R24 record.
        let recordID: String
        /// Exact interval end time reconstructed from the record RTC timestamp.
        let timestamp: Date
        let intervalMilliseconds: Int
        let counter: UInt32
        let beatIndex: Int
        let provenance: Provenance
    }

    struct RelativeBeat: Codable, Equatable, Sendable {
        let stableID: String
        let secondsFromSessionStart: TimeInterval
        let intervalMilliseconds: Int
        let provenance: Provenance
    }

    struct Statistics: Equatable, Sendable {
        let inputRecordCount: Int
        let acceptedRecordCount: Int
        let replayedRecordCount: Int
        let emittedBeatCount: Int
        let rejectionCounts: [RejectionReason: Int]

        func rejected(_ reason: RejectionReason) -> Int {
            rejectionCounts[reason, default: 0]
        }
    }

    struct Result: Equatable, Sendable {
        let beats: [Beat]
        let statistics: Statistics
        /// Content identity for invalidating derived caches after a drain. It is
        /// unchanged by archive replay or input ordering.
        let stableFingerprint: String

        /// Produces relative points without discarding historical provenance.
        /// Beats before the requested session boundary are excluded; no values
        /// are shifted, clamped, or synthesized.
        func relativeBeats(sessionStart: Date, sessionEnd: Date? = nil) -> [RelativeBeat] {
            beats.compactMap { beat in
                guard beat.timestamp >= sessionStart,
                      sessionEnd.map({ beat.timestamp <= $0 }) ?? true else { return nil }
                return RelativeBeat(
                    stableID: beat.id,
                    secondsFromSessionStart: beat.timestamp.timeIntervalSince(sessionStart),
                    intervalMilliseconds: beat.intervalMilliseconds,
                    provenance: beat.provenance
                )
            }
        }
    }

    static func project(records: [HistoricalArchive.Record]) -> Result {
        var accumulator = Accumulator()
        for record in records {
            accumulator.ingest(record)
        }
        return accumulator.finish()
    }

    /// Streaming form of `project(records:)` for the recovered-archive scan
    /// (2026-08-04 footprint fix): verification happens per-record at ingest
    /// time and only a COMPACT accepted representation is retained — recordID,
    /// clock rank, the three timestamp/counter fields `makeBeats` needs, and
    /// the decoded intervals. Retaining whole `Record`s (rawPayloadHex +
    /// candidateRR + three int arrays ≈ 1KB each) was a primary contributor to
    /// the 3.45GB phys_footprint jetsams. `finish()` materializes the exact
    /// same Result as `project(records:)` — same dedup, same clock-provenance
    /// preference, same ordering, same fingerprint.
    struct Accumulator: Codable {
        fileprivate struct CompactAccepted: Codable {
            var clockRank: ClockRank
            var correctedUnix: UInt32
            var subsecond: UInt16
            var counter: UInt32
            var intervals: [Int]
        }

        fileprivate var acceptedByRecordID: [Digest32: CompactAccepted] = [:]
        fileprivate var rejectionCounts: [RejectionReason: Int] = [:]
        fileprivate var replayedRecordCount = 0
        fileprivate var inputRecordCount = 0

        init() {}

        var acceptedRecordCount: Int { acceptedByRecordID.count }

        mutating func ingest(_ record: HistoricalArchive.Record) {
            inputRecordCount += 1
            switch AtriaRecoveredRRProjection.verify(record) {
            case .failure(let reason):
                rejectionCounts[reason, default: 0] += 1

            case .success(let verified):
                let digest = AtriaRecoveredRRProjection.stableRecordDigest(
                    record, normalizedPayloadHex: verified.payloadHex)
                let compact = CompactAccepted(
                    clockRank: AtriaRecoveredRRProjection.clockRank(for: record),
                    correctedUnix: record.clockCorrectedUnix7!,
                    subsecond: record.subsec11,
                    counter: record.flash13,
                    intervals: verified.intervals
                )
                if let existing = acceptedByRecordID[digest] {
                    replayedRecordCount += 1
                    if AtriaRecoveredRRProjection.prefersClockProvenance(
                        compact.clockRank, over: existing.clockRank) {
                        acceptedByRecordID[digest] = compact
                    }
                } else {
                    acceptedByRecordID[digest] = compact
                }
            }
        }

        /// Drop accepted records that end before `cutoff` (cache pruning).
        /// Rejection/replay statistics intentionally keep describing the whole
        /// ingest history — they are diagnostics, not retained data.
        mutating func prune(before cutoff: TimeInterval) {
            acceptedByRecordID = acceptedByRecordID.filter { _, accepted in
                TimeInterval(accepted.correctedUnix)
                    + TimeInterval(accepted.subsecond)
                        / TimeInterval(AtriaRecoveredRRProjection.rtcTicksPerSecond)
                    >= cutoff
            }
        }

        func finish() -> Result {
            // Record-ID strings exist only transiently here (2026-08-05
            // bounding design, Edit 2): reconstructing ~one 87-char string
            // per accepted record costs ~40-60MB at the snapshot stage's
            // peak on the dying recompute thread (verdict F4, accepted)
            // instead of retaining the same bytes between recomputes.
            let beats = acceptedByRecordID
                .flatMap { digest, accepted in
                    AtriaRecoveredRRProjection.makeBeats(
                        correctedUnix: accepted.correctedUnix,
                        subsecond: accepted.subsecond,
                        counter: accepted.counter,
                        intervals: accepted.intervals,
                        recordID: AtriaRecoveredRRProjection.recordID(from: digest)
                    )
                }
                .sorted { lhs, rhs in
                    if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
                    if lhs.recordID != rhs.recordID { return lhs.recordID < rhs.recordID }
                    return lhs.beatIndex < rhs.beatIndex
                }
            let fingerprint = AtriaRecoveredRRProjection.stableFingerprint(for: beats)
            return Result(
                beats: beats,
                statistics: Statistics(
                    inputRecordCount: inputRecordCount,
                    acceptedRecordCount: acceptedByRecordID.count,
                    replayedRecordCount: replayedRecordCount,
                    emittedBeatCount: beats.count,
                    rejectionCounts: rejectionCounts
                ),
                stableFingerprint: fingerprint
            )
        }
    }

    private struct VerifiedRecord {
        let payloadHex: String
        let intervals: [Int]
    }

    /// Raw SHA-256 digest stored inline (32B, four words). The accumulator
    /// retains one per accepted record between recomputes; the equivalent
    /// 87-char recordID String it replaces was a dedicated heap allocation
    /// each (2026-08-05 bounding design, Edit 2). Words are loaded and
    /// re-emitted with the same native convention, so `bytes` reproduces the
    /// digest byte-for-byte.
    fileprivate struct Digest32: Codable, Hashable {
        let word0: UInt64
        let word1: UInt64
        let word2: UInt64
        let word3: UInt64

        init(_ digest: SHA256.Digest) {
            let words: (UInt64, UInt64, UInt64, UInt64) = digest.withUnsafeBytes { raw in
                (raw.loadUnaligned(fromByteOffset: 0, as: UInt64.self),
                 raw.loadUnaligned(fromByteOffset: 8, as: UInt64.self),
                 raw.loadUnaligned(fromByteOffset: 16, as: UInt64.self),
                 raw.loadUnaligned(fromByteOffset: 24, as: UInt64.self))
            }
            word0 = words.0
            word1 = words.1
            word2 = words.2
            word3 = words.3
        }

        var bytes: [UInt8] {
            withUnsafeBytes(of: (word0, word1, word2, word3)) { Array($0) }
        }
    }

    fileprivate struct ClockRank: Codable {
        let wall: UInt32
        let device: UInt32
        let correctedUnix: UInt32
    }

    private static func verify(
        _ record: HistoricalArchive.Record
    ) -> Swift.Result<VerifiedRecord, RejectionReason> {
        guard record.metricUsable else { return .failure(.metricNotUsable) }
        guard record.currentSessionUsable, record.gravityValidated else {
            return .failure(.archiveFieldsNotUsable)
        }
        guard record.source == "0x2f",
              record.command == Int(AtriaWhoop4HistoricalRecordDecoder.packetType) else {
            return .failure(.wrongTransportProvenance)
        }
        guard record.sequence == Int(AtriaWhoop4HistoricalLayout.v24.rawValue),
              record.layoutVersion == HistoricalArchive.layoutVersion,
              HistoricalArchive.metricLayoutValidated(record.layoutVersion) else {
            return .failure(.layoutNotValidatedV24)
        }
        guard record.clockCorrectionStatus == "clock_ref_present",
              let clockDevice = record.clockDeviceRef,
              let clockWall = record.clockWallRef,
              let storedDrift = record.clockDriftSeconds,
              let correctedUnix = record.clockCorrectedUnix7 else {
            return .failure(.clockNotVerified)
        }
        let drift = Int(clockWall) - Int(clockDevice)
        let expectedCorrected = Int64(record.unix7) + Int64(snappedClockDrift(drift))
        guard storedDrift == drift,
              expectedCorrected > 0,
              expectedCorrected <= Int64(UInt32.max),
              correctedUnix == UInt32(expectedCorrected) else {
            return .failure(.clockNotVerified)
        }
        guard correctedUnix > 0,
              record.unix7 > 0,
              record.subsec11 < UInt16(rtcTicksPerSecond) else {
            return .failure(.invalidTimestamp)
        }
        guard let rawPayload = decodeHex(record.rawPayloadHex) else {
            return .failure(.invalidRawPayload)
        }
        guard record.payloadLength == rawPayload.count else {
            return .failure(.rawPayloadMismatch)
        }
        guard case .record(let decoded) = AtriaWhoop4HistoricalRecordDecoder.decode(
            rawPayload,
            origin: "atria-recovered-rr-projection"
        ),
              decoded.layout == .v24,
              decoded.counter == record.flash13,
              decoded.timestampSeconds == record.unix7,
              decoded.subsecond == record.subsec11,
              decoded.physiology?.decodedHeartRateBPM == record.whoofHR17,
              decoded.gravity.magnitude.isFinite,
              (0.5...1.8).contains(decoded.gravity.magnitude) else {
            return .failure(.rawPayloadMismatch)
        }
        guard let intervals = decoded.physiology?.acceptedRRIntervalsMilliseconds else {
            return .failure(.physiologyWithheld)
        }
        guard record.whoofRRNum18 == intervals.count,
              record.whoofRR19 == intervals else {
            return .failure(.rrMetadataMismatch)
        }
        guard !intervals.isEmpty else { return .failure(.noIntervals) }
        return .success(VerifiedRecord(payloadHex: normalizedHex(rawPayload),
                                       intervals: intervals))
    }

    fileprivate static func makeBeats(
        correctedUnix: UInt32,
        subsecond: UInt16,
        counter: UInt32,
        intervals: [Int],
        recordID: String
    ) -> [Beat] {
        let recordTimestamp = TimeInterval(correctedUnix)
            + TimeInterval(subsecond) / TimeInterval(rtcTicksPerSecond)
        var remainingAfterMilliseconds = intervals.reduce(0, +)
        return intervals.enumerated().map { index, interval in
            remainingAfterMilliseconds -= interval
            let beatTimestamp = recordTimestamp
                - TimeInterval(remainingAfterMilliseconds) / 1_000
            return Beat(
                id: "\(recordID):beat:\(index)",
                recordID: recordID,
                timestamp: Date(timeIntervalSince1970: beatTimestamp),
                intervalMilliseconds: interval,
                counter: counter,
                beatIndex: index,
                provenance: .verifiedWhoop4HistoricalV24
            )
        }
    }

    fileprivate static func stableRecordDigest(
        _ record: HistoricalArchive.Record,
        normalizedPayloadHex: String
    ) -> Digest32 {
        let canonical = [
            "atria-recovered-rr-record-v1",
            record.source,
            record.layoutVersion,
            String(record.flash13),
            String(record.unix7),
            String(record.subsec11),
            normalizedPayloadHex,
        ].joined(separator: "|")
        return Digest32(SHA256.hash(data: Data(canonical.utf8)))
    }

    /// Byte-identical reconstruction of the retired stableRecordID string:
    /// that string was `"recovered-rr-record-v1-" + lowercase-hex(sha256)`,
    /// and the stored digest IS that sha256. Pinned by the known-vector
    /// fixture in AtriaRecoveredRRProjectionTests.
    fileprivate static func recordID(from digest: Digest32) -> String {
        "recovered-rr-record-v1-\(hexEncoded(digest.bytes))"
    }

    /// A replay may contain the same immutable strap record decoded against a
    /// newer RTC synchronization. Identity remains attached to the raw record;
    /// the newest wall-clock reference deterministically supplies its timestamp.
    private static func clockRank(for record: HistoricalArchive.Record) -> ClockRank {
        .init(wall: record.clockWallRef ?? 0,
              device: record.clockDeviceRef ?? 0,
              correctedUnix: record.clockCorrectedUnix7 ?? 0)
    }

    private static func prefersClockProvenance(
        _ candidate: ClockRank,
        over existing: ClockRank
    ) -> Bool {
        if candidate.wall != existing.wall { return candidate.wall > existing.wall }
        if candidate.device != existing.device { return candidate.device > existing.device }
        return candidate.correctedUnix > existing.correctedUnix
    }

    private static func stableFingerprint(for beats: [Beat]) -> String {
        let canonical = beats.map { beat in
            "\(beat.id)|\(beat.timestamp.timeIntervalSince1970.bitPattern)|\(beat.intervalMilliseconds)"
        }.joined(separator: "\n")
        return "recovered-rr-projection-v1-\(sha256(canonical))"
    }

    private static func snappedClockDrift(_ drift: Int) -> Int {
        guard abs(drift) >= 86_400 else { return drift }
        let granularity = 300
        if drift >= 0 {
            return ((drift + granularity / 2) / granularity) * granularity
        }
        return ((drift - granularity / 2) / granularity) * granularity
    }

    private static func sha256(_ value: String) -> String {
        hexEncoded(SHA256.hash(data: Data(value.utf8)))
    }

    /// Lowercase hex rendering without per-byte String(format:) — the scan
    /// ingests millions of RR rows and the Foundation format path was a
    /// dominant source of the transient-garbage footprint balloon
    /// (2026-08-04). Output is byte-identical to map{"%02x"}.joined().
    private static let hexEncodeDigits: [UInt8] = Array("0123456789abcdef".utf8)

    private static func hexEncoded<S: Sequence>(_ bytes: S) -> String
    where S.Element == UInt8 {
        var out: [UInt8] = []
        out.reserveCapacity(2 * bytes.underestimatedCount)
        for byte in bytes {
            out.append(hexEncodeDigits[Int(byte >> 4)])
            out.append(hexEncodeDigits[Int(byte & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func decodeHex(_ value: String) -> [UInt8]? {
        // Fast path (the writer's only shape): pure-ASCII input decoded
        // byte-wise with inline ASCII-whitespace skipping — no Character
        // filter, no per-pair substrings. Any non-ASCII byte falls back to
        // the Unicode-correct slow path below; rejection semantics match.
        var sawNonASCII = false
        var nibbles = 0
        var pending: UInt8 = 0
        var fast: [UInt8] = []
        fast.reserveCapacity(value.utf8.count / 2)
        for byte in value.utf8 {
            if byte >= 0x80 {
                sawNonASCII = true
                break
            }
            switch byte {
            case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20:
                continue  // Character.isWhitespace for the ASCII range
            case 0x30...0x39, 0x41...0x46, 0x61...0x66:
                let digit = byte <= 0x39 ? byte - 0x30
                    : (byte <= 0x46 ? byte - 0x41 + 10 : byte - 0x61 + 10)
                if nibbles % 2 == 0 {
                    pending = digit << 4
                } else {
                    fast.append(pending | digit)
                }
                nibbles += 1
            default:
                return nil  // non-hex ASCII rejects in both paths
            }
        }
        if !sawNonASCII {
            guard nibbles > 0, nibbles % 2 == 0 else { return nil }
            return fast
        }
        let compact = value.filter { !$0.isWhitespace }
        guard !compact.isEmpty, compact.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(compact.count / 2)
        var index = compact.startIndex
        while index < compact.endIndex {
            let next = compact.index(index, offsetBy: 2)
            guard let byte = UInt8(compact[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    private static func normalizedHex(_ bytes: [UInt8]) -> String {
        hexEncoded(bytes)
    }
}
