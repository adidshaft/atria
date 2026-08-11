import Darwin
import Foundation

struct ActiveSessionJournalRecord: Codable {
    var schema: Int
    var id: UUID
    var label: String
    var startedAt: Date
    var updatedAt: Date
    var samples: [Sample]
    var rrSamples: [RRSample]?
    var rawHRNotifications: Int
    var acceptedHRSamples: Int
    var zeroHRSamples: Int
    var heldArtifacts: Int
    var droppedArtifacts: Int
    var rawHRGaps: Int
    var acceptedHRGaps: Int
    var maxRawHRGap: Double
    var maxAcceptedHRGap: Double
    var batteryLevel: Int?
    var thermalState: String?
    var lowPowerMode: Bool?
    var powerMode: String?
    var cadenceMultiplier: Double?
    var strengthSets: [LoggedSet]?
    var excludedIntervals: [ExcludedInterval]?
    var eventTimeZoneIdentifier: String? = nil
    var sensorResearchProbeFrames: Int? = nil
    var spo2ResearchCandidateFrames: Int? = nil
    var skinTempResearchCandidateFrames: Int? = nil
    var skinTempResearchCandidateValueSum: Int? = nil
    var skinTempResearchCandidateValueCount: Int? = nil
    /// RESEARCH-ONLY SpO2 candidate byte-value capture at the two historical
    /// hypotheses (offsets 64/66). Optional so journals written before the
    /// capture existed remain decodable. Never rendered as an SpO2 value.
    var spo2ResearchCandidateOffset64ValueSum: Int? = nil
    var spo2ResearchCandidateOffset64ValueCount: Int? = nil
    var spo2ResearchCandidateOffset66ValueSum: Int? = nil
    var spo2ResearchCandidateOffset66ValueCount: Int? = nil
    /// Cumulative, calibration-gated R10 detector state for this live segment.
    /// Optional so journals written before step capture remain decodable.
    var strapStepResearchCount: Int? = nil
    var strapStepResearchRawCount: Int? = nil
    /// Last CRC-valid R10 device second included in the cumulative checkpoint.
    /// A relaunch restores it only as a replay watermark, never as freshness.
    var strapStepResearchDeviceTimestamp: UInt32? = nil
    var strapStepResearchState: String? = nil
    /// RESEARCH-ONLY all-day gyro-cadence shadow total for this live session.
    /// Validation evidence only — never rendered, never feeds daily steps or
    /// any production ledger. Optional so pre-schema journals stay decodable.
    var gyroCadenceResearchSteps: Int? = nil

    struct Sample: Codable {
        let t: Date
        let bpm: Int
    }

    struct RRSample: Codable {
        let t: Date
        let ms: Int
        /// Optional solely so pre-provenance journal files still decode. They
        /// remain diagnostic evidence and are not admitted to restored metrics.
        let source: AtriaRRSourceProvenance?

        init(t: Date,
             ms: Int,
             source: AtriaRRSourceProvenance? = nil) {
            self.t = t
            self.ms = ms
            self.source = source
        }
    }
}

private struct ActiveSessionJournalSegment: Codable {
    var schema: Int
    var sequence: Int
    var id: UUID
    var label: String
    var startedAt: Date
    var updatedAt: Date
    var sampleStartIndex: Int
    var samples: [ActiveSessionJournalRecord.Sample]
    /// A redundant copy of the immediately preceding sample delta. This is
    /// intentionally bounded to one segment: it lets replay bridge a single
    /// interrupted/corrupt middle write without rewriting the full live
    /// session at every checkpoint.
    var recoverySampleStartIndex: Int? = nil
    var recoverySamples: [ActiveSessionJournalRecord.Sample]? = nil
    var rrSampleStartIndex: Int
    var rrSamples: [ActiveSessionJournalRecord.RRSample]
    var recoveryRRSampleStartIndex: Int? = nil
    var recoveryRRSamples: [ActiveSessionJournalRecord.RRSample]? = nil
    var rawHRNotifications: Int
    var acceptedHRSamples: Int
    var zeroHRSamples: Int
    var heldArtifacts: Int
    var droppedArtifacts: Int
    var rawHRGaps: Int
    var acceptedHRGaps: Int
    var maxRawHRGap: Double
    var maxAcceptedHRGap: Double
    var batteryLevel: Int?
    var thermalState: String?
    var lowPowerMode: Bool?
    var powerMode: String?
    var cadenceMultiplier: Double?
    var strengthSets: [LoggedSet]?
    var excludedIntervals: [ExcludedInterval]?
    var eventTimeZoneIdentifier: String? = nil
    var sensorResearchProbeFrames: Int? = nil
    var spo2ResearchCandidateFrames: Int? = nil
    var skinTempResearchCandidateFrames: Int? = nil
    var skinTempResearchCandidateValueSum: Int? = nil
    var skinTempResearchCandidateValueCount: Int? = nil
    var spo2ResearchCandidateOffset64ValueSum: Int? = nil
    var spo2ResearchCandidateOffset64ValueCount: Int? = nil
    var spo2ResearchCandidateOffset66ValueSum: Int? = nil
    var spo2ResearchCandidateOffset66ValueCount: Int? = nil
    var strapStepResearchCount: Int? = nil
    var strapStepResearchRawCount: Int? = nil
    var strapStepResearchDeviceTimestamp: UInt32? = nil
    var strapStepResearchState: String? = nil
    var gyroCadenceResearchSteps: Int? = nil
}

enum ActiveSessionJournal {
    /// Coarse, value-only identity used to invalidate sleep-review projections
    /// when the resident journal is the only source that advanced. A five-
    /// minute bucket avoids rebuilding the overnight projection for every
    /// checkpoint while still making newly sufficient morning evidence visible.
    struct SleepReviewCacheIdentity: Equatable, Sendable {
        let id: UUID?
        let endFiveMinuteBucket: Int?

        static let empty = SleepReviewCacheIdentity(id: nil,
                                                    endFiveMinuteBucket: nil)

        /// Build cache freshness from evidence that was actually committed,
        /// never from the checkpoint wall clock. Forced lifecycle checkpoints
        /// are allowed to rewrite metadata without adding an HR/RR value; in
        /// that case this identity remains unchanged and the expensive sleep
        /// projection is not rebuilt. The evidence timestamp is still rounded
        /// to five minutes so normal sensor flow cannot rebuild on every save.
        init(id: UUID?,
             latestHRSampleAt: Date?,
             persistedHRSampleCount: Int,
             latestRRSampleAt: Date?,
             persistedRRSampleCount: Int) {
            self.id = id
            let evidenceDates = [
                persistedHRSampleCount > 0 ? latestHRSampleAt : nil,
                persistedRRSampleCount > 0 ? latestRRSampleAt : nil
            ].compactMap { $0 }
            self.endFiveMinuteBucket = evidenceDates.max().map {
                Int($0.timeIntervalSince1970 / (5 * 60))
            }
        }

        private init(id: UUID?, endFiveMinuteBucket: Int?) {
            self.id = id
            self.endFiveMinuteBucket = endFiveMinuteBucket
        }
    }

    static let didPersistSleepReviewEvidenceNotification = Notification.Name(
        "AtriaActiveSessionJournalDidPersistSleepReviewEvidence"
    )

    struct SleepReviewCacheWarmEvent: Equatable, Sendable {
        let generation: UInt64
        let containsRecord: Bool
    }

    static let didWarmSleepReviewCacheNotification = Notification.Name(
        "AtriaActiveSessionJournalDidWarmSleepReviewCache"
    )

    /// Called only after an atomic journal checkpoint succeeds. SessionStore
    /// observes this publication on MainActor; no journal file is decoded on a
    /// render or notification-routing path merely to discover freshness.
    static func publishSleepReviewCacheIdentity(id: UUID?,
                                                latestHRSampleAt: Date?,
                                                persistedHRSampleCount: Int,
                                                latestRRSampleAt: Date?,
                                                persistedRRSampleCount: Int) {
        NotificationCenter.default.post(
            name: didPersistSleepReviewEvidenceNotification,
            object: SleepReviewCacheIdentity(
                id: id,
                latestHRSampleAt: latestHRSampleAt,
                persistedHRSampleCount: persistedHRSampleCount,
                latestRRSampleAt: latestRRSampleAt,
                persistedRRSampleCount: persistedRRSampleCount
            )
        )
    }

