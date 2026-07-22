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

    enum RejectionReason: String, CaseIterable, Equatable, Error, Sendable {
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
        var rejectionCounts: [RejectionReason: Int] = [:]
        var acceptedByRecordID: [String: AcceptedRecord] = [:]
        var replayedRecordCount = 0

        for record in records {
            switch verify(record) {
            case .failure(let reason):
                rejectionCounts[reason, default: 0] += 1

            case .success(let verified):
                let recordID = stableRecordID(record, normalizedPayloadHex: verified.payloadHex)
                guard acceptedByRecordID[recordID] == nil else {
                    replayedRecordCount += 1
                    if let existing = acceptedByRecordID[recordID],
                       prefersClockProvenance(clockRank(for: record), over: existing.clockRank) {
                        acceptedByRecordID[recordID] = AcceptedRecord(
                            clockRank: clockRank(for: record),
                            beats: makeBeats(record: record,
                                             intervals: verified.intervals,
                                             recordID: recordID)
                        )
                    }
                    continue
                }
                acceptedByRecordID[recordID] = AcceptedRecord(
                    clockRank: clockRank(for: record),
                    beats: makeBeats(record: record,
                                     intervals: verified.intervals,
                                     recordID: recordID)
                )
            }
        }

        let beats = acceptedByRecordID.values
            .flatMap { $0.beats }
            .sorted { lhs, rhs in
                if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
                if lhs.recordID != rhs.recordID { return lhs.recordID < rhs.recordID }
                return lhs.beatIndex < rhs.beatIndex
            }
        let fingerprint = stableFingerprint(for: beats)
        return Result(
            beats: beats,
            statistics: Statistics(
                inputRecordCount: records.count,
                acceptedRecordCount: acceptedByRecordID.count,
                replayedRecordCount: replayedRecordCount,
                emittedBeatCount: beats.count,
                rejectionCounts: rejectionCounts
            ),
            stableFingerprint: fingerprint
        )
    }

    private struct VerifiedRecord {
        let payloadHex: String
        let intervals: [Int]
    }

    /// The projection output needs only deterministic clock preference after a
    /// record is verified. Retaining the complete Record (including payload
    /// strings and RR arrays) doubled the peak cache footprint.
    private struct AcceptedRecord {
        let clockRank: ClockRank
        let beats: [Beat]
    }

    private struct ClockRank {
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

    private static func makeBeats(
        record: HistoricalArchive.Record,
        intervals: [Int],
        recordID: String
    ) -> [Beat] {
        let correctedUnix = record.clockCorrectedUnix7!
        let recordTimestamp = TimeInterval(correctedUnix)
            + TimeInterval(record.subsec11) / TimeInterval(rtcTicksPerSecond)
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
                counter: record.flash13,
                beatIndex: index,
                provenance: .verifiedWhoop4HistoricalV24
            )
        }
    }

    private static func stableRecordID(
        _ record: HistoricalArchive.Record,
        normalizedPayloadHex: String
    ) -> String {
        let canonical = [
            "atria-recovered-rr-record-v1",
            record.source,
            record.layoutVersion,
            String(record.flash13),
            String(record.unix7),
            String(record.subsec11),
            normalizedPayloadHex,
        ].joined(separator: "|")
        return "recovered-rr-record-v1-\(sha256(canonical))"
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
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func decodeHex(_ value: String) -> [UInt8]? {
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
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
