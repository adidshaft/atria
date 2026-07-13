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
    /// Cumulative, calibration-gated R10 detector state for this live segment.
    /// Optional so journals written before step capture remain decodable.
    var strapStepResearchCount: Int? = nil
    var strapStepResearchRawCount: Int? = nil
    var strapStepResearchState: String? = nil

    struct Sample: Codable {
        let t: Date
        let bpm: Int
    }

    struct RRSample: Codable {
        let t: Date
        let ms: Int
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
    var strapStepResearchCount: Int? = nil
    var strapStepResearchRawCount: Int? = nil
    var strapStepResearchState: String? = nil
}

enum ActiveSessionJournal {
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
    private static var mirroredStrengthCache: MirroredStrengthCache?
    private static var pendingMirroredStrengthState: MirroredStrengthState?
    private static var strengthMirrorGeneration: UInt64 = 0
    private static var persistedStrengthMirrorGeneration: UInt64 = 0
    private static var lastStrengthMirrorPersistenceWasOnMainThread = false
    private static var segmentedReconstructionCount = 0
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
        defer { ioLock.unlock() }
        return loadLocked()
    }

    private static func loadLocked() -> ActiveSessionJournalRecord? {
        if let record = loadSegmentedRecordLocked() {
            return record
        }
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
            return nil
        }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: target.path),
              let modifiedAt = attributes[.modificationDate] as? Date else {
            loadCache = nil
            return decodeRecord(at: target)
        }
        if let cached = loadCache,
           cached.targetPath == target.path,
           cached.modifiedAt == modifiedAt {
            return cached.record
        }
        let record = decodeRecord(at: target)
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
            clearSegmentFiles()
            segmentedLoadCache = nil
            mirroredStrengthCache = nil
            latestSequence = nil
            latest = nil
            existing = nil
        }
        let expectedSamples = existing?.samples.count ?? 0
        let expectedRR = existing?.rrSamples?.count ?? 0
        guard sampleStartIndex == expectedSamples else {
            throw IncrementalSaveError.discontinuousSampleCursor(expected: expectedSamples,
                                                                  actual: sampleStartIndex)
        }
        guard rrSampleStartIndex == expectedRR else {
            throw IncrementalSaveError.discontinuousRRCursor(expected: expectedRR,
                                                              actual: rrSampleStartIndex)
        }

        let nextSequence = (latestSequence ?? -1) + 1
        let segment = ActiveSessionJournalSegment(
            schema: Self.segmentSchema, sequence: nextSequence,
            id: record.id, label: record.label, startedAt: record.startedAt, updatedAt: record.updatedAt,
            sampleStartIndex: sampleStartIndex, samples: record.samples,
            recoverySampleStartIndex: latest?.sampleStartIndex, recoverySamples: latest?.samples,
            rrSampleStartIndex: rrSampleStartIndex, rrSamples: record.rrSamples ?? [],
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
            strapStepResearchCount: record.strapStepResearchCount,
            strapStepResearchRawCount: record.strapStepResearchRawCount,
            strapStepResearchState: record.strapStepResearchState
        )
        try JSONEncoder().encode(segment).write(to: segmentURL(sequence: nextSequence), options: [.atomic])
        clearLegacySnapshotFileIfPresent()
        loadCache = nil
        var updated = applying(segment, to: existing)
        if let complete = updated {
            let bounded = boundedRecord(complete, now: record.updatedAt, maxAge: maxAge, maxSamples: maxSamples)
            if bounded.samples.count != complete.samples.count
                || (bounded.rrSamples?.count ?? 0) != (complete.rrSamples?.count ?? 0) {
                clearSegmentFiles()
                segmentedLoadCache = nil
                mirroredStrengthCache = nil
                try saveLocked(bounded,
                               previousSampleCount: 0,
                               previousRRCount: 0,
                               segmentDirectoryURL: segmentDirectoryURL)
                updated = bounded
                return IncrementalSaveResult(sampleCount: bounded.samples.count,
                                             rrSampleCount: bounded.rrSamples?.count ?? 0,
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
            strapStepResearchCount: record.strapStepResearchCount,
            strapStepResearchRawCount: record.strapStepResearchRawCount,
            strapStepResearchState: record.strapStepResearchState
        )
        let data = try JSONEncoder().encode(segment)
        try data.write(to: segmentURL(sequence: nextSequence), options: [.atomic])
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
        var record = existing ?? ActiveSessionJournalRecord(
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
            strapStepResearchCount: segment.strapStepResearchCount,
            strapStepResearchRawCount: segment.strapStepResearchRawCount,
            strapStepResearchState: segment.strapStepResearchState
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
            valuesMatch: { $0.t == $1.t && $0.ms == $1.ms }
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
        return record
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

    private static func clearSegmentFiles() {
        segmentedLoadCache = nil
        mirroredStrengthCache = nil
        guard let segmentDirectoryURL,
              FileManager.default.fileExists(atPath: segmentDirectoryURL.path) else {
            return
        }
        do {
            let files = try FileManager.default.contentsOfDirectory(at: segmentDirectoryURL,
                                                                    includingPropertiesForKeys: nil)
            for file in files where file.pathExtension == "json" {
                try FileManager.default.removeItem(at: file)
            }
        } catch {
            AtriaDebugLog("ATRIADBG active_session_journal status=clear_segments_failed error=%@", error.localizedDescription)
        }
    }

    static func resetCachesForTesting() {
        drainStrengthMirrorWrites()
        ioLock.lock()
        defer { ioLock.unlock() }
        loadCache = nil
        segmentedLoadCache = nil
        mirroredStrengthCache = nil
        pendingMirroredStrengthState = nil
        strengthMirrorGeneration = 0
        persistedStrengthMirrorGeneration = 0
        lastStrengthMirrorPersistenceWasOnMainThread = false
        segmentedReconstructionCount = 0
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

    static var segmentedReconstructionCountForTesting: Int {
        ioLock.lock()
        defer { ioLock.unlock() }
        return segmentedReconstructionCount
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
