import CryptoKit
import Foundation

/// Compact, bounded derivative of durably archived WHOOP 4 v24 frames.
///
/// The canonical JSONL archive remains the source of truth. This store exists
/// so a completed hourly motion-bank offload can be verified and projected
/// while iOS keeps the app in the background, without rereading the lifetime
/// archive. Every point is produced by the canonical decoder after the raw
/// frame was admitted and persisted. Duplicate raw payloads are idempotent.
final class AtriaWhoop4MotionTickCompactStore: @unchecked Sendable {
    static let shared = AtriaWhoop4MotionTickCompactStore()
    static let didSynchronizeNotification = Notification.Name(
        "AtriaWhoop4MotionTickCompactStore.didSynchronize"
    )

    struct Point: Hashable, Sendable {
        let timestamp: TimeInterval
        let flash: UInt32
        let tick: Int
        let gravityX: Double
        let gravityY: Double
        let gravityZ: Double
        let unknownMotionScalar32: Double?
        let identity: String
    }

    /// A decoded point retains the fixed-width record boundary that produced
    /// it. That offset is what lets a caller which captured an older prefix
    /// safely reuse a newer cached prefix without observing append-only rows
    /// that did not exist in its own snapshot.
    private struct DecodedPrefixPoint: Sendable {
        let recordEndOffset: Int
        let point: Point
    }

    /// Prefixes share a lineage only while they name the same physical file
    /// and the same store-owned structural generation. Append-only growth keeps
    /// this identity; repair, replacement, creation and retention do not.
    private struct DecodedPrefixLineage: Hashable, Sendable {
        let path: String
        let systemNumber: UInt64
        let fileNumber: UInt64
        let structuralGeneration: UInt64
        let cacheEpoch: UInt64
    }

    private struct CapturedDecodedPrefix {
        let size: Int
        let readHandle: FileHandle
        let lineage: DecodedPrefixLineage
    }

    private struct DecodedPrefixCacheEntry: Sendable {
        let capturedByteCount: Int
        let points: [DecodedPrefixPoint]
        var lastAccess: UInt64
    }

    /// Internal result for the day-evidence sweep. `inspectedPoints` counts
    /// source-array cursor advances and boundary comparisons, not downstream
    /// cadence-model work. It exists so focused DEBUG tests can prove that
    /// adding coverage intervals never restores the former intervals x points
    /// scan.
    private struct MotionTickDayEvidenceProjection {
        let read: HistoricalArchive.MotionTickDayEvidenceRead
        let inspectedPoints: Int
    }

    private struct DecodedPrefixCacheBudget: Equatable, Sendable {
        let maximumEntries: Int
        let maximumSourceBytes: Int
        let maximumPoints: Int

        /// Two daily shards cover the overlapping current-cycle/global-ticket
        /// readers seen on device while keeping decoded String/Point storage
        /// explicitly bounded. Reads beyond the cache budget still complete;
        /// they simply do not become resident.
        static let production = DecodedPrefixCacheBudget(
            maximumEntries: 2,
            maximumSourceBytes: 12 * 1_024 * 1_024,
            maximumPoints: 200_000
        )
    }

#if DEBUG
    struct DecodedPrefixCacheStatistics: Equatable, Sendable {
        let entryCount: Int
        let sourceBytes: Int
        let pointCount: Int
        let activeDecoderCount: Int
        let decodePassCount: UInt64
        let waitCount: UInt64
        let epoch: UInt64
    }
#endif

    struct MigrationPoint: Sendable {
        let timestamp: TimeInterval
        let flash: UInt32
        let tick: Int
        let gravityX: Double
        let gravityY: Double
        let gravityZ: Double
        let unknownMotionScalar32: Double?
        let rawPayload: [UInt8]
    }

    /// Fixed ceilings for the only motion read admitted by foreground sleep
    /// settlement while the device is thermally serious. Callers may tighten
    /// these values (tests do), but `latestNightMotionRead` never lets them
    /// widen the production envelope.
    struct LatestNightReadBudget: Equatable, Sendable {
        let maximumShardCount: Int
        let maximumMappedBytes: Int
        let maximumRows: Int
        let deadlineSeconds: TimeInterval

        static let production = LatestNightReadBudget(
            maximumShardCount: 2,
            maximumMappedBytes: 10 * 1_024 * 1_024,
            maximumRows: 200_000,
            deadlineSeconds: 2
        )
    }

    enum LatestNightReadFailure: String, Equatable, Sendable, Error {
        case invalidRequest = "invalid_request"
        case thermalCritical = "thermal_critical"
        case shardCapExceeded = "shard_cap_exceeded"
        case missingShard = "missing_shard"
        case byteCapExceeded = "byte_cap_exceeded"
        case rowCapExceeded = "row_cap_exceeded"
        case integrityFailure = "integrity_failure"
        case deadlineExceeded = "deadline_exceeded"
        case sourceChanged = "source_changed"
    }

    struct LatestNightSourceReceipt: Equatable, Sendable {
        struct Shard: Equatable, Sendable {
            let filename: String
            let bucket: Int64
            let systemNumber: UInt64
            let fileNumber: UInt64
            let capturedByteCount: Int
        }

        let storeIdentity: UUID
        let sourceStrapIdentifier: UUID
        let sourceFingerprint: String
        let mutationGeneration: UInt64
        let structuralGeneration: UInt64
        let start: Date
        let end: Date
        let shardCount: Int
        let mappedBytes: Int
        let rowCount: Int
        let matchedRowCount: Int
        let shards: [Shard]
    }

    struct LatestNightMotionEvidence: Equatable, Sendable {
        let epochs: [AtriaRecoveredMotionEpoch]
        let receipt: LatestNightSourceReceipt
    }

    /// Single-use authority for one exact, atomically captured shard-prefix
    /// vector. Later append-only rows are ordered after that snapshot and do
    /// not invalidate it; destructive prefix-lineage changes always do.
    struct LatestNightCommitAuthority: Equatable, Sendable {
        fileprivate let id: UUID
        fileprivate let storeIdentity: UUID
        fileprivate let structuralGeneration: UInt64
        let sourceStrapIdentifier: UUID
    }

    enum LatestNightMotionRead: Equatable, Sendable {
        case qualified(LatestNightMotionEvidence)
        case incomplete(LatestNightReadFailure)
    }

    private static let schema: UInt32 = 1
    private static let recordMagic: UInt32 = 0x3154_4D41 // "AMT1"
    private static let recordSize = 52
    private static let retainedBucketCount: Int64 = 4
    private static let secondsPerBucket: TimeInterval = 86_400
    private static let maximumLatestNightRowsPerEpoch = 4_096
    private static let lowercaseHexAlphabet =
        Array("0123456789abcdef".utf8)

    private let directoryURL: URL
    private let fileManager: FileManager
    private let storeIdentity = UUID()
    private let lock = NSLock()
    private var handles: [String: FileHandle] = [:]
    private var knownIdentities: Set<Data>?
    private var mutationGeneration: UInt64 = 0
    /// Append-only growth is intentionally excluded. This generation changes
    /// only when prefix lineage can be revoked (repair, replacement/creation,
    /// or retention), invalidating every live prefix authority.
    private var structuralGeneration: UInt64 = 0
    private var publishedGeneration: UInt64 = 0
    private var commitAuthorities: [UUID: LatestNightCommitAuthority] = [:]
    /// Projection readers use a separate condition from the append/fsync lock.
    /// No filesystem read, decode, or condition wait may hold `lock`.
    private let decodedPrefixCondition = NSCondition()
    private var decodedPrefixCache:
        [DecodedPrefixLineage: DecodedPrefixCacheEntry] = [:]
    private var decodedPrefixDecoders = Set<DecodedPrefixLineage>()
    private var decodedPrefixAccessCounter: UInt64 = 0
    private var decodedPrefixCacheEpoch: UInt64 = 0
    private var decodedPrefixCacheBudget = DecodedPrefixCacheBudget.production
#if DEBUG
    private var latestNightShardCaptureHookForTesting:
        (@Sendable (Int64) -> Void)?
    private var tailRepairWillSynchronizeHookForTesting:
        (@Sendable () throws -> Void)?
    private var appendWriteHookForTesting:
        (@Sendable (FileHandle, Data) throws -> Void)?
    private var mintDidValidateReceiptHookForTesting:
        (@Sendable () -> Void)?
    private var decodedPrefixDecodeHookForTesting:
        (@Sendable (String, Int, Int) -> Void)?
    private var decodedPrefixDecodePassCountForTesting: UInt64 = 0
    private var decodedPrefixWaitCountForTesting: UInt64 = 0
#endif
    /// Retention changes only when an appended point crosses a UTC-day shard.
    /// Enumerating the directory for every 52-byte historical point turned a
    /// long drain into thousands of redundant Foundation filesystem calls.
    private var preparedRetentionBucket: Int64?

    init(directoryURL: URL, fileManager: FileManager = .default) {
        self.directoryURL = directoryURL.standardizedFileURL
        self.fileManager = fileManager
    }

    convenience init(fileManager: FileManager = .default) {
        let support = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        self.init(
            directoryURL: support.appendingPathComponent(
                "Atria/whoop4-motion-compact-v1",
                isDirectory: true
            ),
            fileManager: fileManager
        )
    }

    deinit {
        lock.lock()
        let openHandles = Array(handles.values)
        handles.removeAll()
        lock.unlock()
        for handle in openHandles {
            try? handle.close()
        }
    }

    /// Appends only canonical, clock-corrected v24 motion. Returns `true` when
    /// a new compact point was written and `false` for an ineligible/duplicate
    /// frame. A compact-cache failure never changes canonical archive success.
    @discardableResult
    func append(
        record: HistoricalArchive.Record,
        rawPayload: [UInt8],
        strapIdentifier: String
    ) throws -> Bool {
        guard record.sequence
                == Int(AtriaWhoop4HistoricalLayout.v24.rawValue),
              record.clockCorrectionStatus == "clock_ref_present",
              record.gravityValidated,
              let correctedUnix = record.clockCorrectedUnix7,
              record.subsec11 < 32_768,
              let tick = record.motionTickCounter88,
              let gravityX = record.gravityX36,
              let gravityY = record.gravityY40,
              let gravityZ = record.gravityZ44,
              (0...65_535).contains(tick),
              !strapIdentifier.isEmpty,
              UUID(uuidString: strapIdentifier) != nil else {
            return false
        }
        let timestamp = TimeInterval(correctedUnix)
            + TimeInterval(record.subsec11) / 32_768
        guard timestamp.isFinite,
              timestamp > 0,
              gravityX.isFinite,
              gravityY.isFinite,
              gravityZ.isFinite else {
            return false
        }
        let digest = Self.identityDigest(
            rawPayload: rawPayload,
            strapIdentifier: strapIdentifier
        )
        let bucket = Self.bucket(for: timestamp)
        let filename = Self.filename(
            strapIdentifier: strapIdentifier,
            bucket: bucket
        )

        lock.lock()
        defer { lock.unlock() }
        try prepareDirectoryLocked(currentBucket: bucket)
        try loadKnownIdentitiesLocked()
        guard knownIdentities?.insert(digest).inserted == true else {
            return false
        }
        do {
            let handle = try handleLocked(filename: filename)
            try writeRecordLocked(Self.encode(
                timestamp: timestamp,
                flash: record.flash13,
                tick: tick,
                gravityX: gravityX,
                gravityY: gravityY,
                gravityZ: gravityZ,
                scalar: record.unknownMotionScalar32,
                identityDigest: digest
            ), to: handle)
            mutationGeneration &+= 1
            return true
        } catch {
            knownIdentities?.remove(digest)
            // FileHandle may have written a partial record before reporting
            // failure. Never let the poisoned descriptor bypass the torn-tail
            // repair performed when the exact shard is opened again.
            retirePoisonedHandleLocked(filename: filename)
            invalidatePrefixAuthoritiesLocked()
            throw error
        }
    }

    /// One-time foreground migration for canonical rows retained before this
    /// compact derivative existed. The caller has already read and validated
    /// canonical JSONL; this performs no second archive scan and preserves the
    /// same strap+payload idempotency identity as live ingestion.
    @discardableResult
    func appendMigrated(
        _ points: [MigrationPoint],
        strapIdentifier: String
    ) throws -> Int {
        precondition(!Thread.isMainThread)
        guard !points.isEmpty,
              UUID(uuidString: strapIdentifier) != nil else {
            return 0
        }
        let eligible = points.filter {
            $0.timestamp.isFinite
                && $0.timestamp > 0
                && (0...65_535).contains($0.tick)
                && $0.gravityX.isFinite
                && $0.gravityY.isFinite
                && $0.gravityZ.isFinite
                && !$0.rawPayload.isEmpty
        }.sorted { $0.timestamp < $1.timestamp }
        guard !eligible.isEmpty else { return 0 }

        var appended = 0
        // A large historical migration must not monopolize the same lock used
        // to capture an atomic latest-night prefix. Chunking preserves append
        // order while giving the bounded reader an acquisition point.
        for chunkStart in stride(from: 0, to: eligible.count, by: 256) {
            let chunkEnd = min(eligible.count, chunkStart + 256)
            lock.lock()
            do {
                try prepareDirectoryLocked(
                    currentBucket: Self.bucket(
                        for: eligible.last!.timestamp
                    )
                )
                try loadKnownIdentitiesLocked()
                for point in eligible[chunkStart..<chunkEnd] {
                    let digest = Self.identityDigest(
                        rawPayload: point.rawPayload,
                        strapIdentifier: strapIdentifier
                    )
                    guard knownIdentities?.insert(digest).inserted == true else {
                        continue
                    }
                    let filename = Self.filename(
                        strapIdentifier: strapIdentifier,
                        bucket: Self.bucket(for: point.timestamp)
                    )
                    do {
                        let handle = try handleLocked(filename: filename)
                        try writeRecordLocked(Self.encode(
                            timestamp: point.timestamp,
                            flash: point.flash,
                            tick: point.tick,
                            gravityX: point.gravityX,
                            gravityY: point.gravityY,
                            gravityZ: point.gravityZ,
                            scalar: point.unknownMotionScalar32,
                            identityDigest: digest
                        ), to: handle)
                        appended += 1
                        mutationGeneration &+= 1
                    } catch {
                        knownIdentities?.remove(digest)
                        retirePoisonedHandleLocked(filename: filename)
                        invalidatePrefixAuthoritiesLocked()
                        throw error
                    }
                }
                lock.unlock()
            } catch {
                lock.unlock()
                throw error
            }
        }
        return appended
    }

