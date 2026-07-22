import CryptoKit
import Darwin
import Foundation

/// Durable, bounded bookkeeping for intervals where the live strap stream was
/// unavailable. The ledger deliberately stores coverage evidence only from
/// metric-usable historical rows; a successful BLE reconnect by itself never
/// claims that missing heart-rate data was recovered.
enum AtriaHistoricalGapLedger {
    private struct Envelope: Codable, Equatable {
        enum State: String, Codable {
            case valid
            case quarantinedCorruption
        }

        static let currentVersion = 2

        let version: Int
        var generation: UInt64
        var state: State
        var windows: [Window]
        var corruptionSHA256: String?
    }

    private struct AnchorEnvelope: Codable, Equatable {
        static let currentVersion = 1

        let version: Int
        let acceptedUnix: TimeInterval
    }

    struct Window: Codable, Equatable, Identifiable {
        let id: UUID
        var start: Date
        var end: Date?
        var reason: String
        /// For a compacted window, one bit per wall-clock second that was
        /// genuinely missing. `nil` means every second in an ordinary window
        /// is expected. A coalesced window with `nil` is legacy ambiguous
        /// state and must remain unresolved until exact intervals are migrated.
        var expectedSecondBits: Data?
        /// One bit per wall-clock second with a durable, metric-usable archive
        /// row. This is compact enough for the full WHOOP retention horizon
        /// while retaining the cadence information a 15-second occupancy list
        /// destroyed. `nil` also intentionally fails closed when decoding the
        /// legacy bucket-only schema.
        var coveredSecondBits: Data?

        init(id: UUID = UUID(),
             start: Date,
             end: Date? = nil,
             reason: String,
             expectedSecondBits: Data? = nil,
             coveredSecondBits: Data? = nil) {
            self.id = id
            self.start = start
            self.end = end
            self.reason = reason
            self.expectedSecondBits = expectedSecondBits
            self.coveredSecondBits = coveredSecondBits
        }

        private enum CodingKeys: String, CodingKey {
            case id
            case start
            case end
            case reason
            case expectedSecondBitsBase64
            case expectedSecondBits
            case coveredSecondBitsBase64
            // Decode-only compatibility with the short-lived local schema
            // where Foundation encoded Data as an integer array.
            case coveredSecondBits
            // Decode-only compatibility with the production bucket schema.
            // Bucket occupancy is intentionally not promoted to per-second
            // continuity evidence.
            case coveredBucketIndexes
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            start = try container.decode(Date.self, forKey: .start)
            end = try container.decodeIfPresent(Date.self, forKey: .end)
            reason = try container.decode(String.self, forKey: .reason)

            if let encoded = try container.decodeIfPresent(
                String.self,
                forKey: .expectedSecondBitsBase64
            ) {
                expectedSecondBits = Data(base64Encoded: encoded)
            } else {
                expectedSecondBits = try? container.decodeIfPresent(
                    Data.self,
                    forKey: .expectedSecondBits
                )
            }

            if let encoded = try container.decodeIfPresent(
                String.self,
                forKey: .coveredSecondBitsBase64
            ) {
                // Corrupt evidence must leave the gap unresolved rather than
                // making the whole ledger unreadable or authorizing recovery.
                coveredSecondBits = Data(base64Encoded: encoded)
            } else {
                coveredSecondBits = try? container.decodeIfPresent(
                    Data.self,
                    forKey: .coveredSecondBits
                )
            }
            _ = try? container.decodeIfPresent(
                [Int].self,
                forKey: .coveredBucketIndexes
            )
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(start, forKey: .start)
            try container.encodeIfPresent(end, forKey: .end)
            try container.encode(reason, forKey: .reason)
            try container.encodeIfPresent(
                expectedSecondBits?.base64EncodedString(),
                forKey: .expectedSecondBitsBase64
            )
            try container.encodeIfPresent(
                coveredSecondBits?.base64EncodedString(),
                forKey: .coveredSecondBitsBase64
            )
        }
    }

    struct Continuity: Equatable {
        let observedSeconds: Int
        let expectedSeconds: Int
        let densityPercent: Int
        let maximumGapSeconds: Int
        let p95GapSeconds: Int
        let continuous: Bool
    }

    struct MetricRowResult: Equatable {
        let matchedWindows: Int
        let resolvedWindows: Int
        let remainingWindows: Int
    }

    struct CloseResult: Equatable {
        let closedWindow: Bool
        let resolvedWindows: Int
        let remainingWindows: Int
    }

    /// Immutable selection evidence used to bind one closed local gap to one
    /// full-flash transport attempt. The digest describes the exact ledger
    /// snapshot from which the gap was selected; it is not strap range proof.
    struct RecoveryCandidate: Equatable {
        let window: Window
        let ledgerGeneration: UInt64
        let ledgerSnapshotSHA256: String
    }

    static let defaultsKey = "atria.offlineSync.missingWindows.v1"
    static let generationKey = "atria.offlineSync.missingWindows.generation.v1"
    private static let migrationCompleteKey =
        "atria.offlineSync.missingWindows.atomicMigration.v2"
    private static let testStorageNamespaceKey =
        "atria.offlineSync.missingWindows.testStorageNamespace.v2"
    private static let stateFileName = "historical-gap-ledger-v2.json"
    private static let backupFileName = "historical-gap-ledger-v2.backup.json"
    private static let anchorFileName = "historical-live-anchor-v1.json"
    private static let storeLock = NSRecursiveLock()
    /// A lightweight predecessor for the first accepted pulse after process
    /// restoration. The full active-session journal intentionally loads off the
    /// main actor; without this anchor a fresh CoreBluetooth notification can
    /// arrive first and make an otherwise recoverable suspension invisible.
    /// This stores a timestamp only. It is never treated as a heart-rate sample
    /// or coverage evidence.
    static let liveContinuityAnchorKey = "atria.offlineSync.lastAcceptedLiveMetricAt.v1"
    static let maximumWindows = 16
    static let coverageBucketSeconds: TimeInterval = 15
    /// Production recovery uses the same meaningful cadence contract as the
    /// physical HIST-1 verifier. A few isolated seconds may be absent, but a
    /// sparse stream can never resolve a missing interval merely by touching a
    /// coarse bucket.
    /// A retained outage is not considered recovered unless at least nine of
    /// every ten missing wall-clock seconds have metric-usable evidence. The
    /// independent max-gap and p95 cadence limits still apply.
    static let minimumResolvedDensityPercent = 90
    static let maximumResolvedGapSeconds = 3
    static let maximumResolvedP95GapSeconds = 1
    /// The predecessor is a tiny independently-fsynced file, so retaining the
    /// actual one-Hz accepted edge does not rewrite the potentially multi-day
    /// gap bitmap. A duplicate boundary second is harmless: historical archive
    /// identity dedupe collapses it before publication.
    static let liveContinuityAnchorWriteInterval: TimeInterval = 1
    // WHOOP 4 retains a multi-day rolling history. Keep process-restoration
    // gaps pending for the conservative inner portion of that retention window
    // instead of silently discarding any phone-away interval over 18 hours.
    static let maximumRecoverableAnchorAge: TimeInterval = 13 * 24 * 60 * 60
    static let coalescedWindowReason = "coalesced_unresolved_history"

