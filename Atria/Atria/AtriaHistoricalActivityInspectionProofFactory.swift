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
        let aggregateSnapshotDigest = try AtriaHistoricalActivityInspectionProofFactory
            .streamedAggregateSnapshotDigest(aggregateSnapshot)
        return try recordTerminal(generation: generation,
                                  terminalBatchNumber: terminalBatchNumber,
                                  durableSequence: durableSequence,
                                  requestedStart: requestedStart,
                                  requestedEnd: requestedEnd,
                                  completedAt: completedAt,
                                  verifiedCatalog: catalog,
                                  catalogData: catalogData,
                                  aggregateSnapshotDigest: aggregateSnapshotDigest)
    }

    /// Memory-shape overload for flows that already hold the file-verified
    /// catalog, its canonical encoding, and the streamed aggregate-snapshot
    /// digest from the same archive pass. The persisted record's digests are
    /// computed from the exact same `canonicalCatalogData` bytes and the
    /// byte-identical streamed aggregate digest the store-based overload would
    /// produce; only the recomputation frequency changes and the whole
    /// re-encoded aggregate `Data` is never materialized.
    func recordTerminal(
        generation: UInt64,
        terminalBatchNumber: UInt64,
        durableSequence: UInt64,
        requestedStart: Date,
        requestedEnd: Date,
        completedAt: Date,
        verifiedCatalog catalog: AtriaHistoricalArchiveCatalog,
        catalogData: Data,
        aggregateSnapshotDigest: String
    ) throws -> Published {
        try catalog.validate()
        let record = Record(version: Record.currentVersion,
                            generation: generation,
                            terminalBatchNumber: terminalBatchNumber,
                            durableSequence: durableSequence,
                            requestedStart: requestedStart,
                            requestedEnd: requestedEnd,
                            completedAt: completedAt,
                            catalogGeneration: catalog.generation,
                            catalogSnapshotSHA256: Self.sha256(catalogData),
                            aggregateSnapshotSHA256: aggregateSnapshotDigest,
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
        case malformedAggregateSnapshotWrapper
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
        let aggregateSnapshotDigest = try Self.streamedAggregateSnapshotDigest(aggregateSnapshot)
        return try prepare(
            verifiedCatalog: catalog,
            catalogData: catalogData,
            aggregateSnapshot: aggregateSnapshot,
            aggregateSnapshotDigest: aggregateSnapshotDigest,
            requestedStart: requestedStart,
            requestedEnd: requestedEnd
        )
    }

    /// Memory-shape overload of `prepare` for multi-source publication passes
    /// whose catalog and aggregate snapshot are provably invariant across the
    /// pass. The caller supplies the file-verified catalog together with the
    /// exact `canonicalCatalogData` bytes and the byte-identical streamed
    /// aggregate-snapshot digest computed once; every validation and error
    /// below is identical to `prepare(catalogStore:...)`, so the persisted
    /// completion SHA-256s compare against unchanged bytes while the whole
    /// re-encoded aggregate `Data` is never materialized.
    func prepare(
        verifiedCatalog catalog: AtriaHistoricalArchiveCatalog,
        catalogData: Data,
        aggregateSnapshot: AtriaHistoricalAggregateReader.Snapshot,
        aggregateSnapshotDigest: String,
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
        try catalog.validate()
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
        guard completion.aggregateSnapshotSHA256 == aggregateSnapshotDigest else {
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
        let catalog = try catalogStore.snapshotVerifiedAgainstFiles()
        try catalog.validate()
        let catalogData = try Self.canonicalCatalogData(catalog)
        let aggregateSnapshotDigest = try Self.streamedAggregateSnapshotDigest(aggregateSnapshot)
        return try prepareUsingFullScan(
            verifiedCatalog: catalog,
            catalogData: catalogData,
            aggregateSnapshot: aggregateSnapshot,
            aggregateSnapshotDigest: aggregateSnapshotDigest,
            scan: scan,
            requestedStart: requestedStart,
            requestedEnd: requestedEnd
        )
    }

    /// Memory-shape overload: the whole-archive aggregate-snapshot digest is
    /// supplied (computed once via the bounded streaming primitive) and the
    /// catalog is already file-verified, so `aggregateSnapshot` may be a
    /// windowed subset (its diagnostics must still reflect WHOLE-archive
    /// rejection state). Every validation is identical to the store-based
    /// entry above; only the decode is bounded.
    func prepareUsingFullScan(
        verifiedCatalog catalog: AtriaHistoricalArchiveCatalog,
        catalogData: Data,
        aggregateSnapshot: AtriaHistoricalAggregateReader.Snapshot,
        aggregateSnapshotDigest: String,
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
        try catalog.validate()
        guard aggregateSnapshot.aggregates.contains(where: {
            $0.source.chunkID == scan.sourceChunkID
                && $0.source.rawSHA256 == scan.sourceRawSHA256
                && $0.source.firstTimestamp == scan.sourceFirstTimestamp
                && $0.source.lastTimestamp == scan.sourceLastTimestamp
        }) else {
            throw FactoryError.aggregateCatalogMismatch(scan.sourceChunkID)
        }
        guard scan.catalogGeneration <= catalog.generation else {
            throw FactoryError.staleCompletionGeneration
        }
        guard scan.observedArchiveFirstTimestamp <= requestedStart,
              scan.cursorWatermark >= requestedEnd else {
            throw FactoryError.completionCoverageMismatch
        }
        let currentCatalogSHA256 =
            AtriaHistoricalDrainCompletionGenerationStore.sha256(catalogData)
        // Live capture can append to the sole active raw chunk immediately
        // after the full-scan terminal record is fsynced. That advances the
        // catalog generation/byte count without changing any committed
        // aggregate used by the historical consumers. At the same generation,
        // the catalog digest must remain exact. Across a monotonic later
        // generation, the aggregate snapshot below remains the immutable
        // dependency authority and `prepareVerified` revalidates every
        // relevant catalog chunk against that snapshot and the filesystem.
        guard scan.catalogGeneration < catalog.generation
                || scan.catalogSnapshotSHA256 == currentCatalogSHA256 else {
            throw FactoryError.catalogSnapshotMismatch
        }
        guard scan.aggregateSnapshotSHA256 == aggregateSnapshotDigest else {
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
                // The catalog intentionally does not publish time bounds for
                // its mutable active chunk. Live capture may append there
                // immediately after a terminal scan. It cannot be a dependency
                // of an already-closed requested interval when the chunk
                // itself was created strictly after that interval ended.
                if chunk.state == .active, chunk.createdAt > requestedEnd {
                    return nil
                }
                throw FactoryError.unknownCatalogTimeBounds(chunk.id)
            }
            guard let rows = chunk.rowCount,
                  rows >= 0,
                  let digest = chunk.contentSHA256,
                  Self.isSHA256(digest),
                  last >= first else {
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
                  HistoricalArchive.aggregateSourceMatchesCatalogChunk(
                    rawSHA256: aggregate.source.rawSHA256,
                    byteCount: aggregate.source.rawByteCount,
                    rowCount: aggregate.source.rawRowCount,
                    firstTimestamp: aggregate.source.firstTimestamp,
                    lastTimestamp: aggregate.source.lastTimestamp,
                    chunk: chunk
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

    /// Canonical wrapper shape for the aggregate snapshot. Both the whole-buffer
    /// `canonicalAggregateSnapshotData` (kept as the parity reference for tests)
    /// and the streaming `streamedAggregateSnapshotDigest` encode this exact
    /// struct under the same `JSONEncoder.iso8601` options, so their bytes — and
    /// therefore their SHA-256 — are identical.
    private struct CanonicalAggregateSnapshot: Codable {
        let aggregates: [AtriaHistoricalAggregateChunk]
        let committedManifests: Int
        let acceptedAggregates: Int
        let rejectedManifests: Int
    }

    /// Sole canonical ordering shared by both digest paths: firstTimestamp
    /// ascending, then chunkID ascending.
    private static func sortedAggregates(
        _ snapshot: AtriaHistoricalAggregateReader.Snapshot
    ) -> [AtriaHistoricalAggregateChunk] {
        snapshot.aggregates.sorted {
            if $0.source.firstTimestamp != $1.source.firstTimestamp {
                return $0.source.firstTimestamp < $1.source.firstTimestamp
            }
            return $0.source.chunkID < $1.source.chunkID
        }
    }

    static func canonicalAggregateSnapshotData(
        _ snapshot: AtriaHistoricalAggregateReader.Snapshot
    ) throws -> Data {
        try JSONEncoder.iso8601.encode(CanonicalAggregateSnapshot(
            aggregates: sortedAggregates(snapshot),
            committedManifests: snapshot.diagnostics.committedManifests,
            acceptedAggregates: snapshot.diagnostics.acceptedAggregates,
            rejectedManifests: snapshot.diagnostics.rejectedManifests
        ))
    }

    /// Computes the SHA-256 of `canonicalAggregateSnapshotData` WITHOUT ever
    /// materializing the whole re-encoded archive `Data`. This is the memory
    /// bound that keeps the foreground publication passes from ballooning.
    ///
    /// Byte-identity recipe (proven byte-for-byte equal to hashing the whole
    /// buffer): encode the canonical wrapper with an EMPTY aggregates array via
    /// the same encoder, then split it at the sole `[]` literal — everything up
    /// to and including `[` is the prefix, everything from `]` onward is the
    /// suffix. This reuses `JSONEncoder`'s own key names and punctuation exactly.
    /// Each aggregate element is then encoded standalone (byte-identical to its
    /// slice inside the full array under these options) and folded into the hash
    /// with `,` separators between elements (none before the first). Every
    /// per-element encode is wrapped in an `autoreleasepool` so no whole-archive
    /// `Data` is ever resident.
    static func streamedAggregateSnapshotDigest(
        _ snapshot: AtriaHistoricalAggregateReader.Snapshot
    ) throws -> String {
        let (prefix, suffix) = try canonicalAggregateSnapshotWrapperSplit(
            committedManifests: snapshot.diagnostics.committedManifests,
            acceptedAggregates: snapshot.diagnostics.acceptedAggregates,
            rejectedManifests: snapshot.diagnostics.rejectedManifests
        )

        var hasher = SHA256()
        hasher.update(data: prefix)
        let comma = Data([0x2C]) // ","
        for (index, aggregate) in sortedAggregates(snapshot).enumerated() {
            try autoreleasepool {
                if index > 0 {
                    hasher.update(data: comma)
                }
                hasher.update(data: try canonicalAggregateElementData(aggregate))
            }
        }
        hasher.update(data: suffix)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Exposes the exact prefix/suffix split and per-element encoding that
    /// `streamedAggregateSnapshotDigest` above uses, so `AtriaHistoricalAggregateReader
    /// .streamedWholeArchiveDigest` can fold in aggregates it re-decodes one at
    /// a time directly from manifests, WITHOUT ever building an
    /// `AtriaHistoricalAggregateReader.Snapshot` that holds every decoded
    /// aggregate resident. Both callers therefore share one implementation of
    /// the canonical wrapper shape, encoder options, and `[]`-split technique;
    /// any divergence here would change the persisted digest.
    static func canonicalAggregateSnapshotWrapperSplit(
        committedManifests: Int,
        acceptedAggregates: Int,
        rejectedManifests: Int
    ) throws -> (prefix: Data, suffix: Data) {
        let wrapper = try JSONEncoder.iso8601.encode(CanonicalAggregateSnapshot(
            aggregates: [],
            committedManifests: committedManifests,
            acceptedAggregates: acceptedAggregates,
            rejectedManifests: rejectedManifests
        ))
        guard let openBracketIndex = soleEmptyArrayOpenBracketIndex(in: wrapper) else {
            throw FactoryError.malformedAggregateSnapshotWrapper
        }
        let prefix = wrapper[wrapper.startIndex...openBracketIndex]
        let suffix = wrapper[wrapper.index(after: openBracketIndex)..<wrapper.endIndex]
        return (Data(prefix), Data(suffix))
    }

    static func canonicalAggregateElementData(
        _ aggregate: AtriaHistoricalAggregateChunk
    ) throws -> Data {
        try JSONEncoder.iso8601.encode(aggregate)
    }

    /// Returns the index of the `[` of the sole empty-array literal `[]` in the
    /// canonical wrapper, or `nil` if it is absent or not unique (malformed).
    private static func soleEmptyArrayOpenBracketIndex(in data: Data) -> Data.Index? {
        var found: Data.Index?
        var index = data.startIndex
        while index < data.endIndex {
            if data[index] == 0x5B { // "["
                let next = data.index(after: index)
                if next < data.endIndex, data[next] == 0x5D { // "]"
                    if found != nil { return nil }
                    found = index
                }
            }
            index = data.index(after: index)
        }
        return found
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
