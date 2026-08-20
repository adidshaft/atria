import Foundation

/// Deterministic state machine for the WHOOP 4 historical-data drain.
///
/// The reducer deliberately knows nothing about CoreBluetooth or the archive
/// implementation. Its caller performs the returned effects and feeds their
/// verified completions back into the state machine. This keeps the critical
/// ordering explicit:
///
/// 1. every unique frame is persisted;
/// 2. every HISTORY_END waits for all of its persistence completions;
/// 3. that batch is durably flushed before its ACK is sent;
/// 4. only a verified ACK opens the next batch;
/// 5. HISTORY_COMPLETE durably flushes any unsealed tail before completion.
///
/// All errors fail closed. A failed generation never emits another ACK or a
/// successful completion effect.
struct AtriaWhoop4HistoryDrainState: Equatable, Sendable {
    /// A physical full-flash drain can contain hundreds of genuine holes. This
    /// remains bounded, while 448-byte frame identities keep the worst-case
    /// canonical JSON comfortably below the store's 600 KB admission ceiling.
    static let maximumConfirmedForwardDiscontinuities = 512
    static let maximumContinuityFrameKeyUTF8Count = 448

    struct ContinuitySnapshot: Codable, Equatable, Sendable {
        struct Transition: Codable, Equatable, Hashable, Sendable {
            let streamKey: UInt16
            let previousFrameKey: String
            let currentFrameKey: String
            let previousSequence: UInt16
            let currentSequence: UInt16
        }

        struct Pending: Codable, Equatable, Sendable {
            let transition: Transition
            let firstObservedGeneration: UInt64
        }

        static let currentSchemaVersion = 1
        let schemaVersion: Int
        let pending: Pending?
        let confirmed: [Transition]
    }

    private struct ForwardDiscontinuity: Equatable, Hashable, Sendable {
        let streamKey: UInt16
        let previousFrameKey: String
        let currentFrameKey: String
        let previousSequence: UInt16
        let currentSequence: UInt16
    }

    private struct HistoricalSequenceCursor: Equatable, Sendable {
        let sequence: UInt16
        let frameKey: String
    }

    private struct HistoricalSequenceObservation: Equatable, Sendable {
        let streamKey: UInt16
        let sequence: UInt16
    }

    private struct PendingForwardDiscontinuity: Equatable, Sendable {
        let transition: ForwardDiscontinuity
        let firstObservedGeneration: UInt64
        /// Set only by validated durable restore. Process-local generation IDs
        /// may restart at the same value after launch, while a second callback
        /// in the original process must never self-confirm.
        let wasRestoredAcrossProcessBoundary: Bool
    }

    enum FlushBoundary: Equatable, Hashable, Sendable {
        case batch(String)
        case terminal(UInt64)
    }

    enum Failure: Equatable, Sendable {
        case persistence(frameKey: String)
        case durableFlush(boundary: FlushBoundary)
        case ack(boundaryID: String, attempts: Int)
        case protocolViolation(String)
    }

    /// Exact admission is decided by `AtriaWhoop4HistoryAdmissionLedger`
    /// before this reducer is called. Keeping that authority outside the value
    /// reducer makes memory independent of a repeated whole-flash drain.
    enum Admission: Equatable, Sendable {
        case firstSeen
        case needsPersistence
        case durableReplay
        case duplicateInCurrentIncarnation
    }

    enum Effect: Equatable, Sendable {
        case persistFrame(generation: UInt64, frameKey: String, payload: [UInt8])
        case durableFlush(generation: UInt64, boundary: FlushBoundary)
        case sendACK(
            generation: UInt64,
            boundaryID: String,
            payload: [UInt8],
            attempt: Int
        )
        case finished(generation: UInt64)
        case failed(generation: UInt64, failure: Failure)
    }

    private enum Phase: Equatable, Sendable {
        case idle
        case listening
        case waitingForBatchPersistence(boundaryID: String, ackPayload: [UInt8])
        case waitingForBatchFlush(boundaryID: String, ackPayload: [UInt8])
        case waitingForACK(boundaryID: String, ackPayload: [UInt8], attempt: Int)
        case waitingForTerminalPersistence(boundary: FlushBoundary)
        case waitingForTerminalFlush(boundary: FlushBoundary)
        case finished
        case failed(Failure)
    }

