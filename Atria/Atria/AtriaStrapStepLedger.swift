import Darwin
import Foundation

/// A tiny crash-recovery checkpoint for strap-native steps. This deliberately
/// does not live inside `ActiveSessionJournal`: valid R10 motion can continue
/// while HR is zero, rejected, or temporarily absent.
enum AtriaStrapStepLedger {
    struct RecoveredCheckpoint: Equatable, Sendable {
        let record: Record
        let quarantinedMalformedURL: URL
    }

    struct Record: Codable, Equatable, Sendable {
        let schema: Int
        let segmentID: UUID
        let segmentStartedAt: Date
        let updatedAt: Date
        let segmentSteps: Int
        let segmentRawSteps: Int
        let cumulativeSteps: Int
        let cumulativeRawSteps: Int
        let deviceTimestamp: UInt32?
        let state: String?
        var segmentGyroCadenceResearchSteps: Int? = nil
        var cumulativeGyroCadenceResearchSteps: Int? = nil
    }

    enum SaveError: Error, Equatable, LocalizedError {
        case malformed
        case mismatchedSegment
        case regressedCount
        case staleWatermark
        case unavailableStorage

        var errorDescription: String? {
            switch self {
            case .malformed: return "malformed_ledger"
            case .mismatchedSegment: return "mismatched_segment"
            case .regressedCount: return "regressed_count"
            case .staleWatermark: return "stale_watermark"
            case .unavailableStorage: return "unavailable_storage"
            }
        }
    }

    static let schema = 1
    static let maximumCount = 10_000_000
    static let maximumRestoreAge: TimeInterval = 18 * 60 * 60
    private static let fileName = "atria-strap-step-ledger.json"
    private static let ioLock = NSLock()

