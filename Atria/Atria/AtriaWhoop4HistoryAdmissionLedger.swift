import CryptoKit
import Foundation
import SQLite3

/// Exact, disk-backed admission authority for WHOOP 4 full-flash history.
///
/// WHOOP 4 may replay the beginning of flash after an app restart or a lost
/// HISTORY_END ACK.  The BLE reducer must classify those replays *before* it
/// changes its sequence cursor.  Keeping every accepted payload in a Swift Set
/// made that ordering exact but made memory proportional to the whole drain.
///
/// This ledger stores the complete payload as a SQLite BLOB, scoped by strap.
/// SQLite's B-tree performs exact equality (the SHA-256-sized shortcuts used by
/// other stores are deliberately not sufficient here), while a small negative
/// page cache keeps resident memory bounded.  `synchronous=FULL` makes a newly
/// inserted admission durable before `classify` returns `.firstSeen`.
///
/// Raw archive durability remains a separate state.  A row is promoted to
/// `archiveDurable` only after the archive and its identity index have fsynced.
/// Therefore a crash between admission and archive persistence returns
/// `.needsPersistence` on replay and can never turn a write-ahead identity into
/// data loss or a premature strap ACK.
// SAFETY: every SQLite operation and mutable connection access is serialized
// by `lock`; the connection itself is opened with SQLITE_OPEN_FULLMUTEX.
final class AtriaWhoop4HistoryAdmissionLedger: @unchecked Sendable {
    typealias RetiredReplayLookup = (_ strapIdentifier: String, _ frame: Data) throws -> Bool
    static let productionIdentityRetention: TimeInterval = 14 * 24 * 60 * 60
    /// The admission ledger stores complete WHOOP frames as SQLite BLOBs, so a
    /// frame-count budget also has to be a realistic on-device byte budget.
    /// 96k rows retains ample exact replay authority after a completed drain
    /// while keeping the derived ledger materially below the raw-history
    /// budget.  This is deliberately *not* a hard deletion limit: active or
    /// not-yet-archive-durable rows remain protected above it and are reported
    /// as pressure rather than discarded.
    static let productionMaximumIdentityRows = 96_000
    static let maximumClassificationBatch = 256
    /// Covers the maximum 13-day recovery window (1,123,200 one-Hz rows) with
    /// headroom. Enumeration is streaming, so this is a safety ceiling rather
    /// than a resident-memory allocation. Post-proof retention remains lower.
    static let productionMaximumDurableFrameEnumeration = 1_500_000

    struct Attempt: Equatable, Sendable {
        let identifier: String
        let strapIdentifier: String
        let incarnation: String
    }

    enum Classification: Equatable, Sendable {
        /// First exact observation on this strap. The admission row is already
        /// durable, but its raw archive row is not yet durable.
        case firstSeen(ordinal: UInt64)
        /// An earlier process/attempt admitted this exact frame but never
        /// crossed a raw archive durability boundary. It must be persisted.
        case needsPersistence(ordinal: UInt64)
        /// A prior archive durability boundary covered this exact frame. This
        /// is safe to use only for prefix rehydration/duplicate suppression.
        case durableReplay(ordinal: UInt64)
        /// The same logical attempt incarnation already classified the frame.
        /// Its original callback owns any outstanding persistence completion.
        case duplicateInCurrentIncarnation(ordinal: UInt64)

        var reducerAdmission: AtriaWhoop4HistoryDrainState.Admission {
            switch self {
            case .firstSeen: return .firstSeen
            case .needsPersistence: return .needsPersistence
            case .durableReplay: return .durableReplay
            case .duplicateInCurrentIncarnation: return .duplicateInCurrentIncarnation
            }
        }

        var ordinal: UInt64 {
            switch self {
            case .firstSeen(let ordinal),
                 .needsPersistence(let ordinal),
                 .durableReplay(let ordinal),
                 .duplicateInCurrentIncarnation(let ordinal):
                return ordinal
            }
        }
    }

    enum LedgerError: Error, Equatable {
        case open(Int32)
        case sqlite(code: Int32, operation: String)
        case staleAttempt
        case invalidIdentity
        case ordinalOverflow
        case classificationBatchTooLarge(maximum: Int)
        case archiveDurabilityReceiptRequired
        case invalidArchiveDurabilityReceipt
        case reusedArchiveDurabilityReceipt
        case durablePrefixReceiptMismatch
        case durableFrameEnumerationLimitExceeded(maximum: Int)
    }

    struct PruneResult: Equatable, Sendable {
        let removedForAge: Int
        let removedForCount: Int
        let remainingRows: Int
        /// Nonzero means active-attempt or not-yet-archive-durable rows alone
        /// exceed the requested bound. They are intentionally retained: disk
        /// pressure can delay work, but can never authorize data loss.
        let protectedRowsAboveLimit: Int

        var deletedRows: Int { removedForAge + removedForCount }
    }

    struct PrefixDurabilityReceipt: Codable, Equatable, Sendable {
        let storeIdentifier: String
        let snapshotSHA256: String
        let durableSequence: UInt64
        /// `nil` is the explicit no-frame boundary (`durable_ordinal == -1`).
        /// It must never be represented as ordinal zero, because the first
        /// later frame still owns ordinal zero.
        let durableOrdinal: UInt64?
        let recordCount: UInt64
        let byteCount: UInt64
        let fsyncedAtUnix: TimeInterval
        let rawArchiveSnapshotSHA256: String
        let identityIndexSnapshotSHA256: String
        let archiveReceiptChainSHA256: String
    }

    struct DurableFrameEnumerationReport: Equatable, Sendable {
        let attemptIdentifier: String
        let strapIdentifier: String
        let durableOrdinal: UInt64?
        let recordCount: UInt64
        let byteCount: UInt64
        let orderedFramesSHA256: String
    }

    private let lock = NSLock()
    private let databaseURL: URL
    private let durabilityNow: () -> Date
    private let retiredReplayLookup: RetiredReplayLookup
    private var database: OpaquePointer?