    private(set) var generation: UInt64?
    private(set) var persistedFrameCount = 0
    private(set) var acknowledgedBatchCount = 0
    private(set) var terminalWasReceived = false
    private(set) var sequenceRestartCount = 0
    private(set) var failureOriginPhaseForDiagnostics: String?
    private(set) var peakAcceptedFrameIdentityCount = 0

    private let maximumACKAttempts: Int
    private var phase: Phase = .idle
    private var currentBatchNumber: UInt64 = 0
    private var currentBatchFrameCount = 0
    private var historicalSequenceCursors: [UInt16: HistoricalSequenceCursor] = [:]
    private var pendingFrameKeys: Set<String> = []
    private var acknowledgedBoundaryIDs: Set<String> = []
    /// True until the first frame that is not a previously durable prefix.
    /// After process restart, a full-flash replay uses its ordered durable rows
    /// to rebuild only the O(1) sequence cursor. A later old duplicate is then
    /// ignored and can never rewind that cursor.
    private var isRehydratingDurablePrefix = true
    private var classifiedIdentityCount = 0
    private var failurePendingPersistenceCountForDiagnostics = 0
    private var terminalAfterCurrentBatch = false
    /// Survives `begin` so a forward discontinuity must be observed identically
    /// in two different drain generations before the strap cursor may advance.
    private var pendingForwardDiscontinuity: PendingForwardDiscontinuity?
    /// When a prior generation failed at the first frame after an ACKed batch,
    /// the strap legitimately resumes at the candidate's current frame. Seed
    /// the next generation with the ACKed previous identity so that first frame
    /// must still replay-confirm the exact stored transition.
    private var requiresPendingForwardDiscontinuityReplay = false
    /// Multiple real flash holes can occur in one backlog. Retaining a bounded
    /// set of already replay-confirmed transitions prevents retry oscillation.
    private var confirmedForwardDiscontinuities: [ForwardDiscontinuity] = []

    init(maximumACKAttempts: Int = 3) {
        self.maximumACKAttempts = max(1, maximumACKAttempts)
    }

    var continuitySnapshot: ContinuitySnapshot {
        ContinuitySnapshot(
            schemaVersion: ContinuitySnapshot.currentSchemaVersion,
            pending: pendingForwardDiscontinuity.map {
                .init(transition: Self.snapshotTransition($0.transition),
                      firstObservedGeneration: $0.firstObservedGeneration)
            },
            confirmed: confirmedForwardDiscontinuities.map(Self.snapshotTransition)
        )
    }

    /// Restores only cross-generation sequence evidence. Ephemeral drain phase,
    /// frame cursors and ACK state are intentionally never restartable.
    mutating func restoreContinuitySnapshot(_ snapshot: ContinuitySnapshot) -> Bool {
        guard phase == .idle, Self.validate(snapshot) else { return false }
        pendingForwardDiscontinuity = snapshot.pending.map {
            PendingForwardDiscontinuity(
                transition: Self.reducerTransition($0.transition),
                firstObservedGeneration: $0.firstObservedGeneration,
                wasRestoredAcrossProcessBoundary: true
            )
        }
        confirmedForwardDiscontinuities = snapshot.confirmed.map(Self.reducerTransition)
        return true
    }

    mutating func clearContinuityEvidence() {
        pendingForwardDiscontinuity = nil
        confirmedForwardDiscontinuities.removeAll(keepingCapacity: false)
        requiresPendingForwardDiscontinuityReplay = false
    }

    private static func validate(_ snapshot: ContinuitySnapshot) -> Bool {
        guard snapshot.schemaVersion == ContinuitySnapshot.currentSchemaVersion,
              snapshot.confirmed.count <= maximumConfirmedForwardDiscontinuities,
              Set(snapshot.confirmed).count == snapshot.confirmed.count,
              snapshot.pending.map({ !snapshot.confirmed.contains($0.transition) }) ?? true,
              snapshot.pending?.firstObservedGeneration != 0 else { return false }
        let transitions = snapshot.confirmed + (snapshot.pending.map { [$0.transition] } ?? [])
        return transitions.allSatisfy { transition in
            !transition.previousFrameKey.isEmpty
                && transition.previousFrameKey.utf8.count <= maximumContinuityFrameKeyUTF8Count
                && !transition.currentFrameKey.isEmpty
                && transition.currentFrameKey.utf8.count <= maximumContinuityFrameKeyUTF8Count
                && Int16(bitPattern: transition.currentSequence &- transition.previousSequence) > 1
        }
    }

