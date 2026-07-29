import CryptoKit
import Darwin
import Foundation

/// Fail-closed publication of one verified long-term aggregate.
///
/// A manifest is the commit marker. Raw deletion is ordered strictly after the
/// aggregate and manifest have been fsynced, published, fsynced at their parent
/// directories, decoded again, hashed again, and semantically compared with
/// the immutable source. Any interruption before that point leaves raw intact.
struct AtriaHistoricalRetentionTransaction {
    struct Manifest: Codable, Equatable, Sendable {
        static let currentVersion = 2

        let version: Int
        let transactionID: String
        let committedAt: Date
        let sourceChunkID: String
        let sourceFilename: String
        let sourceSHA256: String
        let sourceByteCount: UInt64
        let sourceRowCount: Int
        let sourceFirstTimestamp: Date
        let sourceLastTimestamp: Date
        let aggregateFilename: String
        let aggregateSHA256: String
        let aggregateByteCount: UInt64
        let aggregateSchema: Int
        let heartRateMinuteCount: Int
        let rrEpochCount: Int
        let motionEpochCount: Int
        let semanticParityReceipt: String
    }

    struct Request {
        let transactionID: String
        let sourceURL: URL
        let aggregateDirectoryURL: URL
        let manifestDirectoryURL: URL
        let aggregate: AtriaHistoricalAggregateChunk
        /// Must be a digest/receipt from the canonical raw-vs-derived consumer
        /// parity verifier, not a caller assertion such as `true`.
        let semanticParityReceipt: String
        let deleteSourceAfterCommit: Bool
    }

    /// Separate API surface for a canonical shadow aggregate whose immutable
    /// raw source remains authoritative. There is deliberately no deletion
    /// flag here, so this cheaper proof can never authorize raw retirement.
    struct RetainedRawShadowRequest {
        let transactionID: String
        let sourceURL: URL
        let aggregateDirectoryURL: URL
        let manifestDirectoryURL: URL
        let proof: AtriaHistoricalAggregateBuilder.RetainedRawShadowProof
    }

    struct Result: Equatable {
        let manifestURL: URL
        let aggregateURL: URL
        let sourceDeleted: Bool
        let reusedCommittedTransaction: Bool
    }

    enum Checkpoint: String, CaseIterable, Sendable {
        case aggregateTemporaryDurable
        case manifestTemporaryDurable
        case temporaryArtifactsVerified
        case aggregatePublished
        case manifestPublished
        case committedArtifactsVerified
        case sourceDeleted
    }

    enum TransactionError: Error, Equatable {
        case sourceMissing
        case sourceIsNotRegularFile
        case invalidTransactionID
        case sourceDigestMismatch
        case sourceSizeMismatch
        case semanticParityReceiptMissing
        case aggregateConflict
        case manifestConflict
        case verificationFailed
        case rawRetirementNotAuthorized
    }

    private let fileManager: FileManager
    private let now: () -> Date
    private let checkpoint: (Checkpoint) throws -> Void
    /// Recomputes canonical metric/projection parity directly from the raw
    /// source. Returning false prevents manifest publication and raw deletion.
    private let semanticVerifier: (URL, AtriaHistoricalAggregateChunk, String) throws -> Bool
    /// Reloads and semantically verifies every immutable consumer artifact.
    /// The safe default denies raw retirement; callers that only publish shadow
    /// aggregates do not need a consumer ledger yet.
    private let consumerProjectionVerifier: (AtriaHistoricalAggregateChunk) throws -> Bool
    /// Independently proves that every canonical downstream application store
    /// has durably consumed the verified replacements for this exact source.
    /// Projection publication is not application: keeping this as a distinct,
    /// fail-closed gate prevents a complete receipt set from authorizing raw
    /// deletion while any app feature still reads the source records.
    private let consumerApplicationVerifier: (AtriaHistoricalAggregateChunk) throws -> Bool
    /// Authorizes the production layout where an immutable shadow aggregate
    /// predates consumer publication and therefore cannot embed later receipt
    /// filenames. The default denies. Production callers must bind this to the
    /// exact file-backed six-artifact and canonical-application identity.
    private let externalRawRetirementAuthorizer: (AtriaHistoricalAggregateChunk) throws -> Bool

