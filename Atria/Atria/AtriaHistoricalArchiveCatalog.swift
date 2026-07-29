import CryptoKit
import Darwin
import Foundation

/// Durable inventory for immutable, bounded raw history chunks.
///
/// The catalog is intentionally independent of BLE state. It can choose a new
/// append target, but it can never ACK history and can never retire raw without
/// a committed `AtriaHistoricalRetentionTransaction.Manifest`.
struct AtriaHistoricalArchiveCatalog: Codable, Equatable, Sendable {
    static let currentVersion = 2

    struct RawChunk: Codable, Equatable, Sendable {
        enum State: String, Codable, Equatable, Sendable {
            case active
            case sealed
            case retired
        }

        struct CompressedStorage: Codable, Equatable, Sendable {
            static let currentVersion = 1

            let version: Int
            let codec: String
            let sourceRelativePath: String
            let manifestRelativePath: String
            let storedByteCount: UInt64
            let storedSHA256: String
        }

        let id: String
        var relativePath: String
        let createdAt: Date
        var sealedAt: Date?
        var byteCount: UInt64
        var rowCount: Int?
        var firstTimestamp: Date?
        var lastTimestamp: Date?
        var contentSHA256: String?
        var state: State
        var retirementManifestRelativePath: String?
        var compressedStorage: CompressedStorage? = nil

        /// Logical raw bytes remain the replay/aggregate identity. Device
        /// pressure and file verification use the physical representation.
        var storedByteCount: UInt64 { compressedStorage?.storedByteCount ?? byteCount }
    }

    var version: Int
    var generation: UInt64
    var activeChunkID: String
    var chunks: [RawChunk]

    var activeChunk: RawChunk? {
        chunks.first { $0.id == activeChunkID && $0.state == .active }
    }

    func validate() throws {
        guard version == Self.currentVersion else { throw ValidationError.unsupportedVersion }
        let ids = chunks.map(\.id)
        guard Set(ids).count == ids.count else { throw ValidationError.duplicateChunkID }
        let active = chunks.filter { $0.state == .active }
        guard active.count == 1, active.first?.id == activeChunkID else {
            throw ValidationError.invalidActiveChunk
        }
        guard chunks.allSatisfy({ chunk in
            let storageValid: Bool
            if let storage = chunk.compressedStorage {
                storageValid = chunk.state != .active
                    && storage.version == RawChunk.CompressedStorage.currentVersion
                    && storage.codec == "deflate-raw-v1"
                    && Self.safeRelativePath(storage.sourceRelativePath)
                    && Self.safeRelativePath(storage.manifestRelativePath)
                    && storage.sourceRelativePath != chunk.relativePath
                    && storage.storedByteCount > 0
                    && Self.isSHA256(storage.storedSHA256)
                    && chunk.rowCount != nil
                    && chunk.contentSHA256.map(Self.isSHA256) == true
            } else {
                storageValid = true
            }
            return !chunk.id.isEmpty
                && Self.safeRelativePath(chunk.relativePath)
                && chunk.byteCount >= 0
                && (chunk.state == .active ? chunk.sealedAt == nil : chunk.sealedAt != nil)
                && (chunk.state == .retired ? chunk.retirementManifestRelativePath != nil : true)
                && storageValid
        }) else {
            throw ValidationError.invalidChunk
        }
    }

    enum ValidationError: Error, Equatable {
        case unsupportedVersion
        case duplicateChunkID
        case invalidActiveChunk
        case invalidChunk
    }

    private static func safeRelativePath(_ value: String) -> Bool {
        guard !value.isEmpty, !value.hasPrefix("/") else { return false }
        return !value.split(separator: "/", omittingEmptySubsequences: false)
            .contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "0123456789abcdef").contains($0)
        }
    }
}

final class AtriaHistoricalArchiveCatalogStore {
    static let productionMaximumActiveBytes: UInt64 = 32 * 1024 * 1024

