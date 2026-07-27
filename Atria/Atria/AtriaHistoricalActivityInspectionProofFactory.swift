import CryptoKit
import Darwin
import Foundation

/// Crash-safe terminal authority for one fully drained historical scan.
/// A content-addressed record is durable before the small latest pointer is
/// published; orphan records are never interpreted as completed drains.
final class AtriaHistoricalDrainCompletionGenerationStore {
    struct Record: Codable, Equatable, Sendable {
        static let currentVersion = 1

        enum Disposition: String, Codable, Equatable, Sendable {
            case terminal
        }

        let version: Int
        let generation: UInt64
        let terminalBatchNumber: UInt64
        let durableSequence: UInt64
        let requestedStart: Date
        let requestedEnd: Date
        let completedAt: Date
        let catalogGeneration: UInt64
        let catalogSnapshotSHA256: String
        let aggregateSnapshotSHA256: String
        let disposition: Disposition
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

    init(directoryURL: URL,
         fileManager: FileManager = .default,
         checkpoint: @escaping (Checkpoint) throws -> Void = { _ in }) {
        self.directoryURL = directoryURL
        self.pointerURL = directoryURL.appendingPathComponent("history-drain-completion.latest.json")
        self.fileManager = fileManager
        self.checkpoint = checkpoint
    }

    /// Minimal later-wiring API: invoke only after the terminal drain boundary,
    /// its final durable archive flush, and aggregate commits have succeeded.
    func recordTerminal(
        generation: UInt64,
        terminalBatchNumber: UInt64,
        durableSequence: UInt64,
        requestedStart: Date,
        requestedEnd: Date,
        completedAt: Date,
        catalogStore: AtriaHistoricalArchiveCatalogStore,
        aggregateSnapshot: AtriaHistoricalAggregateReader.Snapshot
    ) throws -> Published {
        let catalog = try catalogStore.snapshotVerifiedAgainstFiles()
        try catalog.validate()
        let catalogData = try AtriaHistoricalActivityInspectionProofFactory.canonicalCatalogData(catalog)
        let aggregateData = try AtriaHistoricalActivityInspectionProofFactory
            .canonicalAggregateSnapshotData(aggregateSnapshot)
        let record = Record(version: Record.currentVersion,
                            generation: generation,
                            terminalBatchNumber: terminalBatchNumber,
                            durableSequence: durableSequence,
                            requestedStart: requestedStart,
                            requestedEnd: requestedEnd,
                            completedAt: completedAt,
                            catalogGeneration: catalog.generation,
                            catalogSnapshotSHA256: Self.sha256(catalogData),
                            aggregateSnapshotSHA256: Self.sha256(aggregateData),
                            disposition: .terminal)
        return try publish(record)
    }

    func loadLatest() throws -> Record {
        lock.lock()
        defer { lock.unlock() }
        return try loadLatestLocked()
    }

    private func publish(_ record: Record) throws -> Published {
        let persistedRecord: Record
        do {
            persistedRecord = try JSONDecoder.iso8601.decode(
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
                return .init(record: persistedRecord,
                             recordURL: directoryURL.appendingPathComponent(
                                "history-drain-completion-\(Self.sha256(data)).json"
                             ),
                             reusedExistingGeneration: true)
            }
        }

        let data = try Self.canonicalData(persistedRecord)
        let digest = Self.sha256(data)
        let filename = "history-drain-completion-\(digest).json"
        let recordURL = directoryURL.appendingPathComponent(filename)
        if fileManager.fileExists(atPath: recordURL.path) {
            guard try Self.sha256(Data(contentsOf: recordURL)) == digest else {
                throw StoreError.recordInvalid
            }
        } else {
            try writeDurably(data, to: recordURL)
        }
        try checkpoint(.recordDurable)
        try Self.synchronizeDirectory(directoryURL)
        try checkpoint(.recordPublished)

        let pointer = Pointer(version: Pointer.currentVersion,
                              generation: persistedRecord.generation,
                              recordFilename: filename,
                              recordSHA256: digest)
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
        return .init(
            record: persistedRecord,
            recordURL: recordURL,
            reusedExistingGeneration: false
        )
    }

