import CryptoKit
import Darwin
import Foundation

/// Durable, fail-closed evidence that immutable historical consumer artifacts
/// were produced from one source. Individual receipts are immutable and
/// generation-addressed. The five app-facing artifacts become visible only by
/// atomically replacing a small current-set pointer after the complete set is
/// durable, so a crash can never expose a mixed or partial generation.
struct AtriaHistoricalConsumerReceiptLedger {
    typealias ProjectionKind = AtriaHistoricalAggregateChunk.MaterializedProjection.Kind

    enum Outcome: String, Codable, Equatable, Sendable {
        case materialized
        case explicitlyEmpty
    }

    struct Source: Codable, Equatable, Sendable {
        let chunkID: String
        let rawSHA256: String
        let firstTimestamp: Date
        let lastTimestamp: Date
    }

    struct Receipt: Codable, Equatable, Sendable {
        static let currentVersion = 1

        let version: Int
        let source: Source
        let kind: ProjectionKind
        let consumerSchemaVersion: Int
        let algorithmVersion: String
        let configurationSHA256: String
        let dependencyStart: Date
        let dependencyEnd: Date
        let completionWatermark: Date
        let outcome: Outcome
        let recordCount: Int
        let artifactFilename: String
        let artifactSHA256: String
        let artifactByteCount: UInt64
        let settledAt: Date
    }

    struct Publication {
        let source: Source
        let kind: ProjectionKind
        let consumerSchemaVersion: Int
        let algorithmVersion: String
        let configurationSHA256: String
        let dependencyStart: Date
        let dependencyEnd: Date
        let completionWatermark: Date
        let outcome: Outcome
        let recordCount: Int
        let artifact: Data
        let settledAt: Date
    }

    struct Published: Equatable {
        let receipt: Receipt
        let receiptURL: URL
        let artifactURL: URL
        let reusedExistingReceipt: Bool
    }

    struct ValidatedArtifact: Equatable, Sendable {
        let receipt: Receipt
        let artifact: Data
    }

    enum Checkpoint: String, CaseIterable, Sendable {
        case artifactTemporaryDurable
        case artifactPublished
        case receiptTemporaryDurable
        case receiptPublished
        case currentSetTemporaryDurable
        case currentSetPublished
        case currentSetPointerTemporaryDurable
        case currentSetPointerPublished
    }

    enum LedgerError: Error, Equatable {
        case invalidSource
        case invalidConsumerSchema
        case invalidRecordCount
        case invalidOutcome
        case emptyArtifact
        case artifactConflict
        case receiptConflict
        case receiptMissing(ProjectionKind)
        case receiptInvalid(ProjectionKind)
        case artifactMissing(ProjectionKind)
        case artifactInvalid(ProjectionKind)
        case receiptTooLarge(ProjectionKind)
        case artifactTooLarge(ProjectionKind)
        case currentSetIncomplete
        case currentSetMissing
        case currentSetInvalid
        case currentSetTooLarge
        case semanticVerificationFailed(ProjectionKind)
    }

    private struct SetEntry: Codable, Equatable {
        let kind: ProjectionKind
        let receiptFilename: String
        let receiptSHA256: String
    }

    private struct ReceiptSet: Codable, Equatable {
        static let currentVersion = 1
        let version: Int
        let source: Source
        let entries: [SetEntry]
    }

    private struct CurrentSetPointer: Codable, Equatable {
        static let currentVersion = 1
        let version: Int
        let source: Source
        let setFilename: String
        let setSHA256: String
    }

    private enum BoundedReadError: Error {
        case limitExceeded
    }

    private static let maximumSetPointerBytes: UInt64 = 64 * 1_024
    private static let maximumSetBytes: UInt64 = 256 * 1_024

    private let directoryURL: URL
    private let fileManager: FileManager
    private let checkpoint: (Checkpoint) throws -> Void