    private static func snapshotTransition(_ transition: ForwardDiscontinuity)
        -> ContinuitySnapshot.Transition {
        .init(streamKey: transition.streamKey,
              previousFrameKey: transition.previousFrameKey,
              currentFrameKey: transition.currentFrameKey,
              previousSequence: transition.previousSequence,
              currentSequence: transition.currentSequence)
    }

    private static func reducerTransition(_ transition: ContinuitySnapshot.Transition)
        -> ForwardDiscontinuity {
        .init(streamKey: transition.streamKey,
              previousFrameKey: transition.previousFrameKey,
              currentFrameKey: transition.currentFrameKey,
              previousSequence: transition.previousSequence,
              currentSequence: transition.currentSequence)
    }

    var isFinished: Bool {
        phase == .finished
    }

    var failure: Failure? {
        guard case .failed(let failure) = phase else { return nil }
        return failure
    }

    var pendingPersistenceCount: Int {
        if case .failed = phase {
            return failurePendingPersistenceCountForDiagnostics
        }
        return pendingFrameKeys.count
    }

    var currentBatchFrameCountForDiagnostics: Int {
        currentBatchFrameCount
    }

    var acceptedFrameIdentityCountForDiagnostics: Int {
        classifiedIdentityCount
    }

    var phaseForDiagnostics: String {
        Self.phaseLabel(phase)
    }

    /// The CoreBluetooth data and metadata characteristics are independent, so
    /// a HISTORY_END callback can reach the ordered transport queue just ahead
    /// of the final data callbacks from that page. The reducer must remain
    /// fail-closed if a caller actually feeds a frame across the boundary, while
    /// the orchestrator uses this signal to retain those callbacks until the
    /// durable flush and ACK have completed.
    var canReceiveFrame: Bool {
        if case .listening = phase { return true }
        return false
    }

    private static func phaseLabel(_ phase: Phase) -> String {
        switch phase {
        case .idle: return "idle"
        case .listening: return "listening"
        case .waitingForBatchPersistence: return "waiting_for_batch_persistence"
        case .waitingForBatchFlush: return "waiting_for_batch_flush"
        case .waitingForACK: return "waiting_for_ack"
        case .waitingForTerminalPersistence: return "waiting_for_terminal_persistence"
        case .waitingForTerminalFlush: return "waiting_for_terminal_flush"
        case .finished: return "finished"
        case .failed: return "failed"
        }
    }

    /// Available only after a genuine HISTORY_COMPLETE reached the terminal
    /// state. These values bind downstream durable completion to this reducer
    /// generation without exposing mutable reducer internals.
    var terminalBatchNumberForCompletedDrain: UInt64? {
        guard isFinished, terminalWasReceived else { return nil }
        return currentBatchNumber
    }

    var durableFrameCountForCompletedDrain: UInt64? {
        guard isFinished, terminalWasReceived, persistedFrameCount > 0 else { return nil }
        return UInt64(persistedFrameCount)
    }

    /// Starts a newer drain generation. Repeated or older begins are ignored so
    /// delayed orchestration cannot erase live progress.
    mutating func begin(generation newGeneration: UInt64) -> [Effect] {
        if let generation, newGeneration <= generation {
            return []
        }
        generation = newGeneration
        persistedFrameCount = 0
        acknowledgedBatchCount = 0
        terminalWasReceived = false
        sequenceRestartCount = 0
        failureOriginPhaseForDiagnostics = nil
        peakAcceptedFrameIdentityCount = 0
        classifiedIdentityCount = 0
        failurePendingPersistenceCountForDiagnostics = 0
        phase = .listening
        currentBatchNumber = 0
        currentBatchFrameCount = 0
        historicalSequenceCursors.removeAll(keepingCapacity: true)
        if let pendingForwardDiscontinuity {
            historicalSequenceCursors[pendingForwardDiscontinuity.transition.streamKey] =
                HistoricalSequenceCursor(
                    sequence: pendingForwardDiscontinuity.transition.previousSequence,
                    frameKey: pendingForwardDiscontinuity.transition.previousFrameKey
                )
            requiresPendingForwardDiscontinuityReplay = true
        } else {
            requiresPendingForwardDiscontinuityReplay = false
        }
        pendingFrameKeys.removeAll(keepingCapacity: false)
        acknowledgedBoundaryIDs.removeAll(keepingCapacity: false)
        isRehydratingDurablePrefix = true
        terminalAfterCurrentBatch = false
        return []
    }