    /// Flushes the derived shard at the same archive-queue boundary as the
    /// canonical raw store. One main-thread notification follows each newly
    /// durable generation so the current-cycle lower bound can advance even
    /// when no individual recovery ticket has reached 90% yet. Failure leaves
    /// the offload ticket unresolved and publishes nothing.
    func synchronize() throws {
        lock.lock()
        let shouldPublish: Bool
        do {
            // FileHandle does not promise that `write` and `synchronize` are
            // safe concurrently on one instance. Keep every shared-handle
            // operation under the same lock used by append/retention.
            for handle in handles.values {
                try handle.synchronize()
            }
            shouldPublish = mutationGeneration > publishedGeneration
            if shouldPublish {
                publishedGeneration = mutationGeneration
            }
            lock.unlock()
        } catch {
            lock.unlock()
            throw error
        }
        if shouldPublish {
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: Self.didSynchronizeNotification,
                    object: nil
                )
            }
        }
    }

    /// Stable revision for the compact shards intersecting one projection
    /// window. Receipt attempt de-duplication must include this derivative
    /// source: canonical JSONL can remain unchanged while a background history
    /// drain appends newly decoded v24 rows to the compact store.
    func sourceFingerprint(
        start: Date,
        end: Date,
        strapIdentifier: String
    ) -> String? {
        precondition(!Thread.isMainThread)
        guard end > start,
              !strapIdentifier.isEmpty,
              UUID(uuidString: strapIdentifier) != nil else {
            return nil
        }
        let firstBucket = Self.bucket(for: start.timeIntervalSince1970)
        let lastBucket = Self.bucket(
            for: end.timeIntervalSince1970
        )
        lock.lock()
        defer { lock.unlock() }
        let revisions = (firstBucket...lastBucket).map { bucket in
            let filename = Self.filename(
                strapIdentifier: strapIdentifier,
                bucket: bucket
            )
            let url = directoryURL.appendingPathComponent(filename)
            let attributes = try? fileManager.attributesOfItem(
                atPath: url.path
            )
            let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
            return "\(bucket):\(size)"
        }
        let material = [
            String(Self.schema),
            strapIdentifier.uppercased(),
            revisions.joined(separator: ","),
        ].joined(separator: "|")
        return SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Cheap stat-only probe: does the store hold enough rows in this window
    /// to be worth reading?
    ///
    /// Callers used to short-circuit when the motion-bank coverage ledger was
    /// empty (`detail=no_bank_coverage`). That ledger is a 512-entry FIFO, so
    /// on 2026-08-25 it had already forgotten 08-22 and 08-23 entirely and
    /// those days scored zero steps despite holding 88,973 and 53,246 decoded
    /// rows. With row-derived coverage, "the ledger forgot" no longer means
    /// "there is no evidence" — so ask the files instead. No decode, no
    /// buffer: one `stat` per day bucket.
    func hasStoredRows(
        start: Date,
        end: Date,
        strapIdentifier: String,
        minimumRows: Int = 2
    ) -> Bool {
        guard end > start,
              !strapIdentifier.isEmpty,
              UUID(uuidString: strapIdentifier) != nil else { return false }
        let firstBucket = Self.bucket(for: start.timeIntervalSince1970)
        let lastBucket = Self.bucket(for: end.timeIntervalSince1970)
        guard firstBucket <= lastBucket else { return false }
        let needed = UInt64(max(1, minimumRows) * Self.recordSize)
        lock.lock()
        defer { lock.unlock() }
        for bucket in firstBucket...lastBucket {
            let url = directoryURL.appendingPathComponent(
                Self.filename(
                    strapIdentifier: strapIdentifier,
                    bucket: bucket
                )
            )
            let attributes = try? fileManager.attributesOfItem(atPath: url.path)
            // `read()` accepts only regular files; a directory at the bucket
            // path would otherwise report a size and defeat this short-circuit.
            guard attributes?[.type] as? FileAttributeType == .typeRegular else {
                continue
            }
            let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
            if size >= needed { return true }
        }
        return false
    }

    /// Strict, fixed-width read for the latest physiological-night settlement.
    /// It never consults canonical JSONL, never repairs a shard, and never
    /// silently skips a malformed row. The complete source prefix is hashed,
    /// then guarded by the store generation before a result may be published.
    /// `.serious` is deliberately admitted because this path is capped and
    /// detached; `.critical` always fails closed.
    func latestNightMotionRead(
        start: Date,
        end: Date,
        strapIdentifier: String,
        thermalState: ProcessInfo.ThermalState,
        budget requestedBudget: LatestNightReadBudget = .production,
        deadlineUptimeNanoseconds callerDeadline: UInt64? = nil,
        monotonicNow: @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        }
    ) -> LatestNightMotionRead {
        precondition(!Thread.isMainThread)
        guard thermalState != .critical else {
            return .incomplete(.thermalCritical)
        }
        let production = LatestNightReadBudget.production
        let budget = LatestNightReadBudget(
            maximumShardCount: min(
                requestedBudget.maximumShardCount,
                production.maximumShardCount
            ),
            maximumMappedBytes: min(
                requestedBudget.maximumMappedBytes,
                production.maximumMappedBytes
            ),
            maximumRows: min(
                requestedBudget.maximumRows,
                production.maximumRows
            ),
            deadlineSeconds: min(
                requestedBudget.deadlineSeconds,
                production.deadlineSeconds
            )
        )
        guard end > start,
              let sourceStrapIdentifier = UUID(
                uuidString: strapIdentifier
              ),
              budget.maximumShardCount > 0,
              budget.maximumMappedBytes > 0,
              budget.maximumRows > 0,
              budget.deadlineSeconds.isFinite,
              budget.deadlineSeconds > 0 else {
            return .incomplete(.invalidRequest)
        }
        let startedAt = monotonicNow()
        let budgetNanoseconds = UInt64(
            (budget.deadlineSeconds * 1_000_000_000).rounded(.down)
        )
        let localDeadline = startedAt.addingReportingOverflow(
            budgetNanoseconds
        ).partialValue
        let deadline = min(callerDeadline ?? localDeadline, localDeadline)
        func deadlineExceeded() -> Bool {
            monotonicNow() >= deadline
        }
        guard !deadlineExceeded() else {
            return .incomplete(.deadlineExceeded)
        }

        let firstBucket = Self.bucket(for: start.timeIntervalSince1970)
        let lastBucket = Self.bucket(for: end.timeIntervalSince1970)
        let endStartsNewBucket = lastBucket != Self.bucket(
            for: end.timeIntervalSince1970.nextDown
        )
        guard firstBucket <= lastBucket else {
            return .incomplete(.invalidRequest)
        }
        let shardCount64 = lastBucket - firstBucket + 1
        guard shardCount64 > 0,
              shardCount64 <= Int64(budget.maximumShardCount) else {
            return .incomplete(.shardCapExceeded)
        }

        struct CapturedShard {
            let bucket: Int64
            let filename: String
            let url: URL
            let size: Int
            let systemNumber: UInt64
            let fileNumber: UInt64
            let readHandle: FileHandle
        }
        struct MappedShard {
            let bucket: Int64
            let filename: String
            let data: Data
            let receipt: LatestNightSourceReceipt.Shard
        }
        typealias PrefixCapture = (
            shards: [CapturedShard],
            mappedBytes: Int,
            rowCount: Int,
            mutationGeneration: UInt64,
            structuralGeneration: UInt64
        )
        let captureResult: Result<PrefixCapture, LatestNightReadFailure>
        guard acquireStoreLock(
            beforeUptimeNanoseconds: deadline,
            monotonicNow: monotonicNow
        ) else {
            return .incomplete(.deadlineExceeded)
        }
        do {
            var captures: [CapturedShard] = []
            captures.reserveCapacity(Int(shardCount64))
            var totalBytes = 0
            var totalRows = 0
            do {
                for bucket in firstBucket...lastBucket {
                    guard !deadlineExceeded() else {
                        throw LatestNightReadFailure.deadlineExceeded
                    }
                let filename = Self.filename(
                    strapIdentifier: strapIdentifier,
                    bucket: bucket
                )
                let url = directoryURL.appendingPathComponent(filename)
                // The shared writer is never touched outside the store lock.
                // Once synchronized, the independent read descriptor below
                // owns the captured immutable prefix while appends resume.
                if let handle = handles[url.path] {
                    try handle.synchronize()
                }
                    guard !deadlineExceeded() else {
                        throw LatestNightReadFailure.deadlineExceeded
                    }
                guard let attributes = try? fileManager.attributesOfItem(
                    atPath: url.path
                ),
                attributes[.type] as? FileAttributeType == .typeRegular,
                let sizeNumber = attributes[.size] as? NSNumber,
                let systemNumber = attributes[.systemNumber] as? NSNumber,
                let fileNumber = attributes[.systemFileNumber] as? NSNumber
                else {
                    // An exact UTC endpoint contributes only an optional
                    // terminal sample. Absence of its just-opened shard is an
                    // authoritative empty endpoint, not a missing interior
                    // prefix. File creation later bumps structuralGeneration.
                    if endStartsNewBucket, bucket == lastBucket {
                        continue
                    }
                    throw LatestNightReadFailure.missingShard
                }
                let size64 = sizeNumber.uint64Value
                    if size64 == 0,
                       endStartsNewBucket,
                       bucket == lastBucket {
                        continue
                    }
                guard size64 > 0,
                      size64 <= UInt64(Int.max),
                      size64 % UInt64(Self.recordSize) == 0 else {
                    throw LatestNightReadFailure.integrityFailure
                }
                let size = Int(size64)
                    let nextBytes = totalBytes.addingReportingOverflow(size)
                    guard !nextBytes.overflow,
                          nextBytes.partialValue
                            <= budget.maximumMappedBytes else {
                    throw LatestNightReadFailure.byteCapExceeded
                }
                let shardRows = size / Self.recordSize
                    let nextRows = totalRows.addingReportingOverflow(shardRows)
                    guard !nextRows.overflow,
                          nextRows.partialValue <= budget.maximumRows else {
                    throw LatestNightReadFailure.rowCapExceeded
                }
                    captures.append(.init(
                        bucket: bucket,
                    filename: filename,
                    url: url,
                    size: size,
                    systemNumber: systemNumber.uint64Value,
                    fileNumber: fileNumber.uint64Value,
                    readHandle: try FileHandle(forReadingFrom: url)
                    ))
#if DEBUG
                    latestNightShardCaptureHookForTesting?(bucket)
#endif
                    totalBytes = nextBytes.partialValue
                    totalRows = nextRows.partialValue
                }
                captureResult = .success((
                    shards: captures,
                    mappedBytes: totalBytes,
                    rowCount: totalRows,
                    mutationGeneration: mutationGeneration,
                    structuralGeneration: structuralGeneration
                ))
            } catch let failure as LatestNightReadFailure {
                captures.forEach { try? $0.readHandle.close() }
                captureResult = .failure(failure)
            } catch {
                captures.forEach { try? $0.readHandle.close() }
                captureResult = .failure(.integrityFailure)
            }
            lock.unlock()
        }

        let captured: PrefixCapture
        switch captureResult {
        case .success(let value):
            captured = value
        case .failure(let failure):
            return .incomplete(failure)
        }
        defer { captured.shards.forEach { try? $0.readHandle.close() } }
        var mappedShards: [MappedShard] = []
        mappedShards.reserveCapacity(captured.shards.count)
        for shard in captured.shards {
            do {
                var data = Data()
                data.reserveCapacity(shard.size)
                while data.count < shard.size {
                    guard !deadlineExceeded() else {
                        return .incomplete(.deadlineExceeded)
                    }
                    let remaining = shard.size - data.count
                    guard let chunk = try shard.readHandle.read(
                        upToCount: min(remaining, 256 * 1_024)
                    ),
                    !chunk.isEmpty else {
                        return .incomplete(.sourceChanged)
                    }
                    data.append(chunk)
                }
                guard data.count == shard.size else {
                    return .incomplete(.sourceChanged)
                }
                mappedShards.append(.init(
                    bucket: shard.bucket,
                    filename: shard.filename,
                    data: data,
                    receipt: .init(
                        filename: shard.filename,
                        bucket: shard.bucket,
                        systemNumber: shard.systemNumber,
                        fileNumber: shard.fileNumber,
                        capturedByteCount: shard.size
                    )
                ))
            } catch {
                return .incomplete(.integrityFailure)
            }
        }
        let mappedBytes = captured.mappedBytes
        let rowCount = captured.rowCount
        let capturedGeneration = captured.mutationGeneration
        let capturedStructuralGeneration = captured.structuralGeneration

        var samples: [AtriaRecoveredMotionProjection.Sample] = []
        samples.reserveCapacity(rowCount)
        var contentHasher = SHA256()
        var rowOrdinal = 0
        for shard in mappedShards {
            guard !deadlineExceeded() else {
                return .incomplete(.deadlineExceeded)
            }
            contentHasher.update(data: Data(
                "\(shard.filename)|\(shard.data.count)|".utf8
            ))
            contentHasher.update(data: shard.data)
            for offset in stride(
                from: 0,
                to: shard.data.count,
                by: Self.recordSize
            ) {
                if rowOrdinal.isMultiple(of: 4_096),
                   deadlineExceeded() {
                    return .incomplete(.deadlineExceeded)
                }
                guard Self.uint32(shard.data, at: offset)
                        == Self.recordMagic else {
                    return .incomplete(.integrityFailure)
                }
                let timestamp = Double(
                    bitPattern: Self.uint64(shard.data, at: offset + 4)
                )
                let tick = Int(Int32(bitPattern: Self.uint32(
                    shard.data,
                    at: offset + 16
                )))
                let gravityX = Double(Float(bitPattern: Self.uint32(
                    shard.data,
                    at: offset + 20
                )))
                let gravityY = Double(Float(bitPattern: Self.uint32(
                    shard.data,
                    at: offset + 24
                )))
                let gravityZ = Double(Float(bitPattern: Self.uint32(
                    shard.data,
                    at: offset + 28
                )))
                guard timestamp.isFinite,
                      timestamp > 0,
                      Self.bucket(for: timestamp) == shard.bucket,
                      (0...65_535).contains(tick),
                      gravityX.isFinite,
                      gravityY.isFinite,
                      gravityZ.isFinite else {
                    return .incomplete(.integrityFailure)
                }
                // Saved-session physiology and compact motion share inclusive
                // terminal-sample semantics. Capturing `bucket(end)` above
                // makes an exact UTC-boundary row part of the same snapshot.
                if timestamp >= start.timeIntervalSince1970,
                   timestamp <= end.timeIntervalSince1970 {
                    samples.append(.init(
                        timestamp: Date(timeIntervalSince1970: timestamp),
                        sequence: rowOrdinal,
                        x: gravityX,
                        y: gravityY,
                        z: gravityZ,
                        timestampValidated: true,
                        gravityValidated: true
                    ))
                }
                rowOrdinal += 1
            }
        }
        guard rowOrdinal == rowCount else {
            return .incomplete(.integrityFailure)
        }
        guard !deadlineExceeded() else {
            return .incomplete(.deadlineExceeded)
        }
        let epochs: [AtriaRecoveredMotionEpoch]
        switch latestNightEpochFeatures(
            samples: samples,
            start: start,
            end: end,
            deadlineUptimeNanoseconds: deadline,
            monotonicNow: monotonicNow
        ) {
        case .success(let prepared):
            epochs = prepared
        case .failure(let failure):
            return .incomplete(failure)
        }
        let fingerprint = contentHasher.finalize().map {
            String(format: "%02x", $0)
        }.joined()
        let receipt = LatestNightSourceReceipt(
            storeIdentity: storeIdentity,
            sourceStrapIdentifier: sourceStrapIdentifier,
            sourceFingerprint: fingerprint,
            mutationGeneration: capturedGeneration,
            structuralGeneration: capturedStructuralGeneration,
            start: start,
            end: end,
            shardCount: mappedShards.count,
            mappedBytes: mappedBytes,
            rowCount: rowCount,
            matchedRowCount: samples.count,
            shards: mappedShards.map(\.receipt)
        )
        guard acquireStoreLock(
            beforeUptimeNanoseconds: deadline,
            monotonicNow: monotonicNow
        ) else {
            return .incomplete(.deadlineExceeded)
        }
        let receiptIsCurrent = latestNightReceiptIsCurrentLocked(receipt)
        lock.unlock()
        guard !deadlineExceeded(), receiptIsCurrent else {
            if deadlineExceeded() {
                return .incomplete(.deadlineExceeded)
            }
            return .incomplete(.sourceChanged)
        }
        return .qualified(.init(epochs: epochs, receipt: receipt))
    }

    /// Deadline-cooperative equivalent of the recovered-motion epoch adapter.
    /// A bottom-up stable merge sort replaces the one uninterruptible 200k-row
    /// standard-library sort; each 30-second projection is then independently
    /// bounded and checked against the same caller deadline.
    func latestNightEpochFeatures(
        samples: [AtriaRecoveredMotionProjection.Sample],
        start: Date,
        end: Date,
        deadlineUptimeNanoseconds: UInt64,
        monotonicNow: @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        }
    ) -> Result<
        [AtriaRecoveredMotionEpoch],
        LatestNightReadFailure
    > {
        func deadlineExceeded() -> Bool {
            monotonicNow() >= deadlineUptimeNanoseconds
        }
        guard !deadlineExceeded() else {
            return .failure(.deadlineExceeded)
        }

        var ordered = samples
        if ordered.count > 1 {
            var buffer = ordered
            var width = 1
            var visits = 0
            while width < ordered.count {
                var left = 0
                while left < ordered.count {
                    let middle = min(left + width, ordered.count)
                    let right = min(left + width * 2, ordered.count)
                    var lower = left
                    var upper = middle
                    var destination = left
                    while lower < middle || upper < right {
                        visits += 1
                        if visits.isMultiple(of: 4_096),
                           deadlineExceeded() {
                            return .failure(.deadlineExceeded)
                        }
                        let takeLower: Bool
                        if upper >= right {
                            takeLower = true
                        } else if lower >= middle {
                            takeLower = false
                        } else {
                            let lhs = ordered[lower]
                            let rhs = ordered[upper]
                            takeLower = lhs.timestamp < rhs.timestamp
                                || (lhs.timestamp == rhs.timestamp
                                    && lhs.sequence <= rhs.sequence)
                        }
                        if takeLower {
                            buffer[destination] = ordered[lower]
                            lower += 1
                        } else {
                            buffer[destination] = ordered[upper]
                            upper += 1
                        }
                        destination += 1
                    }
                    left = right
                }
                swap(&ordered, &buffer)
                width *= 2
            }
        }

        let epochDuration: TimeInterval = 30
        let epochCount = max(
            1,
            Int(ceil(end.timeIntervalSince(start) / epochDuration))
        )
        var lower = 0
        var upper = 0
        var epochs: [AtriaRecoveredMotionEpoch] = []
        epochs.reserveCapacity(epochCount)
        for index in 0..<epochCount {
            guard !deadlineExceeded() else {
                return .failure(.deadlineExceeded)
            }
            let epochStart = start.addingTimeInterval(
                Double(index) * epochDuration
            )
            let epochEnd = min(
                end,
                epochStart.addingTimeInterval(epochDuration)
            )
            while lower < ordered.count,
                  ordered[lower].timestamp < epochStart {
                lower += 1
                if lower.isMultiple(of: 4_096), deadlineExceeded() {
                    return .failure(.deadlineExceeded)
                }
            }
            upper = max(upper, lower)
            let isFinalEpoch = epochEnd == end
            while upper < ordered.count {
                let timestamp = ordered[upper].timestamp
                guard timestamp < epochEnd
                    || (isFinalEpoch && timestamp == epochEnd) else {
                    break
                }
                upper += 1
                if upper.isMultiple(of: 4_096), deadlineExceeded() {
                    return .failure(.deadlineExceeded)
                }
            }
            guard upper - lower <= Self.maximumLatestNightRowsPerEpoch else {
                return .failure(.rowCapExceeded)
            }
            let projected = latestNightEpochFeature(
                orderedSamples: ordered,
                lower: lower,
                upper: upper,
                start: epochStart,
                end: epochEnd,
                deadlineUptimeNanoseconds: deadlineUptimeNanoseconds
            )
            switch projected {
            case .success(let epoch):
                epochs.append(epoch)
            case .failure(let failure):
                return .failure(failure)
            }
        }
        guard !deadlineExceeded() else {
            return .failure(.deadlineExceeded)
        }
        return .success(epochs)
    }

    /// One exact 30-second projection over an already timestamp-sorted slice.
    /// This mirrors `AtriaRecoveredMotionProjection.epochFeatures` without its
    /// second full-array sort/filter pipeline, and checkpoints every row plus
    /// the movement-delta percentile sort.
    private func latestNightEpochFeature(
        orderedSamples: [AtriaRecoveredMotionProjection.Sample],
        lower: Int,
        upper: Int,
        start: Date,
        end: Date,
        deadlineUptimeNanoseconds: UInt64
    ) -> Result<AtriaRecoveredMotionEpoch, LatestNightReadFailure> {
        func deadlineExceeded() -> Bool {
            DispatchTime.now().uptimeNanoseconds
                >= deadlineUptimeNanoseconds
        }
        guard lower >= 0,
              upper >= lower,
              upper <= orderedSamples.count,
              end > start else {
            return .failure(.integrityFailure)
        }
        var configuration = AtriaRecoveredMotionProjection.Configuration
            .production
        configuration.minimumValidatedRows = 4
        configuration.minimumCoverageSeconds = 30 * 0.65
        configuration.maximumGapSeconds = 12
        configuration.maximumWindowSeconds = 60
        var validated: [AtriaRecoveredMotionProjection.Sample] = []
        validated.reserveCapacity(max(0, upper - lower))
        if lower < upper {
            for index in lower..<upper {
                if index.isMultiple(of: 256), deadlineExceeded() {
                    return .failure(.deadlineExceeded)
                }
                let sample = orderedSamples[index]
                let magnitude = (
                    sample.x * sample.x
                    + sample.y * sample.y
                    + sample.z * sample.z
                ).squareRoot()
                if sample.timestampValidated,
                   sample.gravityValidated,
                   sample.x.isFinite,
                   sample.y.isFinite,
                   sample.z.isFinite,
                   magnitude.isFinite,
                   configuration.plausibleGravityMagnitude
                    .contains(magnitude) {
                    validated.append(sample)
                }
            }
        }
        let rowCount = upper - lower
        if rowCount == 0 {
            return .success(.init(
                start: start,
                end: end,
                rows: 0,
                validatedRows: 0,
                stillnessRatio: nil,
                movementIntensity: nil,
                p95VectorDelta: nil,
                maximumGapSeconds: max(
                    0,
                    Int(end.timeIntervalSince(start).rounded())
                ),
                measurementValidated: false,
                lowMotionQualified: false,
                reason: "no_timestamp_overlap"
            ))
        }
        let coverage: Int
        if validated.count >= 2,
           let first = validated.first?.timestamp,
           let last = validated.last?.timestamp {
            coverage = max(
                0,
                Int(last.timeIntervalSince(first).rounded())
            )
        } else {
            coverage = 0
        }
        var maximumGap = end.timeIntervalSince(start)
        if let first = validated.first?.timestamp,
           let last = validated.last?.timestamp {
            maximumGap = max(0, first.timeIntervalSince(start))
            var previous = first
            for (index, sample) in validated.dropFirst().enumerated() {
                if index.isMultiple(of: 256), deadlineExceeded() {
                    return .failure(.deadlineExceeded)
                }
                maximumGap = max(
                    maximumGap,
                    max(0, sample.timestamp.timeIntervalSince(previous))
                )
                previous = sample.timestamp
            }
            maximumGap = max(
                maximumGap,
                max(0, end.timeIntervalSince(last))
            )
        }
        let roundedMaximumGap = max(0, Int(maximumGap.rounded()))
        var deltas: [Double] = []
        deltas.reserveCapacity(max(0, validated.count - 1))
        if validated.count > 1 {
            for index in 1..<validated.count {
                if index.isMultiple(of: 256), deadlineExceeded() {
                    return .failure(.deadlineExceeded)
                }
                let previous = validated[index - 1]
                let current = validated[index]
                let gap = current.timestamp.timeIntervalSince(
                    previous.timestamp
                )
                guard gap >= 0,
                      gap <= configuration.maximumGapSeconds else { continue }
                let dx = current.x - previous.x
                let dy = current.y - previous.y
                let dz = current.z - previous.z
                deltas.append((dx * dx + dy * dy + dz * dz).squareRoot())
            }
        }
        var stillCount = 0
        var intensitySum = 0.0
        for (index, delta) in deltas.enumerated() {
            if index.isMultiple(of: 256), deadlineExceeded() {
                return .failure(.deadlineExceeded)
            }
            if delta <= configuration.stillTransitionThreshold {
                stillCount += 1
            }
            intensitySum += delta
        }
        let stillness = deltas.isEmpty
            ? nil : Double(stillCount) / Double(deltas.count)
        let intensity = deltas.isEmpty
            ? nil : intensitySum / Double(deltas.count)
        var orderedDeltas = deltas
        if orderedDeltas.count > 1 {
            var buffer = orderedDeltas
            var width = 1
            while width < orderedDeltas.count {
                if deadlineExceeded() {
                    return .failure(.deadlineExceeded)
                }
                var left = 0
                while left < orderedDeltas.count {
                    let middle = min(left + width, orderedDeltas.count)
                    let right = min(left + width * 2, orderedDeltas.count)
                    var lowerIndex = left
                    var upperIndex = middle
                    var destination = left
                    while destination < right {
                        if destination.isMultiple(of: 256),
                           deadlineExceeded() {
                            return .failure(.deadlineExceeded)
                        }
                        if lowerIndex < middle,
                           (upperIndex >= right
                            || orderedDeltas[lowerIndex]
                                <= orderedDeltas[upperIndex]) {
                            buffer[destination] = orderedDeltas[lowerIndex]
                            lowerIndex += 1
                        } else {
                            buffer[destination] = orderedDeltas[upperIndex]
                            upperIndex += 1
                        }
                        destination += 1
                    }
                    left = right
                }
                swap(&orderedDeltas, &buffer)
                width = width > orderedDeltas.count / 2
                    ? orderedDeltas.count : width * 2
            }
        }
        let p95: Double? = orderedDeltas.isEmpty ? nil : orderedDeltas[
            Int((Double(orderedDeltas.count - 1) * 0.95).rounded(.down))
        ]
        let validatedFraction = rowCount > 0
            ? Double(validated.count) / Double(rowCount)
            : 0
        let reason: String
        let measurementValidated: Bool
        if validated.count < configuration.minimumValidatedRows {
            reason = "insufficient_validated_rows"
            measurementValidated = false
        } else if validatedFraction < configuration.minimumValidatedFraction {
            reason = "unvalidated_row_fraction"
            measurementValidated = false
        } else if Double(coverage)
                    < configuration.minimumCoverageSeconds {
            reason = "insufficient_coverage"
            measurementValidated = false
        } else if Double(roundedMaximumGap)
                    > configuration.maximumGapSeconds {
            reason = "window_or_internal_gap"
            measurementValidated = false
        } else if deltas.isEmpty {
            reason = "insufficient_contiguous_transitions"
            measurementValidated = false
        } else {
            reason = "bounded_historical_gravity_validated"
            measurementValidated = true
        }
        let lowMotion = measurementValidated
            && (stillness ?? 0) >= configuration.lowMotionStillnessRatio
            && (intensity ?? .infinity)
                <= configuration.lowMotionIntensity
        guard !deadlineExceeded() else {
            return .failure(.deadlineExceeded)
        }
        return .success(.init(
            start: start,
            end: end,
            rows: rowCount,
            validatedRows: validated.count,
            stillnessRatio: stillness,
            movementIntensity: intensity,
            p95VectorDelta: p95,
            maximumGapSeconds: roundedMaximumGap,
            measurementValidated: measurementValidated,
            lowMotionQualified: lowMotion,
            reason: reason
        ))
    }

    /// Append-tolerant commit-time CAS for one atomically captured prefix
    /// vector. The hashed prefixes are immutable under this store's ownership;
    /// append growth is ordered after the cut. Truncation, replacement,
    /// retention, repair, and source replacement fail closed.
    func latestNightReceiptIsCurrent(
        _ receipt: LatestNightSourceReceipt
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return latestNightReceiptIsCurrentLocked(receipt)
    }

    private func latestNightReceiptIsCurrentLocked(
        _ receipt: LatestNightSourceReceipt
    ) -> Bool {
        let capturedBytes = receipt.shards.reduce(into: 0) {
            $0 += $1.capturedByteCount
        }
        guard receipt.storeIdentity == storeIdentity,
              receipt.shardCount == receipt.shards.count,
              !receipt.shards.isEmpty,
              receipt.shardCount <= LatestNightReadBudget.production
                .maximumShardCount,
              receipt.mappedBytes > 0,
              receipt.mappedBytes <= LatestNightReadBudget.production
                .maximumMappedBytes,
              receipt.rowCount > 0,
              receipt.rowCount <= LatestNightReadBudget.production
                .maximumRows,
              receipt.mappedBytes == capturedBytes,
              receipt.rowCount == receipt.mappedBytes / Self.recordSize,
              receipt.structuralGeneration == structuralGeneration else {
            return false
        }
        return receipt.shards.allSatisfy { shard in
            guard shard.capturedByteCount > 0,
                  shard.capturedByteCount % Self.recordSize == 0,
                  shard.filename == Self.filename(
                    strapIdentifier:
                        receipt.sourceStrapIdentifier.uuidString,
                    bucket: shard.bucket
                  ) else {
                return false
            }
            let url = directoryURL.appendingPathComponent(shard.filename)
            guard let attributes = try? fileManager.attributesOfItem(
                atPath: url.path
            ),
            attributes[.type] as? FileAttributeType == .typeRegular,
            let sizeNumber = attributes[.size] as? NSNumber,
            let systemNumber = attributes[.systemNumber] as? NSNumber,
            let fileNumber = attributes[.systemFileNumber] as? NSNumber else {
                return false
            }
            let size = sizeNumber.uint64Value
            return systemNumber.uint64Value == shard.systemNumber
                && fileNumber.uint64Value == shard.fileNumber
                && size >= UInt64(shard.capturedByteCount)
                && size % UInt64(Self.recordSize) == 0
        }
    }

    /// Mints against the exact prefixes already decoded by the reader. It never
    /// chases an active append tail: doing so cannot converge under continuous
    /// historical catch-up. Later rows are part of the next coalesced snapshot.
    func mintLatestNightCommitAuthority(
        for receipt: LatestNightSourceReceipt,
        strapIdentifier: String,
        deadlineUptimeNanoseconds: UInt64
    ) -> LatestNightCommitAuthority? {
        precondition(!Thread.isMainThread)
        guard let sourceStrapIdentifier = UUID(uuidString: strapIdentifier),
              sourceStrapIdentifier == receipt.sourceStrapIdentifier,
              receipt.storeIdentity == storeIdentity,
              receipt.shardCount == receipt.shards.count,
              !receipt.shards.isEmpty,
              DispatchTime.now().uptimeNanoseconds
                < deadlineUptimeNanoseconds else {
            return nil
        }
        guard acquireStoreLock(
            beforeUptimeNanoseconds: deadlineUptimeNanoseconds,
            monotonicNow: { DispatchTime.now().uptimeNanoseconds }
        ) else {
            return nil
        }
        defer { lock.unlock() }
        guard DispatchTime.now().uptimeNanoseconds
                < deadlineUptimeNanoseconds else {
            return nil
        }
        let receiptIsCurrent = latestNightReceiptIsCurrentLocked(receipt)
#if DEBUG
        mintDidValidateReceiptHookForTesting?()
#endif
        guard receiptIsCurrent,
              DispatchTime.now().uptimeNanoseconds
                < deadlineUptimeNanoseconds else {
            return nil
        }
        let authority = LatestNightCommitAuthority(
            id: UUID(),
            storeIdentity: storeIdentity,
            structuralGeneration: structuralGeneration,
            sourceStrapIdentifier: sourceStrapIdentifier
        )
        // Session settlement is single-flight. Retire an authority abandoned
        // by a previous nonblocking MainActor consume before minting its retry.
        commitAuthorities.removeAll(keepingCapacity: true)
        commitAuthorities[authority.id] = authority
        return authority
    }

    /// MainActor-safe: lock-only, single-use, and performs no filesystem work.
    func consumeLatestNightCommitAuthority(
        _ authority: LatestNightCommitAuthority,
        currentStrapIdentifier: String
    ) -> Bool {
        // This runs on MainActor. Never wait behind a compact fsync or
        // migration chunk; a failed try is safely retried by the existing
        // one-shot stale path or the next coalesced source edge.
        guard lock.try() else { return false }
        defer { lock.unlock() }
        guard authority.storeIdentity == storeIdentity else { return false }
        // Every attempt is single-use, including an identity mismatch.
        guard commitAuthorities.removeValue(forKey: authority.id)
                == authority,
              UUID(uuidString: currentStrapIdentifier)
                == authority.sourceStrapIdentifier,
              structuralGeneration == authority.structuralGeneration else {
            return false
        }
        return true
    }