    struct IncrementalSaveResult {
        let sampleCount: Int
        let rrSampleCount: Int
        let compacted: Bool
    }
    enum IncrementalSaveError: Error {
        case discontinuousSampleCursor(expected: Int, actual: Int)
        case discontinuousRRCursor(expected: Int, actual: Int)
    }
    struct MirroredStrengthState {
        let strengthSets: [LoggedSet]?
        let excludedIntervals: [ExcludedInterval]?
    }

    struct Diagnostics {
        let present: Bool
        let fresh: Bool
        let samples: Int
        let rrValues: Int
        let duration: TimeInterval
        let maxRRGap: TimeInterval
        let rrGapOver3: Int
        let rrCoverage3Percent: Int
        let recentRRValues: Int
        let recentRRDuration: TimeInterval
        let recentRRMaxGap: TimeInterval
        let recentRRCoverage3Percent: Int

        var hasCurrentRR: Bool {
            present && fresh && rrValues > 0
        }

        var recentRRContinuityClean: Bool {
            present
                && fresh
                && recentRRValues >= 10
                && recentRRDuration >= 10
                && recentRRMaxGap <= 3
                && recentRRCoverage3Percent >= 90
        }

        var rrContinuityReady: Bool {
            hasCurrentRR
                && duration >= 300
                && rrValues >= 240
                && maxRRGap <= 3
                && rrCoverage3Percent >= 90
        }
    }

    static let schema = 1
    private static let segmentSchema = 2
    private static let freshAgeLimitSeconds = 90
    private static let fileName = "atria-active-session.json"
    private static let legacyFileName = "whoop-active-session.json"
    private static let segmentDirectoryName = "atria-active-session.segments"
    /// The journal is a hot crash-recovery cache, not an unbounded event log.
    /// A complete replacement base preserves every value still admitted by
    /// the caller's age/sample policy while retiring delta-chain overhead.
    static let maximumSegmentChainCount = 64
    static let maximumSegmentChainBytes: UInt64 = 24 * 1_024 * 1_024
    private static let ioLock = NSLock()
    private static let strengthMirrorIOQueue = DispatchQueue(
        label: "com.atria.active-session-journal.strength-mirror",
        qos: .utility
    )
    private struct LoadCache {
        let targetPath: String
        let modifiedAt: Date
        let record: ActiveSessionJournalRecord?
    }
    private static var loadCache: LoadCache?
    private struct SegmentFingerprint: Equatable {
        let directoryModifiedAt: Date
        let latestSequence: Int?
        let latestModifiedAt: Date?
        let latestSize: UInt64?
    }
    private struct SegmentedLoadCache {
        let fingerprint: SegmentFingerprint
        let record: ActiveSessionJournalRecord?
    }
    private struct MirroredStrengthCache {
        let fingerprint: SegmentFingerprint
        let state: MirroredStrengthState
    }
    private static var segmentedLoadCache: SegmentedLoadCache?
    /// `nil` caches are ambiguous until one locked load has proved the journal
    /// absent. Sleep review must defer on cold state instead of publishing a
    /// matching empty five-minute result while launch restore is still warming.
    private static var sleepReviewCacheKnownAbsent = false
    private static var sleepReviewCacheWarmGeneration: UInt64 = 0
    private static var mirroredStrengthCache: MirroredStrengthCache?
    private static var pendingMirroredStrengthState: MirroredStrengthState?
    private static var strengthMirrorGeneration: UInt64 = 0
    private static var persistedStrengthMirrorGeneration: UInt64 = 0
    private static var lastStrengthMirrorPersistenceWasOnMainThread = false
    private static var segmentedReconstructionCount = 0
    private static var compactionReplacementDurableCheckpointForTesting: (() throws -> Void)?
    private enum LastCloseDefaults {
        static let status = "atria.activeJournal.lastClose.status"
        static let reason = "atria.activeJournal.lastClose.reason"
        static let label = "atria.activeJournal.lastClose.label"
        static let samples = "atria.activeJournal.lastClose.samples"
        static let duration = "atria.activeJournal.lastClose.duration"
        static let at = "atria.activeJournal.lastClose.at"
    }