    /// Legacy builds stored only the outer envelope when compacting disjoint
    /// outages. Such a window cannot identify the missing union and is never
    /// eligible for recovery or settlement.
    static func isLegacyCoalescedWindow(_ window: Window) -> Bool {
        window.reason == coalescedWindowReason && window.expectedSecondBits == nil
    }

    static func windows(defaults: UserDefaults = .standard) -> [Window] {
        storeLock.lock(); defer { storeLock.unlock() }
        let envelope = loadEnvelope(defaults: defaults)
        guard envelope.state == .valid else {
            // Never translate corrupt durable state into "no gaps". The open
            // sentinel is intentionally non-selectable and keeps every recovery
            // status fail-closed until a valid backup can be restored.
            let digest = envelope.corruptionSHA256 ?? String(repeating: "0", count: 64)
            return [Window(
                id: corruptionSentinelID,
                start: Date(timeIntervalSince1970: 1),
                reason: "durable_gap_ledger_corrupt_\(digest)"
            )]
        }
        return bounded(envelope.windows)
    }

    /// Read-only projection for diagnostics and support bundles.
    ///
    /// Unlike `windows(defaults:)`, this path never creates a test namespace,
    /// repairs a primary from backup, migrates legacy defaults, or publishes a
    /// quarantine envelope. Evidence collection must not change the recovery
    /// transaction it is describing.
    static func windowsForEvidence(defaults: UserDefaults = .standard) -> [Window] {
        storeLock.lock(); defer { storeLock.unlock() }

        if let directory = existingStorageDirectoryForReadOnlyAccess(defaults: defaults) {
            let primary = directory.appendingPathComponent(stateFileName)
            let backup = directory.appendingPathComponent(backupFileName)
            let primaryExists = FileManager.default.fileExists(atPath: primary.path)
            let backupExists = FileManager.default.fileExists(atPath: backup.path)

            if primaryExists, let valid = try? readValidEnvelope(at: primary) {
                return bounded(valid.windows)
            }
            if backupExists, let valid = try? readValidEnvelope(at: backup) {
                return bounded(valid.windows)
            }
            if primaryExists || backupExists {
                let corruptURL = primaryExists ? primary : backup
                let bytes = (try? Data(contentsOf: corruptURL)) ?? Data("missing".utf8)
                return [corruptionSentinel(digest: sha256(bytes))]
            }
        }

        guard let legacy = defaults.data(forKey: defaultsKey) else { return [] }
        guard let decoded = try? JSONDecoder().decode([Window].self, from: legacy) else {
            return [corruptionSentinel(digest: sha256(legacy))]
        }
        return bounded(decoded)
    }

    /// True only when the canonical atomic envelope (or a verified backup)
    /// decoded as valid. Callers must not interpret the corruption sentinel as
    /// a real gap or use its absence as crash-resume proof.
    static func durableStateIsValid(defaults: UserDefaults = .standard) -> Bool {
        storeLock.lock(); defer { storeLock.unlock() }
        return loadEnvelope(defaults: defaults).state == .valid
    }

    /// Mutation paths never consume the public corruption sentinel. Keeping
    /// this check inside the transaction lock prevents a quarantined store from
    /// being closed, staged, compacted, or accidentally persisted as valid.
    private static func validWindowsForMutation(
        defaults: UserDefaults
    ) -> [Window]? {
        let envelope = loadEnvelope(defaults: defaults)
        guard envelope.state == .valid else { return nil }
        return bounded(envelope.windows)
    }

    @discardableResult
    static func beginGap(at start: Date,
                         reason: String,
                         defaults: UserDefaults = .standard) -> Bool {
        storeLock.lock(); defer { storeLock.unlock() }
        guard var current = validWindowsForMutation(defaults: defaults) else {
            return false
        }
        if let openIndex = current.lastIndex(where: { $0.end == nil }) {
            if start < current[openIndex].start {
                current[openIndex].start = start
                // Coverage bits are relative to `start`; rebasing them would
                // turn old evidence into the wrong timestamps. Fail closed.
                current[openIndex].coveredSecondBits = nil
                current[openIndex].expectedSecondBits = nil
                guard persist(current, defaults: defaults) else { return false }
            }
            return false
        }
        current.append(Window(start: start, reason: reason))
        return persist(current, defaults: defaults)
    }

    /// Closes the newest open interval on the first accepted post-reconnect HR.
    /// Short transitions below the product's 15-second continuity boundary are
    /// discarded because they do not represent missing workout coverage.
    @discardableResult
    static func closeOpenGap(at end: Date,
                             minimumDuration: TimeInterval = coverageBucketSeconds,
                             defaults: UserDefaults = .standard) -> Bool {
        closeOpenGapWithResult(at: end,
                               minimumDuration: minimumDuration,
                               defaults: defaults).closedWindow
    }

    /// Closes the newest open interval and evaluates metric-usable buckets
    /// buffered while the link was down. An open interval can never resolve
    /// early, and buckets beyond the eventual reconnect boundary are discarded.
    @discardableResult
    static func closeOpenGapWithResult(
        at end: Date,
        minimumDuration: TimeInterval = coverageBucketSeconds,
        defaults: UserDefaults = .standard
    ) -> CloseResult {
        storeLock.lock(); defer { storeLock.unlock() }
        guard var current = validWindowsForMutation(defaults: defaults) else {
            return CloseResult(closedWindow: false,
                               resolvedWindows: 0,
                               remainingWindows: 1)
        }
        guard let index = current.lastIndex(where: { $0.end == nil }) else {
            return CloseResult(closedWindow: false,
                               resolvedWindows: 0,
                               remainingWindows: current.count)
        }
        let duration = end.timeIntervalSince(current[index].start)
        if duration <= minimumDuration {
            current.remove(at: index)
            guard persist(current, defaults: defaults) else {
                return CloseResult(closedWindow: false,
                                   resolvedWindows: 0,
                                   remainingWindows: current.count + 1)
            }
            return CloseResult(closedWindow: false,
                               resolvedWindows: 0,
                               remainingWindows: current.count)
        }
        current[index].end = end
        let totalSeconds = secondCount(start: current[index].start, end: end)
        current[index].coveredSecondBits = trimmed(
            current[index].coveredSecondBits,
            toSecondCount: totalSeconds
        )
        current[index].expectedSecondBits = trimmed(
            current[index].expectedSecondBits,
            toSecondCount: totalSeconds
        )
        let resolved = continuity(for: current[index]).continuous
        if resolved {
            current.remove(at: index)
        }
        guard persist(current, defaults: defaults) else {
            return CloseResult(closedWindow: false,
                               resolvedWindows: 0,
                               remainingWindows: current.count)
        }
        return CloseResult(closedWindow: true,
                           resolvedWindows: resolved ? 1 : 0,
                           remainingWindows: current.count)
    }

