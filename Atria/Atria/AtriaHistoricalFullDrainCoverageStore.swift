import Darwin
import Foundation

/// Durable, fail-closed authority for proving that a *full* WHOOP 4 history
/// drain covered one already-known missing-data gap.
///
/// This store is intentionally independent of exact-range request authority.
/// It never claims that the full-drain command selected a range. Instead it
/// binds one pending gap to one strap/transport attempt and journals every
/// HISTORY_END durable boundary before allowing its matching ACK. Exact gap
/// resolution requires timestamp coverage plus recovered-data publication;
/// future-dependent typed consumers remain explicitly pending until their own
/// dependency ranges are durably closed.
final class AtriaHistoricalFullDrainCoverageStore: @unchecked Sendable {
    typealias Stores = AtriaHistoricalFullDrainCoveragePolicy.DurableStorePair
    typealias CoverageProof = AtriaHistoricalFullDrainCoveragePolicy.CoverageProof
    typealias Configuration = AtriaHistoricalFullDrainCoveragePolicy.Configuration

    struct PendingGap: Codable, Equatable, Sendable {
        let gapIdentifier: String
        let gapLedgerGeneration: UInt64
        let gapLedgerSnapshotSHA256: String
        let startUnix: TimeInterval
        let endUnix: TimeInterval
        let reason: String
        let pending: Bool
    }

    struct Attempt: Codable, Equatable, Sendable {
        let attemptIdentifier: String
        let attemptNumber: UInt64
        let peripheralIdentifier: String
        let strapIdentity: String
        let transportNonce: String
        let transportGeneration: UInt64
        let fullDrainCommandSHA256: String
        let commandWriteCompletedAtUnix: TimeInterval
        let transportAuthority: AtriaHistoricalFullDrainCoveragePolicy.TransportAuthority
    }

    struct EventIdentity: Equatable, Sendable {
        let gapIdentifier: String
        let attemptIdentifier: String
        let peripheralIdentifier: String
        let strapIdentity: String
        let transportNonce: String
        let transportGeneration: UInt64
    }

    struct ACKPermit: Codable, Equatable, Sendable {
        let authorityIdentifier: String
        let boundaryIdentifier: String
        let expectedACKSHA256: String
        let evidenceSHA256: String
    }

    struct BatchBoundary: Codable, Equatable, Sendable {
        let boundaryIdentifier: String
        let historyEndSHA256: String
        let expectedACKSHA256: String
        let stores: Stores
        let fsyncedAtUnix: TimeInterval
        var ackAttempt: Int?
        var ackCompletedAtUnix: TimeInterval?
    }

    struct HistoryComplete: Codable, Equatable, Sendable {
        let completionIdentifier: String
        let notificationSHA256: String
        let acknowledgedBoundaryCount: Int
        let stores: Stores
        let receivedAtUnix: TimeInterval
        /// Persisted terminal reducer coordinates allow publication preparation
        /// to resume after a crash between HISTORY_COMPLETE and checkpoint fsync.
        let terminalBatchNumber: UInt64?
        let durableSequence: UInt64?
    }

    struct ConsumerReceipt: Codable, Equatable, Sendable {
        let kind: String
        let receiptSHA256: String
        let artifactSHA256: String
        let sourceRawSnapshotSHA256: String
        let sourceIdentitySnapshotSHA256: String
        let sourceAdmissionSnapshotSHA256: String
        let gapIdentifier: String
        let attemptIdentifier: String
        let completionIdentifier: String
        let commitIdentifier: String
        let committedAtUnix: TimeInterval
    }

    struct ConsumerCommit: Codable, Equatable, Sendable {
        let receiptSetSHA256: String
        let receipts: [ConsumerReceipt]
        let committedAtUnix: TimeInterval
    }

    /// Immutable dependency identity for typed consumers that honestly need a
    /// wider interval than the recovered gap itself. Persisting it makes the
    /// later full-scan settlement restartable instead of relying on a log line
    /// or recomputing against a mutated catalog.
    struct PendingConsumerDependency: Codable, Equatable, Sendable {
        let requiredStartUnix: TimeInterval
        let requiredEndUnix: TimeInterval
        let sourceChunkID: String
        let sourceRawSHA256: String

        var isValid: Bool {
            requiredStartUnix.isFinite
                && requiredEndUnix.isFinite
                && requiredEndUnix > requiredStartUnix
                && !sourceChunkID.isEmpty
                && AtriaHistoricalFullDrainCoverageStore.isSHA256(sourceRawSHA256)
        }
    }

    struct TerminalGapReconciliation: Codable, Equatable, Sendable {
        enum Status: String, Codable, Equatable, Sendable {
            case rejected
            case coverageProven
            case resolutionPrepared
            case resolved
            case preserved
        }

        let gap: PendingGap
        let coverageProof: CoverageProof?
        let rejectionReason: String?
        var resolutionPreparedAtUnix: TimeInterval?
        var resolvedAtUnix: TimeInterval?
        var status: Status
    }

    struct PublicationCheckpoint: Codable, Equatable, Sendable {
        enum Status: String, Codable, Equatable, Sendable {
            case prepared
            case rawSealed
            case completionPublished
            case projectionsPublished
        }
        let chunkID: String
        let terminalBatchNumber: UInt64
        let durableSequence: UInt64
        let completedAtUnix: TimeInterval
        var rawSeal: AtriaBLEHistoryTerminalPublicationStore.RawSealEvidence?
        var completion: AtriaBLEHistoryTerminalPublicationStore.CompletionEvidence?
        var projections: AtriaBLEHistoryTerminalPublicationStore.ProjectionEvidence?
        var status: Status
    }

    struct Authority: Codable, Equatable, Sendable {
        enum Status: String, Codable, Equatable, Sendable {
            case draining
            case historyComplete
            case coverageProven
            /// The exact missing-data window was durably removed after raw
            /// recovered-data publication, while one or more typed consumers
            /// still require honest future lookahead/civil-day evidence.
            case gapResolvedConsumersPending
            case consumersCommitted
            case resolved
        }

        static let currentVersion = 1