    private func loadLatestLocked() throws -> Record {
        guard fileManager.fileExists(atPath: pointerURL.path) else {
            throw StoreError.missingCompletion
        }
        let pointer: Pointer
        do {
            let data = try Data(contentsOf: pointerURL)
            pointer = try JSONDecoder.iso8601.decode(Pointer.self, from: data)
            guard try Self.canonicalData(pointer) == data else { throw StoreError.pointerInvalid }
        } catch let error as StoreError {
            throw error
        } catch {
            throw StoreError.pointerInvalid
        }
        guard pointer.version == Pointer.currentVersion,
              pointer.recordFilename == "history-drain-completion-\(pointer.recordSHA256).json",
              Self.isSHA256(pointer.recordSHA256) else {
            throw StoreError.pointerInvalid
        }
        let url = directoryURL.appendingPathComponent(pointer.recordFilename)
        guard url.deletingLastPathComponent().standardizedFileURL == directoryURL.standardizedFileURL,
              fileManager.fileExists(atPath: url.path) else {
            throw StoreError.recordMissing
        }
        let data = try Data(contentsOf: url)
        guard Self.sha256(data) == pointer.recordSHA256 else { throw StoreError.recordInvalid }
        let record: Record
        do {
            record = try JSONDecoder.iso8601.decode(Record.self, from: data)
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

    private static func validate(_ record: Record) throws {
        guard record.version == Record.currentVersion,
              record.generation > 0,
              record.durableSequence > 0,
              record.requestedStart.timeIntervalSince1970.isFinite,
              record.requestedEnd.timeIntervalSince1970.isFinite,
              record.completedAt.timeIntervalSince1970.isFinite,
              record.requestedEnd > record.requestedStart,
              record.completedAt >= record.requestedEnd,
              isSHA256(record.catalogSnapshotSHA256),
              isSHA256(record.aggregateSnapshotSHA256),
              record.disposition == .terminal else {
            throw StoreError.invalidRecord
        }
    }

    private func writeDurably(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    private static func canonicalData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder.iso8601
        return try encoder.encode(value)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isSHA256(_ value: String) -> Bool {
        let hex = CharacterSet(charactersIn: "0123456789abcdef")
        return value.count == 64 && value.unicodeScalars.allSatisfy(hex.contains)
    }

    private static func synchronizeDirectory(_ url: URL) throws {
        let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY) }
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw POSIXError(.EIO) }
    }
}

/// Produces activity inspection proof only from the real catalog store, the
/// exact committed aggregate-reader snapshot, and a durable terminal record.
struct AtriaHistoricalActivityInspectionProofFactory {
    struct Prepared: Sendable {
        let inspectionProof: AtriaHistoricalActivityProjection.InspectionProof
        let dependencyChunks: [AtriaHistoricalAggregateChunk]
        let completionWatermark: Date
        let completionGeneration: UInt64
        /// Canonical evidence inputs are exposed so other historical consumers
        /// can build their own typed proof manifests from the exact same
        /// file-verified catalog generation. Callers never supply these bytes.
        let catalogSnapshot: Data
        let closedCoverageIntervals: [AtriaHistoricalActivityProjection.ClosedCoverageInterval]
        let generationIdentifier: String
    }

    enum FactoryError: Error, Equatable {
        case invalidRequestedRange
        case rejectedAggregateManifest
        case staleCompletionGeneration
        case completionCoverageMismatch
        case catalogSnapshotMismatch
        case aggregateSnapshotMismatch
        case unknownCatalogTimeBounds(String)
        case incompleteCatalogMetadata(String)
        case missingCommittedAggregate(String)
        case aggregateNotInCatalog(String)
        case aggregateCatalogMismatch(String)
        case duplicateCommittedAggregate(String)
    }

    let completionStore: AtriaHistoricalDrainCompletionGenerationStore