    /// Records a gap observed from consecutive accepted HR timestamps, covering
    /// suspension/silent-link cases where CoreBluetooth emitted no disconnect.
    @discardableResult
    static func recordObservedGap(start: Date,
                                  end: Date,
                                  reason: String,
                                  minimumDuration: TimeInterval = coverageBucketSeconds,
                                  defaults: UserDefaults = .standard) -> Bool {
        storeLock.lock(); defer { storeLock.unlock() }
        guard end.timeIntervalSince(start) > minimumDuration else { return false }
        guard var current = validWindowsForMutation(defaults: defaults) else {
            return false
        }
        current = current.filter { $0.end != nil }
        let candidate = Window(start: start, end: end, reason: reason)
        if let last = current.last,
           let lastEnd = last.end,
           candidate.start <= lastEnd.addingTimeInterval(1) {
            if isLegacyCoalescedWindow(last) {
                // Its real missing intervals are unknowable. Do not widen the
                // ambiguous legacy envelope with a newly observed exact gap.
                current.append(candidate)
            } else {
                current[current.count - 1] = mergeExactWindows(last, candidate)
            }
        } else {
            current.append(candidate)
        }
        return persist(current, defaults: defaults)
    }

    /// Adds one historical row as coverage evidence. The batch implementation
    /// below is the production path so one durable archive flush causes at most
    /// one UserDefaults transaction instead of one rewrite per one-Hz sample.
    @discardableResult
    static func recordMetricUsableRow(at timestamp: Date,
                                      defaults: UserDefaults = .standard) -> MetricRowResult {
        recordMetricUsableRows(at: [timestamp], defaults: defaults)
    }

    /// Adds a durably flushed batch of historical metric timestamps. Duplicate
    /// rows within the same second collapse to one bit. Rows received while a
    /// gap is open are retained but cannot resolve it until the reconnect edge
    /// is known. Closed windows resolve only from dense, boundary-spanning
    /// one-second evidence.
    @discardableResult
    static func recordMetricUsableRows(
        at timestamps: [Date],
        defaults: UserDefaults = .standard
    ) -> MetricRowResult {
        recordMetricUsableRows(at: timestamps,
                               retainingResolvedWindows: false,
                               defaults: defaults)
    }

    /// Stages positive timestamp evidence without removing a gap. Full-drain
    /// recovery uses this path so dense rows alone cannot outrun terminal raw
    /// sealing, consumer receipts, and recovered-session recomputation.
    @discardableResult
    static func stageMetricUsableRows(
        at timestamps: [Date],
        defaults: UserDefaults = .standard
    ) -> MetricRowResult {
        recordMetricUsableRows(at: timestamps,
                               retainingResolvedWindows: true,
                               defaults: defaults)
    }

    /// Full-drain authority is scoped to one selected gap. Rows from the same
    /// flash dump that happen to fall in another pending window remain raw and
    /// cannot mutate or widen this attempt's completion evidence.
    @discardableResult
    static func stageMetricUsableRows(
        at timestamps: [Date],
        forWindowID id: UUID,
        defaults: UserDefaults = .standard
    ) -> MetricRowResult {
        storeLock.lock(); defer { storeLock.unlock() }
        guard !timestamps.isEmpty else {
            return MetricRowResult(matchedWindows: 0,
                                   resolvedWindows: 0,
                                   remainingWindows: windows(defaults: defaults).count)
        }
        guard var current = validWindowsForMutation(defaults: defaults) else {
            return MetricRowResult(matchedWindows: 0,
                                   resolvedWindows: 0,
                                   remainingWindows: 1)
        }
        guard let index = current.firstIndex(where: { $0.id == id }) else {
            return MetricRowResult(matchedWindows: 0,
                                   resolvedWindows: 0,
                                   remainingWindows: current.count)
        }
        var bits = current[index].coveredSecondBits ?? Data()
        var changed = false
        for timestamp in timestamps {
            guard timestamp >= current[index].start else { continue }
            if let end = current[index].end, timestamp >= end { continue }
            let offset = timestamp.timeIntervalSince(current[index].start)
            guard offset.isFinite,
                  offset >= 0,
                  offset <= maximumRecoverableAnchorAge else { continue }
            let second = Int(floor(offset))
            guard expects(second: second, in: current[index]) else { continue }
            changed = set(second: second, in: &bits) || changed
        }
        guard changed else {
            return MetricRowResult(matchedWindows: 0,
                                   resolvedWindows: 0,
                                   remainingWindows: current.count)
        }
        current[index].coveredSecondBits = bits
        let dense = current[index].end != nil && continuity(for: current[index]).continuous
        guard persist(current, defaults: defaults) else {
            return MetricRowResult(matchedWindows: 0,
                                   resolvedWindows: 0,
                                   remainingWindows: current.count)
        }
        return MetricRowResult(matchedWindows: 1,
                               resolvedWindows: dense ? 1 : 0,
                               remainingWindows: current.count)
    }