        let version: Int
        let authorityIdentifier: String
        let createdAtUnix: TimeInterval
        let gap: PendingGap
        let attempt: Attempt
        let configuration: Configuration
        var boundaries: [BatchBoundary]
        var historyComplete: HistoryComplete?
        var coverageProof: CoverageProof?
        var publication: PublicationCheckpoint?
        var consumerCommit: ConsumerCommit?
        var pendingConsumerDependency: PendingConsumerDependency?
        /// Every other closed gap observed when this terminal drain was sealed.
        /// Entries are immutable with respect to identity/coverage and advance
        /// independently through their exact ledger CAS.
        var terminalGapReconciliations: [TerminalGapReconciliation]?
        /// Fsynced authorization for removing this authority's immutable exact
        /// gap from the separate UserDefaults ledger. This must exist before
        /// the ledger CAS, so an absent row is unambiguous after a crash.
        var gapResolutionPreparedAtUnix: TimeInterval?
        var resolvedAtUnix: TimeInterval?
        var status: Status
    }

    enum StoreError: Error, Equatable {
        case invalidConfiguration
        case invalidGap
        case invalidAttempt
        case stateCorrupt
        case conflictingAuthority
        case authorityMissing
        case staleEventIdentity
        case terminalState
        case boundaryAlreadyPending
        case boundaryConflict
        case boundaryMissing
        case staleACKPermit
        case ackPayloadMismatch
        case ackBeforeDurableFlush
        case unacknowledgedBoundary
        case storeSealMismatch
        case historyCompleteConflict
        case coverageRejected
        case consumerReceiptsIncomplete
        case consumerReceiptConflict
        case notReadyToResolve
        case invalidEventTime
    }

    private struct Envelope: Codable, Equatable {
        static let currentVersion = 1
        let version: Int
        var authority: Authority?
    }

    private let directoryURL: URL
    private let stateURL: URL
    private let fileManager: FileManager
    private let makeIdentifier: () -> String
    private let lock = NSLock()

    init(
        directoryURL: URL,
        fileManager: FileManager = .default,
        makeIdentifier: @escaping () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.directoryURL = directoryURL.standardizedFileURL
        self.stateURL = directoryURL.appendingPathComponent(
            "historical-full-drain-coverage-authority-v1.json"
        )
        self.fileManager = fileManager
        self.makeIdentifier = makeIdentifier
    }

    /// Arms exactly one closed, pending gap and one already-written full-drain
    /// transport attempt. No BLE operation is initiated by this method.
    func arm(
        gap: PendingGap,
        attempt: Attempt,
        configuration: Configuration = .production,
        now: Date
    ) throws -> Authority {
        try Self.validate(gap)
        try Self.validate(attempt, gap: gap)
        guard configuration.isValid else { throw StoreError.invalidConfiguration }
        guard now.timeIntervalSince1970.isFinite,
              now.timeIntervalSince1970 >= attempt.commandWriteCompletedAtUnix else {
            throw StoreError.invalidEventTime
        }
        lock.lock()
        defer { lock.unlock() }
        var envelope = try loadLocked()
        if let existing = envelope.authority {
            if existing.gap == gap,
               existing.attempt == attempt,
               existing.configuration == configuration {
                return existing
            }
            let retryingSamePendingGap = existing.status == .draining
                && existing.gap.gapIdentifier == gap.gapIdentifier
                && existing.gap.startUnix == gap.startUnix
                && existing.gap.endUnix == gap.endUnix
                && existing.attempt.transportNonce != attempt.transportNonce
                && existing.attempt.commandWriteCompletedAtUnix
                    < attempt.commandWriteCompletedAtUnix
            guard existing.status == .resolved || retryingSamePendingGap else {
                throw StoreError.conflictingAuthority
            }
        }
        let identifier = makeIdentifier()
        guard !identifier.isEmpty else { throw StoreError.invalidAttempt }
        let authority = Authority(
            version: Authority.currentVersion,
            authorityIdentifier: identifier,
            createdAtUnix: now.timeIntervalSince1970,
            gap: gap,
            attempt: attempt,
            configuration: configuration,
            boundaries: [],
            historyComplete: nil,
            coverageProof: nil,
            publication: nil,
            consumerCommit: nil,
            pendingConsumerDependency: nil,
            terminalGapReconciliations: nil,
            gapResolutionPreparedAtUnix: nil,
            resolvedAtUnix: nil,
            status: .draining
        )
        envelope.authority = authority
        try persistLocked(envelope)
        return try requireAuthority(try loadLocked())
    }

    /// Persists and fsyncs the raw+identity store seals for one HISTORY_END.
    /// The returned permit is the future integration seam: an adapter may send
    /// only its exact expected ACK after this call succeeds and re-reads state.
    func recordHistoryEndFsynced(
        identity: EventIdentity,
        boundaryIdentifier: String,
        historyEndPayload: Data,
        expectedACKPayload: Data,
        stores: Stores,
        fsyncedAt: Date
    ) throws -> ACKPermit {
        guard !boundaryIdentifier.isEmpty,
              !historyEndPayload.isEmpty,
              !expectedACKPayload.isEmpty,
              stores.isValid,
              fsyncedAt.timeIntervalSince1970.isFinite else {
            throw StoreError.boundaryConflict
        }
        lock.lock()
        defer { lock.unlock() }
        var envelope = try loadLocked()
        var authority = try requireAuthority(envelope)
        try Self.match(identity, authority: authority)
        guard authority.status == .draining else { throw StoreError.terminalState }
        guard stores.raw.fsyncedAtUnix <= fsyncedAt.timeIntervalSince1970,
              stores.identity.fsyncedAtUnix <= fsyncedAt.timeIntervalSince1970,
              stores.admission.fsyncedAtUnix <= fsyncedAt.timeIntervalSince1970,
              fsyncedAt.timeIntervalSince1970
                  >= authority.attempt.commandWriteCompletedAtUnix else {
            throw StoreError.ackBeforeDurableFlush
        }
        if let prior = authority.boundaries.last,
           let ackCompletedAtUnix = prior.ackCompletedAtUnix,
           fsyncedAt.timeIntervalSince1970 < ackCompletedAtUnix {
            throw StoreError.invalidEventTime
        }
        if let prior = authority.boundaries.last {
            guard stores.isAtLeastAsDurable(as: prior.stores) else {
                throw StoreError.storeSealMismatch
            }
        }
        let candidate = BatchBoundary(
            boundaryIdentifier: boundaryIdentifier,
            historyEndSHA256: Self.sha256(historyEndPayload),
            expectedACKSHA256: Self.sha256(expectedACKPayload),
            stores: stores,
            fsyncedAtUnix: fsyncedAt.timeIntervalSince1970,
            ackAttempt: nil,
            ackCompletedAtUnix: nil
        )
        if let existing = authority.boundaries.first(where: {
            $0.boundaryIdentifier == boundaryIdentifier
        }) {
            guard existing == candidate else { throw StoreError.boundaryConflict }
            return try Self.permit(authority: authority, boundary: existing)
        }
        if let pending = authority.boundaries.last, pending.ackCompletedAtUnix == nil {
            throw StoreError.boundaryAlreadyPending
        }
        authority.boundaries.append(candidate)
        envelope.authority = authority
        try persistLocked(envelope)
        let persisted = try requireAuthority(try loadLocked())
        guard let boundary = persisted.boundaries.last, boundary == candidate else {
            throw StoreError.stateCorrupt
        }
        return try Self.permit(authority: persisted, boundary: boundary)
    }

