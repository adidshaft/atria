import CryptoKit
import Darwin
import Foundation

/// File-backed destinations for the app's verified historical consumers.
///
/// Receipt artifacts are staging evidence. These snapshots are the durable,
/// source-bound state that downstream consumers may read. A snapshot is not
/// considered applied until it has been written, fsynced, published, and read
/// back through `verify`. The separate application-set store atomically exposes
/// authority only after all five destinations pass that read-back.
struct AtriaHistoricalCanonicalConsumerDestinationStore {
    typealias ApplicationStore = AtriaHistoricalCanonicalConsumerApplicationStore
    typealias Consumer = ApplicationStore.Consumer
    typealias Identity = ApplicationStore.VerificationIdentity
    typealias ProjectionKind = AtriaHistoricalConsumerReceiptLedger.ProjectionKind
    typealias ValidatedArtifact = AtriaHistoricalConsumerReceiptLedger.ValidatedArtifact

    struct PersistedProjection: Codable, Equatable, Sendable {
        let receipt: AtriaHistoricalConsumerReceiptLedger.Receipt
        let artifact: Data
    }

    struct Snapshot: Codable, Equatable, Sendable {
        static let currentSchema = 1

        let schema: Int
        let consumer: Consumer
        let verificationIdentitySHA256: String
        let completionGeneration: UInt64
        let source: AtriaHistoricalConsumerReceiptLedger.Source
        let projections: [PersistedProjection]
        let appliedAt: Date
    }

    enum StoreError: Error, Equatable {
        case invalidIdentity
        case incompleteProjectionSet
        case invalidProjection
        case snapshotConflict
        case snapshotInvalid
        case pointerInvalid
        case readLimitExceeded
    }

    private struct Pointer: Codable, Equatable {
        static let currentVersion = 1

        let version: Int
        let consumer: Consumer
        let sourceChunkID: String
        let identitySHA256: String
        let snapshotFilename: String
        let snapshotSHA256: String
    }

    private static let maximumPointerBytes: UInt64 = 64 * 1_024
    private static let maximumSnapshotBytes: UInt64 = 64 * 1_024 * 1_024
    private static let lock = NSLock()

    private let directoryURL: URL
    private let fileManager: FileManager