    /// Accepts one historical frame. `frameKey` must be a stable strap identity
    /// (for example flash cursor + device timestamp + sequence), not a local
    /// callback counter. Replayed frames with the same key are ignored.
    mutating func receiveFrame(
        generation eventGeneration: UInt64,
        frameKey: String,
        payload: [UInt8],
        admission: Admission = .firstSeen,
        /// An authority-bound full-flash drain has a separate timestamp-based
        /// coverage proof before it can resolve a missing interval. The WHOOP
        /// inner record counter is not that proof: physical captures contain
        /// large forward jumps for the same layout. In this narrow mode retain
        /// and fsync the raw frame, leave the coverage gap pending, and record
        /// the discontinuity for a future replay instead of discarding a whole
        /// page on an unproven counter jump.
        permitsUnconfirmedForwardDiscontinuity: Bool = false
    ) -> [Effect] {
        guard accepts(eventGeneration), !frameKey.isEmpty else { return [] }
        guard case .listening = phase else {
            return fail(.protocolViolation("frame_received_after_batch_boundary"))
        }
        switch admission {
        case .duplicateInCurrentIncarnation:
            return []
        case .durableReplay:
            guard isRehydratingDurablePrefix else { return [] }
            // This row crossed the raw archive+identity fsync boundary in an
            // earlier incarnation. Observe the ordered prefix without asking
            // for another archive write or performing discontinuity policy.
            if let observation = Self.historicalSequence(from: payload) {
                let cursor = historicalSequenceCursors[observation.streamKey]
                if cursor == nil || Int16(bitPattern: observation.sequence &- cursor!.sequence) > 0 {
                    historicalSequenceCursors[observation.streamKey] = HistoricalSequenceCursor(
                        sequence: observation.sequence,
                        frameKey: frameKey
                    )
                }
            }
            return []
        case .firstSeen, .needsPersistence:
            isRehydratingDurablePrefix = false
        }
        classifiedIdentityCount += 1
        peakAcceptedFrameIdentityCount = max(peakAcceptedFrameIdentityCount,
                                             classifiedIdentityCount)
        if let observation = Self.historicalSequence(from: payload) {
            let sequence = observation.sequence
            if let cursor = historicalSequenceCursors[observation.streamKey] {
                let previous = cursor.sequence
                let previousFrameKey = cursor.frameKey
                // The inner UInt16 is a stored-record sequence, not a proven BLE
                // packet counter. Physical drains contain backward flash overlap
                // and forward discontinuities (for example 28818 -> 29279), but a
                // first-seen forward jump is also consistent with dropped BLE
                // notifications. Fail closed on first observation. Only the exact
                // same stable-frame transition replayed by a later generation can
                // prove the discontinuity belongs to the strap backlog and permit
                // persistence/ACK. Backward overlap is immediately replay-safe
                // because full-frame identity dedupes it without cursor loss.
                let serialDelta = Int16(bitPattern: sequence &- previous)
                if requiresPendingForwardDiscontinuityReplay,
                   let replayCandidate = pendingForwardDiscontinuity,
                   observation.streamKey == replayCandidate.transition.streamKey,
                   serialDelta > 0,
                   (frameKey != replayCandidate.transition.currentFrameKey
                    || sequence != replayCandidate.transition.currentSequence) {
                    if serialDelta == 1 {
                        // The retry supplied the exact next record that was
                        // absent from the first observation. That proves the
                        // saved jump was a dropped BLE notification, not a
                        // flash discontinuity. Retract the false candidate and
                        // resume from this contiguous frame; the formerly
                        // expected frame must then arrive contiguously too.
                        pendingForwardDiscontinuity = nil
                        requiresPendingForwardDiscontinuityReplay = false
                    } else if !permitsUnconfirmedForwardDiscontinuity {
                        // The stream key names WHICH record stream is pinned
                        // at the boundary — without it a persisted failure
                        // cannot distinguish a starved motion stream from a
                        // starved HR stream (2026-08-20 device diagnosis had
                        // to infer this from store write times instead).
                        return fail(.protocolViolation(
                            "history_sequence_gap_replay_mismatch_expected_\(replayCandidate.transition.currentSequence)_received_\(sequence)_stream_\(replayCandidate.transition.streamKey)"
                        ))
                    }
                }
                if serialDelta > 1 {
                    let transition = ForwardDiscontinuity(
                        streamKey: observation.streamKey,
                        previousFrameKey: previousFrameKey,
                        currentFrameKey: frameKey,
                        previousSequence: previous,
                        currentSequence: sequence
                    )
                    if confirmedForwardDiscontinuities.contains(transition) {
                        sequenceRestartCount += 1
                    } else if matchesEstablishedForwardDiscontinuityPattern(
                        transition
                    ) {
                        // WHOOP flash layouts can interleave a secondary record
                        // block at a fixed sequence cadence. Require three
                        // independently replay-confirmed transitions with the
                        // same stream, jump and cadence before admitting the
                        // next occurrence on first observation. A changed jump
                        // or cadence still takes the exact two-generation path.
                        rememberConfirmedForwardDiscontinuity(transition)
                        sequenceRestartCount += 1
                    } else if pendingForwardDiscontinuity?.transition == transition,
                              (pendingForwardDiscontinuity?.firstObservedGeneration != eventGeneration
                               || pendingForwardDiscontinuity?.wasRestoredAcrossProcessBoundary == true) {
                        rememberConfirmedForwardDiscontinuity(transition)
                        pendingForwardDiscontinuity = nil
                        sequenceRestartCount += 1
                    } else if permitsUnconfirmedForwardDiscontinuity {
                        // This is deliberately not a coverage acceptance. The
                        // caller has an authority-bound full drain and its
                        // timestamp/cadence verifier still owns retirement of
                        // the exact missing interval. Keeping the raw frame
                        // here prevents a real flash-layout jump from making
                        // every later page unreachable, while the pending
                        // transition remains durable replay evidence.
                        if pendingForwardDiscontinuity == nil {
                            pendingForwardDiscontinuity = PendingForwardDiscontinuity(
                                transition: transition,
                                firstObservedGeneration: eventGeneration,
                                wasRestoredAcrossProcessBoundary: false
                            )
                        }
                        sequenceRestartCount += 1
                    } else {
                        pendingForwardDiscontinuity = PendingForwardDiscontinuity(
                            transition: transition,
                            firstObservedGeneration: eventGeneration,
                            wasRestoredAcrossProcessBoundary: false
                        )
                        return fail(.protocolViolation(
                            "history_sequence_gap_unconfirmed_previous_\(previous)_received_\(sequence)"
                        ))
                    }
                } else if serialDelta <= 0 {
                    sequenceRestartCount += 1
                }
                // A full-flash drain interleaves older/secondary records with
                // the forward record stream. Observe and persist that overlap,
                // but never let it rewind the forward sequence cursor. If it
                // did, the next genuinely contiguous forward record would look
                // like a dropped-notification gap (for example 405, 366, 406).
                // UInt16 wrap remains forward because `serialDelta` is 1.
                if serialDelta <= 0 {
                    pendingFrameKeys.insert(frameKey)
                    currentBatchFrameCount += 1
                    return [.persistFrame(
                        generation: eventGeneration,
                        frameKey: frameKey,
                        payload: payload
                    )]
                }
            }
            historicalSequenceCursors[observation.streamKey] = HistoricalSequenceCursor(
                sequence: sequence,
                frameKey: frameKey
            )
            if pendingForwardDiscontinuity == nil
                || observation.streamKey == pendingForwardDiscontinuity?.transition.streamKey {
                requiresPendingForwardDiscontinuityReplay = false
            }
        }
        pendingFrameKeys.insert(frameKey)
        currentBatchFrameCount += 1
        return [.persistFrame(
            generation: eventGeneration,
            frameKey: frameKey,
            payload: payload
        )]
    }