    func recordMatchingACK(
        identity: EventIdentity,
        permit: ACKPermit,
        actualACKPayload: Data,
        ackAttempt: Int,
        completedAt: Date
    ) throws -> Authority {
        guard !actualACKPayload.isEmpty,
              ackAttempt > 0,
              completedAt.timeIntervalSince1970.isFinite else {
            throw StoreError.ackPayloadMismatch
        }
        lock.lock()
        defer { lock.unlock() }
        var envelope = try loadLocked()
        var authority = try requireAuthority(envelope)
        try Self.match(identity, authority: authority)
        guard authority.status == .draining else { throw StoreError.terminalState }
        guard permit.authorityIdentifier == authority.authorityIdentifier,
              let index = authority.boundaries.firstIndex(where: {
                  $0.boundaryIdentifier == permit.boundaryIdentifier
              }) else { throw StoreError.staleACKPermit }
        let current = authority.boundaries[index]
        guard try Self.permit(authority: authority, boundary: current) == permit else {
            throw StoreError.staleACKPermit
        }
        guard Self.sha256(actualACKPayload) == current.expectedACKSHA256,
              current.expectedACKSHA256 == permit.expectedACKSHA256 else {
            throw StoreError.ackPayloadMismatch
        }
        guard completedAt.timeIntervalSince1970 >= current.fsyncedAtUnix,
              current.stores.raw.fsyncedAtUnix <= current.fsyncedAtUnix,
              current.stores.identity.fsyncedAtUnix <= current.fsyncedAtUnix,
              current.stores.admission.fsyncedAtUnix <= current.fsyncedAtUnix else {
            throw StoreError.ackBeforeDurableFlush
        }
        if let priorAttempt = current.ackAttempt,
           let priorTime = current.ackCompletedAtUnix {
            guard priorAttempt == ackAttempt,
                  priorTime == completedAt.timeIntervalSince1970 else {
                throw StoreError.boundaryConflict
            }
            return authority
        }
        authority.boundaries[index].ackAttempt = ackAttempt
        authority.boundaries[index].ackCompletedAtUnix = completedAt.timeIntervalSince1970
        envelope.authority = authority
        try persistLocked(envelope)
        return try requireAuthority(try loadLocked())
    }

    func recordHistoryComplete(
        identity: EventIdentity,
        completionIdentifier: String,
        notificationPayload: Data,
        stores: Stores,
        receivedAt: Date,
        terminalBatchNumber: UInt64? = nil,
        durableSequence: UInt64? = nil
    ) throws -> Authority {
        guard !completionIdentifier.isEmpty,
              !notificationPayload.isEmpty,
              stores.isValid,
              receivedAt.timeIntervalSince1970.isFinite,
              (terminalBatchNumber == nil) == (durableSequence == nil),
              durableSequence.map({ $0 > 0 }) ?? true else {
            throw StoreError.historyCompleteConflict
        }
        lock.lock()
        defer { lock.unlock() }
        var envelope = try loadLocked()
        var authority = try requireAuthority(envelope)
        try Self.match(identity, authority: authority)
        guard authority.status == .draining || authority.status == .historyComplete else {
            throw StoreError.terminalState
        }
        guard authority.boundaries.allSatisfy({ $0.ackCompletedAtUnix != nil }) else {
            throw StoreError.unacknowledgedBoundary
        }
        if let prior = authority.boundaries.last {
            guard stores.isAtLeastAsDurable(as: prior.stores),
                  receivedAt.timeIntervalSince1970 >= (prior.ackCompletedAtUnix ?? .infinity) else {
                throw StoreError.storeSealMismatch
            }
        }
        let completion = HistoryComplete(
            completionIdentifier: completionIdentifier,
            notificationSHA256: Self.sha256(notificationPayload),
            acknowledgedBoundaryCount: authority.boundaries.count,
            stores: stores,
            receivedAtUnix: receivedAt.timeIntervalSince1970,
            terminalBatchNumber: terminalBatchNumber,
            durableSequence: durableSequence
        )
        if let existing = authority.historyComplete {
            guard existing == completion else { throw StoreError.historyCompleteConflict }
            return authority
        }
        authority.historyComplete = completion
        authority.status = .historyComplete
        envelope.authority = authority
        try persistLocked(envelope)
        return try requireAuthority(try loadLocked())
    }

    func recordCoverageProof(
        identity: EventIdentity,
        proof: CoverageProof
    ) throws -> Authority {
        lock.lock()
        defer { lock.unlock() }
        var envelope = try loadLocked()
        var authority = try requireAuthority(envelope)
        try Self.match(identity, authority: authority)
        guard authority.status == .historyComplete || authority.status == .coverageProven else {
            throw StoreError.terminalState
        }
        guard let terminal = authority.historyComplete,
              AtriaHistoricalFullDrainCoveragePolicy.validate(
                  proof,
                  gapIdentifier: authority.gap.gapIdentifier,
                  gapStartUnix: authority.gap.startUnix,
                  gapEndUnix: authority.gap.endUnix,
                  attemptIdentifier: authority.attempt.attemptIdentifier,
                  transportNonce: authority.attempt.transportNonce,
                  transportGeneration: authority.attempt.transportGeneration,
                  stores: terminal.stores,
                  configuration: authority.configuration
              ) else { throw StoreError.coverageRejected }
        if let existing = authority.coverageProof {
            guard existing == proof else { throw StoreError.coverageRejected }
            return authority
        }
        authority.coverageProof = proof
        authority.status = .coverageProven
        envelope.authority = authority
        try persistLocked(envelope)
        return try requireAuthority(try loadLocked())
    }