    init(directoryURL: URL,
         fileManager: FileManager = .default,
         checkpoint: @escaping (Checkpoint) throws -> Void = { _ in }) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
        self.checkpoint = checkpoint
    }

    func publish(_ publication: Publication) throws -> Published {
        try Self.validate(publication)
        try fileManager.createDirectory(at: directoryURL,
                                        withIntermediateDirectories: true)

        let artifactDigest = Self.sha256(publication.artifact)
        let artifactFilename = "consumer-artifact-\(publication.kind.rawValue)-\(artifactDigest).bin"
        let artifactURL = directoryURL.appendingPathComponent(artifactFilename)
        let receipt = Receipt(version: Receipt.currentVersion,
                              source: publication.source,
                              kind: publication.kind,
                              consumerSchemaVersion: publication.consumerSchemaVersion,
                              algorithmVersion: publication.algorithmVersion,
                              configurationSHA256: publication.configurationSHA256,
                              dependencyStart: publication.dependencyStart,
                              dependencyEnd: publication.dependencyEnd,
                              completionWatermark: publication.completionWatermark,
                              outcome: publication.outcome,
                              recordCount: publication.recordCount,
                              artifactFilename: artifactFilename,
                              artifactSHA256: artifactDigest,
                              artifactByteCount: UInt64(publication.artifact.count),
                              settledAt: publication.settledAt)
        let receiptData = try Self.encode(receipt)
        let receiptDigest = Self.sha256(receiptData)
        let receiptFilename = "consumer-receipt-\(publication.kind.rawValue)-\(sourceKey(publication.source))-\(receiptDigest).json"
        let receiptURL = directoryURL.appendingPathComponent(receiptFilename)

        if fileManager.fileExists(atPath: artifactURL.path) {
            guard try Self.sha256(fileURL: artifactURL) == artifactDigest else {
                throw LedgerError.artifactConflict
            }
        } else {
            let temporaryArtifact = temporaryURL(for: artifactFilename)
            try Self.writeAndSynchronize(publication.artifact, to: temporaryArtifact)
            try checkpoint(.artifactTemporaryDurable)
            try publishTemporary(temporaryArtifact,
                                 to: artifactURL,
                                 expectedSHA256: artifactDigest,
                                 conflict: .artifactConflict)
            try Self.synchronizeDirectory(directoryURL)
            try checkpoint(.artifactPublished)
        }

        if fileManager.fileExists(atPath: receiptURL.path) {
            guard try validatedReceipt(at: receiptURL,
                                       expectedSource: publication.source,
                                       expectedKind: publication.kind,
                                       maximumReceiptBytes: UInt64(receiptData.count),
                                       maximumArtifactBytes: UInt64(publication.artifact.count)) == receipt else {
                throw LedgerError.receiptConflict
            }
            return .init(receipt: receipt,
                         receiptURL: receiptURL,
                         artifactURL: artifactURL,
                         reusedExistingReceipt: true)
        }

        let temporaryReceipt = temporaryURL(for: receiptFilename)
        try Self.writeAndSynchronize(receiptData, to: temporaryReceipt)
        try checkpoint(.receiptTemporaryDurable)
        try publishTemporary(temporaryReceipt,
                             to: receiptURL,
                             expectedSHA256: receiptDigest,
                             conflict: .receiptConflict)
        try Self.synchronizeDirectory(directoryURL)
        try checkpoint(.receiptPublished)

        guard try validatedReceipt(at: receiptURL,
                                   expectedSource: publication.source,
                                   expectedKind: publication.kind,
                                   maximumReceiptBytes: UInt64(receiptData.count),
                                   maximumArtifactBytes: UInt64(publication.artifact.count)) == receipt else {
            throw LedgerError.receiptInvalid(publication.kind)
        }
        return .init(receipt: receipt,
                     receiptURL: receiptURL,
                     artifactURL: artifactURL,
                     reusedExistingReceipt: false)
    }

    /// Makes exactly one complete app-facing generation visible. Old receipt
    /// sets and their content-addressed artifacts remain available for audit.
    func activateCurrentSet(for source: Source,
                            publications: [Published]) throws {
        try fileManager.createDirectory(at: directoryURL,
                                        withIntermediateDirectories: true)
        let expectedKinds = Self.appFacingKinds
        guard publications.count == expectedKinds.count,
              Set(publications.map(\.receipt.kind)) == Set(expectedKinds),
              publications.allSatisfy({ $0.receipt.source == source }) else {
            throw LedgerError.currentSetIncomplete
        }

        var entries: [SetEntry] = []
        for published in publications.sorted(by: { $0.receipt.kind.rawValue < $1.receipt.kind.rawValue }) {
            guard published.receiptURL.deletingLastPathComponent().standardizedFileURL
                    == directoryURL.standardizedFileURL,
                  safeFilename(published.receiptURL.lastPathComponent),
                  fileManager.fileExists(atPath: published.receiptURL.path) else {
                throw LedgerError.receiptMissing(published.receipt.kind)
            }
            let receiptBytes = try fileByteCount(at: published.receiptURL)
            guard receiptBytes <= Self.maximumSetBytes else {
                throw LedgerError.receiptTooLarge(published.receipt.kind)
            }
            guard try validatedReceipt(at: published.receiptURL,
                                       expectedSource: source,
                                       expectedKind: published.receipt.kind,
                                       maximumReceiptBytes: Self.maximumSetBytes,
                                       maximumArtifactBytes: UInt64.max) == published.receipt else {
                throw LedgerError.receiptInvalid(published.receipt.kind)
            }
            _ = try loadArtifact(published.receipt,
                                 maximumArtifactBytes: published.receipt.artifactByteCount)
            entries.append(.init(kind: published.receipt.kind,
                                 receiptFilename: published.receiptURL.lastPathComponent,
                                 receiptSHA256: try Self.sha256(fileURL: published.receiptURL)))
        }

        let set = ReceiptSet(version: ReceiptSet.currentVersion,
                             source: source,
                             entries: entries)
        let setData = try Self.encode(set)
        guard UInt64(setData.count) <= Self.maximumSetBytes else {
            throw LedgerError.currentSetTooLarge
        }
        let setDigest = Self.sha256(setData)
        let setFilename = "consumer-set-\(sourceKey(source))-\(setDigest).json"
        let setURL = directoryURL.appendingPathComponent(setFilename)
        if !fileManager.fileExists(atPath: setURL.path) {
            let temporarySet = temporaryURL(for: setFilename)
            try Self.writeAndSynchronize(setData, to: temporarySet)
            try checkpoint(.currentSetTemporaryDurable)
            try publishTemporary(temporarySet,
                                 to: setURL,
                                 expectedSHA256: setDigest,
                                 conflict: .receiptConflict)
            try Self.synchronizeDirectory(directoryURL)
            try checkpoint(.currentSetPublished)
        } else if try Self.sha256(fileURL: setURL) != setDigest {
            throw LedgerError.receiptConflict
        }

        let pointer = CurrentSetPointer(version: CurrentSetPointer.currentVersion,
                                        source: source,
                                        setFilename: setFilename,
                                        setSHA256: setDigest)
        let pointerData = try Self.encode(pointer)
        guard UInt64(pointerData.count) <= Self.maximumSetPointerBytes else {
            throw LedgerError.currentSetTooLarge
        }
        let pointerURL = currentSetPointerURL(source)
        let temporaryPointer = temporaryURL(for: pointerURL.lastPathComponent)
        try Self.writeAndSynchronize(pointerData, to: temporaryPointer)
        try checkpoint(.currentSetPointerTemporaryDurable)
        try replaceAtomically(temporaryPointer, at: pointerURL)
        try Self.synchronizeDirectory(directoryURL)
        try checkpoint(.currentSetPointerPublished)
    }

    /// Loads only the generation selected by the atomic current-set pointer.
    /// No orphan receipt prefix can become consumer-visible.
    func validatedCurrentSet(
        for source: Source,
        maximumReceiptBytes: UInt64 = 64 * 1_024,
        maximumArtifactBytes: UInt64 = 16 * 1_024 * 1_024
    ) throws -> [ProjectionKind: ValidatedArtifact] {
        guard maximumReceiptBytes > 0, maximumArtifactBytes > 0 else {
            throw LedgerError.currentSetTooLarge
        }
        let pointerURL = currentSetPointerURL(source)
        guard fileManager.fileExists(atPath: pointerURL.path) else {
            throw LedgerError.currentSetMissing
        }
        let pointerData: Data
        do {
            pointerData = try boundedData(at: pointerURL,
                                          maximumBytes: Self.maximumSetPointerBytes)
        } catch BoundedReadError.limitExceeded {
            throw LedgerError.currentSetTooLarge
        }
        let pointer: CurrentSetPointer
        do {
            pointer = try Self.decode(CurrentSetPointer.self, from: pointerData)
        } catch {
            throw LedgerError.currentSetInvalid
        }
        guard pointer.version == CurrentSetPointer.currentVersion,
              pointer.source == source,
              safeFilename(pointer.setFilename),
              Self.isSHA256(pointer.setSHA256) else {
            throw LedgerError.currentSetInvalid
        }
        let setURL = directoryURL.appendingPathComponent(pointer.setFilename)
        guard fileManager.fileExists(atPath: setURL.path) else {
            throw LedgerError.currentSetInvalid
        }
        let setData: Data
        do {
            setData = try boundedData(at: setURL, maximumBytes: Self.maximumSetBytes)
        } catch BoundedReadError.limitExceeded {
            throw LedgerError.currentSetTooLarge
        }
        guard Self.sha256(setData) == pointer.setSHA256 else {
            throw LedgerError.currentSetInvalid
        }
        let set: ReceiptSet
        do {
            set = try Self.decode(ReceiptSet.self, from: setData)
        } catch {
            throw LedgerError.currentSetInvalid
        }
        let expectedKinds = Self.appFacingKinds
        guard set.version == ReceiptSet.currentVersion,
              set.source == source,
              set.entries.count == expectedKinds.count,
              Set(set.entries.map(\.kind)) == Set(expectedKinds) else {
            throw LedgerError.currentSetInvalid
        }

        var result: [ProjectionKind: ValidatedArtifact] = [:]
        for entry in set.entries {
            guard safeFilename(entry.receiptFilename),
                  Self.isSHA256(entry.receiptSHA256) else {
                throw LedgerError.currentSetInvalid
            }
            let receiptURL = directoryURL.appendingPathComponent(entry.receiptFilename)
            let receiptData: Data
            do {
                receiptData = try boundedData(at: receiptURL,
                                              maximumBytes: maximumReceiptBytes)
            } catch BoundedReadError.limitExceeded {
                throw LedgerError.receiptTooLarge(entry.kind)
            } catch {
                throw LedgerError.receiptMissing(entry.kind)
            }
            guard Self.sha256(receiptData) == entry.receiptSHA256 else {
                throw LedgerError.receiptInvalid(entry.kind)
            }
            let receipt = try validatedReceipt(data: receiptData,
                                               expectedSource: source,
                                               expectedKind: entry.kind,
                                               maximumArtifactBytes: maximumArtifactBytes)
            result[entry.kind] = try loadArtifact(receipt,
                                                  maximumArtifactBytes: maximumArtifactBytes)
        }
        return result
    }

    /// Backward-compatible single-artifact API, now resolved exclusively from
    /// the atomic current set rather than a source/kind singleton filename.
    func validatedArtifact(
        for source: Source,
        kind: ProjectionKind,
        maximumReceiptBytes: UInt64 = 64 * 1_024,
        maximumArtifactBytes: UInt64 = 16 * 1_024 * 1_024
    ) throws -> ValidatedArtifact {
        guard let value = try validatedCurrentSet(for: source,
                                                  maximumReceiptBytes: maximumReceiptBytes,
                                                  maximumArtifactBytes: maximumArtifactBytes)[kind] else {
            throw LedgerError.receiptMissing(kind)
        }
        return value
    }

    /// Idempotently removes only the large replay staging payload selected by
    /// an already-durable replay-compaction proof. Replay is not part of the
    /// typed current-set pointer, so sleep/workout/activity/strain/step receipts
    /// remain untouched. Every still-present byte is re-hashed before unlink.
    @discardableResult
    func retireReplayStagingPayload(
        receipt: Receipt
    ) throws -> UInt64 {
        guard receipt.kind == .replayIdentity else {
            throw LedgerError.receiptInvalid(receipt.kind)
        }
        let receiptData = try Self.encode(receipt)
        let receiptDigest = Self.sha256(receiptData)
        let receiptFilename = "consumer-receipt-\(receipt.kind.rawValue)-\(sourceKey(receipt.source))-\(receiptDigest).json"
        let receiptURL = directoryURL.appendingPathComponent(receiptFilename)
        let artifactURL = directoryURL.appendingPathComponent(receipt.artifactFilename)
        var bytes: UInt64 = 0
        if fileManager.fileExists(atPath: receiptURL.path) {
            guard try boundedData(at: receiptURL, maximumBytes: 256 * 1_024) == receiptData else {
                throw LedgerError.receiptInvalid(.replayIdentity)
            }
            bytes += try fileByteCount(at: receiptURL)
        }
        if fileManager.fileExists(atPath: artifactURL.path) {
            let artifactBytes = try fileByteCount(at: artifactURL)
            guard artifactBytes == receipt.artifactByteCount,
                  try Self.sha256(fileURL: artifactURL) == receipt.artifactSHA256 else {
                throw LedgerError.artifactInvalid(.replayIdentity)
            }
            bytes += artifactBytes
        }
        if fileManager.fileExists(atPath: artifactURL.path) {
            try fileManager.removeItem(at: artifactURL)
        }
        if fileManager.fileExists(atPath: receiptURL.path) {
            try fileManager.removeItem(at: receiptURL)
        }
        if bytes > 0 { try Self.synchronizeDirectory(directoryURL) }
        return bytes
    }

    /// Retirement remains disabled in production, but this audit API preserves
    /// verification of all historical receipt generations, including replay
    /// identity. Exactly one semantically valid candidate must exist per kind.
    func validatedMaterializedProjections(
        for source: Source,
        semanticVerifier: (Receipt, Data) throws -> Bool
    ) throws -> [AtriaHistoricalAggregateChunk.MaterializedProjection] {
        var projections: [AtriaHistoricalAggregateChunk.MaterializedProjection] = []
        for kind in AtriaHistoricalAggregateChunk.rawRetirementRequiredProjectionKinds
            .sorted(by: { $0.rawValue < $1.rawValue }) {
            let candidates = try receiptCandidates(source: source, kind: kind)
            guard !candidates.isEmpty else { throw LedgerError.receiptMissing(kind) }
            var verified: [(Receipt, URL)] = []
            var firstValidationError: Error?
            for url in candidates {
                do {
                    let receipt = try validatedReceipt(at: url,
                                                       expectedSource: source,
                                                       expectedKind: kind,
                                                       maximumReceiptBytes: Self.maximumSetBytes,
                                                       maximumArtifactBytes: UInt64.max)
                    let artifact = try loadArtifact(receipt,
                                                    maximumArtifactBytes: 256 * 1_024 * 1_024).artifact
                    if try semanticVerifier(receipt, artifact) {
                        verified.append((receipt, url))
                    }
                } catch {
                    if firstValidationError == nil { firstValidationError = error }
                }
            }
            guard verified.count == 1, let selected = verified.first else {
                if verified.isEmpty, let firstValidationError { throw firstValidationError }
                throw LedgerError.semanticVerificationFailed(kind)
            }
            projections.append(.init(kind: kind,
                                     identifier: selected.1.lastPathComponent,
                                     start: selected.0.source.firstTimestamp,
                                     end: selected.0.source.lastTimestamp,
                                     schemaVersion: selected.0.consumerSchemaVersion,
                                     contentSHA256: selected.0.artifactSHA256,
                                     settledAt: selected.0.settledAt))
        }
        return projections
    }

    private static var appFacingKinds: [ProjectionKind] {
        [.activity, .dailyMetrics, .steps, .sleep, .workout]
    }

    private func validatedReceipt(at url: URL,
                                  expectedSource: Source,
                                  expectedKind: ProjectionKind,
                                  maximumReceiptBytes: UInt64,
                                  maximumArtifactBytes: UInt64) throws -> Receipt {
        let data: Data
        do {
            data = try boundedData(at: url, maximumBytes: maximumReceiptBytes)
        } catch BoundedReadError.limitExceeded {
            throw LedgerError.receiptTooLarge(expectedKind)
        } catch {
            throw LedgerError.receiptMissing(expectedKind)
        }
        return try validatedReceipt(data: data,
                                    expectedSource: expectedSource,
                                    expectedKind: expectedKind,
                                    maximumArtifactBytes: maximumArtifactBytes)
    }

    private func validatedReceipt(data: Data,
                                  expectedSource: Source,
                                  expectedKind: ProjectionKind,
                                  maximumArtifactBytes: UInt64) throws -> Receipt {
        guard let receipt = try? Self.decode(Receipt.self, from: data),
              receipt.version == Receipt.currentVersion,
              receipt.source == expectedSource,
              receipt.kind == expectedKind,
              receipt.consumerSchemaVersion > 0,
              !receipt.algorithmVersion.isEmpty,
              Self.isSHA256(receipt.configurationSHA256),
              receipt.dependencyStart <= receipt.source.firstTimestamp,
              receipt.dependencyEnd >= receipt.source.lastTimestamp,
              receipt.completionWatermark >= receipt.dependencyEnd,
              receipt.settledAt >= receipt.completionWatermark,
              receipt.recordCount >= 0,
              receipt.artifactByteCount > 0,
              receipt.artifactByteCount <= maximumArtifactBytes,
              Self.isSHA256(receipt.artifactSHA256),
              receipt.artifactFilename
                == "consumer-artifact-\(receipt.kind.rawValue)-\(receipt.artifactSHA256).bin",
              Self.outcomeIsConsistent(receipt.outcome,
                                       recordCount: receipt.recordCount) else {
            if let receipt = try? Self.decode(Receipt.self, from: data),
               receipt.artifactByteCount > maximumArtifactBytes {
                throw LedgerError.artifactTooLarge(expectedKind)
            }
            throw LedgerError.receiptInvalid(expectedKind)
        }
        return receipt
    }

    private func loadArtifact(_ receipt: Receipt,
                              maximumArtifactBytes: UInt64) throws -> ValidatedArtifact {
        guard receipt.artifactByteCount <= maximumArtifactBytes else {
            throw LedgerError.artifactTooLarge(receipt.kind)
        }
        let artifactURL = directoryURL.appendingPathComponent(receipt.artifactFilename)
        guard artifactURL.deletingLastPathComponent().standardizedFileURL
                == directoryURL.standardizedFileURL,
              fileManager.fileExists(atPath: artifactURL.path) else {
            throw LedgerError.artifactMissing(receipt.kind)
        }
        let artifact: Data
        do {
            artifact = try boundedData(at: artifactURL,
                                       maximumBytes: maximumArtifactBytes)
        } catch BoundedReadError.limitExceeded {
            throw LedgerError.artifactTooLarge(receipt.kind)
        }
        guard UInt64(artifact.count) == receipt.artifactByteCount,
              Self.sha256(artifact) == receipt.artifactSHA256 else {
            throw LedgerError.artifactInvalid(receipt.kind)
        }
        return .init(receipt: receipt, artifact: artifact)
    }

    private func receiptCandidates(source: Source,
                                   kind: ProjectionKind) throws -> [URL] {
        let prefix = "consumer-receipt-\(kind.rawValue)-\(sourceKey(source))-"
        return try fileManager.contentsOfDirectory(at: directoryURL,
                                                   includingPropertiesForKeys: nil,
                                                   options: [.skipsHiddenFiles])
            .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func currentSetPointerURL(_ source: Source) -> URL {
        directoryURL.appendingPathComponent("consumer-set-current-\(sourceKey(source)).json")
    }

    private func sourceKey(_ source: Source) -> String {
        Self.sha256(Data("\(source.chunkID)|\(source.rawSHA256)".utf8))
    }

    private func temporaryURL(for filename: String) -> URL {
        directoryURL.appendingPathComponent(".\(filename).\(UUID().uuidString).tmp")
    }

    private static func validate(_ publication: Publication) throws {
        guard !publication.source.chunkID.isEmpty,
              isSHA256(publication.source.rawSHA256),
              publication.source.lastTimestamp > publication.source.firstTimestamp else {
            throw LedgerError.invalidSource
        }
        guard publication.consumerSchemaVersion > 0 else {
            throw LedgerError.invalidConsumerSchema
        }
        guard !publication.algorithmVersion.isEmpty,
              isSHA256(publication.configurationSHA256),
              publication.dependencyStart <= publication.source.firstTimestamp,
              publication.dependencyEnd >= publication.source.lastTimestamp,
              publication.completionWatermark >= publication.dependencyEnd,
              publication.settledAt >= publication.completionWatermark else {
            throw LedgerError.invalidSource
        }
        guard publication.recordCount >= 0 else {
            throw LedgerError.invalidRecordCount
        }
        guard outcomeIsConsistent(publication.outcome,
                                  recordCount: publication.recordCount) else {
            throw LedgerError.invalidOutcome
        }
        guard !publication.artifact.isEmpty else { throw LedgerError.emptyArtifact }
    }

    private static func outcomeIsConsistent(_ outcome: Outcome,
                                            recordCount: Int) -> Bool {
        switch outcome {
        case .materialized: return recordCount > 0
        case .explicitlyEmpty: return recordCount == 0
        }
    }

    private static func isSHA256(_ value: String) -> Bool {
        let lowercaseHex = CharacterSet(charactersIn: "0123456789abcdef")
        return value.count == 64
            && value.unicodeScalars.allSatisfy(lowercaseHex.contains)
    }

    private func safeFilename(_ value: String) -> Bool {
        !value.isEmpty
            && URL(fileURLWithPath: value).lastPathComponent == value
            && value != "."
            && value != ".."
    }

    private func publishTemporary(_ temporaryURL: URL,
                                  to finalURL: URL,
                                  expectedSHA256: String,
                                  conflict: LedgerError) throws {
        if fileManager.fileExists(atPath: finalURL.path) {
            guard try Self.sha256(fileURL: finalURL) == expectedSHA256 else { throw conflict }
            try? fileManager.removeItem(at: temporaryURL)
            return
        }
        do {
            try fileManager.moveItem(at: temporaryURL, to: finalURL)
        } catch {
            if fileManager.fileExists(atPath: finalURL.path),
               try Self.sha256(fileURL: finalURL) == expectedSHA256 {
                try? fileManager.removeItem(at: temporaryURL)
                return
            }
            throw error
        }
    }

    private func replaceAtomically(_ temporaryURL: URL, at finalURL: URL) throws {
        guard rename(temporaryURL.path, finalURL.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func boundedData(at url: URL, maximumBytes: UInt64) throws -> Data {
        guard maximumBytes > 0,
              maximumBytes < UInt64(Int.max),
              try fileByteCount(at: url) <= maximumBytes else {
            throw BoundedReadError.limitExceeded
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Int(maximumBytes) + 1) ?? Data()
        guard UInt64(data.count) <= maximumBytes else {
            throw BoundedReadError.limitExceeded
        }
        return data
    }

    private func fileByteCount(at url: URL) throws -> UInt64 {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }

    private static func writeAndSynchronize(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    private static func synchronizeDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256(fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
