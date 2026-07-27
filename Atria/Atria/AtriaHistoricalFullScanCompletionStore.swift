import CryptoKit
import Darwin
import Foundation

/// Durable evidence that one WHOOP full-history scan reached its terminal
/// notification and that the resulting raw source and aggregate catalog were
/// committed. This journal deliberately records observed scan facts only; it
/// does not claim that the strap accepted an app-selected time interval.
final class AtriaHistoricalFullScanCompletionStore {
    struct Record: Codable, Equatable, Sendable {
        static let currentVersion = 1

        let version: Int
        let generation: UInt64
        let transportGeneration: UInt64
        let transportNonce: String
        let peripheralIdentifier: String
        let strapIdentity: String
        /// Upper history time proven by the matched strap range response that
        /// preceded this scan. This bounds historical consumer coverage, not
        /// the aggregate's raw last timestamp: the sealed source can also
        /// contain concurrently observed live rows (and a clock-corrected live
        /// tail) after this cursor. Local terminal time is audit chronology
        /// only.
        let cursorWatermark: Date
        let terminalAt: Date
        let sourceChunkID: String
        let sourceRawSHA256: String
        let sourceFirstTimestamp: Date
        let sourceLastTimestamp: Date
        /// Earliest timestamp present in the exact catalog+aggregate snapshot
        /// hashed by this terminal scan, including deduplicated prior chunks.
        let observedArchiveFirstTimestamp: Date
        let catalogGeneration: UInt64
        let catalogSnapshotSHA256: String
        let aggregateSnapshotSHA256: String
    }

    struct Published: Equatable {
        let record: Record
        let recordURL: URL
        let reusedExistingGeneration: Bool
    }

    enum Checkpoint: Equatable, Sendable {
        case recordDurable
        case recordPublished
        case pointerDurable
    }

    enum StoreError: Error, Equatable {
        case invalidRecord
        case missingCompletion
        case staleGeneration
        case generationConflict
        case pointerInvalid
        case recordMissing
        case recordInvalid
    }

    private struct Pointer: Codable, Equatable {
        static let currentVersion = 1
        let version: Int
        let generation: UInt64
        let recordFilename: String
        let recordSHA256: String
    }

    private let directoryURL: URL
    private let pointerURL: URL
    private let fileManager: FileManager
    private let checkpoint: (Checkpoint) throws -> Void
    private let lock = NSLock()

    init(
        directoryURL: URL,
        fileManager: FileManager = .default,
        checkpoint: @escaping (Checkpoint) throws -> Void = { _ in }
    ) {
        self.directoryURL = directoryURL.standardizedFileURL
        self.pointerURL = directoryURL.appendingPathComponent(
            "historical-full-scan-completion.latest.json"
        )
        self.fileManager = fileManager
        self.checkpoint = checkpoint
    }

    @discardableResult
    func recordCompletion(_ record: Record) throws -> Published {
        // Validate before whole-second ISO-8601 persistence so two invalid
        // subsecond instants cannot collapse into an apparently valid tie.
        try Self.validate(record)
        let persistedRecord: Record
        do {
            persistedRecord = try JSONDecoder.fullScanISO8601.decode(
                Record.self,
                from: Self.canonicalData(record)
            )
        } catch {
            throw StoreError.invalidRecord
        }
        try Self.validate(persistedRecord)
        lock.lock()
        defer { lock.unlock() }
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        if fileManager.fileExists(atPath: pointerURL.path) {
            let existing = try loadLatestLocked()
            guard persistedRecord.generation >= existing.generation else {
                throw StoreError.staleGeneration
            }
            if persistedRecord.generation == existing.generation {
                guard persistedRecord == existing else {
                    throw StoreError.generationConflict
                }
                let data = try Self.canonicalData(persistedRecord)
                return Published(
                    record: persistedRecord,
                    recordURL: recordURL(forDigest: Self.sha256(data)),
                    reusedExistingGeneration: true
                )
            }
        }

        let data = try Self.canonicalData(persistedRecord)
        let digest = Self.sha256(data)
        let recordURL = recordURL(forDigest: digest)
        if fileManager.fileExists(atPath: recordURL.path) {
            guard Self.sha256(try Data(contentsOf: recordURL)) == digest else {
                throw StoreError.recordInvalid
            }
        } else {
            try writeDurably(data, to: recordURL)
        }
        try checkpoint(.recordDurable)
        try Self.synchronizeDirectory(directoryURL)
        try checkpoint(.recordPublished)

        let pointer = Pointer(
            version: Pointer.currentVersion,
            generation: persistedRecord.generation,
            recordFilename: recordURL.lastPathComponent,
            recordSHA256: digest
        )
        let pointerData = try Self.canonicalData(pointer)
        let temporary = directoryURL.appendingPathComponent(
            ".\(pointerURL.lastPathComponent).\(UUID().uuidString).tmp"
        )
        try writeDurably(pointerData, to: temporary)
        try checkpoint(.pointerDurable)
        if fileManager.fileExists(atPath: pointerURL.path) {
            _ = try fileManager.replaceItemAt(pointerURL, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: pointerURL)
        }
        try Self.synchronizeDirectory(directoryURL)
        guard try loadLatestLocked() == persistedRecord else {
            throw StoreError.recordInvalid
        }
        return Published(record: persistedRecord,
                         recordURL: recordURL,
                         reusedExistingGeneration: false)
    }

