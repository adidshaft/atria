import CryptoKit
import Darwin
import Foundation
import zlib

/// Bounded-memory, byte-preserving storage for immutable historical JSONL.
///
/// This is storage substitution, not semantic retirement. The manifest keeps
/// the original byte identity used by replay and aggregate receipts separate
/// from the physical compressed identity. Production callers must publish that
/// mapping in the archive catalog before authorizing removal of the plain file.
struct AtriaHistoricalSealedJSONLCompression {
    static let directoryName = "compressed-raw-v1"
    static let artifactExtension = "atria-deflate"
    static let manifestExtension = "atria-compression.json"

    struct Manifest: Codable, Equatable, Sendable {
        static let currentVersion = 1

        let version: Int
        let chunkID: String
        let createdAt: Date
        let sourceRelativePath: String
        let artifactRelativePath: String
        let codec: String
        let decodedByteCount: UInt64
        let decodedSHA256: String
        let decodedRowCount: Int
        let compressedByteCount: UInt64
        let compressedSHA256: String
    }

    struct Result: Equatable {
        let manifest: Manifest
        let manifestURL: URL
        let artifactURL: URL
        let sourceDeleted: Bool
        let reusedCommittedArtifact: Bool
    }

    enum TransactionError: Error, Equatable {
        case invalidChunkID
        case sourceOutsideRoot
        case activeSource
        case sourceMissing
        case sourceIsNotRegularFile
        case tornTrailingRow
        case codecFailure
        case artifactConflict
        case manifestConflict
        case decodedByteCountMismatch(expected: UInt64, actual: UInt64)
        case decodedDigestMismatch
        case decodedRowCountMismatch
        case compressedIdentityMismatch
        case verificationFailed
        case sourceChanged
        case deletionNotAuthorized
        case unsafeManifest
    }

    enum Checkpoint: String, CaseIterable, Sendable {
        case artifactTemporaryDurable
        case artifactVerified
        case artifactPublished
        case manifestPublished
        case committedArtifactsVerified
        case sourceDeleted
    }

    private let fileManager: FileManager
    private let now: () -> Date
    private let checkpoint: (Checkpoint) throws -> Void
    /// Must verify that a durable catalog generation resolves the source chunk
    /// to this exact manifest/artifact identity. The safe default denies.
    private let storagePublicationVerifier: (Manifest, URL, URL) throws -> Bool

    init(fileManager: FileManager = .default,
         now: @escaping () -> Date = Date.init,
         checkpoint: @escaping (Checkpoint) throws -> Void = { _ in },
         storagePublicationVerifier: @escaping (Manifest, URL, URL) throws -> Bool = { _, _, _ in false }) {
        self.fileManager = fileManager
        self.now = now
        self.checkpoint = checkpoint
        self.storagePublicationVerifier = storagePublicationVerifier
    }

