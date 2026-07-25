import Darwin
import CryptoKit
import Foundation

/// Crash-safe, replay-idempotent storage for WHOOP historical frames.
///
/// The store deliberately remains independent from `HistoricalArchive.Record`.
/// Callers encode their record as a JSON object and select the active archive
/// file (which allows the existing archive rotation policy to remain in charge).
/// A reserved identity property is injected into the object; unknown Codable
/// properties are ignored, so existing readers can continue decoding records.
final class AtriaHistoricalArchiveDurableStore {
    static let identityProperty = "_atriaHistoryKey"
    static let identitySchemaProperty = "_atriaHistoryIdentityVersion"
    static let identityObservedAtProperty = "_atriaHistoryObservedAtUnix"
    static let productionIdentityRetention: TimeInterval = 14 * 24 * 60 * 60
    static let productionMaximumReceiptBatchIdentities = 65_536
    /// The derived index snapshot is only a launch accelerator. Rebuilding it
    /// after every ~50-record HISTORY_END page put a full index read/hash in
    /// the ACK critical path and let the strap's serve session expire before
    /// the acknowledgement arrived. Raw, index, receipt-chain and admission
    /// fsyncs remain unchanged; a missing/stale snapshot simply rebuilds at
    /// next launch.
    static let productionDerivedSnapshotFlushInterval: UInt64 = 512

    struct FrameIdentity: Hashable, Sendable {
        let strapIdentifier: String
        let protocolVersion: UInt8
        let counter: UInt32
        let unixSeconds: UInt32
        let subsecond: UInt16
        /// The complete payload is part of the replay identity. CRC32 is useful
        /// for corruption detection but is not an identity: distinct payloads
        /// can deliberately share it, which would make a false duplicate able
        /// to cross the HISTORY_END ACK boundary.
        let payload: Data

        init(strapIdentifier: String,
             protocolVersion: UInt8,
             counter: UInt32,
             unixSeconds: UInt32,
             subsecond: UInt16,
             payload: Data) {
            self.strapIdentifier = strapIdentifier
            self.protocolVersion = protocolVersion
            self.counter = counter
            self.unixSeconds = unixSeconds
            self.subsecond = subsecond
            self.payload = payload
        }

        /// Canonical identity factory shared by live admission, durable raw
        /// append and retired replay lookup. Keeping the byte offsets here
        /// prevents those three authorities from silently disagreeing.
        static func whoop4(strapIdentifier: String, payload: Data) -> Self {
            let bytes = [UInt8](payload)
            func u16le(_ offset: Int) -> UInt16 {
                guard bytes.count >= offset + 2 else { return 0 }
                return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
            }
            func u32le(_ offset: Int) -> UInt32 {
                guard bytes.count >= offset + 4 else { return 0 }
                return UInt32(bytes[offset])
                    | (UInt32(bytes[offset + 1]) << 8)
                    | (UInt32(bytes[offset + 2]) << 16)
                    | (UInt32(bytes[offset + 3]) << 24)
            }
            return .init(
                strapIdentifier: strapIdentifier,
                protocolVersion: bytes.count > 1 ? bytes[1] : 0,
                counter: u32le(3),
                unixSeconds: u32le(7),
                subsecond: u16le(11),
                payload: payload
            )
        }

        /// Canonical schema-v2 key. It is intentionally longer than a digest:
        /// bounded retention is handled by the exact-index horizon, never by
        /// accepting a probabilistic false-positive at ingestion.
        var stableKey: String {
            let strap = Array(strapIdentifier.utf8)
            var bytes: [UInt8] = [2]
            Self.append(UInt32(strap.count), to: &bytes)
            bytes.append(contentsOf: strap)
            bytes.append(protocolVersion)
            Self.append(counter, to: &bytes)
            Self.append(unixSeconds, to: &bytes)
            Self.append(subsecond, to: &bytes)
            Self.append(UInt32(payload.count), to: &bytes)
            bytes.append(contentsOf: payload)
            return bytes.map { String(format: "%02x", $0) }.joined()
        }

        private static func append(_ value: UInt16, to bytes: inout [UInt8]) {
            bytes.append(UInt8(truncatingIfNeeded: value))
            bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        }

        private static func append(_ value: UInt32, to bytes: inout [UInt8]) {
            bytes.append(UInt8(truncatingIfNeeded: value))
            bytes.append(UInt8(truncatingIfNeeded: value >> 8))
            bytes.append(UInt8(truncatingIfNeeded: value >> 16))
            bytes.append(UInt8(truncatingIfNeeded: value >> 24))
        }

    }

    final class DrainBatch {
        fileprivate let identifier = UUID()
        fileprivate var keys = Set<String>()
        fileprivate var dirtyURLs = Set<URL>()
        fileprivate var lastReceipt: FlushReceipt?

        fileprivate init() {}
    }

    enum AppendResult: Equatable {
        case inserted
        /// `durable == false` means the replay shares an earlier, unflushed
        /// append. Flushing this batch also flushes that earlier append.
        case duplicate(durable: Bool)
    }

    /// One independently auditable side of a raw-history durability boundary.
    /// `recordCount`/`byteCount` describe rows that became durable at this
    /// boundary, not rows merely replayed from an earlier boundary.  The key
    /// digest still covers every exact full-payload identity observed in the
    /// batch, including a replay-only batch.
    struct DurableSeal: Equatable, Sendable, Codable {
        let storeIdentifier: String
        let durableSequence: UInt64
        let snapshotSHA256: String
        let batchKeysSHA256: String
        let byteCount: UInt64
        let recordCount: UInt64
        let observedIdentityCount: UInt64
        let fsyncedAtUnix: TimeInterval
    }

    struct FlushReceipt: Equatable, Sendable {
        let batchIdentifier: UUID
        let synchronizedFiles: [URL]
        let insertedOrPendingKeys: Int
        let raw: DurableSeal
        let identity: DurableSeal
        /// Cumulative, restart-verifiable receipt-chain head persisted only
        /// after raw archive files and the exact identity index have fsynced.
        let receiptChainSHA256: String