#if DEBUG
    /// Focused tests use this to prove MainActor consume never waits behind a
    /// writer/fsync. Production callers cannot acquire the lock through it.
    func withStoreLockHeldForTesting(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body()
    }

    func setLatestNightShardCaptureHookForTesting(
        _ hook: (@Sendable (Int64) -> Void)?
    ) {
        lock.lock()
        defer { lock.unlock() }
        latestNightShardCaptureHookForTesting = hook
    }

    func setTailRepairWillSynchronizeHookForTesting(
        _ hook: (@Sendable () throws -> Void)?
    ) {
        lock.lock()
        defer { lock.unlock() }
        tailRepairWillSynchronizeHookForTesting = hook
    }

    func setAppendWriteHookForTesting(
        _ hook: (@Sendable (FileHandle, Data) throws -> Void)?
    ) {
        lock.lock()
        defer { lock.unlock() }
        appendWriteHookForTesting = hook
    }

    func setMintDidValidateReceiptHookForTesting(
        _ hook: (@Sendable () -> Void)?
    ) {
        lock.lock()
        defer { lock.unlock() }
        mintDidValidateReceiptHookForTesting = hook
    }

    func repairPartialTailForTesting(at url: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        try repairPartialTailLocked(at: url)
    }

    func setDecodedPrefixDecodeHookForTesting(
        _ hook: (@Sendable (String, Int, Int) -> Void)?
    ) {
        decodedPrefixCondition.lock()
        defer { decodedPrefixCondition.unlock() }
        decodedPrefixDecodeHookForTesting = hook
    }

    func setDecodedPrefixCacheBudgetForTesting(
        maximumEntries: Int,
        maximumSourceBytes: Int,
        maximumPoints: Int
    ) {
        decodedPrefixCondition.lock()
        defer {
            decodedPrefixCondition.broadcast()
            decodedPrefixCondition.unlock()
        }
        decodedPrefixCacheBudget = .init(
            maximumEntries: max(0, maximumEntries),
            maximumSourceBytes: max(0, maximumSourceBytes),
            maximumPoints: max(0, maximumPoints)
        )
        decodedPrefixCacheEpoch &+= 1
        decodedPrefixCache.removeAll(keepingCapacity: true)
    }

    func decodedPrefixCacheStatisticsForTesting()
        -> DecodedPrefixCacheStatistics {
        decodedPrefixCondition.lock()
        defer { decodedPrefixCondition.unlock() }
        return .init(
            entryCount: decodedPrefixCache.count,
            sourceBytes: decodedPrefixCache.values.reduce(0) {
                $0 + $1.capturedByteCount
            },
            pointCount: decodedPrefixCache.values.reduce(0) {
                $0 + $1.points.count
            },
            activeDecoderCount: decodedPrefixDecoders.count,
            decodePassCount: decodedPrefixDecodePassCountForTesting,
            waitCount: decodedPrefixWaitCountForTesting,
            epoch: decodedPrefixCacheEpoch
        )
    }

    /// Decoded rows for one window, for consumers that need the per-minute
    /// texture rather than a reduced total — today that is the unattributed-
    /// motion detector. Same lock and decode path as every other read.
    func decodedPoints(
        start: Date,
        end: Date,
        strapIdentifier: String
    ) -> [Point] {
        precondition(!Thread.isMainThread)
        return read(start: start, end: end, strapIdentifier: strapIdentifier)
    }

    func decodedPointsForTesting(
        start: Date,
        end: Date,
        strapIdentifier: String
    ) -> [Point] {
        read(
            start: start,
            end: end,
            strapIdentifier: strapIdentifier
        )
    }

    static func transportCoveragesForTesting(
        points: [Point],
        tickets: [AtriaWhoop4MotionBankCoverageLedger.OffloadTicket],
        strapIdentifier: String
    ) -> [String: HistoricalArchive.MotionBankTransportCoverage] {
        let index = MotionBankTransportCoverageIndex(points: points)
        return Dictionary(uniqueKeysWithValues: tickets.compactMap { ticket in
            guard ticket.strapIdentifier.caseInsensitiveCompare(
                strapIdentifier
            ) == .orderedSame,
                  ticket.end > ticket.start else { return nil }
            return (
                ticket.id,
                transportCoverage(
                    index: index,
                    start: ticket.start,
                    end: ticket.end
                )
            )
        })
    }