    init(directoryURL: URL, fileManager: FileManager = .default) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
    }

    /// Applies all six exact, already semantically verified projections to the
    /// five canonical destinations. Partial writes are harmless: no retention
    /// authority exists until the application proof store publishes its atomic
    /// complete-set pointer.
    func applyCompleteSet(
        identity: Identity,
        artifacts: [ValidatedArtifact],
        appliedAt: Date = Date()
    ) throws -> [ApplicationStore.Application] {
        Self.lock.lock()
        defer { Self.lock.unlock() }

        let identityData = try Self.canonicalData(identity)
        let identitySHA256 = Self.sha256(identityData)
        let byKind = try validatedArtifacts(artifacts, identity: identity)
        guard appliedAt.timeIntervalSince1970.isFinite else {
            throw StoreError.invalidIdentity
        }
        // The on-disk canonical encoder stores millisecond dates. Normalize
        // before constructing the in-memory application so immediate read-back
        // compares the exact durable value rather than sub-millisecond input.
        let durableAppliedAt = Date(
            timeIntervalSince1970: floor(appliedAt.timeIntervalSince1970 * 1_000) / 1_000
        )
        try fileManager.createDirectory(at: directoryURL,
                                        withIntermediateDirectories: true)

        var applications: [ApplicationStore.Application] = []
        for consumer in Consumer.allCases.sorted(by: { $0.rawValue < $1.rawValue }) {
            let kinds = consumer.requiredProjectionKinds.sorted { $0.rawValue < $1.rawValue }
            if let existing = try existingApplication(
                consumer: consumer,
                identity: identity,
                identitySHA256: identitySHA256
            ) {
                guard try verify(application: existing, identity: identity) else {
                    throw StoreError.snapshotInvalid
                }
                applications.append(existing)
                continue
            }
            let projections = try kinds.map { kind -> PersistedProjection in
                guard let artifact = byKind[kind] else {
                    throw StoreError.incompleteProjectionSet
                }
                return .init(receipt: artifact.receipt, artifact: artifact.artifact)
            }
            let snapshot = Snapshot(schema: Snapshot.currentSchema,
                                    consumer: consumer,
                                    verificationIdentitySHA256: identitySHA256,
                                    completionGeneration: identity.completionGeneration,
                                    source: identity.source,
                                    projections: projections,
                                    appliedAt: durableAppliedAt)
            let snapshotData = try Self.canonicalData(snapshot)
            guard UInt64(snapshotData.count) <= Self.maximumSnapshotBytes else {
                throw StoreError.readLimitExceeded
            }
            let snapshotDigest = Self.sha256(snapshotData)
            let identityPrefix = String(identitySHA256.prefix(20))
            let filename = "canonical-\(consumer.rawValue)-\(identityPrefix)-\(snapshotDigest).json"
            let destination = directoryURL.appendingPathComponent(filename)
            try publishContent(snapshotData, to: destination, expectedSHA256: snapshotDigest)

            let pointer = Pointer(version: Pointer.currentVersion,
                                  consumer: consumer,
                                  sourceChunkID: identity.source.chunkID,
                                  identitySHA256: identitySHA256,
                                  snapshotFilename: filename,
                                  snapshotSHA256: snapshotDigest)
            try publishPointer(pointer, to: pointerURL(consumer: consumer,
                                                       sourceChunkID: identity.source.chunkID))
            let application = ApplicationStore.Application(
                consumer: consumer,
                appliedProjectionKinds: kinds,
                canonicalStoreIdentifier: Self.storeIdentifier(for: consumer),
                canonicalStoreSchemaVersion: Snapshot.currentSchema,
                canonicalStoreGeneration: identity.completionGeneration,
                snapshotSHA256: snapshotDigest,
                appliedAt: durableAppliedAt
            )
            guard try verify(application: application, identity: identity) else {
                throw StoreError.snapshotInvalid
            }
            applications.append(application)
        }
        return applications
    }

    /// Returns the already-applied exact identity so retries preserve the
    /// original, truthful application time. A pointer for another generation
    /// is replaceable; corruption of this generation fails closed.
    private func existingApplication(
        consumer: Consumer,
        identity: Identity,
        identitySHA256: String
    ) throws -> ApplicationStore.Application? {
        let url = pointerURL(consumer: consumer, sourceChunkID: identity.source.chunkID)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let pointerData = try Self.boundedData(at: url,
                                               maximumBytes: Self.maximumPointerBytes)
        let pointer: Pointer
        do { pointer = try Self.decoder().decode(Pointer.self, from: pointerData) }
        catch { throw StoreError.pointerInvalid }
        guard try Self.canonicalData(pointer) == pointerData,
              pointer.version == Pointer.currentVersion,
              pointer.consumer == consumer,
              pointer.sourceChunkID == identity.source.chunkID,
              Self.safeFilename(pointer.snapshotFilename),
              Self.isSHA256(pointer.identitySHA256),
              Self.isSHA256(pointer.snapshotSHA256) else {
            throw StoreError.pointerInvalid
        }
        guard pointer.identitySHA256 == identitySHA256 else { return nil }
        let snapshotData = try Self.boundedData(
            at: directoryURL.appendingPathComponent(pointer.snapshotFilename),
            maximumBytes: Self.maximumSnapshotBytes
        )
        guard Self.sha256(snapshotData) == pointer.snapshotSHA256 else {
            throw StoreError.snapshotInvalid
        }
        let snapshot: Snapshot
        do { snapshot = try Self.decoder().decode(Snapshot.self, from: snapshotData) }
        catch { throw StoreError.snapshotInvalid }
        guard try Self.canonicalData(snapshot) == snapshotData,
              snapshot.consumer == consumer,
              snapshot.verificationIdentitySHA256 == identitySHA256 else {
            throw StoreError.snapshotInvalid
        }
        return .init(
            consumer: consumer,
            appliedProjectionKinds: consumer.requiredProjectionKinds.sorted {
                $0.rawValue < $1.rawValue
            },
            canonicalStoreIdentifier: Self.storeIdentifier(for: consumer),
            canonicalStoreSchemaVersion: Snapshot.currentSchema,
            canonicalStoreGeneration: identity.completionGeneration,
            snapshotSHA256: pointer.snapshotSHA256,
            appliedAt: snapshot.appliedAt
        )
    }

    /// Re-reads the current pointer and the complete destination snapshot. It
    /// validates every receipt and payload digest against the exact identity;
    /// no digest supplied by the caller is trusted without file read-back.
    func verify(
        application: ApplicationStore.Application,
        identity: Identity
    ) throws -> Bool {
        let expectedIdentitySHA256 = Self.sha256(try Self.canonicalData(identity))
        guard application.canonicalStoreIdentifier == Self.storeIdentifier(for: application.consumer),
              application.canonicalStoreSchemaVersion == Snapshot.currentSchema,
              application.canonicalStoreGeneration == identity.completionGeneration,
              application.appliedProjectionKinds
                == application.consumer.requiredProjectionKinds.sorted(by: {
                    $0.rawValue < $1.rawValue
                }),
              Self.isSHA256(application.snapshotSHA256) else { return false }

        let pointerData = try Self.boundedData(
            at: pointerURL(consumer: application.consumer,
                           sourceChunkID: identity.source.chunkID),
            maximumBytes: Self.maximumPointerBytes
        )
        let pointer: Pointer
        do { pointer = try Self.decoder().decode(Pointer.self, from: pointerData) }
        catch { throw StoreError.pointerInvalid }
        guard try Self.canonicalData(pointer) == pointerData,
              pointer.version == Pointer.currentVersion,
              pointer.consumer == application.consumer,
              pointer.sourceChunkID == identity.source.chunkID,
              pointer.identitySHA256 == expectedIdentitySHA256,
              pointer.snapshotSHA256 == application.snapshotSHA256,
              Self.safeFilename(pointer.snapshotFilename) else {
            throw StoreError.pointerInvalid
        }

        let snapshotData = try Self.boundedData(
            at: directoryURL.appendingPathComponent(pointer.snapshotFilename),
            maximumBytes: Self.maximumSnapshotBytes
        )
        guard Self.sha256(snapshotData) == pointer.snapshotSHA256 else {
            throw StoreError.snapshotInvalid
        }
        let snapshot: Snapshot
        do { snapshot = try Self.decoder().decode(Snapshot.self, from: snapshotData) }
        catch { throw StoreError.snapshotInvalid }
        guard try Self.canonicalData(snapshot) == snapshotData,
              snapshot.schema == Snapshot.currentSchema,
              snapshot.consumer == application.consumer,
              snapshot.verificationIdentitySHA256 == expectedIdentitySHA256,
              snapshot.completionGeneration == identity.completionGeneration,
              snapshot.source == identity.source,
              snapshot.appliedAt == application.appliedAt,
              snapshot.projections.map(\.receipt.kind)
                == application.appliedProjectionKinds else {
            throw StoreError.snapshotInvalid
        }
        let identityReceipts = Dictionary(uniqueKeysWithValues: identity.receipts.map {
            ($0.kind, $0)
        })
        guard snapshot.projections.allSatisfy({ projection in
            identityReceipts[projection.receipt.kind] == projection.receipt
                && UInt64(projection.artifact.count) == projection.receipt.artifactByteCount
                && Self.sha256(projection.artifact) == projection.receipt.artifactSHA256
        }) else {
            throw StoreError.snapshotInvalid
        }
        return true
    }

    /// Returns the exact projection payloads only after the file-backed
    /// application has been revalidated. This is the sole downstream read seam;
    /// UI consumers never open projection-receipt artifacts directly.
    func validatedArtifacts(
        application: ApplicationStore.Application,
        identity: Identity
    ) throws -> [ValidatedArtifact] {
        guard try verify(application: application, identity: identity) else {
            throw StoreError.snapshotInvalid
        }
        let pointerData = try Self.boundedData(
            at: pointerURL(consumer: application.consumer,
                           sourceChunkID: identity.source.chunkID),
            maximumBytes: Self.maximumPointerBytes
        )
        let pointer = try Self.decoder().decode(Pointer.self, from: pointerData)
        let snapshotData = try Self.boundedData(
            at: directoryURL.appendingPathComponent(pointer.snapshotFilename),
            maximumBytes: Self.maximumSnapshotBytes
        )
        let snapshot = try Self.decoder().decode(Snapshot.self, from: snapshotData)
        return snapshot.projections.map {
            .init(receipt: $0.receipt, artifact: $0.artifact)
        }
    }

    /// Retires only the replay consumer's duplicate canonical payload after a
    /// compact index proof is durable. Typed destination snapshots are separate
    /// files and are never selected by this exact filename derivation.
    @discardableResult
    func retireReplayPayload(
        application: ApplicationStore.Application,
        identity: Identity
    ) throws -> UInt64 {
        guard application.consumer == .replayIdentity,
              identity.replayReceipt.kind == .replayIdentity else {
            throw StoreError.invalidIdentity
        }
        let identitySHA256 = Self.sha256(try Self.canonicalData(identity))
        let snapshotFilename = "canonical-replayIdentity-\(identitySHA256.prefix(20))-\(application.snapshotSHA256).json"
        let snapshotURL = directoryURL.appendingPathComponent(snapshotFilename)
        let pointerURL = pointerURL(consumer: .replayIdentity,
                                    sourceChunkID: identity.source.chunkID)
        var removed: UInt64 = 0
        if fileManager.fileExists(atPath: pointerURL.path) {
            guard try verify(application: application, identity: identity) else {
                throw StoreError.snapshotInvalid
            }
            removed += UInt64(max(0, (try pointerURL.resourceValues(
                forKeys: [.fileSizeKey]
            )).fileSize ?? 0))
        } else if fileManager.fileExists(atPath: snapshotURL.path) {
            let data = try Self.boundedData(at: snapshotURL,
                                            maximumBytes: Self.maximumSnapshotBytes)
            guard Self.sha256(data) == application.snapshotSHA256,
                  let snapshot = try? Self.decoder().decode(Snapshot.self, from: data),
                  snapshot.consumer == .replayIdentity,
                  snapshot.source == identity.source,
                  snapshot.verificationIdentitySHA256 == identitySHA256,
                  snapshot.projections.count == 1,
                  snapshot.projections.first?.receipt == identity.replayReceipt else {
                throw StoreError.snapshotInvalid
            }
        }
        if fileManager.fileExists(atPath: snapshotURL.path) {
            removed += UInt64(max(0, (try snapshotURL.resourceValues(
                forKeys: [.fileSizeKey]
            )).fileSize ?? 0))
        }
        if fileManager.fileExists(atPath: pointerURL.path) {
            try fileManager.removeItem(at: pointerURL)
        }
        if fileManager.fileExists(atPath: snapshotURL.path) {
            try fileManager.removeItem(at: snapshotURL)
        }
        if removed > 0 { try Self.synchronizeDirectory(directoryURL) }
        return removed
    }

    private func validatedArtifacts(
        _ artifacts: [ValidatedArtifact],
        identity: Identity
    ) throws -> [ProjectionKind: ValidatedArtifact] {
        let expectedKinds = AtriaHistoricalAggregateChunk.rawRetirementRequiredProjectionKinds
        guard identity.completionGeneration > 0,
              artifacts.count == expectedKinds.count,
              Set(artifacts.map(\.receipt.kind)) == expectedKinds,
              Set(identity.receipts.map(\.kind)) == expectedKinds else {
            throw StoreError.incompleteProjectionSet
        }
        let identityReceipts = Dictionary(uniqueKeysWithValues: identity.receipts.map {
            ($0.kind, $0)
        })
        var byKind: [ProjectionKind: ValidatedArtifact] = [:]
        for artifact in artifacts {
            guard identityReceipts[artifact.receipt.kind] == artifact.receipt,
                  artifact.receipt.source == identity.source,
                  UInt64(artifact.artifact.count) == artifact.receipt.artifactByteCount,
                  Self.sha256(artifact.artifact) == artifact.receipt.artifactSHA256 else {
                throw StoreError.invalidProjection
            }
            byKind[artifact.receipt.kind] = artifact
        }
        return byKind
    }

    private func publishContent(_ data: Data, to destination: URL,
                                expectedSHA256: String) throws {
        if fileManager.fileExists(atPath: destination.path) {
            guard Self.sha256(try Self.boundedData(at: destination,
                                                  maximumBytes: Self.maximumSnapshotBytes))
                    == expectedSHA256 else { throw StoreError.snapshotConflict }
            return
        }
        let temporary = temporaryURL(destination.lastPathComponent)
        try Self.writeDurably(data, to: temporary)
        do { try fileManager.moveItem(at: temporary, to: destination) }
        catch {
            if fileManager.fileExists(atPath: destination.path),
               Self.sha256(try Self.boundedData(at: destination,
                                                maximumBytes: Self.maximumSnapshotBytes))
                == expectedSHA256 {
                try? fileManager.removeItem(at: temporary)
            } else { throw error }
        }
        try Self.synchronizeDirectory(directoryURL)
    }

    private func publishPointer(_ pointer: Pointer, to destination: URL) throws {
        let temporary = temporaryURL(destination.lastPathComponent)
        try Self.writeDurably(try Self.canonicalData(pointer), to: temporary)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
        try Self.synchronizeDirectory(directoryURL)
    }

    private func pointerURL(consumer: Consumer, sourceChunkID: String) -> URL {
        let sourceDigest = Self.sha256(Data(sourceChunkID.utf8))
        return directoryURL.appendingPathComponent(
            "canonical-\(consumer.rawValue)-current-\(sourceDigest).json"
        )
    }

    private func temporaryURL(_ filename: String) -> URL {
        directoryURL.appendingPathComponent(".\(filename).\(UUID().uuidString).tmp")
    }

    private static func storeIdentifier(for consumer: Consumer) -> String {
        "atria.historical.canonical.\(consumer.rawValue).v1"
    }

    private static func boundedData(at url: URL, maximumBytes: UInt64) throws -> Data {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true,
              let size = values.fileSize,
              size >= 0,
              UInt64(size) <= maximumBytes else { throw StoreError.readLimitExceeded }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard UInt64(data.count) <= maximumBytes else { throw StoreError.readLimitExceeded }
        return data
    }

    private static func canonicalData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy(
            CharacterSet(charactersIn: "0123456789abcdef").contains
        )
    }

    private static func safeFilename(_ value: String) -> Bool {
        !value.isEmpty && value == URL(fileURLWithPath: value).lastPathComponent
            && !value.contains("/") && !value.contains("\\")
    }

    private static func writeDurably(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    private static func synchronizeDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw POSIXError(.EIO) }
    }
}