        // Compatibility projections for diagnostics that predate split seals.
        var storeIdentifier: String { raw.storeIdentifier }
        var snapshotSHA256: String { raw.snapshotSHA256 }
        var byteCount: UInt64 { raw.byteCount }
        var fsyncedAtUnix: TimeInterval { max(raw.fsyncedAtUnix, identity.fsyncedAtUnix) }
        var durableSequence: UInt64 { raw.durableSequence }

        var isPromotionAuthority: Bool {
            raw.storeIdentifier != identity.storeIdentifier
                && raw.durableSequence > 0
                && raw.durableSequence == identity.durableSequence
                && raw.batchKeysSHA256 == identity.batchKeysSHA256
                && raw.observedIdentityCount == identity.observedIdentityCount
                && raw.snapshotSHA256.count == 64
                && identity.snapshotSHA256.count == 64
                && receiptChainSHA256.count == 64
                && raw.fsyncedAtUnix.isFinite
                && identity.fsyncedAtUnix.isFinite
        }
    }

    struct TailRepair: Equatable {
        let originalBytes: UInt64
        let repairedBytes: UInt64

        var bytesDiscarded: UInt64 { originalBytes - repairedBytes }
    }

    enum StoreError: Error, LocalizedError, Equatable {
        case invalidJSONObject
        case reservedIdentityProperty
        case batchAlreadyFlushed
        case corruptDurabilityReceiptState
        case missingExistingIdentity
        case durabilitySequenceOverflow
        case receiptBatchCapacityExceeded(maximum: Int)

        var errorDescription: String? {
            switch self {
            case .invalidJSONObject:
                return "Historical archive records must be encoded JSON objects."
            case .reservedIdentityProperty:
                return "Historical archive record contains a reserved identity property."
            case .batchAlreadyFlushed:
                return "Cannot append to a historical drain batch after its durability boundary."
            case .corruptDurabilityReceiptState:
                return "Historical archive durability receipt state failed verification."
            case .missingExistingIdentity:
                return "Historical archive reconciliation referenced an identity that is not present."
            case .durabilitySequenceOverflow:
                return "Historical archive durability sequence exhausted."
            case .receiptBatchCapacityExceeded(let maximum):
                return "Historical archive receipt batch exceeded its bounded identity capacity of \(maximum)."
            }
        }
    }

    private struct FileSealIdentity: Codable, Equatable {
        let path: String
        let volume: UInt64
        let inode: UInt64
        let size: UInt64
        let modificationMilliseconds: Int64
    }

    /// A restart hint for the derived exact-identity index.  It is deliberately
    /// not a durability authority: a missing, stale, or malformed snapshot
    /// simply makes launch rebuild from the raw JSONL archives.  Its only job
    /// is to prove that the index being loaded names the exact same archive
    /// files that were present after the last successful archive/index flush.
    private struct DerivedIndexSnapshot: Codable, Equatable {
        let version: Int
        let archives: [ArchiveFingerprint]
        let indexByteCount: UInt64
        let indexSHA256: String
    }

    private struct ArchiveFingerprint: Codable, Equatable {
        let path: String
        let exists: Bool
        let volume: UInt64
        let inode: UInt64
        let size: UInt64
        let modificationMilliseconds: Int64
    }

    private struct ReceiptCore: Codable, Equatable {
        let batchIdentifier: String
        let raw: DurableSeal
        let identity: DurableSeal
    }

    private struct PersistedReceiptState: Codable, Equatable {
        let version: Int
        let previousChainSHA256: String
        let receipt: ReceiptCore
        let chainSHA256: String
    }

    private struct IndexEntry: Codable, Equatable {
        let version: Int
        let key: String
        let observedAtUnix: TimeInterval
        let archivePath: String
        let lineOffset: UInt64
        let lineLength: Int
        let lineCRC32: UInt32
    }

    private struct KeyState {
        var entry: IndexEntry
        var indexed: Bool
        var durable: Bool
    }

    private let lock = NSLock()
    private let fileManager: FileManager
    private let indexURL: URL
    private let indexSnapshotURL: URL
    private let receiptStateURL: URL
    private let encoder: JSONEncoder
    private let fileSynchronizer: (URL) throws -> Void
    private let receiptFileSynchronizer: (URL) throws -> Void
    private let identityRetention: TimeInterval
    private let maximumReceiptBatchIdentities: Int
    private let now: () -> Date
    private var statesByKey: [String: KeyState] = [:]
    private var registeredArchivePaths = Set<String>()
    private var openBatches: [UUID: DrainBatch] = [:]
    private var lastPruneAtUnix: TimeInterval
    private var durableSequence: UInt64 = 0
    private var receiptChainSHA256 = String(repeating: "0", count: 64)