#endif

    /// Bounds waiting behind historical migration chunks. Callers own the
    /// original settlement deadline; this helper never mints a fresh budget.
    private func acquireStoreLock(
        beforeUptimeNanoseconds deadline: UInt64,
        monotonicNow: @Sendable () -> UInt64
    ) -> Bool {
        while monotonicNow() < deadline {
            if lock.try() {
                return true
            }
            Thread.sleep(forTimeInterval: 0.000_25)
        }
        return false
    }

    func transportCoverage(
        start: Date,
        end: Date,
        strapIdentifier: String
    ) -> HistoricalArchive.MotionBankTransportCoverage {
        precondition(!Thread.isMainThread)
        guard end > start else {
            return .init(
                observedSeconds: 0,
                expectedSeconds: 0,
                densityPercent: 0,
                maximumMissingRunSeconds: 0,
                firstCapturedAt: nil,
                capturedThrough: nil
            )
        }
        let points = read(
            start: start.addingTimeInterval(-1),
            end: end.addingTimeInterval(1),
            strapIdentifier: strapIdentifier
        )
        return Self.transportCoverage(
            points: points,
            start: start,
            end: end
        )
    }

    /// Reads the compact shard once and evaluates every pending exact bank
    /// window against that same durable generation. A full history response can
    /// satisfy many disconnected bank windows; one-ticket-at-a-time reads made
    /// convergence proportional to link churn and repeatedly interrupted HR.
    func transportCoverages(
        tickets: [AtriaWhoop4MotionBankCoverageLedger.OffloadTicket],
        strapIdentifier: String
    ) -> [String: HistoricalArchive.MotionBankTransportCoverage] {
        precondition(!Thread.isMainThread)
        let eligible = tickets.filter {
            $0.strapIdentifier.caseInsensitiveCompare(strapIdentifier)
                == .orderedSame
                && $0.end > $0.start
        }
        guard let first = eligible.map(\.start).min(),
              let last = eligible.map(\.end).max() else {
            return [:]
        }
        let points = read(
            start: first.addingTimeInterval(-1),
            end: last.addingTimeInterval(1),
            strapIdentifier: strapIdentifier
        )
        let index = MotionBankTransportCoverageIndex(points: points)
        return Dictionary(uniqueKeysWithValues: eligible.map { ticket in
            (
                ticket.id,
                Self.transportCoverage(
                    index: index,
                    start: ticket.start,
                    end: ticket.end
                )
            )
        })
    }

    private static func transportCoverage(
        points: [Point],
        start: Date,
        end: Date
    ) -> HistoricalArchive.MotionBankTransportCoverage {
        transportCoverage(
            index: MotionBankTransportCoverageIndex(points: points),
            start: start,
            end: end
        )
    }

    /// One immutable index serves every exact bank ticket in a compact shard
    /// evaluation. The prior implementation sorted and scanned every point for
    /// every ticket, making 160+ accumulated tickets quadratic on the serial
    /// archive lane. Timestamp and unique-second bounds plus a max-gap segment
    /// tree preserve the exact inclusive-bucket result in O(log n) per ticket.
    private struct MotionBankTransportCoverageIndex {
        let timestamps: [TimeInterval]
        let timestampBuckets: [Int]
        let uniqueBuckets: [Int]
        let maximumGapTreeBase: Int
        let maximumGapTree: [Int]

        init(points: [Point]) {
            timestamps = points.map(\.timestamp).sorted()
            timestampBuckets = timestamps.map { Int(floor($0)) }
            var unique: [Int] = []
            unique.reserveCapacity(timestampBuckets.count)
            for bucket in timestampBuckets where unique.last != bucket {
                unique.append(bucket)
            }
            uniqueBuckets = unique

            var base = 1
            let gapCount = max(0, unique.count - 1)
            while base < gapCount { base *= 2 }
            maximumGapTreeBase = base
            var tree = Array(repeating: 0, count: base * 2)
            if gapCount > 0 {
                for index in 0..<gapCount {
                    tree[base + index] = max(
                        0,
                        unique[index + 1] - unique[index] - 1
                    )
                }
                if base > 1 {
                    for index in stride(
                        from: base - 1,
                        through: 1,
                        by: -1
                    ) {
                        tree[index] = max(
                            tree[index * 2],
                            tree[index * 2 + 1]
                        )
                    }
                }
            }
            maximumGapTree = tree
        }

        func maximumGap(from lower: Int, to upper: Int) -> Int {
            guard lower < upper else { return 0 }
            var left = lower + maximumGapTreeBase
            var right = upper + maximumGapTreeBase
            var result = 0
            while left < right {
                if left.isMultiple(of: 2) == false {
                    result = max(result, maximumGapTree[left])
                    left += 1
                }
                if right.isMultiple(of: 2) == false {
                    right -= 1
                    result = max(result, maximumGapTree[right])
                }
                left /= 2
                right /= 2
            }
            return result
        }
    }

    private static func lowerBound(
        _ values: [Int],
        _ target: Int
    ) -> Int {
        var lower = 0
        var upper = values.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if values[middle] < target {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }

    private static func upperBound(
        _ values: [Int],
        _ target: Int
    ) -> Int {
        var lower = 0
        var upper = values.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if values[middle] <= target {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }

    private static func transportCoverage(
        index: MotionBankTransportCoverageIndex,
        start: Date,
        end: Date
    ) -> HistoricalArchive.MotionBankTransportCoverage {
        guard end > start else {
            return .init(
                observedSeconds: 0,
                expectedSeconds: 0,
                densityPercent: 0,
                maximumMissingRunSeconds: 0,
                firstCapturedAt: nil,
                capturedThrough: nil
            )
        }
        let firstBucket = Int(floor(start.timeIntervalSince1970))
        let lastBucket = Int(floor(end.timeIntervalSince1970))
        let expected = max(1, lastBucket - firstBucket + 1)
        let timestampLower = lowerBound(
            index.timestampBuckets,
            firstBucket
        )
        let timestampUpper = upperBound(
            index.timestampBuckets,
            lastBucket
        )
        let secondLower = lowerBound(index.uniqueBuckets, firstBucket)
        let secondUpper = upperBound(index.uniqueBuckets, lastBucket)
        let observed = max(0, secondUpper - secondLower)
        let maximumMissingRun: Int
        if observed == 0 {
            maximumMissingRun = expected
        } else {
            let firstObserved = index.uniqueBuckets[secondLower]
            let lastObserved = index.uniqueBuckets[secondUpper - 1]
            maximumMissingRun = max(
                max(
                    firstObserved - firstBucket,
                    lastBucket - lastObserved
                ),
                index.maximumGap(
                    from: secondLower,
                    to: secondUpper - 1
                )
            )
        }
        return .init(
            observedSeconds: observed,
            expectedSeconds: expected,
            densityPercent: min(
                100,
                Int(
                    (Double(observed) / Double(expected) * 100)
                        .rounded()
                )
            ),
            maximumMissingRunSeconds: maximumMissingRun,
            firstCapturedAt: timestampLower < timestampUpper
                ? Date(timeIntervalSince1970: index.timestamps[timestampLower])
                : nil,
            capturedThrough: timestampLower < timestampUpper
                ? Date(timeIntervalSince1970:
                    index.timestamps[timestampUpper - 1])
                : nil
        )
    }

    /// Projects one exact confirmed-workout window from the fixed-width
    /// compact shards. These points already carry their accepted corrected
    /// wall timestamps, so one zero offset governs the whole candidate. A
    /// missing boundary remains incomplete: it is never authority to fall back
    /// to lifetime JSONL from a launch, scene, or BLE callback.
    /// Counter-derived count for a confirmed walk the cadence model could not
    /// resolve. Returns `.completeNoQualifiedEvidence` unless explicitly
    /// enabled, so this is inert for every caller that has not proven the
    /// window is a user-labelled walk.
    ///
    /// The scale is not invented: `evidence/2026-07-27-gate4-prearmed-walk`
    /// counted 132 real steps against 155 ticks (155/132 = 1.17424), and the
    /// independent held-out walk predicted 136 from 160 ticks at **0.0%
    /// error**. That is the same constant `publishedSteps` already uses, and
    /// it stays fail-closed: `publishedSteps` returns nil unless the frozen
    /// validation still matches the current algorithm version.
    private func counterFallbackWindowRead(
        first: Point,
        last: Point,
        enabled: Bool
    ) -> HistoricalArchive.MotionTickWindowRead {
        guard enabled else { return .completeNoQualifiedEvidence }
        let duration = last.timestamp - first.timestamp
        guard duration > 0 else {
            AtriaDebugLog(
                "ATRIADBG walk_counter_fallback status=rejected reason=non_positive_duration"
            )
            return .completeNoQualifiedEvidence
        }
        let modulus = 65_536
        let delta = last.tick >= first.tick
            ? last.tick - first.tick
            : last.tick + modulus - first.tick
        // Same rate sanity gate the resolved path applies: a counter that
        // moved faster than 12 ticks per second is a reset or a wrap, never a
        // walk.
        guard delta > 0, Double(delta) <= max(12, duration * 12) else {
            AtriaDebugLog(
                "ATRIADBG walk_counter_fallback status=rejected reason=rate_gate delta=%d duration_s=%.0f",
                delta, duration
            )
            return .completeNoQualifiedEvidence
        }
        guard let steps = AtriaWhoop4MotionTickStepModel.publishedSteps(
            motionTicks: delta,
            validation: AtriaWhoop4MotionTickStepModel
                .physicallyValidatedWhoop4V24
        ), steps > 0 else {
            AtriaDebugLog(
                "ATRIADBG walk_counter_fallback status=rejected reason=published_steps_nil delta=%d",
                delta
            )
            return .completeNoQualifiedEvidence
        }
        AtriaDebugLog(
            "ATRIADBG walk_counter_fallback status=published delta=%d steps=%d duration_s=%.0f",
            delta, steps, duration
        )
        return .qualified(
            .init(
                startTick: first.tick,
                endTick: last.tick,
                delta: delta,
                steps: steps,
                startCapturedAt: Date(timeIntervalSince1970: first.timestamp),
                endCapturedAt: Date(timeIntervalSince1970: last.timestamp),
                coverageFraction: 1,
                decodedRows: 2
            )
        )
    }

    /// - Parameter allowCounterFallbackForConfirmedWalk: publish a
    ///   counter-derived count when the cadence model cannot resolve one.
    ///   DEFAULT OFF, and it must stay off for anything but a workout the user
    ///   themselves labelled as walking.
    ///
    ///   Why the gate is not optional: `evidence/2026-07-27-gate4-arm-control-
    ///   failure` is a physical run where the feet stayed planted and only the
    ///   strap arm swung rhythmically. A tick-driven scorer published 166
    ///   steps — a recorded FAIL. Tick RATE cannot separate that from walking
    ///   (device 2026-08-24: walk 1.156 ticks/s vs a strength block 1.053
    ///   ticks/s, 10% apart), and drained rows arrive at ~1.04 Hz, far below
    ///   the ~1.7-2.2 Hz needed to recover cadence. The user's own workout
    ///   label is therefore the only evidence available here that excludes the
    ///   arm-control shape, so the fallback rides on it and nothing else.
    func motionTickWindowRead(
        start: Date,
        end: Date,
        strapIdentifier: String,
        allowCounterFallbackForConfirmedWalk: Bool = false
    ) -> HistoricalArchive.MotionTickWindowRead {
        precondition(!Thread.isMainThread)
        guard end > start,
              !strapIdentifier.isEmpty else { return .incomplete }
        let tolerance: TimeInterval = 3
        let firstBucket = Self.bucket(
            for: start.addingTimeInterval(-tolerance).timeIntervalSince1970
        )
        let lastBucket = Self.bucket(
            for: end.addingTimeInterval(tolerance).timeIntervalSince1970
        )
        guard firstBucket <= lastBucket,
              lastBucket - firstBucket + 1
                <= Self.retainedBucketCount else {
            return .incomplete
        }
        let points = read(
            start: start.addingTimeInterval(-tolerance),
            end: end.addingTimeInterval(tolerance),
            strapIdentifier: strapIdentifier
        )
        guard points.count >= 2,
              let first = points.min(by: {
                  abs($0.timestamp - start.timeIntervalSince1970)
                      < abs($1.timestamp - start.timeIntervalSince1970)
              }),
              let last = points.min(by: {
                  abs($0.timestamp - end.timeIntervalSince1970)
                      < abs($1.timestamp - end.timeIntervalSince1970)
              }),
              last.timestamp > first.timestamp,
              abs(first.timestamp - start.timeIntervalSince1970)
                <= tolerance,
              abs(last.timestamp - end.timeIntervalSince1970)
                <= tolerance,
              (last.timestamp - first.timestamp)
                / end.timeIntervalSince(start) >= 0.9 else {
            if allowCounterFallbackForConfirmedWalk {
                AtriaDebugLog(
                    "ATRIADBG walk_counter_fallback status=unreached reason=window_guard rows=%d window_s=%.0f",
                    points.count,
                    end.timeIntervalSince(start)
                )
            }
            return .incomplete
        }
        let cadencePoints = points.map {
            AtriaWhoop4GravityCadenceStepModel.Point(
                timestamp: $0.timestamp,
                flash: $0.flash,
                tick: $0.tick,
                gravityX: $0.gravityX,
                gravityY: $0.gravityY,
                gravityZ: $0.gravityZ,
                unknownMotionScalar32: $0.unknownMotionScalar32,
                identity: $0.identity
            )
        }
        guard let selected =
            AtriaWhoop4GravityCadenceStepModel.estimateAlignedWindow(
                points: cadencePoints,
                requestedStart: start.timeIntervalSince1970,
                requestedEnd: end.timeIntervalSince1970,
                clockOffsetByIdentity: Dictionary(
                    uniqueKeysWithValues: cadencePoints.map {
                        ($0.identity, 0)
                    }
                ),
                boundaryTolerance: tolerance
            ) else {
            // The cadence model could not resolve a defensible cadence. On a
            // confirmed walk that is expected rather than suspicious: drained
            // rows sample at ~1.04 Hz (Nyquist 0.52 Hz) while walking runs at
            // 1.7-2.2 Hz, so the alias simply is not recoverable. Publishing 0
            // for a real 21-minute walk (device 2026-08-24: 1,457 counter
            // ticks, model steps 0) is the wrong answer; the counter is right
            // there and its scale is held-out validated.
            return counterFallbackWindowRead(
                first: first,
                last: last,
                enabled: allowCounterFallbackForConfirmedWalk
            )
        }
        let modulus = 65_536
        let delta = selected.last.tick >= selected.first.tick
            ? selected.last.tick - selected.first.tick
            : selected.last.tick + modulus - selected.first.tick
        guard Double(delta) <= max(
            12,
            (selected.last.timestamp - selected.first.timestamp) * 12
        ) else {
            return .completeNoQualifiedEvidence
        }
        return .qualified(
            .init(
                startTick: selected.first.tick,
                endTick: selected.last.tick,
                delta: delta,
                steps: selected.estimate.steps,
                startCapturedAt: Date(
                    timeIntervalSince1970: selected.first.timestamp
                ),
                endCapturedAt: Date(
                    timeIntervalSince1970: selected.last.timestamp
                ),
                coverageFraction: selected.coverageFraction,
                decodedRows: selected.decodedRows
            )
        )
    }

    /// Projects only compact current-cycle points. It performs no canonical
    /// archive enumeration or JSON decoding and is safe on a utility queue
    /// during a locked/background BLE restoration lease.
    /// - Parameter excludedIntervals: spans that must not contribute steps,
    ///   i.e. workouts the user labelled as non-gait. See `subtracting(_:from:)`.
    func motionTickDayEvidenceRead(
        start: Date,
        end: Date,
        bankCoverage: [DateInterval],
        strapIdentifier: String,
        allowOpenTail: Bool = false,
        excludedIntervals: [DateInterval] = []
    ) -> HistoricalArchive.MotionTickDayEvidenceRead {
        precondition(!Thread.isMainThread)
        guard end > start else { return .incomplete }
        let window = DateInterval(start: start, end: end)
        let ledgerCoverage = Self.merge(bankCoverage.compactMap { interval in
            let clippedStart = max(interval.start, window.start)
            let clippedEnd = min(interval.end, window.end)
            return clippedEnd > clippedStart
                ? DateInterval(start: clippedStart, end: clippedEnd)
                : nil
        })
        let tolerance: TimeInterval = 3
        // Read the whole requested window, not just the spans the live bank
        // happened to be armed for.
        //
        // Device pull 2026-08-25: the bank ledger is a 512-entry FIFO whose
        // median entry is 24s, so it retained only 9.77h of coverage in total
        // (oldest 08-24 09:59). Days older than that scored ZERO steps even
        // though the compact store still held complete ~1Hz rows for them
        // (08-23: 53,246 rows -> 0 steps). On the current day the drain owns
        // the link for hours (`sync_cutover`), which keeps the bank from
        // arming, so the ledger covered 8% of the day and 24,701 rows
        // collapsed to 145 ticks.
        //
        // Coverage is not what makes the count honest — the sequence
        // reducer's per-pair gates are. It admits a pair only when the flash
        // counter advanced by a plausible amount for the elapsed time, which
        // is exactly the proof that the strap was recording across that pair.
        // A row's existence with an advancing flash counter therefore IS
        // coverage; the ledger is a weaker proxy for the same fact. Union the
        // two so recovered rows count, and never drop credit the ledger
        // already granted.
        let points = read(
            start: start.addingTimeInterval(-tolerance),
            end: end.addingTimeInterval(tolerance),
            strapIdentifier: strapIdentifier
        )
        guard points.count >= 2 else { return .incomplete }
        let intervals = Self.subtracting(
            excludedIntervals,
            from: Self.merge(
                ledgerCoverage
                    + Self.rowDerivedCoverage(points: points, window: window)
            )
        )
        guard !intervals.isEmpty else { return .incomplete }

        return Self.motionTickDayEvidenceProjection(
            sortedPoints: points,
            start: start,
            end: end,
            mergedCoverage: intervals,
            tolerance: tolerance,
            allowOpenTail: allowOpenTail
        ).read
    }

    /// Contiguous runs of stored rows, used as first-class coverage.
    ///
    /// `maximumGap` matches the cadence model's own
    /// `maximumContinuousSampleGap` (3s) so a derived interval never claims
    /// coverage across a hole the model would itself refuse to bridge —
    /// `knownCoverageSeconds` stays as honest as it was before.
    ///
    /// `maximumRunSeconds` bounds each run because the cadence model runs a
    /// NAIVE O(1.5·N²) DFT per run (`for bin in 1...(count / 2)` over all
    /// `count` differences × 3 axes). Ledger fragments averaged ~24s, so this
    /// never mattered; a drained day can hold a single 29,994-row continuous
    /// run, which is ~2.5e9 operations — roughly two minutes of CPU on a path
    /// re-driven every few seconds during a drain. Splitting at 90s keeps
    /// total work at ~1.5·N·90 and matches the ~90s windows the physical
    /// corpus was actually validated on.
    ///
    /// SAFETY: widening coverage cannot manufacture a step. Several
    /// independent mechanisms hold that line, and none of them is coverage:
    /// interval membership uses monotonic cursors, so no row is ever a member
    /// of two intervals; `canonical()` dedupes by flash and fails closed on
    /// any conflict; the sequence reducer admits a pair only when the flash
    /// counter advanced proportionally to elapsed time; and the cadence model
    /// applies its own fail-closed gates on top. Widening coverage only stops
    /// us discarding rows we already decoded.
    static func rowDerivedCoverage(
        points: [Point],
        window: DateInterval,
        maximumGap: TimeInterval = 3
    ) -> [DateInterval] {
        guard maximumGap > 0, window.end > window.start else { return [] }
        let stamps = points
            .map(\.timestamp)
            .filter(\.isFinite)
            .sorted()
        guard stamps.count >= 2 else { return [] }
        var runs: [DateInterval] = []
        var runStart = stamps[0]
        var previous = stamps[0]
        func closeRun() {
            guard previous > runStart else { return }
            let clippedStart = max(Date(timeIntervalSince1970: runStart),
                                   window.start)
            let clippedEnd = min(Date(timeIntervalSince1970: previous),
                                 window.end)
            if clippedEnd > clippedStart {
                runs.append(DateInterval(start: clippedStart, end: clippedEnd))
            }
        }
        for stamp in stamps.dropFirst() {
            if stamp - previous > maximumGap {
                closeRun()
                runStart = stamp
            }
            previous = stamp
        }
        closeRun()
        return merge(runs)
    }

    /// Remove non-gait spans (workouts the user labelled Strength, Cycling,
    /// Yoga, …) from step coverage.
    ///
    /// The counter measures WRIST MOTION, so a 65-minute strength block adds
    /// thousands of ticks that are not footfalls — on 2026-08-24 it was 5,232
    /// of the day's 12,956, i.e. 40% of the raw total. This is also the exact
    /// shape `evidence/2026-07-27-gate4-arm-control-failure` recorded as a
    /// physical FAIL (planted feet, arm swinging, 166 published steps). The
    /// user's own workout label is the only signal at 1 Hz that reliably
    /// identifies it, so those spans are cut out of coverage entirely: they
    /// contribute neither ticks nor known step-coverage seconds.
    static func subtracting(
        _ excluded: [DateInterval],
        from intervals: [DateInterval]
    ) -> [DateInterval] {
        guard !excluded.isEmpty else { return intervals }
        let cuts = merge(excluded)
        var result: [DateInterval] = []
        for interval in intervals {
            var pieces = [interval]
            for cut in cuts {
                var next: [DateInterval] = []
                for piece in pieces {
                    if cut.end <= piece.start || cut.start >= piece.end {
                        next.append(piece)
                        continue
                    }
                    if cut.start > piece.start {
                        next.append(DateInterval(start: piece.start,
                                                 end: cut.start))
                    }
                    if cut.end < piece.end {
                        next.append(DateInterval(start: cut.end,
                                                 end: piece.end))
                    }
                }
                pieces = next
            }
            result.append(contentsOf: pieces.filter { $0.duration > 0 })
        }
        return result
    }

    /// Split one interval's members into bounded cadence fragments.
    ///
    /// The cadence model runs a NAIVE `O(1.5·N²)` DFT per run (`for bin in
    /// 1...(count / 2)` over all `count` differences × 3 axes). Ledger
    /// fragments averaged ~24s so that never mattered; once stored rows count
    /// as coverage a drained day yields intervals of many thousands of rows —
    /// measured 29,994 on 2026-08-22, about 2.5e9 operations, roughly two
    /// minutes of CPU on a path re-driven every few seconds during a drain.
    ///
    /// Chunking is done HERE, on the cadence input, and deliberately NOT on
    /// the coverage intervals: the projection's ±3s boundary gate and the
    /// `allowOpenTail` relaxation both key on interval edges, so splitting
    /// intervals would silently hand partial credit to intervals the veto is
    /// meant to reject. Fragments carry no such semantics —
    /// `estimateCoveredActivityFragments` already splits them again on its own
    /// 3s continuous-sample gap — so bounding them changes cost, not meaning.
    /// 90s also matches the ~90s windows the physical corpus was validated on.
    static func boundedCadenceFragments(
        _ members: ArraySlice<Point>,
        maximumRunSeconds: TimeInterval = 90
    ) -> [ArraySlice<Point>] {
        guard maximumRunSeconds > 0, members.count >= 2 else {
            return members.isEmpty ? [] : [members]
        }
        guard let first = members.first,
              let last = members.last,
              last.timestamp - first.timestamp > maximumRunSeconds else {
            return [members]
        }
        var chunks: [ArraySlice<Point>] = []
        var chunkStartIndex = members.startIndex
        var chunkStartStamp = first.timestamp
        var index = members.startIndex
        while index < members.endIndex {
            let stamp = members[index].timestamp
            if stamp - chunkStartStamp >= maximumRunSeconds,
               index > chunkStartIndex {
                chunks.append(members[chunkStartIndex..<index])
                chunkStartIndex = index
                chunkStartStamp = stamp
            }
            index = members.index(after: index)
        }
        if chunkStartIndex < members.endIndex {
            chunks.append(members[chunkStartIndex..<members.endIndex])
        }
        return chunks
    }

    /// The compact reader returns points in `(timestamp, identity)` order and
    /// coverage is already merged in chronological order. Four monotonic
    /// cursors therefore replace the prior full-array filter/min/filter/sort
    /// pass for every interval. Each cursor crosses the source at most once;
    /// interval members are visited only for the interval(s) they can serve.
    private static func motionTickDayEvidenceProjection(
        sortedPoints points: [Point],
        start: Date,
        end: Date,
        mergedCoverage intervals: [DateInterval],
        tolerance: TimeInterval,
        allowOpenTail: Bool = false
    ) -> MotionTickDayEvidenceProjection {
        guard end > start, points.count >= 2, !intervals.isEmpty else {
            return .init(read: .incomplete, inspectedPoints: 0)
        }

        typealias CounterPoint =
            AtriaWhoop4MotionTickSequenceReducer.Point
        typealias CadencePoint =
            AtriaWhoop4GravityCadenceStepModel.Point
        var totalTicks = 0
        var totalKnownDuration: TimeInterval = 0
        var totalDecodedRows = 0
        var capturedThrough: Date?
        var cadenceFragments: [[CadencePoint]] = []

        var startBoundaryCursor = 0
        var endBoundaryCursor = 0
        var memberStartCursor = 0
        var memberEndCursor = 0
        var inspectedPoints = 0

        for interval in intervals {
            let requestedStart = interval.start.timeIntervalSince1970
            let requestedEnd = interval.end.timeIntervalSince1970
            guard let firstTimestamp = nearestTimestamp(
                in: points,
                to: requestedStart,
                cursor: &startBoundaryCursor,
                inspectedPoints: &inspectedPoints
            ),
            let lastTimestamp = nearestTimestamp(
                in: points,
                to: requestedEnd,
                cursor: &endBoundaryCursor,
                inspectedPoints: &inspectedPoints
            ),
            abs(firstTimestamp - requestedStart) <= tolerance,
            lastTimestamp > firstTimestamp else {
                continue
            }
            // Open-tail relaxation (2026-08-22): the CURRENT cycle's final
            // coverage interval ends at `now`, but the compact store necessarily
            // lags `now` (offload cadence), so no decoded row sits within
            // tolerance of the open end — the strict both-boundaries guard then
            // discards the whole interval and the day shows "--" even though real
            // drained rows exist (device evidence: compact_only_missing with
            // coverage present). For the open tail ONLY, accept the newest decoded
            // row as the effective end; [lastRow, now] stays honestly missing via
            // missingCoverageSeconds, so the day is never marked complete. CLOSED
            // intervals keep the exact both-boundaries integrity.
            let reachesWindowEnd =
                abs(requestedEnd - end.timeIntervalSince1970) <= tolerance
            let isOpenTail = allowOpenTail && reachesWindowEnd
            guard abs(lastTimestamp - requestedEnd) <= tolerance || isOpenTail else {
                continue
            }

            while memberStartCursor < points.count,
                  points[memberStartCursor].timestamp < firstTimestamp {
                memberStartCursor += 1
                inspectedPoints += 1
            }
            memberEndCursor = max(memberEndCursor, memberStartCursor)
            while memberEndCursor < points.count,
                  points[memberEndCursor].timestamp <= lastTimestamp {
                memberEndCursor += 1
                inspectedPoints += 1
            }
            let members = points[memberStartCursor..<memberEndCursor]
            guard members.count >= 2 else { continue }
            let counterPoints = members.map {
                CounterPoint(
                    timestamp: $0.timestamp,
                    tick: $0.tick,
                    flash: $0.flash,
                    identity: $0.identity
                )
            }
            let rawInterval = DateInterval(
                start: Date(timeIntervalSince1970: firstTimestamp),
                end: Date(timeIntervalSince1970: lastTimestamp)
            )
            guard let reduced = AtriaWhoop4MotionTickSequenceReducer.reduce(
                points: counterPoints,
                intervals: [rawInterval],
                boundaryTolerance: 0.001
            ) else {
                continue
            }
            for chunk in boundedCadenceFragments(members) {
                cadenceFragments.append(chunk.map {
                    CadencePoint(
                        timestamp: $0.timestamp,
                        flash: $0.flash,
                        tick: $0.tick,
                        gravityX: $0.gravityX,
                        gravityY: $0.gravityY,
                        gravityZ: $0.gravityZ,
                        unknownMotionScalar32: $0.unknownMotionScalar32,
                        identity: $0.identity
                    )
                })
            }
            totalTicks += reduced.ticks
            totalKnownDuration += reduced.knownDuration
            totalDecodedRows += reduced.admittedRows
            capturedThrough = max(
                capturedThrough ?? reduced.capturedThrough,
                reduced.capturedThrough
            )
        }

        guard totalKnownDuration > 0,
              totalDecodedRows >= 2,
              let capturedThrough else {
            return .init(
                read: .completeNoQualifiedEvidence,
                inspectedPoints: inspectedPoints
            )
        }
        let estimate = AtriaWhoop4GravityCadenceStepModel
            .estimateCoveredActivityFragments(cadenceFragments)
        // Counter lane. The cadence model is structurally blind to normal
        // walking in drained history: rows arrive at ~1.04 Hz (Nyquist
        // 0.52 Hz) while walking runs at 1.7-2.2 Hz, so a real 21-minute walk
        // resolved to 0 steps on device (2026-08-24, 1,457 ticks). The strap's
        // own counter does see it, and its scale is not a guess — the counted
        // physical corpus measured 132 real steps against 155 ticks and then
        // predicted a held-out 136-step walk from 160 ticks at 0.0% error.
        //
        // Safe as a DAILY total because the same corpus proved the counter is
        // silent at rest ("preceding 60-second rest delta = 0 ticks"), so idle
        // time cannot inflate it. Sustained non-gait arm work is the one shape
        // that can, and those windows are removed from coverage before this
        // point via `excludedIntervals`.
        let counterSteps = AtriaWhoop4MotionTickStepModel.publishedSteps(
            motionTicks: totalTicks,
            validation: AtriaWhoop4MotionTickStepModel
                .physicallyValidatedWhoop4V24
        ) ?? 0
        let unresolved = estimate?.unresolvedMotionSeconds
            ?? totalKnownDuration
        let totalSeconds = max(
            0,
            Int(end.timeIntervalSince(start).rounded())
        )
        let knownSeconds = max(
            0,
            Int(totalKnownDuration.rounded())
        )
        let qualifiedSeconds = max(
            0,
            min(totalSeconds, knownSeconds)
                - max(0, Int(unresolved.rounded(.up)))
        )
        return .init(
            read: .qualified(
                .init(
                    windowStart: start,
                    windowEnd: end,
                    motionTicks: totalTicks,
                    // Whichever lane saw more. Cadence wins when it can
                    // actually resolve (dense live IMU); the counter carries
                    // the day when 1 Hz history makes cadence unrecoverable.
                    steps: max(estimate?.steps ?? 0, counterSteps),
                    knownCoverageSeconds: qualifiedSeconds,
                    missingCoverageSeconds: max(
                        0,
                        totalSeconds - qualifiedSeconds
                    ),
                    decodedRows: totalDecodedRows,
                    capturedThrough: min(capturedThrough, end)
                )
            ),
            inspectedPoints: inspectedPoints
        )
    }

    /// Finds the same nearest timestamp as the former chronological
    /// `min(abs(delta))` pass. Equal-distance ties retain the earlier
    /// timestamp. The cursor advances monotonically as interval boundaries do.
    private static func nearestTimestamp(
        in points: [Point],
        to target: TimeInterval,
        cursor: inout Int,
        inspectedPoints: inout Int
    ) -> TimeInterval? {
        while cursor < points.count,
              points[cursor].timestamp < target {
            cursor += 1
            inspectedPoints += 1
        }
        var nearest: TimeInterval?
        if cursor > 0 {
            nearest = points[cursor - 1].timestamp
            inspectedPoints += 1
        }
        if cursor < points.count {
            let candidate = points[cursor].timestamp
            inspectedPoints += 1
            if let current = nearest {
                if abs(candidate - target) < abs(current - target) {
                    nearest = candidate
                }
            } else {
                nearest = candidate
            }
        }
        return nearest
    }

#if DEBUG
    struct MotionTickDayEvidenceInspectionResult {
        let read: HistoricalArchive.MotionTickDayEvidenceRead
        let inspectedPoints: Int
    }

    /// Pure seam for parity and complexity tests; production always supplies
    /// already-sorted points from `read(start:end:strapIdentifier:)` and merged
    /// intervals from the public day-evidence entry point.
    static func motionTickDayEvidenceReadForTesting(
        sortedPoints: [Point],
        start: Date,
        end: Date,
        bankCoverage: [DateInterval],
        tolerance: TimeInterval = 3,
        allowOpenTail: Bool = false
    ) -> MotionTickDayEvidenceInspectionResult {
        let window = DateInterval(start: start, end: end)
        // Mirror production: ledger coverage unioned with the coverage the
        // stored rows themselves prove.
        let ledgerCoverage = merge(bankCoverage.compactMap { interval in
            let clippedStart = max(interval.start, window.start)
            let clippedEnd = min(interval.end, window.end)
            return clippedEnd > clippedStart
                ? DateInterval(start: clippedStart, end: clippedEnd)
                : nil
        })
        let intervals = merge(
            ledgerCoverage
                + rowDerivedCoverage(points: sortedPoints, window: window)
        )
        let projection = motionTickDayEvidenceProjection(
            sortedPoints: sortedPoints,
            start: start,
            end: end,
            mergedCoverage: intervals,
            tolerance: tolerance,
            allowOpenTail: allowOpenTail
        )
        return .init(
            read: projection.read,
            inspectedPoints: projection.inspectedPoints
        )
    }
#endif

    private func read(
        start: Date,
        end: Date,
        strapIdentifier: String
    ) -> [Point] {
        guard end > start,
              UUID(uuidString: strapIdentifier) != nil else {
            return []
        }
        let firstBucket = Self.bucket(for: start.timeIntervalSince1970)
        let lastBucket = Self.bucket(for: end.timeIntervalSince1970)
        var captures: [CapturedDecodedPrefix] = []
        let capturedStructuralGeneration: UInt64
        lock.lock()
        capturedStructuralGeneration = structuralGeneration
        let capturedCacheEpoch = decodedPrefixCacheEpochSnapshotLocked()
        if firstBucket <= lastBucket {
            for bucket in firstBucket...lastBucket {
                let url = directoryURL.appendingPathComponent(
                    Self.filename(
                        strapIdentifier: strapIdentifier,
                        bucket: bucket
                    )
                )
                if let writer = handles[url.path] {
                    try? writer.synchronize()
                }
                guard let attributes = try? fileManager.attributesOfItem(
                    atPath: url.path
                ),
                attributes[.type] as? FileAttributeType == .typeRegular,
                let sizeNumber = attributes[.size] as? NSNumber,
                sizeNumber.uint64Value <= UInt64(Int.max),
                let systemNumber = attributes[.systemNumber] as? NSNumber,
                let fileNumber = attributes[.systemFileNumber] as? NSNumber,
                let reader = try? FileHandle(forReadingFrom: url) else {
                    continue
                }
                captures.append(.init(
                    size: Int(sizeNumber.uint64Value),
                    readHandle: reader,
                    lineage: .init(
                        path: url.standardizedFileURL.path,
                        systemNumber: systemNumber.uint64Value,
                        fileNumber: fileNumber.uint64Value,
                        structuralGeneration: capturedStructuralGeneration,
                        cacheEpoch: capturedCacheEpoch
                    )
                ))
            }
        }
        lock.unlock()
        defer { captures.forEach { try? $0.readHandle.close() } }

        var byIdentity: [String: Point] = [:]
        // Newest-first lets the current-cycle reader and a wider global-ticket
        // reader rendezvous on their overlapping hot shard before the wider
        // reader spends time on older retained buckets. Final ordering remains
        // the exact timestamp/identity sort below.
        for capture in captures.reversed() {
            guard let decoded = decodedPrefixPoints(for: capture) else {
                continue
            }
            let capturedRecordBytes = capture.size
                - capture.size % Self.recordSize
            for decodedPoint in decoded where
                decodedPoint.recordEndOffset <= capturedRecordBytes {
                let point = decodedPoint.point
                guard point.timestamp >= start.timeIntervalSince1970,
                      point.timestamp <= end.timeIntervalSince1970 else {
                    continue
                }
                byIdentity[point.identity] = point
            }
        }

        // Append-only growth preserves every captured prefix. Any other
        // lineage change revokes the whole query instead of publishing a mix
        // of pre- and post-repair shards.
        lock.lock()
        let capturedPrefixesRemainValid =
            structuralGeneration == capturedStructuralGeneration
        lock.unlock()
        guard capturedPrefixesRemainValid else { return [] }

        return byIdentity.values.sorted {
            if $0.timestamp != $1.timestamp {
                return $0.timestamp < $1.timestamp
            }
            return $0.identity < $1.identity
        }
    }

    /// Called only while the store mutation lock is held. Lock ordering is
    /// always store -> decoded-prefix condition; decoder owners never acquire
    /// the store lock while holding the condition.
    private func decodedPrefixCacheEpochSnapshotLocked() -> UInt64 {
        decodedPrefixCondition.lock()
        defer { decodedPrefixCondition.unlock() }
        return decodedPrefixCacheEpoch
    }

    /// Returns points for the caller's immutable file descriptor/prefix. One
    /// owner decodes a physical shard lineage at a time; same-prefix callers
    /// wait and reuse, while append-grown callers decode only the fixed-width
    /// suffix after the previous owner publishes its prefix.
    private func decodedPrefixPoints(
        for capture: CapturedDecodedPrefix
    ) -> [DecodedPrefixPoint]? {
        while true {
            decodedPrefixCondition.lock()
            guard capture.lineage.cacheEpoch == decodedPrefixCacheEpoch else {
                decodedPrefixCondition.unlock()
                return nil
            }
            decodedPrefixAccessCounter &+= 1
            let access = decodedPrefixAccessCounter
            if var cached = decodedPrefixCache[capture.lineage],
               cached.capturedByteCount >= capture.size {
                cached.lastAccess = access
                decodedPrefixCache[capture.lineage] = cached
                let points = cached.points
                decodedPrefixCondition.unlock()
                return points
            }
            if decodedPrefixDecoders.contains(capture.lineage) {
#if DEBUG
                decodedPrefixWaitCountForTesting &+= 1
#endif
                decodedPrefixCondition.wait()
                decodedPrefixCondition.unlock()
                continue
            }

            let cachedBase = decodedPrefixCache[capture.lineage].flatMap {
                $0.capturedByteCount < capture.size
                    && $0.capturedByteCount % Self.recordSize == 0
                    && capture.size % Self.recordSize == 0
                    ? $0 : nil
            }
            decodedPrefixDecoders.insert(capture.lineage)
#if DEBUG
            decodedPrefixDecodePassCountForTesting &+= 1
            let decodeHook = decodedPrefixDecodeHookForTesting
#endif
            decodedPrefixCondition.unlock()

            let startOffset = cachedBase?.capturedByteCount ?? 0
#if DEBUG
            decodeHook?(
                capture.lineage.path,
                startOffset,
                capture.size
            )
#endif
            let materialized = materializeDecodedPrefix(
                capture,
                cachedBase: cachedBase
            )

            decodedPrefixCondition.lock()
            decodedPrefixDecoders.remove(capture.lineage)
            let epochRemainsCurrent =
                capture.lineage.cacheEpoch == decodedPrefixCacheEpoch
            if var materialized, epochRemainsCurrent {
                decodedPrefixAccessCounter &+= 1
                materialized.lastAccess = decodedPrefixAccessCounter
                admitDecodedPrefixCacheEntry(
                    materialized,
                    lineage: capture.lineage
                )
            }
            decodedPrefixCondition.broadcast()
            decodedPrefixCondition.unlock()
            return epochRemainsCurrent ? materialized?.points : nil
        }
    }

    /// Reads only the exact bytes absent from a validated cached prefix. The
    /// descriptor was opened while the store lock captured its byte count, so
    /// later appends cannot leak into this read.
    private func materializeDecodedPrefix(
        _ capture: CapturedDecodedPrefix,
        cachedBase: DecodedPrefixCacheEntry?
    ) -> DecodedPrefixCacheEntry? {
        let startOffset = cachedBase?.capturedByteCount ?? 0
        guard startOffset >= 0, startOffset <= capture.size else {
            return nil
        }
        var data = Data()
        data.reserveCapacity(capture.size - startOffset)
        do {
            try capture.readHandle.seek(toOffset: UInt64(startOffset))
            while data.count < capture.size - startOffset {
                guard let chunk = try capture.readHandle.read(
                    upToCount: min(
                        capture.size - startOffset - data.count,
                        256 * 1_024
                    )
                ), !chunk.isEmpty else {
                    break
                }
                data.append(chunk)
            }
        } catch {
            return nil
        }
        guard data.count == capture.size - startOffset else { return nil }
        let suffix = Self.decode(
            data,
            startingAtByteOffset: startOffset
        )
        return .init(
            capturedByteCount: capture.size,
            points: (cachedBase?.points ?? []) + suffix,
            lastAccess: 0
        )
    }

    /// Must be called with `decodedPrefixCondition` held.
    private func admitDecodedPrefixCacheEntry(
        _ entry: DecodedPrefixCacheEntry,
        lineage: DecodedPrefixLineage
    ) {
        let budget = decodedPrefixCacheBudget
        guard budget.maximumEntries > 0,
              entry.capturedByteCount <= budget.maximumSourceBytes,
              entry.points.count <= budget.maximumPoints else {
            return
        }
        decodedPrefixCache[lineage] = entry
        while decodedPrefixCache.count > budget.maximumEntries
                || decodedPrefixCache.values.reduce(0, {
                    $0 + $1.capturedByteCount
                }) > budget.maximumSourceBytes
                || decodedPrefixCache.values.reduce(0, {
                    $0 + $1.points.count
                }) > budget.maximumPoints {
            guard let victim = decodedPrefixCache.min(by: {
                if $0.value.lastAccess != $1.value.lastAccess {
                    return $0.value.lastAccess < $1.value.lastAccess
                }
                if $0.key.path != $1.key.path {
                    return $0.key.path < $1.key.path
                }
                return $0.value.capturedByteCount
                    < $1.value.capturedByteCount
            })?.key else {
                break
            }
            decodedPrefixCache.removeValue(forKey: victim)
        }
    }

    private func prepareDirectoryLocked(currentBucket: Int64) throws {
        guard preparedRetentionBucket != currentBucket else { return }
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let minimumBucket =
            currentBucket - Self.retainedBucketCount + 1
        let urls = (try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        )) ?? []
        for url in urls {
            guard let bucket = Self.bucket(from: url.lastPathComponent),
                  bucket < minimumBucket else {
                continue
            }
            if let handle = handles.removeValue(forKey: url.path) {
                try? handle.close()
            }
            do {
                try fileManager.removeItem(at: url)
                // The identity index mirrors only retained shards. Keeping
                // digests from deleted buckets would make memory grow for the
                // lifetime of the process and would falsely reject a later
                // canonical rebuild of that payload.
                knownIdentities = nil
                invalidatePrefixAuthoritiesLocked()
            } catch {
                // Retention is best effort. If deletion failed, the shard and
                // its identities remain part of the retained source.
            }
        }
        preparedRetentionBucket = currentBucket
    }

    private func loadKnownIdentitiesLocked() throws {
        guard knownIdentities == nil else { return }
        var identities = Set<Data>()
        let urls = (try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        )) ?? []
        for url in urls where url.pathExtension == "bin" {
            try repairPartialTailLocked(at: url)
            guard let data = try? Data(
                contentsOf: url,
                options: .mappedIfSafe
            ) else {
                continue
            }
            // First append after every launch used to fully decode every
            // retained point, format its 16-byte digest as 32 hex characters,
            // then parse those characters back into Data. On a physical store
            // with four retained shards that consumed a full CPU for seconds
            // before one new history row could land. The identity index needs
            // only the fixed-width digest. Validate the same record fields as
            // the projection decoder, then copy bytes 36..<52 directly.
            Self.decodeKnownIdentities(data, into: &identities)
        }
        knownIdentities = identities
    }

    private func handleLocked(filename: String) throws -> FileHandle {
        let url = directoryURL.appendingPathComponent(filename)
        if let existing = handles[url.path] {
            return existing
        }
        let created: Bool
        if !fileManager.fileExists(atPath: url.path) {
            guard fileManager.createFile(atPath: url.path, contents: nil)
            else {
                throw CocoaError(.fileWriteUnknown)
            }
            created = true
        } else {
            created = false
        }
        if created {
            invalidatePrefixAuthoritiesLocked()
        }
        try repairPartialTailLocked(at: url)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        handles[url.path] = handle
        return handle
    }

    /// A write error can arrive after FileHandle has committed only a prefix
    /// of one fixed-width record. Remove only that shard's descriptor before
    /// closing it so no later append can reuse its post-partial-write offset.
    /// The next `handleLocked` call must therefore repair the tail first.
    private func retirePoisonedHandleLocked(filename: String) {
        let url = directoryURL.appendingPathComponent(filename)
        guard let poisoned = handles.removeValue(forKey: url.path) else {
            return
        }
        try? poisoned.close()
    }

    private func writeRecordLocked(
        _ data: Data,
        to handle: FileHandle
    ) throws {
#if DEBUG
        if let appendWriteHookForTesting {
            try appendWriteHookForTesting(handle, data)
            return
        }
#endif
        try handle.write(contentsOf: data)
    }

    /// A process can be killed after only a prefix of one fixed-width record
    /// reaches the filesystem. Never append behind that torn tail: doing so
    /// shifts every later record away from the 52-byte decode boundary. The
    /// compact store is a rebuildable derivative, so truncating only the
    /// incomplete suffix is the loss-minimizing repair.
    private func repairPartialTailLocked(at url: URL) throws {
        guard let attributes = try? fileManager.attributesOfItem(
            atPath: url.path
        ),
        let number = attributes[.size] as? NSNumber else {
            return
        }
        let size = number.uint64Value
        let remainder = size % UInt64(Self.recordSize)
        guard remainder > 0 else { return }
        let repairedSize = size - remainder
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: repairedSize)
        // Truncate is the lineage change. Revoke before fsync so an fsync
        // failure cannot leave an authority alive for the already-shortened
        // prefix.
        invalidatePrefixAuthoritiesLocked()
