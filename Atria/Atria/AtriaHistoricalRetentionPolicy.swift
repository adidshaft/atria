import Foundation

/// Pure selection policy for bounded WHOOP historical storage.
///
/// Selection never authorizes deletion by itself. A selected sealed chunk must
/// first pass `AtriaHistoricalRetentionTransaction`; its committed manifest is
/// the only proof that the raw file may be retired.
struct AtriaHistoricalRetentionPolicy: Equatable, Sendable {
    static let production = AtriaHistoricalRetentionPolicy(
        rawHorizon: 14 * 24 * 60 * 60,
        maximumRawBytes: 512 * 1024 * 1024
    )

    let rawHorizon: TimeInterval
    let maximumRawBytes: UInt64

    init(rawHorizon: TimeInterval, maximumRawBytes: UInt64) {
        precondition(rawHorizon >= 0)
        precondition(maximumRawBytes > 0)
        self.rawHorizon = rawHorizon
        self.maximumRawBytes = maximumRawBytes
    }

    struct Chunk: Equatable, Sendable {
        let identifier: String
        let url: URL
        let byteCount: UInt64
        let earliestTimestamp: Date
        let latestTimestamp: Date
        /// False for the base append target and today's active daily segment.
        /// An active file is never selected, even when the cap is exceeded.
        let isSealed: Bool

        init(identifier: String,
             url: URL,
             byteCount: UInt64,
             earliestTimestamp: Date,
             latestTimestamp: Date,
             isSealed: Bool) {
            precondition(byteCount >= 0)
            precondition(latestTimestamp >= earliestTimestamp)
            self.identifier = identifier
            self.url = url
            self.byteCount = byteCount
            self.earliestTimestamp = earliestTimestamp
            self.latestTimestamp = latestTimestamp
            self.isSealed = isSealed
        }
    }

    enum Reason: String, Codable, Equatable, Sendable {
        case outsideRawHorizon = "outside_raw_horizon"
        case hardCapPressure = "hard_cap_pressure"
    }

    struct Candidate: Equatable, Sendable {
        let chunk: Chunk
        let reason: Reason
    }

    struct Plan: Equatable, Sendable {
        let candidates: [Candidate]
        let rawBytesBefore: UInt64
        /// Expected remaining bytes if every candidate is successfully
        /// compacted and committed. A failure leaves the corresponding raw
        /// bytes in place and the real total higher than this estimate.
        let projectedRawBytes: UInt64
        let hardCapSatisfied: Bool
        let blockedActiveBytes: UInt64
    }

    func plan(chunks: [Chunk], now: Date) -> Plan {
        let ordered = chunks.sorted {
            if $0.latestTimestamp != $1.latestTimestamp {
                return $0.latestTimestamp < $1.latestTimestamp
            }
            if $0.earliestTimestamp != $1.earliestTimestamp {
                return $0.earliestTimestamp < $1.earliestTimestamp
            }
            return $0.identifier < $1.identifier
        }
        let total = ordered.reduce(UInt64(0)) { partial, chunk in
            partial.addingReportingOverflow(chunk.byteCount).overflow
                ? UInt64.max
                : partial + chunk.byteCount
        }
        let cutoff = now.addingTimeInterval(-rawHorizon)
        var selected = Set<String>()
        var candidates: [Candidate] = []
        var projected = total

        // Time retention is the normal path. Boundary-overlapping chunks stay
        // raw because deleting one would shorten the promised horizon.
        for chunk in ordered where chunk.isSealed && chunk.latestTimestamp < cutoff {
            selected.insert(chunk.identifier)
            candidates.append(Candidate(chunk: chunk, reason: .outsideRawHorizon))
            projected = projected >= chunk.byteCount ? projected - chunk.byteCount : 0
        }

        // The byte cap is a safety ceiling, not a second age estimate. If 14
        // days of high-rate raw data exceed it, retire the oldest remaining
        // *sealed* chunks only. The active writer can temporarily keep the
        // process above the ceiling until it is sealed; mutating it would race
        // ACK-gated appends and risks loss.
        if projected > maximumRawBytes {
            for chunk in ordered where chunk.isSealed && !selected.contains(chunk.identifier) {
                selected.insert(chunk.identifier)
                candidates.append(Candidate(chunk: chunk, reason: .hardCapPressure))
                projected = projected >= chunk.byteCount ? projected - chunk.byteCount : 0
                if projected <= maximumRawBytes { break }
            }
        }

        return Plan(
            candidates: candidates,
            rawBytesBefore: total,
            projectedRawBytes: projected,
            hardCapSatisfied: projected <= maximumRawBytes,
            blockedActiveBytes: ordered.filter { !$0.isSealed }.reduce(0) { $0 + $1.byteCount }
        )
    }
}