    init(indexURL: URL,
         existingArchiveURLs: [URL],
         fileManager: FileManager = .default,
         identityRetention: TimeInterval = AtriaHistoricalArchiveDurableStore.productionIdentityRetention,
         now: @escaping () -> Date = Date.init,
         fileSynchronizer: ((URL) throws -> Void)? = nil,
         receiptFileSynchronizer: ((URL) throws -> Void)? = nil,
         maximumReceiptBatchIdentities: Int = AtriaHistoricalArchiveDurableStore.productionMaximumReceiptBatchIdentities) throws {
        precondition(maximumReceiptBatchIdentities > 0)
        self.indexURL = indexURL.standardizedFileURL
        self.indexSnapshotURL = indexURL.deletingPathExtension()
            .appendingPathExtension("snapshot.json")
            .standardizedFileURL
        self.receiptStateURL = indexURL.deletingPathExtension()
            .appendingPathExtension("durability.json")
            .standardizedFileURL
        self.fileManager = fileManager
        self.fileSynchronizer = fileSynchronizer ?? Self.synchronizeFile
        self.receiptFileSynchronizer = receiptFileSynchronizer ?? Self.synchronizeFile
        self.identityRetention = identityRetention
        self.maximumReceiptBatchIdentities = maximumReceiptBatchIdentities
        self.now = now
        self.lastPruneAtUnix = now().timeIntervalSince1970
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        let canonicalArchiveURLs = Array(Set(existingArchiveURLs.map(\.standardizedFileURL)))
            .sorted { $0.path < $1.path }
        for archiveURL in canonicalArchiveURLs {
            let canonical = archiveURL.standardizedFileURL
            registeredArchivePaths.insert(canonical.path)
        }

        let cutoff = now().timeIntervalSince1970 - max(0, identityRetention)
        let discovered: [String: IndexEntry]
        if let cached = try loadValidatedDerivedIndex(archiveURLs: canonicalArchiveURLs,
                                                      cutoff: cutoff) {
            discovered = cached
            AtriaDebugLog("ATRIADBG historical_identity_index status=reused entries=%d archives=%d",
                          discovered.count,
                          canonicalArchiveURLs.count)
        } else {
            var rebuilt: [String: IndexEntry] = [:]
            for archiveURL in canonicalArchiveURLs {
                guard fileManager.fileExists(atPath: archiveURL.path) else { continue }
                _ = try Self.repairTornJSONLTail(at: archiveURL)
                for entry in try Self.scanArchive(at: archiveURL) {
                    if let existing = rebuilt[entry.key],
                       existing.observedAtUnix >= entry.observedAtUnix {
                        continue
                    }
                    rebuilt[entry.key] = entry
                }
            }
            discovered = rebuilt.filter { $0.value.observedAtUnix >= cutoff }
            try rebuildDerivedIndex(with: Array(discovered.values))
            persistDerivedIndexSnapshotBestEffort()
            AtriaDebugLog("ATRIADBG historical_identity_index status=rebuilt entries=%d archives=%d",
                          discovered.count,
                          canonicalArchiveURLs.count)
        }

        // A complete line proves replay identity, not that its archive inode was
        // synchronized before the prior process died. Rebuild and synchronize
        // the derived index now, but keep every recovered archive row
        // durability-unknown. If the strap replays it, that drain batch must
        // synchronize both the archive and index before it can report a durable
        // duplicate eligible for ACK.
        statesByKey = discovered.mapValues { KeyState(entry: $0, indexed: true, durable: false) }
        try loadAndVerifyReceiptState()
    }

    func beginDrainBatch() -> DrainBatch {
        lock.lock()
        defer { lock.unlock() }
        let batch = DrainBatch()
        openBatches[batch.identifier] = batch
        return batch
    }

    /// Adds an already archived exact identity to a later durability boundary
    /// without writing a second raw row. This is used when the archive fsync
    /// succeeded but the admission-ledger promotion was interrupted: the next
    /// receipt must enumerate the complete still-pending admission set before
    /// ACK, not only the latest transport burst.
    func includeExisting(_ identity: FrameIdentity, in batch: DrainBatch) throws {
        lock.lock()
        defer { lock.unlock() }
        guard batch.lastReceipt == nil else { throw StoreError.batchAlreadyFlushed }
        let key = identity.stableKey
        guard batch.keys.contains(key) || batch.keys.count < maximumReceiptBatchIdentities else {
            throw StoreError.receiptBatchCapacityExceeded(maximum: maximumReceiptBatchIdentities)
        }
        guard var state = statesByKey[key] else { throw StoreError.missingExistingIdentity }
        batch.keys.insert(key)
        if !state.indexed {
            try appendIndex(state.entry)
            state.indexed = true
            statesByKey[key] = state
        }
        if !state.durable {
            batch.dirtyURLs.insert(URL(fileURLWithPath: state.entry.archivePath).standardizedFileURL)
            batch.dirtyURLs.insert(indexURL)
        }
    }

    @discardableResult
    func append(identity: FrameIdentity,
                encodedJSONObject: Data,
                to archiveURL: URL,
                batch: DrainBatch) throws -> AppendResult {
        lock.lock()
        defer { lock.unlock() }

        guard batch.lastReceipt == nil else { throw StoreError.batchAlreadyFlushed }
        let key = identity.stableKey
        guard batch.keys.contains(key) || batch.keys.count < maximumReceiptBatchIdentities else {
            throw StoreError.receiptBatchCapacityExceeded(maximum: maximumReceiptBatchIdentities)
        }
        let archiveURL = archiveURL.standardizedFileURL
        try registerArchiveIfNeeded(archiveURL)

        if var existing = statesByKey[key] {
            batch.keys.insert(key)
            if !existing.durable {
                batch.dirtyURLs.insert(URL(fileURLWithPath: existing.entry.archivePath).standardizedFileURL)
                if !existing.indexed {
                    try appendIndex(existing.entry)
                    existing.indexed = true
                    statesByKey[key] = existing
                }
                batch.dirtyURLs.insert(indexURL)
            }
            return .duplicate(durable: existing.durable)
        }

        let observedAtUnix = now().timeIntervalSince1970
        let line = try Self.decoratedLine(from: encodedJSONObject,
                                          key: key,
                                          observedAtUnix: observedAtUnix)
        try fileManager.createDirectory(at: archiveURL.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: archiveURL.path) {
            fileManager.createFile(atPath: archiveURL.path, contents: nil)
        }

        let handle = try FileHandle(forWritingTo: archiveURL)
        let offset: UInt64
        do {
            offset = try handle.seekToEnd()
            try handle.write(contentsOf: line)
            try handle.close()
        } catch {
            try? handle.close()
            _ = try? Self.repairTornJSONLTail(at: archiveURL)
            throw error
        }

        let entry = IndexEntry(version: 2,
                               key: key,
                               observedAtUnix: observedAtUnix,
                               archivePath: archiveURL.path,
                               lineOffset: offset,
                               lineLength: line.count,
                               lineCRC32: Self.checksum(line))
        statesByKey[key] = KeyState(entry: entry, indexed: false, durable: false)
        batch.keys.insert(key)
        batch.dirtyURLs.insert(archiveURL)

        do {
            try appendIndex(entry)
            statesByKey[key]?.indexed = true
            batch.dirtyURLs.insert(indexURL)
        } catch {
            // The archive line is already complete and discoverable. Preserve
            // its pending state so a retry can rebuild and flush the index.
            throw error
        }
        return .inserted
    }

