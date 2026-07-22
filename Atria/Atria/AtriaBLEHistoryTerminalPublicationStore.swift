import Darwin
import Foundation

/// Durable bridge between an exact BLE request authority and the immutable raw
/// chunk sealed by its terminal callback. It exists so a crash after publishing
/// a completion (or a prefix of consumer receipts) can resume from that exact
/// completion even when the retry terminal contains no new raw rows.
final class AtriaBLEHistoryTerminalPublicationStore: @unchecked Sendable {
    /// CoreBluetooth's write callback is the first point at which the verified
    /// WHOOP 4 full-drain command can be treated as transmitted. This receipt
    /// deliberately describes a full drain only; it is not exact-range proof.
    struct TransportWriteEvidence: Codable, Equatable, Sendable {
        let transportGeneration: UInt64
        let commandSequence: UInt8
        let command: UInt8
        let payload: [UInt8]
        let writeCompletedAtUnix: TimeInterval

        var writeCompletedAt: Date {
            Date(timeIntervalSince1970: writeCompletedAtUnix)
        }
    }

    struct RawSealEvidence: Codable, Equatable, Sendable {
        let drainGeneration: UInt64
        let contentSHA256: String
        let byteCount: UInt64
        let rowCount: Int
        let firstTimestampUnix: TimeInterval
        let lastTimestampUnix: TimeInterval
    }

    struct CompletionEvidence: Codable, Equatable, Sendable {
        let generation: UInt64
        let catalogGeneration: UInt64
        let catalogSnapshotSHA256: String
        let aggregateSnapshotSHA256: String
    }

    struct ProjectionEvidence: Codable, Equatable, Sendable {
        let completionGeneration: UInt64
        let inspectedSourceCount: Int
        let receiptCount: Int
        let artifactSHA256s: [String]
    }

    struct Job: Codable, Equatable, Sendable {
        enum Status: String, Codable, Equatable, Sendable {
            /// Immutable terminal identity is durable, but the catalog seal
            /// has not yet been re-read and verified.
            case prepared
            /// Generation-specific raw bytes and their catalog seal were
            /// verified after the terminal durability fence.
            case rawSealed
            /// The exact-range completion generation and aggregate snapshot
            /// are durably published and re-readable.
            case completionPublished
            /// Every required consumer artifact/receipt set is durably active.
            case projectionsPublished
            /// The matching request authority was durably consumed. This is
            /// terminal; no later stage is permitted.
            case authorityConsumed
        }

        static let currentVersion = 1

        let version: Int
        let authorityGeneration: UInt64
        let requestIdentifier: String
        let peripheralIdentifier: String
        let strapIdentity: String
        let exactRequest: AtriaBLEHistoryRequestAuthorityStore.ExactRequest
        let originalAttempt: UInt64
        let originalTransportNonce: String
        let originalTransportGeneration: UInt64
        let chunkID: String
        let terminalBatchNumber: UInt64
        let durableSequence: UInt64
        let completedAtUnix: TimeInterval
        let transportWrite: TransportWriteEvidence
        var rawSeal: RawSealEvidence?
        var completion: CompletionEvidence?
        var projections: ProjectionEvidence?
        var status: Status

        var completedAt: Date { Date(timeIntervalSince1970: completedAtUnix) }
    }

    enum StoreError: Error, Equatable {
        case stateCorrupt
        case invalidJob
        case conflictingJob
        case staleAuthority
        case jobMissing
        case jobCompleted
    }

    private let directoryURL: URL
    private let stateURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    init(directoryURL: URL, fileManager: FileManager = .default) {
        self.directoryURL = directoryURL.standardizedFileURL
        self.stateURL = directoryURL.appendingPathComponent(
            "ble-history-terminal-publication-v1.json"
        )
        self.fileManager = fileManager
    }

    /// Must be called immediately after a terminal raw chunk is sealed and
    /// before aggregate/completion/receipt publication begins.
    func prepareStaged(
        binding: AtriaBLEHistoryRequestAuthorityStore.Binding,
        chunkID: String,
        terminalBatchNumber: UInt64,
        durableSequence: UInt64,
        completedAt: Date,
        transportWrite: TransportWriteEvidence
    ) throws -> Job {
        let candidate = Job(
            version: Job.currentVersion,
            authorityGeneration: binding.authorityGeneration,
            requestIdentifier: binding.requestIdentifier,
            peripheralIdentifier: binding.peripheralIdentifier,
            strapIdentity: binding.strapIdentity,
            exactRequest: binding.exactRequest,
            originalAttempt: binding.attempt,
            originalTransportNonce: binding.transportNonce,
            originalTransportGeneration: binding.transportGeneration,
            chunkID: chunkID,
            terminalBatchNumber: terminalBatchNumber,
            durableSequence: durableSequence,
            completedAtUnix: completedAt.timeIntervalSince1970,
            transportWrite: transportWrite,
            rawSeal: nil,
            completion: nil,
            projections: nil,
            status: .prepared
        )
        try Self.validate(candidate)
        lock.lock()
        defer { lock.unlock() }
        if let existing = try loadLocked(),
           Self.sameAuthority(existing, binding) {
            guard existing == candidate else { throw StoreError.conflictingJob }
            return existing
        }
        // A newer authority has already invalidated a different job. Replacing
        // that stale metadata cannot delete or retire its raw source.
        try persistLocked(candidate)
        return try loadLocked() ?? candidate
    }

