import Foundation
import SQLite3

/// Disk-backed exact-identity lookup for the live historical archive.
///
/// This database is deliberately an accelerator, not persistence authority.
/// A hit must still be verified against the canonical raw archive row before
/// it can reject a replay. A miss, malformed database, interrupted upsert, or
/// deleted database must therefore be handled by accepting the frame through
/// the canonical raw + identity-index fsync path.
///
/// In particular, this type has no durability receipt or ACK API. The
/// `AtriaHistoricalArchiveDurableStore` remains the sole owner of those
/// boundaries.
final class AtriaHistoricalLiveIdentityLookup: @unchecked Sendable {
    static let productionMaximumBatchEntries = 4_096

    struct Entry: Equatable, Sendable {
        let stableKey: String
        let observedAtUnix: TimeInterval
        let archivePath: String
        let lineOffset: UInt64
        let lineLength: Int
        let lineCRC32: UInt32

        init(
            stableKey: String,
            observedAtUnix: TimeInterval,
            archivePath: String,
            lineOffset: UInt64,
            lineLength: Int,
            lineCRC32: UInt32
        ) {
            self.stableKey = stableKey
            self.observedAtUnix = observedAtUnix
            self.archivePath = archivePath
            self.lineOffset = lineOffset
            self.lineLength = lineLength
            self.lineCRC32 = lineCRC32
        }
    }

    enum LookupError: Error, Equatable {
        case open(Int32)
        case sqlite(code: Int32, operation: String)
        case invalidIdentity
        case invalidEntry
        case batchCapacityExceeded(maximum: Int)
        case unexpectedJournalMode(String)
        case corruptRow
    }

    private enum Binding {
        case text(String)
        case blob(Data)
        case int64(Int64)
        case double(Double)
    }

    private static let table = "live_history_identity_lookup_v1"
    private let lock = NSLock()
    private let maximumBatchEntries: Int
    private var database: OpaquePointer?