    private func matchesEstablishedForwardDiscontinuityPattern(
        _ candidate: ForwardDiscontinuity
    ) -> Bool {
        let candidateDelta = candidate.currentSequence &- candidate.previousSequence
        let matching = confirmedForwardDiscontinuities.filter { transition in
            transition.streamKey == candidate.streamKey
                && transition.currentSequence &- transition.previousSequence
                    == candidateDelta
        }
        guard matching.count >= 3 else { return false }
        let a = matching[matching.count - 3]
        let b = matching[matching.count - 2]
        let c = matching[matching.count - 1]
        let firstCadence = b.previousSequence &- a.previousSequence
        let secondCadence = c.previousSequence &- b.previousSequence
        let candidateCadence = candidate.previousSequence &- c.previousSequence
        return firstCadence > 0
            && firstCadence == secondCadence
            && candidateCadence == firstCadence
    }

    mutating func persistenceCompleted(
        generation eventGeneration: UInt64,
        frameKey: String,
        succeeded: Bool
    ) -> [Effect] {
        guard accepts(eventGeneration), pendingFrameKeys.contains(frameKey) else {
            return []
        }
        guard succeeded else {
            return fail(.persistence(frameKey: frameKey))
        }
        pendingFrameKeys.remove(frameKey)
        persistedFrameCount += 1
        guard pendingFrameKeys.isEmpty else { return [] }

        switch phase {
        case .waitingForBatchPersistence(let boundaryID, let ackPayload):
            let boundary = FlushBoundary.batch(boundaryID)
            phase = .waitingForBatchFlush(boundaryID: boundaryID, ackPayload: ackPayload)
            return [.durableFlush(generation: eventGeneration, boundary: boundary)]
        case .waitingForTerminalPersistence(let boundary):
            phase = .waitingForTerminalFlush(boundary: boundary)
            return [.durableFlush(generation: eventGeneration, boundary: boundary)]
        default:
            return []
        }
    }