    /// A reconnect creates a new transport attempt, so matching deliberately
    /// ignores attempt/nonce while retaining them in the job for audit. The
    /// durable authority generation + request UUID + strap/peripheral + exact
    /// interval remain invariant and are all required.
    func loadPending(
        matching binding: AtriaBLEHistoryRequestAuthorityStore.Binding
    ) throws -> Job? {
        lock.lock()
        defer { lock.unlock() }
        guard let job = try loadLocked() else { return nil }
        guard Self.sameAuthority(job, binding) else { return nil }
        guard job.status != .authorityConsumed else { throw StoreError.jobCompleted }
        return job
    }

    func markRawSealed(_ job: Job, evidence: RawSealEvidence) throws -> Job {
        try mutate(job, allowed: [.prepared, .rawSealed]) { current in
            if let existing = current.rawSeal, existing != evidence {
                throw StoreError.conflictingJob
            }
            current.rawSeal = evidence
            current.status = .rawSealed
        }
    }

    func markCompletionPublished(_ job: Job,
                                 evidence: CompletionEvidence) throws -> Job {
        try mutate(job, allowed: [.rawSealed, .completionPublished]) { current in
            guard current.rawSeal != nil else { throw StoreError.conflictingJob }
            if let existing = current.completion, existing != evidence {
                throw StoreError.conflictingJob
            }
            current.completion = evidence
            current.status = .completionPublished
        }
    }

    func markProjectionsPublished(_ job: Job,
                                  evidence: ProjectionEvidence) throws -> Job {
        try mutate(job, allowed: [.completionPublished, .projectionsPublished]) { current in
            guard let completion = current.completion,
                  completion.generation == evidence.completionGeneration,
                  evidence.inspectedSourceCount > 0,
                  evidence.receiptCount > 0,
                  evidence.artifactSHA256s.count == evidence.receiptCount,
                  evidence.artifactSHA256s.allSatisfy({ !$0.isEmpty }) else {
                throw StoreError.conflictingJob
            }
            if let existing = current.projections, existing != evidence {
                throw StoreError.conflictingJob
            }
            current.projections = evidence
            current.status = .projectionsPublished
        }
    }

    func markAuthorityConsumed(
        _ job: Job,
        matching binding: AtriaBLEHistoryRequestAuthorityStore.Binding
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard var current = try loadLocked() else { throw StoreError.jobMissing }
        guard Self.sameJob(current, job), Self.sameAuthority(current, binding) else {
            throw StoreError.staleAuthority
        }
        guard current.status == .projectionsPublished
                || current.status == .authorityConsumed else {
            throw StoreError.conflictingJob
        }
        current.status = .authorityConsumed
        try persistLocked(current)
    }

    /// Final reconciliation after the authority store already durably consumed
    /// this exact request. No current transport binding is required.
    func markAuthorityConsumedAfterReconciliation(_ job: Job) throws {
        lock.lock()
        defer { lock.unlock() }
        guard var current = try loadLocked() else { throw StoreError.jobMissing }
        guard Self.sameJob(current, job),
              current.status == .projectionsPublished
                || current.status == .authorityConsumed else {
            throw StoreError.conflictingJob
        }
        current.status = .authorityConsumed
        try persistLocked(current)
    }

    func load() throws -> Job? {
        lock.lock()
        defer { lock.unlock() }
        return try loadLocked()
    }