    func loadLatest() throws -> Record {
        lock.lock()
        defer { lock.unlock() }
        return try loadLatestLocked()
    }

    private func loadLatestLocked() throws -> Record {
        guard fileManager.fileExists(atPath: pointerURL.path) else {
            throw StoreError.missingCompletion
        }
        let pointer: Pointer
        do {
            let data = try Data(contentsOf: pointerURL)
            pointer = try JSONDecoder.fullScanISO8601.decode(Pointer.self, from: data)
            guard try Self.canonicalData(pointer) == data else {
                throw StoreError.pointerInvalid
            }
        } catch let error as StoreError {
            throw error
        } catch {
            throw StoreError.pointerInvalid
        }
        guard pointer.version == Pointer.currentVersion,
              pointer.generation > 0,
              Self.isSHA256(pointer.recordSHA256),
              pointer.recordFilename == "historical-full-scan-completion-\(pointer.recordSHA256).json"
        else { throw StoreError.pointerInvalid }

        let recordURL = directoryURL.appendingPathComponent(pointer.recordFilename)
        guard fileManager.fileExists(atPath: recordURL.path) else {
            throw StoreError.recordMissing
        }
        let data = try Data(contentsOf: recordURL)
        guard Self.sha256(data) == pointer.recordSHA256 else {
            throw StoreError.recordInvalid
        }
        let record: Record
        do {
            record = try JSONDecoder.fullScanISO8601.decode(Record.self, from: data)
        } catch {
            throw StoreError.recordInvalid
        }
        guard try Self.canonicalData(record) == data,
              record.generation == pointer.generation else {
            throw StoreError.recordInvalid
        }
        try Self.validate(record)
        return record
    }

    private func recordURL(forDigest digest: String) -> URL {
        directoryURL.appendingPathComponent(
            "historical-full-scan-completion-\(digest).json"
        )
    }

    private static func validate(_ record: Record) throws {
        let terminal = record.terminalAt.timeIntervalSince1970
        let watermark = record.cursorWatermark.timeIntervalSince1970
        let first = record.sourceFirstTimestamp.timeIntervalSince1970
        let last = record.sourceLastTimestamp.timeIntervalSince1970
        let observedFirst = record.observedArchiveFirstTimestamp.timeIntervalSince1970
        guard record.version == Record.currentVersion,
              record.generation > 0,
              record.transportGeneration > 0,
              !record.transportNonce.isEmpty,
              !record.peripheralIdentifier.isEmpty,
              !record.strapIdentity.isEmpty,
              !record.sourceChunkID.isEmpty,
              terminal.isFinite,
              watermark.isFinite,
              first.isFinite,
              last.isFinite,
              observedFirst.isFinite,
              last >= first,
              observedFirst <= first,
              terminal >= watermark,
              record.catalogGeneration > 0,
              isSHA256(record.sourceRawSHA256),
              isSHA256(record.catalogSnapshotSHA256),
              isSHA256(record.aggregateSnapshotSHA256) else {
            throw StoreError.invalidRecord
        }
    }

    private func writeDurably(_ data: Data, to url: URL) throws {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(descriptor) }
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var written = 0
            while written < data.count {
                let count = Darwin.write(descriptor,
                                         base.advanced(by: written),
                                         data.count - written)
                guard count > 0 else { throw POSIXError(.EIO) }
                written += count
            }
        }
        guard Darwin.fsync(descriptor) == 0 else { throw POSIXError(.EIO) }
    }

    private static func synchronizeDirectory(_ url: URL) throws {
        let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY) }
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw POSIXError(.EIO) }
    }

    private static func canonicalData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder.fullScanISO8601
        return try encoder.encode(value)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isSHA256(_ value: String) -> Bool {
        let hex = CharacterSet(charactersIn: "0123456789abcdef")
        return value.count == 64 && value.unicodeScalars.allSatisfy(hex.contains)
    }
}

private extension JSONEncoder {
    static var fullScanISO8601: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

private extension JSONDecoder {
    static var fullScanISO8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