    func prepare(
        catalogStore: AtriaHistoricalArchiveCatalogStore,
        aggregateSnapshot: AtriaHistoricalAggregateReader.Snapshot,
        requestedStart: Date,
        requestedEnd: Date
    ) throws -> Prepared {
        guard requestedStart.timeIntervalSince1970.isFinite,
              requestedEnd.timeIntervalSince1970.isFinite,
              requestedEnd > requestedStart else {
            throw FactoryError.invalidRequestedRange
        }
        guard !aggregateSnapshot.diagnostics.limitExceeded,
              aggregateSnapshot.diagnostics.rejectedManifests == 0 else {
            throw FactoryError.rejectedAggregateManifest
        }
        let catalog = try catalogStore.snapshotVerifiedAgainstFiles()
        try catalog.validate()
        let catalogData = try Self.canonicalCatalogData(catalog)
        let aggregateData = try Self.canonicalAggregateSnapshotData(aggregateSnapshot)
        let completion = try completionStore.loadLatest()
        guard completion.catalogGeneration == catalog.generation else {
            throw FactoryError.staleCompletionGeneration
        }
        guard HistoricalArchive.persistedTimestamp(
                completion.requestedStart,
                coversStart: requestedStart
              ),
              HistoricalArchive.persistedTimestamp(
                completion.requestedEnd,
                coversEnd: requestedEnd
              ),
              HistoricalArchive.persistedTimestamp(
                completion.completedAt,
                coversEnd: requestedEnd
              ) else {
            throw FactoryError.completionCoverageMismatch
        }
        guard completion.catalogSnapshotSHA256
                == AtriaHistoricalDrainCompletionGenerationStore.sha256(catalogData) else {
            throw FactoryError.catalogSnapshotMismatch
        }
        guard completion.aggregateSnapshotSHA256
                == AtriaHistoricalDrainCompletionGenerationStore.sha256(aggregateData) else {
            throw FactoryError.aggregateSnapshotMismatch
        }

        return try Self.prepareVerified(
            catalog: catalog,
            catalogData: catalogData,
            aggregateSnapshot: aggregateSnapshot,
            requestedStart: requestedStart,
            requestedEnd: requestedEnd,
            completionWatermark: completion.requestedEnd,
            completionGeneration: completion.generation,
            generationIdentifier: "catalog-\(catalog.generation)-drain-\(completion.generation)"
        )
    }

    /// Builds the same five-consumer proof from a later exhaustive scan. The
    /// matched strap cursor watermark, never local elapsed time, must close the
    /// dependency suffix; the observed full-scan source must reach back through
    /// the dependency prefix.
    func prepareUsingFullScan(
        catalogStore: AtriaHistoricalArchiveCatalogStore,
        aggregateSnapshot: AtriaHistoricalAggregateReader.Snapshot,
        scan: AtriaHistoricalFullScanCompletionStore.Record,
        requestedStart: Date,
        requestedEnd: Date
    ) throws -> Prepared {
        guard requestedStart.timeIntervalSince1970.isFinite,
              requestedEnd.timeIntervalSince1970.isFinite,
              requestedEnd > requestedStart else {
            throw FactoryError.invalidRequestedRange
        }
        guard !aggregateSnapshot.diagnostics.limitExceeded,
              aggregateSnapshot.diagnostics.rejectedManifests == 0 else {
            throw FactoryError.rejectedAggregateManifest
        }
        let catalog = try catalogStore.snapshotVerifiedAgainstFiles()
        try catalog.validate()
        let catalogData = try Self.canonicalCatalogData(catalog)
        let aggregateData = try Self.canonicalAggregateSnapshotData(aggregateSnapshot)
        guard aggregateSnapshot.aggregates.contains(where: {
            $0.source.chunkID == scan.sourceChunkID
                && $0.source.rawSHA256 == scan.sourceRawSHA256
                && $0.source.firstTimestamp == scan.sourceFirstTimestamp
                && $0.source.lastTimestamp == scan.sourceLastTimestamp
        }) else {
            throw FactoryError.aggregateCatalogMismatch(scan.sourceChunkID)
        }
        guard scan.catalogGeneration == catalog.generation else {
            throw FactoryError.staleCompletionGeneration
        }
        guard scan.observedArchiveFirstTimestamp <= requestedStart,
              scan.cursorWatermark >= requestedEnd else {
            throw FactoryError.completionCoverageMismatch
        }
        guard scan.catalogSnapshotSHA256
                == AtriaHistoricalDrainCompletionGenerationStore.sha256(catalogData) else {
            throw FactoryError.catalogSnapshotMismatch
        }
        guard scan.aggregateSnapshotSHA256
                == AtriaHistoricalDrainCompletionGenerationStore.sha256(aggregateData) else {
            throw FactoryError.aggregateSnapshotMismatch
        }
        return try Self.prepareVerified(
            catalog: catalog,
            catalogData: catalogData,
            aggregateSnapshot: aggregateSnapshot,
            requestedStart: requestedStart,
            requestedEnd: requestedEnd,
            completionWatermark: scan.cursorWatermark,
            completionGeneration: scan.generation,
            generationIdentifier: "catalog-\(catalog.generation)-full-scan-\(scan.generation)"
        )
    }