    init(fileManager: FileManager = .default,
         now: @escaping () -> Date = Date.init,
         checkpoint: @escaping (Checkpoint) throws -> Void = { _ in },
         consumerProjectionVerifier: @escaping (AtriaHistoricalAggregateChunk) throws -> Bool = { _ in false },
         consumerApplicationVerifier: @escaping (AtriaHistoricalAggregateChunk) throws -> Bool = { _ in false },
         externalRawRetirementAuthorizer: @escaping (AtriaHistoricalAggregateChunk) throws -> Bool = { _ in false },
         semanticVerifier: @escaping (URL, AtriaHistoricalAggregateChunk, String) throws -> Bool) {
        self.fileManager = fileManager
        self.now = now
        self.checkpoint = checkpoint
        self.consumerProjectionVerifier = consumerProjectionVerifier
        self.consumerApplicationVerifier = consumerApplicationVerifier
        self.externalRawRetirementAuthorizer = externalRawRetirementAuthorizer
        self.semanticVerifier = semanticVerifier
    }

    func commit(_ request: Request) throws -> Result {
        try commit(request, semanticVerification: semanticVerifier)
    }

    func commitRetainedRawShadow(
        _ shadow: RetainedRawShadowRequest
    ) throws -> Result {
        guard AtriaHistoricalAggregateBuilder.validateRetainedRawShadowProof(
            shadow.proof
        ) else {
            throw TransactionError.verificationFailed
        }
        let request = Request(
            transactionID: shadow.transactionID,
            sourceURL: shadow.sourceURL,
            aggregateDirectoryURL: shadow.aggregateDirectoryURL,
            manifestDirectoryURL: shadow.manifestDirectoryURL,
            aggregate: shadow.proof.aggregate,
            semanticParityReceipt: shadow.proof.semanticParityReceipt,
            deleteSourceAfterCommit: false
        )
        let result = try commit(
            request,
            semanticVerification: { _, aggregate, receipt in
                aggregate == shadow.proof.aggregate
                    && receipt == shadow.proof.semanticParityReceipt
                    && AtriaHistoricalAggregateBuilder
                        .validateRetainedRawShadowProof(shadow.proof)
            }
        )
        // The generic transaction already checks identity before publication
        // and again before its commit marker. Seal the shadow API return as
        // well, including committed-retry paths that find a prior manifest.
        guard try AtriaHistoricalJSONLInput.identity(at: shadow.sourceURL)
            == shadow.proof.sourceIdentity else {
            throw TransactionError.sourceDigestMismatch
        }
        return result
    }