    static var url: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent(fileName)
    }

    private static var legacyURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent(legacyFileName)
    }

    private static var segmentDirectoryURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent(segmentDirectoryName, isDirectory: true)
    }

    static func load() -> ActiveSessionJournalRecord? {
        ioLock.lock()
        let wasCold = segmentedLoadCache?.record == nil
            && loadCache?.record == nil
            && !sleepReviewCacheKnownAbsent
        let record = loadLocked()
        let becameKnown = record != nil || sleepReviewCacheKnownAbsent
        let warmEvent: SleepReviewCacheWarmEvent?
        if wasCold, becameKnown {
            sleepReviewCacheWarmGeneration &+= 1
            warmEvent = SleepReviewCacheWarmEvent(
                generation: sleepReviewCacheWarmGeneration,
                containsRecord: record != nil
            )
        } else {
            warmEvent = nil
        }
        ioLock.unlock()
        // Never deliver observers while holding the journal I/O lock. A
        // foreground retry may immediately request the cache-only snapshot.
        if let warmEvent {
            NotificationCenter.default.post(
                name: didWarmSleepReviewCacheNotification,
                object: warmEvent
            )
        }
        return record
    }

    enum CachedSleepReviewRecord {
        case busy
        case cold
        case knownAbsent
        case record(ActiveSessionJournalRecord)
    }

    /// Returns only the same-process reconstructed value already maintained by
    /// the incremental writer. It performs no directory scan, file read, or
    /// JSON decode. Lock contention is distinct from a genuinely cold cache:
    /// the review lane must defer rather than publish a five-minute empty
    /// result while a save/fsync owns the cache.
    static func cachedRecordForSleepReview() -> CachedSleepReviewRecord {
        guard ioLock.try() else { return .busy }
        defer { ioLock.unlock() }
        guard let record = segmentedLoadCache?.record ?? loadCache?.record else {
            return sleepReviewCacheKnownAbsent ? .knownAbsent : .cold
        }
        return .record(record)
    }

    private static func loadLocked() -> ActiveSessionJournalRecord? {
        if let record = loadSegmentedRecordLocked() {
            sleepReviewCacheKnownAbsent = false
            return record
        }
        // A failed segmented replay is uncertainty, not absence. This metadata
        // read is already inside the explicit file-backed restore path; the
        // cache-only review accessor never reaches it.
        let segmentedSourceExists = currentLatestSegmentSequenceLocked() != nil
        let target: URL?
        if let url, FileManager.default.fileExists(atPath: url.path) {
            target = url
        } else if let legacyURL, FileManager.default.fileExists(atPath: legacyURL.path) {
            target = legacyURL
        } else {
            target = nil
        }
        guard let target else {
            loadCache = nil
            sleepReviewCacheKnownAbsent = !segmentedSourceExists
            return nil
        }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: target.path),
              let modifiedAt = attributes[.modificationDate] as? Date else {
            loadCache = nil
            sleepReviewCacheKnownAbsent = false
            return decodeRecord(at: target)
        }
        if let cached = loadCache,
           cached.targetPath == target.path,
           cached.modifiedAt == modifiedAt {
            sleepReviewCacheKnownAbsent = false
            return cached.record
        }
        let record = decodeRecord(at: target)
        sleepReviewCacheKnownAbsent = false
        loadCache = LoadCache(targetPath: target.path,
                              modifiedAt: modifiedAt,
                              record: record)
        return record
    }

    private static func decodeRecord(at target: URL) -> ActiveSessionJournalRecord? {
        do {
            let data = try Data(contentsOf: target)
            return try JSONDecoder().decode(ActiveSessionJournalRecord.self, from: data)
        } catch {
            AtriaDebugLog("ATRIADBG active_session_journal status=load_failed error=%@", error.localizedDescription)
            return nil
        }
    }

    static func save(_ record: ActiveSessionJournalRecord,
                     previousSampleCount: Int? = nil,
                     previousRRCount: Int? = nil) throws {
        guard let segmentDirectoryURL else { return }
        ioLock.lock()
        defer { ioLock.unlock() }
        try saveLocked(record,
                       previousSampleCount: previousSampleCount,
                       previousRRCount: previousRRCount,
                       segmentDirectoryURL: segmentDirectoryURL)
    }

    /// Persists an append-only checkpoint without requiring the caller to
    /// materialize the complete live session. `record.samples` and
    /// `record.rrSamples` contain only the values beginning at the supplied
    /// cursors; metadata remains a complete latest-state snapshot.
    static func saveIncremental(_ record: ActiveSessionJournalRecord,
                                sampleStartIndex: Int,
                                rrSampleStartIndex: Int,
                                maxAge: TimeInterval,
                                maxSamples: Int) throws -> IncrementalSaveResult {
        guard let segmentDirectoryURL else {
            return IncrementalSaveResult(sampleCount: 0, rrSampleCount: 0, compacted: false)
        }
        ioLock.lock()
        defer { ioLock.unlock() }
        try FileManager.default.createDirectory(at: segmentDirectoryURL, withIntermediateDirectories: true)

        var latestSequence = currentLatestSegmentSequenceLocked()
        var latest = latestSequence.flatMap { loadSegment(sequence: $0) }
        var existing = loadSegmentedRecordLocked()
        if latest?.id != record.id {
            // A different (or absent) durable generation may only be replaced
            // by a complete base. Previously this branch deleted the durable
            // chain before cursor validation, so a stale non-zero manager
            // cursor could erase the last crash-recovery checkpoint and then
            // fail with `expected_0_actual_N`. Keep the old generation durable
            // until the caller returns with its verified full rebase.
            guard sampleStartIndex == 0 else {
                throw IncrementalSaveError.discontinuousSampleCursor(expected: 0,
                                                                      actual: sampleStartIndex)
            }
            guard rrSampleStartIndex == 0 else {
                throw IncrementalSaveError.discontinuousRRCursor(expected: 0,
                                                                  actual: rrSampleStartIndex)
            }
            clearSegmentFiles()
            segmentedLoadCache = nil
            mirroredStrengthCache = nil
            latestSequence = nil
            latest = nil
            existing = nil
        }
        let existingSamples = existing?.samples ?? []
        let existingRRSamples = existing?.rrSamples ?? []
        let expectedSamples = existingSamples.count
        let expectedRR = existingRRSamples.count
        let samples: [ActiveSessionJournalRecord.Sample]
        if sampleStartIndex == expectedSamples {
            samples = record.samples
        } else if sampleStartIndex < expectedSamples,
                  let rebased = exactReplaySafeNovelSuffix(
                    existing: existingSamples,
                    incoming: record.samples,
                    timestamp: \.t,
                    matches: { $0.t == $1.t && $0.bpm == $1.bpm }
                  ) {
            // A process relaunch resets the manager's source cursors even when
            // the durable journal still owns the same live session ID. Accept
            // only a provable exact replay plus a strictly newer suffix; never
            // discard or duplicate the durable prefix to repair the cursor.
            samples = rebased
        } else {
            throw IncrementalSaveError.discontinuousSampleCursor(expected: expectedSamples,
                                                                  actual: sampleStartIndex)
        }
        let rrSamples: [ActiveSessionJournalRecord.RRSample]
        if rrSampleStartIndex == expectedRR {
            rrSamples = record.rrSamples ?? []
        } else if rrSampleStartIndex < expectedRR,
                  let rebased = exactReplaySafeNovelSuffix(
                    existing: existingRRSamples,
                    incoming: record.rrSamples ?? [],
                    timestamp: \.t,
                    matches: {
                        $0.t == $1.t && $0.ms == $1.ms && $0.source == $1.source
                    }
                  ) {
            rrSamples = rebased
        } else {
            throw IncrementalSaveError.discontinuousRRCursor(expected: expectedRR,
                                                              actual: rrSampleStartIndex)
        }

        let nextSequence = (latestSequence ?? -1) + 1
        let segment = ActiveSessionJournalSegment(
            schema: Self.segmentSchema, sequence: nextSequence,
            id: record.id, label: record.label, startedAt: record.startedAt, updatedAt: record.updatedAt,
            sampleStartIndex: expectedSamples, samples: samples,
            recoverySampleStartIndex: latest?.sampleStartIndex, recoverySamples: latest?.samples,
            rrSampleStartIndex: expectedRR, rrSamples: rrSamples,
            recoveryRRSampleStartIndex: latest?.rrSampleStartIndex, recoveryRRSamples: latest?.rrSamples,
            rawHRNotifications: record.rawHRNotifications, acceptedHRSamples: record.acceptedHRSamples,
            zeroHRSamples: record.zeroHRSamples, heldArtifacts: record.heldArtifacts,
            droppedArtifacts: record.droppedArtifacts, rawHRGaps: record.rawHRGaps,
            acceptedHRGaps: record.acceptedHRGaps, maxRawHRGap: record.maxRawHRGap,
            maxAcceptedHRGap: record.maxAcceptedHRGap, batteryLevel: record.batteryLevel,
            thermalState: record.thermalState, lowPowerMode: record.lowPowerMode,
            powerMode: record.powerMode, cadenceMultiplier: record.cadenceMultiplier,
            strengthSets: record.strengthSets, excludedIntervals: record.excludedIntervals,
            eventTimeZoneIdentifier: record.eventTimeZoneIdentifier,
            sensorResearchProbeFrames: record.sensorResearchProbeFrames,
            spo2ResearchCandidateFrames: record.spo2ResearchCandidateFrames,
            skinTempResearchCandidateFrames: record.skinTempResearchCandidateFrames,
            skinTempResearchCandidateValueSum: record.skinTempResearchCandidateValueSum,
            skinTempResearchCandidateValueCount: record.skinTempResearchCandidateValueCount,
            spo2ResearchCandidateOffset64ValueSum: record.spo2ResearchCandidateOffset64ValueSum,
            spo2ResearchCandidateOffset64ValueCount: record.spo2ResearchCandidateOffset64ValueCount,
            spo2ResearchCandidateOffset66ValueSum: record.spo2ResearchCandidateOffset66ValueSum,
            spo2ResearchCandidateOffset66ValueCount: record.spo2ResearchCandidateOffset66ValueCount,
            strapStepResearchCount: record.strapStepResearchCount,
            strapStepResearchRawCount: record.strapStepResearchRawCount,
            strapStepResearchDeviceTimestamp: record.strapStepResearchDeviceTimestamp,
            strapStepResearchState: record.strapStepResearchState,
            gyroCadenceResearchSteps: record.gyroCadenceResearchSteps
        )
        try writeDurable(JSONEncoder().encode(segment),
                         to: segmentURL(sequence: nextSequence))
        sleepReviewCacheKnownAbsent = false
        clearLegacySnapshotFileIfPresent()
        loadCache = nil
        var updated = applying(segment, to: existing)
        if let complete = updated {
            let bounded = boundedRecord(complete, now: record.updatedAt, maxAge: maxAge, maxSamples: maxSamples)
            let valueWindowWasTrimmed = bounded.samples.count != complete.samples.count
                || (bounded.rrSamples?.count ?? 0) != (complete.rrSamples?.count ?? 0)
            let chainBudgetWasExceeded = segmentChainStorageLocked().exceedsBudget
            if valueWindowWasTrimmed || chainBudgetWasExceeded {
                // Publish a complete replacement base before removing any old
                // segment. A crash after this write can replay the old chain
                // followed by the replacement reset; a crash after cleanup can
                // replay the replacement alone. There is never a no-journal gap.
                try saveLocked(bounded,
                               previousSampleCount: 0,
                               previousRRCount: 0,
                               segmentDirectoryURL: segmentDirectoryURL)
                try compactionReplacementDurableCheckpointForTesting?()
                guard let replacementSequence = currentLatestSegmentSequenceLocked() else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                clearSegmentFiles(preservingSequence: replacementSequence)
                try synchronizeDirectory(segmentDirectoryURL)
                // Re-open the survivor after destructive cleanup and publish a
                // cache fingerprint from the post-cleanup directory state.
                // The previous implementation deliberately nulled both caches;
                // on device, the next five-second append sometimes observed no
                // reconstructible base (`expected_0_actual_N`) even though this
                // compaction had just reported success. A compaction is not
                // successful until its sole survivor replays exactly.
                guard let replacement = loadSegment(sequence: replacementSequence),
                      replacement.id == record.id,
                      let verified = applying(replacement, to: nil),
                      verified.samples.count == bounded.samples.count,
                      (verified.rrSamples?.count ?? 0) == (bounded.rrSamples?.count ?? 0),
                      let fingerprint = segmentFingerprintLocked(
                        latestSequence: replacementSequence
                      ) else {
                    segmentedLoadCache = nil
                    mirroredStrengthCache = nil
                    throw CocoaError(.fileReadCorruptFile)
                }
                segmentedLoadCache = SegmentedLoadCache(
                    fingerprint: fingerprint,
                    record: verified
                )
                mirroredStrengthCache = MirroredStrengthCache(
                    fingerprint: fingerprint,
                    state: mirroredStrengthState(from: verified)
                )
                updated = verified
                return IncrementalSaveResult(sampleCount: verified.samples.count,
                                             rrSampleCount: verified.rrSamples?.count ?? 0,
                                             compacted: true)
            }
        }
        if let updated, let fingerprint = segmentFingerprintLocked(latestSequence: nextSequence) {
            segmentedLoadCache = SegmentedLoadCache(fingerprint: fingerprint, record: updated)
            mirroredStrengthCache = MirroredStrengthCache(fingerprint: fingerprint,
                                                          state: mirroredStrengthState(from: updated))
        } else {
            segmentedLoadCache = nil
            mirroredStrengthCache = nil
        }
        return IncrementalSaveResult(sampleCount: updated?.samples.count ?? 0,
                                     rrSampleCount: updated?.rrSamples?.count ?? 0,
                                     compacted: false)
    }

    /// Returns only values not already present in an existing durable prefix.
    /// Overlap must be byte-for-byte equivalent at the same timestamp and all
    /// novel values must follow the durable tail. A conflicting or out-of-order
    /// overlap fails closed so callers cannot turn cursor recovery into data
    /// replacement.
    private static func exactReplaySafeNovelSuffix<Value>(
        existing: [Value],
        incoming: [Value],
        timestamp: (Value) -> Date,
        matches: (Value, Value) -> Bool
    ) -> [Value]? {
        guard let durableTail = existing.last.map(timestamp) else {
            return incoming
        }
        var previousIncomingTimestamp: Date?
        var existingIndex = 0
        var novel: [Value] = []
        novel.reserveCapacity(incoming.count)

        for value in incoming {
            let valueTimestamp = timestamp(value)
            if let previousIncomingTimestamp,
               valueTimestamp < previousIncomingTimestamp {
                return nil
            }
            previousIncomingTimestamp = valueTimestamp

            while existingIndex < existing.count,
                  timestamp(existing[existingIndex]) < valueTimestamp {
                existingIndex += 1
            }
            if valueTimestamp <= durableTail {
                var candidateIndex = existingIndex
                var foundExactReplay = false
                while candidateIndex < existing.count,
                      timestamp(existing[candidateIndex]) == valueTimestamp {
                    if matches(existing[candidateIndex], value) {
                        existingIndex = candidateIndex + 1
                        foundExactReplay = true
                        break
                    }
                    candidateIndex += 1
                }
                guard foundExactReplay else { return nil }
            } else {
                novel.append(value)
            }
        }
        return novel
    }

    private static func boundedRecord(_ record: ActiveSessionJournalRecord,
                                      now: Date,
                                      maxAge: TimeInterval,
                                      maxSamples: Int) -> ActiveSessionJournalRecord {
        var bounded = record
        let minimumDate = now.addingTimeInterval(-maxAge)
        let recentSamples = record.samples.suffix(maxSamples)
        let firstRecent = recentSamples.firstIndex { $0.t >= minimumDate } ?? recentSamples.endIndex
        bounded.samples = Array(recentSamples[firstRecent...])
        guard let first = bounded.samples.first, let last = bounded.samples.last else {
            bounded.rrSamples = []
            return bounded
        }
        bounded.startedAt = first.t
        bounded.rrSamples = Array((record.rrSamples ?? []).suffix(maxSamples).filter {
            $0.t >= minimumDate && $0.t >= first.t && $0.t <= last.t.addingTimeInterval(1)
        })
        return bounded
    }

    private static func saveLocked(_ record: ActiveSessionJournalRecord,
                                   previousSampleCount: Int?,
                                   previousRRCount: Int?,
                                   segmentDirectoryURL: URL) throws {
        try FileManager.default.createDirectory(at: segmentDirectoryURL, withIntermediateDirectories: true)
        var latestSequence = currentLatestSegmentSequenceLocked()
        let latest = latestSequence.flatMap { loadSegment(sequence: $0) }
        let cachedRecord = currentSegmentedCacheLocked()?.record
        var existingSampleCount = previousSampleCount ?? 0
        var existingRRCount = previousRRCount ?? 0
        var resetSegments = false
        if latest?.id != record.id {
            clearSegmentFiles()
            segmentedLoadCache = nil
            latestSequence = nil
            resetSegments = true
            existingSampleCount = 0
            existingRRCount = 0
        } else if existingSampleCount > record.samples.count
                    || existingRRCount > (record.rrSamples?.count ?? 0) {
            clearSegmentFiles()
            segmentedLoadCache = nil
            latestSequence = nil
            resetSegments = true
            existingSampleCount = 0
            existingRRCount = 0
        } else if previousSampleCount == nil || previousRRCount == nil {
            let existing = loadSegmentedRecordLocked()
            if let replayed = existing, replayed.id == record.id, recordAppends(to: replayed, with: record) {
                existingSampleCount = min(replayed.samples.count, record.samples.count)
                existingRRCount = min(replayed.rrSamples?.count ?? 0, record.rrSamples?.count ?? 0)
            } else {
                clearSegmentFiles()
                segmentedLoadCache = nil
                latestSequence = nil
                resetSegments = true
                existingSampleCount = 0
                existingRRCount = 0
            }
        }
        let nextSequence = (latestSequence ?? -1) + 1
        let segment = ActiveSessionJournalSegment(
            schema: Self.segmentSchema,
            sequence: nextSequence,
            id: record.id,
            label: record.label,
            startedAt: record.startedAt,
            updatedAt: record.updatedAt,
            sampleStartIndex: existingSampleCount,
            samples: Array(record.samples.dropFirst(existingSampleCount)),
            recoverySampleStartIndex: latest?.sampleStartIndex,
            recoverySamples: latest?.samples,
            rrSampleStartIndex: existingRRCount,
            rrSamples: Array((record.rrSamples ?? []).dropFirst(existingRRCount)),
            recoveryRRSampleStartIndex: latest?.rrSampleStartIndex,
            recoveryRRSamples: latest?.rrSamples,
            rawHRNotifications: record.rawHRNotifications,
            acceptedHRSamples: record.acceptedHRSamples,
            zeroHRSamples: record.zeroHRSamples,
            heldArtifacts: record.heldArtifacts,
            droppedArtifacts: record.droppedArtifacts,
            rawHRGaps: record.rawHRGaps,
            acceptedHRGaps: record.acceptedHRGaps,
            maxRawHRGap: record.maxRawHRGap,
            maxAcceptedHRGap: record.maxAcceptedHRGap,
            batteryLevel: record.batteryLevel,
            thermalState: record.thermalState,
            lowPowerMode: record.lowPowerMode,
            powerMode: record.powerMode,
            cadenceMultiplier: record.cadenceMultiplier,
            strengthSets: record.strengthSets,
            excludedIntervals: record.excludedIntervals,
            eventTimeZoneIdentifier: record.eventTimeZoneIdentifier,
            sensorResearchProbeFrames: record.sensorResearchProbeFrames,
            spo2ResearchCandidateFrames: record.spo2ResearchCandidateFrames,
            skinTempResearchCandidateFrames: record.skinTempResearchCandidateFrames,
            skinTempResearchCandidateValueSum: record.skinTempResearchCandidateValueSum,
            skinTempResearchCandidateValueCount: record.skinTempResearchCandidateValueCount,
            spo2ResearchCandidateOffset64ValueSum: record.spo2ResearchCandidateOffset64ValueSum,
            spo2ResearchCandidateOffset64ValueCount: record.spo2ResearchCandidateOffset64ValueCount,
            spo2ResearchCandidateOffset66ValueSum: record.spo2ResearchCandidateOffset66ValueSum,
            spo2ResearchCandidateOffset66ValueCount: record.spo2ResearchCandidateOffset66ValueCount,
            strapStepResearchCount: record.strapStepResearchCount,
            strapStepResearchRawCount: record.strapStepResearchRawCount,
            strapStepResearchDeviceTimestamp: record.strapStepResearchDeviceTimestamp,
            strapStepResearchState: record.strapStepResearchState,
            gyroCadenceResearchSteps: record.gyroCadenceResearchSteps
        )
        let data = try JSONEncoder().encode(segment)
        try writeDurable(data, to: segmentURL(sequence: nextSequence))
        sleepReviewCacheKnownAbsent = false
        clearLegacySnapshotFileIfPresent()
        loadCache = nil
        let updatedRecord: ActiveSessionJournalRecord?
        if resetSegments {
            updatedRecord = applying(segment, to: nil)
        } else if let baseRecord = segmentedLoadCache?.record ?? cachedRecord {
            updatedRecord = applying(segment, to: baseRecord)
        } else {
            updatedRecord = nil
        }
        if let updatedRecord,
           let fingerprint = segmentFingerprintLocked(latestSequence: nextSequence) {
            segmentedLoadCache = SegmentedLoadCache(fingerprint: fingerprint, record: updatedRecord)
            mirroredStrengthCache = MirroredStrengthCache(
                fingerprint: fingerprint,
                state: mirroredStrengthState(from: updatedRecord)
            )
        } else {
            segmentedLoadCache = nil
            if let fingerprint = segmentFingerprintLocked(latestSequence: nextSequence) {
                mirroredStrengthCache = MirroredStrengthCache(
                    fingerprint: fingerprint,
                    state: MirroredStrengthState(strengthSets: segment.strengthSets,
                                                 excludedIntervals: segment.excludedIntervals)
                )
            } else {
                mirroredStrengthCache = nil
            }
        }
    }

    static func clear() {
        drainStrengthMirrorWrites()
        ioLock.lock()
        defer { ioLock.unlock() }
        clearLocked()
    }

    /// Deletes a restore candidate only if no newer checkpoint replaced it.
    /// The comparison and deletion share the journal lock, so moving cleanup
    /// off the MainActor cannot race a live incremental save and erase it.
    @discardableResult
    static func clearIfUnchanged(id: UUID,
                                 updatedAt: Date,
                                 schema: Int,
                                 sampleCount: Int,
                                 rrSampleCount: Int) -> Bool {
        drainStrengthMirrorWrites()
        ioLock.lock()
        defer { ioLock.unlock() }
        guard let current = loadLocked(),
              current.id == id,
              current.updatedAt == updatedAt,
              current.schema == schema,
              current.samples.count == sampleCount,
              (current.rrSamples?.count ?? 0) == rrSampleCount else {
            return false
        }
        clearLocked()
        return true
    }

    private static func clearLocked() {
        loadCache = nil
        segmentedLoadCache = nil
        mirroredStrengthCache = nil
        pendingMirroredStrengthState = nil
        strengthMirrorGeneration = 0
        persistedStrengthMirrorGeneration = 0
        lastStrengthMirrorPersistenceWasOnMainThread = false
        clearSegmentFiles()
        for target in [url, legacyURL].compactMap({ $0 }) where FileManager.default.fileExists(atPath: target.path) {
            do {
                try FileManager.default.removeItem(at: target)
            } catch {
                AtriaDebugLog("ATRIADBG active_session_journal status=clear_failed error=%@", error.localizedDescription)
            }
        }
        sleepReviewCacheKnownAbsent = true
    }

    private static func loadSegmentedRecordLocked() -> ActiveSessionJournalRecord? {
        if let cache = currentSegmentedCacheLocked() {
            return cache.record
        }
        let segments = loadSegments()
        segmentedReconstructionCount += 1
        var record: ActiveSessionJournalRecord?
        for segment in segments {
            record = applying(segment, to: record)
        }
        let latestSequence = segments.map(\.sequence).max() ?? latestSegmentSequence()
        if let fingerprint = segmentFingerprintLocked(latestSequence: latestSequence) {
            segmentedLoadCache = SegmentedLoadCache(fingerprint: fingerprint, record: record)
        } else {
            segmentedLoadCache = nil
        }
        return record
    }

    private static func applying(_ segment: ActiveSessionJournalSegment,
                                 to existing: ActiveSessionJournalRecord?) -> ActiveSessionJournalRecord? {
        guard existing == nil || existing?.id == segment.id else { return existing }
        // A later complete base is a generation boundary. It intentionally
        // supersedes an older unbounded chain while coexisting with it during
        // crash-safe compaction.
        let replacesExistingBase = segment.sampleStartIndex == 0
            && segment.rrSampleStartIndex == 0
            && ((existing?.samples.isEmpty == false)
                || ((existing?.rrSamples?.isEmpty == false)))
        var record = (replacesExistingBase ? nil : existing) ?? ActiveSessionJournalRecord(
            schema: Self.schema,
            id: segment.id,
            label: segment.label,
            startedAt: segment.startedAt,
            updatedAt: segment.updatedAt,
            samples: [],
            rrSamples: [],
            rawHRNotifications: segment.rawHRNotifications,
            acceptedHRSamples: segment.acceptedHRSamples,
            zeroHRSamples: segment.zeroHRSamples,
            heldArtifacts: segment.heldArtifacts,
            droppedArtifacts: segment.droppedArtifacts,
            rawHRGaps: segment.rawHRGaps,
            acceptedHRGaps: segment.acceptedHRGaps,
            maxRawHRGap: segment.maxRawHRGap,
            maxAcceptedHRGap: segment.maxAcceptedHRGap,
            batteryLevel: segment.batteryLevel,
            thermalState: segment.thermalState,
            lowPowerMode: segment.lowPowerMode,
            powerMode: segment.powerMode,
            cadenceMultiplier: segment.cadenceMultiplier,
            strengthSets: segment.strengthSets,
            excludedIntervals: segment.excludedIntervals,
            eventTimeZoneIdentifier: segment.eventTimeZoneIdentifier,
            sensorResearchProbeFrames: segment.sensorResearchProbeFrames,
            spo2ResearchCandidateFrames: segment.spo2ResearchCandidateFrames,
            skinTempResearchCandidateFrames: segment.skinTempResearchCandidateFrames,
            skinTempResearchCandidateValueSum: segment.skinTempResearchCandidateValueSum,
            skinTempResearchCandidateValueCount: segment.skinTempResearchCandidateValueCount,
            spo2ResearchCandidateOffset64ValueSum: segment.spo2ResearchCandidateOffset64ValueSum,
            spo2ResearchCandidateOffset64ValueCount: segment.spo2ResearchCandidateOffset64ValueCount,
            spo2ResearchCandidateOffset66ValueSum: segment.spo2ResearchCandidateOffset66ValueSum,
            spo2ResearchCandidateOffset66ValueCount: segment.spo2ResearchCandidateOffset66ValueCount,
            strapStepResearchCount: segment.strapStepResearchCount,
            strapStepResearchRawCount: segment.strapStepResearchRawCount,
            strapStepResearchDeviceTimestamp: segment.strapStepResearchDeviceTimestamp,
            strapStepResearchState: segment.strapStepResearchState,
            gyroCadenceResearchSteps: segment.gyroCadenceResearchSteps
        )
        guard let samples = replaying(
            current: record.samples,
            segmentStartIndex: segment.sampleStartIndex,
            segmentValues: segment.samples,
            recoveryStartIndex: segment.recoverySampleStartIndex,
            recoveryValues: segment.recoverySamples,
            valuesMatch: { $0.t == $1.t && $0.bpm == $1.bpm }
        ) else {
            AtriaDebugLog("ATRIADBG active_session_journal status=segment_gap sequence=%d sample_start=%d current_samples=%d",
                          segment.sequence, segment.sampleStartIndex, record.samples.count)
            return existing
        }
        let currentRR = record.rrSamples ?? []
        guard let rr = replaying(
            current: currentRR,
            segmentStartIndex: segment.rrSampleStartIndex,
            segmentValues: segment.rrSamples,
            recoveryStartIndex: segment.recoveryRRSampleStartIndex,
            recoveryValues: segment.recoveryRRSamples,
            valuesMatch: { $0.t == $1.t && $0.ms == $1.ms && $0.source == $1.source }
        ) else {
            AtriaDebugLog("ATRIADBG active_session_journal status=segment_gap sequence=%d rr_start=%d current_rr=%d",
                          segment.sequence, segment.rrSampleStartIndex, currentRR.count)
            return existing
        }
        record.label = segment.label
        record.startedAt = min(record.startedAt, segment.startedAt)
        record.updatedAt = latestUpdatedAt(record.updatedAt, segment.updatedAt)
        record.samples = samples
        record.rrSamples = rr
        record.rawHRNotifications = segment.rawHRNotifications
        record.acceptedHRSamples = segment.acceptedHRSamples
        record.zeroHRSamples = segment.zeroHRSamples
        record.heldArtifacts = segment.heldArtifacts
        record.droppedArtifacts = segment.droppedArtifacts
        record.rawHRGaps = segment.rawHRGaps
        record.acceptedHRGaps = segment.acceptedHRGaps
        record.maxRawHRGap = segment.maxRawHRGap
        record.maxAcceptedHRGap = segment.maxAcceptedHRGap
        record.batteryLevel = segment.batteryLevel
        record.thermalState = segment.thermalState
        record.lowPowerMode = segment.lowPowerMode
        record.powerMode = segment.powerMode
        record.cadenceMultiplier = segment.cadenceMultiplier
        record.strengthSets = segment.strengthSets
        record.excludedIntervals = segment.excludedIntervals
        record.eventTimeZoneIdentifier = segment.eventTimeZoneIdentifier ?? record.eventTimeZoneIdentifier
        record.sensorResearchProbeFrames = segment.sensorResearchProbeFrames
        record.spo2ResearchCandidateFrames = segment.spo2ResearchCandidateFrames
        record.skinTempResearchCandidateFrames = segment.skinTempResearchCandidateFrames
        record.skinTempResearchCandidateValueSum = segment.skinTempResearchCandidateValueSum
        record.skinTempResearchCandidateValueCount = segment.skinTempResearchCandidateValueCount
        record.spo2ResearchCandidateOffset64ValueSum = segment.spo2ResearchCandidateOffset64ValueSum
        record.spo2ResearchCandidateOffset64ValueCount = segment.spo2ResearchCandidateOffset64ValueCount
        record.spo2ResearchCandidateOffset66ValueSum = segment.spo2ResearchCandidateOffset66ValueSum
        record.spo2ResearchCandidateOffset66ValueCount = segment.spo2ResearchCandidateOffset66ValueCount
        let previousStepCount = record.strapStepResearchCount
        let incomingStepCount = segment.strapStepResearchCount
        let previousStepState = record.strapStepResearchState
        record.strapStepResearchCount = monotonicOptionalCount(incomingStepCount,
                                                                previousStepCount)
        record.strapStepResearchRawCount = monotonicOptionalCount(segment.strapStepResearchRawCount,
                                                                   record.strapStepResearchRawCount)
        let incomingCheckpointIsWeaker = incomingStepCount.flatMap { incoming in
            incoming >= 0 ? previousStepCount.map { $0 >= 0 && incoming < $0 } : true
        } ?? (previousStepCount != nil)
        if let previousStepCount,
           previousStepCount >= 0,
           incomingCheckpointIsWeaker {
            // Keep the state paired with the stronger persisted step checkpoint.
            // A delayed/lower segment must not downgrade either half of it.
            record.strapStepResearchState = previousStepState
        } else {
            record.strapStepResearchState = segment.strapStepResearchState
        }
        if !incomingCheckpointIsWeaker {
            record.strapStepResearchDeviceTimestamp = newestDeviceTimestamp(
                existing: record.strapStepResearchDeviceTimestamp,
                incoming: segment.strapStepResearchDeviceTimestamp
            )
        }
        // Research-only gyro-cadence shadow: monotonic within a session; a
        // delayed/lower segment must never downgrade the persisted total.
        record.gyroCadenceResearchSteps = monotonicOptionalCount(
            segment.gyroCadenceResearchSteps,
            record.gyroCadenceResearchSteps
        )
        return record
    }

    /// RFC-1982 ordering keeps the replay watermark monotonic across ordinary
    /// incremental saves and the UInt32 seconds-clock wrap.
    private static func newestDeviceTimestamp(existing: UInt32?,
                                              incoming: UInt32?) -> UInt32? {
        guard let incoming, incoming > 0 else { return existing }
        guard let existing, existing > 0 else { return incoming }
        let delta = incoming &- existing
        return delta > 0 && delta < (UInt32.max / 2 + 1) ? incoming : existing
    }

    private static func monotonicOptionalCount(_ incoming: Int?, _ existing: Int?) -> Int? {
        let validIncoming = incoming.flatMap { $0 >= 0 ? $0 : nil }
        let validExisting = existing.flatMap { $0 >= 0 ? $0 : nil }
        switch (validIncoming, validExisting) {
        case let (incoming?, existing?): return max(incoming, existing)
        case let (incoming?, nil): return incoming
        case let (nil, existing?): return existing
        case (nil, nil): return nil
        }
    }

    /// Replays an append-only delta. When the current reconstruction stops
    /// before this delta's start, the bounded recovery copy may bridge exactly
    /// that missing predecessor. Existing overlap is verified byte-for-value;
    /// inconsistent or incomplete chains fail closed instead of inventing data.
    private static func replaying<Value>(
        current: [Value],
        segmentStartIndex: Int,
        segmentValues: [Value],
        recoveryStartIndex: Int?,
        recoveryValues: [Value]?,
        valuesMatch: (Value, Value) -> Bool
    ) -> [Value]? {
        guard segmentStartIndex >= 0, segmentStartIndex <= current.count || recoveryStartIndex != nil else {
            return nil
        }
        var replayed = current
        if replayed.count < segmentStartIndex {
            guard let recoveryStartIndex,
                  let recoveryValues,
                  recoveryStartIndex >= 0,
                  recoveryStartIndex <= replayed.count,
                  recoveryStartIndex + recoveryValues.count == segmentStartIndex else {
                return nil
            }
            let overlapCount = replayed.count - recoveryStartIndex
            guard overlapCount <= recoveryValues.count else { return nil }
            for offset in 0..<overlapCount where
                !valuesMatch(replayed[recoveryStartIndex + offset], recoveryValues[offset]) {
                return nil
            }
            replayed.append(contentsOf: recoveryValues.dropFirst(overlapCount))
        }
        guard replayed.count >= segmentStartIndex else { return nil }
        let segmentOverlapCount = replayed.count - segmentStartIndex
        guard segmentOverlapCount <= segmentValues.count else {
            // This segment is already fully represented by a later/duplicate
            // checkpoint only when all of its values can be verified.
            for offset in segmentValues.indices where
                !valuesMatch(replayed[segmentStartIndex + offset], segmentValues[offset]) {
                return nil
            }
            return replayed
        }
        for offset in 0..<segmentOverlapCount where
            !valuesMatch(replayed[segmentStartIndex + offset], segmentValues[offset]) {
            return nil
        }
        replayed.append(contentsOf: segmentValues.dropFirst(segmentOverlapCount))
        return replayed
    }

    static func latestUpdatedAt(_ current: Date, _ candidate: Date) -> Date {
        max(current, candidate)
    }

    static func latestMirroredStrengthState() -> MirroredStrengthState? {
        ioLock.lock()
        defer { ioLock.unlock() }
        if let pendingMirroredStrengthState {
            return pendingMirroredStrengthState
        }
        if let cache = currentSegmentedCacheLocked(), let record = cache.record {
            return mirroredStrengthState(from: record)
        }
        if let cache = currentMirroredStrengthCacheLocked() {
            return cache.state
        }
        if let sequence = currentLatestSegmentSequenceLocked(),
           let segment = loadSegment(sequence: sequence),
           segment.schema == Self.segmentSchema {
            let state = MirroredStrengthState(strengthSets: segment.strengthSets,
                                              excludedIntervals: segment.excludedIntervals)
            if let fingerprint = segmentFingerprintLocked(latestSequence: sequence) {
                mirroredStrengthCache = MirroredStrengthCache(fingerprint: fingerprint, state: state)
            }
            return state
        }
        guard let record = loadLocked() else { return nil }
        return mirroredStrengthState(from: record)
    }

    private static func mirroredStrengthState(from record: ActiveSessionJournalRecord) -> MirroredStrengthState {
        MirroredStrengthState(strengthSets: record.strengthSets,
                              excludedIntervals: record.excludedIntervals)
    }

    static func mirrorStrengthState(strengthSets: [LoggedSet],
                                    excludedIntervals: [ExcludedInterval]) throws {
        let state = MirroredStrengthState(
            strengthSets: strengthSets.isEmpty ? nil : strengthSets,
            excludedIntervals: excludedIntervals.isEmpty ? nil : excludedIntervals
        )
        ioLock.lock()
        strengthMirrorGeneration &+= 1
        let generation = strengthMirrorGeneration
        pendingMirroredStrengthState = state
        ioLock.unlock()

        strengthMirrorIOQueue.async {
            persistMirroredStrengthState(state, generation: generation)
        }
    }

    private static func persistMirroredStrengthState(_ state: MirroredStrengthState,
                                                     generation: UInt64) {
        let persistenceWasOnMainThread = Thread.isMainThread
        ioLock.lock()
        defer { ioLock.unlock() }
        guard let segmentDirectoryURL, var record = loadLocked() else {
            if generation == strengthMirrorGeneration {
                pendingMirroredStrengthState = nil
            }
            return
        }
        record.updatedAt = Date()
        record.strengthSets = state.strengthSets
        record.excludedIntervals = state.excludedIntervals
        do {
            try saveLocked(record,
                           previousSampleCount: record.samples.count,
                           previousRRCount: record.rrSamples?.count ?? 0,
                           segmentDirectoryURL: segmentDirectoryURL)
            lastStrengthMirrorPersistenceWasOnMainThread = persistenceWasOnMainThread
            persistedStrengthMirrorGeneration = max(persistedStrengthMirrorGeneration, generation)
            if generation == strengthMirrorGeneration {
                pendingMirroredStrengthState = nil
            }
        } catch {
            AtriaDebugLog("ATRIADBG active_session_journal status=strength_mirror_failed generation=%llu error=%@",
                          generation, error.localizedDescription)
        }
    }

    private static func recordAppends(to existing: ActiveSessionJournalRecord,
                                      with record: ActiveSessionJournalRecord) -> Bool {
        guard existing.samples.count <= record.samples.count,
              (existing.rrSamples ?? []).count <= (record.rrSamples ?? []).count else {
            return false
        }
        for index in existing.samples.indices {
            let lhs = existing.samples[index]
            let rhs = record.samples[index]
            guard lhs.t == rhs.t, lhs.bpm == rhs.bpm else { return false }
        }
        let existingRR = existing.rrSamples ?? []
        let recordRR = record.rrSamples ?? []
        for index in existingRR.indices {
            let lhs = existingRR[index]
            let rhs = recordRR[index]
            guard lhs.t == rhs.t, lhs.ms == rhs.ms else { return false }
        }
        return true
    }

    private static func loadSegments() -> [ActiveSessionJournalSegment] {
        guard let segmentDirectoryURL,
              FileManager.default.fileExists(atPath: segmentDirectoryURL.path) else {
            return []
        }
        do {
            return try FileManager.default.contentsOfDirectory(at: segmentDirectoryURL,
                                                              includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }
                .compactMap { url in
                    do {
                        let data = try Data(contentsOf: url)
                        let segment = try JSONDecoder().decode(ActiveSessionJournalSegment.self, from: data)
                        guard segment.schema == Self.segmentSchema else { return nil }
                        return segment
                    } catch {
                        AtriaDebugLog("ATRIADBG active_session_journal status=segment_load_failed file=%@ error=%@",
                              url.lastPathComponent, error.localizedDescription)
                        return nil
                    }
                }
                .sorted { $0.sequence < $1.sequence }
        } catch {
            AtriaDebugLog("ATRIADBG active_session_journal status=segment_list_failed error=%@", error.localizedDescription)
            return []
        }
    }

    private static func currentSegmentedCacheLocked() -> SegmentedLoadCache? {
        guard let cache = segmentedLoadCache,
              let fingerprint = segmentFingerprintLocked(latestSequence: cache.fingerprint.latestSequence),
              fingerprint == cache.fingerprint else {
            segmentedLoadCache = nil
            return nil
        }
        return cache
    }

    private static func currentMirroredStrengthCacheLocked() -> MirroredStrengthCache? {
        guard let cache = mirroredStrengthCache,
              let fingerprint = segmentFingerprintLocked(latestSequence: cache.fingerprint.latestSequence),
              fingerprint == cache.fingerprint else {
            mirroredStrengthCache = nil
            return nil
        }
        return cache
    }

    private static func currentLatestSegmentSequenceLocked() -> Int? {
        if let cache = currentSegmentedCacheLocked() {
            return cache.fingerprint.latestSequence
        }
        if let cache = currentMirroredStrengthCacheLocked() {
            return cache.fingerprint.latestSequence
        }
        return latestSegmentSequence()
    }

    private static func segmentFingerprintLocked(latestSequence: Int?) -> SegmentFingerprint? {
        guard let segmentDirectoryURL,
              let directoryAttributes = try? FileManager.default.attributesOfItem(atPath: segmentDirectoryURL.path),
              let directoryModifiedAt = directoryAttributes[.modificationDate] as? Date else {
            return nil
        }
        guard let latestSequence else {
            return SegmentFingerprint(directoryModifiedAt: directoryModifiedAt,
                                      latestSequence: nil,
                                      latestModifiedAt: nil,
                                      latestSize: nil)
        }
        let latestURL = segmentURL(sequence: latestSequence)
        guard let latestAttributes = try? FileManager.default.attributesOfItem(atPath: latestURL.path),
              let latestModifiedAt = latestAttributes[.modificationDate] as? Date,
              let latestSize = latestAttributes[.size] as? NSNumber else {
            return nil
        }
        return SegmentFingerprint(directoryModifiedAt: directoryModifiedAt,
                                  latestSequence: latestSequence,
                                  latestModifiedAt: latestModifiedAt,
                                  latestSize: latestSize.uint64Value)
    }

    private static func latestSegmentSequence() -> Int? {
        guard let segmentDirectoryURL,
              FileManager.default.fileExists(atPath: segmentDirectoryURL.path),
              let files = try? FileManager.default.contentsOfDirectory(at: segmentDirectoryURL,
                                                                        includingPropertiesForKeys: nil) else {
            return nil
        }
        return files.compactMap { url -> Int? in
            let name = url.deletingPathExtension().lastPathComponent
            guard name.hasPrefix("segment-") else { return nil }
            return Int(name.dropFirst("segment-".count))
        }.max()
    }

    private static func loadSegment(sequence: Int) -> ActiveSessionJournalSegment? {
        let target = segmentURL(sequence: sequence)
        guard FileManager.default.fileExists(atPath: target.path) else { return nil }
        do {
            let data = try Data(contentsOf: target)
            return try JSONDecoder().decode(ActiveSessionJournalSegment.self, from: data)
        } catch {
            AtriaDebugLog("ATRIADBG active_session_journal status=segment_load_failed file=%@ error=%@",
                          target.lastPathComponent, error.localizedDescription)
            return nil
        }
    }

    private static func segmentURL(sequence: Int) -> URL {
        segmentDirectoryURL!.appendingPathComponent(String(format: "segment-%08d.json", sequence))
    }

    /// Completes the checkpoint's storage durability boundary before callers
    /// advance their in-memory cursors or report success. Atomic replacement
    /// protects readers from torn JSON; synchronizing the resulting file keeps
    /// a process termination immediately after `saveIncremental` from losing a
    /// checkpoint that the app already described as saved.
    private static func writeDurable(_ data: Data, to target: URL) throws {
        try data.write(to: target, options: [.atomic])
        let handle = try FileHandle(forWritingTo: target)
        defer { try? handle.close() }
        try handle.synchronize()
        try synchronizeDirectory(target.deletingLastPathComponent())
    }

    private static func synchronizeDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func clearSegmentFiles(preservingSequence: Int? = nil) {
        segmentedLoadCache = nil
        mirroredStrengthCache = nil
        guard let segmentDirectoryURL,
              FileManager.default.fileExists(atPath: segmentDirectoryURL.path) else {
            return
        }
        do {
            let files = try FileManager.default.contentsOfDirectory(at: segmentDirectoryURL,
                                                                    includingPropertiesForKeys: nil)
            let preservedName = preservingSequence.map {
                segmentURL(sequence: $0).lastPathComponent
            }
            for file in files where file.pathExtension == "json" {
                if file.lastPathComponent == preservedName {
                    continue
                }
                try FileManager.default.removeItem(at: file)
            }
        } catch {
            AtriaDebugLog("ATRIADBG active_session_journal status=clear_segments_failed error=%@", error.localizedDescription)
        }
    }

    private static func segmentChainStorageLocked() -> (count: Int, bytes: UInt64, exceedsBudget: Bool) {
        guard let segmentDirectoryURL,
              let files = try? FileManager.default.contentsOfDirectory(
                at: segmentDirectoryURL,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
              ) else {
            return (0, 0, false)
        }
        var count = 0
        var bytes: UInt64 = 0
        for file in files where file.pathExtension == "json" && file.lastPathComponent.hasPrefix("segment-") {
            count += 1
            if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               size > 0 {
                bytes += UInt64(size)
            }
        }
        return (count,
                bytes,
                count > maximumSegmentChainCount || bytes > maximumSegmentChainBytes)
    }

    static func resetCachesForTesting() {
        drainStrengthMirrorWrites()
        ioLock.lock()
        defer { ioLock.unlock() }
        loadCache = nil
        segmentedLoadCache = nil
        sleepReviewCacheKnownAbsent = false
        mirroredStrengthCache = nil
        pendingMirroredStrengthState = nil
        strengthMirrorGeneration = 0
        persistedStrengthMirrorGeneration = 0
        lastStrengthMirrorPersistenceWasOnMainThread = false
        segmentedReconstructionCount = 0
        compactionReplacementDurableCheckpointForTesting = nil
    }

    static func drainStrengthMirrorWrites() {
        strengthMirrorIOQueue.sync {}
    }

    static var strengthMirrorGenerationsForTesting: (requested: UInt64, persisted: UInt64) {
        ioLock.lock()
        defer { ioLock.unlock() }
        return (strengthMirrorGeneration, persistedStrengthMirrorGeneration)
    }

    static var lastStrengthMirrorPersistenceWasOnMainThreadForTesting: Bool {
        ioLock.lock()
        defer { ioLock.unlock() }
        return lastStrengthMirrorPersistenceWasOnMainThread
    }

    static func setCompactionReplacementDurableCheckpointForTesting(
        _ checkpoint: (() throws -> Void)?
    ) {
        ioLock.lock()
        defer { ioLock.unlock() }
        compactionReplacementDurableCheckpointForTesting = checkpoint
    }

    static var segmentedReconstructionCountForTesting: Int {
        ioLock.lock()
        defer { ioLock.unlock() }
        return segmentedReconstructionCount
    }

    static var segmentChainStorageForTesting: (count: Int, bytes: UInt64) {
        ioLock.lock()
        defer { ioLock.unlock() }
        let storage = segmentChainStorageLocked()
        return (storage.count, storage.bytes)
    }

    private static func clearLegacySnapshotFileIfPresent() {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            AtriaDebugLog("ATRIADBG active_session_journal status=clear_legacy_snapshot_failed error=%@", error.localizedDescription)
        }
    }

    static func recordClose(status: String, reason: String, label: String, samples: Int, duration: TimeInterval) {
        let defaults = UserDefaults.standard
        defaults.set(status, forKey: LastCloseDefaults.status)
        defaults.set(reason, forKey: LastCloseDefaults.reason)
        defaults.set(label, forKey: LastCloseDefaults.label)
        defaults.set(samples, forKey: LastCloseDefaults.samples)
        defaults.set(Int(duration.rounded()), forKey: LastCloseDefaults.duration)
        defaults.set(Date().timeIntervalSince1970, forKey: LastCloseDefaults.at)
    }

    static func diagnostics() -> Diagnostics {
        guard let record = load() else {
            return Diagnostics(present: false,
                               fresh: false,
                               samples: 0,
                               rrValues: 0,
                               duration: 0,
                               maxRRGap: 0,
                               rrGapOver3: 0,
                               rrCoverage3Percent: 0,
                               recentRRValues: 0,
                               recentRRDuration: 0,
                               recentRRMaxGap: 0,
                               recentRRCoverage3Percent: 0)
        }
        let age = max(0, Date().timeIntervalSince(record.updatedAt))
        let fresh = age <= Double(freshAgeLimitSeconds)
        let duration = max(0, (record.samples.last?.t ?? record.startedAt).timeIntervalSince(record.startedAt))
        let rr = (record.rrSamples ?? []).sorted { $0.t < $1.t }
        let full = rrContinuityStats(rr)
        let recentCutoff = Date().addingTimeInterval(-30)
        let recent = rr.filter { $0.t >= recentCutoff }
        let recentStats = rrContinuityStats(recent)
        return Diagnostics(present: true,
                           fresh: fresh,
                           samples: record.samples.count,
                           rrValues: rr.count,
                           duration: duration,
                           maxRRGap: full.maxGap,
                           rrGapOver3: full.gapOver3,
                           rrCoverage3Percent: full.coverage3Percent,
                           recentRRValues: recent.count,
                           recentRRDuration: recentStats.span,
                           recentRRMaxGap: recentStats.maxGap,
                           recentRRCoverage3Percent: recentStats.coverage3Percent)
    }

    static func evidence(includeAge: Bool = true) -> String {
        let closeEvidence = lastCloseEvidence()
        guard let record = load() else {
            let age = includeAge ? "active_journal_age_s=0; " : ""
            return "active_journal_present=0; active_journal_samples=0; active_journal_rr_values=0; \(age)active_journal_freshness=missing; active_collection_status=no_journal; active_collection_blocker=active_journal_missing; active_journal_duration_s=0; active_journal_rr_max_gap_s=0.0; active_journal_rr_gap_over_3s=0; active_journal_rr_gap_over_5s=0; active_journal_rr_coverage_3s_percent=0; \(closeEvidence)"
        }
        let now = Date()
        let age = max(0, Int(now.timeIntervalSince(record.updatedAt).rounded()))
        let freshness = age <= freshAgeLimitSeconds ? "fresh" : "stale"
        let collectionStatus = freshness == "fresh" ? "active" : "stale"
        let collectionBlocker = freshness == "fresh" ? "none" : "active_journal_stale"
        let duration = max(0, Int((record.samples.last?.t ?? record.startedAt).timeIntervalSince(record.startedAt).rounded()))
        let rr = (record.rrSamples ?? []).sorted { $0.t < $1.t }
        var rrGapOver5 = 0
        let full = rrContinuityStats(rr)
        for pair in zip(rr, rr.dropFirst()) {
            let gap = max(0, pair.1.t.timeIntervalSince(pair.0.t))
            if gap > SavedSession.workoutContinuityGapLimit {
                rrGapOver5 += 1
            }
        }
        let recentCutoff = now.addingTimeInterval(-30)
        let recent = rr.filter { $0.t >= recentCutoff }
        let recentStats = rrContinuityStats(recent)
        let ageField = includeAge ? "active_journal_age_s=\(age); " : ""
        return "active_journal_present=1; active_journal_samples=\(record.samples.count); active_journal_rr_values=\(rr.count); \(ageField)active_journal_freshness=\(freshness); active_collection_status=\(collectionStatus); active_collection_blocker=\(collectionBlocker); active_journal_duration_s=\(duration); active_journal_rr_max_gap_s=\(String(format: "%.1f", full.maxGap)); active_journal_rr_gap_over_3s=\(full.gapOver3); active_journal_rr_gap_over_5s=\(rrGapOver5); active_journal_rr_coverage_3s_percent=\(full.coverage3Percent); active_journal_recent_rr_values=\(recent.count); active_journal_recent_rr_duration_s=\(Int(recentStats.span.rounded())); active_journal_recent_rr_max_gap_s=\(String(format: "%.1f", recentStats.maxGap)); active_journal_recent_rr_coverage_3s_percent=\(recentStats.coverage3Percent); \(closeEvidence)"
    }

    private static func rrContinuityStats(_ rr: [ActiveSessionJournalRecord.RRSample]) -> (span: TimeInterval, maxGap: TimeInterval, gapOver3: Int, coverage3Percent: Int) {
        guard rr.count > 1 else { return (0, 0, 0, 0) }
        var maxGap: TimeInterval = 0
        var gapOver3 = 0
        var observed3: TimeInterval = 0
        for pair in zip(rr, rr.dropFirst()) {
            let gap = max(0, pair.1.t.timeIntervalSince(pair.0.t))
            maxGap = max(maxGap, gap)
            if gap > 3 {
                gapOver3 += 1
            } else {
                observed3 += gap
            }
        }
        let span = max(0, (rr.last?.t ?? rr[0].t).timeIntervalSince(rr[0].t))
        let coverage3 = span > 0 ? min(100, max(0, Int(((observed3 / span) * 100).rounded()))) : 0
        return (span, maxGap, gapOver3, coverage3)
    }

    private static func lastCloseEvidence() -> String {
        let defaults = UserDefaults.standard
        let status = token(defaults.string(forKey: LastCloseDefaults.status) ?? "none")
        let reason = token(defaults.string(forKey: LastCloseDefaults.reason) ?? "none")
        let label = token(defaults.string(forKey: LastCloseDefaults.label) ?? "none")
        let at = defaults.object(forKey: LastCloseDefaults.at) as? Double
        let age = at.map { max(0, Int((Date().timeIntervalSince1970 - $0).rounded())) } ?? -1
        return "active_journal_last_close_status=\(status); active_journal_last_close_reason=\(reason); active_journal_last_close_label=\(label); active_journal_last_close_samples=\(defaults.integer(forKey: LastCloseDefaults.samples)); active_journal_last_close_duration_s=\(defaults.integer(forKey: LastCloseDefaults.duration)); active_journal_last_close_age_s=\(age)"
    }

    private static func token(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-."))
        return value.unicodeScalars.map { allowed.contains($0) ? String($0) : "_" }.joined()
    }
}
