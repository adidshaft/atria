import Foundation

/// A tiny crash-recovery checkpoint for strap-native steps. This deliberately
/// does not live inside `ActiveSessionJournal`: valid R10 motion can continue
/// while HR is zero, rejected, or temporarily absent.
enum AtriaStrapStepLedger {
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
    }

    enum SaveError: Error, Equatable {
        case malformed
        case mismatchedSegment
        case regressedCount
        case staleWatermark
        case unavailableStorage
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
            state: stored.state
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
        now: Date = Date(),
        at target: URL? = url
    ) throws -> Record {
        ioLock.lock()
        defer { ioLock.unlock() }
        guard let target else { throw SaveError.unavailableStorage }
        let existing = loadLocked(now: now, from: target, enforcesFreshness: false)
        if existing == nil, FileManager.default.fileExists(atPath: target.path) {
            throw SaveError.malformed
        }
        let record = try reconciledCheckpoint(
            existing: existing,
            segmentID: segmentID,
            segmentStartedAt: segmentStartedAt,
            segmentSteps: segmentSteps,
            segmentRawSteps: segmentRawSteps,
            deviceTimestamp: deviceTimestamp,
            state: state,
            now: now
        )
        try writeLocked(record, to: target)
        return record
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
            state: finalized.state
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
        to nextSegmentID: UUID,
        carriedSteps: Int,
        carriedRawSteps: Int,
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
            now: now
        )
        guard carriedSteps >= 0,
              carriedRawSteps >= 0,
              carriedSteps <= observed.segmentSteps,
              carriedRawSteps <= observed.segmentRawSteps else {
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
            state: observed.state
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
        guard record.schema == schema,
              record.segmentSteps >= 0,
              record.segmentRawSteps >= 0,
              record.cumulativeSteps >= record.segmentSteps,
              record.cumulativeRawSteps >= record.segmentRawSteps,
              record.cumulativeSteps <= maximumCount,
              record.cumulativeRawSteps <= maximumCount,
              record.segmentStartedAt.timeIntervalSince1970.isFinite,
              record.updatedAt.timeIntervalSince1970.isFinite,
              record.updatedAt >= record.segmentStartedAt,
              record.state.map({ $0.count <= 80 }) ?? true else {
            return false
        }
        if record.segmentRawSteps == 0, record.segmentSteps != 0 { return false }
        if record.segmentRawSteps > 0 {
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
        now: Date
    ) throws -> Record {
        guard segmentSteps >= 0,
              segmentRawSteps >= 0,
              segmentSteps <= maximumCount,
              segmentRawSteps <= maximumCount,
              deviceTimestamp != 0 else {
            throw SaveError.malformed
        }

        let priorSegmentSteps: Int
        let priorSegmentRawSteps: Int
        let priorCumulativeSteps: Int
        let priorCumulativeRawSteps: Int
        let priorTimestamp: UInt32?
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
        } else {
            priorSegmentSteps = 0
            priorSegmentRawSteps = 0
            priorCumulativeSteps = 0
            priorCumulativeRawSteps = 0
            priorTimestamp = nil
        }

        let cumulativeSteps = priorCumulativeSteps - priorSegmentSteps + segmentSteps
        let cumulativeRawSteps = priorCumulativeRawSteps - priorSegmentRawSteps + segmentRawSteps
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
            state: state ?? existing?.state
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
    }
}