    /// Synchronizes every archive file touched by the batch, then the index.
    /// A successful return is the storage durability boundary required before
    /// sending the strap's history ACK.
    func flush(_ batch: DrainBatch) throws -> FlushReceipt {
        lock.lock()
        defer { lock.unlock() }

        if let receipt = batch.lastReceipt { return receipt }

        guard durableSequence < UInt64.max else {
            throw StoreError.durabilitySequenceOverflow
        }
        let nextSequence = durableSequence + 1
        let keys = batch.keys.sorted()
        let pendingKeys = keys.filter { statesByKey[$0]?.durable == false }

        for key in batch.keys {
            guard var state = statesByKey[key], !state.indexed else { continue }
            try appendIndex(state.entry)
            state.indexed = true
            statesByKey[key] = state
            batch.dirtyURLs.insert(indexURL)
        }

        let dirtyArchiveURLs = batch.dirtyURLs
            .filter { $0.standardizedFileURL != indexURL }
            .sorted { $0.path < $1.path }
        var synchronized: [URL] = []
        for url in dirtyArchiveURLs {
            try fileSynchronizer(url)
            synchronized.append(url)
        }
        if batch.dirtyURLs.contains(indexURL) {
            try fileSynchronizer(indexURL)
            synchronized.append(indexURL)
        }

        // Construct both seals from bounded batch metadata. No historical
        // archive content is reread here: exact keys and line sizes were
        // retained while this transport batch was admitted.
        let synchronizedSet = Set(synchronized.map(\.standardizedFileURL))
        for key in pendingKeys {
            guard let state = statesByKey[key], state.indexed else {
                throw StoreError.corruptDurabilityReceiptState
            }
            let archiveURL = URL(fileURLWithPath: state.entry.archivePath).standardizedFileURL
            guard synchronizedSet.contains(archiveURL), synchronizedSet.contains(indexURL) else {
                throw StoreError.corruptDurabilityReceiptState
            }
        }

        let fsyncedAtUnix = now().timeIntervalSince1970
        let keyDigest = Self.identityBatchDigest(keys)
        let archiveURLs = Set(keys.compactMap { key -> URL? in
            guard let entry = statesByKey[key]?.entry else { return nil }
            return URL(fileURLWithPath: entry.archivePath).standardizedFileURL
        }).sorted { $0.path < $1.path }
        let rawFiles = try archiveURLs.map(fileSealIdentity)
        let identityFiles = keys.isEmpty ? [] : [try fileSealIdentity(indexURL)]
        let rawRecordBytes = pendingKeys.reduce(UInt64(0)) { partial, key in
            partial &+ UInt64(max(0, statesByKey[key]?.entry.lineLength ?? 0))
        }
        let identityRecordBytes = try pendingKeys.reduce(UInt64(0)) { partial, key in
            guard let entry = statesByKey[key]?.entry else { return partial }
            return partial &+ UInt64(try encodedIndexLine(entry).count)
        }
        let raw = makeSeal(
            storeIdentifier: "whoop4-raw-archive-jsonl-v2",
            durableSequence: nextSequence,
            keyDigest: keyDigest,
            recordCount: UInt64(pendingKeys.count),
            byteCount: rawRecordBytes,
            observedIdentityCount: UInt64(keys.count),
            files: rawFiles,
            fsyncedAtUnix: fsyncedAtUnix
        )
        let identity = makeSeal(
            storeIdentifier: "whoop4-exact-identity-index-jsonl-v2",
            durableSequence: nextSequence,
            keyDigest: keyDigest,
            recordCount: UInt64(pendingKeys.count),
            byteCount: identityRecordBytes,
            observedIdentityCount: UInt64(keys.count),
            files: identityFiles,
            fsyncedAtUnix: fsyncedAtUnix
        )
        let core = ReceiptCore(batchIdentifier: batch.identifier.uuidString.lowercased(),
                               raw: raw,
                               identity: identity)
        let chain = try receiptChainDigest(previous: receiptChainSHA256, core: core)
        let persisted = PersistedReceiptState(version: 1,
                                              previousChainSHA256: receiptChainSHA256,
                                              receipt: core,
                                              chainSHA256: chain)
        try persistReceiptState(persisted)

        // Receipt-state fsync is the final boundary. Only after it succeeds may
        // pending identities be advertised as archive durable or ACK-eligible.
        for key in pendingKeys {
            guard var state = statesByKey[key] else { continue }
            state.durable = true
            statesByKey[key] = state
        }
        let receipt = FlushReceipt(
            batchIdentifier: batch.identifier,
            synchronizedFiles: synchronized,
            insertedOrPendingKeys: batch.keys.count,
            raw: raw,
            identity: identity,
            receiptChainSHA256: chain
        )
        durableSequence = nextSequence
        receiptChainSHA256 = chain
        batch.lastReceipt = receipt
        openBatches.removeValue(forKey: batch.identifier)
        // This snapshot is strictly an acceleration cache. Keep its O(total
        // index size) rebuild out of almost every page ACK; the receipt above
        // is already the restart-safe durability authority.
        if Self.shouldRefreshDerivedSnapshot(
            durableSequence: nextSequence,
            interval: Self.productionDerivedSnapshotFlushInterval
        ) {
            persistDerivedIndexSnapshotBestEffort()
        }
        let maintenanceNow = now()
        if maintenanceNow.timeIntervalSince1970 - lastPruneAtUnix >= 6 * 60 * 60 {
            do {
                _ = try pruneExpiredIdentitiesLocked(now: maintenanceNow)
            } catch {
                // Retention maintenance is derived and must never invalidate a
                // raw+index fsync that already made this BLE drain ACK-safe.
                AtriaDebugLog("ATRIADBG historical_identity_prune status=deferred error=%@",
                              error.localizedDescription)
            }
        }
        return receipt
    }