    /// Seals the current batch. A repeated copy of the same boundary is
    /// idempotent both before and after its verified ACK. Record completeness
    /// is enforced by the contiguous sequence check in `receiveFrame`; WHOOP
    /// 4 HISTORY_END does not carry a batch packet count.
    mutating func historyEnd(
        generation eventGeneration: UInt64,
        boundaryID: String,
        ackPayload: [UInt8]
    ) -> [Effect] {
        guard accepts(eventGeneration), !boundaryID.isEmpty else { return [] }
        if acknowledgedBoundaryIDs.contains(boundaryID) { return [] }

        switch phase {
        case .listening:
            if pendingFrameKeys.isEmpty {
                phase = .waitingForBatchFlush(boundaryID: boundaryID, ackPayload: ackPayload)
                return [.durableFlush(
                    generation: eventGeneration,
                    boundary: .batch(boundaryID)
                )]
            }
            phase = .waitingForBatchPersistence(boundaryID: boundaryID, ackPayload: ackPayload)
            return []
        case .waitingForBatchPersistence(let activeID, let activePayload),
             .waitingForBatchFlush(let activeID, let activePayload),
             .waitingForACK(let activeID, let activePayload, _):
            guard activeID == boundaryID, activePayload == ackPayload else {
                return fail(.protocolViolation("overlapping_history_end"))
            }
            return []
        default:
            return []
        }
    }

    mutating func durableFlushCompleted(
        generation eventGeneration: UInt64,
        boundary: FlushBoundary,
        succeeded: Bool
    ) -> [Effect] {
        guard accepts(eventGeneration) else { return [] }
        guard succeeded else {
            return fail(.durableFlush(boundary: boundary))
        }

        switch phase {
        case .waitingForBatchFlush(let boundaryID, let ackPayload)
            where boundary == .batch(boundaryID):
            phase = .waitingForACK(
                boundaryID: boundaryID,
                ackPayload: ackPayload,
                attempt: 1
            )
            return [.sendACK(
                generation: eventGeneration,
                boundaryID: boundaryID,
                payload: ackPayload,
                attempt: 1
            )]
        case .waitingForTerminalFlush(let expectedBoundary)
            where boundary == expectedBoundary:
            return finish()
        default:
            return []
        }
    }