    func recordTerminalGapReconciliations(
        identity: EventIdentity,
        entries: [TerminalGapReconciliation]
    ) throws -> Authority {
        lock.lock(); defer { lock.unlock() }
        var envelope = try loadLocked()
        var authority = try requireAuthority(envelope)
        try Self.match(identity, authority: authority)
        guard authority.status == .historyComplete || authority.status == .coverageProven,
              authority.historyComplete != nil else { throw StoreError.terminalState }
        let sorted = entries.sorted { $0.gap.startUnix < $1.gap.startUnix }
        try Self.validateTerminalGapReconciliations(sorted, authority: authority)
        if let existing = authority.terminalGapReconciliations {
            guard existing == sorted else { throw StoreError.coverageRejected }
            return authority
        }
        authority.terminalGapReconciliations = sorted
        envelope.authority = authority
        try persistLocked(envelope)
        return try requireAuthority(try loadLocked())
    }

    func prepareTerminalGapResolution(
        identity: EventIdentity,
        gapIdentifier: String,
        at preparedAt: Date
    ) throws -> Authority {
        guard preparedAt.timeIntervalSince1970.isFinite else {
            throw StoreError.invalidEventTime
        }
        lock.lock(); defer { lock.unlock() }
        var envelope = try loadLocked()
        var authority = try requireAuthority(envelope)
        try Self.match(identity, authority: authority)
        guard authority.publication?.status == .projectionsPublished,
              var entries = authority.terminalGapReconciliations,
              let index = entries.firstIndex(where: {
                  $0.gap.gapIdentifier == gapIdentifier
              }) else { throw StoreError.notReadyToResolve }
        if entries[index].status == .resolutionPrepared
            || entries[index].status == .resolved
            || entries[index].status == .preserved {
            return authority
        }
        guard entries[index].status == .coverageProven,
              entries[index].coverageProof != nil else {
            throw StoreError.notReadyToResolve
        }
        entries[index].resolutionPreparedAtUnix = preparedAt.timeIntervalSince1970
        entries[index].status = .resolutionPrepared
        authority.terminalGapReconciliations = entries
        envelope.authority = authority
        try persistLocked(envelope)
        return try requireAuthority(try loadLocked())
    }

    func finishTerminalGapResolution(
        identity: EventIdentity,
        gapIdentifier: String,
        resolved: Bool,
        at completedAt: Date
    ) throws -> Authority {
        guard completedAt.timeIntervalSince1970.isFinite else {
            throw StoreError.invalidEventTime
        }
        lock.lock(); defer { lock.unlock() }
        var envelope = try loadLocked()
        var authority = try requireAuthority(envelope)
        try Self.match(identity, authority: authority)
        guard var entries = authority.terminalGapReconciliations,
              let index = entries.firstIndex(where: {
                  $0.gap.gapIdentifier == gapIdentifier
              }) else { throw StoreError.notReadyToResolve }
        if entries[index].status == .resolved || entries[index].status == .preserved {
            return authority
        }
        guard entries[index].status == .resolutionPrepared,
              entries[index].resolutionPreparedAtUnix != nil else {
            throw StoreError.notReadyToResolve
        }
        entries[index].resolvedAtUnix = completedAt.timeIntervalSince1970
        entries[index].status = resolved ? .resolved : .preserved
        authority.terminalGapReconciliations = entries
        envelope.authority = authority
        try persistLocked(envelope)
        return try requireAuthority(try loadLocked())
    }

    func recordCommittedConsumers(
        identity: EventIdentity,
        receipts: [ConsumerReceipt],
        committedAt: Date
    ) throws -> Authority {
        guard committedAt.timeIntervalSince1970.isFinite else {
            throw StoreError.consumerReceiptConflict
        }
        lock.lock()
        defer { lock.unlock() }
        var envelope = try loadLocked()
        var authority = try requireAuthority(envelope)
        try Self.match(identity, authority: authority)
        guard authority.status == .coverageProven
                || authority.status == .gapResolvedConsumersPending
                || authority.status == .consumersCommitted else {
            throw StoreError.terminalState
        }
        guard authority.publication?.status == .projectionsPublished else {
            throw StoreError.consumerReceiptsIncomplete
        }
        guard let terminal = authority.historyComplete else {
            throw StoreError.historyCompleteConflict
        }
        let sorted = receipts.sorted { $0.kind < $1.kind }
        let expectedKinds = Set(authority.configuration.requiredConsumerKinds)
        guard sorted.count == expectedKinds.count,
              Set(sorted.map(\.kind)) == expectedKinds,
              Set(sorted.map(\.commitIdentifier)).count == sorted.count,
              sorted.allSatisfy({ receipt in
                  !receipt.commitIdentifier.isEmpty
                      && Self.isSHA256(receipt.receiptSHA256)
                      && Self.isSHA256(receipt.artifactSHA256)
                      && receipt.sourceRawSnapshotSHA256
                          == terminal.stores.raw.snapshotSHA256
                      && receipt.sourceIdentitySnapshotSHA256
                          == terminal.stores.identity.snapshotSHA256
                      && receipt.sourceAdmissionSnapshotSHA256
                          == terminal.stores.admission.snapshotSHA256
                      && receipt.gapIdentifier == authority.gap.gapIdentifier
                      && receipt.attemptIdentifier == authority.attempt.attemptIdentifier
                      && receipt.completionIdentifier == terminal.completionIdentifier
                      && receipt.committedAtUnix.isFinite
                      && receipt.committedAtUnix >= terminal.receivedAtUnix
                      && committedAt.timeIntervalSince1970 >= receipt.committedAtUnix
              }) else { throw StoreError.consumerReceiptsIncomplete }
        let data = try Self.canonicalData(sorted)
        let commit = ConsumerCommit(
            receiptSetSHA256: Self.sha256(data),
            receipts: sorted,
            committedAtUnix: committedAt.timeIntervalSince1970
        )
        if let existing = authority.consumerCommit {
            guard existing == commit else { throw StoreError.consumerReceiptConflict }
            return authority
        }
        authority.consumerCommit = commit
        authority.status = authority.resolvedAtUnix == nil ? .consumersCommitted : .resolved
        envelope.authority = authority
        try persistLocked(envelope)
        return try requireAuthority(try loadLocked())
    }

