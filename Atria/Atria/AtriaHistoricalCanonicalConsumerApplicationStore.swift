import CryptoKit
import Darwin
import Foundation

/// Durable evidence that one exact verified history generation was read back
/// from every canonical downstream store.
///
/// Projection receipts prove only that shadow artifacts exist. This store does
/// not promote those receipts by itself: callers must provide a verifier that
/// re-reads each canonical destination and validates its snapshot digest. The
/// verifier defaults to denial. A complete five-consumer set becomes visible
/// through one atomic pointer only after every readback succeeds.
struct AtriaHistoricalCanonicalConsumerApplicationStore {
    typealias ProjectionKind = AtriaHistoricalConsumerReceiptLedger.ProjectionKind
    typealias ProjectionReceipt = AtriaHistoricalConsumerReceiptLedger.Receipt
    typealias TypedVerificationIdentity = AtriaHistoricalVerifiedConsumerReader.VerificationIdentity

    enum Consumer: String, Codable, CaseIterable, Equatable, Sendable {
        case sleep
        case workoutAndActivity
        case dailyStrainAndRecovery
        case steps
        case replayIdentity

        var requiredProjectionKinds: Set<ProjectionKind> {
            switch self {
            case .sleep: [.sleep]
            case .workoutAndActivity: [.workout, .activity]
            case .dailyStrainAndRecovery: [.dailyMetrics]
            case .steps: [.steps]
            case .replayIdentity: [.replayIdentity]
            }
        }
    }

    /// Exact immutable source generation consumed by all five destinations.
    /// The typed identity has the atomic app-facing five-receipt set; replay is
    /// separate because it is intentionally not part of that UI-facing set.
    struct VerificationIdentity: Codable, Equatable, Sendable {
        let typed: TypedVerificationIdentity
        let replayReceipt: ProjectionReceipt

        var source: AtriaHistoricalConsumerReceiptLedger.Source { typed.source }
        var completionGeneration: UInt64 { typed.completionGeneration }

        var receipts: [ProjectionReceipt] {
            (typed.receipts + [replayReceipt]).sorted {
                $0.kind.rawValue < $1.kind.rawValue
            }
        }
    }

    /// A canonical destination's durable readback. `snapshotSHA256` must be a
    /// digest of the destination state after its own atomic persistence, not a
    /// digest copied from the input projection artifact.
    struct Application: Codable, Equatable, Sendable {
        let consumer: Consumer
        let appliedProjectionKinds: [ProjectionKind]
        let canonicalStoreIdentifier: String
        let canonicalStoreSchemaVersion: Int
        let canonicalStoreGeneration: UInt64
        let snapshotSHA256: String
        let appliedAt: Date
    }

    struct ProjectionBinding: Codable, Equatable, Sendable {
        let kind: ProjectionKind
        let receiptSHA256: String
        let artifactSHA256: String
        let outcome: AtriaHistoricalConsumerReceiptLedger.Outcome
    }

    struct AppliedSet: Codable, Equatable, Sendable {
        static let currentSchema = 1

        let schema: Int
        let verificationIdentity: VerificationIdentity
        let verificationIdentitySHA256: String
        let projectionBindings: [ProjectionBinding]
        let applications: [Application]
        let committedAt: Date
    }

    enum Checkpoint: Equatable, Sendable {
        case setTemporaryDurable
        case setPublished
        case pointerTemporaryDurable
        case pointerPublished
    }

    enum StoreError: Error, Equatable {
        case invalidIdentity
        case invalidApplication
        case incompleteApplicationSet
        case canonicalApplicationNotVerified(Consumer)
        case staleCurrentGeneration
        case setConflict
        case setInvalid
        case pointerInvalid
        case readLimitExceeded
    }

    private struct Pointer: Codable, Equatable {
        static let currentVersion = 1

        let version: Int
        let sourceChunkID: String
        let identitySHA256: String
        let setFilename: String
        let setSHA256: String
    }

    typealias CanonicalStateVerifier = (Application, VerificationIdentity) throws -> Bool

    private static let maximumPointerBytes: UInt64 = 64 * 1_024
    private static let maximumSetBytes: UInt64 = 512 * 1_024
    private static let mutationLock = NSLock()

    private let directoryURL: URL
    private let fileManager: FileManager
    private let canonicalStateVerifier: CanonicalStateVerifier
    private let checkpoint: (Checkpoint) throws -> Void