    private static func recordMetricUsableRows(
        at timestamps: [Date],
        retainingResolvedWindows: Bool,
        defaults: UserDefaults
    ) -> MetricRowResult {
        storeLock.lock(); defer { storeLock.unlock() }
        guard !timestamps.isEmpty else {
            let count = windows(defaults: defaults).count
            return MetricRowResult(matchedWindows: 0,
                                   resolvedWindows: 0,
                                   remainingWindows: count)
        }
        guard var current = validWindowsForMutation(defaults: defaults) else {
            return MetricRowResult(matchedWindows: 0,
                                   resolvedWindows: 0,
                                   remainingWindows: 1)
        }
        var matchedWindowIDs: Set<UUID> = []
        var resolved = 0
        var changed = false
        for index in current.indices.reversed() {
            var bits = current[index].coveredSecondBits ?? Data()
            var windowChanged = false
            for timestamp in timestamps {
                guard timestamp >= current[index].start else { continue }
                if let end = current[index].end, timestamp >= end { continue }
                let offset = timestamp.timeIntervalSince(current[index].start)
                guard offset.isFinite,
                      offset >= 0,
                      offset <= maximumRecoverableAnchorAge else { continue }
                let second = Int(floor(offset))
                guard expects(second: second, in: current[index]) else { continue }
                matchedWindowIDs.insert(current[index].id)
                if set(second: second, in: &bits) {
                    windowChanged = true
                }
            }
            guard windowChanged else { continue }
            current[index].coveredSecondBits = bits
            changed = true
            if current[index].end != nil,
               continuity(for: current[index]).continuous {
                resolved += 1
                if !retainingResolvedWindows {
                    current.remove(at: index)
                }
            }
        }
        if changed {
            guard persist(current, defaults: defaults) else {
                return MetricRowResult(matchedWindows: 0,
                                       resolvedWindows: 0,
                                       remainingWindows: current.count)
            }
        }
        return MetricRowResult(matchedWindows: matchedWindowIDs.count,
                               resolvedWindows: resolved,
                               remainingWindows: current.count)
    }

