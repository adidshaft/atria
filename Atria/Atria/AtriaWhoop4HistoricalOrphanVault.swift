import CryptoKit
import Darwin
import Foundation

/// A bounded, fsynced safety vault for exact history ingress left by a prior
/// process. It is deliberately separate from `HistoricalArchive`: sealing a
/// real frame must never wait for a large derived identity-index rebuild.
///
/// A vault entry is raw-only evidence. It does not authorize a strap ACK,
/// cursor advance, admission write, decoded metric publication, or historical
/// gap coverage. A later canonical promotion replays the exact spool through
/// the normal archive and retires the entry only after that archive flushes.
final class AtriaWhoop4HistoricalOrphanVault {
    static let productionDirectoryName = "atria-historical/history-orphan-vault-v1"
    static let productionMaximumBytes: UInt64 = 64 * 1024 * 1024

    struct Entry: Codable, Equatable, Sendable {
        let schema: Int
        let id: UUID
        let fileName: String
        let strapIdentifier: String
        let generation: UInt64
        let byteCount: UInt64
        let sha256: String
        let sealedAtUnix: TimeInterval
    }

    enum VaultError: Error, Equatable {
        case sourceMissing
        case invalidSpool
        case capacityExceeded
        case digestMismatch
        case corruptManifest
        case ownerMismatch
    }

    private let directoryURL: URL
    private let maximumBytes: UInt64
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    init(directoryURL: URL,
         maximumBytes: UInt64 = productionMaximumBytes,
         fileManager: FileManager = .default) throws {
        self.directoryURL = directoryURL.standardizedFileURL
        self.maximumBytes = maximumBytes
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try fileManager.createDirectory(at: self.directoryURL,
                                        withIntermediateDirectories: true)
        try removeUnsealedArtifacts()
    }

    static func production() throws -> AtriaWhoop4HistoricalOrphanVault {
        let root = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return try AtriaWhoop4HistoricalOrphanVault(
            directoryURL: root.appendingPathComponent(productionDirectoryName,
                                                       isDirectory: true)
        )
    }

    /// Cheap MainActor admission check. Full manifest/hash validation remains
    /// on the archive worker; this merely avoids scheduling empty work from
    /// every accepted heart-rate callback.
    static func hasPotentialProductionEntries(fileManager: FileManager = .default) -> Bool {
        let root = fileManager.urls(for: .applicationSupportDirectory,
                                    in: .userDomainMask)[0]
            .appendingPathComponent(productionDirectoryName, isDirectory: true)
        return (try? fileManager.contentsOfDirectory(at: root,
                                                      includingPropertiesForKeys: nil,
                                                      options: [.skipsHiddenFiles]))?.contains {
            $0.lastPathComponent.hasSuffix(".manifest.json")
        } ?? false
    }

    /// Copies and fsyncs a previously closed ingress spool before returning a
    /// manifest-bound entry. The caller must retain the source until this call
    /// succeeds, and may then remove it only after re-validating the returned
    /// entry. Repeating the operation is idempotent.
    func seal(sourceURL: URL,
              strapIdentifier: String,
              generation: UInt64,
              now: Date = Date()) throws -> Entry {
        let source = sourceURL.standardizedFileURL
        guard fileManager.fileExists(atPath: source.path) else {
            throw VaultError.sourceMissing
        }
        guard try AtriaWhoop4HistoricalIngressSpool.generation(at: source) == generation else {
            throw VaultError.invalidSpool
        }
        // Reopening validates every complete record (and repairs only a torn
        // terminal write, which never crossed a canonical ACK boundary).
        _ = try AtriaWhoop4HistoricalIngressSpool(url: source, generation: generation)
        let sourceDigest = try digest(of: source)
        let sourceBytes = try byteCount(of: source)
        guard sourceBytes <= maximumBytes else { throw VaultError.capacityExceeded }

        if let existing = try validatedEntries(for: strapIdentifier).first(where: {
            $0.generation == generation
                && $0.byteCount == sourceBytes
                && $0.sha256 == sourceDigest
        }) {
            return existing
        }

        let existingBytes = try validatedEntries(for: nil).reduce(UInt64(0)) {
            $0 &+ $1.byteCount
        }
        guard existingBytes <= maximumBytes,
              sourceBytes <= maximumBytes - existingBytes else {
            throw VaultError.capacityExceeded
        }

        let id = UUID()
        let fileName = "\(id.uuidString.lowercased()).bin"
        let destination = directoryURL.appendingPathComponent(fileName)
        let temporary = directoryURL.appendingPathComponent(".\(fileName).tmp")
        try copyAndSynchronize(source: source, destination: temporary)
        let copiedDigest = try digest(of: temporary)
        guard copiedDigest == sourceDigest,
              try byteCount(of: temporary) == sourceBytes else {
            try? fileManager.removeItem(at: temporary)
            throw VaultError.digestMismatch
        }
        try fileManager.moveItem(at: temporary, to: destination)
        try synchronizeDirectory(directoryURL)

        let entry = Entry(schema: 1,
                          id: id,
                          fileName: fileName,
                          strapIdentifier: strapIdentifier,
                          generation: generation,
                          byteCount: sourceBytes,
                          sha256: sourceDigest,
                          sealedAtUnix: now.timeIntervalSince1970)
        try writeManifest(entry)
        _ = try validatedEntry(entry)
        return entry
    }