    @discardableResult
    func recordPendingConsumerDependency(
        identity: EventIdentity,
        dependency: PendingConsumerDependency
    ) throws -> Authority {
        guard dependency.isValid else { throw StoreError.consumerReceiptConflict }
        lock.lock()
        defer { lock.unlock() }
        var envelope = try loadLocked()
        var authority = try requireAuthority(envelope)
        try Self.match(identity, authority: authority)
        guard authority.status == .coverageProven
                || authority.status == .gapResolvedConsumersPending else {
            throw StoreError.terminalState
        }
        if let existing = authority.pendingConsumerDependency {
            guard existing == dependency else {
                throw StoreError.consumerReceiptConflict
            }
            return authority
        }
        authority.pendingConsumerDependency = dependency
        envelope.authority = authority
        try persistLocked(envelope)
        return try requireAuthority(try loadLocked())
    }

    func preparePublication(
        identity: EventIdentity,
        chunkID: String,
        terminalBatchNumber: UInt64,
        durableSequence: UInt64,
        completedAt: Date
    ) throws -> Authority {
        guard !chunkID.isEmpty, durableSequence > 0,
              completedAt.timeIntervalSince1970.isFinite else {
            throw StoreError.consumerReceiptConflict
        }
        lock.lock(); defer { lock.unlock() }
        var envelope = try loadLocked()
        var authority = try requireAuthority(envelope)
        try Self.match(identity, authority: authority)
        guard authority.status == .historyComplete
                || authority.status == .coverageProven else {
            throw StoreError.terminalState
        }
        let checkpoint = PublicationCheckpoint(
            chunkID: chunkID,
            terminalBatchNumber: terminalBatchNumber,
            durableSequence: durableSequence,
            completedAtUnix: completedAt.timeIntervalSince1970,
            rawSeal: nil,
            completion: nil,
            projections: nil,
            status: .prepared
        )
        if let existing = authority.publication {
            guard existing.chunkID == chunkID,
                  existing.terminalBatchNumber == terminalBatchNumber,
                  existing.durableSequence == durableSequence,
                  existing.completedAtUnix == completedAt.timeIntervalSince1970 else {
                throw StoreError.consumerReceiptConflict
            }
            return authority
        }
        if let terminal = authority.historyComplete {
            guard terminal.terminalBatchNumber.map({ $0 == terminalBatchNumber }) ?? true,
                  terminal.durableSequence.map({ $0 == durableSequence }) ?? true else {
                throw StoreError.consumerReceiptConflict
            }
        }
        authority.publication = checkpoint
        envelope.authority = authority
        try persistLocked(envelope)
        return try requireAuthority(try loadLocked())
    }

    func recordRawSeal(
        identity: EventIdentity,
        evidence: AtriaBLEHistoryTerminalPublicationStore.RawSealEvidence
    ) throws -> Authority {
        try mutatePublication(identity: identity,
                              allowed: [.prepared, .rawSealed]) { publication in
            if let existing = publication.rawSeal, existing != evidence {
                throw StoreError.consumerReceiptConflict
            }
            publication.rawSeal = evidence
            publication.status = .rawSealed
        }
    }

    func recordCompletionPublished(
        identity: EventIdentity,
        evidence: AtriaBLEHistoryTerminalPublicationStore.CompletionEvidence
    ) throws -> Authority {
        try mutatePublication(identity: identity,
                              allowed: [.rawSealed, .completionPublished]) { publication in
            guard publication.rawSeal != nil else { throw StoreError.consumerReceiptConflict }
            if let existing = publication.completion, existing != evidence {
                throw StoreError.consumerReceiptConflict
            }
            publication.completion = evidence
            publication.status = .completionPublished
        }
    }

    func recordProjectionsPublished(
        identity: EventIdentity,
        evidence: AtriaBLEHistoryTerminalPublicationStore.ProjectionEvidence
    ) throws -> Authority {
        try mutatePublication(identity: identity,
                              allowed: [.completionPublished, .projectionsPublished]) { publication in
            guard publication.completion != nil,
                  evidence.receiptCount == publication.projections?.receiptCount
                    || publication.projections == nil else {
                throw StoreError.consumerReceiptConflict
            }
            publication.projections = evidence
            publication.status = .projectionsPublished
        }
    }

    private func mutatePublication(
        identity: EventIdentity,
        allowed: Set<PublicationCheckpoint.Status>,
        mutation: (inout PublicationCheckpoint) throws -> Void
    ) throws -> Authority {
        lock.lock(); defer { lock.unlock() }
        var envelope = try loadLocked()
        var authority = try requireAuthority(envelope)
        try Self.match(identity, authority: authority)
        guard (authority.status == .historyComplete
                || authority.status == .coverageProven
                || authority.status == .gapResolvedConsumersPending),
              var publication = authority.publication,
              allowed.contains(publication.status) else { throw StoreError.terminalState }
        try mutation(&publication)
        authority.publication = publication
        envelope.authority = authority
        try persistLocked(envelope)
        return try requireAuthority(try loadLocked())
    }

    /// Durably records the exact authority's intent to remove its bound gap.
    /// Repeated calls preserve the original timestamp, making crash replay
    /// idempotent while the gap ledger and authority store settle separately.
    func prepareGapResolution(
        identity: EventIdentity,
        at preparedAt: Date
    ) throws -> Authority {
        guard preparedAt.timeIntervalSince1970.isFinite else {
            throw StoreError.invalidEventTime
        }
        lock.lock()
        defer { lock.unlock() }
        var envelope = try loadLocked()
        var authority = try requireAuthority(envelope)
        try Self.match(identity, authority: authority)
        if authority.status == .resolved
            || authority.status == .gapResolvedConsumersPending
            || authority.gapResolutionPreparedAtUnix != nil {
            return authority
        }
        guard authority.status == .coverageProven
                || authority.status == .consumersCommitted,
              authority.historyComplete != nil,
              authority.coverageProof != nil,
              authority.resolvedAtUnix == nil else {
            throw StoreError.notReadyToResolve
        }
        authority.gapResolutionPreparedAtUnix = preparedAt.timeIntervalSince1970
        envelope.authority = authority
        try persistLocked(envelope)
        return try requireAuthority(try loadLocked())
    }