    private func commit(
        _ request: Request,
        semanticVerification:
            (URL, AtriaHistoricalAggregateChunk, String) throws -> Bool
    ) throws -> Result {
        guard Self.validIdentifier(request.transactionID) else {
            throw TransactionError.invalidTransactionID
        }
        guard !request.semanticParityReceipt.isEmpty else {
            throw TransactionError.semanticParityReceiptMissing
        }
        if request.deleteSourceAfterCommit {
            guard try rawRetirementAuthorized(request.aggregate),
                  try consumerProjectionVerifier(request.aggregate),
                  try consumerApplicationVerifier(request.aggregate) else {
                throw TransactionError.rawRetirementNotAuthorized
            }
        }
        guard fileManager.fileExists(atPath: request.sourceURL.path) else {
            // An already-committed retry is valid even after source retirement.
            return try loadCommittedResult(request, sourceDeleted: true)
        }
        let values = try request.sourceURL.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else { throw TransactionError.sourceIsNotRegularFile }
        // Aggregate identity is always the canonical decoded JSONL stream.
        // This is byte-identical to a plain source and transparently inflates
        // an immutable compressed source. Comparing the physical DEFLATE bytes
        // with a logical raw receipt would otherwise strand compressed chunks.
        let sourceIdentity = try AtriaHistoricalJSONLInput.identity(
            at: request.sourceURL
        )
        let sourceBytes = sourceIdentity.byteCount
        let sourceDigest = sourceIdentity.sha256
        guard sourceDigest == request.aggregate.source.rawSHA256 else {
            throw TransactionError.sourceDigestMismatch
        }
        guard sourceBytes == request.aggregate.source.rawByteCount else {
            throw TransactionError.sourceSizeMismatch
        }
        try request.aggregate.validateForCommit()

        try fileManager.createDirectory(at: request.aggregateDirectoryURL,
                                        withIntermediateDirectories: true)
        try fileManager.createDirectory(at: request.manifestDirectoryURL,
                                        withIntermediateDirectories: true)

        let aggregateFilename = "aggregate-\(request.transactionID).json"
        let manifestFilename = "manifest-\(request.transactionID).json"
        let aggregateURL = request.aggregateDirectoryURL.appendingPathComponent(aggregateFilename)
        let manifestURL = request.manifestDirectoryURL.appendingPathComponent(manifestFilename)
        if fileManager.fileExists(atPath: manifestURL.path) {
            return try finishCommittedRetry(request,
                                            aggregateURL: aggregateURL,
                                            manifestURL: manifestURL)
        }

        let nonce = UUID().uuidString
        let aggregateTemporaryURL = request.aggregateDirectoryURL
            .appendingPathComponent(".\(aggregateFilename).\(nonce).tmp")
        let manifestTemporaryURL = request.manifestDirectoryURL
            .appendingPathComponent(".\(manifestFilename).\(nonce).tmp")
        // A failed semantic verification or lifecycle cancellation must not
        // strand a complete multi-megabyte temporary aggregate. Crash-left
        // files are handled by generated-artifact GC; ordinary thrown errors
        // are cleaned synchronously here.
        defer {
            try? fileManager.removeItem(at: aggregateTemporaryURL)
            try? fileManager.removeItem(at: manifestTemporaryURL)
        }
        let encoder = Self.canonicalEncoder()
        let aggregateData = try encoder.encode(request.aggregate)
        let aggregateDigest = Self.sha256(of: aggregateData)

        try writeAndSynchronize(aggregateData, to: aggregateTemporaryURL)
        try checkpoint(.aggregateTemporaryDurable)

        let manifest = Manifest(
            version: Manifest.currentVersion,
            transactionID: request.transactionID,
            committedAt: now(),
            sourceChunkID: request.aggregate.source.chunkID,
            sourceFilename: request.sourceURL.lastPathComponent,
            sourceSHA256: sourceDigest,
            sourceByteCount: sourceBytes,
            sourceRowCount: request.aggregate.source.rawRowCount,
            sourceFirstTimestamp: request.aggregate.source.firstTimestamp,
            sourceLastTimestamp: request.aggregate.source.lastTimestamp,
            aggregateFilename: aggregateFilename,
            aggregateSHA256: aggregateDigest,
            aggregateByteCount: UInt64(aggregateData.count),
            aggregateSchema: request.aggregate.schema,
            heartRateMinuteCount: request.aggregate.heartRateMinutes.count,
            rrEpochCount: request.aggregate.rrEpochs.count,
            motionEpochCount: request.aggregate.motionEpochs.count,
            semanticParityReceipt: request.semanticParityReceipt
        )
        let manifestData = try encoder.encode(manifest)
        try writeAndSynchronize(manifestData, to: manifestTemporaryURL)
        try checkpoint(.manifestTemporaryDurable)
        try Self.synchronizeDirectory(request.aggregateDirectoryURL)
        if request.manifestDirectoryURL.standardizedFileURL != request.aggregateDirectoryURL.standardizedFileURL {
            try Self.synchronizeDirectory(request.manifestDirectoryURL)
        }

        guard try verifyAggregate(at: aggregateTemporaryURL,
                                  expectedDigest: aggregateDigest,
                                  expected: request.aggregate),
              try verifyManifest(at: manifestTemporaryURL,
                                 expectedDigest: Self.sha256(of: manifestData),
                                 expected: manifest),
              try semanticVerification(request.sourceURL,
                                       request.aggregate,
                                       request.semanticParityReceipt) else {
            throw TransactionError.verificationFailed
        }
        // Source immutability is checked again after the potentially expensive
        // semantic pass. An append to a supposedly sealed file fails closed.
        guard try AtriaHistoricalJSONLInput.identity(at: request.sourceURL)
            == sourceIdentity else {
            throw TransactionError.sourceDigestMismatch
        }
        try checkpoint(.temporaryArtifactsVerified)
        // A checkpoint is an explicit crash/fault-injection seam and may run
        // arbitrary test or diagnostic work. Re-seal source identity after it
        // so no artifact can be published from a source changed at that edge.
        guard try AtriaHistoricalJSONLInput.identity(at: request.sourceURL)
            == sourceIdentity else {
            throw TransactionError.sourceDigestMismatch
        }

        try publish(temporaryURL: aggregateTemporaryURL,
                    finalURL: aggregateURL,
                    expectedDigest: aggregateDigest,
                    conflict: .aggregateConflict)
        try Self.synchronizeDirectory(request.aggregateDirectoryURL)
        try checkpoint(.aggregatePublished)

        try publish(temporaryURL: manifestTemporaryURL,
                    finalURL: manifestURL,
                    expectedDigest: Self.sha256(of: manifestData),
                    conflict: .manifestConflict)
        try Self.synchronizeDirectory(request.manifestDirectoryURL)
        try checkpoint(.manifestPublished)

        guard try verifyCommitted(manifestURL: manifestURL,
                                  aggregateURL: aggregateURL,
                                  expectedManifest: manifest,
                                  expectedAggregate: request.aggregate) else {
            throw TransactionError.verificationFailed
        }
        try checkpoint(.committedArtifactsVerified)

        var sourceDeleted = false
        if request.deleteSourceAfterCommit {
            // Verify once more immediately before the irreversible step.
            guard try rawRetirementAuthorized(request.aggregate),
                  try consumerProjectionVerifier(request.aggregate),
                  try consumerApplicationVerifier(request.aggregate) else {
                throw TransactionError.rawRetirementNotAuthorized
            }
            let identity = try AtriaHistoricalJSONLInput.identity(
                at: request.sourceURL
            )
            guard identity.sha256 == manifest.sourceSHA256,
                  identity.byteCount == manifest.sourceByteCount else {
                throw TransactionError.sourceDigestMismatch
            }
            try fileManager.removeItem(at: request.sourceURL)
            try Self.synchronizeDirectory(request.sourceURL.deletingLastPathComponent())
            sourceDeleted = true
            try checkpoint(.sourceDeleted)
        }
        return Result(manifestURL: manifestURL,
                      aggregateURL: aggregateURL,
                      sourceDeleted: sourceDeleted,
                      reusedCommittedTransaction: false)
    }