    func validatedEntries(for strapIdentifier: String?) throws -> [Entry] {
        let manifests = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.lastPathComponent.hasSuffix(".manifest.json") }
        return try manifests.compactMap { url in
            guard let entry = try? decoder.decode(Entry.self, from: Data(contentsOf: url)) else {
                throw VaultError.corruptManifest
            }
            let validated = try validatedEntry(entry)
            guard strapIdentifier == nil || validated.strapIdentifier == strapIdentifier else {
                return nil
            }
            return validated
        }
        .sorted { lhs, rhs in
            if lhs.sealedAtUnix != rhs.sealedAtUnix { return lhs.sealedAtUnix < rhs.sealedAtUnix }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    func spool(for entry: Entry) throws -> AtriaWhoop4HistoricalIngressSpool {
        let checked = try validatedEntry(entry)
        return try AtriaWhoop4HistoricalIngressSpool(
            url: directoryURL.appendingPathComponent(checked.fileName),
            generation: checked.generation
        )
    }

    /// Only call after the canonical archive's durability boundary succeeds.
    func retire(_ entry: Entry) throws {
        let checked = try validatedEntry(entry)
        let manifest = manifestURL(for: checked)
        let file = directoryURL.appendingPathComponent(checked.fileName)
        try fileManager.removeItem(at: manifest)
        try fileManager.removeItem(at: file)
        try synchronizeDirectory(directoryURL)
    }

    private func validatedEntry(_ entry: Entry) throws -> Entry {
        guard entry.schema == 1,
              entry.id.uuidString.lowercased() + ".bin" == entry.fileName,
              entry.generation > 0,
              entry.byteCount > 0,
              entry.sha256.count == 64,
              !entry.strapIdentifier.isEmpty else {
            throw VaultError.corruptManifest
        }
        let file = directoryURL.appendingPathComponent(entry.fileName).standardizedFileURL
        guard file.deletingLastPathComponent() == directoryURL,
              fileManager.fileExists(atPath: file.path),
              try byteCount(of: file) == entry.byteCount,
              try digest(of: file) == entry.sha256,
              try AtriaWhoop4HistoricalIngressSpool.generation(at: file) == entry.generation else {
            throw VaultError.digestMismatch
        }
        return entry
    }

    private func writeManifest(_ entry: Entry) throws {
        let destination = manifestURL(for: entry)
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).tmp")
        do {
            try encoder.encode(entry).write(to: temporary, options: [])
            try synchronizeFile(temporary)
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: destination)
            }
            try synchronizeDirectory(directoryURL)
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    private func manifestURL(for entry: Entry) -> URL {
        directoryURL.appendingPathComponent("\(entry.id.uuidString.lowercased()).manifest.json")
    }

    private func removeUnsealedArtifacts() throws {
        let urls = try fileManager.contentsOfDirectory(at: directoryURL,
                                                        includingPropertiesForKeys: nil,
                                                        options: [])
        let manifestNames = Set(urls
            .filter { $0.lastPathComponent.hasSuffix(".manifest.json") }
            .map { $0.deletingPathExtension().deletingPathExtension().lastPathComponent + ".bin" })
        for url in urls {
            let name = url.lastPathComponent
            if name.hasPrefix(".") && name.hasSuffix(".tmp") {
                try? fileManager.removeItem(at: url)
            } else if name.hasSuffix(".bin") && !manifestNames.contains(name) {
                // A crash before the manifest is never allowed to authorize
                // removal of the source spool, so this orphaned copy is safe
                // to reclaim on the next initialization.
                try? fileManager.removeItem(at: url)
            }
        }
    }

    private func byteCount(of url: URL) throws -> UInt64 {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    }

    private func digest(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func copyAndSynchronize(source: URL, destination: URL) throws {
        guard fileManager.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let reader = try FileHandle(forReadingFrom: source)
        let writer = try FileHandle(forWritingTo: destination)
        defer {
            try? reader.close()
            try? writer.close()
        }
        while let chunk = try reader.read(upToCount: 64 * 1024), !chunk.isEmpty {
            try writer.write(contentsOf: chunk)
        }
        try writer.synchronize()
    }

    private func synchronizeFile(_ url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    private func synchronizeDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw CocoaError(.fileNoSuchFile) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}