/// Production coordinator joining canonical destination writes to the atomic
/// application proof. Its verifier always performs file-backed destination
/// read-back; callers cannot inject a successful assertion.
struct AtriaHistoricalCanonicalConsumerApplicationAdapter {
    typealias ApplicationStore = AtriaHistoricalCanonicalConsumerApplicationStore
    typealias Identity = ApplicationStore.VerificationIdentity
    typealias ValidatedArtifact = AtriaHistoricalConsumerReceiptLedger.ValidatedArtifact

    let destinationStore: AtriaHistoricalCanonicalConsumerDestinationStore
    let proofDirectoryURL: URL

    func apply(
        identity: Identity,
        artifacts: [ValidatedArtifact],
        appliedAt: Date = Date()
    ) throws -> ApplicationStore.AppliedSet {
        let applications = try destinationStore.applyCompleteSet(
            identity: identity,
            artifacts: artifacts,
            appliedAt: appliedAt
        )
        let proofStore = makeProofStore()
        let current = try proofStore.loadCurrent(sourceChunkID: identity.source.chunkID)
        let published = try proofStore.publishCompleteSet(
            identity: identity,
            applications: applications,
            expectedCurrentIdentitySHA256: current?.verificationIdentitySHA256,
            committedAt: appliedAt
        )
        // Only after the atomic application proof is visible may superseded
        // receipt/destination/proof generations become unreachable. Collection
        // is best-effort retention maintenance; a failed scan removes nothing
        // and cannot invalidate the just-published canonical generation.
        let archiveRoot = proofDirectoryURL.deletingLastPathComponent()
            .deletingLastPathComponent()
        do {
            let result = try AtriaHistoricalGeneratedArtifactGC(
                archiveRoot: archiveRoot
            ).prune()
            AtriaDebugLog("ATRIADBG historical_generated_gc status=ok removed=%d removed_bytes=%llu avoidable_after=%llu limit_satisfied=%d",
                          result.removedFiles,
                          result.removedBytes,
                          result.avoidableBytesAfter,
                          result.limitSatisfied ? 1 : 0)
        } catch {
            AtriaDebugLog("ATRIADBG historical_generated_gc status=deferred error=%@ removed=0",
                          String(describing: error))
        }
        return published
    }