    enum StoreError: Error, Equatable {
        case catalogNotLoaded
        case discoveredFileOutsideRoot
        case activeChunkMissing
        case chunkNotSealed
        case retirementManifestMissing
        case sourceStillExists
        case invalidSealedMetadata
        case sealedMetadataConflict
        case sealedContentMismatch
        case catalogFileMismatch
        case invalidCompressedStorage
        case compressedStorageConflict
    }

    struct ActiveChunkDescriptor: Equatable, Sendable {
        let chunkID: String
        let fileURL: URL
        let catalogByteCount: UInt64
    }

    private let lock = NSLock()
    private let rootURL: URL
    private let catalogURL: URL
    private let chunksDirectoryURL: URL
    private let maximumActiveBytes: UInt64
    private let calendar: Calendar
    private let fileManager: FileManager
    private let makeIdentifier: () -> String
    private var catalog: AtriaHistoricalArchiveCatalog?

    init(rootURL: URL,
         maximumActiveBytes: UInt64 = AtriaHistoricalArchiveCatalogStore.productionMaximumActiveBytes,
         calendar: Calendar = .current,
         fileManager: FileManager = .default,
         makeIdentifier: @escaping () -> String = { UUID().uuidString.lowercased() }) {
        precondition(maximumActiveBytes > 0)
        self.rootURL = rootURL.standardizedFileURL
        self.catalogURL = rootURL.appendingPathComponent("historical-archive.catalog-v2.json")
        self.chunksDirectoryURL = rootURL.appendingPathComponent("segments/raw-v2", isDirectory: true)
        self.maximumActiveBytes = maximumActiveBytes
        self.calendar = calendar
        self.fileManager = fileManager
        self.makeIdentifier = makeIdentifier
    }

    /// Loads a valid catalog or reconstructs one without moving/deleting any
    /// discovered raw file. A malformed catalog is preserved as a `.corrupt`
    /// artifact for diagnosis before the recovered catalog is published.
    func loadOrRecover(discoveredLegacyURLs: [URL], now: Date) throws -> AtriaHistoricalArchiveCatalog {
        lock.lock()
        defer { lock.unlock() }
        if var loaded = try? decodeCatalog(at: catalogURL) {
            try loaded.validate()
            // The raw append and catalog publication are intentionally not one
            // transaction. Reconcile the sole active file after a crash so a
            // stale catalog byte count cannot make every verified snapshot
            // fail until the next rotation.
            if let activeIndex = loaded.chunks.firstIndex(where: {
                $0.id == loaded.activeChunkID && $0.state == .active
            }) {
                let activeURL = rootURL.appendingPathComponent(
                    loaded.chunks[activeIndex].relativePath
                )
                let actualBytes = ((try? fileManager.attributesOfItem(
                    atPath: activeURL.path
                )[.size]) as? NSNumber)?.uint64Value ?? 0
                if loaded.chunks[activeIndex].byteCount != actualBytes {
                    loaded.chunks[activeIndex].byteCount = actualBytes
                    loaded.generation &+= 1
                    try persistDurably(loaded)
                }
            }
            catalog = loaded
            return loaded
        }

        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: catalogURL.path) {
            let preserved = rootURL.appendingPathComponent(
                "historical-archive.catalog-v2.corrupt-\(makeIdentifier()).json"
            )
            try fileManager.moveItem(at: catalogURL, to: preserved)
            try Self.synchronizeDirectory(rootURL)
        }

