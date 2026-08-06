import CryptoKit
import Foundation

/// Incrementally frames objects from the trusted top-level SavedSession JSON
/// array. It avoids allocating another copy of a multi-hundred-megabyte cold
/// source while the app already holds its normal in-memory model.
struct AtriaColdSessionSourceScanner {
    static let maximumEncodedSessionBytes = 64 * 1_024 * 1_024

    struct Result: Equatable, Sendable {
        let sha256: String
        let byteCount: UInt64
        let sessionCount: Int
        /// Hard upper bound for the scanner's per-session framing buffer during
        /// this pass. This is intentionally observable so launch migration can
        /// prove it never allocated a source-sized `Data` value.
        let largestEncodedSessionBytes: Int
    }

    /// Result of streaming a cold source directly into the caller's canonical
    /// in-memory model. `scan` keeps at most one encoded session object in its
    /// framing buffer; this facade therefore avoids a whole-file `Data` buffer
    /// and a second temporary `[SavedSession]` allocation at launch.
    struct AppendResult: Equatable, Sendable {
        let source: Result
        let appendedSessionCount: Int
    }

    enum ScanError: Error, Equatable {
        case malformedTopLevelArray
        case unterminatedObject
        case trailingContent
        case sessionTooLarge(Int)
        case sessionDecodeFailed(Int)
    }

    static func scan(url: URL,
                     onSession: (SavedSession) throws -> Void) throws -> Result {
        try scanFrames(url: url) { session, _ in
            try onSession(session)
        }
    }

    /// Variant used by full-fidelity migration. The encoded bytes are the exact
    /// object frame from the source array and are valid only for the duration of
    /// the callback. Callers may compress/write that one object, but must not
    /// accumulate frames from the whole source.
    static func scanFrames(url: URL,
                           onSession: (SavedSession, Data) throws -> Void) throws -> Result {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var bytes: UInt64 = 0
        var started = false
        var finished = false
        var expectingValue = true
        var capturing = false
        var depth = 0
        var inString = false
        var escaped = false
        var object = Data()
        var sessionCount = 0
        var largestEncodedSessionBytes = 0

        while true {
            let block = try handle.read(upToCount: 64 * 1_024) ?? Data()
            if block.isEmpty { break }
            hasher.update(data: block)
            let (updatedBytes, overflow) = bytes.addingReportingOverflow(UInt64(block.count))
            guard !overflow else { throw ScanError.malformedTopLevelArray }
            bytes = updatedBytes
            for byte in block {
                if finished {
                    guard isWhitespace(byte) else { throw ScanError.trailingContent }
                    continue
                }
                if capturing {
                    object.append(byte)
                    guard object.count <= maximumEncodedSessionBytes else {
                        throw ScanError.sessionTooLarge(sessionCount)
                    }
                    if inString {
                        if escaped {
                            escaped = false
                        } else if byte == 0x5c {
                            escaped = true
                        } else if byte == 0x22 {
                            inString = false
                        }
                        continue
                    }
                    if byte == 0x22 {
                        inString = true
                    } else if byte == 0x7b {
                        depth += 1
                    } else if byte == 0x7d {
                        depth -= 1
                        guard depth >= 0 else { throw ScanError.malformedTopLevelArray }
                        if depth == 0 {
                            let session: SavedSession
                            do { session = try JSONDecoder().decode(SavedSession.self, from: object) }
                            catch { throw ScanError.sessionDecodeFailed(sessionCount) }
                            largestEncodedSessionBytes = max(largestEncodedSessionBytes, object.count)
                            try onSession(session, object)
                            sessionCount += 1
                            object.removeAll(keepingCapacity: true)
                            capturing = false
                            expectingValue = false
                        }
                    }
                    continue
                }

                if !started {
                    if isWhitespace(byte) { continue }
                    guard byte == 0x5b else { throw ScanError.malformedTopLevelArray }
                    started = true
                    continue
                }
                if isWhitespace(byte) { continue }
                if byte == 0x2c {
                    guard !expectingValue else { throw ScanError.malformedTopLevelArray }
                    expectingValue = true
                    continue
                }
                if byte == 0x5d {
                    // An empty array may close while expecting its first value;
                    // a non-empty array may not close immediately after a comma.
                    guard !expectingValue || sessionCount == 0 else {
                        throw ScanError.malformedTopLevelArray
                    }
                    finished = true
                    continue
                }
                guard expectingValue, byte == 0x7b else {
                    throw ScanError.malformedTopLevelArray
                }
                capturing = true
                depth = 1
                inString = false
                escaped = false
                object.removeAll(keepingCapacity: true)
                object.append(byte)
            }
        }
        guard started, finished, !capturing else {
            throw capturing ? ScanError.unterminatedObject : ScanError.malformedTopLevelArray
        }
        return .init(sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined(),
                     byteCount: bytes,
                     sessionCount: sessionCount,
                     largestEncodedSessionBytes: largestEncodedSessionBytes)
    }

    /// Streams full-fidelity sessions into `destination`, excluding IDs that
    /// are already owned by the hot tier. Publication is transactional: if any
    /// byte or session fails validation, every session appended during this
    /// attempt is removed and the caller sees its original array unchanged.
    ///
    /// The exclusion set is intentionally frozen before scanning. This matches
    /// the legacy hot/cold union exactly: duplicate IDs inside the cold source
    /// are preserved, while any ID present in the hot source is excluded.
    static func appendFullFidelitySessions(from url: URL,
                                           to destination: inout [SavedSession],
                                           excludingIDs: Set<UUID>) throws -> AppendResult {
        let originalCount = destination.count
        do {
            let source = try scan(url: url) { session in
                guard !excludingIDs.contains(session.id) else { return }
                destination.append(session)
            }
            return AppendResult(source: source,
                                appendedSessionCount: destination.count - originalCount)
        } catch {
            if destination.count > originalCount {
                destination.removeSubrange(originalCount...)
            }
            throw error
        }
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0a || byte == 0x0d
    }
}