    /// Completes one ACK write-with-response. A failed write retries the same
    /// payload up to `maximumACKAttempts`; exhausting the budget fails closed.
    mutating func ackCompleted(
        generation eventGeneration: UInt64,
        boundaryID: String,
        succeeded: Bool
    ) -> [Effect] {
        guard accepts(eventGeneration) else { return [] }
        guard case .waitingForACK(let activeID, let payload, let attempt) = phase,
              activeID == boundaryID else { return [] }

        if !succeeded {
            guard attempt < maximumACKAttempts else {
                return fail(.ack(boundaryID: boundaryID, attempts: attempt))
            }
            let nextAttempt = attempt + 1
            phase = .waitingForACK(
                boundaryID: boundaryID,
                ackPayload: payload,
                attempt: nextAttempt
            )
            return [.sendACK(
                generation: eventGeneration,
                boundaryID: boundaryID,
                payload: payload,
                attempt: nextAttempt
            )]
        }

        acknowledgedBoundaryIDs.insert(boundaryID)
        acknowledgedBatchCount += 1
        currentBatchNumber += 1
        currentBatchFrameCount = 0
        pendingFrameKeys.removeAll(keepingCapacity: true)
        if terminalAfterCurrentBatch {
            return finish()
        }
        phase = .listening
        return []
    }

    /// Handles HISTORY_COMPLETE. A non-empty unsealed tail is persisted and
    /// durably flushed without an ACK. An empty terminal has no undurable state
    /// and may complete immediately.
    mutating func historyComplete(generation eventGeneration: UInt64) -> [Effect] {
        guard accepts(eventGeneration) else { return [] }
        terminalWasReceived = true

        switch phase {
        case .listening:
            guard currentBatchFrameCount > 0 else { return finish() }
            let boundary = FlushBoundary.terminal(currentBatchNumber)
            if pendingFrameKeys.isEmpty {
                phase = .waitingForTerminalFlush(boundary: boundary)
                return [.durableFlush(generation: eventGeneration, boundary: boundary)]
            }
            phase = .waitingForTerminalPersistence(boundary: boundary)
            return []
        case .waitingForBatchPersistence, .waitingForBatchFlush, .waitingForACK:
            terminalAfterCurrentBatch = true
            return []
        case .waitingForTerminalPersistence, .waitingForTerminalFlush:
            return []
        case .idle, .finished, .failed:
            return []
        }
    }

    private func accepts(_ eventGeneration: UInt64) -> Bool {
        generation == eventGeneration && failure == nil && !isFinished
    }

    private mutating func rememberConfirmedForwardDiscontinuity(
        _ transition: ForwardDiscontinuity
    ) {
        guard !confirmedForwardDiscontinuities.contains(transition) else { return }
        confirmedForwardDiscontinuities.append(transition)
        if confirmedForwardDiscontinuities.count > Self.maximumConfirmedForwardDiscontinuities {
            confirmedForwardDiscontinuities.removeFirst(
                confirmedForwardDiscontinuities.count - Self.maximumConfirmedForwardDiscontinuities
            )
        }
    }

    /// WHOOP 4 historical record sequence at inner payload offsets 3..<5.
    /// The value wraps naturally at UInt16.max. Non-0x2f synthetic/test
    /// payloads have no transport sequence and are left to identity dedupe.
    private static func historicalSequence(from payload: [UInt8]) -> HistoricalSequenceObservation? {
        guard payload.count >= 5, payload[0] == 0x2f else { return nil }
        return HistoricalSequenceObservation(
            streamKey: (UInt16(payload[1]) << 8) | UInt16(payload[2]),
            sequence: UInt16(payload[3]) | (UInt16(payload[4]) << 8)
        )
    }

    private mutating func finish() -> [Effect] {
        guard let generation else { return [] }
        phase = .finished
        pendingFrameKeys.removeAll(keepingCapacity: false)
        classifiedIdentityCount = 0
        acknowledgedBoundaryIDs.removeAll(keepingCapacity: false)
        return [.finished(generation: generation)]
    }

    private mutating func fail(_ failure: Failure) -> [Effect] {
        guard let generation, self.failure == nil, !isFinished else { return [] }
        failureOriginPhaseForDiagnostics = Self.phaseLabel(phase)
        failurePendingPersistenceCountForDiagnostics = pendingFrameKeys.count
        phase = .failed(failure)
        pendingFrameKeys.removeAll(keepingCapacity: false)
        classifiedIdentityCount = 0
        acknowledgedBoundaryIDs.removeAll(keepingCapacity: false)
        return [.failed(generation: generation, failure: failure)]
    }
}
