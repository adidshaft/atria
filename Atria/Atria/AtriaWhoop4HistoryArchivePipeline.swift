import Foundation

/// Decode + durable-persistence boundary for WHOOP 4 historical frames.
///
/// The BLE manager owns transport ordering only. This module owns the versioned
/// decode, clock correction, metric usability decision, stable archive identity,
/// and append result returned to the drain reducer.
enum AtriaWhoop4HistoryArchivePipeline {
    struct ClockReference: Sendable {
        let device: UInt32
        let wall: UInt32
        let driftSeconds: Int
        let snappedDriftSeconds: Int
    }

    struct Computation {
        enum Payload {
            case record(HistoricalArchive.Record)
            case undecodable(payload: [UInt8], reason: String)
        }

        /// The decoded frame log is intentionally absent in normal Release
        /// operation. Formatting several hundred bytes of diagnostics for
        /// every row in a full-flash drain consumed measurable CPU even though
        /// `AtriaDebugLog` ultimately discarded it.
        let logMessage: String?
        let rawPayload: [UInt8]
        let payload: Payload
    }

    struct PersistenceResult {
        let succeeded: Bool
        let inserted: Bool
        let archivedUndecodable: Bool
        let currentSessionUsable: Bool
        let metricUsable: Bool
        let reason: String?
        let persistedPath: String
        let errorDescription: String?
        let effectiveUnix: UInt32?
    }

    static func prepare(
        payload: [UInt8],
        clock: ClockReference?,
        historyClockSyncEnabled: Bool,
        now: Date = Date()
    ) -> Computation {
        let decoded = AtriaWhoop4HistoricalRecordDecoder.decode(payload)
        guard case .record(let decodedRecord) = decoded else {
            let reason = decoded.decodeFailure
                .map { "decoder_\(String(describing: $0.reason))" }
                ?? "decoder_unknown_failure"
            return Computation(
                logMessage: AtriaDebugLogging.isEnabled
                    ? String(
                        format: "ATRIADBG historicalData decoded=0 reason=%@ len=%d payload=%@",
                        reason,
                        payload.count,
                        hex(payload)
                    )
                    : nil,
                rawPayload: payload,
                payload: .undecodable(payload: payload, reason: reason)
            )
        }

        let layoutVersion = HistoricalArchive.layoutVersion(for: decodedRecord.layout.rawValue)
        let unix = decodedRecord.timestampSeconds
        let subsecond = decodedRecord.subsecond ?? 0
        let counter = decodedRecord.counter
        let physiology = decodedRecord.physiology
        let decodedHeartRate = physiology?.decodedHeartRateBPM ?? -1
        let acceptedHeartRate = physiology?.acceptedHeartRateBPM
        let decodedRR = physiology?.decodedRRIntervalsMilliseconds ?? []
        let acceptedRR = physiology?.acceptedRRIntervalsMilliseconds
        let gravity = decodedRecord.gravity
        let gravityValidated = gravity.magnitude.isFinite
            && (0.5...1.8).contains(gravity.magnitude)

        let correctedUnix: UInt32?
        let clockStatus: String
        if let clock, unix > 0 {
            let corrected = Int64(unix) + Int64(clock.snappedDriftSeconds)
            correctedUnix = corrected > 0 && corrected <= Int64(UInt32.max)
                ? UInt32(corrected)
                : nil
            clockStatus = abs(clock.driftSeconds) >= 86_400
                ? "stale_corrected_diagnostic_only"
                : "clock_ref_present"
        } else if historyClockSyncEnabled {
            correctedUnix = nil
            clockStatus = "clock_ref_missing"
        } else {
            correctedUnix = nil
            clockStatus = "clock_sync_not_requested"
        }

        let currentSessionUsable = (correctedUnix ?? unix) > 0
            && gravityValidated
            && (acceptedHeartRate != nil || acceptedRR != nil)
        let effectiveUnix = correctedUnix ?? unix
        let effectiveAgeSeconds = effectiveUnix > 0
            ? Int(now.timeIntervalSince1970.rounded()) - Int(effectiveUnix)
            : nil
        let recentTwelveHours = effectiveAgeSeconds
            .map { $0 >= 0 && $0 <= 12 * 60 * 60 } ?? false
        let metricUsable = HistoricalArchive.metricLayoutValidated(layoutVersion)
            && clockStatus == "clock_ref_present"
            && gravityValidated
            && acceptedHeartRate != nil

        let usabilityReason: String
        if metricUsable {
            usabilityReason = "verified_v24_heart_rate"
        } else if decodedRecord.layout == .v25 {
            usabilityReason = "v25_motion_only_no_hr_rr_layout"
        } else if acceptedHeartRate == nil {
            usabilityReason = "physiology_withheld_\(String(describing: physiology?.gate))"
        } else if !HistoricalArchive.metricLayoutValidated(layoutVersion) {
            usabilityReason = "decoded_layout_not_captured_validated"
        } else if clockStatus != "clock_ref_present" {
            usabilityReason = "historical_clock_not_verified"
        } else {
            usabilityReason = "historical_gravity_not_plausible"
        }

        let payloadHex = hex(payload)
        let logMessage = AtriaDebugLogging.isEnabled
            ? String(
                format: "ATRIADBG historicalData decoded=1 layout=%@ metric_usable=%d unix=%u subsec=%u counter=%u len=%d hr=%d hr_accepted=%d rr_count=%d rr_accepted=%d rr=%@ gravity_mag=%.3f gravity_validated=%d clock_status=%@ clock_device_ref=%@ clock_wall_ref=%@ clock_drift_s=%@ clock_snapped_drift_s=%@ clock_corrected_unix=%@ clock_effective_unix=%u clock_effective_age_s=%@ clock_recent_12h=%d payload=%@",
                layoutVersion,
                metricUsable ? 1 : 0,
                unix,
                subsecond,
                counter,
                payload.count,
                decodedHeartRate,
                acceptedHeartRate != nil ? 1 : 0,
                decodedRR.count,
                acceptedRR != nil ? 1 : 0,
                decodedRR.map(String.init).joined(separator: ","),
                gravity.magnitude,
                gravityValidated ? 1 : 0,
                clockStatus,
                clock.map { String($0.device) } ?? "none",
                clock.map { String($0.wall) } ?? "none",
                clock.map { String($0.driftSeconds) } ?? "none",
                clock.map { String($0.snappedDriftSeconds) } ?? "none",
                correctedUnix.map(String.init) ?? "none",
                effectiveUnix,
                effectiveAgeSeconds.map(String.init) ?? "none",
                recentTwelveHours ? 1 : 0,
                payloadHex
            )
            : nil

        var record = HistoricalArchive.Record(
            schema: HistoricalArchive.schema,
            capturedAt: now,
            source: "0x2f",
            layoutVersion: layoutVersion,
            sequence: Int(decodedRecord.layout.rawValue),
            command: Int(AtriaWhoop4HistoricalRecordDecoder.packetType),
            unix7: unix,
            subsec11: subsecond,
            flash13: counter,
            payloadLength: payload.count,
            whoofHR17: decodedHeartRate,
            whoofRRNum18: decodedRR.count,
            whoofRR19: decodedRR,
            kRR64: [],
            gravityX36: gravity.x,
            gravityY40: gravity.y,
            gravityZ44: gravity.z,
            unknownMotionScalar32: decodedRecord.unknownMotionScalar32,
            gravityMagnitude: gravity.magnitude,
            gravityValidated: gravityValidated,
            candidateRR: [],
            rawPayloadHex: payloadHex,
            clockDeviceRef: clock?.device,
            clockWallRef: clock?.wall,
            clockDriftSeconds: clock?.driftSeconds,
            clockCorrectedUnix7: correctedUnix,
            clockCorrectionStatus: clockStatus,
            currentSessionUsable: currentSessionUsable,
            metricUsable: metricUsable,
            usabilityReason: usabilityReason
        )
        record.motionTickCounter88 =
            decodedRecord.motionTickCounter.map(Int.init)
        return Computation(logMessage: logMessage,
                           rawPayload: payload,
                           payload: .record(record))
    }