        var chunks: [AtriaHistoricalArchiveCatalog.RawChunk] = []
        for url in discoveredLegacyURLs {
            let canonical = url.standardizedFileURL
            guard canonical.path.hasPrefix(rootURL.path + "/") else {
                throw StoreError.discoveredFileOutsideRoot
            }
            guard fileManager.fileExists(atPath: canonical.path) else { continue }
            let attributes = try fileManager.attributesOfItem(atPath: canonical.path)
            let bytes = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            let modified = (attributes[.modificationDate] as? Date) ?? now
            chunks.append(.init(id: "legacy-\(makeIdentifier())",
                                relativePath: relativePath(for: canonical),
                                createdAt: modified,
                                sealedAt: now,
                                byteCount: bytes,
                                rowCount: nil,
                                firstTimestamp: nil,
                                lastTimestamp: nil,
                                contentSHA256: nil,
                                state: .sealed,
                                retirementManifestRelativePath: nil))
        }
        let active = makeFreshActiveChunk(now: now)
        chunks.append(active)
        let recovered = AtriaHistoricalArchiveCatalog(version: AtriaHistoricalArchiveCatalog.currentVersion,
                                                       generation: 1,
                                                       activeChunkID: active.id,
                                                       chunks: chunks)
        try persistDurably(recovered)
        catalog = recovered
        return recovered
    }

    /// Returns the sole append target, sealing it first at a day boundary or
    /// size boundary. A sealed filename is never made active again.
    func writableChunkURL(now: Date) throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        guard var value = catalog else { throw StoreError.catalogNotLoaded }
        guard let activeIndex = value.chunks.firstIndex(where: {
            $0.id == value.activeChunkID && $0.state == .active
        }) else { throw StoreError.activeChunkMissing }

        let activeURL = rootURL.appendingPathComponent(value.chunks[activeIndex].relativePath)
        let actualBytes = ((try? fileManager.attributesOfItem(atPath: activeURL.path)[.size]) as? NSNumber)?
            .uint64Value ?? 0
        let crossedDay = !calendar.isDate(value.chunks[activeIndex].createdAt, inSameDayAs: now)
        if crossedDay || actualBytes >= maximumActiveBytes {
            value.chunks[activeIndex].state = .sealed
            value.chunks[activeIndex].sealedAt = now
            value.chunks[activeIndex].byteCount = actualBytes
            value.chunks[activeIndex].contentSHA256 = try? AtriaHistoricalRetentionTransaction.sha256(of: activeURL)
            let next = makeFreshActiveChunk(now: now)
            value.chunks.append(next)
            value.activeChunkID = next.id
            value.generation &+= 1
            try persistDurably(value)
            catalog = value
            return rootURL.appendingPathComponent(next.relativePath)
        }

        value.chunks[activeIndex].byteCount = actualBytes
        catalog = value
        return activeURL
    }

    func snapshot() throws -> AtriaHistoricalArchiveCatalog {
        lock.lock()
        defer { lock.unlock() }
        guard let catalog else { throw StoreError.catalogNotLoaded }
        return catalog
    }

    /// A snapshot is proof input only when every live file still has the byte
    /// size recorded by that generation and every sealed digest still matches.
    /// This catches appends to the new active chunk after a terminal record.
    func snapshotVerifiedAgainstFiles() throws -> AtriaHistoricalArchiveCatalog {
        lock.lock()
        defer { lock.unlock() }
        guard let catalog else { throw StoreError.catalogNotLoaded }
        for chunk in catalog.chunks where chunk.state != .retired {
            let url = rootURL.appendingPathComponent(chunk.relativePath)
            let actualBytes = ((try? fileManager.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?
                .uint64Value ?? 0
            guard actualBytes == chunk.storedByteCount else { throw StoreError.catalogFileMismatch }
            if let storage = chunk.compressedStorage {
                guard chunk.state == .sealed,
                      try verifyCompressedStorage(chunk: chunk,
                                                  storage: storage,
                                                  artifactURL: url) else {
                    throw StoreError.catalogFileMismatch
                }
            } else if chunk.state == .sealed, let digest = chunk.contentSHA256 {
                guard fileManager.fileExists(atPath: url.path),
                      try AtriaHistoricalRetentionTransaction.sha256(of: url) == digest else {
                    throw StoreError.catalogFileMismatch
                }
            }
        }
        return catalog
    }

    /// Returns the currently authoritative physical representation. Plain
    /// active/sealed chunks resolve to JSONL; compressed sealed chunks resolve
    /// to their immutable DEFLATE artifact.
    func resolvedFileURL(forChunkID chunkID: String) throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        guard let catalog else { throw StoreError.catalogNotLoaded }
        guard let chunk = catalog.chunks.first(where: { $0.id == chunkID }) else {
            throw StoreError.catalogFileMismatch
        }
        return rootURL.appendingPathComponent(chunk.relativePath)
    }

    /// Atomically changes only the physical storage representation of one
    /// immutable sealed chunk. The original JSONL is deliberately retained;
    /// this method has no unlink API and grants no retirement authority.
    func recordCompressedStorage(chunkID: String,
                                 manifestURL: URL,
                                 artifactURL: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        guard var value = catalog else { throw StoreError.catalogNotLoaded }
        guard let index = value.chunks.firstIndex(where: { $0.id == chunkID }),
              value.chunks[index].state == .sealed else {
            throw StoreError.chunkNotSealed
        }
        let manifest: AtriaHistoricalSealedJSONLCompression.Manifest
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            manifest = try decoder.decode(
                AtriaHistoricalSealedJSONLCompression.Manifest.self,
                from: Data(contentsOf: manifestURL)
            )
        } catch {
            throw StoreError.invalidCompressedStorage
        }
        let artifact = artifactURL.standardizedFileURL
        let manifestFile = manifestURL.standardizedFileURL
        guard artifact.path.hasPrefix(rootURL.path + "/"),
              manifestFile.path.hasPrefix(rootURL.path + "/") else {
            throw StoreError.invalidCompressedStorage
        }
        let artifactRelative = relativePath(for: artifact)
        let manifestRelative = relativePath(for: manifestFile)
        let chunk = value.chunks[index]
        if let existing = chunk.compressedStorage {
            guard chunk.relativePath == artifactRelative,
                  existing.manifestRelativePath == manifestRelative,
                  try verifyCompressedStorage(chunk: chunk,
                                              storage: existing,
                                              artifactURL: artifact) else {
                throw StoreError.compressedStorageConflict
            }
            return
        }
        guard chunk.rowCount != nil,
              let logicalDigest = chunk.contentSHA256,
              manifest.version == AtriaHistoricalSealedJSONLCompression.Manifest.currentVersion,
              manifest.chunkID == chunkID,
              manifest.codec == "deflate-raw-v1",
              manifest.sourceRelativePath == chunk.relativePath,
              manifest.artifactRelativePath == artifactRelative,
              manifestRelative.hasPrefix(AtriaHistoricalSealedJSONLCompression.directoryName + "/"),
              manifest.decodedByteCount == chunk.byteCount,
              manifest.decodedSHA256 == logicalDigest,
              manifest.decodedRowCount == chunk.rowCount,
              manifest.compressedByteCount > 0,
              Self.isSHA256(manifest.compressedSHA256) else {
            throw StoreError.invalidCompressedStorage
        }
        let originalURL = rootURL.appendingPathComponent(chunk.relativePath)
        guard fileManager.fileExists(atPath: originalURL.path),
              try AtriaHistoricalJSONLInput.identity(at: originalURL)
                == .init(byteCount: manifest.decodedByteCount,
                         sha256: manifest.decodedSHA256) else {
            throw StoreError.sealedContentMismatch
        }
        let verified = try AtriaHistoricalSealedJSONLCompression.verifyCompressed(at: artifact)
        guard verified.decodedByteCount == manifest.decodedByteCount,
              verified.decodedSHA256 == manifest.decodedSHA256,
              verified.decodedRowCount == manifest.decodedRowCount,
              verified.compressedByteCount == manifest.compressedByteCount,
              verified.compressedSHA256 == manifest.compressedSHA256 else {
            throw StoreError.invalidCompressedStorage
        }
        value.chunks[index].relativePath = artifactRelative
        value.chunks[index].compressedStorage = .init(
            version: AtriaHistoricalArchiveCatalog.RawChunk.CompressedStorage.currentVersion,
            codec: manifest.codec,
            sourceRelativePath: manifest.sourceRelativePath,
            manifestRelativePath: manifestRelative,
            storedByteCount: manifest.compressedByteCount,
            storedSHA256: manifest.compressedSHA256
        )
        value.generation &+= 1
        try persistDurably(value)
        catalog = value
    }

    /// Catalog-side proof callback for the compression transaction's future
    /// cleanup phase. It verifies mapping and bytes but never removes either
    /// representation itself.
    func verifiesCompressedStorage(
        manifest: AtriaHistoricalSealedJSONLCompression.Manifest,
        artifactURL: URL,
        manifestURL: URL
    ) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let catalog,
              let chunk = catalog.chunks.first(where: { $0.id == manifest.chunkID }),
              let storage = chunk.compressedStorage,
              chunk.relativePath == relativePath(for: artifactURL),
              storage.sourceRelativePath == manifest.sourceRelativePath,
              storage.manifestRelativePath == relativePath(for: manifestURL),
              storage.storedByteCount == manifest.compressedByteCount,
              storage.storedSHA256 == manifest.compressedSHA256,
              chunk.byteCount == manifest.decodedByteCount,
              chunk.contentSHA256 == manifest.decodedSHA256,
              chunk.rowCount == manifest.decodedRowCount else { return false }
        return try verifyCompressedStorage(chunk: chunk,
                                           storage: storage,
                                           artifactURL: artifactURL)
    }

    func activeChunkDescriptor() throws -> ActiveChunkDescriptor {
        lock.lock()
        defer { lock.unlock() }
        guard let catalog else { throw StoreError.catalogNotLoaded }
        guard let active = catalog.activeChunk else { throw StoreError.activeChunkMissing }
        return .init(chunkID: active.id,
                     fileURL: rootURL.appendingPathComponent(active.relativePath),
                     catalogByteCount: active.byteCount)
    }

    /// Publishes the exact post-append size into the in-process generation.
    /// The append remains the source of truth; restart reconciliation above
    /// durably repairs this hint without forcing a catalog fsync for every row.
    func recordAppendCompleted(at fileURL: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        guard var value = catalog,
              let index = value.chunks.firstIndex(where: {
                  $0.id == value.activeChunkID && $0.state == .active
              }) else { throw StoreError.activeChunkMissing }
        let expectedURL = rootURL
            .appendingPathComponent(value.chunks[index].relativePath)
            .standardizedFileURL
        guard fileURL.standardizedFileURL == expectedURL else {
            throw StoreError.catalogFileMismatch
        }
        let actualBytes = ((try? fileManager.attributesOfItem(
            atPath: expectedURL.path
        )[.size]) as? NSNumber)?.uint64Value ?? 0
        value.chunks[index].byteCount = actualBytes
        catalog = value
    }

    /// Seals the current active chunk at a terminal drain boundary and opens a
    /// fresh append target. The caller supplies bounds from the canonical raw
    /// aggregate builder; the file digest and byte count are rechecked here.
    func sealActiveChunkAtTerminal(chunkID: String,
                                   rowCount: Int,
                                   firstTimestamp: Date,
                                   lastTimestamp: Date,
                                   contentSHA256: String,
                                   now: Date) throws {
        lock.lock()
        defer { lock.unlock() }
        let lowercaseHex = CharacterSet(charactersIn: "0123456789abcdef")
        guard rowCount > 0,
              lastTimestamp >= firstTimestamp,
              contentSHA256.count == 64,
              contentSHA256.unicodeScalars.allSatisfy(lowercaseHex.contains) else {
            throw StoreError.invalidSealedMetadata
        }
        guard var value = catalog else { throw StoreError.catalogNotLoaded }
        guard let index = value.chunks.firstIndex(where: {
            $0.id == chunkID && $0.id == value.activeChunkID && $0.state == .active
        }) else { throw StoreError.activeChunkMissing }
        let url = rootURL.appendingPathComponent(value.chunks[index].relativePath)
        let actualBytes = ((try? fileManager.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?
            .uint64Value ?? 0
        guard actualBytes > 0,
              fileManager.fileExists(atPath: url.path),
              try AtriaHistoricalRetentionTransaction.sha256(of: url) == contentSHA256 else {
            throw StoreError.sealedContentMismatch
        }
        value.chunks[index].state = .sealed
        value.chunks[index].sealedAt = now
        value.chunks[index].byteCount = actualBytes
        value.chunks[index].rowCount = rowCount
        value.chunks[index].firstTimestamp = firstTimestamp
        value.chunks[index].lastTimestamp = lastTimestamp
        value.chunks[index].contentSHA256 = contentSHA256
        let next = makeFreshActiveChunk(now: now)
        value.chunks.append(next)
        value.activeChunkID = next.id
        value.generation &+= 1
        try persistDurably(value)
        catalog = value
    }

    /// Finalizes the metric bounds of an already sealed immutable chunk. This
    /// is intentionally a separate durable catalog generation so downstream
    /// proof factories never infer time coverage from filenames or mtimes.
    func recordSealedMetadata(chunkID: String,
                              rowCount: Int,
                              firstTimestamp: Date,
                              lastTimestamp: Date,
                              contentSHA256: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let lowercaseHex = CharacterSet(charactersIn: "0123456789abcdef")
        guard rowCount > 0,
              lastTimestamp >= firstTimestamp,
              contentSHA256.count == 64,
              contentSHA256.unicodeScalars.allSatisfy(lowercaseHex.contains) else {
            throw StoreError.invalidSealedMetadata
        }
        guard var value = catalog else { throw StoreError.catalogNotLoaded }
        guard let index = value.chunks.firstIndex(where: { $0.id == chunkID }),
              value.chunks[index].state == .sealed else {
            throw StoreError.chunkNotSealed
        }
        let chunkURL = rootURL.appendingPathComponent(value.chunks[index].relativePath)
        guard fileManager.fileExists(atPath: chunkURL.path),
              try AtriaHistoricalRetentionTransaction.sha256(of: chunkURL) == contentSHA256 else {
            throw StoreError.sealedContentMismatch
        }
        let existing = value.chunks[index]
        guard existing.rowCount.map({ $0 == rowCount }) ?? true,
              existing.firstTimestamp.map({ $0 == firstTimestamp }) ?? true,
              existing.lastTimestamp.map({ $0 == lastTimestamp }) ?? true,
              existing.contentSHA256.map({ $0 == contentSHA256 }) ?? true else {
            throw StoreError.sealedMetadataConflict
        }
        if existing.rowCount == rowCount,
           existing.firstTimestamp == firstTimestamp,
           existing.lastTimestamp == lastTimestamp,
           existing.contentSHA256 == contentSHA256 {
            return
        }
        value.chunks[index].rowCount = rowCount
        value.chunks[index].firstTimestamp = firstTimestamp
        value.chunks[index].lastTimestamp = lastTimestamp
        value.chunks[index].contentSHA256 = contentSHA256
        value.generation &+= 1
        try persistDurably(value)
        catalog = value
    }

    /// Records retirement only after the transaction manifest and aggregate
    /// verify and the raw source is already absent. This method never deletes.
    func markRetired(chunkID: String,
                     manifestURL: URL,
                     now: Date) throws {
        lock.lock()
        defer { lock.unlock() }
        guard var value = catalog else { throw StoreError.catalogNotLoaded }
        guard let index = value.chunks.firstIndex(where: { $0.id == chunkID }),
              value.chunks[index].state == .sealed else { throw StoreError.chunkNotSealed }
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw StoreError.retirementManifestMissing
        }
        let sourceURL = rootURL.appendingPathComponent(value.chunks[index].relativePath)
        guard !fileManager.fileExists(atPath: sourceURL.path) else { throw StoreError.sourceStillExists }
        value.chunks[index].state = .retired
        value.chunks[index].sealedAt = value.chunks[index].sealedAt ?? now
        value.chunks[index].retirementManifestRelativePath = relativePath(for: manifestURL)
        value.generation &+= 1
        try persistDurably(value)
        catalog = value
    }

    private func makeFreshActiveChunk(now: Date) -> AtriaHistoricalArchiveCatalog.RawChunk {
        let id = makeIdentifier()
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyyMMdd"
        let filename = "raw-\(formatter.string(from: now))-\(id).jsonl"
        let url = chunksDirectoryURL.appendingPathComponent(filename)
        return .init(id: id,
                     relativePath: relativePath(for: url),
                     createdAt: now,
                     sealedAt: nil,
                     byteCount: 0,
                     rowCount: nil,
                     firstTimestamp: nil,
                     lastTimestamp: nil,
                     contentSHA256: nil,
                     state: .active,
                     retirementManifestRelativePath: nil)
    }

    private func verifyCompressedStorage(
        chunk: AtriaHistoricalArchiveCatalog.RawChunk,
        storage: AtriaHistoricalArchiveCatalog.RawChunk.CompressedStorage,
        artifactURL: URL
    ) throws -> Bool {
        let manifestURL = rootURL.appendingPathComponent(storage.manifestRelativePath)
        guard fileManager.fileExists(atPath: artifactURL.path),
              fileManager.fileExists(atPath: manifestURL.path),
              ((try? fileManager.attributesOfItem(atPath: artifactURL.path)[.size]) as? NSNumber)?
                .uint64Value == storage.storedByteCount,
              try AtriaHistoricalRetentionTransaction.sha256(of: artifactURL)
                == storage.storedSHA256 else { return false }
        let manifest: AtriaHistoricalSealedJSONLCompression.Manifest
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            manifest = try decoder.decode(
                AtriaHistoricalSealedJSONLCompression.Manifest.self,
                from: Data(contentsOf: manifestURL)
            )
        } catch { return false }
        guard manifest.chunkID == chunk.id,
              manifest.sourceRelativePath == storage.sourceRelativePath,
              manifest.artifactRelativePath == chunk.relativePath,
              manifest.codec == storage.codec,
              manifest.decodedByteCount == chunk.byteCount,
              manifest.decodedSHA256 == chunk.contentSHA256,
              manifest.decodedRowCount == chunk.rowCount,
              manifest.compressedByteCount == storage.storedByteCount,
              manifest.compressedSHA256 == storage.storedSHA256 else { return false }
        let verified = try AtriaHistoricalSealedJSONLCompression.verifyCompressed(at: artifactURL)
        return verified.decodedByteCount == chunk.byteCount
            && verified.decodedSHA256 == chunk.contentSHA256
            && verified.decodedRowCount == chunk.rowCount
            && verified.compressedByteCount == storage.storedByteCount
            && verified.compressedSHA256 == storage.storedSHA256
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "0123456789abcdef").contains($0)
        }
    }

    private func persistDurably(_ value: AtriaHistoricalArchiveCatalog) throws {
        try value.validate()
        try fileManager.createDirectory(at: catalogURL.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let temporary = catalogURL.deletingLastPathComponent()
            .appendingPathComponent(".\(catalogURL.lastPathComponent).\(UUID().uuidString).tmp")
        guard fileManager.createFile(atPath: temporary.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: temporary)
        do {
            try handle.write(contentsOf: encoder.encode(value))
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            try? fileManager.removeItem(at: temporary)
            throw error
        }
        if fileManager.fileExists(atPath: catalogURL.path) {
            _ = try fileManager.replaceItemAt(catalogURL, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: catalogURL)
        }
        try Self.synchronizeDirectory(catalogURL.deletingLastPathComponent())
    }

    private func decodeCatalog(at url: URL) throws -> AtriaHistoricalArchiveCatalog {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AtriaHistoricalArchiveCatalog.self, from: Data(contentsOf: url))
    }

    private func relativePath(for url: URL) -> String {
        let canonical = url.standardizedFileURL.path
        let root = rootURL.path
        guard canonical.hasPrefix(root + "/") else { return canonical }
        return String(canonical.dropFirst(root.count + 1))
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
}