    static var url: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(fileName)
    }

    static func load(now: Date = Date(), from target: URL? = url) -> Record? {
        ioLock.lock()
        defer { ioLock.unlock() }
        guard let target else { return nil }
        return loadLocked(now: now, from: target)
    }

    /// A valid but old count remains useful, while its old strap clock is not
    /// safe as a replay watermark after a long process gap. Atomically retain
    /// the count and retire only that watermark before launch restoration.
    static func loadForRestore(now: Date = Date(), from target: URL? = url) -> Record? {
        ioLock.lock()
        defer { ioLock.unlock() }
        guard let target,
              let stored = loadLocked(now: now, from: target, enforcesFreshness: false) else {
            return nil
        }
        let age = now.timeIntervalSince(stored.updatedAt)
        guard age > maximumRestoreAge else {
            return age >= 0 ? stored : nil
        }
        let resumed = Record(
            schema: stored.schema,
            segmentID: stored.segmentID,
            segmentStartedAt: stored.segmentStartedAt,
            updatedAt: now,
            segmentSteps: stored.segmentSteps,
            segmentRawSteps: stored.segmentRawSteps,
            cumulativeSteps: stored.cumulativeSteps,
            cumulativeRawSteps: stored.cumulativeRawSteps,
            deviceTimestamp: nil,
            state: stored.state,
            segmentGyroCadenceResearchSteps: stored.segmentGyroCadenceResearchSteps,
            cumulativeGyroCadenceResearchSteps: stored.cumulativeGyroCadenceResearchSteps
        )
        guard isValid(resumed, now: now) else { return nil }
        do {
            try writeLocked(resumed, to: target)
            return resumed
        } catch {
            return nil
        }
    }

    /// Creates or advances the current accounting segment. The read/validate/
    /// reconcile/write transaction is held under one lock so a delayed async
    /// write cannot replace a newer checkpoint.
    @discardableResult
    static func checkpoint(
        segmentID: UUID,
        segmentStartedAt: Date,
        segmentSteps: Int,
        segmentRawSteps: Int,
        deviceTimestamp: UInt32?,
        state: String?,
        gyroCadenceResearchSteps: Int? = nil,
        now: Date = Date(),
        at target: URL? = url,
        unhandedRebindingSourceSegmentID: UUID? = nil
    ) throws -> Record {
        ioLock.lock()
        defer { ioLock.unlock() }
        guard let target else { throw SaveError.unavailableStorage }
        let existing = loadLocked(now: now, from: target, enforcesFreshness: false)
        if existing == nil, FileManager.default.fileExists(atPath: target.path) {
            throw SaveError.malformed
        }
        let record: Record
        if let unhandedRebindingSourceSegmentID,
           let existing,
           existing.segmentID != segmentID {
            // This narrowly-scoped recovery is enabled only while restoring an
            // unhanded live R10 prefix. First advance the old identity using
            // all ordinary monotonic/watermark checks, then transfer ownership
            // of that exact prefix. Delayed writers do not pass this flag and
            // therefore still fail with `mismatchedSegment`.
            guard existing.segmentID == unhandedRebindingSourceSegmentID else {
                throw SaveError.mismatchedSegment
            }
            let observed = try reconciledCheckpoint(
                existing: existing,
                segmentID: existing.segmentID,
                segmentStartedAt: existing.segmentStartedAt,
                segmentSteps: segmentSteps,
                segmentRawSteps: segmentRawSteps,
                deviceTimestamp: deviceTimestamp,
                state: state,
                gyroCadenceResearchSteps: gyroCadenceResearchSteps,
                now: now
            )
            record = Record(
                schema: schema,
                segmentID: segmentID,
                segmentStartedAt: min(segmentStartedAt, now),
                updatedAt: now,
                segmentSteps: observed.segmentSteps,
                segmentRawSteps: observed.segmentRawSteps,
                cumulativeSteps: observed.cumulativeSteps,
                cumulativeRawSteps: observed.cumulativeRawSteps,
                deviceTimestamp: observed.deviceTimestamp,
                state: observed.state,
                segmentGyroCadenceResearchSteps: observed.segmentGyroCadenceResearchSteps,
                cumulativeGyroCadenceResearchSteps: observed.cumulativeGyroCadenceResearchSteps
            )
            guard isValid(record, now: now, enforcesFreshness: false) else {
                throw SaveError.malformed
            }
        } else {
            record = try reconciledCheckpoint(
                existing: existing,
                segmentID: segmentID,
                segmentStartedAt: segmentStartedAt,
                segmentSteps: segmentSteps,
                segmentRawSteps: segmentRawSteps,
                deviceTimestamp: deviceTimestamp,
                state: state,
                gyroCadenceResearchSteps: gyroCadenceResearchSteps,
                now: now
            )
        }
        try writeLocked(record, to: target)
        return record
    }

    /// Preserves a structurally unreadable ledger byte-for-byte, then seeds a
    /// fresh atomic checkpoint from the caller's current in-memory segment.
    /// This is deliberately separate from `checkpoint`: valid ledgers still
    /// fail closed on segment, count, and watermark conflicts.
    @discardableResult
    static func recoverMalformedFileAndCheckpoint(
        segmentID: UUID,
        segmentStartedAt: Date,
        segmentSteps: Int,
        segmentRawSteps: Int,
        deviceTimestamp: UInt32?,
        state: String?,
        gyroCadenceResearchSteps: Int? = nil,
        now: Date = Date(),
        at target: URL? = url,
        quarantineID: UUID = UUID()
    ) throws -> RecoveredCheckpoint {
        ioLock.lock()
        defer { ioLock.unlock() }
        guard let target else { throw SaveError.unavailableStorage }
        guard FileManager.default.fileExists(atPath: target.path),
              loadLocked(now: now,
                         from: target,
                         enforcesFreshness: false) == nil else {
            throw SaveError.malformed
        }

        let quarantineURL = target.deletingPathExtension()
            .appendingPathExtension("corrupt-\(quarantineID.uuidString).json")
        try FileManager.default.moveItem(at: target, to: quarantineURL)
        try synchronizeDirectoryLocked(target.deletingLastPathComponent())

        let record = try reconciledCheckpoint(
            existing: nil,
            segmentID: segmentID,
            segmentStartedAt: segmentStartedAt,
            segmentSteps: segmentSteps,
            segmentRawSteps: segmentRawSteps,
            deviceTimestamp: deviceTimestamp,
            state: state,
            gyroCadenceResearchSteps: gyroCadenceResearchSteps,
            now: now
        )
        try writeLocked(record, to: target)
        return RecoveredCheckpoint(
            record: record,
            quarantinedMalformedURL: quarantineURL
        )
    }

    /// Moves to a new detector-accounting segment only after the caller has
    /// durably handed off the exact old prefix. Cumulative user-facing totals
    /// and the replay watermark remain intact.
    @discardableResult
    static func rotate(
        from segmentID: UUID,
        finalizedSteps: Int,
        finalizedRawSteps: Int,
        deviceTimestamp: UInt32?,
        finalizedGyroCadenceResearchSteps: Int? = nil,
        to nextSegmentID: UUID,
        nextSegmentStartedAt: Date,
        now: Date = Date(),
        at target: URL? = url
    ) throws -> Record {
        ioLock.lock()
        defer { ioLock.unlock() }
        guard let target else { throw SaveError.unavailableStorage }
        guard let existing = loadLocked(now: now, from: target, enforcesFreshness: false) else {
            throw SaveError.malformed
        }
        let finalized = try reconciledCheckpoint(
            existing: existing,
            segmentID: segmentID,
            segmentStartedAt: existing.segmentStartedAt,
            segmentSteps: finalizedSteps,
            segmentRawSteps: finalizedRawSteps,
            deviceTimestamp: deviceTimestamp,
            state: existing.state,
            gyroCadenceResearchSteps: finalizedGyroCadenceResearchSteps,
            now: now
        )
        let rotated = Record(
            schema: schema,
            segmentID: nextSegmentID,
            segmentStartedAt: nextSegmentStartedAt,
            updatedAt: now,
            segmentSteps: 0,
            segmentRawSteps: 0,
            cumulativeSteps: finalized.cumulativeSteps,
            cumulativeRawSteps: finalized.cumulativeRawSteps,
            deviceTimestamp: finalized.deviceTimestamp,
            state: finalized.state,
            segmentGyroCadenceResearchSteps: finalizedGyroCadenceResearchSteps == nil ? nil : 0,
            cumulativeGyroCadenceResearchSteps: finalized.cumulativeGyroCadenceResearchSteps
        )
        guard isValid(rotated, now: now, enforcesFreshness: false) else {
            throw SaveError.malformed
        }
        try writeLocked(rotated, to: target)
        return rotated
    }

    /// Changes only ownership of an unhanded detector prefix. This is used
    /// when an accounting boundary advances its generation without durably
    /// handing the prefix to the closing SavedSession. Nothing is cleared or
    /// counted twice: the same contribution becomes the new segment prefix.
    @discardableResult
    static func resegmentPreservingUnhandedPrefix(
        from segmentID: UUID,
        observedSteps: Int,
        observedRawSteps: Int,
        deviceTimestamp: UInt32?,
        observedGyroCadenceResearchSteps: Int? = nil,
        to nextSegmentID: UUID,
        carriedSteps: Int,
        carriedRawSteps: Int,
        carriedGyroCadenceResearchSteps: Int? = nil,
        nextSegmentStartedAt: Date,
        now: Date = Date(),
        at target: URL? = url
    ) throws -> Record {
        ioLock.lock()
        defer { ioLock.unlock() }
        guard let target else { throw SaveError.unavailableStorage }
        guard let existing = loadLocked(now: now, from: target, enforcesFreshness: false) else {
            throw SaveError.malformed
        }
        let observed = try reconciledCheckpoint(
            existing: existing,
            segmentID: segmentID,
            segmentStartedAt: existing.segmentStartedAt,
            segmentSteps: observedSteps,
            segmentRawSteps: observedRawSteps,
            deviceTimestamp: deviceTimestamp,
            state: existing.state,
            gyroCadenceResearchSteps: observedGyroCadenceResearchSteps,
            now: now
        )
        let carriedGyroIsValid = carriedGyroCadenceResearchSteps.map {
            $0 >= 0 && $0 <= (observed.segmentGyroCadenceResearchSteps ?? 0)
        } ?? true
        guard carriedSteps >= 0,
              carriedRawSteps >= 0,
              carriedSteps <= observed.segmentSteps,
              carriedRawSteps <= observed.segmentRawSteps,
              carriedGyroIsValid else {
            throw SaveError.malformed
        }
        let resegmented = Record(
            schema: schema,
            segmentID: nextSegmentID,
            segmentStartedAt: nextSegmentStartedAt,
            updatedAt: now,
            segmentSteps: carriedSteps,
            segmentRawSteps: carriedRawSteps,
            cumulativeSteps: observed.cumulativeSteps,
            cumulativeRawSteps: observed.cumulativeRawSteps,
            deviceTimestamp: observed.deviceTimestamp,
            state: observed.state,
            segmentGyroCadenceResearchSteps: carriedGyroCadenceResearchSteps,
            cumulativeGyroCadenceResearchSteps: observed.cumulativeGyroCadenceResearchSteps
        )
        guard isValid(resegmented, now: now, enforcesFreshness: false) else {
            throw SaveError.malformed
        }
        try writeLocked(resegmented, to: target)
        return resegmented
    }

    static func isValid(
        _ record: Record,
        now: Date = Date(),
        enforcesFreshness: Bool = true
    ) -> Bool {
        let segmentGyroIsValid = record.segmentGyroCadenceResearchSteps.map {
            $0 >= 0 && $0 <= maximumCount
        } ?? true
        let cumulativeGyroIsValid = record.cumulativeGyroCadenceResearchSteps.map {
            $0 >= (record.segmentGyroCadenceResearchSteps ?? 0)
                && $0 <= maximumCount
        } ?? (record.segmentGyroCadenceResearchSteps == nil)
        guard record.schema == schema,
              record.segmentSteps >= 0,
              record.segmentRawSteps >= 0,
              record.cumulativeSteps >= record.segmentSteps,
              record.cumulativeRawSteps >= record.segmentRawSteps,
              record.cumulativeSteps <= maximumCount,
              record.cumulativeRawSteps <= maximumCount,
              segmentGyroIsValid,
              cumulativeGyroIsValid,
              record.segmentStartedAt.timeIntervalSince1970.isFinite,
              record.updatedAt.timeIntervalSince1970.isFinite,
              record.updatedAt >= record.segmentStartedAt,
              record.state.map({ $0.count <= 80 }) ?? true else {
            return false
        }
        // Legacy records store an acceleration-derived primary count and its
        // raw peak count, so their ratio is an integrity check. Promoted R10
        // gyro records intentionally retain raw peaks only as diagnostics;
        // forcing a cross-detector ratio would reject a valid durable walking
        // prefix (and lose it on relaunch).
        let usesPromotedGyroCoordinate = record.state == "r10_live_validated"
        if !usesPromotedGyroCoordinate,
           record.segmentRawSteps == 0,
           record.segmentSteps != 0 { return false }
        if !usesPromotedGyroCoordinate, record.segmentRawSteps > 0 {
            let ratio = Double(record.segmentSteps) / Double(record.segmentRawSteps)
            guard ratio >= 0.5, ratio <= 2 else { return false }
        }
        if let timestamp = record.deviceTimestamp, timestamp == 0 { return false }
        guard enforcesFreshness else { return true }
        let age = now.timeIntervalSince(record.updatedAt)
        return age >= 0 && age <= maximumRestoreAge
    }

    static func forwardDeviceTimestampDelta(from previous: UInt32,
                                            to current: UInt32) -> UInt32? {
        let delta = current &- previous
        guard delta > 0, delta < (UInt32.max / 2 + 1) else { return nil }
        return delta
    }

    private static func reconciledCheckpoint(
        existing: Record?,
        segmentID: UUID,
        segmentStartedAt: Date,
        segmentSteps: Int,
        segmentRawSteps: Int,
        deviceTimestamp: UInt32?,
        state: String?,
        gyroCadenceResearchSteps: Int?,
        now: Date
    ) throws -> Record {
        let gyroStepsAreValid = gyroCadenceResearchSteps.map {
            $0 >= 0 && $0 <= maximumCount
        } ?? true
        guard segmentSteps >= 0,
              segmentRawSteps >= 0,
              segmentSteps <= maximumCount,
              segmentRawSteps <= maximumCount,
              gyroStepsAreValid,
              deviceTimestamp != 0 else {
            throw SaveError.malformed
        }

        let priorSegmentSteps: Int
        let priorSegmentRawSteps: Int
        let priorCumulativeSteps: Int
        let priorCumulativeRawSteps: Int
        let priorTimestamp: UInt32?
        let priorSegmentGyroSteps: Int?
        let priorCumulativeGyroSteps: Int?
        if let existing {
            guard isValid(existing, now: now, enforcesFreshness: false) else {
                throw SaveError.malformed
            }
            guard existing.segmentID == segmentID else {
                throw SaveError.mismatchedSegment
            }
            guard segmentSteps >= existing.segmentSteps,
                  segmentRawSteps >= existing.segmentRawSteps else {
                throw SaveError.regressedCount
            }
            if let previous = existing.deviceTimestamp,
               let incoming = deviceTimestamp,
               incoming != previous,
               forwardDeviceTimestampDelta(from: previous, to: incoming) == nil {
                throw SaveError.staleWatermark
            }
            // A count advance must be paired with a newer device watermark.
            if segmentRawSteps > existing.segmentRawSteps,
               existing.deviceTimestamp != nil,
               deviceTimestamp == nil || deviceTimestamp == existing.deviceTimestamp {
                throw SaveError.staleWatermark
            }
            priorSegmentSteps = existing.segmentSteps
            priorSegmentRawSteps = existing.segmentRawSteps
            priorCumulativeSteps = existing.cumulativeSteps
            priorCumulativeRawSteps = existing.cumulativeRawSteps
            priorTimestamp = existing.deviceTimestamp
            if let incoming = gyroCadenceResearchSteps,
               let prior = existing.segmentGyroCadenceResearchSteps,
               incoming < prior {
                throw SaveError.regressedCount
            }
            priorSegmentGyroSteps = existing.segmentGyroCadenceResearchSteps
            priorCumulativeGyroSteps = existing.cumulativeGyroCadenceResearchSteps
        } else {
            priorSegmentSteps = 0
            priorSegmentRawSteps = 0
            priorCumulativeSteps = 0
            priorCumulativeRawSteps = 0
            priorTimestamp = nil
            priorSegmentGyroSteps = nil
            priorCumulativeGyroSteps = nil
        }

        let cumulativeSteps = priorCumulativeSteps - priorSegmentSteps + segmentSteps
        let cumulativeRawSteps = priorCumulativeRawSteps - priorSegmentRawSteps + segmentRawSteps
        let resolvedSegmentGyroSteps = gyroCadenceResearchSteps ?? priorSegmentGyroSteps
        let cumulativeGyroSteps = resolvedSegmentGyroSteps.map {
            (priorCumulativeGyroSteps ?? priorSegmentGyroSteps ?? 0)
                - (priorSegmentGyroSteps ?? 0) + $0
        }
        let record = Record(
            schema: schema,
            segmentID: segmentID,
            segmentStartedAt: min(segmentStartedAt, now),
            updatedAt: now,
            segmentSteps: segmentSteps,
            segmentRawSteps: segmentRawSteps,
            cumulativeSteps: cumulativeSteps,
            cumulativeRawSteps: cumulativeRawSteps,
            deviceTimestamp: deviceTimestamp ?? priorTimestamp,
            state: state ?? existing?.state,
            segmentGyroCadenceResearchSteps: resolvedSegmentGyroSteps,
            cumulativeGyroCadenceResearchSteps: cumulativeGyroSteps
        )
        guard isValid(record, now: now, enforcesFreshness: false) else {
            throw SaveError.malformed
        }
        return record
    }

    private static func loadLocked(
        now: Date,
        from target: URL,
        enforcesFreshness: Bool = true
    ) -> Record? {
        guard let data = try? Data(contentsOf: target),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              isValid(record, now: now, enforcesFreshness: enforcesFreshness) else {
            return nil
        }
        return record
    }

    private static func writeLocked(_ record: Record, to target: URL) throws {
        let directory = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(record)
        try data.write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        let handle = try FileHandle(forWritingTo: target)
        defer { try? handle.close() }
        try handle.synchronize()
        try synchronizeDirectoryLocked(directory)
    }

    private static func synchronizeDirectoryLocked(_ directory: URL) throws {
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