    private static func prepareVerified(
        catalog: AtriaHistoricalArchiveCatalog,
        catalogData: Data,
        aggregateSnapshot: AtriaHistoricalAggregateReader.Snapshot,
        requestedStart: Date,
        requestedEnd: Date,
        completionWatermark: Date,
        completionGeneration: UInt64,
        generationIdentifier: String
    ) throws -> Prepared {

        let knownChunks = try catalog.chunks.compactMap { chunk -> AtriaHistoricalArchiveCatalog.RawChunk? in
            let hasPayload = chunk.byteCount > 0 || (chunk.rowCount ?? 0) > 0
            guard hasPayload else { return nil }
            guard let first = chunk.firstTimestamp, let last = chunk.lastTimestamp else {
                throw FactoryError.unknownCatalogTimeBounds(chunk.id)
            }
            guard let rows = chunk.rowCount,
                  rows >= 0,
                  let digest = chunk.contentSHA256,
                  Self.isSHA256(digest),
                  last > first else {
                throw FactoryError.incompleteCatalogMetadata(chunk.id)
            }
            return chunk
        }
        let relevantCatalog = knownChunks.filter {
            $0.lastTimestamp! >= requestedStart && $0.firstTimestamp! <= requestedEnd
        }.sorted {
            if $0.firstTimestamp! != $1.firstTimestamp! {
                return $0.firstTimestamp! < $1.firstTimestamp!
            }
            return $0.id < $1.id
        }
        let relevantAggregates = aggregateSnapshot.aggregates.filter {
            $0.source.lastTimestamp >= requestedStart && $0.source.firstTimestamp <= requestedEnd
        }.sorted {
            if $0.source.firstTimestamp != $1.source.firstTimestamp {
                return $0.source.firstTimestamp < $1.source.firstTimestamp
            }
            return $0.source.chunkID < $1.source.chunkID
        }
        var aggregateIDs = Set<String>()
        for aggregate in relevantAggregates where !aggregateIDs.insert(aggregate.source.chunkID).inserted {
            throw FactoryError.duplicateCommittedAggregate(aggregate.source.chunkID)
        }
        let catalogByID = Dictionary(uniqueKeysWithValues: relevantCatalog.map { ($0.id, $0) })
        let aggregateByID = Dictionary(uniqueKeysWithValues: relevantAggregates.map {
            ($0.source.chunkID, $0)
        })
        for chunk in relevantCatalog where aggregateByID[chunk.id] == nil {
            throw FactoryError.missingCommittedAggregate(chunk.id)
        }
        for aggregate in relevantAggregates {
            guard let chunk = catalogByID[aggregate.source.chunkID] else {
                throw FactoryError.aggregateNotInCatalog(aggregate.source.chunkID)
            }
            guard chunk.state == .sealed || chunk.state == .retired,
                  chunk.contentSHA256 == aggregate.source.rawSHA256,
                  chunk.byteCount == aggregate.source.rawByteCount,
                  chunk.rowCount == aggregate.source.rawRowCount,
                  HistoricalArchive.catalogTimestampMatches(
                    raw: aggregate.source.firstTimestamp,
                    catalog: chunk.firstTimestamp
                  ),
                  HistoricalArchive.catalogTimestampMatches(
                    raw: aggregate.source.lastTimestamp,
                    catalog: chunk.lastTimestamp
                  ) else {
                throw FactoryError.aggregateCatalogMismatch(aggregate.source.chunkID)
            }
        }

        let intervals = Self.closedCoverageIntervals(catalogChunks: relevantCatalog,
                                                     requestedStart: requestedStart,
                                                     requestedEnd: requestedEnd)
        let proof = try AtriaHistoricalActivityProjection.InspectionProof.make(
            generationIdentifier: generationIdentifier,
            catalogSnapshot: catalogData,
            closedCoverageIntervals: intervals
        )
        return .init(inspectionProof: proof,
                     dependencyChunks: relevantAggregates,
                     // The strap terminal certifies the requested history
                     // boundary. Local `completedAt` is audit time only and is
                     // never promoted into alleged no-data coverage.
                     completionWatermark: completionWatermark,
                     completionGeneration: completionGeneration,
                     catalogSnapshot: catalogData,
                     closedCoverageIntervals: intervals,
                     generationIdentifier: generationIdentifier)
    }

