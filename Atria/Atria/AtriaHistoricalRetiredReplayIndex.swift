import CryptoKit
import Foundation
import SQLite3

/// Bounded-memory exact replay authority for raw chunks that have been retired.
///
/// The canonical replay artifact remains the auditable source-bound proof. This
/// SQLite index stores the complete canonical binary replay identity (not
/// decoded raw JSON and not the hex key) and provides one indexed equality lookup
/// frame. Import and source receipt publication share a FULL-synchronous
/// transaction, so retirement cannot observe a partial index.
final class AtriaHistoricalRetiredReplayIndex: @unchecked Sendable {
    enum MaintenanceCheckpoint: Equatable, Sendable {
        case logicalPruneCommitted
        case vacuumCompleted
    }

    struct ImportReceipt: Codable, Equatable, Sendable {
        let sourceChunkID: String
        let sourceRawSHA256: String
        let identityCount: Int
        let orderedKeysSHA256: String
    }

    struct PruneResult: Equatable, Sendable {
        let removedSourceMemberships: Int
        let removedExactIdentities: Int
        let remainingExactIdentities: Int
    }

    struct MaintenanceResult: Equatable, Sendable {
        let removedSourceMemberships: Int
        let removedExactIdentities: Int
        let removedSourceTombstones: Int
        let remainingExactIdentities: Int
        let remainingSourceTombstones: Int
        let bytesBefore: UInt64
        let bytesAfter: UInt64
    }

    enum IndexError: Error, Equatable {
        case open(Int32)
        case sqlite(code: Int32, operation: String)
        case invalidIdentity
        case sourceConflict
        case importVerificationFailed
    }

    private let lock = NSLock()
    private let databaseURL: URL
    private let maintenanceCheckpoint: (MaintenanceCheckpoint) throws -> Void
    private var database: OpaquePointer?

