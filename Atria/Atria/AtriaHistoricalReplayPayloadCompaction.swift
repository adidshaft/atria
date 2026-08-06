import CryptoKit
import Darwin
import Foundation

/// Durable substitution receipt for the two large copies of replay identity
/// payload (receipt staging and canonical replay destination). Typed historical
/// snapshots remain independent and continue to serve every app-visible view.
struct AtriaHistoricalReplayPayloadCompactionStore {
    enum Checkpoint: Equatable, Sendable {
        case proofTemporaryDurable
        case proofPublished
    }

    struct Proof: Codable, Equatable, Sendable {
        static let currentSchema = 1

        let schema: Int
        let source: AtriaHistoricalConsumerReceiptLedger.Source
        let verificationIdentitySHA256: String
        let replayReceiptSHA256: String
        let replayArtifactSHA256: String
        let replayArtifactByteCount: UInt64
        let replayIndexReceipt: AtriaHistoricalRetiredReplayIndex.ImportReceipt
        let publishedAt: Date
    }

    enum ProofError: Error, Equatable {
        case invalidIdentity
        case indexAuthorityMissing
        case conflict
        case corrupt
    }

    let directoryURL: URL
    var fileManager: FileManager = .default
    var checkpoint: (Checkpoint) throws -> Void = { _ in }

    func publish(
        identity: AtriaHistoricalCanonicalConsumerApplicationStore.VerificationIdentity,
        indexReceipt: AtriaHistoricalRetiredReplayIndex.ImportReceipt,
        replayIndex: AtriaHistoricalRetiredReplayIndex,
        publishedAt: Date = Date()
    ) throws -> Proof {
        guard identity.source.chunkID == indexReceipt.sourceChunkID,
              identity.source.rawSHA256 == indexReceipt.sourceRawSHA256,
              identity.replayReceipt.kind == .replayIdentity,
              identity.replayReceipt.recordCount == indexReceipt.identityCount,
              identity.replayReceipt.artifactSHA256.count == 64,
              publishedAt.timeIntervalSince1970.isFinite else {
            throw ProofError.invalidIdentity
        }
        guard try replayIndex.verifiesRetiredSource(indexReceipt) else {
            throw ProofError.indexAuthorityMissing
        }
        let proof = Proof(
            schema: Proof.currentSchema,
            source: identity.source,
            verificationIdentitySHA256: Self.sha256(try Self.encode(identity)),
            replayReceiptSHA256: Self.sha256(try Self.encode(identity.replayReceipt)),
            replayArtifactSHA256: identity.replayReceipt.artifactSHA256,
            replayArtifactByteCount: identity.replayReceipt.artifactByteCount,
            replayIndexReceipt: indexReceipt,
            publishedAt: publishedAt
        )
        let data = try Self.encode(proof)
        let destination = proofURL(chunkID: identity.source.chunkID)
        try createDirectoryDurably(directoryURL)
        if fileManager.fileExists(atPath: destination.path) {
            guard try Data(contentsOf: destination) == data else { throw ProofError.conflict }
            return proof
        }
        let temporary = directoryURL.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp"
        )
        try data.write(to: temporary)
        let handle = try FileHandle(forWritingTo: temporary)
        try handle.synchronize()
        try handle.close()
        try checkpoint(.proofTemporaryDurable)
        guard rename(temporary.path, destination.path) == 0 else {
            try? fileManager.removeItem(at: temporary)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try Self.synchronizeDirectory(directoryURL)
        try checkpoint(.proofPublished)
        return proof
    }

    func verifiedProof(
        identity: AtriaHistoricalCanonicalConsumerApplicationStore.VerificationIdentity,
        replayIndex: AtriaHistoricalRetiredReplayIndex
    ) throws -> Proof {
        let url = proofURL(chunkID: identity.source.chunkID)
        guard fileManager.fileExists(atPath: url.path),
              UInt64((try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? -1) <= 128 * 1_024 else {
            throw ProofError.corrupt
        }
        let data = try Data(contentsOf: url)
        let proof: Proof
        do { proof = try Self.decoder().decode(Proof.self, from: data) }
        catch { throw ProofError.corrupt }
        guard try Self.encode(proof) == data,
              proof.schema == Proof.currentSchema,
              proof.source == identity.source,
              proof.verificationIdentitySHA256 == Self.sha256(try Self.encode(identity)),
              proof.replayReceiptSHA256 == Self.sha256(try Self.encode(identity.replayReceipt)),
              proof.replayArtifactSHA256 == identity.replayReceipt.artifactSHA256,
              proof.replayArtifactByteCount == identity.replayReceipt.artifactByteCount,
              proof.replayIndexReceipt.sourceChunkID == identity.source.chunkID,
              proof.replayIndexReceipt.sourceRawSHA256 == identity.source.rawSHA256 else {
            throw ProofError.corrupt
        }
        let hasLiveIndexAuthority = try replayIndex.verifiesRetiredSource(
            proof.replayIndexReceipt
        )
        guard hasLiveIndexAuthority
                || proof.publishedAt <= Date().addingTimeInterval(-90 * 86_400) else {
            throw ProofError.indexAuthorityMissing
        }
        return proof
    }

    private func proofURL(chunkID: String) -> URL {
        directoryURL.appendingPathComponent(
            "replay-compaction-\(Self.sha256(Data(chunkID.utf8))).json"
        )
    }

    private func createDirectoryDurably(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw ProofError.conflict }
            return
        }
        let parent = url.deletingLastPathComponent()
        if parent.path != url.path { try createDirectoryDurably(parent) }
        try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
        // mkdir durability belongs to the parent directory entry. Fsync both
        // sides before any proof can authorize payload deletion.
        try Self.synchronizeDirectory(url)
        try Self.synchronizeDirectory(parent)
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
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