    @discardableResult
    func resolve(identity: EventIdentity, at resolvedAt: Date) throws -> Authority {
        guard resolvedAt.timeIntervalSince1970.isFinite else {
            throw StoreError.invalidEventTime
        }
        lock.lock()
        defer { lock.unlock() }
        var envelope = try loadLocked()
        var authority = try requireAuthority(envelope)
        try Self.match(identity, authority: authority)
        if authority.status == .resolved || authority.status == .gapResolvedConsumersPending {
            return authority
        }
        guard authority.status == .coverageProven || authority.status == .consumersCommitted,
              authority.historyComplete != nil,
              authority.coverageProof != nil,
              authority.gapResolutionPreparedAtUnix != nil,
              authority.resolvedAtUnix == nil else {
            throw StoreError.notReadyToResolve
        }
        authority.resolvedAtUnix = resolvedAt.timeIntervalSince1970
        authority.status = authority.consumerCommit == nil
            ? .gapResolvedConsumersPending
            : .resolved
        envelope.authority = authority
        try persistLocked(envelope)
        return try requireAuthority(try loadLocked())
    }

    func load() throws -> Authority? {
        lock.lock()
        defer { lock.unlock() }
        return try loadLocked().authority
    }

    func clearUnresolvedAuthorityIfGapNoLongerPending(
        gapIdentifier: String
    ) throws {
        lock.lock(); defer { lock.unlock() }
        var envelope = try loadLocked()
        guard let authority = envelope.authority,
              authority.status != .resolved,
              authority.gap.gapIdentifier == gapIdentifier else { return }
        envelope.authority = nil
        try persistLocked(envelope)
    }

    /// A gap-ledger compaction may retain the UUID while widening/changing the
    /// interval. Only a still-draining authority (no ACKed terminal claim) may
    /// be abandoned for that changed fingerprint. Terminal authorities remain
    /// immutable and require their exact crash-resume path.
    func abandonDrainingAuthorityIfGapFingerprintChanged(
        gapIdentifier: String,
        observedStartUnix: TimeInterval,
        observedEndUnix: TimeInterval,
        observedReason: String
    ) throws -> Bool {
        guard observedStartUnix.isFinite,
              observedEndUnix.isFinite,
              observedEndUnix > observedStartUnix,
              !observedReason.isEmpty else { throw StoreError.invalidGap }
        lock.lock(); defer { lock.unlock() }
        var envelope = try loadLocked()
        guard let authority = envelope.authority,
              authority.status == .draining,
              authority.gap.gapIdentifier == gapIdentifier else { return false }
        let changed = authority.gap.startUnix != observedStartUnix
            || authority.gap.endUnix != observedEndUnix
            || authority.gap.reason != observedReason
        guard changed else { return false }
        envelope.authority = nil
        try persistLocked(envelope)
        return true
    }

    private func loadLocked() throws -> Envelope {
        guard fileManager.fileExists(atPath: stateURL.path) else {
            return Envelope(version: Envelope.currentVersion, authority: nil)
        }
        do {
            let data = try Data(contentsOf: stateURL)
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            guard envelope.version == Envelope.currentVersion,
                  try Self.canonicalData(envelope) == data else {
                throw StoreError.stateCorrupt
            }
            if let authority = envelope.authority { try Self.validate(authority) }
            return envelope
        } catch let error as StoreError {
            throw error
        } catch {
            throw StoreError.stateCorrupt
        }
    }

    private func persistLocked(_ envelope: Envelope) throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let data = try Self.canonicalData(envelope)
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

    private static func validate(_ gap: PendingGap) throws {
        guard gap.pending,
              !gap.gapIdentifier.isEmpty,
              gap.gapLedgerGeneration > 0,
              isSHA256(gap.gapLedgerSnapshotSHA256),
              gap.startUnix.isFinite,
              gap.endUnix.isFinite,
              gap.startUnix > 0,
              gap.endUnix > gap.startUnix,
              !gap.reason.isEmpty else { throw StoreError.invalidGap }
    }

    private static func validate(_ attempt: Attempt, gap: PendingGap) throws {
        guard !attempt.attemptIdentifier.isEmpty,
              attempt.attemptNumber > 0,
              !attempt.peripheralIdentifier.isEmpty,
              !attempt.strapIdentity.isEmpty,
              !attempt.transportNonce.isEmpty,
              attempt.transportGeneration > 0,
              isSHA256(attempt.fullDrainCommandSHA256),
              attempt.commandWriteCompletedAtUnix.isFinite,
              attempt.commandWriteCompletedAtUnix >= gap.endUnix,
              attempt.transportAuthority.isValid,
              attempt.transportAuthority.peripheralIdentifier == attempt.peripheralIdentifier,
              attempt.transportAuthority.strapIdentity == attempt.strapIdentity,
              attempt.transportAuthority.transportNonce == attempt.transportNonce,
              attempt.transportAuthority.transportGeneration == attempt.transportGeneration,
              attempt.transportAuthority.fullDrainWriteCompletedAtUnix
                == attempt.commandWriteCompletedAtUnix else {
            throw StoreError.invalidAttempt
        }
    }