    func validatedCurrent(identity: Identity) throws -> ApplicationStore.AppliedSet {
        try makeProofStore().validatedCurrent(expectedIdentity: identity)
    }

    /// Loads the structurally durable application identity for crash recovery.
    /// This is not retirement authority by itself: callers must feed the
    /// returned identity back through `validatedCurrent(identity:)` and
    /// `validatedArtifacts(identity:)`, which re-open every canonical
    /// destination snapshot.
    func loadCurrent(sourceChunkID: String) throws -> ApplicationStore.AppliedSet? {
        try makeProofStore().loadCurrent(sourceChunkID: sourceChunkID)
    }

    func validatedArtifacts(identity: Identity) throws -> [ValidatedArtifact] {
        let applied = try validatedCurrent(identity: identity)
        let values = try applied.applications.flatMap {
            try destinationStore.validatedArtifacts(application: $0, identity: identity)
        }
        guard values.count == AtriaHistoricalAggregateChunk
                .rawRetirementRequiredProjectionKinds.count,
              Set(values.map(\.receipt.kind)) == AtriaHistoricalAggregateChunk
                .rawRetirementRequiredProjectionKinds else {
            throw AtriaHistoricalCanonicalConsumerDestinationStore.StoreError
                .incompleteProjectionSet
        }
        return values.sorted { $0.receipt.kind.rawValue < $1.receipt.kind.rawValue }
    }

    private func makeProofStore() -> ApplicationStore {
        ApplicationStore(directoryURL: proofDirectoryURL) { application, identity in
            try destinationStore.verify(application: application, identity: identity)
        }
    }
}