    static func canonicalCatalogData(_ catalog: AtriaHistoricalArchiveCatalog) throws -> Data {
        try catalog.validate()
        return try JSONEncoder.iso8601.encode(catalog)
    }

    static func canonicalAggregateSnapshotData(
        _ snapshot: AtriaHistoricalAggregateReader.Snapshot
    ) throws -> Data {
        struct Canonical: Codable {
            let aggregates: [AtriaHistoricalAggregateChunk]
            let committedManifests: Int
            let acceptedAggregates: Int
            let rejectedManifests: Int
        }
        let sorted = snapshot.aggregates.sorted {
            if $0.source.firstTimestamp != $1.source.firstTimestamp {
                return $0.source.firstTimestamp < $1.source.firstTimestamp
            }
            return $0.source.chunkID < $1.source.chunkID
        }
        return try JSONEncoder.iso8601.encode(Canonical(
            aggregates: sorted,
            committedManifests: snapshot.diagnostics.committedManifests,
            acceptedAggregates: snapshot.diagnostics.acceptedAggregates,
            rejectedManifests: snapshot.diagnostics.rejectedManifests
        ))
    }

    private static func closedCoverageIntervals(
        catalogChunks: [AtriaHistoricalArchiveCatalog.RawChunk],
        requestedStart: Date,
        requestedEnd: Date
    ) -> [AtriaHistoricalActivityProjection.ClosedCoverageInterval] {
        var intervals: [AtriaHistoricalActivityProjection.ClosedCoverageInterval] = []
        var cursor = requestedStart
        for chunk in catalogChunks {
            let start = max(requestedStart, chunk.firstTimestamp!)
            let end = min(requestedEnd, chunk.lastTimestamp!)
            guard end >= start else { continue }
            if start > cursor {
                intervals.append(.init(start: cursor, end: start, recordCount: 0))
            }
            if end > cursor {
                intervals.append(.init(start: max(cursor, start),
                                       end: end,
                                       recordCount: chunk.rowCount ?? 0))
                cursor = end
            }
        }
        if cursor < requestedEnd {
            intervals.append(.init(start: cursor, end: requestedEnd, recordCount: 0))
        }
        if intervals.isEmpty {
            intervals = [.init(start: requestedStart, end: requestedEnd, recordCount: 0)]
        }
        return intervals
    }

    private static func isSHA256(_ value: String) -> Bool {
        let hex = CharacterSet(charactersIn: "0123456789abcdef")
        return value.count == 64 && value.unicodeScalars.allSatisfy(hex.contains)
    }
}

private extension JSONEncoder {
    static var iso8601: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
