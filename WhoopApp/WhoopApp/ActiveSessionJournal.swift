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
    var rrSampleStartIndex: Int
    var rrSamples: [ActiveSessionJournalRecord.RRSample]
    var rawHRNotifications: Int
    var acceptedHRSamples: Int
    var zeroHRSamples: Int
    var heldArtifacts: Int
    var droppedArtifacts: Int
    var rawHRGaps: Int
    var acceptedHRGaps: Int
    var maxRawHRGap: Double
    var maxAcceptedHRGap: Double
}

enum ActiveSessionJournal {
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
    private struct LoadCache {
        let targetPath: String
        let modifiedAt: Date
        let record: ActiveSessionJournalRecord?
    }
    private static var loadCache: LoadCache?
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
        if let record = loadSegmentedRecord() {
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
            WHOOPDebugLog("WHOOPDBG active_session_journal status=load_failed error=%@", error.localizedDescription)
            return nil
        }
    }

    static func save(_ record: ActiveSessionJournalRecord) throws {
        guard let segmentDirectoryURL else { return }
        ioLock.lock()
        defer { ioLock.unlock() }
        try FileManager.default.createDirectory(at: segmentDirectoryURL, withIntermediateDirectories: true)
        var existing = loadSegmentedRecord()
        var sameSession = existing?.id == record.id
        if sameSession, let replayed = existing, !recordAppends(to: replayed, with: record) {
            clearSegmentFiles()
            existing = nil
            sameSession = false
        } else if !sameSession {
            clearSegmentFiles()
        }
        let existingSampleCount = sameSession ? min(existing?.samples.count ?? 0, record.samples.count) : 0
        let existingRRCount = sameSession ? min(existing?.rrSamples?.count ?? 0, record.rrSamples?.count ?? 0) : 0
        let nextSequence = (latestSegmentSequence() ?? -1) + 1
        let segment = ActiveSessionJournalSegment(
            schema: Self.segmentSchema,
            sequence: nextSequence,
            id: record.id,
            label: record.label,
            startedAt: record.startedAt,
            updatedAt: record.updatedAt,
            sampleStartIndex: existingSampleCount,
            samples: Array(record.samples.dropFirst(existingSampleCount)),
            rrSampleStartIndex: existingRRCount,
            rrSamples: Array((record.rrSamples ?? []).dropFirst(existingRRCount)),
            rawHRNotifications: record.rawHRNotifications,
            acceptedHRSamples: record.acceptedHRSamples,
            zeroHRSamples: record.zeroHRSamples,
            heldArtifacts: record.heldArtifacts,
            droppedArtifacts: record.droppedArtifacts,
            rawHRGaps: record.rawHRGaps,
            acceptedHRGaps: record.acceptedHRGaps,
            maxRawHRGap: record.maxRawHRGap,
            maxAcceptedHRGap: record.maxAcceptedHRGap
        )
        let data = try JSONEncoder().encode(segment)
        try data.write(to: segmentURL(sequence: nextSequence), options: [.atomic])
        clearLegacySnapshotFileIfPresent()
        loadCache = nil
    }

    static func clear() {
        ioLock.lock()
        defer { ioLock.unlock() }
        loadCache = nil
        clearSegmentFiles()
        for target in [url, legacyURL].compactMap({ $0 }) where FileManager.default.fileExists(atPath: target.path) {
            do {
                try FileManager.default.removeItem(at: target)
            } catch {
                WHOOPDebugLog("WHOOPDBG active_session_journal status=clear_failed error=%@", error.localizedDescription)
            }
        }
    }

    private static func loadSegmentedRecord() -> ActiveSessionJournalRecord? {
        let segments = loadSegments()
        guard let first = segments.first else { return nil }
        var record = ActiveSessionJournalRecord(
            schema: Self.schema,
            id: first.id,
            label: first.label,
            startedAt: first.startedAt,
            updatedAt: first.updatedAt,
            samples: [],
            rrSamples: [],
            rawHRNotifications: first.rawHRNotifications,
            acceptedHRSamples: first.acceptedHRSamples,
            zeroHRSamples: first.zeroHRSamples,
            heldArtifacts: first.heldArtifacts,
            droppedArtifacts: first.droppedArtifacts,
            rawHRGaps: first.rawHRGaps,
            acceptedHRGaps: first.acceptedHRGaps,
            maxRawHRGap: first.maxRawHRGap,
            maxAcceptedHRGap: first.maxAcceptedHRGap
        )
        for segment in segments where segment.id == record.id {
            record.label = segment.label
            record.startedAt = min(record.startedAt, segment.startedAt)
            record.updatedAt = max(record.updatedAt, segment.updatedAt)
            if record.samples.count == segment.sampleStartIndex {
                record.samples.append(contentsOf: segment.samples)
            } else if record.samples.count < segment.sampleStartIndex {
                WHOOPDebugLog("WHOOPDBG active_session_journal status=segment_gap sequence=%d sample_start=%d current_samples=%d",
                      segment.sequence, segment.sampleStartIndex, record.samples.count)
            }
            var rr = record.rrSamples ?? []
            if rr.count == segment.rrSampleStartIndex {
                rr.append(contentsOf: segment.rrSamples)
            } else if rr.count < segment.rrSampleStartIndex {
                WHOOPDebugLog("WHOOPDBG active_session_journal status=segment_gap sequence=%d rr_start=%d current_rr=%d",
                      segment.sequence, segment.rrSampleStartIndex, rr.count)
            }
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
        }
        return record
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
                        WHOOPDebugLog("WHOOPDBG active_session_journal status=segment_load_failed file=%@ error=%@",
                              url.lastPathComponent, error.localizedDescription)
                        return nil
                    }
                }
                .sorted { $0.sequence < $1.sequence }
        } catch {
            WHOOPDebugLog("WHOOPDBG active_session_journal status=segment_list_failed error=%@", error.localizedDescription)
            return []
        }
    }

    private static func latestSegmentSequence() -> Int? {
        loadSegments().map(\.sequence).max()
    }

    private static func segmentURL(sequence: Int) -> URL {
        segmentDirectoryURL!.appendingPathComponent(String(format: "segment-%08d.json", sequence))
    }

    private static func clearSegmentFiles() {
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
            WHOOPDebugLog("WHOOPDBG active_session_journal status=clear_segments_failed error=%@", error.localizedDescription)
        }
    }

    private static func clearLegacySnapshotFileIfPresent() {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            WHOOPDebugLog("WHOOPDBG active_session_journal status=clear_legacy_snapshot_failed error=%@", error.localizedDescription)
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