#if DEBUG
        try tailRepairWillSynchronizeHookForTesting?()
#endif
        try handle.synchronize()
    }

    /// Must be called while `lock` is held. Append-only growth intentionally
    /// does not revoke a prefix snapshot; only lineage-changing filesystem
    /// operations call this helper.
    private func invalidatePrefixAuthoritiesLocked() {
        structuralGeneration &+= 1
        commitAuthorities.removeAll(keepingCapacity: true)
        // The mutation lock is held here. Decoder owners never acquire it
        // while holding `decodedPrefixCondition`, so this one-way lock order
        // cannot deadlock an in-flight read. Old owners may finish for their
        // captured descriptor, but the epoch check prevents reinsertion.
        decodedPrefixCondition.lock()
        decodedPrefixCacheEpoch &+= 1
        decodedPrefixCache.removeAll(keepingCapacity: true)
        decodedPrefixCondition.broadcast()
        decodedPrefixCondition.unlock()
    }

    private static func encode(
        timestamp: TimeInterval,
        flash: UInt32,
        tick: Int,
        gravityX: Double,
        gravityY: Double,
        gravityZ: Double,
        scalar: Double?,
        identityDigest: Data
    ) -> Data {
        var data = Data(capacity: recordSize)
        append(recordMagic, to: &data)
        append(timestamp.bitPattern, to: &data)
        append(flash, to: &data)
        append(UInt32(bitPattern: Int32(tick)), to: &data)
        append(Float(gravityX).bitPattern, to: &data)
        append(Float(gravityY).bitPattern, to: &data)
        append(Float(gravityZ).bitPattern, to: &data)
        append(Float(scalar ?? .nan).bitPattern, to: &data)
        data.append(identityDigest.prefix(16))
        return data
    }

    private static func decode(
        _ data: Data,
        startingAtByteOffset: Int
    ) -> [DecodedPrefixPoint] {
        guard data.count >= recordSize else { return [] }
        var result: [DecodedPrefixPoint] = []
        result.reserveCapacity(data.count / recordSize)
        for offset in stride(
            from: 0,
            to: data.count - (data.count % recordSize),
            by: recordSize
        ) {
            let timestamp = Double(
                bitPattern: uint64(data, at: offset + 4)
            )
            let flash = uint32(data, at: offset + 12)
            let tick = Int(
                Int32(bitPattern: uint32(data, at: offset + 16))
            )
            let gravityX = Double(
                Float(bitPattern: uint32(data, at: offset + 20))
            )
            let gravityY = Double(
                Float(bitPattern: uint32(data, at: offset + 24))
            )
            let gravityZ = Double(
                Float(bitPattern: uint32(data, at: offset + 28))
            )
            let scalarFloat = Float(
                bitPattern: uint32(data, at: offset + 32)
            )
            let digest = Data(data[(offset + 36)..<(offset + 52)])
            guard isValidRecord(
                data,
                at: offset,
                timestamp: timestamp,
                tick: tick,
                gravityX: gravityX,
                gravityY: gravityY,
                gravityZ: gravityZ
            ) else {
                continue
            }
            result.append(
                .init(
                    recordEndOffset:
                        startingAtByteOffset + offset + recordSize,
                    point: .init(
                        timestamp: timestamp,
                        flash: flash,
                        tick: tick,
                        gravityX: gravityX,
                        gravityY: gravityY,
                        gravityZ: gravityZ,
                        unknownMotionScalar32:
                            scalarFloat.isFinite
                                ? Double(scalarFloat) : nil,
                        identity: lowercaseHexString(digest)
                    )
                )
            )
        }
        return result
    }

    /// `String(format:)` crosses Foundation/CF formatting for every byte of
    /// every row. The late physical profile attributed several CPU-seconds per
    /// pass to that conversion alone. This fixed lookup is byte-for-byte the
    /// same lowercase identity with one bounded UTF-8 allocation.
    private static func lowercaseHexString(_ data: Data) -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(data.count * 2)
        for byte in data {
            bytes.append(lowercaseHexAlphabet[Int(byte >> 4)])
            bytes.append(lowercaseHexAlphabet[Int(byte & 0x0f)])
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Allocation-bounded retained-shard index rebuild. This deliberately
    /// shares the decoder's full validity predicate: a magic word alone never
    /// suppresses canonical repair of a corrupt compact record.
    private static func decodeKnownIdentities(
        _ data: Data,
        into result: inout Set<Data>
    ) {
        guard data.count >= recordSize else { return }
        result.reserveCapacity(result.count + data.count / recordSize)
        for offset in stride(
            from: 0,
            to: data.count - (data.count % recordSize),
            by: recordSize
        ) {
            let timestamp = Double(
                bitPattern: uint64(data, at: offset + 4)
            )
            let tick = Int(
                Int32(bitPattern: uint32(data, at: offset + 16))
            )
            let gravityX = Double(
                Float(bitPattern: uint32(data, at: offset + 20))
            )
            let gravityY = Double(
                Float(bitPattern: uint32(data, at: offset + 24))
            )
            let gravityZ = Double(
                Float(bitPattern: uint32(data, at: offset + 28))
            )
            guard isValidRecord(
                data,
                at: offset,
                timestamp: timestamp,
                tick: tick,
                gravityX: gravityX,
                gravityY: gravityY,
                gravityZ: gravityZ
            ) else {
                continue
            }
            result.insert(Data(data[(offset + 36)..<(offset + 52)]))
        }
    }

    private static func isValidRecord(
        _ data: Data,
        at offset: Int,
        timestamp: TimeInterval,
        tick: Int,
        gravityX: Double,
        gravityY: Double,
        gravityZ: Double
    ) -> Bool {
        uint32(data, at: offset) == recordMagic
            && timestamp.isFinite
            && timestamp > 0
            && (0...65_535).contains(tick)
            && gravityX.isFinite
            && gravityY.isFinite
            && gravityZ.isFinite
    }

    private static func append<T: FixedWidthInteger>(
        _ value: T,
        to data: inout Data
    ) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) {
            data.append(contentsOf: $0)
        }
    }

    private static func identityDigest(
        rawPayload: [UInt8],
        strapIdentifier: String
    ) -> Data {
        var material = Data(strapIdentifier.uppercased().utf8)
        material.append(0)
        material.append(contentsOf: rawPayload)
        return Data(SHA256.hash(data: material).prefix(16))
    }

    private static func uint32(_ data: Data, at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        return data[offset..<(offset + 4)].enumerated().reduce(0) {
            $0 | UInt32($1.element) << UInt32($1.offset * 8)
        }
    }

    private static func uint64(_ data: Data, at offset: Int) -> UInt64 {
        guard offset >= 0, offset + 8 <= data.count else { return 0 }
        return data[offset..<(offset + 8)].enumerated().reduce(0) {
            $0 | UInt64($1.element) << UInt64($1.offset * 8)
        }
    }

    private static func bucket(for timestamp: TimeInterval) -> Int64 {
        Int64(floor(timestamp / secondsPerBucket))
    }

    private static func filename(
        strapIdentifier: String,
        bucket: Int64
    ) -> String {
        "v\(schema)-\(strapIdentifier.uppercased())-\(bucket).bin"
    }

    private static func bucket(from filename: String) -> Int64? {
        guard filename.hasPrefix("v\(schema)-"),
              filename.hasSuffix(".bin"),
              let value = filename
                .dropLast(4)
                .split(separator: "-")
                .last else {
            return nil
        }
        return Int64(value)
    }

    private static func merge(_ intervals: [DateInterval])
        -> [DateInterval] {
        let sorted = intervals.filter {
            $0.end > $0.start
        }.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.end < $1.end
        }
        var result: [DateInterval] = []
        for interval in sorted {
            guard let last = result.last else {
                result.append(interval)
                continue
            }
            if interval.start <= last.end {
                result[result.count - 1] = .init(
                    start: last.start,
                    end: max(last.end, interval.end)
                )
            } else {
                result.append(interval)
            }
        }
        return result
    }
}