    private static func synchronizeDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw POSIXError(.EIO) }
    }
}

struct AtriaHistoricalReplayPayloadCompactor {
    enum Checkpoint: Equatable, Sendable {
        case proofVerified
        case canonicalReplayRetired
        case stagingReplayRetired
    }

    struct Result: Equatable, Sendable {
        let chunkID: String
        let retiredBytes: UInt64
        let proof: AtriaHistoricalReplayPayloadCompactionStore.Proof
    }

    let archiveRoot: URL
    var checkpoint: (Checkpoint) throws -> Void = { _ in }
    var proofCheckpoint: (AtriaHistoricalReplayPayloadCompactionStore.Checkpoint) throws -> Void = { _ in }

    func compactRetiredSource(chunkID: String, now: Date = Date()) throws -> Result {
        let replayIndex = try AtriaHistoricalRetiredReplayIndex(
            databaseURL: archiveRoot.appendingPathComponent(
                "retired-replay-v1/exact-identities-v3.sqlite"
            )
        )
        let canonicalRoot = archiveRoot.appendingPathComponent(
            "canonical-consumers-v1", isDirectory: true
        )
        let destination = AtriaHistoricalCanonicalConsumerDestinationStore(
            directoryURL: canonicalRoot.appendingPathComponent("destinations", isDirectory: true)
        )
        let proofDirectory = canonicalRoot.appendingPathComponent(
            "application-proofs", isDirectory: true
        )
        let structural = AtriaHistoricalCanonicalConsumerApplicationStore(
            directoryURL: proofDirectory
        )
        guard let applied = try structural.loadCurrent(sourceChunkID: chunkID) else {
            throw AtriaHistoricalReplayPayloadCompactionStore.ProofError.invalidIdentity
        }
        let identity = applied.verificationIdentity
        let proofStore = AtriaHistoricalReplayPayloadCompactionStore(
            directoryURL: archiveRoot.appendingPathComponent(
                "replay-compaction-v1", isDirectory: true
            ),
            checkpoint: proofCheckpoint
        )
        let existingProof = try? proofStore.verifiedProof(identity: identity,
                                                          replayIndex: replayIndex)
        if existingProof == nil {
            // Full six-projection readback is mandatory before the replacement
            // proof becomes visible.
            let adapter = AtriaHistoricalCanonicalConsumerApplicationAdapter(
                destinationStore: destination,
                proofDirectoryURL: proofDirectory
            )
            _ = try adapter.validatedCurrent(identity: identity)
        }
        let proof: AtriaHistoricalReplayPayloadCompactionStore.Proof
        if let existingProof {
            proof = existingProof
        } else {
            guard let indexReceipt = try replayIndex.retiredSourceReceipt(chunkID: chunkID) else {
                throw AtriaHistoricalReplayPayloadCompactionStore.ProofError.indexAuthorityMissing
            }
            proof = try proofStore.publish(identity: identity,
                                           indexReceipt: indexReceipt,
                                           replayIndex: replayIndex,
                                           publishedAt: now)
        }
        _ = try proofStore.verifiedProof(identity: identity, replayIndex: replayIndex)
        try checkpoint(.proofVerified)
        guard let replayApplication = applied.applications.first(where: {
            $0.consumer == .replayIdentity
        }) else {
            throw AtriaHistoricalReplayPayloadCompactionStore.ProofError.invalidIdentity
        }
        var retired: UInt64 = 0
        retired += try destination.retireReplayPayload(application: replayApplication,
                                                       identity: identity)
        try checkpoint(.canonicalReplayRetired)
        retired += try AtriaHistoricalConsumerReceiptLedger(
            directoryURL: archiveRoot.appendingPathComponent(
                "consumer-receipts-v1", isDirectory: true
            )
        ).retireReplayStagingPayload(receipt: identity.replayReceipt)
        try checkpoint(.stagingReplayRetired)
        return .init(chunkID: chunkID, retiredBytes: retired, proof: proof)
    }
}