    static func persist(
        _ computation: Computation,
        strapIdentifier: String,
        generation: UInt64
    ) -> PersistenceResult {
        do {
            switch computation.payload {
            case .record(var record):
                record.strapIdentifier = strapIdentifier
                let identity = AtriaHistoricalArchiveDurableStore.FrameIdentity.whoop4(
                    strapIdentifier: strapIdentifier,
                    payload: Data(computation.rawPayload)
                )
                let append = try HistoricalArchive.appendDurably(
                    record,
                    identity: identity,
                    generation: generation
                )
                do {
                    _ = try AtriaWhoop4MotionTickCompactStore.shared.append(
                        record: record,
                        rawPayload: computation.rawPayload,
                        strapIdentifier: strapIdentifier
                    )
                } catch {
                    // The compact shard is a rebuildable projection cache. Raw
                    // archive admission remains successful, while the exact
                    // bank ticket stays unresolved until compact publication
                    // succeeds or the foreground legacy scan rebuilds it.
                    AtriaDebugLog(
                        "ATRIADBG whoop4_motion_compact status=append_failed generation=%llu error=%@ action=retain_raw_ticket_unresolved",
                        generation,
                        String(describing: error)
                    )
                }
                return PersistenceResult(
                    succeeded: true,
                    inserted: append.inserted,
                    archivedUndecodable: false,
                    currentSessionUsable: record.currentSessionUsable,
                    metricUsable: record.metricUsable,
                    reason: nil,
                    persistedPath: documentsRelativePath(for: append.url),
                    errorDescription: nil,
                    effectiveUnix: record.clockCorrectedUnix7 ?? record.unix7
                )

            case .undecodable(let payload, let reason):
                let identity = AtriaHistoricalArchiveDurableStore.FrameIdentity.whoop4(
                    strapIdentifier: strapIdentifier,
                    payload: Data(payload)
                )
                let append = try HistoricalArchive.appendUndecodableDurably(
                    payload: payload,
                    reason: reason,
                    identity: identity,
                    generation: generation
                )
                return PersistenceResult(
                    succeeded: true,
                    inserted: append.inserted,
                    archivedUndecodable: true,
                    currentSessionUsable: false,
                    metricUsable: false,
                    reason: reason,
                    persistedPath: documentsRelativePath(for: append.url),
                    errorDescription: nil,
                    effectiveUnix: nil
                )
            }
        } catch {
            return PersistenceResult(
                succeeded: false,
                inserted: false,
                archivedUndecodable: false,
                currentSessionUsable: false,
                metricUsable: false,
                reason: nil,
                persistedPath: HistoricalArchive.relativePath,
                errorDescription: String(describing: error)
                    .replacingOccurrences(of: " ", with: "_"),
                effectiveUnix: nil
            )
        }
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func u32le(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    private static func u16le(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func documentsRelativePath(for url: URL) -> String {
        let documents = FileManager.default.urls(for: .documentDirectory,
                                                  in: .userDomainMask)[0]
        guard url.path.hasPrefix(documents.path) else { return url.path }
        let relative = url.path.dropFirst(documents.path.count)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return "Documents/\(relative)"
    }
}