    init(directoryURL: URL,
         fileManager: FileManager = .default,
         canonicalStateVerifier: @escaping CanonicalStateVerifier = { _, _ in false },
         checkpoint: @escaping (Checkpoint) throws -> Void = { _ in }) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
        self.canonicalStateVerifier = canonicalStateVerifier
        self.checkpoint = checkpoint
    }

    /// Publishes one complete, exact generation. The expected identity is a
    /// compare-and-swap token from `loadCurrent`; nil means the caller observed
    /// no prior application for this source chunk.
    @discardableResult
    func publishCompleteSet(
        identity: VerificationIdentity,
        applications: [Application],
        expectedCurrentIdentitySHA256: String?,
        committedAt: Date = Date()
    ) throws -> AppliedSet {
        Self.mutationLock.lock()
        defer { Self.mutationLock.unlock() }

        try fileManager.createDirectory(at: directoryURL,
                                        withIntermediateDirectories: true)
        let current = try loadCurrentLocked(sourceChunkID: identity.source.chunkID)
        guard current?.verificationIdentitySHA256 == expectedCurrentIdentitySHA256 else {
            throw StoreError.staleCurrentGeneration
        }

        let identityDigest = try Self.sha256(Self.canonicalData(identity))
        let bindings = try validatedBindings(identity)
        let normalizedApplications = try validateApplications(applications)
        for application in normalizedApplications {
            guard try canonicalStateVerifier(application, identity) else {
                throw StoreError.canonicalApplicationNotVerified(application.consumer)
            }
        }
        guard committedAt.timeIntervalSince1970.isFinite,
              normalizedApplications.allSatisfy({ committedAt >= $0.appliedAt }) else {
            throw StoreError.invalidApplication
        }

        let applied = AppliedSet(
            schema: AppliedSet.currentSchema,
            verificationIdentity: identity,
            verificationIdentitySHA256: identityDigest,
            projectionBindings: bindings,
            applications: normalizedApplications,
            committedAt: committedAt
        )

        if let current, current.verificationIdentitySHA256 == identityDigest {
            var replay = applied
            replay = .init(schema: replay.schema,
                           verificationIdentity: replay.verificationIdentity,
                           verificationIdentitySHA256: replay.verificationIdentitySHA256,
                           projectionBindings: replay.projectionBindings,
                           applications: replay.applications,
                           committedAt: current.committedAt)
            guard replay == current else { throw StoreError.setConflict }
            return current
        }

        let setData = try Self.canonicalData(applied)
        guard UInt64(setData.count) <= Self.maximumSetBytes else {
            throw StoreError.readLimitExceeded
        }
        let setDigest = Self.sha256(setData)
        let filename = "canonical-consumer-set-\(identityDigest)-\(setDigest).json"
        let destination = directoryURL.appendingPathComponent(filename)
        if fileManager.fileExists(atPath: destination.path) {
            guard try Self.sha256(Self.boundedData(at: destination,
                                                  maximumBytes: Self.maximumSetBytes)) == setDigest else {
                throw StoreError.setConflict
            }
        } else {
            let temporary = temporaryURL(filename)
            try Self.writeDurably(setData, to: temporary)
            try checkpoint(.setTemporaryDurable)
            try publish(temporary: temporary,
                        destination: destination,
                        expectedSHA256: setDigest)
            try Self.synchronizeDirectory(directoryURL)
            try checkpoint(.setPublished)
        }

        let pointer = Pointer(version: Pointer.currentVersion,
                              sourceChunkID: identity.source.chunkID,
                              identitySHA256: identityDigest,
                              setFilename: filename,
                              setSHA256: setDigest)
        let pointerURL = self.pointerURL(sourceChunkID: identity.source.chunkID)
        let temporaryPointer = temporaryURL(pointerURL.lastPathComponent)
        try Self.writeDurably(try Self.canonicalData(pointer), to: temporaryPointer)
        try checkpoint(.pointerTemporaryDurable)
        if fileManager.fileExists(atPath: pointerURL.path) {
            _ = try fileManager.replaceItemAt(pointerURL, withItemAt: temporaryPointer)
        } else {
            try fileManager.moveItem(at: temporaryPointer, to: pointerURL)
        }
        try Self.synchronizeDirectory(directoryURL)
        try checkpoint(.pointerPublished)
        return try loadCurrentLocked(sourceChunkID: identity.source.chunkID) ?? {
            throw StoreError.pointerInvalid
        }()
    }

    /// Loads structural proof only. Retention code must use
    /// `validatedCurrent` so canonical destinations are re-read.
    func loadCurrent(sourceChunkID: String) throws -> AppliedSet? {
        Self.mutationLock.lock()
        defer { Self.mutationLock.unlock() }
        return try loadCurrentLocked(sourceChunkID: sourceChunkID)
    }

    /// Revalidates the exact expected identity and every canonical destination
    /// against its persisted readback before returning authority to a caller.
    func validatedCurrent(expectedIdentity: VerificationIdentity) throws -> AppliedSet {
        let expectedDigest = try Self.sha256(Self.canonicalData(expectedIdentity))
        guard let current = try loadCurrent(sourceChunkID: expectedIdentity.source.chunkID),
              current.verificationIdentity == expectedIdentity,
              current.verificationIdentitySHA256 == expectedDigest else {
            throw StoreError.setInvalid
        }
        for application in current.applications {
            guard try canonicalStateVerifier(application, expectedIdentity) else {
                throw StoreError.canonicalApplicationNotVerified(application.consumer)
            }
        }
        return current
    }

    private func loadCurrentLocked(sourceChunkID: String) throws -> AppliedSet? {
        guard !sourceChunkID.isEmpty else { throw StoreError.pointerInvalid }
        let pointerURL = pointerURL(sourceChunkID: sourceChunkID)
        guard fileManager.fileExists(atPath: pointerURL.path) else { return nil }
        let pointerData = try Self.boundedData(at: pointerURL,
                                               maximumBytes: Self.maximumPointerBytes)
        let pointer: Pointer
        do { pointer = try Self.decoder().decode(Pointer.self, from: pointerData) }
        catch { throw StoreError.pointerInvalid }
        guard pointer.version == Pointer.currentVersion,
              pointer.sourceChunkID == sourceChunkID,
              Self.isSHA256(pointer.identitySHA256),
              Self.isSHA256(pointer.setSHA256),
              Self.safeFilename(pointer.setFilename),
              try Self.canonicalData(pointer) == pointerData else {
            throw StoreError.pointerInvalid
        }

        let setURL = directoryURL.appendingPathComponent(pointer.setFilename)
        guard fileManager.fileExists(atPath: setURL.path) else { throw StoreError.setInvalid }
        let setData = try Self.boundedData(at: setURL, maximumBytes: Self.maximumSetBytes)
        guard Self.sha256(setData) == pointer.setSHA256 else { throw StoreError.setInvalid }
        let applied: AppliedSet
        do { applied = try Self.decoder().decode(AppliedSet.self, from: setData) }
        catch { throw StoreError.setInvalid }
        guard try Self.canonicalData(applied) == setData,
              applied.schema == AppliedSet.currentSchema,
              applied.verificationIdentity.source.chunkID == sourceChunkID,
              applied.verificationIdentitySHA256 == pointer.identitySHA256,
              try Self.sha256(Self.canonicalData(applied.verificationIdentity))
                == applied.verificationIdentitySHA256,
              try validatedBindings(applied.verificationIdentity) == applied.projectionBindings,
              try validateApplications(applied.applications) == applied.applications,
              applied.committedAt.timeIntervalSince1970.isFinite,
              applied.applications.allSatisfy({ applied.committedAt >= $0.appliedAt }) else {
            throw StoreError.setInvalid
        }
        return applied
    }

    private func validatedBindings(_ identity: VerificationIdentity) throws -> [ProjectionBinding] {
        let typedKinds: Set<ProjectionKind> = [.activity, .dailyMetrics, .steps, .sleep, .workout]
        guard identity.completionGeneration > 0,
              !identity.typed.generationIdentifier.isEmpty,
              Self.isSHA256(identity.typed.catalogSnapshotSHA256),
              !identity.source.chunkID.isEmpty,
              Self.isSHA256(identity.source.rawSHA256),
              identity.source.lastTimestamp >= identity.source.firstTimestamp,
              identity.typed.receipts.count == typedKinds.count,
              Set(identity.typed.receipts.map(\.kind)) == typedKinds,
              identity.typed.receipts == identity.typed.receipts.sorted(by: {
                  $0.kind.rawValue < $1.kind.rawValue
              }),
              identity.replayReceipt.kind == .replayIdentity,
              identity.receipts.count == AtriaHistoricalAggregateChunk
                .rawRetirementRequiredProjectionKinds.count,
              Set(identity.receipts.map(\.kind)) == AtriaHistoricalAggregateChunk
                .rawRetirementRequiredProjectionKinds,
              identity.receipts.allSatisfy({ Self.valid($0, source: identity.source) }) else {
            throw StoreError.invalidIdentity
        }
        return try identity.receipts.map { receipt in
            .init(kind: receipt.kind,
                  receiptSHA256: try Self.sha256(Self.canonicalData(receipt)),
                  artifactSHA256: receipt.artifactSHA256,
                  outcome: receipt.outcome)
        }
    }

    private static func valid(
        _ receipt: ProjectionReceipt,
        source: AtriaHistoricalConsumerReceiptLedger.Source
    ) -> Bool {
        receipt.version == ProjectionReceipt.currentVersion
            && receipt.source == source
            && receipt.consumerSchemaVersion > 0
            && !receipt.algorithmVersion.isEmpty
            && isSHA256(receipt.configurationSHA256)
            && receipt.dependencyStart <= source.firstTimestamp
            && receipt.dependencyEnd >= source.lastTimestamp
            && receipt.completionWatermark >= receipt.dependencyEnd
            && receipt.recordCount >= 0
            && isSHA256(receipt.artifactSHA256)
            && receipt.artifactByteCount > 0
            && receipt.artifactFilename
                == "consumer-artifact-\(receipt.kind.rawValue)-\(receipt.artifactSHA256).bin"
            && receipt.settledAt >= receipt.completionWatermark
            && ((receipt.outcome == .materialized && receipt.recordCount > 0)
                || (receipt.outcome == .explicitlyEmpty && receipt.recordCount == 0))
    }

    private func validateApplications(_ applications: [Application]) throws -> [Application] {
        let sorted = applications.sorted { $0.consumer.rawValue < $1.consumer.rawValue }
        guard sorted.count == Consumer.allCases.count,
              Set(sorted.map(\.consumer)) == Set(Consumer.allCases) else {
            throw StoreError.incompleteApplicationSet
        }
        for application in sorted {
            guard application.appliedProjectionKinds
                    == application.consumer.requiredProjectionKinds.sorted(by: {
                        $0.rawValue < $1.rawValue
                    }),
                  !application.canonicalStoreIdentifier.isEmpty,
                  application.canonicalStoreSchemaVersion > 0,
                  application.canonicalStoreGeneration > 0,
                  Self.isSHA256(application.snapshotSHA256),
                  application.appliedAt.timeIntervalSince1970.isFinite else {
                throw StoreError.invalidApplication
            }
        }
        return sorted
    }

    private func pointerURL(sourceChunkID: String) -> URL {
        let digest = Self.sha256(Data(sourceChunkID.utf8))
        return directoryURL.appendingPathComponent("canonical-consumer-current-\(digest).json")
    }

    private func temporaryURL(_ filename: String) -> URL {
        directoryURL.appendingPathComponent(".\(filename).\(UUID().uuidString).tmp")
    }

    private func publish(temporary: URL,
                         destination: URL,
                         expectedSHA256: String) throws {
        do {
            try fileManager.moveItem(at: temporary, to: destination)
        } catch {
            if fileManager.fileExists(atPath: destination.path),
               try Self.sha256(Self.boundedData(at: destination,
                                                maximumBytes: Self.maximumSetBytes)) == expectedSHA256 {
                try? fileManager.removeItem(at: temporary)
                return
            }
            throw error
        }
    }

    private static func boundedData(at url: URL, maximumBytes: UInt64) throws -> Data {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true,
              let size = values.fileSize,
              size >= 0,
              UInt64(size) <= maximumBytes else {
            throw StoreError.readLimitExceeded
        }
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
        value.count == 64
            && value.unicodeScalars.allSatisfy(
                CharacterSet(charactersIn: "0123456789abcdef").contains
            )
    }

    private static func safeFilename(_ value: String) -> Bool {
        !value.isEmpty && value == URL(fileURLWithPath: value).lastPathComponent
    }

    private static func writeDurably(_ data: Data, to url: URL) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        try data.withUnsafeBytes { rawBuffer in
            guard var address = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, address, remaining)
                guard written > 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
                remaining -= written
                address = address.advanced(by: written)
            }
        }
        guard fsync(descriptor) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
    }

    private static func synchronizeDirectory(_ directory: URL) throws {
        let descriptor = open(directory.path, O_RDONLY)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
    }
}