    /// Selects one genuine closed pending window. Open windows are never sent
    /// to recovery because their right boundary is not yet known.
    static func oldestClosedRecoveryCandidate(
        defaults: UserDefaults = .standard
    ) -> RecoveryCandidate? {
        storeLock.lock(); defer { storeLock.unlock() }
        guard let current = validWindowsForMutation(defaults: defaults) else {
            return nil
        }
        guard let window = current
            .filter({ $0.end != nil && !isLegacyCoalescedWindow($0) })
            .sorted(by: { $0.start < $1.start })
            .first,
              let (generation, data) = validSnapshot(defaults: defaults) else {
            return nil
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return RecoveryCandidate(window: window,
                                 ledgerGeneration: generation,
                                 ledgerSnapshotSHA256: digest)
    }

    /// A reconnect-created gap is the one a user is waiting to see repaired.
    /// Keep older unresolved windows durable, but let the automatic live-link
    /// recovery path select the newest closed exact interval first. Explicit
    /// archival repair can still use the chronological selector above.
    static func newestClosedRecoveryCandidate(
        defaults: UserDefaults = .standard
    ) -> RecoveryCandidate? {
        storeLock.lock(); defer { storeLock.unlock() }
        guard let current = validWindowsForMutation(defaults: defaults) else {
            return nil
        }
        guard let window = current
            .filter({ $0.end != nil && !isLegacyCoalescedWindow($0) })
            .sorted(by: { $0.start > $1.start })
            .first,
              let (generation, data) = validSnapshot(defaults: defaults) else {
            return nil
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return RecoveryCandidate(window: window,
                                 ledgerGeneration: generation,
                                 ledgerSnapshotSHA256: digest)
    }

    static func allClosedRecoveryCandidates(
        defaults: UserDefaults = .standard
    ) -> [RecoveryCandidate] {
        storeLock.lock(); defer { storeLock.unlock() }
        guard let valid = validWindowsForMutation(defaults: defaults) else {
            return []
        }
        let current = valid
            .filter { $0.end != nil && !isLegacyCoalescedWindow($0) }
            .sorted { $0.start < $1.start }
        guard !current.isEmpty,
              let (generation, data) = validSnapshot(defaults: defaults) else {
            return []
        }
        let digest = SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
        return current.map {
            RecoveryCandidate(window: $0,
                              ledgerGeneration: generation,
                              ledgerSnapshotSHA256: digest)
        }
    }

    static func recoveryCandidate(
        id: UUID,
        startUnix: TimeInterval,
        endUnix: TimeInterval,
        reason: String,
        defaults: UserDefaults = .standard
    ) -> RecoveryCandidate? {
        storeLock.lock(); defer { storeLock.unlock() }
        guard let valid = validWindowsForMutation(defaults: defaults),
              let current = valid.first(where: {
            $0.id == id
                && $0.start.timeIntervalSince1970 == startUnix
                && $0.end?.timeIntervalSince1970 == endUnix
                && $0.reason == reason
                && !isLegacyCoalescedWindow($0)
        }), let (generation, data) = validSnapshot(defaults: defaults) else {
            return nil
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return .init(window: current,
                     ledgerGeneration: generation,
                     ledgerSnapshotSHA256: digest)
    }

    /// Final removal is deliberately separate from evidence staging. Callers
    /// may invoke it only after their durable full-drain authority reaches the
    /// consumer-committed state. Sparse/empty evidence keeps the gap pending.
    @discardableResult
    static func commitResolvedWindow(
        id: UUID,
        defaults: UserDefaults = .standard
    ) -> Bool {
        storeLock.lock(); defer { storeLock.unlock() }
        guard var current = validWindowsForMutation(defaults: defaults) else {
            return false
        }
        guard let index = current.firstIndex(where: { $0.id == id }),
              current[index].end != nil,
              continuity(for: current[index]).continuous else { return false }
        current.remove(at: index)
        guard persist(current, defaults: defaults) else { return false }
        return !windows(defaults: defaults).contains { $0.id == id }
    }

    /// CAS variant for full-drain settlement. Compaction deliberately reuses
    /// the oldest UUID, so UUID+density alone cannot authorize removal after a
    /// long-running transport attempt.
    @discardableResult
    static func commitResolvedWindow(
        candidate: RecoveryCandidate,
        defaults: UserDefaults = .standard
    ) -> Bool {
        storeLock.lock(); defer { storeLock.unlock() }
        let envelope = loadEnvelope(defaults: defaults)
        guard envelope.state == .valid,
              candidate.ledgerGeneration > 0,
              envelope.generation >= candidate.ledgerGeneration,
              candidate.ledgerSnapshotSHA256.count == 64,
              candidate.ledgerSnapshotSHA256.unicodeScalars.allSatisfy({
                  CharacterSet(charactersIn: "0123456789abcdef").contains($0)
              }) else { return false }
        if envelope.generation == candidate.ledgerGeneration {
            guard let snapshot = try? canonicalData(envelope),
                  sha256(snapshot) == candidate.ledgerSnapshotSHA256 else {
                return false
            }
        }
        var current = bounded(envelope.windows)
        guard let index = current.firstIndex(where: {
            $0.id == candidate.window.id
                && $0.start == candidate.window.start
                && $0.end == candidate.window.end
                && $0.reason == candidate.window.reason
                && $0.expectedSecondBits == candidate.window.expectedSecondBits
        }), current[index].end != nil,
           continuity(for: current[index]).continuous else { return false }
        current.remove(at: index)
        guard persist(current, defaults: defaults) else { return false }
        let reread = windows(defaults: defaults)
        return !reread.contains { window in
            window.id == candidate.window.id
                && window.start == candidate.window.start
                && window.end == candidate.window.end
                && window.reason == candidate.window.reason
        }
    }

    static func coveragePercent(for window: Window) -> Int {
        continuity(for: window).densityPercent
    }

    /// Replaces one ambiguous legacy envelope only when an external migration
    /// has recovered its exact constituent intervals. The intervals must be
    /// finite, closed, non-empty, and contained by the old envelope. Existing
    /// positive coverage is intersected into those intervals; it is never
    /// promoted across the formerly unknown live spans.
    @discardableResult
    static func migrateLegacyCoalescedWindow(
        id: UUID,
        exactIntervals: [(start: Date, end: Date, reason: String)],
        defaults: UserDefaults = .standard
    ) -> Bool {
        storeLock.lock(); defer { storeLock.unlock() }
        guard var current = validWindowsForMutation(defaults: defaults) else {
            return false
        }
        guard let index = current.firstIndex(where: { $0.id == id }),
              isLegacyCoalescedWindow(current[index]),
              let envelopeEnd = current[index].end,
              !exactIntervals.isEmpty,
              exactIntervals.allSatisfy({ interval in
                  interval.start >= current[index].start
                      && interval.end <= envelopeEnd
                      && interval.end > interval.start
                      && interval.start.timeIntervalSince1970.isFinite
                      && interval.end.timeIntervalSince1970.isFinite
              }) else { return false }

        let legacy = current.remove(at: index)
        let replacements = exactIntervals.map { interval -> Window in
            var replacement = Window(start: interval.start,
                                     end: interval.end,
                                     reason: interval.reason)
            if let legacyCoverage = legacy.coveredSecondBits {
                var translated = Data()
                let sourceCount = secondCount(start: legacy.start, end: envelopeEnd)
                for sourceSecond in setSecondIndexes(in: legacyCoverage,
                                                     limitedTo: sourceCount) {
                    let timestamp = legacy.start.addingTimeInterval(Double(sourceSecond))
                    guard timestamp >= interval.start, timestamp < interval.end else { continue }
                    let targetSecond = Int(floor(timestamp.timeIntervalSince(interval.start)))
                    _ = set(second: targetSecond, in: &translated)
                }
                replacement.coveredSecondBits = trimmed(
                    translated,
                    toSecondCount: secondCount(start: interval.start, end: interval.end)
                )
            }
            return replacement
        }
        current.insert(contentsOf: replacements, at: index)
        return persist(current, defaults: defaults)
    }

    static func continuity(for window: Window) -> Continuity {
        guard window.id != corruptionSentinelID,
              !window.reason.hasPrefix("durable_gap_ledger_corrupt_"),
              let end = window.end,
              end > window.start else {
            return Continuity(observedSeconds: 0,
                              expectedSeconds: 0,
                              densityPercent: 0,
                              maximumGapSeconds: 0,
                              p95GapSeconds: 0,
                              continuous: false)
        }
        guard !isLegacyCoalescedWindow(window) else {
            return Continuity(observedSeconds: 0,
                              expectedSeconds: 0,
                              densityPercent: 0,
                              maximumGapSeconds: 0,
                              p95GapSeconds: 0,
                              continuous: false)
        }
        let duration = end.timeIntervalSince(window.start)
        guard duration.isFinite,
              duration <= maximumRecoverableAnchorAge else {
            return Continuity(observedSeconds: 0,
                              expectedSeconds: 0,
                              densityPercent: 0,
                              maximumGapSeconds: 0,
                              p95GapSeconds: 0,
                              continuous: false)
        }
        let envelopeSeconds = secondCount(start: window.start, end: end)
        let expectedIndexes = window.expectedSecondBits.map {
            setSecondIndexes(in: $0, limitedTo: envelopeSeconds)
        } ?? Array(0..<envelopeSeconds)
        let expectedSet = Set(expectedIndexes)
        let observed = setSecondIndexes(in: window.coveredSecondBits,
                                        limitedTo: envelopeSeconds)
            .filter { expectedSet.contains($0) }
        let expected = expectedIndexes.count
        let density = min(100, Int((Double(observed.count)
            / Double(max(1, expected)) * 100).rounded(.down)))
        guard expected > 0, !observed.isEmpty else {
            return Continuity(observedSeconds: 0,
                              expectedSeconds: expected,
                              densityPercent: 0,
                              maximumGapSeconds: expected,
                              p95GapSeconds: expected,
                              continuous: false)
        }
        let observedSet = Set(observed)
        let expectedRuns = contiguousRuns(expectedIndexes)
        var cadenceGaps: [Int] = []
        var maximumGap = 0
        for run in expectedRuns {
            let runObserved = run.filter { observedSet.contains($0) }
            guard let first = runObserved.first, let last = runObserved.last else {
                maximumGap = max(maximumGap, run.count)
                cadenceGaps.append(run.count)
                continue
            }
            let internalGaps = zip(runObserved, runObserved.dropFirst()).map { $1 - $0 }
            let startGap = first - run[0]
            let endGap = run[run.count - 1] - last
            maximumGap = max(maximumGap,
                             max(max(startGap, endGap), internalGaps.max() ?? 0))
            cadenceGaps.append(contentsOf: internalGaps)
            if internalGaps.isEmpty {
                cadenceGaps.append(max(startGap, endGap))
            }
        }
        let p95Gap = nearestRankPercentile(cadenceGaps, percentile: 0.95)
        let continuous = density >= minimumResolvedDensityPercent
            && maximumGap <= maximumResolvedGapSeconds
            && p95Gap <= maximumResolvedP95GapSeconds
        return Continuity(observedSeconds: observed.count,
                          expectedSeconds: expected,
                          densityPercent: density,
                          maximumGapSeconds: maximumGap,
                          p95GapSeconds: p95Gap,
                          continuous: continuous)
    }

    static func stagedMetricTimestamps(
        forWindowID id: UUID,
        defaults: UserDefaults = .standard
    ) -> [TimeInterval] {
        guard let window = windows(defaults: defaults).first(where: {
            $0.id == id
        }), let end = window.end else { return [] }
        return setSecondIndexes(in: window.coveredSecondBits,
                                limitedTo: secondCount(start: window.start, end: end))
            .filter { expects(second: $0, in: window) }
            .map { window.start.timeIntervalSince1970 + Double($0) }
    }

    static func hasPendingWindows(defaults: UserDefaults = .standard) -> Bool {
        !windows(defaults: defaults).isEmpty
    }

    static func hasOpenWindow(defaults: UserDefaults = .standard) -> Bool {
        windows(defaults: defaults).contains { $0.end == nil }
    }

    /// Returns only a plausible, finite timestamp. A malformed or future value
    /// must not create a synthetic historical-recovery interval.
    static func liveContinuityAnchor(defaults: UserDefaults = .standard,
                                     now: Date = Date()) -> Date? {
        storeLock.lock(); defer { storeLock.unlock() }
        let url = anchorURL(defaults: defaults)
        let raw: Double? = {
            if let data = try? Data(contentsOf: url),
               let envelope = try? JSONDecoder().decode(AnchorEnvelope.self, from: data),
               envelope.version == AnchorEnvelope.currentVersion,
               (try? canonicalData(envelope)) == data {
                return envelope.acceptedUnix
            }
            // One-time predecessor migration. It remains a timestamp only and
            // cannot authorize coverage.
            return defaults.object(forKey: liveContinuityAnchorKey) as? Double
        }()
        guard let raw,
              raw.isFinite,
              raw > 0,
              raw <= now.timeIntervalSince1970 + 5 else { return nil }
        return Date(timeIntervalSince1970: raw)
    }

    /// Advances the independently fsynced predecessor at most once per second.
    /// This keeps the relaunch uncertainty within the archive's one-Hz cadence
    /// contract. It never moves backwards, including when delayed callbacks
    /// arrive out of order.
    @discardableResult
    static func advanceLiveContinuityAnchor(to timestamp: Date,
                                            force: Bool = false,
                                            defaults: UserDefaults = .standard) -> Bool {
        storeLock.lock(); defer { storeLock.unlock() }
        let raw = timestamp.timeIntervalSince1970
        guard raw.isFinite, raw > 0 else { return false }
        let priorRaw = liveContinuityAnchor(defaults: defaults,
                                            now: timestamp.addingTimeInterval(5))?
            .timeIntervalSince1970
        if let priorRaw, priorRaw.isFinite {
            guard raw > priorRaw else { return false }
            guard force || raw - priorRaw >= liveContinuityAnchorWriteInterval else {
                return false
            }
        }
        let envelope = AnchorEnvelope(version: AnchorEnvelope.currentVersion,
                                      acceptedUnix: raw)
        let directory = storageDirectory(defaults: defaults)
        let temporary = directory.appendingPathComponent(
            ".\(anchorFileName).\(UUID().uuidString).tmp"
        )
        do {
            try createDurableDirectory(at: directory)
            try canonicalData(envelope).write(to: temporary)
            try synchronizeFile(at: temporary)
            try replaceOrMove(temporary, to: anchorURL(defaults: defaults))
            try synchronizeDirectory(directory)
            let reread = try Data(contentsOf: anchorURL(defaults: defaults))
            guard try canonicalData(envelope) == reread else { return false }
            defaults.removeObject(forKey: liveContinuityAnchorKey)
            return true
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            return false
        }
    }

    /// Reconstructs only the missing *window* when the first accepted pulse in
    /// this process has no in-memory predecessor. No HR, RR, steps, calories or
    /// strain are created. Historical metric rows must still independently
    /// satisfy the dense continuity contract for this exact interval.
    @discardableResult
    static func recordRestorationGapIfNeeded(firstAcceptedAt timestamp: Date,
                                             reason: String,
                                             minimumDuration: TimeInterval = coverageBucketSeconds,
                                             maximumAnchorAge: TimeInterval = maximumRecoverableAnchorAge,
                                             defaults: UserDefaults = .standard) -> Bool {
        storeLock.lock(); defer { storeLock.unlock() }
        defer {
            _ = advanceLiveContinuityAnchor(to: timestamp,
                                            force: true,
                                            defaults: defaults)
        }
        guard let anchor = liveContinuityAnchor(defaults: defaults, now: timestamp) else {
            // Replace malformed/future persisted state with this real accepted
            // observation. `advance` normally refuses to move backwards, so the
            // invalid value must be removed explicitly first.
            if defaults.object(forKey: liveContinuityAnchorKey) != nil {
                defaults.removeObject(forKey: liveContinuityAnchorKey)
            }
            return false
        }
        let anchorAge = timestamp.timeIntervalSince(anchor)
        // Start at the exact durable predecessor. The boundary sample can be
        // present in both live and history stores; archive identity dedupe makes
        // that overlap safe, while skipping it would make short relaunch gaps
        // mathematically incapable of reaching the product's 90% requirement.
        guard timestamp.timeIntervalSince(anchor) > minimumDuration,
              anchorAge <= maximumAnchorAge,
              !hasOpenWindow(defaults: defaults) else { return false }
        return recordObservedGap(start: anchor,
                                 end: timestamp,
                                 reason: reason,
                                 minimumDuration: minimumDuration,
                                 defaults: defaults)
    }

    static func clearLiveContinuityAnchor(defaults: UserDefaults = .standard) {
        storeLock.lock(); defer { storeLock.unlock() }
        try? FileManager.default.removeItem(at: anchorURL(defaults: defaults))
        defaults.removeObject(forKey: liveContinuityAnchorKey)
    }

    private static func secondCount(start: Date, end: Date) -> Int {
        max(1, Int(ceil(max(0, end.timeIntervalSince(start)))))
    }

    @discardableResult
    private static func set(second: Int, in bits: inout Data) -> Bool {
        guard second >= 0 else { return false }
        let byteIndex = second / 8
        if byteIndex >= bits.count {
            bits.append(contentsOf: repeatElement(0, count: byteIndex - bits.count + 1))
        }
        let mask = UInt8(1 << UInt8(second % 8))
        guard bits[byteIndex] & mask == 0 else { return false }
        bits[byteIndex] |= mask
        return true
    }

    private static func trimmed(_ bits: Data?, toSecondCount count: Int) -> Data? {
        guard count > 0, var bits else { return nil }
        let byteCount = (count + 7) / 8
        if bits.count > byteCount {
            bits = bits.prefix(byteCount)
        }
        guard !bits.isEmpty else { return nil }
        let remainder = count % 8
        if remainder > 0 {
            bits[bits.count - 1] &= UInt8((1 << remainder) - 1)
        }
        return bits.contains(where: { $0 != 0 }) ? bits : nil
    }

    private static func setSecondIndexes(in bits: Data?, limitedTo count: Int) -> [Int] {
        guard count > 0, let bits, !bits.isEmpty else { return [] }
        var indexes: [Int] = []
        indexes.reserveCapacity(min(count, bits.count * 8))
        for second in 0..<count {
            let byteIndex = second / 8
            guard byteIndex < bits.count else { break }
            let mask = UInt8(1 << UInt8(second % 8))
            if bits[byteIndex] & mask != 0 {
                indexes.append(second)
            }
        }
        return indexes
    }

    private static func expects(second: Int, in window: Window) -> Bool {
        guard second >= 0, !isLegacyCoalescedWindow(window) else { return false }
        guard let expected = window.expectedSecondBits else { return true }
        let byteIndex = second / 8
        guard byteIndex < expected.count else { return false }
        return expected[byteIndex] & UInt8(1 << UInt8(second % 8)) != 0
    }

    private static func contiguousRuns(_ indexes: [Int]) -> [[Int]] {
        guard var previous = indexes.first else { return [] }
        var runs: [[Int]] = [[previous]]
        for index in indexes.dropFirst() {
            if index == previous + 1 {
                runs[runs.count - 1].append(index)
            } else {
                runs.append([index])
            }
            previous = index
        }
        return runs
    }

    private static func nearestRankPercentile(_ values: [Int], percentile: Double) -> Int {
        guard !values.isEmpty else { return 0 }
        let ordered = values.sorted()
        let rank = max(1, Int(ceil(Double(ordered.count) * min(1, max(0, percentile)))))
        return ordered[min(ordered.count - 1, rank - 1)]
    }

    /// Keeps the defaults payload bounded without turning the live spans
    /// between disjoint outages into missing time. Compacted windows retain an
    /// exact one-bit-per-second union mask and translate existing coverage into
    /// the same coordinate system.
    private static func bounded(_ windows: [Window]) -> [Window] {
        var result = windows.sorted { $0.start < $1.start }
        while result.count > maximumWindows {
            guard let mergeIndex = result.indices.dropLast().first(where: { index in
                result[index].end != nil
                    && result[index + 1].end != nil
                    && !isLegacyCoalescedWindow(result[index])
                    && !isLegacyCoalescedWindow(result[index + 1])
            }) else {
                // A production legacy payload contains at most one ambiguous
                // envelope. If a corrupt payload contains only such entries,
                // retaining them (normally at most cap + 1) is safer than
                // discarding or inventing their missing-time union.
                break
            }
            let merged = mergeExactWindows(result[mergeIndex], result[mergeIndex + 1])
            result.replaceSubrange(mergeIndex...mergeIndex + 1, with: [merged])
        }
        return result
    }

    private static func mergeExactWindows(_ lhs: Window, _ rhs: Window) -> Window {
        precondition(!isLegacyCoalescedWindow(lhs) && !isLegacyCoalescedWindow(rhs))
        guard let lhsEnd = lhs.end, let rhsEnd = rhs.end else { return lhs }
        let start = min(lhs.start, rhs.start)
        let end = max(lhsEnd, rhsEnd)
        let envelopeCount = secondCount(start: start, end: end)
        var expected = Data()
        var covered = Data()

        for source in [lhs, rhs] {
            guard let sourceEnd = source.end else { continue }
            let sourceCount = secondCount(start: source.start, end: sourceEnd)
            let sourceExpected = source.expectedSecondBits.map {
                setSecondIndexes(in: $0, limitedTo: sourceCount)
            } ?? Array(0..<sourceCount)
            let sourceExpectedSet = Set(sourceExpected)
            for sourceSecond in sourceExpected {
                let target = Int(floor(source.start
                    .addingTimeInterval(Double(sourceSecond)).timeIntervalSince(start)))
                guard target >= 0, target < envelopeCount else { continue }
                _ = set(second: target, in: &expected)
            }
            for sourceSecond in setSecondIndexes(in: source.coveredSecondBits,
                                                 limitedTo: sourceCount) {
                guard sourceExpectedSet.contains(sourceSecond) else { continue }
                let target = Int(floor(source.start
                    .addingTimeInterval(Double(sourceSecond)).timeIntervalSince(start)))
                guard target >= 0, target < envelopeCount else { continue }
                _ = set(second: target, in: &covered)
            }
        }

        return Window(id: lhs.start <= rhs.start ? lhs.id : rhs.id,
                      start: start,
                      end: end,
                      reason: coalescedWindowReason,
                      expectedSecondBits: trimmed(expected, toSecondCount: envelopeCount),
                      coveredSecondBits: trimmed(covered, toSecondCount: envelopeCount))
    }

    @discardableResult
    private static func persist(_ windows: [Window], defaults: UserDefaults) -> Bool {
        storeLock.lock(); defer { storeLock.unlock() }
        let prior = loadEnvelope(defaults: defaults)
        guard prior.state == .valid else { return false }
        let boundedWindows = bounded(windows)
        let envelope = Envelope(version: Envelope.currentVersion,
                                generation: prior.generation &+ 1,
                                state: .valid,
                                windows: boundedWindows,
                                corruptionSHA256: nil)
        do {
            try persistEnvelope(envelope, defaults: defaults)
            let verified = try readValidEnvelope(at: stateURL(defaults: defaults))
            guard verified == envelope else { return false }
            defaults.set(envelope.generation, forKey: generationKey)
            defaults.set(true, forKey: migrationCompleteKey)
            // Remove the legacy payload only after the atomic file has been
            // fsynced and byte-for-byte decoded back.
            defaults.removeObject(forKey: defaultsKey)
            return true
        } catch {
            return false
        }
    }

    private static let corruptionSentinelID = UUID(
        uuidString: "00000000-0000-4000-8000-000000000002"
    )!

    private static func corruptionSentinel(digest: String) -> Window {
        Window(id: corruptionSentinelID,
               start: Date(timeIntervalSince1970: 1),
               reason: "durable_gap_ledger_corrupt_\(digest)")
    }

    private static func loadEnvelope(defaults: UserDefaults) -> Envelope {
        let primary = stateURL(defaults: defaults)
        if FileManager.default.fileExists(atPath: primary.path) {
            if let valid = try? readValidEnvelope(at: primary) { return valid }
            let backup = backupURL(defaults: defaults)
            if let recovered = try? readValidEnvelope(at: backup) {
                // Repair the primary from the last fsynced valid generation.
                try? persistEnvelope(recovered, defaults: defaults,
                                     preserveExistingAsBackup: false)
                return recovered
            }
            let bytes = (try? Data(contentsOf: primary)) ?? Data("missing".utf8)
            return Envelope(version: Envelope.currentVersion,
                            generation: max(1, legacyGeneration(defaults)),
                            state: .quarantinedCorruption,
                            windows: [],
                            corruptionSHA256: sha256(bytes))
        }

        if let legacy = defaults.data(forKey: defaultsKey) {
            guard let decoded = try? JSONDecoder().decode([Window].self, from: legacy) else {
                let quarantined = Envelope(
                    version: Envelope.currentVersion,
                    generation: max(1, legacyGeneration(defaults)),
                    state: .quarantinedCorruption,
                    windows: [],
                    corruptionSHA256: sha256(legacy)
                )
                try? persistEnvelope(quarantined, defaults: defaults,
                                     preserveExistingAsBackup: false)
                return quarantined
            }
            let migrated = Envelope(version: Envelope.currentVersion,
                                    generation: max(1, legacyGeneration(defaults)),
                                    state: .valid,
                                    windows: bounded(decoded),
                                    corruptionSHA256: nil)
            do {
                try persistEnvelope(migrated, defaults: defaults,
                                    preserveExistingAsBackup: false)
                guard try readValidEnvelope(at: primary) == migrated else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                defaults.set(true, forKey: migrationCompleteKey)
                defaults.removeObject(forKey: defaultsKey)
                defaults.set(migrated.generation, forKey: generationKey)
            } catch {
                return Envelope(version: Envelope.currentVersion,
                                generation: migrated.generation,
                                state: .quarantinedCorruption,
                                windows: [],
                                corruptionSHA256: sha256(legacy))
            }
            return migrated
        }
        return Envelope(version: Envelope.currentVersion,
                        generation: max(0, legacyGeneration(defaults)),
                        state: .valid,
                        windows: [],
                        corruptionSHA256: nil)
    }

    private static func readValidEnvelope(at url: URL) throws -> Envelope {
        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode(Envelope.self, from: data)
        guard decoded.version == Envelope.currentVersion,
              decoded.state == .valid,
              try canonicalData(decoded) == data else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return decoded
    }

    private static func persistEnvelope(
        _ envelope: Envelope,
        defaults: UserDefaults,
        preserveExistingAsBackup: Bool = true
    ) throws {
        let fileManager = FileManager.default
        let directory = storageDirectory(defaults: defaults)
        try createDurableDirectory(at: directory)
        let target = stateURL(defaults: defaults)
        if preserveExistingAsBackup,
           fileManager.fileExists(atPath: target.path),
           (try? readValidEnvelope(at: target)) != nil {
            let backupTemporary = directory.appendingPathComponent(
                ".\(backupFileName).\(UUID().uuidString).tmp"
            )
            try fileManager.copyItem(at: target, to: backupTemporary)
            try synchronizeFile(at: backupTemporary)
            try replaceOrMove(backupTemporary, to: backupURL(defaults: defaults))
        }
        let temporary = directory.appendingPathComponent(
            ".\(stateFileName).\(UUID().uuidString).tmp"
        )
        try canonicalData(envelope).write(to: temporary)
        try synchronizeFile(at: temporary)
        try replaceOrMove(temporary, to: target)
        try synchronizeDirectory(directory)
    }

    private static func storageDirectory(defaults: UserDefaults) -> URL {
        if defaults === UserDefaults.standard {
            let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                in: .userDomainMask).first!
            return base.appendingPathComponent("Atria/HistoricalRecovery",
                                               isDirectory: true)
        }
        let namespace: String
        if let existing = defaults.string(forKey: testStorageNamespaceKey) {
            namespace = existing
        } else {
            namespace = UUID().uuidString
            defaults.set(namespace, forKey: testStorageNamespaceKey)
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("AtriaHistoricalGapLedgerTests", isDirectory: true)
            .appendingPathComponent(namespace, isDirectory: true)
    }

    private static func existingStorageDirectoryForReadOnlyAccess(
        defaults: UserDefaults
    ) -> URL? {
        if defaults === UserDefaults.standard {
            let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                in: .userDomainMask).first!
            return base.appendingPathComponent("Atria/HistoricalRecovery",
                                               isDirectory: true)
        }
        guard let namespace = defaults.string(forKey: testStorageNamespaceKey) else {
            return nil
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("AtriaHistoricalGapLedgerTests", isDirectory: true)
            .appendingPathComponent(namespace, isDirectory: true)
    }

    private static func stateURL(defaults: UserDefaults) -> URL {
        storageDirectory(defaults: defaults).appendingPathComponent(stateFileName)
    }

    private static func backupURL(defaults: UserDefaults) -> URL {
        storageDirectory(defaults: defaults).appendingPathComponent(backupFileName)
    }

    private static func anchorURL(defaults: UserDefaults) -> URL {
        storageDirectory(defaults: defaults).appendingPathComponent(anchorFileName)
    }

    private static func legacyGeneration(_ defaults: UserDefaults) -> UInt64 {
        (defaults.object(forKey: generationKey) as? NSNumber)?.uint64Value ?? 0
    }

    private static func validSnapshot(
        defaults: UserDefaults
    ) -> (generation: UInt64, data: Data)? {
        storeLock.lock(); defer { storeLock.unlock() }
        let envelope = loadEnvelope(defaults: defaults)
        guard envelope.state == .valid,
              let data = try? canonicalData(envelope),
              !data.isEmpty else { return nil }
        return (max(1, envelope.generation), data)
    }

    static func durableStateURLForTesting(defaults: UserDefaults) -> URL {
        stateURL(defaults: defaults)
    }

    static func durableBackupURLForTesting(defaults: UserDefaults) -> URL {
        backupURL(defaults: defaults)
    }

    static func resetStorageForTesting(defaults: UserDefaults) {
        storeLock.lock(); defer { storeLock.unlock() }
        try? FileManager.default.removeItem(at: storageDirectory(defaults: defaults))
    }

    private static func canonicalData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func synchronizeFile(at url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.synchronize()
        try handle.close()
    }

    private static func replaceOrMove(_ source: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: source)
        } else {
            try fileManager.moveItem(at: source, to: destination)
        }
    }

    private static func synchronizeDirectory(_ directory: URL) throws {
        let descriptor = open(directory.path, O_RDONLY)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    /// `mkdir -p` alone does not make newly-created directory entries durable.
    /// Fsync every parent that received a child entry before publishing files
    /// inside the final directory.
    private static func createDurableDirectory(at directory: URL) throws {
        let fileManager = FileManager.default
        var missing: [URL] = []
        var cursor = directory.standardizedFileURL
        while cursor.path != "/",
              !fileManager.fileExists(atPath: cursor.path) {
            missing.append(cursor)
            cursor.deleteLastPathComponent()
        }
        try fileManager.createDirectory(at: directory,
                                        withIntermediateDirectories: true)
        for created in missing.reversed() {
            try synchronizeDirectory(created.deletingLastPathComponent())
        }
    }
}