    private func finishCommittedRetry(_ request: Request,
                                      aggregateURL: URL,
                                      manifestURL: URL) throws -> Result {
        let result = try loadCommittedResult(request, sourceDeleted: false)
        var sourceDeleted = false
        if request.deleteSourceAfterCommit,
           fileManager.fileExists(atPath: request.sourceURL.path) {
            let manifest = try decodeManifest(at: manifestURL)
            guard try rawRetirementAuthorized(request.aggregate),
                  try consumerProjectionVerifier(request.aggregate),
                  try consumerApplicationVerifier(request.aggregate) else {
                throw TransactionError.rawRetirementNotAuthorized
            }
            let identity = try AtriaHistoricalJSONLInput.identity(
                at: request.sourceURL
            )
            guard identity.sha256 == manifest.sourceSHA256,
                  identity.byteCount == manifest.sourceByteCount else {
                throw TransactionError.sourceDigestMismatch
            }
            try fileManager.removeItem(at: request.sourceURL)
            try Self.synchronizeDirectory(request.sourceURL.deletingLastPathComponent())
            sourceDeleted = true
            try checkpoint(.sourceDeleted)
        }
        return Result(manifestURL: result.manifestURL,
                      aggregateURL: result.aggregateURL,
                      sourceDeleted: sourceDeleted,
                      reusedCommittedTransaction: true)
    }