    init(databaseURL: URL,
         pageCacheKiB: Int = 2_048,
         unsafeDisableDurabilityForTests: Bool = false,
         durabilityNow: @escaping () -> Date = Date.init,
         retiredReplayLookup: @escaping RetiredReplayLookup = { _, _ in false }) throws {
        self.databaseURL = databaseURL.standardizedFileURL
        self.durabilityNow = durabilityNow
        self.retiredReplayLookup = retiredReplayLookup
        let databaseAlreadyExisted = FileManager.default.fileExists(
            atPath: self.databaseURL.path
        )
        try FileManager.default.createDirectory(
            at: self.databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var opened: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let code = sqlite3_open_v2(self.databaseURL.path, &opened, flags, nil)
        guard code == SQLITE_OK, let opened else {
            if let opened { sqlite3_close_v2(opened) }
            throw LedgerError.open(code)
        }
        database = opened
        do {
            try execute("PRAGMA journal_mode=WAL")
            try execute(unsafeDisableDurabilityForTests
                        ? "PRAGMA synchronous=OFF"
                        : "PRAGMA synchronous=FULL")
            try execute("PRAGMA temp_store=FILE")
            try execute("PRAGMA foreign_keys=ON")
            try execute("PRAGMA busy_timeout=5000")
            try execute("PRAGMA wal_autocheckpoint=256")
            try execute("PRAGMA cache_size=-\(max(256, pageCacheKiB))")
            try execute("PRAGMA auto_vacuum=INCREMENTAL")
            if !databaseAlreadyExisted {
                try execute("VACUUM")
            }
            try execute("""
                CREATE TABLE IF NOT EXISTS history_attempt (
                    id TEXT PRIMARY KEY NOT NULL,
                    strap_id TEXT NOT NULL,
                    incarnation TEXT NOT NULL,
                    state INTEGER NOT NULL,
                    next_ordinal INTEGER NOT NULL,
                    durable_ordinal INTEGER NOT NULL,
                    created_unix REAL NOT NULL,
                    updated_unix REAL NOT NULL
                ) WITHOUT ROWID
                """)
            try execute("""
                CREATE INDEX IF NOT EXISTS history_attempt_resume
                ON history_attempt(strap_id, state, updated_unix DESC)
                """)
            try execute("""
                CREATE TABLE IF NOT EXISTS history_frame (
                    strap_id TEXT NOT NULL,
                    frame BLOB NOT NULL,
                    first_attempt_id TEXT NOT NULL,
                    first_ordinal INTEGER NOT NULL,
                    last_attempt_id TEXT NOT NULL,
                    last_incarnation TEXT NOT NULL,
                    last_ordinal INTEGER NOT NULL,
                    archive_durable INTEGER NOT NULL,
                    last_seen_unix REAL NOT NULL,
                    PRIMARY KEY(strap_id, frame)
                ) WITHOUT ROWID
                """)
            try execute("""
                CREATE INDEX IF NOT EXISTS history_frame_attempt_prefix
                ON history_frame(last_attempt_id, last_ordinal, archive_durable)
                """)
            try execute("""
                CREATE INDEX IF NOT EXISTS history_frame_retention
                ON history_frame(archive_durable, last_seen_unix)
                """)
            try execute("""
                CREATE TABLE IF NOT EXISTS history_archive_receipt (
                    chain_digest TEXT PRIMARY KEY NOT NULL,
                    attempt_id TEXT NOT NULL,
                    durable_sequence INTEGER NOT NULL,
                    promoted_ordinal INTEGER NOT NULL,
                    raw_digest TEXT NOT NULL,
                    identity_digest TEXT NOT NULL,
                    prefix_digest TEXT NOT NULL,
                    record_count INTEGER NOT NULL,
                    byte_count INTEGER NOT NULL,
                    created_unix REAL NOT NULL
                ) WITHOUT ROWID
                """)
            try execute("""
                CREATE INDEX IF NOT EXISTS history_archive_receipt_attempt_sequence
                ON history_archive_receipt(attempt_id, durable_sequence)
                """)
        } catch {
            sqlite3_close_v2(opened)
            database = nil
            throw error
        }
    }

    deinit {
        if let database { sqlite3_close_v2(database) }
    }

    /// Resumes only an interrupted attempt. Completed/failed attempts remain
    /// immutable evidence, and a later full-flash request gets a new attempt.
    func beginAttempt(strapIdentifier: String, now: Date = Date()) throws -> Attempt {
        guard !strapIdentifier.isEmpty else { throw LedgerError.invalidIdentity }
        lock.lock()
        defer { lock.unlock() }
        return try transaction {
            let incarnation = UUID().uuidString.lowercased()
            if let identifier = try resumableAttemptID(strapIdentifier: strapIdentifier) {
                try execute(
                    "UPDATE history_attempt SET incarnation = ?, updated_unix = ? WHERE id = ? AND state = 0",
                    bindings: [.text(incarnation), .double(now.timeIntervalSince1970), .text(identifier)]
                )
                return Attempt(identifier: identifier,
                               strapIdentifier: strapIdentifier,
                               incarnation: incarnation)
            }
            let identifier = UUID().uuidString.lowercased()
            try execute(
                """
                INSERT INTO history_attempt
                (id, strap_id, incarnation, state, next_ordinal, durable_ordinal, created_unix, updated_unix)
                VALUES (?, ?, ?, 0, 0, -1, ?, ?)
                """,
                bindings: [
                    .text(identifier), .text(strapIdentifier), .text(incarnation),
                    .double(now.timeIntervalSince1970), .double(now.timeIntervalSince1970)
                ]
            )
            return Attempt(identifier: identifier,
                           strapIdentifier: strapIdentifier,
                           incarnation: incarnation)
        }
    }

    /// Inserts/looks up one complete frame in a FULL-synchronous transaction.
    /// This method is intentionally safe under competing ledger instances: the
    /// exact primary key and `BEGIN IMMEDIATE` serialize first admission.
    func classify(frame: Data, attempt: Attempt, now: Date = Date()) throws -> Classification {
        guard let result = try classify(frames: [frame], attempt: attempt, now: now).first else {
            throw LedgerError.invalidIdentity
        }
        return result
    }

    /// Group-commits a bounded notification burst. Every returned admission is
    /// durable before the method returns, so callers may then reduce the frames
    /// in the same order. This amortizes one device fsync across up to 256
    /// frames without permitting unbounded callback buffering.
    func classify(
        frames: [Data],
        attempt: Attempt,
        now: Date = Date()
    ) throws -> [Classification] {
        guard frames.count <= Self.maximumClassificationBatch else {
            throw LedgerError.classificationBatchTooLarge(
                maximum: Self.maximumClassificationBatch
            )
        }
        guard frames.allSatisfy({ !$0.isEmpty }) else { throw LedgerError.invalidIdentity }
        guard !frames.isEmpty else { return [] }
        lock.lock()
        defer { lock.unlock() }
        return try transaction {
            guard try attemptIsCurrent(attempt) else { throw LedgerError.staleAttempt }
            return try frames.map {
                try classifyLocked(frame: $0, attempt: attempt, now: now)
            }
        }
    }

    private func classifyLocked(frame: Data,
                                attempt: Attempt,
                                now: Date) throws -> Classification {
        let ordinal = try reserveOrdinal(attempt: attempt, now: now)
        if let existing = try frameState(strapIdentifier: attempt.strapIdentifier,
                                         frame: frame) {
            if existing.lastAttemptID == attempt.identifier,
               existing.lastIncarnation == attempt.incarnation {
                // Do not consume a second ordinal for a duplicate callback.
                try execute(
                    "UPDATE history_attempt SET next_ordinal = ?, updated_unix = ? WHERE id = ?",
                    bindings: [
                        .int64(Int64(ordinal)), .double(now.timeIntervalSince1970),
                        .text(attempt.identifier)
                    ]
                )
                return .duplicateInCurrentIncarnation(ordinal: existing.lastOrdinal)
            }
            try execute(
                """
                UPDATE history_frame
                SET last_attempt_id = ?, last_incarnation = ?, last_ordinal = ?, last_seen_unix = ?
                WHERE strap_id = ? AND frame = ?
                """,
                bindings: [
                    .text(attempt.identifier), .text(attempt.incarnation), .int64(Int64(ordinal)),
                    .double(now.timeIntervalSince1970), .text(attempt.strapIdentifier), .blob(frame)
                ]
            )
            return existing.archiveDurable
                ? .durableReplay(ordinal: ordinal)
                : .needsPersistence(ordinal: ordinal)
        }
        let isRetiredReplay = try retiredReplayLookup(attempt.strapIdentifier, frame)
        try execute(
            """
            INSERT INTO history_frame
            (strap_id, frame, first_attempt_id, first_ordinal, last_attempt_id,
             last_incarnation, last_ordinal, archive_durable, last_seen_unix)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            bindings: [
                .text(attempt.strapIdentifier), .blob(frame), .text(attempt.identifier),
                .int64(Int64(ordinal)), .text(attempt.identifier),
                .text(attempt.incarnation), .int64(Int64(ordinal)),
                .int64(isRetiredReplay ? 1 : 0),
                .double(now.timeIntervalSince1970)
            ]
        )
        return isRetiredReplay
            ? .durableReplay(ordinal: ordinal)
            : .firstSeen(ordinal: ordinal)
    }

    /// Promotes the exact prefix only after raw archive + archive identity
    /// index synchronization. Its own FULL transaction must succeed before the
    /// reducer is told that the durability boundary completed and may ACK.
    @discardableResult
    func markCurrentPrefixArchiveDurable(
        attempt: Attempt,
        through ordinal: UInt64,
        now: Date = Date()
    ) throws -> Int {
        // There is no safe compatibility fallback: an admission row alone
        // proves only write-ahead identity, never raw archive durability.
        throw LedgerError.archiveDurabilityReceiptRequired
    }

    @discardableResult
    func markCurrentPrefixArchiveDurableWithReceipt(
        attempt: Attempt,
        through ordinal: UInt64,
        archiveReceipt: AtriaHistoricalArchiveDurableStore.FlushReceipt,
        now: Date = Date()
    ) throws -> (changedRows: Int, receipt: PrefixDurabilityReceipt) {
        guard archiveReceipt.isPromotionAuthority else {
            throw LedgerError.invalidArchiveDurabilityReceipt
        }
        lock.lock()
        defer { lock.unlock() }
        let committed = try transaction {
            guard try attemptIsCurrent(attempt) else { throw LedgerError.staleAttempt }
            let pending = try scalarInt(
                """
                SELECT COUNT(*) FROM history_frame
                WHERE last_attempt_id = ? AND last_ordinal <= ? AND archive_durable = 0
                """,
                bindings: [.text(attempt.identifier), .int64(Int64(ordinal))]
            )
            let pendingIdentitySnapshot = try pendingArchiveIdentitySnapshot(
                attempt: attempt,
                through: ordinal
            )
            // A replay-only or empty-tail seal may advance ordering and ACK an
            // already-durable prefix. A crash after raw+identity fsync but
            // before this SQLite promotion leaves positive admission rows
            // pending while the archive correctly reports them as durable
            // replay duplicates on retry. Reconcile that split boundary only
            // when the receipt proves the exact full-payload identity set;
            // counts alone must never authorize promotion.
            let newlyDurableCountCoversPending =
                archiveReceipt.raw.recordCount >= UInt64(pending)
                    && archiveReceipt.identity.recordCount >= UInt64(pending)
            let exactReplaySetCoversPending = pending > 0
                && archiveReceipt.raw.recordCount == archiveReceipt.identity.recordCount
                && archiveReceipt.raw.observedIdentityCount == UInt64(pending)
                && archiveReceipt.identity.observedIdentityCount == UInt64(pending)
                && archiveReceipt.raw.batchKeysSHA256 == pendingIdentitySnapshot.sha256
                && archiveReceipt.identity.batchKeysSHA256 == pendingIdentitySnapshot.sha256
            guard pending == 0
                    || newlyDurableCountCoversPending
                    || exactReplaySetCoversPending else {
                throw LedgerError.invalidArchiveDurabilityReceipt
            }
            if try scalarInt(
                "SELECT COUNT(*) FROM history_archive_receipt WHERE chain_digest = ?",
                bindings: [.text(archiveReceipt.receiptChainSHA256)]
            ) > 0 {
                throw LedgerError.reusedArchiveDurabilityReceipt
            }
            let previous = try previousPrefixReceipt(attemptID: attempt.identifier)
            guard archiveReceipt.durableSequence > UInt64(previous?.durableSequence ?? 0) else {
                throw LedgerError.invalidArchiveDurabilityReceipt
            }
            if let previous, previous.promotedOrdinal >= 0,
               ordinal < UInt64(previous.promotedOrdinal) {
                throw LedgerError.invalidArchiveDurabilityReceipt
            }
            try execute(
                """
                UPDATE history_frame SET archive_durable = 1
                WHERE last_attempt_id = ? AND last_ordinal <= ? AND archive_durable = 0
                """,
                bindings: [.text(attempt.identifier), .int64(Int64(ordinal))]
            )
            let changed = Int(sqlite3_changes(database))
            try execute(
                """
                UPDATE history_attempt
                SET durable_ordinal = MAX(durable_ordinal, ?), updated_unix = ?
                WHERE id = ?
                """,
                bindings: [
                    .int64(Int64(ordinal)), .double(now.timeIntervalSince1970),
                    .text(attempt.identifier)
                ]
            )
            let batchSnapshot = try admissionBatchSnapshot(
                attempt: attempt,
                after: previous.flatMap {
                    $0.promotedOrdinal >= 0 ? UInt64($0.promotedOrdinal) : nil
                },
                through: ordinal
            )
            let cumulativeRecordCount = (previous.map { UInt64($0.recordCount) } ?? 0)
                &+ batchSnapshot.recordCount
            let cumulativeByteCount = (previous.map { UInt64($0.byteCount) } ?? 0)
                &+ batchSnapshot.byteCount
            let prefixDigest = Self.boundPrefixDigest(
                previousPrefixSHA256: previous?.prefixDigest,
                admissionBatchSHA256: batchSnapshot.sha256,
                archiveReceipt: archiveReceipt,
                attempt: attempt,
                ordinal: ordinal
            )
            try execute(
                """
                INSERT INTO history_archive_receipt
                (chain_digest, attempt_id, durable_sequence, promoted_ordinal,
                 raw_digest, identity_digest, prefix_digest, record_count,
                 byte_count, created_unix)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                bindings: [
                    .text(archiveReceipt.receiptChainSHA256),
                    .text(attempt.identifier),
                    .int64(Int64(archiveReceipt.durableSequence)),
                    .int64(Int64(ordinal)),
                    .text(archiveReceipt.raw.snapshotSHA256),
                    .text(archiveReceipt.identity.snapshotSHA256),
                    .text(prefixDigest),
                    .int64(Int64(cumulativeRecordCount)),
                    .int64(Int64(cumulativeByteCount)),
                    .double(now.timeIntervalSince1970)
                ]
            )
            return (changedRows: changed,
                    prefixDigest: prefixDigest,
                    recordCount: cumulativeRecordCount,
                    byteCount: cumulativeByteCount)
        }
        // FULL-synchronous COMMIT has returned before this timestamp is read.
        let durableCompletedAtUnix = durabilityNow().timeIntervalSince1970
        return (committed.changedRows, PrefixDurabilityReceipt(
            storeIdentifier: "whoop4-exact-admission-sqlite-prefix-v2",
            snapshotSHA256: committed.prefixDigest,
            durableSequence: archiveReceipt.durableSequence,
            durableOrdinal: ordinal,
            recordCount: committed.recordCount,
            byteCount: committed.byteCount,
            fsyncedAtUnix: durableCompletedAtUnix,
            rawArchiveSnapshotSHA256: archiveReceipt.raw.snapshotSHA256,
            identityIndexSnapshotSHA256: archiveReceipt.identity.snapshotSHA256,
            archiveReceiptChainSHA256: archiveReceipt.receiptChainSHA256
        ))
    }