    init(
        databaseURL: URL,
        pageCacheKiB: Int = 2_048,
        maximumBatchEntries: Int =
            AtriaHistoricalLiveIdentityLookup.productionMaximumBatchEntries,
        unsafeDisableDurabilityForTests: Bool = false
    ) throws {
        precondition(maximumBatchEntries > 0)
        self.maximumBatchEntries = maximumBatchEntries

        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var opened: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let code = sqlite3_open_v2(databaseURL.path, &opened, flags, nil)
        guard code == SQLITE_OK, let opened else {
            if let opened { sqlite3_close_v2(opened) }
            throw LookupError.open(code)
        }
        database = opened

        do {
            let journalMode = try scalarText("PRAGMA journal_mode=WAL").lowercased()
            guard journalMode == "wal" else {
                throw LookupError.unexpectedJournalMode(journalMode)
            }
            // This database is rebuildable and never authorizes ACK. NORMAL
            // avoids adding a second FULL-fsync boundary to the canonical
            // archive receipt path. Tests may disable even that derived-store
            // durability to keep large fixtures cheap.
            try execute(
                unsafeDisableDurabilityForTests
                    ? "PRAGMA synchronous=OFF"
                    : "PRAGMA synchronous=NORMAL"
            )
            try execute("PRAGMA temp_store=FILE")
            try execute("PRAGMA busy_timeout=5000")
            try execute("PRAGMA wal_autocheckpoint=256")
            try execute("PRAGMA cache_size=-\(max(256, pageCacheKiB))")
            try execute("""
                CREATE TABLE IF NOT EXISTS \(Self.table) (
                    stable_key BLOB PRIMARY KEY NOT NULL,
                    observed_unix REAL NOT NULL,
                    archive_path TEXT NOT NULL,
                    line_offset INTEGER NOT NULL CHECK(line_offset >= 0),
                    line_length INTEGER NOT NULL CHECK(line_length > 0),
                    line_crc32 INTEGER NOT NULL
                        CHECK(line_crc32 >= 0 AND line_crc32 <= 4294967295)
                ) WITHOUT ROWID
                """)
            try execute("""
                CREATE INDEX IF NOT EXISTS live_history_identity_expiry_v1
                ON \(Self.table)(observed_unix)
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

    /// Returns only a candidate raw-row location. The caller must verify its
    /// CRC and complete decorated stable key against the canonical archive.
    func lookup(stableKey: String) throws -> Entry? {
        let key = try Self.decodeStableKey(stableKey)
        lock.lock()
        defer { lock.unlock() }
        guard let database else { throw LookupError.open(SQLITE_MISUSE) }

        let sql = """
            SELECT observed_unix, archive_path, line_offset, line_length, line_crc32
            FROM \(Self.table) WHERE stable_key = ?
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw sqliteError("prepare_lookup")
        }
        defer { sqlite3_finalize(statement) }
        try bind([.blob(key)], to: statement)

        let step = sqlite3_step(statement)
        if step == SQLITE_DONE { return nil }
        guard step == SQLITE_ROW,
              sqlite3_column_type(statement, 0) == SQLITE_FLOAT,
              sqlite3_column_type(statement, 1) == SQLITE_TEXT,
              sqlite3_column_type(statement, 2) == SQLITE_INTEGER,
              sqlite3_column_type(statement, 3) == SQLITE_INTEGER,
              sqlite3_column_type(statement, 4) == SQLITE_INTEGER,
              let pathPointer = sqlite3_column_text(statement, 1) else {
            throw LookupError.corruptRow
        }

        let observedAtUnix = sqlite3_column_double(statement, 0)
        let archivePath = String(cString: pathPointer)
        let signedOffset = sqlite3_column_int64(statement, 2)
        let signedLength = sqlite3_column_int64(statement, 3)
        let signedCRC32 = sqlite3_column_int64(statement, 4)
        guard observedAtUnix.isFinite,
              !archivePath.isEmpty,
              signedOffset >= 0,
              signedLength > 0,
              signedLength <= Int64(Int.max),
              signedCRC32 >= 0,
              signedCRC32 <= Int64(UInt32.max) else {
            throw LookupError.corruptRow
        }
        return Entry(
            stableKey: stableKey,
            observedAtUnix: observedAtUnix,
            archivePath: archivePath,
            lineOffset: UInt64(signedOffset),
            lineLength: Int(signedLength),
            lineCRC32: UInt32(signedCRC32)
        )
    }

    func upsert(_ entry: Entry) throws {
        try upsert([entry])
    }

    /// Bounded transaction used to publish one canonical archive page's lookup
    /// hints without a prepare/commit round trip per frame.
    func upsert(_ entries: [Entry]) throws {
        guard entries.count <= maximumBatchEntries else {
            throw LookupError.batchCapacityExceeded(maximum: maximumBatchEntries)
        }
        guard !entries.isEmpty else { return }
        let validated = try entries.map { entry in
            (try Self.validate(entry), try Self.decodeStableKey(entry.stableKey))
        }

        lock.lock()
        defer { lock.unlock() }
        guard let database else { throw LookupError.open(SQLITE_MISUSE) }
        try execute("BEGIN IMMEDIATE")
        do {
            let sql = """
                INSERT INTO \(Self.table)
                    (stable_key, observed_unix, archive_path, line_offset,
                     line_length, line_crc32)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(stable_key) DO UPDATE SET
                    observed_unix = MAX(observed_unix, excluded.observed_unix),
                    archive_path = CASE
                        WHEN excluded.observed_unix >= observed_unix
                        THEN excluded.archive_path ELSE archive_path END,
                    line_offset = CASE
                        WHEN excluded.observed_unix >= observed_unix
                        THEN excluded.line_offset ELSE line_offset END,
                    line_length = CASE
                        WHEN excluded.observed_unix >= observed_unix
                        THEN excluded.line_length ELSE line_length END,
                    line_crc32 = CASE
                        WHEN excluded.observed_unix >= observed_unix
                        THEN excluded.line_crc32 ELSE line_crc32 END
                """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement else {
                throw sqliteError("prepare_upsert")
            }
            defer { sqlite3_finalize(statement) }

            for (entry, stableIdentity) in validated {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                guard let signedOffset = Int64(exactly: entry.lineOffset) else {
                    throw LookupError.invalidEntry
                }
                try bind(
                    [
                        .blob(stableIdentity),
                        .double(entry.observedAtUnix),
                        .text(entry.archivePath),
                        .int64(signedOffset),
                        .int64(Int64(entry.lineLength)),
                        .int64(Int64(entry.lineCRC32)),
                    ],
                    to: statement
                )
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw sqliteError("step_upsert")
                }
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    @discardableResult
    func delete(stableKey: String) throws -> Bool {
        let key = try Self.decodeStableKey(stableKey)
        lock.lock()
        defer { lock.unlock() }
        try execute(
            "DELETE FROM \(Self.table) WHERE stable_key = ?",
            bindings: [.blob(key)]
        )
        return changesLocked() == 1
    }

    /// Removes only lookup hints older than the caller-selected observation
    /// horizon. Canonical archive/index rows are untouched.
    @discardableResult
    func prune(observedBefore cutoff: Date) throws -> Int {
        guard cutoff.timeIntervalSince1970.isFinite else {
            throw LookupError.invalidEntry
        }
        lock.lock()
        defer { lock.unlock() }
        try execute(
            "DELETE FROM \(Self.table) WHERE observed_unix < ?",
            bindings: [.double(cutoff.timeIntervalSince1970)]
        )
        return changesLocked()
    }

    func count() throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        return try scalarInt("SELECT COUNT(*) FROM \(Self.table)")
    }

    func journalMode() throws -> String {
        lock.lock()
        defer { lock.unlock() }
        return try scalarText("PRAGMA journal_mode").lowercased()
    }

    private static func validate(_ entry: Entry) throws -> Entry {
        guard entry.observedAtUnix.isFinite,
              !entry.archivePath.isEmpty,
              entry.archivePath.utf8.count <= Int32.max,
              entry.lineOffset <= UInt64(Int64.max),
              entry.lineLength > 0,
              entry.lineLength <= Int(Int32.max) else {
            throw LookupError.invalidEntry
        }
        return entry
    }

    /// Converts the canonical schema-v2 hexadecimal key to its exact binary
    /// representation while validating every length-prefixed component.
    private static func decodeStableKey(_ stableKey: String) throws -> Data {
        guard stableKey.count.isMultiple(of: 2) else {
            throw LookupError.invalidIdentity
        }
        var bytes = [UInt8]()
        bytes.reserveCapacity(stableKey.count / 2)
        var cursor = stableKey.startIndex
        while cursor < stableKey.endIndex {
            let end = stableKey.index(cursor, offsetBy: 2)
            guard let byte = UInt8(stableKey[cursor..<end], radix: 16) else {
                throw LookupError.invalidIdentity
            }
            bytes.append(byte)
            cursor = end
        }

        var offset = 0
        func take(_ count: Int) throws -> ArraySlice<UInt8> {
            guard count >= 0, offset + count <= bytes.count else {
                throw LookupError.invalidIdentity
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

        guard try take(1).first == 2 else {
            throw LookupError.invalidIdentity
        }
        let strapLength = Int(try u32())
        guard let strap = String(bytes: try take(strapLength), encoding: .utf8),
              !strap.isEmpty else {
            throw LookupError.invalidIdentity
        }
        _ = try take(1) // protocol version
        _ = try take(4) // counter
        _ = try take(4) // unix seconds
        _ = try take(2) // subsecond
        let payloadLength = Int(try u32())
        let payload = try take(payloadLength)
        guard offset == bytes.count, !payload.isEmpty else {
            throw LookupError.invalidIdentity
        }
        return Data(bytes)
    }

    private func execute(_ sql: String, bindings: [Binding] = []) throws {
        guard let database else { throw LookupError.open(SQLITE_MISUSE) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw sqliteError("prepare")
        }
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW { step = sqlite3_step(statement) }
        guard step == SQLITE_DONE else { throw sqliteError("step") }
    }

    private func scalarInt(_ sql: String) throws -> Int {
        guard let database else { throw LookupError.open(SQLITE_MISUSE) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw sqliteError("prepare_scalar_int")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw sqliteError("step_scalar_int")
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func scalarText(_ sql: String) throws -> String {
        guard let database else { throw LookupError.open(SQLITE_MISUSE) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw sqliteError("prepare_scalar_text")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let pointer = sqlite3_column_text(statement, 0) else {
            throw sqliteError("step_scalar_text")
        }
        return String(cString: pointer)
    }

    private func changesLocked() -> Int {
        guard let database else { return 0 }
        return Int(sqlite3_changes(database))
    }

    private func bind(_ bindings: [Binding], to statement: OpaquePointer) throws {
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let code: Int32
            switch value {
            case .text(let text):
                code = sqlite3_bind_text(
                    statement,
                    index,
                    text,
                    -1,
                    ATRIA_LIVE_IDENTITY_SQLITE_TRANSIENT
                )
            case .blob(let data):
                code = data.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(
                        statement,
                        index,
                        bytes.baseAddress,
                        Int32(bytes.count),
                        ATRIA_LIVE_IDENTITY_SQLITE_TRANSIENT
                    )
                }
            case .int64(let integer):
                code = sqlite3_bind_int64(statement, index, integer)
            case .double(let value):
                code = sqlite3_bind_double(statement, index, value)
            }
            guard code == SQLITE_OK else { throw sqliteError("bind") }
        }
    }

    private func sqliteError(_ operation: String) -> LookupError {
        .sqlite(
            code: database.map(sqlite3_errcode) ?? SQLITE_MISUSE,
            operation: operation
        )
    }
}

private let ATRIA_LIVE_IDENTITY_SQLITE_TRANSIENT = unsafeBitCast(
    -1,
    to: sqlite3_destructor_type.self
)