    private func loadLocked() throws -> Job? {
        guard fileManager.fileExists(atPath: stateURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: stateURL)
            let job = try JSONDecoder().decode(Job.self, from: data)
            guard try Self.canonicalData(job) == data else { throw StoreError.stateCorrupt }
            try Self.validate(job)
            return job
        } catch let error as StoreError {
            throw error
        } catch {
            throw StoreError.stateCorrupt
        }
    }

    private func persistLocked(_ job: Job) throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let data = try Self.canonicalData(job)
        let temporary = directoryURL.appendingPathComponent(
            ".\(stateURL.lastPathComponent).\(UUID().uuidString).tmp"
        )
        try data.write(to: temporary)
        let handle = try FileHandle(forWritingTo: temporary)
        try handle.synchronize()
        try handle.close()
        if fileManager.fileExists(atPath: stateURL.path) {
            _ = try fileManager.replaceItemAt(stateURL, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: stateURL)
        }
        try Self.synchronizeDirectory(directoryURL)
    }

    private func mutate(_ job: Job,
                        allowed: Set<Job.Status>,
                        mutation: (inout Job) throws -> Void) throws -> Job {
        lock.lock()
        defer { lock.unlock() }
        guard var current = try loadLocked() else { throw StoreError.jobMissing }
        guard Self.sameJob(current, job), allowed.contains(current.status) else {
            throw StoreError.conflictingJob
        }
        try mutation(&current)
        try Self.validate(current)
        try persistLocked(current)
        return current
    }

    private static func validate(_ job: Job) throws {
        guard job.version == Job.currentVersion,
              job.authorityGeneration > 0,
              !job.requestIdentifier.isEmpty,
              !job.peripheralIdentifier.isEmpty,
              !job.strapIdentity.isEmpty,
              !job.exactRequest.sourceIdentifier.isEmpty,
              job.exactRequest.requestedStartUnix.isFinite,
              job.exactRequest.requestedEndUnix > job.exactRequest.requestedStartUnix,
              job.originalAttempt > 0,
              !job.originalTransportNonce.isEmpty,
              job.originalTransportGeneration > 0,
              !job.chunkID.isEmpty,
              job.durableSequence > 0,
              job.completedAtUnix.isFinite,
              job.completedAtUnix >= job.exactRequest.requestedEndUnix,
              job.transportWrite.transportGeneration
                == job.originalTransportGeneration,
              job.transportWrite.command == 0x16,
              job.transportWrite.payload == [0x00],
              job.transportWrite.writeCompletedAtUnix.isFinite,
              job.transportWrite.writeCompletedAtUnix <= job.completedAtUnix else {
            throw StoreError.invalidJob
        }
        switch job.status {
        case .prepared:
            guard job.rawSeal == nil,
                  job.completion == nil,
                  job.projections == nil else { throw StoreError.invalidJob }
        case .rawSealed:
            guard let raw = job.rawSeal,
                  raw.drainGeneration == job.originalTransportGeneration,
                  raw.contentSHA256.count == 64,
                  raw.byteCount > 0,
                  raw.rowCount > 0,
                  raw.firstTimestampUnix.isFinite,
                  raw.lastTimestampUnix >= raw.firstTimestampUnix,
                  job.completion == nil,
                  job.projections == nil else { throw StoreError.invalidJob }
        case .completionPublished:
            guard job.rawSeal != nil,
                  let completion = job.completion,
                  completion.generation > 0,
                  completion.catalogGeneration > 0,
                  completion.catalogSnapshotSHA256.count == 64,
                  completion.aggregateSnapshotSHA256.count == 64,
                  job.projections == nil else { throw StoreError.invalidJob }
        case .projectionsPublished, .authorityConsumed:
            guard job.rawSeal != nil,
                  let completion = job.completion,
                  let projections = job.projections,
                  projections.completionGeneration == completion.generation,
                  projections.inspectedSourceCount > 0,
                  projections.receiptCount > 0,
                  projections.artifactSHA256s.count == projections.receiptCount,
                  projections.artifactSHA256s.allSatisfy({ $0.count == 64 }) else {
                throw StoreError.invalidJob
            }
        }
    }

    private static func sameAuthority(
        _ job: Job,
        _ binding: AtriaBLEHistoryRequestAuthorityStore.Binding
    ) -> Bool {
        job.authorityGeneration == binding.authorityGeneration
            && job.requestIdentifier == binding.requestIdentifier
            && job.peripheralIdentifier == binding.peripheralIdentifier
            && job.strapIdentity == binding.strapIdentity
            && job.exactRequest == binding.exactRequest
    }

    private static func sameJob(_ lhs: Job, _ rhs: Job) -> Bool {
        lhs.version == rhs.version
            && lhs.authorityGeneration == rhs.authorityGeneration
            && lhs.requestIdentifier == rhs.requestIdentifier
            && lhs.peripheralIdentifier == rhs.peripheralIdentifier
            && lhs.strapIdentity == rhs.strapIdentity
            && lhs.exactRequest == rhs.exactRequest
            && lhs.originalAttempt == rhs.originalAttempt
            && lhs.originalTransportNonce == rhs.originalTransportNonce
            && lhs.originalTransportGeneration == rhs.originalTransportGeneration
            && lhs.chunkID == rhs.chunkID
            && lhs.terminalBatchNumber == rhs.terminalBatchNumber
            && lhs.durableSequence == rhs.durableSequence
            && lhs.completedAtUnix == rhs.completedAtUnix
            && lhs.transportWrite == rhs.transportWrite
    }

    private static func canonicalData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func synchronizeDirectory(_ url: URL) throws {
        let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY) }
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw POSIXError(.EIO) }
    }
}