    /// Records a real archive durability boundary for an attempt that has not
    /// admitted any frame. This is ACK-ordering evidence only: it leaves both
    /// `next_ordinal` at zero and `durable_ordinal` at -1, publishes no positive
    /// row count, and cryptographically chains the exact zero-row archive seal.
    @discardableResult
    func recordEmptyArchiveDurabilityBoundary(
        attempt: Attempt,
        archiveReceipt: AtriaHistoricalArchiveDurableStore.FlushReceipt,
        now: Date = Date()
    ) throws -> PrefixDurabilityReceipt {
        guard archiveReceipt.isPromotionAuthority,
              archiveReceipt.raw.recordCount == 0,
              archiveReceipt.identity.recordCount == 0,
              archiveReceipt.raw.byteCount == 0,
              archiveReceipt.identity.byteCount == 0,
              archiveReceipt.raw.observedIdentityCount == 0,
              archiveReceipt.identity.observedIdentityCount == 0 else {
            throw LedgerError.invalidArchiveDurabilityReceipt
        }
        lock.lock()
        defer { lock.unlock() }
        let prefixDigest = try transaction {
            guard try attemptIsCurrent(attempt) else { throw LedgerError.staleAttempt }
            let attemptState = try attemptOrdinalState(attemptID: attempt.identifier)
            guard attemptState.nextOrdinal == 0,
                  attemptState.durableOrdinal == -1,
                  try scalarInt(
                    "SELECT COUNT(*) FROM history_frame WHERE last_attempt_id = ?",
                    bindings: [.text(attempt.identifier)]
                  ) == 0 else {
                throw LedgerError.invalidArchiveDurabilityReceipt
            }
            if try scalarInt(
                "SELECT COUNT(*) FROM history_archive_receipt WHERE chain_digest = ?",
                bindings: [.text(archiveReceipt.receiptChainSHA256)]
            ) > 0 {
                throw LedgerError.reusedArchiveDurabilityReceipt
            }
            let previous = try previousPrefixReceipt(attemptID: attempt.identifier)
            guard archiveReceipt.durableSequence > UInt64(previous?.durableSequence ?? 0),
                  (previous?.promotedOrdinal ?? -1) == -1,
                  (previous?.recordCount ?? 0) == 0,
                  (previous?.byteCount ?? 0) == 0 else {
                throw LedgerError.invalidArchiveDurabilityReceipt
            }
            let emptyBatchDigest = SHA256.hash(data: Data()).map {
                String(format: "%02x", $0)
            }.joined()
            let prefixDigest = Self.boundPrefixDigest(
                previousPrefixSHA256: previous?.prefixDigest,
                admissionBatchSHA256: emptyBatchDigest,
                archiveReceipt: archiveReceipt,
                attempt: attempt,
                ordinal: nil
            )
            try execute(
                """
                INSERT INTO history_archive_receipt
                (chain_digest, attempt_id, durable_sequence, promoted_ordinal,
                 raw_digest, identity_digest, prefix_digest, record_count,
                 byte_count, created_unix)
                VALUES (?, ?, ?, -1, ?, ?, ?, 0, 0, ?)
                """,
                bindings: [
                    .text(archiveReceipt.receiptChainSHA256),
                    .text(attempt.identifier),
                    .int64(Int64(archiveReceipt.durableSequence)),
                    .text(archiveReceipt.raw.snapshotSHA256),
                    .text(archiveReceipt.identity.snapshotSHA256),
                    .text(prefixDigest),
                    .double(now.timeIntervalSince1970)
                ]
            )
            return prefixDigest
        }
        let durableCompletedAtUnix = durabilityNow().timeIntervalSince1970
        return PrefixDurabilityReceipt(
            storeIdentifier: "whoop4-exact-admission-sqlite-prefix-v2",
            snapshotSHA256: prefixDigest,
            durableSequence: archiveReceipt.durableSequence,
            durableOrdinal: nil,
            recordCount: 0,
            byteCount: 0,
            fsyncedAtUnix: durableCompletedAtUnix,
            rawArchiveSnapshotSHA256: archiveReceipt.raw.snapshotSHA256,
            identityIndexSnapshotSHA256: archiveReceipt.identity.snapshotSHA256,
            archiveReceiptChainSHA256: archiveReceipt.receiptChainSHA256
        )
    }