    init(databaseURL: URL,
         pageCacheKiB: Int = 2_048,
         unsafeDisableDurabilityForTests: Bool = false,
         maintenanceCheckpoint: @escaping (MaintenanceCheckpoint) throws -> Void = { _ in }) throws {
        self.databaseURL = databaseURL
        self.maintenanceCheckpoint = maintenanceCheckpoint
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var opened: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let code = sqlite3_open_v2(databaseURL.path, &opened, flags, nil)
        guard code == SQLITE_OK, let opened else {
            if let opened { sqlite3_close_v2(opened) }
            throw IndexError.open(code)
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
            try execute("""
                CREATE TABLE IF NOT EXISTS retired_replay_identity_v3 (
                    identity_id INTEGER PRIMARY KEY NOT NULL,
                    stable_key BLOB UNIQUE NOT NULL,
                    maximum_observed_unix REAL NOT NULL
                )
                """)
            try execute("""
                CREATE TABLE IF NOT EXISTS retired_replay_source_v3 (
                    chunk_id TEXT PRIMARY KEY NOT NULL,
                    raw_sha256 TEXT NOT NULL,
                    identity_count INTEGER NOT NULL,
                    ordered_keys_sha256 TEXT NOT NULL,
                    imported_unix REAL NOT NULL,
                    catalog_retired_unix REAL
                ) WITHOUT ROWID
                """)
            try execute("""
                CREATE TABLE IF NOT EXISTS retired_replay_source_identity_v3 (
                    chunk_id TEXT NOT NULL,
                    identity_id INTEGER NOT NULL,
                    observed_unix REAL NOT NULL,
                    PRIMARY KEY(chunk_id, identity_id),
                    FOREIGN KEY(chunk_id) REFERENCES retired_replay_source_v3(chunk_id)
                        ON DELETE CASCADE,
                    FOREIGN KEY(identity_id) REFERENCES retired_replay_identity_v3(identity_id)
                        ON DELETE CASCADE
                ) WITHOUT ROWID
                """)
            try execute("""
                CREATE INDEX IF NOT EXISTS retired_replay_source_identity_expiry_v3
                ON retired_replay_source_identity_v3(observed_unix, chunk_id)
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

    func importAndVerify(
        shard: AtriaHistoricalReplayIdentityShard,
        source: AtriaHistoricalAggregateChunk.Source,
        importedAt: Date = Date()
    ) throws -> ImportReceipt {
        guard shard.source.chunkID == source.chunkID,
              shard.source.rawSHA256 == source.rawSHA256,
              shard.source.rawRowCount == source.rawRowCount,
              shard.entries.count == source.rawRowCount,
              shard.entries.allSatisfy({ $0.observedAtUnix.isFinite }),
              importedAt.timeIntervalSince1970.isFinite else {
            throw IndexError.invalidIdentity
        }
        let receipt = try Self.receipt(shard: shard, source: source)
        lock.lock()
        defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do {
            if let existing = try sourceReceipt(chunkID: source.chunkID) {
                guard existing == receipt else { throw IndexError.sourceConflict }
            } else {
                try execute(
                    """
                    INSERT INTO retired_replay_source_v3
                    (chunk_id, raw_sha256, identity_count, ordered_keys_sha256,
                     imported_unix, catalog_retired_unix)
                    VALUES (?, ?, ?, ?, ?, NULL)
                    """,
                    bindings: [
                        .text(receipt.sourceChunkID),
                        .text(receipt.sourceRawSHA256),
                        .int64(Int64(receipt.identityCount)),
                        .text(receipt.orderedKeysSHA256),
                        .double(importedAt.timeIntervalSince1970),
                    ]
                )
                for entry in shard.entries {
                    let decoded = try Self.decodeStableKey(entry.stableKey)
                    try execute(
                        """
                        INSERT INTO retired_replay_identity_v3
                        (stable_key, maximum_observed_unix) VALUES (?, ?)
                        ON CONFLICT(stable_key) DO UPDATE SET maximum_observed_unix =
                            MAX(maximum_observed_unix, excluded.maximum_observed_unix)
                        """,
                        bindings: [.blob(decoded), .double(entry.observedAtUnix)]
                    )
                    try execute(
                        """
                        INSERT INTO retired_replay_source_identity_v3
                        (chunk_id, identity_id, observed_unix)
                        SELECT ?, identity_id, ? FROM retired_replay_identity_v3
                        WHERE stable_key = ?
                        """,
                        bindings: [
                            .text(source.chunkID), .double(entry.observedAtUnix),
                            .blob(decoded),
                        ]
                    )
                }
            }
            guard try verifyLocked(shard: shard, expected: receipt) else {
                throw IndexError.importVerificationFailed
            }
            try execute("COMMIT")
            return receipt
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func verify(
        shard: AtriaHistoricalReplayIdentityShard,
        receipt: ImportReceipt
    ) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return try verifyLocked(shard: shard, expected: receipt)
    }

    /// One SQLite B-tree equality query. No replay shard or key set is loaded.
    func contains(stableKey: String) throws -> Bool {
        let decoded = try Self.decodeStableKey(stableKey)
        lock.lock()
        defer { lock.unlock() }
        return try scalarInt(
            "SELECT COUNT(*) FROM retired_replay_identity_v3 WHERE stable_key = ?",
            bindings: [.blob(decoded)]
        ) == 1
    }

    func contains(strapIdentifier: String, whoopFrame: Data) throws -> Bool {
        guard !strapIdentifier.isEmpty, !whoopFrame.isEmpty else {
            throw IndexError.invalidIdentity
        }
        return try contains(stableKey:
            AtriaHistoricalArchiveDurableStore.FrameIdentity.whoop4(
                strapIdentifier: strapIdentifier,
                payload: whoopFrame
            ).stableKey
        )
    }

    /// Catalog retirement is recorded only after its durable manifest is
    /// visible. Pruning refuses to remove memberships for any other source.
    func markCatalogRetired(
        receipt: ImportReceipt,
        retiredAt: Date = Date()
    ) throws {
        guard retiredAt.timeIntervalSince1970.isFinite else {
            throw IndexError.invalidIdentity
        }
        lock.lock()
        defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do {
            guard try sourceReceipt(chunkID: receipt.sourceChunkID) == receipt else {
                throw IndexError.sourceConflict
            }
            try execute(
                """
                UPDATE retired_replay_source_v3
                SET catalog_retired_unix = COALESCE(catalog_retired_unix, ?)
                WHERE chunk_id = ?
                """,
                bindings: [.double(retiredAt.timeIntervalSince1970),
                           .text(receipt.sourceChunkID)]
            )
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Small durable source-level tombstone used after the large replay shard
    /// has been retired from staging/canonical destinations.
    func retiredSourceReceipt(chunkID: String) throws -> ImportReceipt? {
        lock.lock()
        defer { lock.unlock() }
        guard let receipt = try sourceReceipt(chunkID: chunkID),
              try scalarInt(
                "SELECT COUNT(*) FROM retired_replay_source_v3 WHERE chunk_id = ? AND catalog_retired_unix IS NOT NULL",
                bindings: [.text(chunkID)]
              ) == 1 else { return nil }
        return receipt
    }

    func verifiesRetiredSource(_ receipt: ImportReceipt) throws -> Bool {
        try retiredSourceReceipt(chunkID: receipt.sourceChunkID) == receipt
    }

    /// Removes only expired memberships belonging to catalog-retired sources,
    /// then removes an exact key only when no membership remains. Freed pages
    /// stay in SQLite's freelist for bounded reuse. A TRUNCATE checkpoint is
    /// used instead of VACUUM so pruning cannot require a second database-sized
    /// temporary file.
    func pruneExpired(observedBefore cutoff: Date) throws -> PruneResult {
        guard cutoff.timeIntervalSince1970.isFinite else {
            throw IndexError.invalidIdentity
        }
        lock.lock()
        defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        let membershipsBefore: Int
        let identitiesBefore: Int
        do {
            membershipsBefore = try scalarInt(
                "SELECT COUNT(*) FROM retired_replay_source_identity_v3",
                bindings: []
            )
            identitiesBefore = try scalarInt(
                "SELECT COUNT(*) FROM retired_replay_identity_v3",
                bindings: []
            )
            try execute(
                """
                DELETE FROM retired_replay_source_identity_v3
                WHERE observed_unix < ? AND chunk_id IN (
                    SELECT chunk_id FROM retired_replay_source_v3
                    WHERE catalog_retired_unix IS NOT NULL
                )
                """,
                bindings: [.double(cutoff.timeIntervalSince1970)]
            )
            try execute(
                """
                DELETE FROM retired_replay_identity_v3
                WHERE NOT EXISTS (
                    SELECT 1 FROM retired_replay_source_identity_v3 membership
                    WHERE membership.identity_id = retired_replay_identity_v3.identity_id
                )
                """
            )
            let membershipsAfter = try scalarInt(
                "SELECT COUNT(*) FROM retired_replay_source_identity_v3",
                bindings: []
            )
            let identitiesAfter = try scalarInt(
                "SELECT COUNT(*) FROM retired_replay_identity_v3",
                bindings: []
            )
            try execute("COMMIT")
            guard let database else { throw IndexError.open(SQLITE_MISUSE) }
            var logFrames: Int32 = 0
            var checkpointedFrames: Int32 = 0
            let checkpointCode = sqlite3_wal_checkpoint_v2(
                database, nil, SQLITE_CHECKPOINT_TRUNCATE,
                &logFrames, &checkpointedFrames
            )
            guard checkpointCode == SQLITE_OK else {
                throw sqliteError("wal_checkpoint_truncate")
            }
            return .init(
                removedSourceMemberships: membershipsBefore - membershipsAfter,
                removedExactIdentities: identitiesBefore - identitiesAfter,
                remainingExactIdentities: identitiesAfter
            )
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Bounds lifetime replay storage without loading keys into memory.
    /// SQLite performs both deletes and VACUUM as crash-safe disk transactions;
    /// a process death after the logical prune but before VACUUM merely leaves
    /// reusable freelist pages, and the next invocation completes compaction.
    /// Per-source receipts remain as bounded reimport tombstones for the
    /// requested horizon after their last exact membership expires.
    func maintainStorage(
        identityCutoff: Date,
        sourceTombstoneCutoff: Date,
        sourceTombstoneRetirementAuthorizedChunkIDs: Set<String> = []
    ) throws -> MaintenanceResult {
        guard identityCutoff.timeIntervalSince1970.isFinite,
              sourceTombstoneCutoff.timeIntervalSince1970.isFinite,
              sourceTombstoneCutoff <= identityCutoff else {
            throw IndexError.invalidIdentity
        }
        let bytesBefore = Self.managedBytes(databaseURL: databaseURL)
        lock.lock()
        defer { lock.unlock() }
        let membershipsBefore: Int
        let identitiesBefore: Int
        let sourcesBefore: Int
        try execute("BEGIN IMMEDIATE")
        do {
            membershipsBefore = try scalarInt(
                "SELECT COUNT(*) FROM retired_replay_source_identity_v3", bindings: []
            )
            identitiesBefore = try scalarInt(
                "SELECT COUNT(*) FROM retired_replay_identity_v3", bindings: []
            )
            sourcesBefore = try scalarInt(
                "SELECT COUNT(*) FROM retired_replay_source_v3", bindings: []
            )
            try execute(
                """
                DELETE FROM retired_replay_source_identity_v3
                WHERE observed_unix < ? AND chunk_id IN (
                    SELECT chunk_id FROM retired_replay_source_v3
                    WHERE catalog_retired_unix IS NOT NULL
                )
                """,
                bindings: [.double(identityCutoff.timeIntervalSince1970)]
            )
            try execute(
                """
                DELETE FROM retired_replay_identity_v3
                WHERE NOT EXISTS (
                    SELECT 1 FROM retired_replay_source_identity_v3 membership
                    WHERE membership.identity_id = retired_replay_identity_v3.identity_id
                )
                """
            )
            if !sourceTombstoneRetirementAuthorizedChunkIDs.isEmpty {
                let ids = sourceTombstoneRetirementAuthorizedChunkIDs.sorted()
                let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
                try execute(
                    """
                    DELETE FROM retired_replay_source_v3
                    WHERE catalog_retired_unix IS NOT NULL
                      AND imported_unix < ?
                      AND chunk_id IN (\(placeholders))
                      AND NOT EXISTS (
                        SELECT 1 FROM retired_replay_source_identity_v3 membership
                        WHERE membership.chunk_id = retired_replay_source_v3.chunk_id
                      )
                    """,
                    bindings: [.double(sourceTombstoneCutoff.timeIntervalSince1970)]
                        + ids.map { Binding.text($0) }
                )
            }
            let membershipsAfter = try scalarInt(
                "SELECT COUNT(*) FROM retired_replay_source_identity_v3", bindings: []
            )
            let identitiesAfter = try scalarInt(
                "SELECT COUNT(*) FROM retired_replay_identity_v3", bindings: []
            )
            let sourcesAfter = try scalarInt(
                "SELECT COUNT(*) FROM retired_replay_source_v3", bindings: []
            )
            try execute("COMMIT")
            try maintenanceCheckpoint(.logicalPruneCommitted)
            try checkpointTruncateLocked()
            guard try scalarText("PRAGMA integrity_check") == "ok" else {
                throw IndexError.importVerificationFailed
            }
            // VACUUM uses SQLite's own rollback-safe temporary database and is
            // streaming/page-bounded; it never materializes the key set in RAM.
            try execute("VACUUM")
            try checkpointTruncateLocked()
            guard try scalarText("PRAGMA integrity_check") == "ok" else {
                throw IndexError.importVerificationFailed
            }
            try maintenanceCheckpoint(.vacuumCompleted)
            return .init(
                removedSourceMemberships: membershipsBefore - membershipsAfter,
                removedExactIdentities: identitiesBefore - identitiesAfter,
                removedSourceTombstones: sourcesBefore - sourcesAfter,
                remainingExactIdentities: identitiesAfter,
                remainingSourceTombstones: sourcesAfter,
                bytesBefore: bytesBefore,
                bytesAfter: Self.managedBytes(databaseURL: databaseURL)
            )
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func verifyLocked(
        shard: AtriaHistoricalReplayIdentityShard,
        expected: ImportReceipt
    ) throws -> Bool {
        guard try sourceReceipt(chunkID: expected.sourceChunkID) == expected,
              shard.entries.count == expected.identityCount else { return false }
        for entry in shard.entries {
            let decoded = try Self.decodeStableKey(entry.stableKey)
            guard try scalarInt(
                """
                SELECT COUNT(*)
                FROM retired_replay_source_identity_v3 membership
                JOIN retired_replay_identity_v3 identity
                  ON identity.identity_id = membership.identity_id
                WHERE membership.chunk_id = ? AND identity.stable_key = ?
                  AND membership.observed_unix = ?
                """,
                bindings: [.text(expected.sourceChunkID), .blob(decoded),
                           .double(entry.observedAtUnix)]
            ) == 1 else { return false }
        }
        return true
    }

    private func sourceReceipt(chunkID: String) throws -> ImportReceipt? {
        guard let database else { throw IndexError.open(SQLITE_MISUSE) }
        let sql = """
            SELECT raw_sha256, identity_count, ordered_keys_sha256
            FROM retired_replay_source_v3 WHERE chunk_id = ?
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw sqliteError("prepare_source_receipt")
        }
        defer { sqlite3_finalize(statement) }
        try bind([.text(chunkID)], to: statement)
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE { return nil }
        guard step == SQLITE_ROW,
              let digestPointer = sqlite3_column_text(statement, 0),
              let keysPointer = sqlite3_column_text(statement, 2) else {
            throw sqliteError("step_source_receipt")
        }
        return .init(
            sourceChunkID: chunkID,
            sourceRawSHA256: String(cString: digestPointer),
            identityCount: Int(sqlite3_column_int64(statement, 1)),
            orderedKeysSHA256: String(cString: keysPointer)
        )
    }

    private static func receipt(
        shard: AtriaHistoricalReplayIdentityShard,
        source: AtriaHistoricalAggregateChunk.Source
    ) throws -> ImportReceipt {
        var hasher = SHA256()
        for entry in shard.entries {
            _ = try decodeStableKey(entry.stableKey)
            let key = Data(entry.stableKey.utf8)
            var length = UInt64(key.count).littleEndian
            withUnsafeBytes(of: &length) { hasher.update(data: Data($0)) }
            hasher.update(data: key)
        }
        return .init(
            sourceChunkID: source.chunkID,
            sourceRawSHA256: source.rawSHA256,
            identityCount: shard.entries.count,
            orderedKeysSHA256: hasher.finalize().map {
                String(format: "%02x", $0)
            }.joined()
        )
    }

    private static func decodeStableKey(
        _ stableKey: String
    ) throws -> Data {
        guard stableKey.count.isMultiple(of: 2) else {
            throw IndexError.invalidIdentity
        }
        var bytes = [UInt8]()
        bytes.reserveCapacity(stableKey.count / 2)
        var cursor = stableKey.startIndex
        while cursor < stableKey.endIndex {
            let end = stableKey.index(cursor, offsetBy: 2)
            guard let byte = UInt8(stableKey[cursor..<end], radix: 16) else {
                throw IndexError.invalidIdentity
            }
            bytes.append(byte)
            cursor = end
        }
        var offset = 0
        func take(_ count: Int) throws -> ArraySlice<UInt8> {
            guard count >= 0, offset + count <= bytes.count else {
                throw IndexError.invalidIdentity
            }
            defer { offset += count }
            return bytes[offset..<(offset + count)]
        }
        func u32() throws -> UInt32 {
            let value = try take(4)
            return value.enumerated().reduce(UInt32(0)) {
                $0 | (UInt32($1.element) << UInt32($1.offset * 8))
            }
        }
        guard try take(1).first == 2 else { throw IndexError.invalidIdentity }
        let strapLength = Int(try u32())
        guard let strap = String(bytes: try take(strapLength), encoding: .utf8),
              !strap.isEmpty else { throw IndexError.invalidIdentity }
        _ = try take(1) // protocol version
        _ = try take(4) // counter
        _ = try take(4) // unix seconds
        _ = try take(2) // subsecond
        let payloadLength = Int(try u32())
        let payload = Data(try take(payloadLength))
        guard offset == bytes.count, !payload.isEmpty else {
            throw IndexError.invalidIdentity
        }
        // Preserve every identity component. In particular, identical payload
        // bytes at a different counter/timestamp must not become a replay hit.
        return Data(bytes)
    }

    private enum Binding {
        case text(String)
        case blob(Data)
        case int64(Int64)
        case double(Double)
    }

    private func execute(_ sql: String, bindings: [Binding] = []) throws {
        guard let database else { throw IndexError.open(SQLITE_MISUSE) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw sqliteError("prepare") }
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW { step = sqlite3_step(statement) }
        guard step == SQLITE_DONE else { throw sqliteError("step") }
    }

    private func scalarInt(_ sql: String, bindings: [Binding]) throws -> Int {
        guard let database else { throw IndexError.open(SQLITE_MISUSE) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw sqliteError("prepare_scalar") }
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw sqliteError("step_scalar") }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func scalarText(_ sql: String) throws -> String {
        guard let database else { throw IndexError.open(SQLITE_MISUSE) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw sqliteError("prepare_scalar_text") }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let pointer = sqlite3_column_text(statement, 0) else {
            throw sqliteError("step_scalar_text")
        }
        return String(cString: pointer)
    }

    private func checkpointTruncateLocked() throws {
        guard let database else { throw IndexError.open(SQLITE_MISUSE) }
        var logFrames: Int32 = 0
        var checkpointedFrames: Int32 = 0
        let code = sqlite3_wal_checkpoint_v2(database, nil, SQLITE_CHECKPOINT_TRUNCATE,
                                             &logFrames, &checkpointedFrames)
        guard code == SQLITE_OK else { throw sqliteError("wal_checkpoint_truncate") }
    }

    private static func managedBytes(databaseURL: URL) -> UInt64 {
        [databaseURL,
         URL(fileURLWithPath: databaseURL.path + "-wal"),
         URL(fileURLWithPath: databaseURL.path + "-shm")]
            .reduce(0) { total, url in
                let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                return total &+ UInt64(max(0, bytes))
            }
    }

    private func bind(_ bindings: [Binding], to statement: OpaquePointer) throws {
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let code: Int32
            switch value {
            case .text(let text):
                code = sqlite3_bind_text(statement, index, text, -1,
                                         ATRIA_REPLAY_SQLITE_TRANSIENT)
            case .blob(let data):
                code = data.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(statement, index, bytes.baseAddress,
                                      Int32(bytes.count), ATRIA_REPLAY_SQLITE_TRANSIENT)
                }
            case .int64(let integer):
                code = sqlite3_bind_int64(statement, index, integer)
            case .double(let value):
                code = sqlite3_bind_double(statement, index, value)
            }
            guard code == SQLITE_OK else { throw sqliteError("bind") }
        }
    }

    private func sqliteError(_ operation: String) -> IndexError {
        .sqlite(code: database.map(sqlite3_errcode) ?? SQLITE_MISUSE,
                operation: operation)
    }
}

private let ATRIA_REPLAY_SQLITE_TRANSIENT = unsafeBitCast(
    -1,
    to: sqlite3_destructor_type.self
)