    /// Publishes a verified compressed artifact and durable manifest. Source
    /// deletion remains fail-closed until the injected catalog verifier proves
    /// the new physical location is authoritative.
    func commit(chunkID: String,
                sourceURL: URL,
                archiveRootURL: URL,
                activeSourceURL: URL,
                deleteSourceAfterCommit: Bool = false,
                chunkSize: Int = 64 * 1024) throws -> Result {
        guard Self.validIdentifier(chunkID), chunkSize > 0 else {
            throw TransactionError.invalidChunkID
        }
        let root = archiveRootURL.standardizedFileURL
        let source = sourceURL.standardizedFileURL
        let active = activeSourceURL.standardizedFileURL
        guard source.path.hasPrefix(root.path + "/") else {
            throw TransactionError.sourceOutsideRoot
        }
        guard source != active else { throw TransactionError.activeSource }

        let sourceResource = try? source.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileResourceIdentifierKey,
        ])
        let activeResource = try? active.resourceValues(forKeys: [.fileResourceIdentifierKey])
        if let sourceIdentifier = sourceResource?.fileResourceIdentifier,
           let activeIdentifier = activeResource?.fileResourceIdentifier,
           String(describing: sourceIdentifier) == String(describing: activeIdentifier) {
            throw TransactionError.activeSource
        }

        let directory = root.appendingPathComponent(Self.directoryName, isDirectory: true)
        let artifactURL = directory.appendingPathComponent(chunkID)
            .appendingPathExtension(Self.artifactExtension)
        let manifestURL = directory.appendingPathComponent(chunkID)
            .appendingPathExtension(Self.manifestExtension)

        if fileManager.fileExists(atPath: manifestURL.path) {
            let manifest = try loadAndVerifyCommitted(manifestURL: manifestURL,
                                                      artifactURL: artifactURL,
                                                      archiveRootURL: root,
                                                      chunkSize: chunkSize)
            guard manifest.chunkID == chunkID,
                  manifest.sourceRelativePath == Self.relativePath(source, under: root) else {
                throw TransactionError.manifestConflict
            }
            let deleted = try finishDeletionIfAuthorized(manifest: manifest,
                                                         sourceURL: source,
                                                         artifactURL: artifactURL,
                                                         manifestURL: manifestURL,
                                                         deleteSourceAfterCommit: deleteSourceAfterCommit,
                                                         chunkSize: chunkSize)
            return .init(manifest: manifest,
                         manifestURL: manifestURL,
                         artifactURL: artifactURL,
                         sourceDeleted: deleted,
                         reusedCommittedArtifact: true)
        }

        guard fileManager.fileExists(atPath: source.path) else {
            throw TransactionError.sourceMissing
        }
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw TransactionError.sourceIsNotRegularFile
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let temporaryArtifact = directory.appendingPathComponent(
            ".\(chunkID).\(UUID().uuidString).artifact.tmp"
        )
        let encoded: StreamIdentity
        do {
            encoded = try Self.encode(sourceURL: source,
                                      destinationURL: temporaryArtifact,
                                      chunkSize: chunkSize)
            try Self.synchronizeFile(temporaryArtifact)
        } catch {
            try? fileManager.removeItem(at: temporaryArtifact)
            throw error
        }
        try checkpoint(.artifactTemporaryDurable)

        let verified = try Self.verifyCompressed(at: temporaryArtifact, chunkSize: chunkSize)
        guard verified.decodedByteCount == encoded.decodedByteCount else {
            try? fileManager.removeItem(at: temporaryArtifact)
            throw TransactionError.decodedByteCountMismatch(expected: encoded.decodedByteCount,
                                                            actual: verified.decodedByteCount)
        }
        guard verified.decodedSHA256 == encoded.decodedSHA256 else {
            try? fileManager.removeItem(at: temporaryArtifact)
            throw TransactionError.decodedDigestMismatch
        }
        guard verified.decodedRowCount == encoded.decodedRowCount else {
            try? fileManager.removeItem(at: temporaryArtifact)
            throw TransactionError.decodedRowCountMismatch
        }
        guard verified.compressedByteCount == encoded.compressedByteCount,
              verified.compressedSHA256 == encoded.compressedSHA256 else {
            try? fileManager.removeItem(at: temporaryArtifact)
            throw TransactionError.compressedIdentityMismatch
        }
        try checkpoint(.artifactVerified)

        let manifest = Manifest(version: Manifest.currentVersion,
                                chunkID: chunkID,
                                createdAt: now(),
                                sourceRelativePath: Self.relativePath(source, under: root),
                                artifactRelativePath: Self.relativePath(artifactURL, under: root),
                                codec: "deflate-raw-v1",
                                decodedByteCount: encoded.decodedByteCount,
                                decodedSHA256: encoded.decodedSHA256,
                                decodedRowCount: encoded.decodedRowCount,
                                compressedByteCount: encoded.compressedByteCount,
                                compressedSHA256: encoded.compressedSHA256)

        if fileManager.fileExists(atPath: artifactURL.path) {
            let existing = try Self.verifyCompressed(at: artifactURL, chunkSize: chunkSize)
            guard existing == verified else {
                try? fileManager.removeItem(at: temporaryArtifact)
                throw TransactionError.artifactConflict
            }
            try? fileManager.removeItem(at: temporaryArtifact)
        } else {
            try fileManager.moveItem(at: temporaryArtifact, to: artifactURL)
            try Self.synchronizeDirectory(directory)
        }
        try checkpoint(.artifactPublished)

        let manifestData = try Self.encoder().encode(manifest)
        let temporaryManifest = directory.appendingPathComponent(
            ".\(chunkID).\(UUID().uuidString).manifest.tmp"
        )
        try Self.writeAndSynchronize(manifestData, to: temporaryManifest)
        if fileManager.fileExists(atPath: manifestURL.path) {
            guard (try? Data(contentsOf: manifestURL)) == manifestData else {
                try? fileManager.removeItem(at: temporaryManifest)
                throw TransactionError.manifestConflict
            }
            try? fileManager.removeItem(at: temporaryManifest)
        } else {
            try fileManager.moveItem(at: temporaryManifest, to: manifestURL)
            try Self.synchronizeDirectory(directory)
        }
        try checkpoint(.manifestPublished)

        let committedManifest = try loadAndVerifyCommitted(manifestURL: manifestURL,
                                                           artifactURL: artifactURL,
                                                           archiveRootURL: root,
                                                           chunkSize: chunkSize)
        try checkpoint(.committedArtifactsVerified)
        let deleted = try finishDeletionIfAuthorized(manifest: committedManifest,
                                                     sourceURL: source,
                                                     artifactURL: artifactURL,
                                                     manifestURL: manifestURL,
                                                     deleteSourceAfterCommit: deleteSourceAfterCommit,
                                                     chunkSize: chunkSize)
        return .init(manifest: committedManifest,
                     manifestURL: manifestURL,
                     artifactURL: artifactURL,
                     sourceDeleted: deleted,
                     reusedCommittedArtifact: false)
    }

    private func finishDeletionIfAuthorized(manifest: Manifest,
                                            sourceURL: URL,
                                            artifactURL: URL,
                                            manifestURL: URL,
                                            deleteSourceAfterCommit: Bool,
                                            chunkSize: Int) throws -> Bool {
        guard deleteSourceAfterCommit else { return false }
        guard try storagePublicationVerifier(manifest, artifactURL, manifestURL) else {
            throw TransactionError.deletionNotAuthorized
        }
        guard fileManager.fileExists(atPath: sourceURL.path) else { return true }
        let identity = try Self.identity(ofPlainFile: sourceURL, chunkSize: chunkSize)
        guard identity.decodedByteCount == manifest.decodedByteCount,
              identity.decodedSHA256 == manifest.decodedSHA256,
              identity.decodedRowCount == manifest.decodedRowCount else {
            throw TransactionError.sourceChanged
        }
        _ = try loadAndVerifyCommitted(manifestURL: manifestURL,
                                       artifactURL: artifactURL,
                                       archiveRootURL: sourceURL.deletingLastPathComponent(),
                                       validateRelativePaths: false,
                                       chunkSize: chunkSize)
        try fileManager.removeItem(at: sourceURL)
        try Self.synchronizeDirectory(sourceURL.deletingLastPathComponent())
        try checkpoint(.sourceDeleted)
        return true
    }

    private func loadAndVerifyCommitted(manifestURL: URL,
                                        artifactURL: URL,
                                        archiveRootURL: URL,
                                        validateRelativePaths: Bool = true,
                                        chunkSize: Int) throws -> Manifest {
        let manifest: Manifest
        do { manifest = try Self.decoder().decode(Manifest.self, from: Data(contentsOf: manifestURL)) }
        catch { throw TransactionError.manifestConflict }
        guard manifest.version == Manifest.currentVersion,
              manifest.codec == "deflate-raw-v1",
              Self.validIdentifier(manifest.chunkID),
              !manifest.sourceRelativePath.isEmpty,
              !manifest.artifactRelativePath.isEmpty else {
            throw TransactionError.unsafeManifest
        }
        if validateRelativePaths {
            guard Self.safeRelativePath(manifest.sourceRelativePath),
                  Self.safeRelativePath(manifest.artifactRelativePath),
                  archiveRootURL.appendingPathComponent(manifest.artifactRelativePath)
                    .standardizedFileURL == artifactURL.standardizedFileURL else {
                throw TransactionError.unsafeManifest
            }
        }
        let verified = try Self.verifyCompressed(at: artifactURL, chunkSize: chunkSize)
        guard verified.decodedByteCount == manifest.decodedByteCount,
              verified.decodedSHA256 == manifest.decodedSHA256,
              verified.decodedRowCount == manifest.decodedRowCount,
              verified.compressedByteCount == manifest.compressedByteCount,
              verified.compressedSHA256 == manifest.compressedSHA256 else {
            throw TransactionError.verificationFailed
        }
        return manifest
    }

    struct StreamIdentity: Equatable {
        let decodedByteCount: UInt64
        let decodedSHA256: String
        let decodedRowCount: Int
        let compressedByteCount: UInt64
        let compressedSHA256: String
    }

    static func verifyCompressed(at url: URL,
                                 chunkSize: Int = 64 * 1024) throws -> StreamIdentity {
        var decodedHasher = SHA256()
        var decodedBytes: UInt64 = 0
        var rows = 0
        try AtriaHistoricalJSONLInput.forEachCompressedChunk(at: url, chunkSize: chunkSize) { chunk in
            decodedHasher.update(data: chunk)
            decodedBytes &+= UInt64(chunk.count)
            rows += chunk.reduce(into: 0) { $0 += $1 == 0x0a ? 1 : 0 }
        }
        let physical = try identityOfPhysicalFile(url, chunkSize: chunkSize)
        return .init(decodedByteCount: decodedBytes,
                     decodedSHA256: decodedHasher.finalize().hexString,
                     decodedRowCount: rows,
                     compressedByteCount: physical.bytes,
                     compressedSHA256: physical.sha256)
    }

    private static func identity(ofPlainFile url: URL, chunkSize: Int) throws -> StreamIdentity {
        var hasher = SHA256()
        var bytes: UInt64 = 0
        var rows = 0
        var lastByte: UInt8?
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            hasher.update(data: chunk)
            bytes &+= UInt64(chunk.count)
            rows += chunk.reduce(into: 0) { $0 += $1 == 0x0a ? 1 : 0 }
            lastByte = chunk.last
        }
        guard bytes == 0 || lastByte == 0x0a else { throw TransactionError.tornTrailingRow }
        let digest = hasher.finalize().hexString
        return .init(decodedByteCount: bytes,
                     decodedSHA256: digest,
                     decodedRowCount: rows,
                     compressedByteCount: bytes,
                     compressedSHA256: digest)
    }

    private static func encode(sourceURL: URL,
                               destinationURL: URL,
                               chunkSize: Int) throws -> StreamIdentity {
        guard fileManagerCreateEmptyFile(destinationURL) else { throw CocoaError(.fileWriteUnknown) }
        let source = try FileHandle(forReadingFrom: sourceURL)
        let destination = try FileHandle(forWritingTo: destinationURL)
        defer { try? source.close(); try? destination.close() }
        var stream = z_stream()
        guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -MAX_WBITS, 8,
                           Z_DEFAULT_STRATEGY, ZLIB_VERSION,
                           Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw TransactionError.codecFailure
        }
        defer { deflateEnd(&stream) }
        let output = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { output.deallocate() }
        var decodedHasher = SHA256()
        var compressedHasher = SHA256()
        var decodedBytes: UInt64 = 0
        var compressedBytes: UInt64 = 0
        var rows = 0
        var lastByte: UInt8?

        func pump(_ data: Data, flush: Int32) throws -> Int32 {
            try data.withUnsafeBytes { raw -> Int32 in
                stream.next_in = UnsafeMutablePointer<Bytef>(mutating: raw.bindMemory(to: UInt8.self).baseAddress)
                stream.avail_in = uInt(data.count)
                var status: Int32 = Z_OK
                repeat {
                    stream.next_out = output
                    stream.avail_out = uInt(chunkSize)
                    status = deflate(&stream, flush)
                    guard status == Z_OK || status == Z_STREAM_END else {
                        throw TransactionError.codecFailure
                    }
                    let produced = chunkSize - Int(stream.avail_out)
                    if produced > 0 {
                        let chunk = Data(bytes: output, count: produced)
                        try destination.write(contentsOf: chunk)
                        compressedHasher.update(data: chunk)
                        compressedBytes &+= UInt64(produced)
                    }
                } while stream.avail_in > 0 || (flush == Z_FINISH && status != Z_STREAM_END)
                return status
            }
        }

        while let chunk = try source.read(upToCount: chunkSize), !chunk.isEmpty {
            decodedHasher.update(data: chunk)
            decodedBytes &+= UInt64(chunk.count)
            rows += chunk.reduce(into: 0) { $0 += $1 == 0x0a ? 1 : 0 }
            lastByte = chunk.last
            _ = try pump(chunk, flush: Z_NO_FLUSH)
        }
        guard decodedBytes == 0 || lastByte == 0x0a else { throw TransactionError.tornTrailingRow }
        _ = try pump(Data(), flush: Z_FINISH)
        return .init(decodedByteCount: decodedBytes,
                     decodedSHA256: decodedHasher.finalize().hexString,
                     decodedRowCount: rows,
                     compressedByteCount: compressedBytes,
                     compressedSHA256: compressedHasher.finalize().hexString)
    }

    private static func identityOfPhysicalFile(_ url: URL,
                                               chunkSize: Int) throws -> (bytes: UInt64, sha256: String) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var bytes: UInt64 = 0
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            hasher.update(data: chunk)
            bytes &+= UInt64(chunk.count)
        }
        return (bytes, hasher.finalize().hexString)
    }

    private static func writeAndSynchronize(_ data: Data, to url: URL) throws {
        guard fileManagerCreateEmptyFile(url) else { throw CocoaError(.fileWriteUnknown) }
        let handle = try FileHandle(forWritingTo: url)
        do { try handle.write(contentsOf: data); try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw error }
    }

    private static func fileManagerCreateEmptyFile(_ url: URL) -> Bool {
        FileManager.default.createFile(atPath: url.path, contents: nil)
    }

    private static func synchronizeFile(_ url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.synchronize()
        try handle.close()
    }

    private static func synchronizeDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    private static func relativePath(_ url: URL, under root: URL) -> String {
        String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
    }

    private static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 128
            && value.unicodeScalars.allSatisfy { scalar in
                CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_"
            }
    }

    private static func safeRelativePath(_ value: String) -> Bool {
        guard !value.isEmpty, !value.hasPrefix("/") else { return false }
        return !value.split(separator: "/", omittingEmptySubsequences: false)
            .contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// Shared raw-input seam. Plain JSONL remains seekable elsewhere; compressed
/// sealed sources are immutable and are always decoded from byte zero.
enum AtriaHistoricalJSONLInput {
    enum InputError: Error, Equatable { case corruptCompressedStream }

    struct Identity: Equatable {
        let byteCount: UInt64
        let sha256: String
    }

    static func identity(at url: URL, chunkSize: Int = 64 * 1024) throws -> Identity {
        var hasher = SHA256()
        var byteCount: UInt64 = 0
        try forEachChunk(at: url, chunkSize: chunkSize) { chunk in
            hasher.update(data: chunk)
            byteCount &+= UInt64(chunk.count)
        }
        return .init(byteCount: byteCount, sha256: hasher.finalize().hexString)
    }

    static func forEachChunk(at url: URL,
                             chunkSize: Int = 64 * 1024,
                             consume: (Data) throws -> Void) throws {
        precondition(chunkSize > 0)
        if url.pathExtension != AtriaHistoricalSealedJSONLCompression.artifactExtension {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
                try consume(chunk)
            }
            return
        }
        try decodeRawDeflate(at: url, chunkSize: chunkSize, consume: consume)
    }

    static func forEachCompressedChunk(at url: URL,
                                       chunkSize: Int = 64 * 1024,
                                       consume: (Data) throws -> Void) throws {
        precondition(chunkSize > 0)
        try decodeRawDeflate(at: url, chunkSize: chunkSize, consume: consume)
    }

    static func forEachLine(at url: URL,
                            chunkSize: Int = 64 * 1024,
                            includeTrailingNewline: Bool = false,
                            consume: (Data) throws -> Void) throws {
        var carry = Data()
        try forEachChunk(at: url, chunkSize: chunkSize) { chunk in
            carry.append(chunk)
            while let newline = carry.firstIndex(of: 0x0a) {
                let end = includeTrailingNewline ? carry.index(after: newline) : newline
                try consume(Data(carry[carry.startIndex..<end]))
                carry.removeSubrange(carry.startIndex...newline)
            }
        }
        guard carry.isEmpty else {
            throw AtriaHistoricalSealedJSONLCompression.TransactionError.tornTrailingRow
        }
    }

    private static func decodeRawDeflate(at url: URL,
                                         chunkSize: Int,
                                         consume: (Data) throws -> Void) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var stream = z_stream()
        guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION,
                           Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw InputError.corruptCompressedStream
        }
        defer { inflateEnd(&stream) }
        let output = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { output.deallocate() }
        var reachedEnd = false
        while let input = try handle.read(upToCount: chunkSize), !input.isEmpty {
            try input.withUnsafeBytes { raw in
                stream.next_in = UnsafeMutablePointer<Bytef>(mutating: raw.bindMemory(to: UInt8.self).baseAddress)
                stream.avail_in = uInt(input.count)
                var shouldContinue = true
                while shouldContinue {
                    stream.next_out = output
                    stream.avail_out = uInt(chunkSize)
                    let status = inflate(&stream, Z_NO_FLUSH)
                    let produced = chunkSize - Int(stream.avail_out)
                    if produced > 0 { try consume(Data(bytes: output, count: produced)) }
                    if status == Z_STREAM_END {
                        guard stream.avail_in == 0, !reachedEnd else {
                            throw InputError.corruptCompressedStream
                        }
                        reachedEnd = true
                        break
                    }
                    // A full output buffer makes us call inflate again even
                    // after the current input block was consumed. If zlib had
                    // no buffered expansion left, that probe legitimately
                    // returns Z_BUF_ERROR with no progress. It is not stream
                    // corruption: fetch the next physical input block. EOF is
                    // still rejected by the final `reachedEnd` guard below.
                    if status == Z_BUF_ERROR,
                       produced == 0,
                       stream.avail_in == 0 {
                        shouldContinue = false
                        continue
                    }
                    guard status == Z_OK else {
                        throw InputError.corruptCompressedStream
                    }
                    if produced == 0, stream.avail_in == 0 {
                        shouldContinue = false
                        continue
                    }
                    // DEFLATE can consume a tiny input block while retaining a
                    // much larger expansion internally. A full output buffer
                    // must be drained even when `avail_in` has reached zero.
                    shouldContinue = stream.avail_in > 0 || stream.avail_out == 0
                }
            }
            if reachedEnd {
                guard (try handle.read(upToCount: 1) ?? Data()).isEmpty else {
                    throw InputError.corruptCompressedStream
                }
                break
            }
        }
        guard reachedEnd else { throw InputError.corruptCompressedStream }
    }
}

private extension SHA256.Digest {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