    /// Streams only the exact frames owned by one durably receipted attempt
    /// prefix. The caller may reconstruct terminal coverage without scanning a
    /// catalog chunk that also contains stale rows from earlier attempts.
    /// Receipt ownership is verified from SQLite and does not depend on the
    /// volatile attempt incarnation, so this remains usable after restart.
    @discardableResult
    func enumerateDurableFrames(
        attemptIdentifier: String,
        strapIdentifier: String,
        throughReceipt receipt: PrefixDurabilityReceipt,
        maximumFrames: Int = AtriaWhoop4HistoryAdmissionLedger.productionMaximumDurableFrameEnumeration,
        _ visit: (UInt64, Data) throws -> Void
    ) throws -> DurableFrameEnumerationReport {
        guard maximumFrames >= 0 else {
            throw LedgerError.durableFrameEnumerationLimitExceeded(maximum: maximumFrames)
        }
        lock.lock()
        defer { lock.unlock() }
        guard receipt.storeIdentifier == "whoop4-exact-admission-sqlite-prefix-v2",
              receipt.snapshotSHA256.count == 64,
              receipt.archiveReceiptChainSHA256.count == 64,
              try receiptMatchesPersistedAuthority(
                attemptIdentifier: attemptIdentifier,
                strapIdentifier: strapIdentifier,
                receipt: receipt
              ) else {
            throw LedgerError.durablePrefixReceiptMismatch
        }
        guard let durableOrdinal = receipt.durableOrdinal else {
            return DurableFrameEnumerationReport(
                attemptIdentifier: attemptIdentifier,
                strapIdentifier: strapIdentifier,
                durableOrdinal: nil,
                recordCount: 0,
                byteCount: 0,
                orderedFramesSHA256: Self.emptySHA256
            )
        }
        let count = try scalarInt(
            """
            SELECT COUNT(*) FROM history_frame
            WHERE last_attempt_id = ? AND strap_id = ?
              AND archive_durable = 1 AND last_ordinal <= ?
            """,
            bindings: [
                .text(attemptIdentifier), .text(strapIdentifier),
                .int64(Int64(durableOrdinal))
            ]
        )
        guard count <= maximumFrames else {
            throw LedgerError.durableFrameEnumerationLimitExceeded(maximum: maximumFrames)
        }
        guard UInt64(count) == receipt.recordCount else {
            throw LedgerError.durablePrefixReceiptMismatch
        }
        guard let database else { throw LedgerError.open(SQLITE_MISUSE) }
        let sql = """
            SELECT last_ordinal, frame FROM history_frame
            WHERE last_attempt_id = ? AND strap_id = ?
              AND archive_durable = 1 AND last_ordinal <= ?
            ORDER BY last_ordinal ASC
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw LedgerError.sqlite(code: sqlite3_errcode(database),
                                     operation: "prepare_durable_frame_enumeration")
        }
        defer { sqlite3_finalize(statement) }
        try bind([
            .text(attemptIdentifier), .text(strapIdentifier),
            .int64(Int64(durableOrdinal))
        ], to: statement)
        var hasher = SHA256()
        var emitted: UInt64 = 0
        var bytes: UInt64 = 0
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else {
                throw LedgerError.sqlite(code: result,
                                         operation: "durable_frame_enumeration")
            }
            let ordinalValue = sqlite3_column_int64(statement, 0)
            guard ordinalValue >= 0 else { throw LedgerError.durablePrefixReceiptMismatch }
            let length = Int(sqlite3_column_bytes(statement, 1))
            guard length > 0, let pointer = sqlite3_column_blob(statement, 1) else {
                throw LedgerError.durablePrefixReceiptMismatch
            }
            let frame = Data(bytes: pointer, count: length)
            var ordinalLE = UInt64(ordinalValue).littleEndian
            withUnsafeBytes(of: &ordinalLE) { hasher.update(data: Data($0)) }
            var lengthLE = UInt64(length).littleEndian
            withUnsafeBytes(of: &lengthLE) { hasher.update(data: Data($0)) }
            hasher.update(data: frame)
            try visit(UInt64(ordinalValue), frame)
            emitted &+= 1
            bytes &+= UInt64(length)
        }
        guard emitted == receipt.recordCount, bytes == receipt.byteCount else {
            throw LedgerError.durablePrefixReceiptMismatch
        }
        return DurableFrameEnumerationReport(
            attemptIdentifier: attemptIdentifier,
            strapIdentifier: strapIdentifier,
            durableOrdinal: durableOrdinal,
            recordCount: emitted,
            byteCount: bytes,
            orderedFramesSHA256: hasher.finalize().map {
                String(format: "%02x", $0)
            }.joined()
        )
    }

    /// Returns the exact still-unpromoted identities in the requested attempt
    /// prefix. The bounded result is used to make the next archive receipt
    /// cover interrupted earlier bursts as well as the current burst.
    func pendingFrames(
        attempt: Attempt,
        through ordinal: UInt64,
        maximumFrames: Int = AtriaHistoricalArchiveDurableStore.productionMaximumReceiptBatchIdentities
    ) throws -> [Data] {
        guard maximumFrames >= 0 else {
            throw LedgerError.durableFrameEnumerationLimitExceeded(maximum: maximumFrames)
        }
        lock.lock()
        defer { lock.unlock() }
        guard try attemptIsCurrent(attempt) else { throw LedgerError.staleAttempt }
        let count = try scalarInt(
            """
            SELECT COUNT(*) FROM history_frame
            WHERE last_attempt_id = ? AND last_ordinal <= ? AND archive_durable = 0
            """,
            bindings: [.text(attempt.identifier), .int64(Int64(ordinal))]
        )
        guard count <= maximumFrames else {
            throw LedgerError.durableFrameEnumerationLimitExceeded(maximum: maximumFrames)
        }
        guard let database else { throw LedgerError.open(SQLITE_MISUSE) }
        let sql = """
            SELECT frame FROM history_frame
            WHERE last_attempt_id = ? AND last_ordinal <= ? AND archive_durable = 0
            ORDER BY last_ordinal ASC
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw LedgerError.sqlite(code: sqlite3_errcode(database),
                                     operation: "prepare_pending_frame_enumeration")
        }
        defer { sqlite3_finalize(statement) }
        try bind([.text(attempt.identifier), .int64(Int64(ordinal))], to: statement)
        var frames: [Data] = []
        frames.reserveCapacity(count)
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else {
                throw LedgerError.sqlite(code: result,
                                         operation: "pending_frame_enumeration_query")
            }
            let length = Int(sqlite3_column_bytes(statement, 0))
            guard let pointer = sqlite3_column_blob(statement, 0), length > 0 else {
                throw LedgerError.invalidIdentity
            }
            frames.append(Data(bytes: pointer, count: length))
        }
        return frames
    }

    func finish(_ attempt: Attempt, succeeded: Bool, now: Date = Date()) throws {
        lock.lock()
        defer { lock.unlock() }
        try transaction {
            guard try attemptIsCurrent(attempt) else { throw LedgerError.staleAttempt }
            try execute(
                "UPDATE history_attempt SET state = ?, updated_unix = ? WHERE id = ?",
                bindings: [
                    .int64(succeeded ? 1 : 2), .double(now.timeIntervalSince1970),
                    .text(attempt.identifier)
                ]
            )
        }
    }

    /// Bounds the derived exact-identity ledger without weakening ACK safety.
    /// Only rows that already crossed a raw archive fsync and are not owned by
    /// an active attempt are eligible. A replay after pruning is classified as
    /// first-seen and traverses raw persistence/fsync again; it is never
    /// silently discarded. Call this after attempt completion or background
    /// retention maintenance, never in the notification hot path.
    @discardableResult
    func prune(
        now: Date = Date(),
        identityRetention: TimeInterval = AtriaWhoop4HistoryAdmissionLedger.productionIdentityRetention,
        maximumRows: Int = AtriaWhoop4HistoryAdmissionLedger.productionMaximumIdentityRows
    ) throws -> PruneResult {
        lock.lock()
        defer { lock.unlock() }
        let result = try transaction { () -> PruneResult in
            let cutoff = now.timeIntervalSince1970 - max(0, identityRetention)
            try execute(
                """
                DELETE FROM history_frame
                WHERE archive_durable = 1
                  AND last_seen_unix < ?
                  AND last_attempt_id NOT IN
                      (SELECT id FROM history_attempt WHERE state = 0)
                """,
                bindings: [.double(cutoff)]
            )
            let removedForAge = Int(sqlite3_changes(database))
            let afterAge = try scalarInt("SELECT COUNT(*) FROM history_frame")
            let requestedMaximum = max(0, maximumRows)
            let excess = max(0, afterAge - requestedMaximum)
            var removedForCount = 0
            if excess > 0 {
                try execute(
                    """
                    DELETE FROM history_frame
                    WHERE (strap_id, frame) IN (
                        SELECT strap_id, frame FROM history_frame
                        WHERE archive_durable = 1
                          AND last_attempt_id NOT IN
                              (SELECT id FROM history_attempt WHERE state = 0)
                        ORDER BY last_seen_unix ASC, strap_id ASC, frame ASC
                        LIMIT ?
                    )
                    """,
                    bindings: [.int64(Int64(excess))]
                )
                removedForCount = Int(sqlite3_changes(database))
            }
            let remaining = try scalarInt("SELECT COUNT(*) FROM history_frame")
            return PruneResult(
                removedForAge: removedForAge,
                removedForCount: removedForCount,
                remainingRows: remaining,
                protectedRowsAboveLimit: max(0, remaining - requestedMaximum)
            )
        }
        // Deleted pages remain reusable even when an older database was not
        // created with incremental auto-vacuum. New ledgers also return free
        // tail pages to the filesystem, and WAL truncation prevents a second
        // unbounded sidecar from accumulating.
        try execute("PRAGMA wal_checkpoint(TRUNCATE)")
        try execute("PRAGMA incremental_vacuum(1024)")
        return result
    }

    func countsForDiagnostics() throws -> (frames: Int, activeAttempts: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (
            try scalarInt("SELECT COUNT(*) FROM history_frame"),
            try scalarInt("SELECT COUNT(*) FROM history_attempt WHERE state = 0")
        )
    }

    // MARK: - SQLite

    private enum Binding {
        case text(String)
        case blob(Data)
        case int64(Int64)
        case double(Double)
    }

    private struct FrameState {
        let lastAttemptID: String
        let lastIncarnation: String
        let lastOrdinal: UInt64
        let archiveDurable: Bool
    }

    private struct PreviousPrefixReceipt {
        let durableSequence: Int64
        let promotedOrdinal: Int64
        let prefixDigest: String
        let recordCount: Int64
        let byteCount: Int64
    }

    private struct AttemptOrdinalState {
        let nextOrdinal: Int64
        let durableOrdinal: Int64
    }

    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func resumableAttemptID(strapIdentifier: String) throws -> String? {
        try queryOne(
            """
            SELECT id FROM history_attempt
            WHERE strap_id = ? AND state = 0
            ORDER BY updated_unix DESC LIMIT 1
            """,
            bindings: [.text(strapIdentifier)]
        ) { statement in
            guard let value = sqlite3_column_text(statement, 0) else { return nil }
            return String(cString: value)
        } ?? nil
    }

    private func attemptIsCurrent(_ attempt: Attempt) throws -> Bool {
        try queryOne(
            "SELECT COUNT(*) FROM history_attempt WHERE id = ? AND strap_id = ? AND incarnation = ? AND state = 0",
            bindings: [.text(attempt.identifier), .text(attempt.strapIdentifier), .text(attempt.incarnation)]
        ) { sqlite3_column_int64($0, 0) == 1 } ?? false
    }

    private func reserveOrdinal(attempt: Attempt, now: Date) throws -> UInt64 {
        let next = try queryOne(
            "SELECT next_ordinal FROM history_attempt WHERE id = ?",
            bindings: [.text(attempt.identifier)]
        ) { sqlite3_column_int64($0, 0) }
        guard let next, next >= 0, next < Int64.max else { throw LedgerError.ordinalOverflow }
        try execute(
            "UPDATE history_attempt SET next_ordinal = ?, updated_unix = ? WHERE id = ?",
            bindings: [.int64(next + 1), .double(now.timeIntervalSince1970), .text(attempt.identifier)]
        )
        return UInt64(next)
    }

    private func frameState(strapIdentifier: String, frame: Data) throws -> FrameState? {
        try queryOne(
            """
            SELECT last_attempt_id, last_incarnation, last_ordinal, archive_durable
            FROM history_frame WHERE strap_id = ? AND frame = ?
            """,
            bindings: [.text(strapIdentifier), .blob(frame)]
        ) { statement in
            guard let attempt = sqlite3_column_text(statement, 0),
                  let incarnation = sqlite3_column_text(statement, 1) else { return nil }
            return FrameState(
                lastAttemptID: String(cString: attempt),
                lastIncarnation: String(cString: incarnation),
                lastOrdinal: UInt64(sqlite3_column_int64(statement, 2)),
                archiveDurable: sqlite3_column_int(statement, 3) != 0
            )
        } ?? nil
    }

    private func previousPrefixReceipt(attemptID: String) throws -> PreviousPrefixReceipt? {
        try queryOne(
            """
            SELECT durable_sequence, promoted_ordinal, prefix_digest, record_count, byte_count
            FROM history_archive_receipt
            WHERE attempt_id = ?
            ORDER BY durable_sequence DESC LIMIT 1
            """,
            bindings: [.text(attemptID)]
        ) { statement in
            guard let digest = sqlite3_column_text(statement, 2) else { return nil }
            return PreviousPrefixReceipt(
                durableSequence: sqlite3_column_int64(statement, 0),
                promotedOrdinal: sqlite3_column_int64(statement, 1),
                prefixDigest: String(cString: digest),
                recordCount: sqlite3_column_int64(statement, 3),
                byteCount: sqlite3_column_int64(statement, 4)
            )
        } ?? nil
    }

    private func receiptMatchesPersistedAuthority(
        attemptIdentifier: String,
        strapIdentifier: String,
        receipt: PrefixDurabilityReceipt
    ) throws -> Bool {
        try queryOne(
            """
            SELECT r.durable_sequence, r.promoted_ordinal, r.raw_digest,
                   r.identity_digest, r.prefix_digest, r.record_count,
                   r.byte_count, a.strap_id
            FROM history_archive_receipt r
            JOIN history_attempt a ON a.id = r.attempt_id
            WHERE r.chain_digest = ? AND r.attempt_id = ?
            """,
            bindings: [
                .text(receipt.archiveReceiptChainSHA256),
                .text(attemptIdentifier)
            ]
        ) { statement in
            guard let raw = sqlite3_column_text(statement, 2),
                  let identity = sqlite3_column_text(statement, 3),
                  let prefix = sqlite3_column_text(statement, 4),
                  let strap = sqlite3_column_text(statement, 7) else { return false }
            let persistedOrdinal = sqlite3_column_int64(statement, 1)
            let suppliedOrdinal = receipt.durableOrdinal.map(Int64.init) ?? -1
            return sqlite3_column_int64(statement, 0) == Int64(receipt.durableSequence)
                && persistedOrdinal == suppliedOrdinal
                && String(cString: raw) == receipt.rawArchiveSnapshotSHA256
                && String(cString: identity) == receipt.identityIndexSnapshotSHA256
                && String(cString: prefix) == receipt.snapshotSHA256
                && sqlite3_column_int64(statement, 5) == Int64(receipt.recordCount)
                && sqlite3_column_int64(statement, 6) == Int64(receipt.byteCount)
                && String(cString: strap) == strapIdentifier
        } ?? false
    }

    private func attemptOrdinalState(attemptID: String) throws -> AttemptOrdinalState {
        guard let state = try queryOne(
            "SELECT next_ordinal, durable_ordinal FROM history_attempt WHERE id = ?",
            bindings: [.text(attemptID)],
            map: { statement in
            AttemptOrdinalState(nextOrdinal: sqlite3_column_int64(statement, 0),
                                durableOrdinal: sqlite3_column_int64(statement, 1))
            }
        ) else {
            throw LedgerError.staleAttempt
        }
        return state
    }

    private func scalarInt(_ sql: String, bindings: [Binding] = []) throws -> Int {
        try queryOne(sql, bindings: bindings) { Int(sqlite3_column_int64($0, 0)) } ?? 0
    }

    private func scalarInt64(_ sql: String, bindings: [Binding] = []) throws -> Int64? {
        try queryOne(sql, bindings: bindings) { statement in
            guard sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
            return sqlite3_column_int64(statement, 0)
        } ?? nil
    }

    private static func boundPrefixDigest(
        previousPrefixSHA256: String?,
        admissionBatchSHA256: String,
        archiveReceipt: AtriaHistoricalArchiveDurableStore.FlushReceipt,
        attempt: Attempt,
        ordinal: UInt64?
    ) -> String {
        var hasher = SHA256()
        func add(_ string: String) {
            let data = Data(string.utf8)
            var length = UInt64(data.count).littleEndian
            withUnsafeBytes(of: &length) { hasher.update(data: Data($0)) }
            hasher.update(data: data)
        }
        add("whoop4-admission-prefix-bound-to-archive-v2")
        add(attempt.identifier)
        add(attempt.strapIdentifier)
        add(previousPrefixSHA256 ?? String(repeating: "0", count: 64))
        add(admissionBatchSHA256)
        add(archiveReceipt.raw.snapshotSHA256)
        add(archiveReceipt.identity.snapshotSHA256)
        add(archiveReceipt.receiptChainSHA256)
        var sequence = archiveReceipt.durableSequence.littleEndian
        withUnsafeBytes(of: &sequence) { hasher.update(data: Data($0)) }
        if let ordinal {
            hasher.update(data: Data([1]))
            var durableOrdinal = ordinal.littleEndian
            withUnsafeBytes(of: &durableOrdinal) { hasher.update(data: Data($0)) }
        } else {
            hasher.update(data: Data([0]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static let emptySHA256 = SHA256.hash(data: Data()).map {
        String(format: "%02x", $0)
    }.joined()

    /// Hashes only rows admitted since the preceding prefix receipt. This is
    /// bounded by the current transport batch and avoids rehashing an entire
    /// full-flash prefix at every HISTORY_END.
    private func admissionBatchSnapshot(
        attempt: Attempt,
        after previousOrdinal: UInt64?,
        through ordinal: UInt64
    ) throws -> (sha256: String, recordCount: UInt64, byteCount: UInt64) {
        guard let database else { throw LedgerError.open(SQLITE_MISUSE) }
        let sql: String
        let bindings: [Binding]
        if let previousOrdinal {
            sql = """
                SELECT last_ordinal, frame FROM history_frame
                WHERE last_attempt_id = ? AND last_ordinal > ? AND last_ordinal <= ?
                ORDER BY last_ordinal ASC
                """
            bindings = [
                .text(attempt.identifier), .int64(Int64(previousOrdinal)),
                .int64(Int64(ordinal))
            ]
        } else {
            sql = """
                SELECT last_ordinal, frame FROM history_frame
                WHERE last_attempt_id = ? AND last_ordinal <= ?
                ORDER BY last_ordinal ASC
                """
            bindings = [.text(attempt.identifier), .int64(Int64(ordinal))]
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw LedgerError.sqlite(code: sqlite3_errcode(database),
                                     operation: "prepare_admission_batch_receipt")
        }
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        var hasher = SHA256()
        var count: UInt64 = 0
        var bytes: UInt64 = 0
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else {
                throw LedgerError.sqlite(code: result,
                                         operation: "admission_batch_receipt_query")
            }
            var value = UInt64(sqlite3_column_int64(statement, 0)).littleEndian
            withUnsafeBytes(of: &value) { hasher.update(data: Data($0)) }
            let length = Int(sqlite3_column_bytes(statement, 1))
            var encodedLength = UInt64(max(0, length)).littleEndian
            withUnsafeBytes(of: &encodedLength) { hasher.update(data: Data($0)) }
            if let pointer = sqlite3_column_blob(statement, 1), length > 0 {
                hasher.update(data: Data(bytes: pointer, count: length))
                bytes &+= UInt64(length)
            }
            count &+= 1
        }
        return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), count, bytes)
    }

    /// Reconstructs the exact archive identity set for admission rows that
    /// still need promotion. This is intentionally bounded by the transport
    /// receipt limit and uses complete payload identities, not a probabilistic
    /// counter/timestamp shortcut.
    private func pendingArchiveIdentitySnapshot(
        attempt: Attempt,
        through ordinal: UInt64
    ) throws -> (sha256: String, recordCount: UInt64) {
        guard let database else { throw LedgerError.open(SQLITE_MISUSE) }
        let sql = """
            SELECT frame FROM history_frame
            WHERE last_attempt_id = ? AND last_ordinal <= ? AND archive_durable = 0
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw LedgerError.sqlite(code: sqlite3_errcode(database),
                                     operation: "prepare_pending_archive_identity_snapshot")
        }
        defer { sqlite3_finalize(statement) }
        try bind([.text(attempt.identifier), .int64(Int64(ordinal))], to: statement)
        var keys: [String] = []
        keys.reserveCapacity(min(
            AtriaHistoricalArchiveDurableStore.productionMaximumReceiptBatchIdentities,
            256
        ))
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else {
                throw LedgerError.sqlite(code: result,
                                         operation: "pending_archive_identity_snapshot_query")
            }
            guard keys.count
                    < AtriaHistoricalArchiveDurableStore.productionMaximumReceiptBatchIdentities else {
                throw LedgerError.invalidArchiveDurabilityReceipt
            }
            let length = Int(sqlite3_column_bytes(statement, 0))
            let frame: Data
            if let pointer = sqlite3_column_blob(statement, 0), length > 0 {
                frame = Data(bytes: pointer, count: length)
            } else {
                frame = Data()
            }
            keys.append(AtriaHistoricalArchiveDurableStore.FrameIdentity.whoop4(
                strapIdentifier: attempt.strapIdentifier,
                payload: frame
            ).stableKey)
        }
        return (
            AtriaHistoricalArchiveDurableStore.identityBatchDigest(keys),
            UInt64(keys.count)
        )
    }

    private func prefixSnapshot(
        attempt: Attempt,
        through ordinal: UInt64
    ) throws -> (sha256: String, recordCount: UInt64, byteCount: UInt64) {
        guard let database else { throw LedgerError.open(SQLITE_MISUSE) }
        let sql = """
            SELECT last_ordinal, frame FROM history_frame
            WHERE last_attempt_id = ? AND last_ordinal <= ? AND archive_durable = 1
            ORDER BY last_ordinal ASC
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw LedgerError.sqlite(code: sqlite3_errcode(database), operation: "prepare_prefix_receipt")
        }
        defer { sqlite3_finalize(statement) }
        try bind([.text(attempt.identifier), .int64(Int64(ordinal))], to: statement)
        var hasher = SHA256()
        var count: UInt64 = 0
        var bytes: UInt64 = 0
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else {
                throw LedgerError.sqlite(code: result, operation: "prefix_receipt_query")
            }
            var value = UInt64(sqlite3_column_int64(statement, 0)).littleEndian
            withUnsafeBytes(of: &value) { hasher.update(data: Data($0)) }
            let length = Int(sqlite3_column_bytes(statement, 1))
            if let pointer = sqlite3_column_blob(statement, 1), length > 0 {
                let data = Data(bytes: pointer, count: length)
                hasher.update(data: data)
                bytes &+= UInt64(length)
            }
            count &+= 1
        }
        return (hasher.finalize().map { String(format: "%02x", $0) }.joined(),
                count,
                bytes)
    }

    private func execute(_ sql: String, bindings: [Binding] = []) throws {
        guard let database else { throw LedgerError.open(SQLITE_MISUSE) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw LedgerError.sqlite(code: sqlite3_errcode(database), operation: "prepare")
        }
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw LedgerError.sqlite(code: result, operation: "step")
        }
    }

    private func queryOne<T>(
        _ sql: String,
        bindings: [Binding],
        map: (OpaquePointer) -> T?
    ) throws -> T? {
        guard let database else { throw LedgerError.open(SQLITE_MISUSE) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw LedgerError.sqlite(code: sqlite3_errcode(database), operation: "prepare_query")
        }
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else {
            throw LedgerError.sqlite(code: result, operation: "query")
        }
        return map(statement)
    }

    private func bind(_ bindings: [Binding], to statement: OpaquePointer) throws {
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let code: Int32
            switch binding {
            case .text(let value):
                code = value.withCString {
                    sqlite3_bind_text(statement, index, $0, -1, SQLITE_TRANSIENT)
                }
            case .blob(let value):
                code = value.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(statement, index, bytes.baseAddress,
                                      Int32(bytes.count), SQLITE_TRANSIENT)
                }
            case .int64(let value):
                code = sqlite3_bind_int64(statement, index, value)
            case .double(let value):
                code = sqlite3_bind_double(statement, index, value)
            }
            guard code == SQLITE_OK else {
                throw LedgerError.sqlite(code: code, operation: "bind")
            }
        }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