    nonisolated static func shouldRefreshDerivedSnapshot(
        durableSequence: UInt64,
        interval: UInt64
    ) -> Bool {
        interval > 0 && durableSequence > 0 && durableSequence.isMultiple(of: interval)
    }

    func contains(_ identity: FrameIdentity) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return statesByKey[identity.stableKey] != nil
    }

    /// Drops only durable exact identities outside the repair horizon. Pending
    /// writes and identities referenced by an open drain batch are untouchable.
    /// An expired replay is intentionally accepted as new and must cross the
    /// normal archive+index fsync boundary before ACK; this can create a benign
    /// duplicate but can never create a false rejection/data loss.
    @discardableResult
    func pruneExpiredIdentities(now pruningDate: Date) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        return try pruneExpiredIdentitiesLocked(now: pruningDate)
    }

    private func pruneExpiredIdentitiesLocked(now pruningDate: Date) throws -> Int {
        let cutoff = pruningDate.timeIntervalSince1970 - max(0, identityRetention)
        let protectedKeys = openBatches.values.reduce(into: Set<String>()) {
            $0.formUnion($1.keys)
        }
        let expired = statesByKey.compactMap { key, state -> String? in
            guard state.durable,
                  state.entry.observedAtUnix < cutoff,
                  !protectedKeys.contains(key) else { return nil }
            return key
        }
        lastPruneAtUnix = pruningDate.timeIntervalSince1970
        guard !expired.isEmpty else { return 0 }
        var retained = statesByKey
        for key in expired { retained.removeValue(forKey: key) }
        try rebuildDerivedIndex(with: retained.values.map(\.entry))
        statesByKey = retained
        persistDerivedIndexSnapshotBestEffort()
        return expired.count
    }

    /// Removes bytes after the final newline. A complete JSONL line is never
    /// removed, while a power-loss write fragment can never become a new row.
    @discardableResult
    static func repairTornJSONLTail(at url: URL) throws -> TailRepair {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard size > 0 else { return TailRepair(originalBytes: 0, repairedBytes: 0) }

        try handle.seek(toOffset: size - 1)
        if try handle.read(upToCount: 1)?.first == 0x0a {
            return TailRepair(originalBytes: size, repairedBytes: size)
        }

        let chunkSize: UInt64 = 64 * 1024
        var cursor = size
        while cursor > 0 {
            let start = cursor > chunkSize ? cursor - chunkSize : 0
            try handle.seek(toOffset: start)
            let data = try handle.read(upToCount: Int(cursor - start)) ?? Data()
            if let newline = data.lastIndex(of: 0x0a) {
                let repaired = start + UInt64(data.distance(from: data.startIndex, to: newline)) + 1
                try handle.truncate(atOffset: repaired)
                try handle.synchronize()
                return TailRepair(originalBytes: size, repairedBytes: repaired)
            }
            cursor = start
        }

        try handle.truncate(atOffset: 0)
        try handle.synchronize()
        return TailRepair(originalBytes: size, repairedBytes: 0)
    }

    private func registerArchiveIfNeeded(_ archiveURL: URL) throws {
        guard !registeredArchivePaths.contains(archiveURL.path) else { return }
        registeredArchivePaths.insert(archiveURL.path)
        guard fileManager.fileExists(atPath: archiveURL.path) else { return }
        _ = try Self.repairTornJSONLTail(at: archiveURL)
        let cutoff = now().timeIntervalSince1970 - max(0, identityRetention)
        for entry in try Self.scanArchive(at: archiveURL)
            where entry.observedAtUnix >= cutoff && statesByKey[entry.key] == nil {
            // The row is complete, but this late-discovered rotated file was
            // not part of the startup index rebuild. Require one durability
            // boundary that adds its identity to the index before ACK.
            statesByKey[entry.key] = KeyState(entry: entry, indexed: false, durable: false)
        }
    }

    /// Returns a restart-safe index only after proving three independent facts:
    /// (1) the registered archive set did not change, (2) the index file is
    /// exactly the snapshot that was written after a successful flush, and
    /// (3) every index offset still points at its CRC-checked decorated raw
    /// row.  Any failed proof returns `nil`, intentionally taking the existing
    /// raw-archive rebuild path rather than risking a false replay duplicate.
    private func loadValidatedDerivedIndex(archiveURLs: [URL],
                                           cutoff: TimeInterval) throws -> [String: IndexEntry]? {
        let currentArchives = try archiveURLs.map { try archiveFingerprint($0) }
            .sorted { $0.path < $1.path }
        guard fileManager.fileExists(atPath: indexURL.path),
              fileManager.fileExists(atPath: indexSnapshotURL.path),
              let snapshot = try? JSONDecoder().decode(DerivedIndexSnapshot.self,
                                                       from: Data(contentsOf: indexSnapshotURL)),
              snapshot.version == 1,
              snapshot.indexSHA256.count == 64,
              snapshot.archives == currentArchives
        else {
            return nil
        }

        let decoded = try decodedIndexEntriesAndDigest()
        guard decoded.byteCount == snapshot.indexByteCount,
              decoded.sha256 == snapshot.indexSHA256 else {
            return nil
        }

        var entries: [String: IndexEntry] = [:]
        for entry in decoded.entries {
            // The index is derived, so duplicates, out-of-horizon entries and
            // paths outside the registered raw set all invalidate the shortcut.
            // They are rebuilt from raw rather than silently selecting a row.
            guard entry.version == 2,
                  entry.observedAtUnix.isFinite,
                  entry.observedAtUnix >= cutoff,
                  registeredArchivePaths.contains(entry.archivePath),
                  entries[entry.key] == nil,
                  try indexEntryMatchesRawArchive(entry) else {
                return nil
            }
            entries[entry.key] = entry
        }
        return entries
    }

    private func decodedIndexEntriesAndDigest() throws -> (entries: [IndexEntry], byteCount: UInt64, sha256: String) {
        let handle = try FileHandle(forReadingFrom: indexURL)
        defer { try? handle.close() }
        let decoder = JSONDecoder()
        var hasher = SHA256()
        var entries: [IndexEntry] = []
        var buffer = Data()
        var unreadStart = 0
        var byteCount: UInt64 = 0
        let compactionThreshold = 64 * 1024

        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
            byteCount &+= UInt64(chunk.count)
            buffer.append(chunk)
            while unreadStart < buffer.count {
                let lineStart = buffer.index(buffer.startIndex, offsetBy: unreadStart)
                guard let newline = buffer[lineStart...].firstIndex(of: 0x0a) else { break }
                let line = Data(buffer[lineStart...newline])
                guard let entry = try? decoder.decode(IndexEntry.self, from: line) else {
                    return ([], 0, "")
                }
                entries.append(entry)
                unreadStart += line.count
            }
            if unreadStart >= compactionThreshold {
                buffer.removeFirst(unreadStart)
                unreadStart = 0
            }
        }
        // A JSONL index without a terminating newline is never a valid cache.
        guard unreadStart == buffer.count else { return ([], 0, "") }
        return (entries, byteCount, Self.hex(hasher.finalize()))
    }

    private func indexEntryMatchesRawArchive(_ entry: IndexEntry) throws -> Bool {
        guard entry.lineLength > 0 else { return false }
        let url = URL(fileURLWithPath: entry.archivePath).standardizedFileURL
        guard fileManager.fileExists(atPath: url.path) else { return false }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: entry.lineOffset)
        guard let line = try handle.read(upToCount: entry.lineLength),
              line.count == entry.lineLength,
              Self.checksum(line) == entry.lineCRC32,
              let identity = Self.decoratedIdentity(from: line),
              identity.key == entry.key,
              identity.observedAtUnix == entry.observedAtUnix else {
            return false
        }
        return true
    }

    private func archiveFingerprint(_ url: URL) throws -> ArchiveFingerprint {
        let canonical = url.standardizedFileURL
        guard fileManager.fileExists(atPath: canonical.path) else {
            return ArchiveFingerprint(path: canonical.path,
                                      exists: false,
                                      volume: 0,
                                      inode: 0,
                                      size: 0,
                                      modificationMilliseconds: 0)
        }
        let attributes = try fileManager.attributesOfItem(atPath: canonical.path)
        let volume = (attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return ArchiveFingerprint(path: canonical.path,
                                  exists: true,
                                  volume: volume,
                                  inode: inode,
                                  size: size,
                                  modificationMilliseconds: Int64((modified * 1_000).rounded(.towardZero)))
    }

    private func persistDerivedIndexSnapshotBestEffort() {
        do {
            let archiveURLs = registeredArchivePaths.map { URL(fileURLWithPath: $0) }
                .sorted { $0.path < $1.path }
            let index = try decodedIndexEntriesAndDigest()
            guard index.byteCount > 0 || statesByKey.isEmpty else { return }
            let snapshot = DerivedIndexSnapshot(
                version: 1,
                archives: try archiveURLs.map(archiveFingerprint),
                indexByteCount: index.byteCount,
                indexSHA256: index.sha256
            )
            try fileManager.createDirectory(at: indexSnapshotURL.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            let temporaryURL = indexSnapshotURL.deletingLastPathComponent()
                .appendingPathComponent(".\(indexSnapshotURL.lastPathComponent).\(UUID().uuidString).tmp")
            do {
                try encoder.encode(snapshot).write(to: temporaryURL, options: [])
                try Self.synchronizeFile(at: temporaryURL)
                if fileManager.fileExists(atPath: indexSnapshotURL.path) {
                    _ = try fileManager.replaceItemAt(indexSnapshotURL, withItemAt: temporaryURL)
                } else {
                    try fileManager.moveItem(at: temporaryURL, to: indexSnapshotURL)
                }
                try Self.synchronizeDirectory(indexSnapshotURL.deletingLastPathComponent())
            } catch {
                try? fileManager.removeItem(at: temporaryURL)
                throw error
            }
        } catch {
            AtriaDebugLog("ATRIADBG historical_identity_index status=snapshot_deferred error=%@",
                          error.localizedDescription)
        }
    }

    private func fileSealIdentity(_ url: URL) throws -> FileSealIdentity {
        let canonical = url.standardizedFileURL
        let attributes = try fileManager.attributesOfItem(atPath: canonical.path)
        let volume = (attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return FileSealIdentity(
            path: canonical.path,
            volume: volume,
            inode: inode,
            size: size,
            modificationMilliseconds: Int64((modified * 1_000).rounded(.towardZero))
        )
    }

    private func makeSeal(storeIdentifier: String,
                          durableSequence: UInt64,
                          keyDigest: String,
                          recordCount: UInt64,
                          byteCount: UInt64,
                          observedIdentityCount: UInt64,
                          files: [FileSealIdentity],
                          fsyncedAtUnix: TimeInterval) -> DurableSeal {
        var hasher = SHA256()
        Self.hashString(storeIdentifier, into: &hasher)
        Self.hashUInt64(durableSequence, into: &hasher)
        Self.hashString(keyDigest, into: &hasher)
        Self.hashUInt64(recordCount, into: &hasher)
        Self.hashUInt64(byteCount, into: &hasher)
        Self.hashUInt64(observedIdentityCount, into: &hasher)
        for file in files.sorted(by: { $0.path < $1.path }) {
            Self.hashString(file.path, into: &hasher)
            Self.hashUInt64(file.volume, into: &hasher)
            Self.hashUInt64(file.inode, into: &hasher)
            Self.hashUInt64(file.size, into: &hasher)
            Self.hashUInt64(UInt64(bitPattern: file.modificationMilliseconds), into: &hasher)
        }
        return DurableSeal(
            storeIdentifier: storeIdentifier,
            durableSequence: durableSequence,
            snapshotSHA256: Self.hex(hasher.finalize()),
            batchKeysSHA256: keyDigest,
            byteCount: byteCount,
            recordCount: recordCount,
            observedIdentityCount: observedIdentityCount,
            fsyncedAtUnix: fsyncedAtUnix
        )
    }

    private func receiptChainDigest(previous: String, core: ReceiptCore) throws -> String {
        var hasher = SHA256()
        Self.hashString("whoop4-archive-durability-chain-v1", into: &hasher)
        Self.hashString(previous, into: &hasher)
        hasher.update(data: try encoder.encode(core))
        return Self.hex(hasher.finalize())
    }

    private func persistReceiptState(_ state: PersistedReceiptState) throws {
        try fileManager.createDirectory(at: receiptStateURL.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        let temporaryURL = receiptStateURL.deletingLastPathComponent()
            .appendingPathComponent(".\(receiptStateURL.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try encoder.encode(state).write(to: temporaryURL, options: [])
            try receiptFileSynchronizer(temporaryURL)
            if fileManager.fileExists(atPath: receiptStateURL.path) {
                _ = try fileManager.replaceItemAt(receiptStateURL, withItemAt: temporaryURL)
            } else {
                try fileManager.moveItem(at: temporaryURL, to: receiptStateURL)
            }
            try Self.synchronizeDirectory(receiptStateURL.deletingLastPathComponent())
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }

    private func loadAndVerifyReceiptState() throws {
        guard fileManager.fileExists(atPath: receiptStateURL.path) else { return }
        let decoder = JSONDecoder()
        guard let state = try? decoder.decode(PersistedReceiptState.self,
                                              from: Data(contentsOf: receiptStateURL)),
              state.version == 1,
              state.receipt.raw.durableSequence == state.receipt.identity.durableSequence,
              state.receipt.raw.durableSequence > 0,
              state.receipt.raw.storeIdentifier != state.receipt.identity.storeIdentifier,
              state.receipt.raw.batchKeysSHA256 == state.receipt.identity.batchKeysSHA256,
              state.receipt.raw.snapshotSHA256.count == 64,
              state.receipt.identity.snapshotSHA256.count == 64,
              state.previousChainSHA256.count == 64,
              state.chainSHA256 == (try? receiptChainDigest(
                previous: state.previousChainSHA256,
                core: state.receipt
              )) else {
            throw StoreError.corruptDurabilityReceiptState
        }
        durableSequence = state.receipt.raw.durableSequence
        receiptChainSHA256 = state.chainSHA256
    }

    private func encodedIndexLine(_ entry: IndexEntry) throws -> Data {
        var line = try encoder.encode(entry)
        line.append(0x0a)
        return line
    }

    /// Canonical digest used by a durability receipt for every exact identity
    /// observed at a boundary, including replay-only identities. Admission
    /// uses the same function to reconcile a prefix after a crash between the
    /// archive fsync and its SQLite promotion transaction.
    static func identityBatchDigest(_ strings: [String]) -> String {
        var hasher = SHA256()
        for string in strings.sorted() {
            hashString(string, into: &hasher)
        }
        return hex(hasher.finalize())
    }

    private static func hashString(_ string: String, into hasher: inout SHA256) {
        let data = Data(string.utf8)
        hashUInt64(UInt64(data.count), into: &hasher)
        hasher.update(data: data)
    }

    private static func hashUInt64(_ value: UInt64, into hasher: inout SHA256) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { hasher.update(data: Data($0)) }
    }

    private static func hex<D: Digest>(_ digest: D) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private func appendIndex(_ entry: IndexEntry) throws {
        try fileManager.createDirectory(at: indexURL.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: indexURL.path) {
            fileManager.createFile(atPath: indexURL.path, contents: nil)
        }
        let line = try encodedIndexLine(entry)
        let handle = try FileHandle(forWritingTo: indexURL)
        do {
            _ = try handle.seekToEnd()
            try handle.write(contentsOf: line)
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
    }

    private func rebuildDerivedIndex(with entries: [IndexEntry]) throws {
        try fileManager.createDirectory(at: indexURL.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        let temporaryURL = indexURL.deletingLastPathComponent()
            .appendingPathComponent(".\(indexURL.lastPathComponent).\(UUID().uuidString).tmp")
        guard fileManager.createFile(atPath: temporaryURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: temporaryURL)
        var writeError: Error?
        for entry in entries.sorted(by: { $0.key < $1.key }) {
            do {
                var line = try encoder.encode(entry)
                line.append(0x0a)
                try handle.write(contentsOf: line)
            } catch {
                writeError = error
                break
            }
        }
        do {
            if let writeError { throw writeError }
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
        if fileManager.fileExists(atPath: indexURL.path) {
            _ = try fileManager.replaceItemAt(indexURL, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: indexURL)
        }
        try Self.synchronizeDirectory(indexURL.deletingLastPathComponent())
    }

    private static func decoratedLine(from encodedJSONObject: Data,
                                      key: String,
                                      observedAtUnix: TimeInterval) throws -> Data {
        guard let object = try? JSONSerialization.jsonObject(with: encodedJSONObject),
              let dictionary = object as? [String: Any] else {
            throw StoreError.invalidJSONObject
        }
        guard dictionary[identityProperty] == nil,
              dictionary[identitySchemaProperty] == nil,
              dictionary[identityObservedAtProperty] == nil else {
            throw StoreError.reservedIdentityProperty
        }

        guard let openingBrace = encodedJSONObject.firstIndex(where: { byte in
            byte != 0x20 && byte != 0x09 && byte != 0x0a && byte != 0x0d
        }), encodedJSONObject[openingBrace] == 0x7b else {
            throw StoreError.invalidJSONObject
        }
        let suffixStart = encodedJSONObject.index(after: openingBrace)
        let suffix = encodedJSONObject[suffixStart...]
        let emptyObject = dictionary.isEmpty
        let prefix = "{\"\(identityProperty)\":\"\(key)\",\"\(identitySchemaProperty)\":2,\"\(identityObservedAtProperty)\":\(observedAtUnix)"
            + (emptyObject ? "" : ",")
        var line = Data(prefix.utf8)
        line.append(contentsOf: suffix)
        if line.last != 0x0a { line.append(0x0a) }
        return line
    }

    private static func scanArchive(at url: URL) throws -> [IndexEntry] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var buffer = Data()
        var bufferOffset: UInt64 = 0
        // Keep the file offset separate from the unread position. Removing
        // each JSONL row from the front of `Data` shifts every remaining byte,
        // turning a large cold rebuild into quadratic work. The archive can be
        // hundreds of megabytes, so consume by index and compact only after a
        // chunk-sized prefix has been processed.
        var unreadStart = 0
        let compactionThreshold = 64 * 1024
        var entries: [IndexEntry] = []

        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            buffer.append(chunk)
            while unreadStart < buffer.count {
                let lineStart = buffer.index(buffer.startIndex, offsetBy: unreadStart)
                guard let newline = buffer[lineStart...].firstIndex(of: 0x0a) else { break }
                let lineLength = buffer.distance(from: lineStart, to: newline) + 1
                let line = Data(buffer[lineStart...newline])
                // Durable rows are written with a canonical identity prefix.
                // Parse that prefix directly instead of JSON-decoding every
                // legacy archive row. A physical archive can contain hundreds
                // of thousands of pre-index rows; decoding all of them delayed
                // the first persistence callback for minutes and therefore
                // correctly (but indefinitely) withheld HISTORY_END ACK.
                if let identity = decoratedIdentity(from: line) {
                    entries.append(IndexEntry(version: 2,
                                              key: identity.key,
                                              observedAtUnix: identity.observedAtUnix,
                                              archivePath: url.standardizedFileURL.path,
                                              lineOffset: bufferOffset + UInt64(unreadStart),
                                              lineLength: lineLength,
                                              lineCRC32: checksum(line)))
                }
                unreadStart += lineLength
            }

            // Preserve a possible partial final row but release already-read
            // storage in bounded batches. `bufferOffset` is advanced only when
            // those bytes are physically discarded, keeping index offsets
            // identical to the previous implementation.
            if unreadStart >= compactionThreshold {
                buffer.removeFirst(unreadStart)
                bufferOffset += UInt64(unreadStart)
                unreadStart = 0
            }
        }
        return entries
    }

    struct DecoratedIdentity: Equatable, Sendable {
        let key: String
        let observedAtUnix: TimeInterval
    }

    /// Exact schema-v2 identity embedded in every newly durable archive row.
    /// Internal so the retired-identity shard can preserve replay truth before
    /// a sealed raw chunk is ever eligible for deletion.
    static func decoratedIdentity(from line: Data) -> DecoratedIdentity? {
        let prefix = Data("{\"\(identityProperty)\":\"".utf8)
        guard line.starts(with: prefix) else { return nil }
        let keyStart = prefix.count
        guard let keyEnd = line[keyStart...].firstIndex(of: 0x22),
              keyEnd > keyStart else { return nil }
        let keyBytes = line[keyStart..<keyEnd]
        // Stable keys are lowercase hexadecimal. Rejecting any other bytes
        // keeps an arbitrary legacy JSON string from entering the ACK index.
        guard keyBytes.count >= 2,
              keyBytes.count.isMultiple(of: 2),
              keyBytes.starts(with: Data("02".utf8)),
              keyBytes.allSatisfy({
            ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66)
        }), let key = String(data: keyBytes, encoding: .utf8) else { return nil }

        let schemaStart = line.index(after: keyEnd)
        let schema2Prefix = Data(",\"\(identitySchemaProperty)\":2".utf8)
        guard line[schemaStart...].starts(with: schema2Prefix) else {
            // v1 used a CRC32 identity. It cannot safely reject a schema-v2
            // exact replay, so it is intentionally excluded from the new index.
            return nil
        }
        let observedKey = Data("\"\(identityObservedAtProperty)\":".utf8)
        guard let range = line.range(of: observedKey) else { return nil }
        let cursor = range.upperBound
        var end = cursor
        while end < line.endIndex {
            let byte = line[end]
            guard (byte >= 0x30 && byte <= 0x39) || byte == 0x2e || byte == 0x2d else { break }
            end = line.index(after: end)
        }
        guard end > cursor,
              let value = String(data: line[cursor..<end], encoding: .utf8),
              let observedAtUnix = TimeInterval(value),
              observedAtUnix.isFinite else { return nil }
        return DecoratedIdentity(key: key, observedAtUnix: observedAtUnix)
    }

    private static func synchronizeFile(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    private static func synchronizeDirectory(_ url: URL) throws {
        let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY) }
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func checksum(_ data: Data) -> UInt32 {
        var value: UInt32 = 0xffff_ffff
        for byte in data {
            value ^= UInt32(byte)
            for _ in 0..<8 {
                let mask = UInt32(bitPattern: -Int32(value & 1))
                value = (value >> 1) ^ (0xedb8_8320 & mask)
            }
        }
        return value ^ 0xffff_ffff
    }
}
