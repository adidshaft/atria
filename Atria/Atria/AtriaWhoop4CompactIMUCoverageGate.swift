import Foundation

/// Step 6 / 7 measurement for live compact `0x33`, not a start command.
///
/// Continuity PASS requires ~6000 live frames and adjacent device-time Δt ≤ 1 s.
/// `hist_lastNotify` snapshots can never PASS. Equal-quality backfill is
/// compact-shaped Harvard type `0x34` only — not leftover 2B and not 1 Hz 0x2F.
enum AtriaWhoop4CompactIMUCoverageGate {
    static let requiredLiveFrames = 6_000
    static let maximumAdjacentDeviceDeltaSeconds: UInt32 = 1
    static let historicalPacketType: UInt8 = 0x34

    enum Provenance: String, Sendable {
        case live
        case histLastNotify = "hist_lastNotify"
        case histEvidence = "hist_evidence"
        case histImport = "hist_import"
        case unknown

        var allowsContinuityPass: Bool { self == .live }
    }

    struct ContinuityVerdict: Equatable, Sendable {
        let provenance: Provenance
        let frameCount: Int
        let adjacentPairs: Int
        let pairsWithinOneSecond: Int
        /// Device-time seconds absent between adjacent stamps (Δt − 1 when Δt > 1).
        let missingCount: Int
        let medianDeltaSeconds: Double?
        let maxDeltaSeconds: UInt32?
        let passed: Bool
        let reason: String

        var dictionary: [String: Any] {
            var payload: [String: Any] = [
                "provenance": provenance.rawValue,
                "frame_count": frameCount,
                "required_live_frames": requiredLiveFrames,
                "adjacent_pairs": adjacentPairs,
                "pairs_within_1s": pairsWithinOneSecond,
                "missing_count": missingCount,
                "passed": passed,
                "reason": reason,
            ]
            if let medianDeltaSeconds {
                payload["median_delta_s"] = medianDeltaSeconds
            }
            if let maxDeltaSeconds {
                payload["max_delta_s"] = Int(maxDeltaSeconds)
            }
            return payload
        }
    }

    struct BackfillVerdict: Equatable, Sendable {
        let equalQuality34Count: Int
        let passed: Bool
        let reason: String

        var dictionary: [String: Any] {
            [
                "equal_quality_34": equalQuality34Count,
                "passed": passed,
                "reason": reason,
            ]
        }
    }

    static func evaluateContinuity(
        deviceTimestamps: [UInt32],
        provenance: Provenance
    ) -> ContinuityVerdict {
        let sorted = deviceTimestamps.sorted()
        var deltas: [UInt32] = []
        if sorted.count >= 2 {
            deltas.reserveCapacity(sorted.count - 1)
            for index in 1..<sorted.count {
                deltas.append(sorted[index] &- sorted[index - 1])
            }
        }
        let withinOne = deltas.filter { $0 <= maximumAdjacentDeviceDeltaSeconds }.count
        let missingCount = deltas.reduce(0) { partial, delta in
            guard delta > maximumAdjacentDeviceDeltaSeconds else { return partial }
            return partial + Int(delta - maximumAdjacentDeviceDeltaSeconds)
        }
        let median = Self.median(deltas)
        let maxDelta = deltas.max()
        let liveEnough = provenance.allowsContinuityPass
            && sorted.count >= requiredLiveFrames
            && !deltas.isEmpty
            && withinOne == deltas.count
        let reason: String
        if !provenance.allowsContinuityPass {
            reason = "provenance_\(provenance.rawValue)_not_live"
        } else if sorted.count < requiredLiveFrames {
            reason = "live_frame_count_below_\(requiredLiveFrames)"
        } else if deltas.isEmpty || withinOne != deltas.count {
            reason = "adjacent_device_delta_exceeds_1s"
        } else {
            reason = "pass"
        }
        return ContinuityVerdict(
            provenance: provenance,
            frameCount: sorted.count,
            adjacentPairs: deltas.count,
            pairsWithinOneSecond: withinOne,
            missingCount: missingCount,
            medianDeltaSeconds: median,
            maxDeltaSeconds: maxDelta,
            passed: liveEnough,
            reason: reason
        )
    }

    /// Compact-shaped Harvard `0x34` (same 10+10 planar header as live `0x33`).
    /// Rejects leftover R10/R11 and last-notify `0x33`.
    static func equalQualityHistoricalIMUFrame(from data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count >= 9, bytes[0] == 0xAA else { return nil }
        let declaredLength = Int(bytes[1]) | (Int(bytes[2]) << 8)
        let frameLength = declaredLength + 4
        guard declaredLength >= AtriaWhoop4CompactIMUDecoder.headerBytes + 1,
              bytes.count >= frameLength,
              bytes[3] == crc8([bytes[1], bytes[2]]) else { return nil }
        let payload = Array(bytes[4..<declaredLength])
        guard payload.first == historicalPacketType else { return nil }
        guard payload.count >= AtriaWhoop4CompactIMUDecoder.headerBytes else { return nil }
        let accelCount = Int(UInt16(payload[20]) | (UInt16(payload[21]) << 8))
        let gyroCount = Int(UInt16(payload[22]) | (UInt16(payload[23]) << 8))
        guard accelCount == 10, gyroCount == 10 else { return nil }
        let needed = AtriaWhoop4CompactIMUDecoder.headerBytes + accelCount * 6 + gyroCount * 6
        guard payload.count >= needed else { return nil }
        return Data(bytes[0..<frameLength])
    }

    static func evaluateBackfill(equalQuality34Count: Int) -> BackfillVerdict {
        if equalQuality34Count > 0 {
            return BackfillVerdict(
                equalQuality34Count: equalQuality34Count,
                passed: true,
                reason: "pass"
            )
        }
        return BackfillVerdict(
            equalQuality34Count: 0,
            passed: false,
            reason: "no_compact_shaped_0x34"
        )
    }

    private static func median(_ values: [UInt32]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 0 {
            return Double(sorted[mid - 1]) + Double(sorted[mid] - sorted[mid - 1]) / 2
        }
        return Double(sorted[mid])
    }

    private static func crc8(_ bytes: [UInt8]) -> UInt8 {
        var crc: UInt8 = 0
        for byte in bytes {
            crc ^= byte
            for _ in 0..<8 {
                crc = crc & 0x80 != 0 ? ((crc << 1) ^ 0x07) : (crc << 1)
            }
        }
        return crc
    }
}