    private static func validateTerminalGapReconciliations(
        _ entries: [TerminalGapReconciliation],
        authority: Authority
    ) throws {
        guard entries.map(\.gap.startUnix) == entries.map(\.gap.startUnix).sorted(),
              Set(entries.map(\.gap.gapIdentifier)).count == entries.count,
              !entries.contains(where: {
                  $0.gap.gapIdentifier == authority.gap.gapIdentifier
              }), let terminal = authority.historyComplete else {
            throw StoreError.stateCorrupt
        }
        for entry in entries {
            do { try validate(entry.gap) } catch { throw StoreError.stateCorrupt }
            if let prepared = entry.resolutionPreparedAtUnix, !prepared.isFinite {
                throw StoreError.stateCorrupt
            }
            if let resolved = entry.resolvedAtUnix, !resolved.isFinite {
                throw StoreError.stateCorrupt
            }
            if let proof = entry.coverageProof,
               !AtriaHistoricalFullDrainCoveragePolicy.validate(
                   proof,
                   gapIdentifier: entry.gap.gapIdentifier,
                   gapStartUnix: entry.gap.startUnix,
                   gapEndUnix: entry.gap.endUnix,
                   attemptIdentifier: authority.attempt.attemptIdentifier,
                   transportNonce: authority.attempt.transportNonce,
                   transportGeneration: authority.attempt.transportGeneration,
                   stores: terminal.stores,
                   configuration: authority.configuration
               ) {
                throw StoreError.stateCorrupt
            }
            switch entry.status {
            case .rejected:
                guard entry.coverageProof == nil,
                      entry.rejectionReason?.isEmpty == false,
                      entry.resolutionPreparedAtUnix == nil,
                      entry.resolvedAtUnix == nil else { throw StoreError.stateCorrupt }
            case .coverageProven:
                guard let proof = entry.coverageProof,
                      entry.rejectionReason == nil,
                      entry.resolutionPreparedAtUnix == nil,
                      entry.resolvedAtUnix == nil,
                      AtriaHistoricalFullDrainCoveragePolicy.validate(
                          proof,
                          gapIdentifier: entry.gap.gapIdentifier,
                          gapStartUnix: entry.gap.startUnix,
                          gapEndUnix: entry.gap.endUnix,
                          attemptIdentifier: authority.attempt.attemptIdentifier,
                          transportNonce: authority.attempt.transportNonce,
                          transportGeneration: authority.attempt.transportGeneration,
                          stores: terminal.stores,
                          configuration: authority.configuration
                      ) else { throw StoreError.stateCorrupt }
            case .resolutionPrepared:
                guard entry.coverageProof != nil,
                      entry.rejectionReason == nil,
                      entry.resolutionPreparedAtUnix != nil,
                      entry.resolvedAtUnix == nil else { throw StoreError.stateCorrupt }
            case .resolved, .preserved:
                guard entry.coverageProof != nil,
                      entry.rejectionReason == nil,
                      entry.resolutionPreparedAtUnix != nil,
                      entry.resolvedAtUnix != nil else { throw StoreError.stateCorrupt }
            }
        }
    }