    private func rawRetirementAuthorized(
        _ aggregate: AtriaHistoricalAggregateChunk
    ) throws -> Bool {
        if aggregate.authorizesRawRetirement { return true }
        return try externalRawRetirementAuthorizer(aggregate)
    }

    private func loadCommittedResult(_ request: Request,
                                     sourceDeleted: Bool) throws -> Result {
        let aggregateURL = request.aggregateDirectoryURL
            .appendingPathComponent("aggregate-\(request.transactionID).json")
        let manifestURL = request.manifestDirectoryURL
            .appendingPathComponent("manifest-\(request.transactionID).json")
        guard fileManager.fileExists(atPath: aggregateURL.path),
              fileManager.fileExists(atPath: manifestURL.path) else {
            throw TransactionError.sourceMissing
        }
        let manifest = try decodeManifest(at: manifestURL)
        guard manifest.transactionID == request.transactionID,
              manifest.sourceChunkID == request.aggregate.source.chunkID,
              manifest.sourceSHA256 == request.aggregate.source.rawSHA256,
              manifest.semanticParityReceipt == request.semanticParityReceipt,
              try verifyCommitted(manifestURL: manifestURL,
                                  aggregateURL: aggregateURL,
                                  expectedManifest: manifest,
                                  expectedAggregate: request.aggregate) else {
            throw TransactionError.manifestConflict
        }
        return Result(manifestURL: manifestURL,
                      aggregateURL: aggregateURL,
                      sourceDeleted: sourceDeleted,
                      reusedCommittedTransaction: true)
    }

    private func verifyCommitted(manifestURL: URL,
                                 aggregateURL: URL,
                                 expectedManifest: Manifest,
                                 expectedAggregate: AtriaHistoricalAggregateChunk) throws -> Bool {
        try verifyManifest(at: manifestURL,
                           expectedDigest: nil,
                           expected: expectedManifest)
            && verifyAggregate(at: aggregateURL,
                               expectedDigest: expectedManifest.aggregateSHA256,
                               expected: expectedAggregate)
    }

    private func verifyAggregate(at url: URL,
                                 expectedDigest: String,
                                 expected: AtriaHistoricalAggregateChunk) throws -> Bool {
        guard try Self.sha256(of: url) == expectedDigest else { return false }
        let data = try Data(contentsOf: url)
        let decoder = Self.canonicalDecoder()
        let decoded = try decoder.decode(AtriaHistoricalAggregateChunk.self, from: data)
        let persistedExpected = try decoder.decode(
            AtriaHistoricalAggregateChunk.self,
            from: Self.canonicalEncoder().encode(expected)
        )
        try decoded.validateForCommit()
        return decoded == persistedExpected
    }

    private func verifyManifest(at url: URL,
                                expectedDigest: String?,
                                expected: Manifest) throws -> Bool {
        if let expectedDigest, try Self.sha256(of: url) != expectedDigest { return false }
        let decoder = Self.canonicalDecoder()
        let persistedExpected = try decoder.decode(
            Manifest.self,
            from: Self.canonicalEncoder().encode(expected)
        )
        return try decodeManifest(at: url) == persistedExpected
    }

    private func decodeManifest(at url: URL) throws -> Manifest {
        try Self.canonicalDecoder().decode(
            Manifest.self,
            from: Data(contentsOf: url)
        )
    }

    private static func canonicalEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func canonicalDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func writeAndSynchronize(_ data: Data, to url: URL) throws {
        guard fileManager.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: url)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
    }

    private func publish(temporaryURL: URL,
                         finalURL: URL,
                         expectedDigest: String,
                         conflict: TransactionError) throws {
        if fileManager.fileExists(atPath: finalURL.path) {
            guard try Self.sha256(of: finalURL) == expectedDigest else { throw conflict }
            try? fileManager.removeItem(at: temporaryURL)
            return
        }
        try fileManager.moveItem(at: temporaryURL, to: finalURL)
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39)
                || (byte >= 0x41 && byte <= 0x5a)
                || (byte >= 0x61 && byte <= 0x7a)
                || byte == 0x2d || byte == 0x5f || byte == 0x2e
        }
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