    private static func validate(_ authority: Authority) throws {
        guard authority.version == Authority.currentVersion,
              !authority.authorityIdentifier.isEmpty,
              authority.createdAtUnix.isFinite,
              authority.createdAtUnix >= authority.attempt.commandWriteCompletedAtUnix,
              authority.configuration.isValid else { throw StoreError.stateCorrupt }
        do {
            try validate(authority.gap)
            try validate(authority.attempt, gap: authority.gap)
        } catch {
            throw StoreError.stateCorrupt
        }
        var priorStores: Stores?
        var identifiers = Set<String>()
        for boundary in authority.boundaries {
            guard !boundary.boundaryIdentifier.isEmpty,
                  identifiers.insert(boundary.boundaryIdentifier).inserted,
                  isSHA256(boundary.historyEndSHA256),
                  isSHA256(boundary.expectedACKSHA256),
                  boundary.stores.isValid,
                  boundary.fsyncedAtUnix.isFinite,
                  boundary.fsyncedAtUnix >= authority.attempt.commandWriteCompletedAtUnix,
                  boundary.stores.raw.fsyncedAtUnix <= boundary.fsyncedAtUnix,
                  boundary.stores.identity.fsyncedAtUnix <= boundary.fsyncedAtUnix,
                  boundary.stores.admission.fsyncedAtUnix <= boundary.fsyncedAtUnix,
                  (boundary.ackAttempt == nil) == (boundary.ackCompletedAtUnix == nil),
                  boundary.ackAttempt.map({ $0 > 0 }) ?? true,
                  boundary.ackCompletedAtUnix.map({ $0 >= boundary.fsyncedAtUnix }) ?? true else {
                throw StoreError.stateCorrupt
            }
            if let priorStores, !boundary.stores.isAtLeastAsDurable(as: priorStores) {
                throw StoreError.stateCorrupt
            }
            priorStores = boundary.stores
        }
        if let terminal = authority.historyComplete {
            guard !terminal.completionIdentifier.isEmpty,
                  isSHA256(terminal.notificationSHA256),
                  terminal.acknowledgedBoundaryCount == authority.boundaries.count,
                  terminal.stores.isValid,
                  terminal.receivedAtUnix.isFinite,
                  (terminal.terminalBatchNumber == nil)
                    == (terminal.durableSequence == nil),
                  terminal.durableSequence.map({ $0 > 0 }) ?? true,
                  authority.boundaries.allSatisfy({ $0.ackCompletedAtUnix != nil }) else {
                throw StoreError.stateCorrupt
            }
            if let last = authority.boundaries.last {
                guard terminal.stores.isAtLeastAsDurable(as: last.stores),
                      terminal.receivedAtUnix >= (last.ackCompletedAtUnix ?? .infinity) else {
                    throw StoreError.stateCorrupt
                }
            }
        }
        if let proof = authority.coverageProof {
            guard let terminal = authority.historyComplete,
                  AtriaHistoricalFullDrainCoveragePolicy.validate(
                      proof,
                      gapIdentifier: authority.gap.gapIdentifier,
                      gapStartUnix: authority.gap.startUnix,
                      gapEndUnix: authority.gap.endUnix,
                      attemptIdentifier: authority.attempt.attemptIdentifier,
                      transportNonce: authority.attempt.transportNonce,
                      transportGeneration: authority.attempt.transportGeneration,
                      stores: terminal.stores,
                      configuration: authority.configuration
                  ) else { throw StoreError.stateCorrupt }
        }
        if let commit = authority.consumerCommit {
            guard let terminal = authority.historyComplete,
                  commit.committedAtUnix.isFinite else { throw StoreError.stateCorrupt }
            let receipts = commit.receipts.sorted { $0.kind < $1.kind }
            let expectedKinds = Set(authority.configuration.requiredConsumerKinds)
            guard receipts == commit.receipts,
                  receipts.count == expectedKinds.count,
                  Set(receipts.map(\.kind)) == expectedKinds,
                  Set(receipts.map(\.commitIdentifier)).count == receipts.count,
                  receipts.allSatisfy({ receipt in
                      !receipt.commitIdentifier.isEmpty
                          && isSHA256(receipt.receiptSHA256)
                          && isSHA256(receipt.artifactSHA256)
                          && receipt.sourceRawSnapshotSHA256
                              == terminal.stores.raw.snapshotSHA256
                          && receipt.sourceIdentitySnapshotSHA256
                              == terminal.stores.identity.snapshotSHA256
                          && receipt.sourceAdmissionSnapshotSHA256
                              == terminal.stores.admission.snapshotSHA256
                          && receipt.gapIdentifier == authority.gap.gapIdentifier
                          && receipt.attemptIdentifier
                              == authority.attempt.attemptIdentifier
                          && receipt.completionIdentifier == terminal.completionIdentifier
                          && receipt.committedAtUnix.isFinite
                          && receipt.committedAtUnix >= terminal.receivedAtUnix
                          && commit.committedAtUnix >= receipt.committedAtUnix
                  }),
                  commit.receiptSetSHA256 == sha256(try canonicalData(receipts)) else {
                throw StoreError.stateCorrupt
            }
        }
        if let publication = authority.publication {
            guard !publication.chunkID.isEmpty,
                  publication.durableSequence > 0,
                  publication.completedAtUnix.isFinite else {
                throw StoreError.stateCorrupt
            }
            switch publication.status {
            case .prepared:
                guard publication.rawSeal == nil,
                      publication.completion == nil,
                      publication.projections == nil else { throw StoreError.stateCorrupt }
            case .rawSealed:
                guard publication.rawSeal != nil,
                      publication.completion == nil,
                      publication.projections == nil else { throw StoreError.stateCorrupt }
            case .completionPublished:
                guard publication.rawSeal != nil,
                      publication.completion != nil,
                      publication.projections == nil else { throw StoreError.stateCorrupt }
            case .projectionsPublished:
                guard publication.rawSeal != nil,
                      publication.completion != nil,
                      publication.projections != nil else { throw StoreError.stateCorrupt }
            }
        }
        if let entries = authority.terminalGapReconciliations {
            try validateTerminalGapReconciliations(entries, authority: authority)
        }
        if let resolvedAtUnix = authority.resolvedAtUnix {
            guard resolvedAtUnix.isFinite else { throw StoreError.stateCorrupt }
        }
        if let preparedAtUnix = authority.gapResolutionPreparedAtUnix {
            guard preparedAtUnix.isFinite else { throw StoreError.stateCorrupt }
        }
        if let pending = authority.boundaries.last, pending.ackCompletedAtUnix == nil {
            guard authority.status == .draining,
                  authority.historyComplete == nil,
                  authority.coverageProof == nil,
                  authority.consumerCommit == nil else { throw StoreError.stateCorrupt }
        }
        switch authority.status {
        case .draining:
            guard authority.historyComplete == nil,
                  authority.coverageProof == nil,
                  authority.consumerCommit == nil,
                  authority.gapResolutionPreparedAtUnix == nil,
                  authority.resolvedAtUnix == nil else { throw StoreError.stateCorrupt }
        case .historyComplete:
            guard authority.historyComplete != nil,
                  authority.coverageProof == nil,
                  authority.consumerCommit == nil,
                  authority.gapResolutionPreparedAtUnix == nil,
                  authority.resolvedAtUnix == nil else { throw StoreError.stateCorrupt }
        case .coverageProven:
            guard authority.historyComplete != nil,
                  authority.coverageProof != nil,
                  authority.consumerCommit == nil,
                  authority.resolvedAtUnix == nil else { throw StoreError.stateCorrupt }
        case .gapResolvedConsumersPending:
            guard authority.historyComplete != nil,
                  authority.coverageProof != nil,
                  authority.consumerCommit == nil,
                  authority.resolvedAtUnix != nil else { throw StoreError.stateCorrupt }
        case .consumersCommitted:
            guard authority.historyComplete != nil,
                  authority.coverageProof != nil,
                  authority.consumerCommit != nil,
                  authority.resolvedAtUnix == nil else { throw StoreError.stateCorrupt }
        case .resolved:
            guard authority.historyComplete != nil,
                  authority.coverageProof != nil,
                  authority.consumerCommit != nil,
                  authority.resolvedAtUnix != nil else { throw StoreError.stateCorrupt }
        }
    }

    private static func match(_ identity: EventIdentity, authority: Authority) throws {
        guard identity.gapIdentifier == authority.gap.gapIdentifier,
              identity.attemptIdentifier == authority.attempt.attemptIdentifier,
              identity.peripheralIdentifier == authority.attempt.peripheralIdentifier,
              identity.strapIdentity == authority.attempt.strapIdentity,
              identity.transportNonce == authority.attempt.transportNonce,
              identity.transportGeneration == authority.attempt.transportGeneration else {
            throw StoreError.staleEventIdentity
        }
    }

    private static func permit(authority: Authority, boundary: BatchBoundary) throws -> ACKPermit {
        var immutable = boundary
        immutable.ackAttempt = nil
        immutable.ackCompletedAtUnix = nil
        return ACKPermit(
            authorityIdentifier: authority.authorityIdentifier,
            boundaryIdentifier: boundary.boundaryIdentifier,
            expectedACKSHA256: boundary.expectedACKSHA256,
            evidenceSHA256: sha256(try canonicalData(immutable))
        )
    }

    private func requireAuthority(_ envelope: Envelope) throws -> Authority {
        guard let authority = envelope.authority else { throw StoreError.authorityMissing }
        return authority
    }

    private static func canonicalData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(value)
    }

    private static func sha256(_ data: Data) -> String {
        AtriaHistoricalFullDrainCoveragePolicy.sha256(data)
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }

    private static func synchronizeDirectory(_ directory: URL) throws {
        let descriptor = open(directory.path, O_RDONLY)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}
