import Foundation

/// Read-only WHOOP 4 ring-buffer cursor observation returned by
/// GET_DATA_RANGE (0x22/00). These offsets are relative to the decoded command
/// response payload `[24,responseSeq,22,requestSeq,data...]` and mirror the
/// physically verified W/U/T layout. The observation never authorizes a trim,
/// acknowledgement, rewind, or local gap deletion.
/// Handoff-9 CP2: the exact durable evidence of ONE finished history slice,
/// persisted only from the final durable boundary of its generation. This is
/// the sole permission for the fast (60 s) connected retry cadence — a
/// received frame is not progress; only a durably advanced frontier is.
struct AtriaHistoricalDurableProductiveSliceReceipt: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        /// Handoff-10 CP2B: written at slice START, before any terminal is
        /// known. A surviving `.started` row after relaunch proves a prior
        /// process died mid-slice — it re-arms scheduling only, and never
        /// implies ACK, durable persistence, prefix retirement, or success.
        case started
        case productive
        case noProgress
        case failed
    }

    let generation: UInt64
    let attemptStartedAtUnix: Double
    let startFrontierUnix: Double
    let endFrontierUnix: Double
    let durableRowsDelta: Int
    /// Identity of the boundary this receipt was minted from (the published
    /// completion status of the exact durable/live-restored terminal).
    let flushBoundaryIdentity: String
    let liveRestoredAtUnix: Double?
    let gapFingerprint: String?
    let status: Status
    let recordedAtUnix: Double
    /// Process-lifetime identity of the writer (handoff-10 CP2B). A `.started`
    /// row from the CURRENT process is an in-flight slice, not an orphan.
    var processInstanceID: String? = nil

    /// True when this receipt proves a prior process started a slice and died
    /// before writing any terminal — the one condition that re-arms catch-up
    /// scheduling after relaunch without foreground help.
    func isOrphanedStart(currentProcessInstanceID: String) -> Bool {
        status == .started && processInstanceID != currentProcessInstanceID
    }
}

struct AtriaWhoop4HistoryCursorRange: Equatable, Sendable {
    let responseSequence: UInt8
    let requestSequenceEcho: UInt8
    let writeCursor: UInt32
    let readCursor: UInt32
    let capacity: UInt32
    let pendingRecords: UInt32
    /// Current strap Unix time carried by the physically verified 22/00
    /// response. WHOOP 4 places it at bytes 62...65 of the decoded command
    /// response (little-endian). Short legacy observations remain parseable but
    /// cannot become production clock authority.
    let deviceUnix: UInt32?

    static func parseCommandResponse(_ payload: [UInt8]) -> Self? {
        guard payload.count >= 30,
              payload[0] == 0x24,
              payload[2] == 0x22 else { return nil }
        let data = Array(payload.dropFirst(4))
        guard data.count >= 26 else { return nil }
        func u32(_ offset: Int) -> UInt32 {
            UInt32(data[offset])
                | (UInt32(data[offset + 1]) << 8)
                | (UInt32(data[offset + 2]) << 16)
                | (UInt32(data[offset + 3]) << 24)
        }
        let write = u32(10)
        let read = u32(14)
        let capacity = u32(22)
        guard capacity >= 1_024,
              capacity <= 1_048_576,
              write < capacity,
              read < capacity else { return nil }
        let pending = write >= read
            ? write - read
            : write + (capacity - read)
        return .init(
            responseSequence: payload[1],
            requestSequenceEcho: payload[3],
            writeCursor: write,
            readCursor: read,
            capacity: capacity,
            pendingRecords: pending,
            deviceUnix: payload.count >= 66 ? u32(58) : nil
        )
    }
}

/// Strap GET_DATA_RANGE (0x22) ring cursors captured around persist-before-ACK.
/// Display `drainedThroughUnix` is not this pointer.
struct AtriaWhoop4HistoryRangePointerSnapshot: Equatable, Sendable {
    let writeCursor: UInt32
    let readCursor: UInt32
    let pendingRecords: UInt32
}

enum AtriaWhoop4HistoryRangePointerDisposition: String, Equatable, Sendable {
    case pointerAdvanced
    case sameWindowReserve
    case strapCaughtUp
    case inconclusive
}

extension AtriaWhoop4HistoryRangePointerSnapshot {
    init(_ range: AtriaWhoop4HistoryCursorRange) {
        self.init(
            writeCursor: range.writeCursor,
            readCursor: range.readCursor,
            pendingRecords: range.pendingRecords
        )
    }
}

enum AtriaWhoop4HistoryRangePointerPolicy {
    /// Classify whether ACK moved the strap read pointer. `pending` falling
    /// is consume; a moved read cursor is also consume (write can grow
    /// faster than one ACK'd page). Unchanged pending+read is the same
    /// oldest window.
    /// Soak 15:50→15:52: read 67683→67688, pending 11690→11698 because
    /// write grew +13 while read moved +5 — still ACK consume, not re-serve.
    static func disposition(
        beforeACK: AtriaWhoop4HistoryRangePointerSnapshot?,
        afterACK: AtriaWhoop4HistoryRangePointerSnapshot?
    ) -> AtriaWhoop4HistoryRangePointerDisposition {
        guard let beforeACK, let afterACK else { return .inconclusive }
        if afterACK.pendingRecords == 0,
           afterACK.readCursor == afterACK.writeCursor {
            return .strapCaughtUp
        }
        if afterACK.pendingRecords < beforeACK.pendingRecords {
            return .pointerAdvanced
        }
        if afterACK.readCursor != beforeACK.readCursor {
            return .pointerAdvanced
        }
        if afterACK.readCursor == beforeACK.readCursor,
           afterACK.pendingRecords >= beforeACK.pendingRecords {
            return .sameWindowReserve
        }
        return .inconclusive
    }

    static func servedPagesAreSameWindow(
        previousMin: UInt32?,
        previousMax: UInt32?,
        currentMin: UInt32?,
        currentMax: UInt32?
    ) -> Bool {
        guard let previousMin, let previousMax,
              let currentMin, let currentMax else {
            return false
        }
        return previousMin == currentMin && previousMax == currentMax
    }

    /// Intra-slice GET_DATA_RANGE after ACK is device-proven unanswered.
    /// Soak 15:50/15:52: stream5 quiet, 0x22 WR-confirmed, no cmdResp for
    /// ~16s. Cross-slice 0x22 is the after-ACK snapshot. Do not stall 2A37.
    static func shouldIssueIdleWindowPostACKRangeProbe(
        idleWindowDrainOwnsLink: Bool,
        acknowledgedPages: Int,
        postACKProbeAlreadyIssued: Bool
    ) -> Bool {
        _ = (idleWindowDrainOwnsLink, acknowledgedPages, postACKProbeAlreadyIssued)
        return false
    }

    /// Consume-to-now / BLE clear is never auto. Consent plus a proven
    /// pointer-advance or empty ring is required; anything else is a no-op.
    static func shouldSelectHistoryConsumeOrClear(
        pointerDisposition: AtriaWhoop4HistoryRangePointerDisposition,
        explicitConsent: Bool
    ) -> Bool {
        guard explicitConsent else { return false }
        switch pointerDisposition {
        case .pointerAdvanced, .strapCaughtUp:
            return true
        case .sameWindowReserve, .inconclusive:
            return false
        }
    }

    /// Official WHOOP 4 erase-device wire capture (0x19 FE×8 + 00). M0
    /// proved ACK advances the read pointer; consume-to-now therefore
    /// walks pages instead of FORCE_TRIM. Keep this predicate false so
    /// the consented flag cannot fire 0x19 until a later device proof.
    static func shouldIssueIdleWindowForceTrim(
        idleWindowDrainOwnsLink: Bool,
        heartRateNotifying: Bool,
        consumeConsent: Bool,
        pointerDisposition: AtriaWhoop4HistoryRangePointerDisposition,
        alreadyIssued: Bool
    ) -> Bool {
        _ = (idleWindowDrainOwnsLink, heartRateNotifying, consumeConsent,
             pointerDisposition, alreadyIssued)
        return false
    }

    /// Start-fresh only after the strap itself reports an empty ring.
    static func shouldReconcileStartFreshAfterVerifiedStrapZero(
        pendingRecords: UInt32,
        readCursor: UInt32,
        writeCursor: UInt32,
        consumeConsent: Bool
    ) -> Bool {
        consumeConsent
            && pendingRecords == 0
            && readCursor == writeCursor
    }
}

/// Pure ordering and clock checks for the production WHOOP 4 bootstrap proven
/// on the physical strap. This grants full-drain transport/clock evidence only;
/// it never represents an exact-range selector or gap-completion authority.
enum AtriaWhoop4ProductionHistoryBootstrapPolicy {
    struct ClockAuthority: Equatable, Sendable {
        let deviceUnix: UInt32
        let wallUnix: UInt32
        let driftSeconds: Int
    }

    static let postRangeResponseSettle: TimeInterval = 2
    static let rangeWriteConfirmationTimeout: TimeInterval = 45
    static let maximumClockDrift: TimeInterval = 24 * 60 * 60

    static func validatedClockAuthority(
        range: AtriaWhoop4HistoryCursorRange,
        responseWallUnix: TimeInterval
    ) -> ClockAuthority? {
        guard let deviceUnix = range.deviceUnix,
              deviceUnix > 0,
              responseWallUnix.isFinite,
              responseWallUnix > 0,
              responseWallUnix <= TimeInterval(UInt32.max) else { return nil }
        let wallUnix = UInt32(responseWallUnix.rounded())
        let drift = Int(wallUnix) - Int(deviceUnix)
        guard abs(TimeInterval(drift)) <= maximumClockDrift else { return nil }
        return .init(deviceUnix: deviceUnix,
                     wallUnix: wallUnix,
                     driftSeconds: drift)
    }

    static func hasCompletedPostResponseSettle(
        responseUptime: TimeInterval,
        nowUptime: TimeInterval
    ) -> Bool {
        responseUptime.isFinite
            && nowUptime.isFinite
            && responseUptime >= 0
            && nowUptime >= responseUptime
            && nowUptime - responseUptime >= postRangeResponseSettle
    }
}

/// Pure admission and completion policy for WHOOP historical recovery.
///
/// Keeping these decisions outside the stateful CoreBluetooth manager makes
/// their fail-closed behavior independently reviewable while preserving the
/// existing `AtriaBLEManager` API used by runtime call sites and tests.
extension AtriaBLEManager {
    struct TerminalConsumerRawFirstSliceOrchestrationState:
        Equatable, Sendable
    {
        let authorityIdentifier: String
        let deadline: Date
        var rawGeneration: UInt64?
        var spent: Bool
    }

    enum TerminalConsumerRawFirstSliceOrchestrationEvent:
        Equatable, Sendable
    {
        case bindRawGeneration(UInt64)
        case finishRawGeneration(UInt64)
        case deadlineReached(Date)
    }

    struct TerminalConsumerRawFirstSliceOrchestrationTransition:
        Equatable, Sendable
    {
        let state: TerminalConsumerRawFirstSliceOrchestrationState
        let shouldResumeLocalMaterialization: Bool
    }

    /// Pure state transition for the one-shot raw-first scheduling lease.
    /// Binding never spends the lease, only the exact bound generation may
    /// spend it at a slice boundary, and the absolute deadline always fails
    /// open so a stalled raw lane cannot retain local publication forever.
    nonisolated static func transitionTerminalConsumerRawFirstSlice(
        state: TerminalConsumerRawFirstSliceOrchestrationState,
        event: TerminalConsumerRawFirstSliceOrchestrationEvent
    ) -> TerminalConsumerRawFirstSliceOrchestrationTransition {
        var next = state
        switch event {
        case .bindRawGeneration(let generation):
            guard !next.spent, next.rawGeneration == nil else {
                return .init(
                    state: next,
                    shouldResumeLocalMaterialization: false
                )
            }
            next.rawGeneration = generation
        case .finishRawGeneration(let generation):
            guard !next.spent, next.rawGeneration == generation else {
                return .init(
                    state: next,
                    shouldResumeLocalMaterialization: false
                )
            }
            next.spent = true
            return .init(
                state: next,
                shouldResumeLocalMaterialization: true
            )
        case .deadlineReached(let now):
            guard !next.spent, now >= next.deadline else {
                return .init(
                    state: next,
                    shouldResumeLocalMaterialization: false
                )
            }
            next.spent = true
            return .init(
                state: next,
                shouldResumeLocalMaterialization: true
            )
        }
        return .init(
            state: next,
            shouldResumeLocalMaterialization: false
        )
    }

    /// A deliberate force request may move history onto one fresh connection,
    /// but ordinary/aged recovery must never manufacture a live-link cutover.
    /// The caller still has to durably close the live journal boundary before
    /// cancelling the connected peripheral.
    nonisolated static func shouldUseFreshHistoryOwnerCutover(
        linkConnected: Bool,
        force: Bool,
        explicitRequest: Bool,
        activeExplicitWorkout: Bool,
        cutoverAlreadyPending: Bool
    ) -> Bool {
        linkConnected
            && force
            && explicitRequest
            && !activeExplicitWorkout
            && !cutoverAlreadyPending
    }

    /// Onboarding needs one encrypted, read-only command to verify proprietary
    /// strap access. Standard HR can flow without that bond, so fresh 2A37 data
    /// must not suppress this check. This permission never grants history
    /// ownership or completion.
    nonisolated static func shouldAttemptOnboardingPairingPreflight(
        linkConnected: Bool,
        currentConnectionHasFreshHeartRate: Bool,
        activeExplicitWorkout: Bool,
        historyTransportActive: Bool,
        freshHistoryOwnerCutoverPending: Bool,
        preflightInFlight: Bool,
        alreadyAttemptedForConnection: Bool
    ) -> Bool {
        _ = currentConnectionHasFreshHeartRate
        return linkConnected
            && !activeExplicitWorkout
            && !historyTransportActive
            && !freshHistoryOwnerCutoverPending
            && !preflightInFlight
            && !alreadyAttemptedForConnection
    }

    nonisolated static func supportsVerifiedHistoricalRecovery(
        model: AtriaStrapModel,
        previouslyVerified: Bool
    ) -> Bool {
        previouslyVerified || model == .strap4 || model == .strap4Class
    }

    /// Decoder support is not recovery support. This capability says only that
    /// a raw WHOOP 4 frame can be interpreted with a reference-validated metric
    /// layout. It does not say that production can request the missing interval
    /// or establish the clock authority required to retire a durable gap.
    nonisolated static func supportsDecodedHistoricalMetricLayout(
        model: AtriaStrapModel,
        previouslyVerified: Bool,
        hasValidatedMetricLayout: Bool = HistoricalArchive.hasValidatedMetricLayout
    ) -> Bool {
        supportsVerifiedHistoricalRecovery(
            model: model,
            previouslyVerified: previouslyVerified
        ) && hasValidatedMetricLayout
    }

    /// Exact-range selection remains research-only. Production WHOOP 4 repair
    /// uses a complete flash drain and filters positive decoded timestamps to
    /// one already-known local gap under the durable full-drain authority.
    nonisolated static let productionHistoricalExactRangeTransportEnabledAndProven = false
    nonisolated static let productionHistoricalClockAuthorityEnabledAndProven = true
    nonisolated static let productionHistoricalFullDrainGapRecoveryEnabled =
        AtriaHistoricalFullDrainCoverageIntegration.automaticFullDrainRecoveryEnabled

    nonisolated static func supportsVerifiedHistoricalTransactionRecovery(
        model: AtriaStrapModel,
        previouslyVerified: Bool,
        hasValidatedMetricLayout: Bool = HistoricalArchive.hasValidatedMetricLayout,
        fullDrainGapRecoveryEnabled: Bool
    ) -> Bool {
        supportsDecodedHistoricalMetricLayout(
            model: model,
            previouslyVerified: previouslyVerified,
            hasValidatedMetricLayout: hasValidatedMetricLayout
        ) && fullDrainGapRecoveryEnabled
    }

    nonisolated static func supportsVerifiedHistoricalTransactionRecovery(
        model: AtriaStrapModel,
        previouslyVerified: Bool,
        hasValidatedMetricLayout: Bool = HistoricalArchive.hasValidatedMetricLayout,
        exactRangeTransportEnabledAndProven: Bool,
        clockAuthorityEnabledAndProven: Bool
    ) -> Bool {
        // Retained for the isolated exact-selector harness. Automatic runtime
        // call sites use the full-drain overload above.
        supportsDecodedHistoricalMetricLayout(
            model: model,
            previouslyVerified: previouslyVerified,
            hasValidatedMetricLayout: hasValidatedMetricLayout
        )
            && exactRangeTransportEnabledAndProven
            && clockAuthorityEnabledAndProven
    }

    /// A restored protected-HR connection may expose only the standard HR and
    /// battery services. In that state `strapModel` remains unknown forever,
    /// while the pending-history gate waits for a verified WHOOP 4 class: a
    /// launch-order deadlock. Permit one read-only service discovery to resolve
    /// the hardware class. This does not discover characteristics, mutate a
    /// CCCD, send a proprietary command, or authorize recovery by itself.
    nonisolated static func shouldQualifyPendingHistoryByServiceDiscovery(
        exactGapPending: Bool,
        verifiedHistoryCapability: Bool,
        model: AtriaStrapModel,
        linkConnected: Bool,
        activeExplicitWorkout: Bool,
        syncInProgress: Bool
    ) -> Bool {
        exactGapPending
            && !verifiedHistoryCapability
            && model == .unknown
            && linkConnected
            && !activeExplicitWorkout
            && !syncInProgress
    }

    nonisolated static func historicalSyncCompletionStatus(
        newRows: Int,
        requestedWindowMetricProgress: Bool,
        ledgerCoverageResolved: Bool,
        hasValidatedMetricLayout: Bool = HistoricalArchive.hasValidatedMetricLayout
    ) -> String {
        guard newRows > 0 else { return "no_rows" }
        if ledgerCoverageResolved { return "gap_recovered" }
        if requestedWindowMetricProgress { return "metric_progress" }
        return hasValidatedMetricLayout
            ? "archived_gap_unresolved"
            : "raw_archived_metric_unverified"
    }

    /// A verified historical transaction that reached its terminal state,
    /// restored live collection, and still yielded no new durable rows has
    /// established negative evidence for its *exact* durable gap set. Keep the
    /// gap visible for diagnostics and manual retry, but suppress only the
    /// automatic path for that unchanged fingerprint. A new closed interval
    /// necessarily changes the fingerprint and becomes eligible again.
    nonisolated static func shouldSuppressAutomaticHistoricalNoRowsRetry(
        exactGapPending: Bool,
        explicitUserRequest: Bool,
        currentGapFingerprint: String?,
        noRowsGapFingerprint: String?
    ) -> Bool {
        exactGapPending
            && !explicitUserRequest
            && currentGapFingerprint != nil
            && currentGapFingerprint == noRowsGapFingerprint
    }

    /// A history-start timeout after the command write was confirmed is weaker
    /// than a terminal no-rows response: the strap may still hold the data.
    /// Keep the exact durable gap visible and preserve manual retry, but do not
    /// repeatedly take the live BLE owner for the identical failed automatic
    /// handoff. A changed gap fingerprint gets one new automatic opportunity.
    nonisolated static func shouldSuppressAutomaticHistoryStartTimeoutRetry(
        exactGapPending: Bool,
        explicitUserRequest: Bool,
        currentGapFingerprint: String?,
        historyStartTimeoutGapFingerprint: String?
    ) -> Bool {
        exactGapPending
            && !explicitUserRequest
            && currentGapFingerprint != nil
            && currentGapFingerprint == historyStartTimeoutGapFingerprint
    }

    /// One flash discontinuity that never passes the two-generation replay
    /// proof (`history_sequence_gap_unconfirmed_…` on first observation,
    /// `history_sequence_gap_replay_mismatch_…` on every retry) gets this
    /// many automatic drain attempts per exact gap fingerprint before the
    /// ticket parks as a terminal unavailable interval.
    nonisolated static let historySequenceGapAttemptBudget = 6

    nonisolated static func isHistorySequenceGapFailureDetail(
        _ detail: String
    ) -> Bool {
        detail.contains("history_sequence_gap_")
    }

    /// Per-fingerprint attempt accounting: the same gap set increments, a
    /// changed gap set starts over at one. Parking triggers at the budget.
    nonisolated static func historySequenceGapAttemptAccounting(
        storedFingerprint: String?,
        storedAttempts: Int,
        currentFingerprint: String,
        budget: Int = historySequenceGapAttemptBudget
    ) -> (attempts: Int, parked: Bool) {
        let attempts = storedFingerprint == currentFingerprint
            ? max(0, storedAttempts) + 1
            : 1
        return (attempts, attempts >= budget)
    }

    /// True while the automatic lane must stay quiet for a terminally parked
    /// sequence-gap ticket. Suppression requires the exact parked fingerprint
    /// to still describe the pending gap; a changed fingerprint (new strap
    /// evidence closed or opened windows) or a drained frontier that moved
    /// materially past the parked frontier disarms it — those are the only
    /// automatic paths back to one fresh attempt. Explicit user repair is
    /// never suppressed.
    nonisolated static func shouldSuppressAutomaticSequenceGapRetry(
        exactGapPending: Bool,
        explicitUserRequest: Bool,
        currentGapFingerprint: String?,
        parkedGapFingerprint: String?,
        parkedFrontierUnix: Double?,
        currentFrontierUnix: Double?,
        minimumFrontierAdvance: TimeInterval = 60 * 60
    ) -> Bool {
        guard exactGapPending,
              !explicitUserRequest,
              let currentGapFingerprint,
              parkedGapFingerprint != nil,
              currentGapFingerprint == parkedGapFingerprint else { return false }
        if let parkedFrontierUnix,
           let currentFrontierUnix,
           currentFrontierUnix - parkedFrontierUnix >= minimumFrontierAdvance {
            return false
        }
        return true
    }

    /// Migrates an install that recorded the pre-circuit-breaker timeout but
    /// did not yet persist its exact-gap marker. All timestamps must describe
    /// the same short history-owner epoch; the current newest closed gap must
    /// predate that epoch so an unrelated later loss is never suppressed.
    nonisolated static func shouldMigrateHistoryStartTimeoutCircuitBreaker(
        lastAppCancelReason: String?,
        lastAppCancelAtUnix: Double,
        handshakeStatus: String?,
        handshakeAtUnix: Double,
        backfillStartedAtUnix: Double,
        newestClosedGapEndUnix: Double?
    ) -> Bool {
        guard lastAppCancelReason == "history_start_timeout_transport_reset",
              handshakeStatus == "full_drain_write_confirmed",
              lastAppCancelAtUnix > 0,
              handshakeAtUnix > 0,
              backfillStartedAtUnix > 0,
              handshakeAtUnix >= backfillStartedAtUnix,
              lastAppCancelAtUnix >= handshakeAtUnix,
              lastAppCancelAtUnix - backfillStartedAtUnix <= 5 * 60 else {
            return false
        }
        return newestClosedGapEndUnix.map { $0 <= backfillStartedAtUnix } ?? true
    }

    /// Even before a historical payload layout is metric-validated, a natural
    /// disconnect is a safe opportunity to copy the strap's raw backlog. This
    /// never promotes HR/RR, never interrupts a connected realtime pipe, and
    /// runs at most once for the exact durable gap set. A later decoder can then
    /// repair that interval from locally archived evidence instead of asking a
    /// finite strap buffer for the same data indefinitely.
    nonisolated static func shouldAttemptRawOnlyHistoricalRecovery(
        exactGapPending: Bool,
        rawHistoryVerified: Bool,
        metricHistoryVerified: Bool,
        linkConnected: Bool,
        activeExplicitWorkout: Bool,
        explicitUserRequest: Bool,
        rawGapAlreadyArchived: Bool
    ) -> Bool {
        exactGapPending
            && rawHistoryVerified
            && !metricHistoryVerified
            && !linkConnected
            && !activeExplicitWorkout
            && !explicitUserRequest
            && !rawGapAlreadyArchived
    }

    nonisolated static func historicalGapFingerprint(
        _ windows: [AtriaHistoricalGapLedger.Window]
    ) -> String? {
        guard !windows.isEmpty else { return nil }
        return windows
            .sorted { lhs, rhs in
                if lhs.start != rhs.start { return lhs.start < rhs.start }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            .map { window in
                let start = Int64((window.start.timeIntervalSince1970 * 1_000).rounded())
                let end = window.end.map {
                    Int64(($0.timeIntervalSince1970 * 1_000).rounded())
                } ?? -1
                return "\(window.id.uuidString):\(start):\(end)"
            }
            .joined(separator: "|")
    }

    /// Older installs can carry the durable range-loss request before the
    /// per-gap ledger was introduced. Give that finite requested interval the
    /// same one-shot raw archive semantics instead of re-pulling it after every
    /// natural disconnect.
    nonisolated static func historicalGapFingerprint(
        windows: [AtriaHistoricalGapLedger.Window],
        recoveryStart: Date?,
        recoveryEnd: Date?,
        requestedAt: Double?
    ) -> String? {
        if let ledgerFingerprint = historicalGapFingerprint(windows) {
            return ledgerFingerprint
        }
        guard recoveryStart != nil || recoveryEnd != nil || requestedAt != nil else {
            return nil
        }
        let start = recoveryStart.map {
            Int64(($0.timeIntervalSince1970 * 1_000).rounded())
        } ?? -1
        let end = recoveryEnd.map {
            Int64(($0.timeIntervalSince1970 * 1_000).rounded())
        } ?? -1
        let requested = requestedAt.map {
            Int64(($0 * 1_000).rounded())
        } ?? -1
        return "legacy:\(start):\(end):\(requested)"
    }

    /// A full history dump cannot certify an arbitrary locally-selected gap.
    /// Both facts must come from a verified protocol path before the durable
    /// exact authority store is reachable.
    nonisolated static func shouldBindExactHistoricalRequestAuthority(
        exactRangeWasEncodedAndTransmitted: Bool,
        acceptedResponseDurablyTiedToAttempt: Bool
    ) -> Bool {
        exactRangeWasEncodedAndTransmitted
            && acceptedResponseDurablyTiedToAttempt
    }

    nonisolated static func shouldScheduleStaleRangeLossReconciliation(
        inFlight: Bool,
        lastAttemptAt: Date?,
        now: Date,
        minimumInterval: TimeInterval
    ) -> Bool {
        guard !inFlight else { return false }
        guard let lastAttemptAt else { return true }
        return now.timeIntervalSince(lastAttemptAt) >= minimumInterval
    }

    nonisolated static func shouldDeferOfflineSyncForExplicitWorkout(
        activeExplicitWorkout: Bool
    ) -> Bool {
        activeExplicitWorkout
    }

    nonisolated static func isExplicitUserOfflineSyncReason(_ reason: String) -> Bool {
        reason == "manual_user_request"
    }

    /// The exact-recovery fence refuses to START a history transport while the
    /// non-convergent full-flash gap recovery stays retired. Its purpose is to
    /// keep autonomous lanes from replaying old flash rows as fake "gap
    /// recovery" — not to strand the user's own Sync tap. 2026-08-07 (3 AM
    /// soak): with no authority draining, the fence refused even Settings →
    /// "Sync missed data from strap" (`gap_retained_exact_recovery_unproven`)
    /// while the identical cursor-anchored chunked catch-up was admitted from
    /// the scene-background lane minutes later. An attended request with a
    /// real strap backlog admits the same forward-from-cursor catch-up the
    /// background lanes run; every downstream guard (workout, storm,
    /// archive-warm, admission ledger) still applies.
    nonisolated static func shouldRefuseUnprovenExactRecoveryStart(
        fullDrainGapRecoveryEnabled: Bool,
        syncInProgress: Bool,
        resumingPersistedDrainAuthority: Bool,
        attendedSelectorSeekTrial: Bool,
        attendedGate2FullDrainProof: Bool,
        explicitPostWorkoutBankRequest: Bool,
        attendedUserRequest: Bool,
        strapBacklogPending: Bool,
        autonomousBackgroundCatchUp: Bool = false
    ) -> Bool {
        if fullDrainGapRecoveryEnabled
            || syncInProgress
            || resumingPersistedDrainAuthority
            || attendedSelectorSeekTrial
            || attendedGate2FullDrainProof
            || explicitPostWorkoutBankRequest {
            return false
        }
        if attendedUserRequest && strapBacklogPending {
            return false
        }
        if autonomousBackgroundCatchUp {
            return false
        }
        return true
    }

    /// Step 1 of the strap-only cutover re-engineering (2026-08-22 user decision):
    /// the ONLY safe window to drain flash history on a WHOOP4 that shares one link
    /// between live 2A37/R10 and history is a moment when there is NO healthy live
    /// epoch to protect — i.e. the strap has just naturally dropped its own link, or
    /// the current epoch is provably idle/ending. The Build-5 soak proved that
    /// seizing the link from a HEALTHY epoch cancels live HR; this predicate makes
    /// that failure un-bypassable by requiring `!healthyLiveEpochActive` as a hard
    /// precondition, never a soft preference. It authorizes at most a bounded,
    /// ACK-cursor-advancing history chunk on a reconnect that follows a natural gap;
    /// live HR remains the highest-priority owner the instant it re-establishes.
    ///
    /// Pure/testable: it decides eligibility only. The caller still binds the
    /// generation/peripheral authority, bounds the chunk, and restores realtime.
    nonisolated static func shouldDrainHistoryDuringNaturalGap(
        retainedExplicitHistoryRequest: Bool,
        strapBacklogPending: Bool,
        priorEpochEndedNaturally: Bool,
        healthyLiveEpochActive: Bool,
        explicitMotionOwnershipActive: Bool,
        thermalParked: Bool
    ) -> Bool {
        // The invariant that protects live HR: never drain while a healthy live
        // epoch is transmitting. This is checked first and unconditionally.
        guard !healthyLiveEpochActive else { return false }
        guard !explicitMotionOwnershipActive, !thermalParked else { return false }
        return retainedExplicitHistoryRequest
            && strapBacklogPending
            && priorEpochEndedNaturally
    }

    /// Flag-gated stop-realtime history drain that may pause 2A37 only where
    /// there is no live HR to protect. Unflagged default builds never select a
    /// window. A healthy attended (foreground) epoch is never selected unless
    /// the strap itself is charging or off-wrist — those states have no live HR
    /// to seize. Device soak 2026-08-23: production already sends 0x22 first and
    /// still yields `stream5_rx=0` then `ble_disconnect` ~13s while 2A37 stays
    /// subscribed, so this path pauses notify on the same connection instead of
    /// `cancelPeripheralConnection`.
    nonisolated static let idleWindowHistoryDrainEnableArgument =
        "--atria-idle-window-drain-enable"

    enum IdleWindowHistoryDrainWindow: String, Equatable, Sendable {
        case none
        case strapCharging
        case strapOffWrist
        case appBackgroundIdle
        case naturalGapPreHR
    }

    nonisolated static func selectedIdleWindowHistoryDrain(
        launchFlagEnabled: Bool,
        strapBacklogPending: Bool,
        strapIsCharging: Bool,
        strapOffWrist: Bool,
        appBackgrounded: Bool,
        priorEpochEndedNaturally: Bool,
        healthyLiveEpochActive: Bool,
        attendedForeground: Bool,
        explicitMotionOwnershipActive: Bool,
        thermalParked: Bool,
        consumeToNow: Bool = false,
        lastPendingRecords: UInt32? = nil
    ) -> IdleWindowHistoryDrainWindow {
        let consumeLiveTail = shouldTreatConsumeLiveTailAsBacklog(
            consumeToNow: consumeToNow,
            lastPendingRecords: lastPendingRecords
        )
        guard launchFlagEnabled, strapBacklogPending || consumeLiveTail else {
            return .none
        }
        guard !explicitMotionOwnershipActive, !thermalParked else { return .none }
        _ = priorEpochEndedNaturally
        // Strap on charger / off-wrist: firmware is not producing a live pulse
        // to protect even if the epoch fence is owned by the connected link.
        if strapIsCharging { return .strapCharging }
        if strapOffWrist && !healthyLiveEpochActive { return .strapOffWrist }
        // Consented ACK-consume-to-now may re-pause 2A37 after the resume
        // interval so later slices keep walking. Unconsented builds still
        // never seize a healthy attended epoch.
        if consumeToNow {
            return healthyLiveEpochActive ? .appBackgroundIdle : .naturalGapPreHR
        }
        // Build-5 contract: never cancel a healthy attended epoch.
        if healthyLiveEpochActive && attendedForeground { return .none }
        // Pre-HR (didConnect, first-HR race, natural gap): no live pulse yet.
        // 2026-08-23 04:27 recapture never armed because didConnect health is
        // false but this predicate previously required a prior natural drop.
        if !healthyLiveEpochActive { return .naturalGapPreHR }
        if appBackgrounded { return .appBackgroundIdle }
        return .none
    }

    /// Kill switch for the now-default idle-window drain. The enable
    /// argument stays accepted so existing soak scripts keep working, but a
    /// stock home-screen launch carries no arguments at all — which is why
    /// the flag-gated build showed "Strap steps --" for a full day while the
    /// drain never selected a window (device 2026-08-24 19:29).
    nonisolated static let idleWindowHistoryDrainDisableArgument =
        "--atria-idle-window-drain-disable"

    nonisolated static func idleWindowHistoryDrainIsEnabled(
        arguments: [String]
    ) -> Bool {
        !arguments.contains(idleWindowHistoryDrainDisableArgument)
    }

    /// Explicit consent for the destructive strap-zero. Default launches
    /// omit this argument. Never pairs with Start-fresh until 0x22 pending=0.
    nonisolated static let historyConsumeToNowLaunchArgument =
        "--atria-confirm-history-consume-to-now"

    nonisolated static func shouldApplyLaunchArgHistoryConsumeToNow(
        arguments: [String]
    ) -> Bool {
        arguments.contains(historyConsumeToNowLaunchArgument)
    }

    nonisolated static func idleWindowHistoryDrainMayPauseHeartRate(
        window: IdleWindowHistoryDrainWindow
    ) -> Bool {
        window != .none
    }

    /// Persist-before-ACK: a HISTORY_END token must not go on the air until
    /// its page is durably on disk. Skip the ACK and the strap re-serves the
    /// same cursor forever; that is the resume mechanism (no SET_READ_POINTER).
    /// Soak 15:40: first ACK then post-ACK 0x22 seq=3 was still outstanding
    /// when a second HISTORY_END tried WR — withhold until the probe lands.
    nonisolated static func shouldQueueHistoryEndACK(
        alreadyAcked: Bool,
        archiveWriteFailures: Int,
        postACKRangeProbeIssued: Bool = false
    ) -> Bool {
        !alreadyAcked
            && archiveWriteFailures == 0
            && !postACKRangeProbeIssued
    }

    /// M2: consented idle-window consume walks the strap pointer by ACK'ing
    /// HISTORY_END without a durable archive write. Default drains stay
    /// persist-before-ACK. Never selected without both the idle-window
    /// owner and explicit consume consent.
    nonisolated static func shouldACKIdleWindowHistoryEndWithoutPersisting(
        idleWindowDrainOwnsLink: Bool,
        consumeToNow: Bool
    ) -> Bool {
        idleWindowDrainOwnsLink && consumeToNow
    }

    /// Worn-background: one ACK-cursor chunk then restore 2A37. Charging /
    /// off-wrist has no live HR to protect — keep serving until thermal
    /// park, the longer absolute budget, or attended abort. Consented
    /// ACK-consume-to-now keeps walking past the first ACK on a large
    /// leftover, then restores 2A37 once the live-HR pause budget is spent
    /// so the pill never sits on No signal. A live tail at or below
    /// `idleWindowConsumeLiveTailPendingLimit` keeps ACK'ing until the
    /// slice-start pending count is consumed (or the pause budget is
    /// spent). Soak 14: finishing at the first ACK restored 2A37 and
    /// waited for a live sample (~7s); the worn write cursor sealed one
    /// new page in that window, so 0x22 pending stayed 1–2. Pickup abort
    /// is `shouldReleaseIdleWindowHistoryDrainForAttendedForeground`.
    nonisolated static let idleWindowConsumeHeartRatePauseLimit: TimeInterval = 18
    /// Worn soak 8: after the 13k ring collapsed, 0x22 pending stayed 1–9
    /// because each 18s slice + 20s resume let write grow before the next
    /// probe. ACK that tail and re-probe immediately.
    nonisolated static let idleWindowConsumeLiveTailPendingLimit: UInt32 = 16
    nonisolated static let idleWindowConsumeLiveTailResumeInterval: TimeInterval = 2
    /// Soak 14 gens 11–21/96–98: a 1–2 page tail plus the 2s resume and
    /// 2A37 toggle let write grow one page, so pending never hit 0.
    /// Stay paused and re-issue 0x22 before the next HISTORY_END seals.
    /// Soak 15 gen 1: ACK'd a 4-page tail to HISTORY_COMPLETE in 5s, then
    /// restored 2A37 because pending was 4 (>2); the next 0x22 never ran.
    /// Any live tail at or below `idleWindowConsumeLiveTailPendingLimit`
    /// keeps 2A37 paused until a later 0x22 or the 18s cap.
    nonisolated static let idleWindowConsumeLiveTailImmediateResumeInterval: TimeInterval = 0.4

    /// Consented consume must keep walking a 1–9 live tail even when the
    /// 120-record flush-debt floor already reads "caught up".
    nonisolated static func shouldTreatConsumeLiveTailAsBacklog(
        consumeToNow: Bool,
        lastPendingRecords: UInt32?
    ) -> Bool {
        consumeToNow && (lastPendingRecords ?? 0) > 0
    }

    nonisolated static func shouldFinishIdleWindowHistoryDrainAtACKBoundary(
        idleWindowDrainOwnsLink: Bool,
        acknowledgedPages: Int,
        chargingOrOffWrist: Bool = false,
        attendedForeground: Bool = false,
        consumeToNow: Bool = false,
        sliceStartPendingRecords: UInt32? = nil,
        heartRatePauseElapsed: TimeInterval = 0
    ) -> Bool {
        guard idleWindowDrainOwnsLink, acknowledgedPages >= 1 else {
            return false
        }
        if consumeToNow {
            if let pending = sliceStartPendingRecords,
               pending <= idleWindowConsumeLiveTailPendingLimit {
                if acknowledgedPages >= max(Int(pending), 1) {
                    return true
                }
                return heartRatePauseElapsed >= idleWindowConsumeHeartRatePauseLimit
            }
            if chargingOrOffWrist { return false }
            return heartRatePauseElapsed >= idleWindowConsumeHeartRatePauseLimit
        }
        if attendedForeground { return true }
        if chargingOrOffWrist { return false }
        return true
    }

    /// 900s consume slices left the pill on No signal (2A37 paused past the
    /// 30s continuity watchdog). Restore 2A37 from the pause clock, not the
    /// 0x22 write clock, so handshake slop cannot starve live HR. Charging /
    /// off-wrist has no pulse to protect — keep the consume walk on the
    /// longer absolute budget so a still write cursor can reach pending=0.
    /// Soak 10 gen 31+: 18s pause fired while stream5 was mid-page
    /// (admitted=0, no HISTORY_END), so ACK never went out and 0x22 pending
    /// grew. Hold the pause while a consume page is still in the spool.
    nonisolated static let idleWindowConsumeHeartRatePauseHardCap: TimeInterval = 28

    nonisolated static func shouldReleaseIdleWindowHistoryDrainForHeartRatePause(
        idleWindowDrainOwnsLink: Bool,
        consumeToNow: Bool,
        pausedAt: Date?,
        now: Date,
        pauseLimit: TimeInterval = idleWindowConsumeHeartRatePauseLimit,
        chargingOrOffWrist: Bool = false,
        acknowledgedPages: Int = 0,
        consumeIngressInFlight: Bool = false,
        lastFrameAge: TimeInterval? = nil,
        stream5Received: Int = 0
    ) -> Bool {
        guard idleWindowDrainOwnsLink, consumeToNow, let pausedAt else {
            return false
        }
        if chargingOrOffWrist { return false }
        let elapsed = now.timeIntervalSince(pausedAt)
        if elapsed >= idleWindowConsumeHeartRatePauseHardCap { return true }
        if acknowledgedPages == 0, consumeIngressInFlight { return false }
        if acknowledgedPages == 0,
           stream5Received > 0,
           let lastFrameAge,
           lastFrameAge < 5 {
            return false
        }
        return elapsed >= pauseLimit
    }

    /// Pickup mid-chunk: restore 2A37 immediately instead of waiting out
    /// the handshake absolute budget. A same-launch restore that starts
    /// pre-HR before scene-active is not pickup — require the chunk to
    /// have begun unattended and already issued 0x22.
    nonisolated static func shouldReleaseIdleWindowHistoryDrainForAttendedForeground(
        idleWindowDrainOwnsLink: Bool,
        attendedForeground: Bool,
        drainBeganUnattended: Bool,
        historyRangeRequested: Bool
    ) -> Bool {
        idleWindowDrainOwnsLink
            && attendedForeground
            && drainBeganUnattended
            && historyRangeRequested
    }

    /// Charging / off-wrist bursts are thermal-bounded, not the 20s worn
    /// handshake cap (owner-rejected 5s cap; charging soak is the bulk window).
    /// Worn consume keeps the 20s cap plus the 18s 2A37 pause so the pill
    /// stays on live HR between slices. Off-wrist consume may use the
    /// charging burst: write is still and there is no live pulse to seize.
    nonisolated static func idleWindowHistoryDrainAbsoluteBudgetLimit(
        chargingOrOffWrist: Bool,
        consumeToNow: Bool = false
    ) -> TimeInterval {
        if consumeToNow && !chargingOrOffWrist { return 20 }
        return chargingOrOffWrist ? 180 : 20
    }

    /// A drain-owned drop must not arm the next-connect natural-gap drain.
    /// Soak 2 logged `not_rearmed` then set `naturalGapDrainArmed` 1ms later.
    nonisolated static func shouldArmNaturalGapDrainAfterDisconnect(
        endedNaturally: Bool,
        drainOwnedDisconnect: Bool,
        strapBacklogPending: Bool,
        explicitMotionOwnershipActive: Bool,
        thermalParked: Bool
    ) -> Bool {
        endedNaturally
            && !drainOwnedDisconnect
            && strapBacklogPending
            && !explicitMotionOwnershipActive
            && !thermalParked
    }

    /// Resume beat when there is no live pulse to protect (strap charging or
    /// off-wrist). Not zero: the transport still needs a moment to settle the
    /// 2A37 CCCD and history-pipe teardown between chunks.
    nonisolated static let idleWindowUnprotectedResumeInterval: TimeInterval = 2

    /// Give live 2A37 a beat after a bounded chunk before the charging
    /// window can seize the link again. Consented consume shortens that
    /// beat on a live tail / still write cursor so the next 0x22 can
    /// observe pending=0 before new samples accrue.
    nonisolated static func shouldAdmitIdleWindowHistoryDrainRetry(
        lastFinishedAt: Date?,
        now: Date,
        minimumResumeInterval: TimeInterval = 20,
        consumeToNow: Bool = false,
        lastPendingRecords: UInt32? = nil,
        chargingOrOffWrist: Bool = false
    ) -> Bool {
        guard let lastFinishedAt else { return true }
        let interval: TimeInterval
        if consumeToNow,
           chargingOrOffWrist
            || (lastPendingRecords.map {
                $0 <= idleWindowConsumeLiveTailPendingLimit
            } == true) {
            let pending = lastPendingRecords ?? 0
            interval = pending > 0
                && pending <= idleWindowConsumeLiveTailPendingLimit
                ? idleWindowConsumeLiveTailImmediateResumeInterval
                : idleWindowConsumeLiveTailResumeInterval
        } else if chargingOrOffWrist {
            // The 20s beat exists to let live 2A37 breathe between chunks.
            // On the charger / off the wrist the firmware is not producing a
            // pulse to protect, so that beat is dead air on the one window
            // where the backlog can actually be cleared in bulk.
            interval = idleWindowUnprotectedResumeInterval
        } else {
            interval = minimumResumeInterval
        }
        return now.timeIntervalSince(lastFinishedAt) >= interval
    }

    /// Soak 15:30: stream5_rx=20, historicalData decoded, persist still
    /// queued, 20s absolute budget restored 2A37, then
    /// `stale_persistence_callback` — ACK never went out. Hold the budget
    /// while a page is still persisting and un-ACK'd.
    nonisolated static func shouldHoldIdleWindowAbsoluteBudgetForInFlightPersist(
        persistPending: Bool,
        acknowledgedPages: Int
    ) -> Bool {
        persistPending && acknowledgedPages == 0
    }

    /// Soak 15:40: ACK + 0x22 seq=3 while stream5 still notifying; no
    /// write_confirmed and no data_range_response in 5s. Hold 2A37 paused
    /// until the post-ACK GET_DATA_RANGE is observed (or the probe gives up).
    nonisolated static func shouldHoldIdleWindowAbsoluteBudgetForPostACKRangeProbe(
        postACKProbeIssued: Bool,
        afterACKRangeObserved: Bool
    ) -> Bool {
        postACKProbeIssued && !afterACKRangeObserved
    }

    /// 0x22 never WR-confirms while a notify pipe is hot (2A37 lesson).
    /// Quiet stream 5 only; RX must stay notifying so the range response
    /// can land.
    nonisolated static func shouldQuietIdleWindowStream5BeforePostACKRangeProbe(
        idleWindowDrainOwnsLink: Bool,
        acknowledgedPages: Int,
        postACKProbeIssued: Bool
    ) -> Bool {
        idleWindowDrainOwnsLink
            && acknowledgedPages >= 1
            && postACKProbeIssued
    }

    /// Fail-closed restore if the handshake never serves a frame. The clock
    /// starts when `0x22` is requested, not when 2A37 is paused: soak 04:33
    /// spent 13s in rediscovery, then cancelled the write at the same
    /// millisecond `historyRange requested` landed. Notify-settle + range
    /// response + 2s settle + 0x16 still fits in 20s after the write. Pause
    /// without a range request keeps the pause timestamp so a hung discovery
    /// still restores. Frame-without-persist is the 5s persist/ACK stall.
    nonisolated static func shouldReleaseIdleWindowHistoryDrainForAbsoluteBudget(
        idleWindowDrainOwnsLink: Bool,
        startedAt: Date?,
        now: Date,
        absoluteLimit: TimeInterval = 20,
        rangeRequestedAt: Date? = nil
    ) -> Bool {
        guard idleWindowDrainOwnsLink else { return false }
        guard let anchor = rangeRequestedAt ?? startedAt else { return false }
        return now.timeIntervalSince(anchor) >= absoluteLimit
    }

    /// Soak 1 gen7: stream5_rx=50 admitted=0 persisted=0 pending=47–51 for
    /// ~20s, then absolute_budget. Restore as soon as frames are landing
    /// without any admission — do not wait out the handshake absolute cap.
    /// Soak-2 04:56: admitted=5, decode on the archive queue, persist in
    /// flight, then this 5s first-frame clock restored 2A37 and the persist
    /// callback was ignored as stale. Admission progress means the pipeline
    /// is working; wait for persist/ACK or the 20s absolute budget.
    /// Consume-soak gen5: the 5s stall restored 2A37 after a disconnect
    /// while stream5 was still landing and admission had not yet opened,
    /// so later generations never ACK'd. Consented consume-to-now waits
    /// for persist/ACK or the absolute budget instead.
    nonisolated static func shouldReleaseIdleWindowHistoryDrainWhenPersistAckStalled(
        idleWindowDrainOwnsLink: Bool,
        firstFrameAt: Date?,
        lastDurableProgressAt: Date?,
        persisted: Int,
        acknowledgedPages: Int,
        now: Date,
        persistAckStallLimit: TimeInterval = 5,
        admitted: Int = 0,
        consumeToNow: Bool = false
    ) -> Bool {
        guard idleWindowDrainOwnsLink, acknowledgedPages == 0 else { return false }
        if consumeToNow { return false }
        if persisted == 0 && admitted > 0 {
            return false
        }
        let stallAnchor: Date?
        if persisted > 0 {
            stallAnchor = lastDurableProgressAt
        } else {
            stallAnchor = firstFrameAt
        }
        guard let stallAnchor else { return false }
        return now.timeIntervalSince(stallAnchor) >= persistAckStallLimit
    }

    /// Idle-window drain already unsubscribed 2A37. The 45s live-HR slice
    /// watchdog would either cancel the link or hold the pause too long.
    nonisolated static func shouldArmConnectedHistoricalSliceForLiveHeartRateWatchdog(
        idleWindowDrainOwnsLink: Bool
    ) -> Bool {
        !idleWindowDrainOwnsLink
    }

    /// 0x03 timed out on a live-2A37 production handshake. Idle-window has
    /// already unsubscribed 2A37, so an unconfirmed stop still proceeds to
    /// `0x16` instead of cancelling the peripheral.
    nonisolated static func shouldContinueHistoricalServeAfterRealtimeStopTimeout(
        idleWindowStopRealtimeDrain: Bool
    ) -> Bool {
        idleWindowStopRealtimeDrain
    }

    /// Soak 2026-08-23 04:05 gen1: notification settle then 1ms
    /// `history_write_22_callback_failed` with no `historyRange requested` /
    /// `send mode=wr cmd=22`. `beginProductionHistoricalAdmissionAttempt`
    /// returned false because the SQLite admission ledger was still nil —
    /// idle-window calls `startOfflineHistoricalSync` directly and skipped
    /// `requestOfflineHistoricalSyncIfNeeded`'s ledger gate. Charging soaks
    /// later succeeded only after `historyAdmission status=ready`. Do not
    /// issue 0x22, and do not pause 2A37, until that ledger is open.
    nonisolated static func shouldIssueProductionHistoryRangeRequest(
        admissionLedgerReady: Bool
    ) -> Bool {
        admissionLedgerReady
    }

    /// A missing admission ledger is not a CoreBluetooth write-callback
    /// failure. Mapping it to `history_write_22_callback_failed` burned the
    /// first idle-window slice and blocked uncharged retries.
    nonisolated static func shouldClassifyMissingAdmissionLedgerAsHistoryRangeWriteCallbackFailure(
        admissionLedgerReady: Bool
    ) -> Bool {
        admissionLedgerReady
    }

    /// Soak 04:41 gen1: pause 2A37, then `discoverServices` of 180D+6108 on a
    /// live standard-HR link, wait for skipped RX/stream5 CCCDs, 3s settle,
    /// 0x22, no range response, `ble_disconnect` at 16.1s (36s HR gap). Soak
    /// 04:43 sent 0x22 in 3.2s with TX already live and kept the epoch. Skip
    /// full rediscovery when the command characteristic is already in hand.
    nonisolated static func shouldRediscoverServicesForIdleWindowHistoryDrain(
        txCharacteristicAvailable: Bool
    ) -> Bool {
        !txCharacteristicAvailable
    }

    /// Soak-2 09:07 gen1: waited for RX+stream5 on a restored live 2A37
    /// link, then paused and sent 0x22; WR never confirmed, drop at T+5.9s.
    /// The same soak's gen2 reconnect kept 2A37 off, enabled the pipe, and
    /// got matched range + stream5_rx=50 + ACK. Pause even if the history
    /// pipe is not ready — CCCDs come up after `notifying=0`, like gen2.
    nonisolated static func shouldPauseHeartRateForIdleWindowHistoryDrain(
        historyTransportReady: Bool,
        readyFor: TimeInterval = .greatestFiniteMagnitude,
        minimumReadyInterval: TimeInterval = 3.0,
        freshEpochWithoutHeartRate: Bool = false
    ) -> Bool {
        _ = (historyTransportReady, readyFor, minimumReadyInterval, freshEpochWithoutHeartRate)
        return true
    }

    /// Soak-2 08:53 didConnect: evaluate deferred for the history pipe,
    /// then the arm fence was cleared and 2A37 re-enabled. Keep the fence
    /// while the idle-window pipe/ledger is still preparing.
    nonisolated static func shouldClearIdleWindowArmFenceWhenDrainDidNotStart(
        idleWindowStillPreparing: Bool
    ) -> Bool {
        !idleWindowStillPreparing
    }

    /// Drain-owned drop with zero frames: keep 2A37 suppressed so the
    /// next connect is history-first (08:19 gen2), not 2A37-then-pause
    /// (08:53). After a productive ACK, restore HR as usual.
    /// Soak 9 gen 23: a verified empty 0x22 (`pending=0`, read==write)
    /// also has stream5_rx=0, but that is a completed drain, not a
    /// handshake drop. Suppressing then skipped 2A37 reassert and the
    /// continuity watchdog hard-reconnected after a 50s gap.
    nonisolated static func shouldKeepIdleWindowHeartRateSuppressedAfterDisconnect(
        drainOwnedDisconnect: Bool,
        receivedHistoryFrames: Bool,
        verifiedEmptyHistoryCursor: Bool = false,
        linkStillConnected: Bool = false
    ) -> Bool {
        if verifiedEmptyHistoryCursor { return false }
        // Soak 12 gen 1: 18s pause finish on a live link armed the fence
        // (`stream5_rx=0`) and skipped 2A37 reassert. History-first suppress
        // is for an actual drop, not a still-connected restore.
        if linkStillConnected { return false }
        return drainOwnedDisconnect && !receivedHistoryFrames
    }

    /// Soak 9 gen 23: `finishOfflineHistoricalSync` called reassert while
    /// the drain still owned 2A37 (`ble_notify_reassert skipped
    /// detail=idle_window_drain_pauses_2a37`), so `live_restored=0`.
    /// A verified empty 0x22, or any still-connected finish, is a completed
    /// drain — reassert must run. Mid-slice scene_active reassert still skips.
    /// Soak 14: a 1–2 page live tail is not complete; keep 2A37 paused so
    /// the next 0x22 can land before write seals another page.
    nonisolated static func shouldSkipIdleWindowHeartRateReassert(
        idleWindowDrainOwnsLink: Bool,
        verifiedEmptyHistoryCursor: Bool = false,
        deferLiveRestoreForConsumeLiveTail: Bool = false
    ) -> Bool {
        if verifiedEmptyHistoryCursor { return false }
        if deferLiveRestoreForConsumeLiveTail { return true }
        return idleWindowDrainOwnsLink
    }

    /// Soak 14: ACK of a 1–2 page worn tail plus 2A37 restore + live-sample
    /// wait (~7s) lets write grow one page, so the next 0x22 never shows
    /// pending=0. Keep the pause and re-probe immediately. A verified empty
    /// cursor, pause-budget expiry, or a leftover above 2 pages must still
    /// restore 2A37 (soak 9 / soak 12).
    nonisolated static func shouldDeferLiveHeartRateRestoreForConsumeLiveTailRetry(
        consumeToNow: Bool,
        lastPendingRecords: UInt32?,
        verifiedEmptyHistoryCursor: Bool,
        linkStillConnected: Bool,
        consumePauseElapsed: TimeInterval
    ) -> Bool {
        if verifiedEmptyHistoryCursor { return false }
        guard consumeToNow, linkStillConnected else { return false }
        if consumePauseElapsed >= idleWindowConsumeHeartRatePauseLimit {
            return false
        }
        let pending = lastPendingRecords ?? 0
        return pending > 0 && pending <= idleWindowConsumeLiveTailPendingLimit
    }

    /// Soak-2 09:07 wrote RX+stream5 CCCDs on live 2A37, then paused and
    /// sent 0x22; WR never confirmed. Gen2 enabled those CCCDs only after
    /// 2A37 was off and got a matched range. Do not enable history
    /// notifications while 2A37 is still notifying.
    /// Soak-2 09:14: `heartRateCharacteristic` was still nil at generation
    /// start, so pause was a no-op and `isNotifying` read as false — CCCDs
    /// and 0x22 armed while live HR continued. Require the characteristic.
    nonisolated static func shouldEnableIdleWindowHistoryNotifications(
        heartRateNotifying: Bool,
        heartRateCharacteristicAvailable: Bool = true
    ) -> Bool {
        heartRateCharacteristicAvailable && !heartRateNotifying
    }

    /// Do not open a history generation until 2A37 is in hand so pause
    /// cannot no-op (soak-2 09:14).
    nonisolated static func shouldStartIdleWindowHistoryGeneration(
        heartRateCharacteristicAvailable: Bool
    ) -> Bool {
        heartRateCharacteristicAvailable
    }

    /// Soak-2 09:18 skipped 180D while 2A37 was uncached, so pause never
    /// ran. Discover only the heart-rate service (not 6108) until 2A37 is
    /// in hand; 04:41's drop was a full 180D+6108 rediscovery after pause.
    nonisolated static func shouldDiscoverHeartRateServiceForIdleWindowHistoryDrain(
        heartRateCharacteristicAvailable: Bool
    ) -> Bool {
        !heartRateCharacteristicAvailable
    }

    /// Soak-2 08:38: idle-window deferred pause for the history pipe, then
    /// `historical_archive_warm_ready_exact_motion_bank` armed
    /// `connected_chunked_backfill` on live 2A37 and dropped at ~13s
    /// (`stream5_rx=0`). While the idle-window pipe is warming, only the
    /// idle-window / natural-gap reason may start a generation.
    nonisolated static func shouldSuppressNonIdleWindowHistoryWhileIdleWindowPipeWarms(
        idleWindowPipeWarming: Bool,
        idleWindowReasonAdmitted: Bool
    ) -> Bool {
        idleWindowPipeWarming && !idleWindowReasonAdmitted
    }

    /// Soak-2 09:27 restored a live 2A37 link, admitted idle-window, then
    /// returned at the orphan-replay spool guard without pausing or setting
    /// the archive-warm retry. RAW `connected_chunked_backfill` later seized
    /// the same epoch (gen1/2 streamed; gen3 dropped at 12.9s). Keep the
    /// retry so history-first pause survives the replay.
    nonisolated static func shouldRetryIdleWindowHistoryDrainWhenIngressReplayBlocks(
        idleWindowAdmitted: Bool,
        ingressReplayOrSpoolBlocking: Bool,
        historicalSyncAlreadyInProgress: Bool
    ) -> Bool {
        idleWindowAdmitted
            && ingressReplayOrSpoolBlocking
            && !historicalSyncAlreadyInProgress
    }

    /// Do not arm 0x22 / treat the pipe as ready while the previous-process
    /// spool is still replaying (soak-2 07:59 blocked evaluate 16s; 09:27
    /// never paused). The retry loop must wait, not one-shot evaluate.
    nonisolated static func shouldWaitForIdleWindowHistoricalIngressReplay(
        orphanReplayInFlight: Bool,
        currentGenerationSpoolOpen: Bool,
        consumeToNow: Bool = false
    ) -> Bool {
        if consumeToNow { return false }
        return orphanReplayInFlight || currentGenerationSpoolOpen
    }

    /// Soak 10: consume finish left the production spool file; the next
    /// generation saw `orphan_not_archived`, latched admission-failed, and
    /// dropped stream5 so HISTORY_END/ACK never ran. ACK-without-persist
    /// must discard that file, not fail-closed retain it.
    nonisolated static func shouldDiscardUnackedConsumeIngressSpool(
        consumeToNow: Bool,
        idleWindowDrainOwnsLink: Bool
    ) -> Bool {
        consumeToNow && idleWindowDrainOwnsLink
    }

    /// If replay is still blocking after the pipe-retry budget, restore 2A37
    /// rather than leave notify off with no generation.
    nonisolated static func shouldRestoreIdleWindowHeartRateWhenIngressReplayTimesOut(
        idleWindowPausedHeartRate: Bool,
        ingressStillBlocking: Bool
    ) -> Bool {
        idleWindowPausedHeartRate && ingressStillBlocking
    }

    /// Soak-2 05:34: pipe-ready pause then `startOfflineHistoricalSync`
    /// nilled TX (`txCharacteristic = nil`) and rediscovered after 2A37 was
    /// already unsubscribed. 0x22 never went out; drop at 10s. Idle-window
    /// already has TX in hand.
    nonisolated static func shouldClearCachedTXBeforeHistoricalHandshake(
        idleWindowDrainOwnsLink: Bool
    ) -> Bool {
        !idleWindowDrainOwnsLink
    }

    /// Production waits 3s after CCCD-on before 0x22 (too long for the
    /// ~16s window). Soak-2 08:07 sent 0x22 1ms after stream5 CCCD-on
    /// and the WR never confirmed. Soak-2 08:43 enabled the pipe first
    /// then sent 0x22 1ms after 2A37 `notifying=0` (`settle_s=0.0`); the
    /// WR never confirmed and the link dropped at T+7s. Always leave the
    /// CCCD callback turn (~400ms) before 0x22.
    nonisolated static func idleWindowHistoryRangePostNotifySettle(
        idleWindowDrainOwnsLink: Bool,
        historyPipeReadyBeforePause: Bool = false
    ) -> TimeInterval {
        _ = historyPipeReadyBeforePause
        guard idleWindowDrainOwnsLink else {
            return AtriaBLEHistoryWriteConfirmationPolicy.postNotificationSettleInterval
        }
        return 0.4
    }

    /// Soak-2 05:39: pause 2A37 and send 0x22 32ms later, before the CCCD
    /// callback. The WR never confirmed and the link dropped at 10s.
    /// Soak-1 04:55 sent 0x22 after `notifyState ch=2A37 notifying=0`.
    nonisolated static func shouldArmIdleWindowHistoryRangeRequest(
        heartRateNotifying: Bool,
        heartRateCharacteristicAvailable: Bool = true
    ) -> Bool {
        heartRateCharacteristicAvailable && !heartRateNotifying
    }

    /// Soak-1's CCCD-off was 132ms on a quiet restore-seeded link. Soak-2
    /// 07:35 gen1: abort at 1s then `notifying=0` arrived at 5.9s. Wait
    /// long enough for that callback; abort only if it never comes.
    nonisolated static func shouldTimeoutIdleWindowHeartRateUnsubscribe(
        elapsed: TimeInterval,
        limit: TimeInterval = 8
    ) -> Bool {
        elapsed >= limit
    }

    /// Soak-2 08:14 gen1: 0x22 write-confirmed at T+7.3s. Restoring 2A37
    /// without 0x16 still dropped at T+14.4s. The served trace is 22/00 WR
    /// → ~2.1s → 16/00. After a confirmed 0x22, send 0x16 even if the
    /// range response is late. 07:49's drop was 0x16 at T+16.5s, not the
    /// missing range itself.
    nonisolated static func shouldServeIdleWindowHistoryWithoutMatchedRange(
        idleWindowDrainOwnsLink: Bool,
        writeConfirmed: Bool,
        elapsedSinceWriteConfirm: TimeInterval,
        limit: TimeInterval = 2.1
    ) -> Bool {
        idleWindowDrainOwnsLink && writeConfirmed && elapsedSinceWriteConfirm >= limit
    }

    /// Restore 2A37 without 0x16 only when 0x22 itself never write-confirmed.
    /// After a confirmed 0x22 the strap is already in the history window.
    nonisolated static func shouldRestoreIdleWindowHeartRateWhenRangeUnanswered(
        idleWindowDrainOwnsLink: Bool,
        writeConfirmed: Bool,
        elapsedSinceWriteConfirm: TimeInterval,
        limit: TimeInterval = 2.1
    ) -> Bool {
        _ = (idleWindowDrainOwnsLink, elapsedSinceWriteConfirm, limit)
        return idleWindowDrainOwnsLink && !writeConfirmed
    }

    /// Soak-2 07:49 withheld strap-service discovery until 2A37 CCCD-off,
    /// so TX was missing and 0x22 went out at T+10s. Discovery is not a
    /// CCCD write; start it while unsubscribe is in flight.
    nonisolated static func shouldDiscoverIdleWindowHistoryTransportWhileHeartRateNotifying(
        heartRateNotifying: Bool
    ) -> Bool {
        _ = heartRateNotifying
        return true
    }

    /// If 2A37 is still notifying after the unsubscribe timeout, the CCCD
    /// write never reached the strap. Sending 0x22 anyway jammed the WR
    /// (soak-2 07:11). Restore 2A37 and abort.
    nonisolated static func shouldAbortIdleWindowPauseWhenUnsubscribeLost(
        heartRateStillNotifying: Bool
    ) -> Bool {
        heartRateStillNotifying
    }

    /// Admit-probe 14:40: pause CCCD completed with `notifying=1 err=Unknown
    /// error` then 8s abort, `stream5_rx=0`. Retry the unsubscribe once
    /// instead of treating a failed CCCD as lost.
    nonisolated static func shouldRetryIdleWindowHeartRateUnsubscribe(
        cccdErrorPresent: Bool,
        heartRateStillNotifying: Bool
    ) -> Bool {
        cccdErrorPresent && heartRateStillNotifying
    }

    /// Drain-keeping continuity (2026-08-07 soak): a `.draining` authority
    /// whose transport died (slice released for live HR, orphaned lease, BLE
    /// drop) used to be resumable ONLY via the interrupted-full-drain
    /// reacquisition reasons; every ordinary re-arm (bg_processing, the P3
    /// tick, accepted-HR chains) answered `deferred_existing_drain_authority`,
    /// so a 19 h backlog advanced in rare bursts tens of minutes apart. An
    /// ordinary guarded re-arm may resume the SAME persisted authority once
    /// the chain is provably silent and live capture has provably recovered on
    /// a stable link — the documented 60 s-stable resume. Fresh accepted HR is
    /// the safety precondition (the slice watchdog releases history again if
    /// it goes stale), not a reason to defer forever; a healthy in-flight
    /// chain is protected by the silence floor and `syncInProgress`.
    nonisolated static func shouldResumeStrandedDrainingAuthority(
        syncInProgress: Bool,
        linkConnected: Bool,
        connectedAt: Date?,
        lastAcceptedHRAt: Date?,
        lastAuthorityProgressAtUnix: TimeInterval?,
        activeExplicitWorkout: Bool,
        recentDisconnectStorm: Bool,
        now: Date,
        stableConnectionInterval: TimeInterval = 60,
        acceptedFreshnessWindow: TimeInterval = 45,
        progressSilenceFloor: TimeInterval = 90
    ) -> Bool {
        guard !syncInProgress,
              linkConnected,
              !activeExplicitWorkout,
              !recentDisconnectStorm,
              let connectedAt,
              let lastAcceptedHRAt else { return false }
        let connectionAge = now.timeIntervalSince(connectedAt)
        let acceptedAge = now.timeIntervalSince(lastAcceptedHRAt)
        guard connectionAge >= stableConnectionInterval,
              acceptedAge >= 0,
              acceptedAge <= acceptedFreshnessWindow else { return false }
        // No durable progress marker at all → nothing to protect; resume.
        guard let lastProgress = lastAuthorityProgressAtUnix,
              lastProgress.isFinite else { return true }
        return now.timeIntervalSince1970 - lastProgress >= progressSilenceFloor
    }

    /// Attempt cadence for the catch-up lanes (2026-08-07 overnight): the
    /// 6-hour ordinary interval is idle-upkeep pacing, and the 10-minute
    /// catch-up interval used to apply ONLY while the range-loss ticket was
    /// pending. Once publication cleared that ticket mid-backlog, every
    /// maintenance re-arm answered `throttled` for up to six hours while the
    /// strap still held hours of data — the drain ran in rare bursts. Any real
    /// backlog now uses the catch-up cadence, and a previous attempt that
    /// actually yielded rows earns the fast progress-gated retry (the same
    /// "progress, not hope" rule as the P1 slice chain). Every downstream
    /// guard (stable link, fresh HR, workout, storm) still applies.
    nonisolated static func catchUpAttemptMinimumInterval(
        backlogPending: Bool,
        lastAttemptYieldedRows: Bool,
        ordinaryInterval: TimeInterval,
        backlogInterval: TimeInterval,
        productiveInterval: TimeInterval
    ) -> TimeInterval {
        guard backlogPending else { return ordinaryInterval }
        return lastAttemptYieldedRows ? productiveInterval : backlogInterval
    }

    /// Handoff-9 CP2: the connected-handoff retry interval, computed ONCE and
    /// fed to BOTH the eligibility gate and the transport throttle gate so the
    /// two can never contradict each other. The fast (productive) cadence is
    /// earned only by an exact durable productive-slice receipt: same
    /// completed generation, at least one durably persisted row, a succeeded
    /// durable flush boundary, a frontier that actually advanced past the
    /// attempt's captured start, restored live-HR authority, and an unchanged
    /// gap fingerprint. A missing, unreadable, stale-generation, failed,
    /// no-progress, or fingerprint-mismatched receipt keeps the existing brake.
    /// Receiving a frame (`stream5Received > 0`) is deliberately NOT enough —
    /// parse/persist/flush/authority failure can still follow a received frame.
    nonisolated static func connectedHandoffRetryInterval(
        receipt: AtriaHistoricalDurableProductiveSliceReceipt?,
        currentGapFingerprint: String?,
        lastCompletedGeneration: UInt64?,
        productiveInterval: TimeInterval,
        brakeInterval: TimeInterval
    ) -> TimeInterval {
        guard let receipt,
              receipt.status == .productive,
              receipt.durableRowsDelta > 0,
              receipt.startFrontierUnix.isFinite,
              receipt.endFrontierUnix.isFinite,
              receipt.endFrontierUnix > receipt.startFrontierUnix,
              receipt.liveRestoredAtUnix != nil,
              let lastCompletedGeneration,
              receipt.generation == lastCompletedGeneration,
              receipt.gapFingerprint == currentGapFingerprint else {
            return brakeInterval
        }
        return productiveInterval
    }

    /// Autonomous cursor-anchored catch-up admission (2026-08-07, the last
    /// starvation hole): resume lanes and attended taps could START nothing
    /// when no authority existed — after any process kill that cleared or
    /// resolved the authority, the backlog sat dead until a human tapped Sync
    /// or relaunched. A BACKGROUND re-arm with a real backlog may create the
    /// same forward-from-cursor chunked catch-up an attended tap gets, under
    /// the same proven-live-epoch conditions as the stranded resume plus an
    /// attempt cooldown. Foreground still defers (that dead-end stays dead);
    /// the seekless full-flash gap replay stays retired.
    nonisolated static func shouldAdmitAutonomousCursorAnchoredCatchUpStart(
        foregroundInteractive: Bool,
        strapBacklogPending: Bool,
        syncInProgress: Bool,
        linkConnected: Bool,
        connectedAt: Date?,
        lastAcceptedHRAt: Date?,
        lastAttemptAt: Date?,
        activeExplicitWorkout: Bool,
        recentDisconnectStorm: Bool,
        now: Date,
        stableConnectionInterval: TimeInterval = 60,
        acceptedFreshnessWindow: TimeInterval = 45,
        attemptCooldown: TimeInterval = 120
    ) -> Bool {
        guard !foregroundInteractive,
              strapBacklogPending,
              !syncInProgress,
              linkConnected,
              !activeExplicitWorkout,
              !recentDisconnectStorm,
              let connectedAt,
              let lastAcceptedHRAt else { return false }
        let connectionAge = now.timeIntervalSince(connectedAt)
        let acceptedAge = now.timeIntervalSince(lastAcceptedHRAt)
        guard connectionAge >= stableConnectionInterval,
              acceptedAge >= 0,
              acceptedAge <= acceptedFreshnessWindow else { return false }
        if let lastAttemptAt {
            guard now.timeIntervalSince(lastAttemptAt) >= attemptCooldown else {
                return false
            }
        }
        return true
    }

    /// Mints the process-local proof for one non-destructive raw-history slice
    /// over the already-canonical realtime connection. This is deliberately
    /// stricter than the ordinary history-request policy: a reason string,
    /// `force`, persisted pending tuple, or foreground lifecycle race can never
    /// satisfy it. The stateful caller still has to bind the proof to the exact
    /// `CBPeripheral` object/callback epoch and atomically claim that canonical
    /// object before publishing a transport generation.
    ///
    /// A materially stale foreground may also enter automatically. This does
    /// not turn lifecycle state or a reason string into authority: the caller
    /// must still mint the exact callback-source token on an accepted 2A37
    /// boundary and win the canonical-object claim synchronously.
    nonisolated static func shouldMintConnectedRawHistoryCatchUpAuthority(
        applicationIsBackground: Bool,
        queuedPullIntent: Bool,
        foregroundAutomaticBacklog: Bool,
        strapBacklogPending: Bool,
        verifiedRawHistoryCapability: Bool,
        exactCallbackSourceAvailable: Bool,
        syncInProgress: Bool,
        linkConnected: Bool,
        thermalPressureActive: Bool,
        connectedAt: Date?,
        acceptedSampleCount: Int,
        lastAcceptedHRAt: Date?,
        activeExplicitWorkout: Bool,
        now: Date,
        stableConnectionInterval: TimeInterval = 60,
        acceptedFreshnessWindow: TimeInterval = 45,
        minimumSamples: Int = 10
    ) -> Bool {
        guard applicationIsBackground
                || queuedPullIntent
                || foregroundAutomaticBacklog,
              strapBacklogPending,
              verifiedRawHistoryCapability,
              exactCallbackSourceAvailable,
              !syncInProgress,
              linkConnected,
              !thermalPressureActive,
              !activeExplicitWorkout,
              acceptedSampleCount >= minimumSamples,
              let connectedAt,
              let lastAcceptedHRAt else { return false }
        let connectionAge = now.timeIntervalSince(connectedAt)
        let acceptedAge = now.timeIntervalSince(lastAcceptedHRAt)
        guard connectionAge >= stableConnectionInterval,
              acceptedAge >= 0,
              acceptedAge <= acceptedFreshnessWindow else { return false }
        return true
    }

    /// Gives a verified same-link raw backlog one finite first turn before a
    /// terminal whole-archive projection occupies the serial archive lane.
    /// This is scheduling only: the accepted 2A37 callback must still mint the
    /// exact object/epoch authority, and expiry always releases publication.
    nonisolated static func shouldDeferTerminalConsumerMaterializationForRawFirstSlice(
        applicationIsActive: Bool,
        strapBacklogPending: Bool,
        verifiedRawHistoryCapability: Bool,
        linkConnected: Bool,
        activeExplicitWorkout: Bool,
        rawThermalPressureActive: Bool,
        publicationYieldActive: Bool,
        rawFirstSliceSpent: Bool,
        now: Date,
        deadline: Date
    ) -> Bool {
        applicationIsActive
            && strapBacklogPending
            && verifiedRawHistoryCapability
            && linkConnected
            && !activeExplicitWorkout
            && !rawThermalPressureActive
            && !publicationYieldActive
            && !rawFirstSliceSpent
            && now < deadline
    }

    /// Soak 16: after strap-zero, connected-raw catch-up was admitted
    /// (`terminal_publication_parallel_range_loss_raw`) then refused by
    /// `historicalConsumerMaterializationInFlight`. Terminal publication is a
    /// local archive projection; it must not block a same-link persist-before-ACK
    /// / raw catch-up that never mutates the parked journal.
    nonisolated static func shouldBlockHistoryTransportForTerminalConsumerMaterialization(
        materializationInFlight: Bool,
        exactConnectedRealtimePreservingRequest: Bool,
        idleWindowDrainAdmitted: Bool = false
    ) -> Bool {
        guard materializationInFlight else { return false }
        if exactConnectedRealtimePreservingRequest { return false }
        if idleWindowDrainAdmitted { return false }
        return true
    }

    /// Consume-to-now ACK'd HISTORY_COMPLETE with persisted=0. There is no
    /// durable journal from that generation to project; scheduling
    /// terminal materialization latched the lane and blocked go-forward
    /// persist-before-ACK (soak 16 gen 2 → in_flight until ceiling).
    nonisolated static func shouldScheduleTerminalConsumerMaterializationAfterHistoryFinish(
        terminalAndLiveRestored: Bool,
        reachedTerminal: Bool,
        compactMotionBankOnly: Bool,
        connectedRawCatchUpContinuationPending: Bool,
        consumeToNow: Bool,
        persistedRows: Int
    ) -> Bool {
        guard !compactMotionBankOnly,
              !connectedRawCatchUpContinuationPending,
              terminalAndLiveRestored,
              reachedTerminal else { return false }
        if consumeToNow && persistedRows <= 0 { return false }
        return true
    }

    /// The persisted workout intent can reach its terminal value just before
    /// the in-memory motion lease is released. Treat either representation (or
    /// a live calibration hold) as explicit motion ownership so a raw 0x16
    /// generation cannot enter that release gap.
    nonisolated static func explicitMotionOwnershipBlocksHistory(
        pendingWorkoutIntentActive: Bool,
        inMemoryLeaseHeld: Bool,
        calibrationHoldActive: Bool
    ) -> Bool {
        pendingWorkoutIntentActive
            || inMemoryLeaseHeld
            || calibrationHoldActive
    }

    /// A failed reacquisition after a productive connected-raw slice owns no
    /// radio. Release its logical continuation so present 0x69 capture can
    /// recover, but hold the next raw attempt for one meaningful bank interval
    /// instead of recreating the physically observed 6-15 second ticket loop.
    nonisolated static func connectedRawNoRadioRetryNotBefore(
        priorContinuationPending: Bool,
        admissionStarted: Bool,
        historyOwnerActive: Bool,
        failedAt: Date,
        minimumPresentCaptureInterval: TimeInterval = 120
    ) -> Date? {
        guard priorContinuationPending,
              !admissionStarted,
              !historyOwnerActive,
              minimumPresentCaptureInterval.isFinite,
              minimumPresentCaptureInterval >= 0 else { return nil }
        return failedAt.addingTimeInterval(minimumPresentCaptureInterval)
    }

    /// A newly armed factual bank is not immediately cut into another tiny
    /// ticket by raw admission later in the same accepted-HR callback.
    nonisolated static func connectedRawPresentBankRetryNotBefore(
        bankArmedForCurrentConnection: Bool,
        bankArmedAt: Date?,
        now: Date,
        minimumPresentCaptureInterval: TimeInterval = 120
    ) -> Date? {
        guard bankArmedForCurrentConnection,
              let bankArmedAt,
              minimumPresentCaptureInterval.isFinite,
              minimumPresentCaptureInterval >= 0 else { return nil }
        let deadline = bankArmedAt.addingTimeInterval(
            minimumPresentCaptureInterval
        )
        return now < deadline ? deadline : nil
    }

    struct GlobalFrontierEvaluationCoalescer: Equatable {
        private(set) var trailingRequested = false

        /// Returns true only when the caller may start immediately. While any
        /// shared compact evaluation is active, arbitrarily many raw slice
        /// boundaries collapse into one fresh trailing request.
        mutating func request(whileEvaluationInFlight: Bool) -> Bool {
            guard whileEvaluationInFlight else { return true }
            trailingRequested = true
            return false
        }

        mutating func consumeTrailingRequest() -> Bool {
            guard trailingRequested else { return false }
            trailingRequested = false
            return true
        }
    }

    enum ConnectedRawHistoryCatchUpThermalDisposition: Equatable {
        case fullRate
        case boundedSeriousDuty
        case parkCritical
    }

    /// Low Power Mode never strands durable raw history. Nominal/fair serves
    /// continuously; serious heat receives short duty-cycled serves; only
    /// critical heat parks completely. Optional motion-bank history retains
    /// its separate, stricter power policy.
    nonisolated static func connectedRawHistoryCatchUpThermalDisposition(
        thermalState: ProcessInfo.ThermalState
    ) -> ConnectedRawHistoryCatchUpThermalDisposition {
        switch thermalState {
        case .critical:
            return .parkCritical
        case .serious:
            return .boundedSeriousDuty
        case .nominal, .fair:
            return .fullRate
        @unknown default:
            return .boundedSeriousDuty
        }
    }

    /// ITEM-4 2026-08-15 (strap 50%→11% field report): STRAP-battery-aware
    /// duty shaping for the connected raw catch-up lane. Mirrors the motion
    /// bank's battery floor pattern — floor with resume hysteresis, charging
    /// exempt, unknown level permissive. Scheduling-only: no backlog flag is
    /// touched and the lane still converges; a constrained strap simply
    /// spends its radio in smaller, spaced slices so capture outlives the
    /// backfill. Flash history is durable on the strap; live capture is the
    /// thing a dead battery loses.
    nonisolated static func strapPowerConstrainedForRawCatchUp(
        batteryLevel: Int,
        isCharging: Bool,
        previouslyConstrained: Bool,
        floor: Int = 20,
        resumeMargin: Int = 5
    ) -> Bool {
        guard batteryLevel >= 0 else { return false }
        guard !isCharging else { return false }
        if previouslyConstrained {
            return batteryLevel < floor + resumeMargin
        }
        return batteryLevel <= floor
    }

    nonisolated static func shouldParkConnectedRawHistoryCatchUpForPowerPressure(
        thermalState: ProcessInfo.ThermalState
    ) -> Bool {
        connectedRawHistoryCatchUpThermalDisposition(
            thermalState: thermalState
        ) == .parkCritical
    }

    /// A live-HR preemption is a failed coexistence attempt, not a productive
    /// slice. Keep the retry process- and restoration-stable for at least five
    /// minutes so the first fresh 2A37 callback after the rebuild cannot start
    /// the same failure again.
    nonisolated static func connectedRawHistoryLivePreemptionRetryNotBefore(
        now: Date,
        connectedSliceCooldown: TimeInterval,
        zeroProgressRetry: TimeInterval,
        minimumCooldown: TimeInterval = 5 * 60
    ) -> Date {
        now.addingTimeInterval(max(
            1,
            minimumCooldown,
            connectedSliceCooldown,
            zeroProgressRetry
        ))
    }

    /// Normal raw-slice completion is owned by the matching ACK callback, not
    /// this timer. Critical heat may stop immediately. Invalid time input fails
    /// closed, while a genuine no-progress transport is owned by the existing
    /// history idle watchdog so this polling timer can never cut a live page.
    nonisolated static func connectedRawHistoryCatchUpBudgetDisposition(
        startedAt: Date,
        lastAcceptedHeartRateAt: Date?,
        now: Date,
        liveSilenceLimit: TimeInterval,
        thermalState: ProcessInfo.ThermalState,
        durableBoundaryReached: Bool,
        seriousDutyMaximum: TimeInterval = 45
    ) -> ConnectedMotionBankHistoryBudgetDisposition {
        let elapsed = now.timeIntervalSince(startedAt)
        switch connectedRawHistoryCatchUpThermalDisposition(
            thermalState: thermalState
        ) {
        case .parkCritical:
            return .finishForPowerPressure
        case .boundedSeriousDuty, .fullRate:
            break
        }

        // WHOOP does not interleave 2A37 while serving one proprietary page.
        // Treating that expected silence as a mid-page failure made every
        // slice pay the full 22/00 + discovery setup, then preserve/replay an
        // uncommitted suffix. Normal slice termination is therefore decided
        // synchronously at a confirmed ACK boundary. A negative clock is the
        // only absolute-budget failure this task owns.
        guard elapsed >= 0 else {
            return .finishForAbsoluteBudget
        }
        guard let lastAcceptedHeartRateAt,
              now.timeIntervalSince(lastAcceptedHeartRateAt) >= 0 else {
            return .finishForLiveHeartRateSilence
        }
        _ = liveSilenceLimit
        if durableBoundaryReached {
            // An earlier ACK is durable progress, not slice completion. Keep
            // serving until the intent/thermal matching ACK callback ends the
            // burst.
            return .keepServing
        }
        if elapsed >= max(1, seriousDutyMaximum) {
            // No ACK by the former wall-clock cap is not permission to cut an
            // in-flight page. The progress-clocked history idle watchdog owns
            // the true-stall exit and preserves the exact realtime link.
            return .keepServing
        }
        return .keepServing
    }

    /// Selects a finite clean-ACK burst which amortizes the expensive history
    /// handshake without ignoring real heat. A locked-background slice gets
    /// exactly one clean page: physical ab071 evidence showed the first page
    /// can stop 2A37 and outlive every MainActor budget task. Foreground work
    /// retains the prior thermal duty because the visible watchdog can recover
    /// it and the user explicitly has the app available.
    nonisolated static func connectedRawHistoryCatchUpTargetAcknowledgedPages(
        thermalState: ProcessInfo.ThermalState,
        backgroundSlice: Bool = false,
        strapPowerConstrained: Bool = false
    ) -> Int {
        if backgroundSlice { return 1 }
        switch connectedRawHistoryCatchUpThermalDisposition(
            thermalState: thermalState
        ) {
        case .fullRate:
            // ITEM-4 2026-08-15: a low-battery discharging strap trades burst
            // size for capture longevity (16 → 4 pages per handshake).
            return strapPowerConstrained ? 4 : 16
        case .boundedSeriousDuty:
            return 4
        case .parkCritical:
            return 1
        }
    }

    /// A productive connected raw slice amortizes the expensive history
    /// handshake across a thermal-qualified number of complete WHOOP pages.
    /// The caller invokes this
    /// only after canonical durability and the matching ACK have both
    /// succeeded, so returning true can never cut through a page or discard an
    /// unacknowledged suffix. Critical heat remains owned by the independent
    /// immediate budget fence above.
    nonisolated static func shouldFinishConnectedRawHistoryCatchUpAtACKBoundary(
        acknowledgedPages: Int,
        minimumAcknowledgedPages: Int = 4
    ) -> Bool {
        acknowledgedPages >= max(1, minimumAcknowledgedPages)
    }

    /// A local ACK-boundary yield can leave the strap finishing the next page
    /// after the old callback phase has retired. A new exact raw generation may
    /// consume historical ingress only when the callback itself captured that
    /// generation's armed serve token and its durable admission attempt already
    /// exists. Looking at current state later is a TOCTOU: a predecessor frame
    /// can queue before 0x16, then reach MainActor after 0x16. Other history
    /// modes keep their existing protocol handling.
    nonisolated static func shouldAcceptConnectedRawHistoryIngress(
        exactRawAuthorityActive: Bool,
        callbackCapturedCurrentServe: Bool,
        admissionAttemptAvailable: Bool
    ) -> Bool {
        guard exactRawAuthorityActive else { return true }
        return callbackCapturedCurrentServe && admissionAttemptAvailable
    }

    /// A page-continuation command is only a silence fallback. Once a frame
    /// captured under the current serve token has crossed the ingress gate, it
    /// proves that the strap is already serving that page and any armed 0x16
    /// fallback must be cancelled. Generation matching prevents a delayed frame
    /// from cancelling a newer generation's continuation; `ingressAccepted`
    /// keeps rejected predecessor callbacks completely observational.
    nonisolated static func shouldCancelHistoricalPageContinuationForFrame(
        activeGeneration: UInt64?,
        continuationGeneration: UInt64?,
        frameGeneration: UInt64,
        ingressAccepted: Bool,
        callbackCapturedCurrentServe: Bool
    ) -> Bool {
        ingressAccepted
            && callbackCapturedCurrentServe
            && activeGeneration == frameGeneration
            && continuationGeneration == frameGeneration
    }

    /// `admissionBatchScheduled` is deliberately not a blocker. Scheduling is
    /// MainActor-local and the task cannot pop the unread suffix while the
    /// synchronous ACK finalizer is executing. In-flight classification,
    /// popped deferred metadata, persistence, flush, or ACK work still makes
    /// the dequeue cursor non-durable and therefore fails closed.
    nonisolated static func shouldRetireConnectedRawConsumedPrefix(
        exactCleanACKFinishAuthority: Bool,
        durableBoundaryReached: Bool,
        acknowledgedPages: Int,
        pendingPersistenceCount: Int,
        admissionBatchInFlight: Bool,
        admissionBatchScheduled: Bool,
        hasDeferredEvent: Bool,
        durableFlushInFlight: Bool,
        hasPendingACK: Bool,
        ackGateDeferringCallbacks: Bool
    ) -> Bool {
        _ = admissionBatchScheduled
        return exactCleanACKFinishAuthority
            && durableBoundaryReached
            && acknowledgedPages > 0
            && pendingPersistenceCount == 0
            && !admissionBatchInFlight
            && !hasDeferredEvent
            && !durableFlushInFlight
            && !hasPendingACK
            && !ackGateDeferringCallbacks
    }

    enum ConnectedRawHistoryCatchUpContinuationDisposition: Equatable {
        case complete
        case awaitThermalRecovery
        case yieldForPublication(TimeInterval)
        /// W1-A 2026-08-20 (step-latency Step 2): a scheduled coarse pause,
        /// long enough for the existing arm path's idle-window test to open
        /// present 0x69 capture. Never an interleave inside a continuation
        /// episode — the raw lane stays latched and the next slice's serve
        /// cutover reclaims transport.
        case pauseForPresentCapture(TimeInterval)
        case resumeAfter(TimeInterval)
        case retryAfter(TimeInterval)
    }

    struct HistoricalMotionBankCutoverState: Equatable {
        let processArmed: Bool
        let persistedEnabled: Bool
        let prearmRequested: Bool
    }

    /// An accepted history serve closes firmware bank 0x69. Keeping either
    /// armed bit true would both invent coverage and suppress the real 69/01
    /// successor arm, so the only honest local mirror is fixed and explicit.
    nonisolated static func historicalMotionBankStateAfterHistoryServeCutover()
        -> HistoricalMotionBankCutoverState {
        .init(
            processArmed: false,
            persistedEnabled: false,
            prearmRequested: true
        )
    }

    /// A connected-raw continuation is one logical FIFO owner across its
    /// bounded live-restoration gaps. Ordinary all-day rearm cannot interleave
    /// 69/01 with that owner. An explicit workout/calibration may preempt only
    /// after the physical history owner has already released transport.
    nonisolated static func historicalMotionBankRearmBlockedByRawOwnership(
        historyTransportActive: Bool,
        rawContinuationPending: Bool,
        postHistoryRawRestorationActive: Bool,
        explicitPresentCapturePriority: Bool
    ) -> Bool {
        historyTransportActive
            || (!explicitPresentCapturePriority
                && (rawContinuationPending
                    || postHistoryRawRestorationActive))
    }

    /// W1-A 2026-08-20: floor below which a pending continuation's next
    /// evaluation still counts as active radio ownership. The 60s floor keeps
    /// 2s productive chains from arm/disarm churn (arm-path comment of the
    /// original inline test).
    nonisolated static let connectedRawContinuationIdleWindowSeconds:
        TimeInterval = 60

    /// W1-A 2026-08-20 (step-latency Step 1): the ONE predicate for "the raw
    /// lane actively owns the radio". The continuation flag is a SCHEDULING
    /// latch that stays true across hours of idle retry cadence while a
    /// backlog exists — treating the bare latch as radio ownership disarmed
    /// the all-day bank for ~12k seconds of a sampled day and deferred closed
    /// directOffload tickets for as long as any backlog existed. A pending
    /// continuation owns the radio only while its next evaluation is sooner
    /// than `rawSliceIdleWindow`; an unknown next evaluation fails closed to
    /// active ownership. Extracted from the arm path's inline idle test so
    /// the arm path, the offload resume path, and the hourly-checkpoint gate
    /// cannot drift apart again.
    nonisolated static func connectedRawContinuationActivelyOwnsRadio(
        continuationPending: Bool,
        nextEvaluationNotBefore: Date?,
        now: Date,
        rawSliceIdleWindow: TimeInterval =
            connectedRawContinuationIdleWindowSeconds
    ) -> Bool {
        guard continuationPending else { return false }
        guard let nextEvaluationNotBefore else { return true }
        return nextEvaluationNotBefore.timeIntervalSince(now)
            < rawSliceIdleWindow
    }

    /// Productive raw slices chain on a later accepted-HR boundary instead of
    /// waiting behind the global history-attempt timestamp. Zero-progress or
    /// protocol-failure attempts retain the conservative backoff. When bounded
    /// app-facing work is already pending, a finite publication yield
    /// releases only the process-local projection fence; it never recreates a
    /// BLE authority. Pending work yields after one proven productive slice;
    /// a fair/nominal slice already spans sixteen clean page ACKs, which is a
    /// sufficiently bounded quantum. Serious heat keeps its four-page raw duty
    /// because the app-facing worker refuses that environment; a pending intent
    /// alone must never create an empty 120-second cooling loop.
    /// With no pending publication work, the existing small periodic duty pause
    /// remains the only interruption.
    ///
    /// W1-A 2026-08-20 (step-latency Step 2) adds one more leg: after roughly
    /// 25–30 minutes of sustained productive drain
    /// (`presentCaptureShareAfterSlices` productive slices), a single coarse
    /// `pauseForPresentCapture` long enough (>= the 60s arm-path idle window
    /// plus margin) for the EXISTING arm path to open present 0x69 capture in
    /// the gap; the next slice's serve cutover closes it into honest
    /// coverage. This is a scheduled pause, never a 69/01 interleave inside a
    /// raw continuation episode (the physically rejected v5 flow manufactured
    /// tickets faster than read_cursor could converge). Under the ITEM-4
    /// strap-power constraint the capture cadence stretches twice over: the
    /// slice cadence itself is 15x slower AND the slice-count threshold
    /// doubles.
    nonisolated static let
        connectedRawCatchUpPresentCaptureShareAfterSlicesDefault = 30
    nonisolated static let
        connectedRawCatchUpConstrainedPresentCaptureShareAfterSlicesDefault = 60
    nonisolated static let
        connectedRawCatchUpPresentCaptureSharePauseSecondsDefault:
        TimeInterval = 120
    /// Margin above the idle window that any capture pause must keep so the
    /// arm path still sees a comfortably-in-the-future next evaluation by the
    /// time it runs.
    nonisolated static let
        connectedRawCatchUpPresentCaptureSharePauseMarginSeconds:
        TimeInterval = 30
    nonisolated static func connectedRawHistoryCatchUpContinuationDisposition(
        backlogPending: Bool,
        cursorCaughtUp: Bool,
        durableRows: Int,
        frontierAdvanceSeconds: TimeInterval,
        thermalState: ProcessInfo.ThermalState,
        durableProgressAuthorized: Bool,
        thermalInterruption: Bool,
        consecutiveProductiveSlices: Int,
        publicationYieldNeeded: Bool = false,
        publicationYieldRunnable: Bool = true,
        productiveDelay: TimeInterval = 2,
        dutyPauseAfterSlices: Int = 8,
        dutyPause: TimeInterval = 8,
        zeroProgressDelay: TimeInterval = 120,
        publicationYieldBudget: TimeInterval = 120,
        publicationYieldAfterSlices: Int = 1,
        strapPowerConstrained: Bool = false,
        constrainedProductiveDelay: TimeInterval = 30,
        constrainedDutyPauseAfterSlices: Int = 2,
        constrainedDutyPause: TimeInterval = 60,
        productiveSlicesSinceCaptureShare: Int = 0,
        presentCaptureShareAfterSlices: Int =
            connectedRawCatchUpPresentCaptureShareAfterSlicesDefault,
        presentCaptureSharePause: TimeInterval =
            connectedRawCatchUpPresentCaptureSharePauseSecondsDefault,
        constrainedPresentCaptureShareAfterSlices: Int =
            connectedRawCatchUpConstrainedPresentCaptureShareAfterSlicesDefault
    ) -> ConnectedRawHistoryCatchUpContinuationDisposition {
        // ITEM-4 2026-08-15: on a low-battery discharging strap the cadence
        // stretches (2s→30s between slices, long pause every 2 instead of
        // every 8) so history radio duty drops from ~99% to well under half
        // while the backlog still converges.
        let effectiveProductiveDelay = strapPowerConstrained
            ? constrainedProductiveDelay : productiveDelay
        let effectiveDutyPauseAfterSlices = strapPowerConstrained
            ? constrainedDutyPauseAfterSlices : dutyPauseAfterSlices
        let effectiveDutyPause = strapPowerConstrained
            ? constrainedDutyPause : dutyPause
        guard !cursorCaughtUp, backlogPending else { return .complete }
        let thermalDisposition = connectedRawHistoryCatchUpThermalDisposition(
            thermalState: thermalState
        )
        if thermalDisposition == .parkCritical, thermalInterruption {
            return .awaitThermalRecovery
        }
        let productive = durableProgressAuthorized
            && (durableRows > 0 || frontierAdvanceSeconds > 0)
        guard productive else {
            return .retryAfter(max(1, zeroProgressDelay))
        }
        guard thermalDisposition != .parkCritical else {
            return .awaitThermalRecovery
        }
        let nextProductiveCount = max(0, consecutiveProductiveSlices) + 1
        if publicationYieldNeeded,
           publicationYieldRunnable,
           thermalDisposition == .fullRate,
           nextProductiveCount >= max(1, publicationYieldAfterSlices) {
            return .yieldForPublication(max(1, publicationYieldBudget))
        }
        // W1-A 2026-08-20 (step-latency Step 2): the bounded capture-share
        // leg. Only sustained PRODUCTIVE drain accumulates toward it (the
        // productive guard above already returned for dry slices, whose 120s
        // retry is itself an armable idle gap). The pause is clamped so it
        // can never drop below the idle window + margin — even a
        // misconfigured caller cannot recreate a sub-idle-window interleave.
        let effectiveCaptureShareAfterSlices = strapPowerConstrained
            ? constrainedPresentCaptureShareAfterSlices
            : presentCaptureShareAfterSlices
        let nextCaptureShareCount =
            max(0, productiveSlicesSinceCaptureShare) + 1
        if nextCaptureShareCount >= max(1, effectiveCaptureShareAfterSlices) {
            return .pauseForPresentCapture(max(
                connectedRawContinuationIdleWindowSeconds
                    + connectedRawCatchUpPresentCaptureSharePauseMarginSeconds,
                presentCaptureSharePause
            ))
        }
        if nextProductiveCount >= max(1, effectiveDutyPauseAfterSlices) {
            return .resumeAfter(max(1, effectiveDutyPause))
        }
        return .resumeAfter(max(1, effectiveProductiveDelay))
    }

    /// The raw continuation is still pending during an app-facing yield, but
    /// that scheduling hint must not masquerade as archive/radio ownership.
    /// Actual transport state remains covered by the caller's independent
    /// historical-ownership predicate.
    nonisolated static func connectedRawHistoryCatchUpContinuationDefersProjection(
        continuationPending: Bool,
        publicationYieldActive: Bool
    ) -> Bool {
        continuationPending && !publicationYieldActive
    }

    /// A publication yield is finite and token-local. Success, a cleared durable
    /// intent, or completion of its one bounded offer ends it early; the absolute
    /// deadline is only the safety terminal for an offer still in flight. Closing
    /// this gate authorizes scheduling only—the next accepted 2A37 callback must
    /// still mint a new exact transport authority.
    nonisolated static func connectedRawHistoryCatchUpPublicationYieldShouldRemainActive(
        publicationNeeded: Bool,
        publicationSucceeded: Bool,
        publicationAttemptCompleted: Bool = false,
        now: Date,
        deadline: Date
    ) -> Bool {
        guard publicationNeeded,
              !publicationSucceeded,
              !publicationAttemptCompleted,
              now.timeIntervalSince(deadline) < 0 else { return false }
        return true
    }

    struct ConnectedRawHistoryCatchUpSliceProgress: Equatable {
        let durableRows: Int
        let durationSeconds: TimeInterval
        let rowsPerSecond: Double
        let frontierAdvanceSeconds: TimeInterval
    }

    nonisolated static func connectedRawHistoryCatchUpSliceProgress(
        durableRows: Int,
        startedAt: Date,
        finishedAt: Date,
        startFrontierUnix: TimeInterval,
        endFrontierUnix: TimeInterval
    ) -> ConnectedRawHistoryCatchUpSliceProgress {
        let duration = max(0.001, finishedAt.timeIntervalSince(startedAt))
        let rows = max(0, durableRows)
        return .init(
            durableRows: rows,
            durationSeconds: duration,
            rowsPerSecond: Double(rows) / duration,
            frontierAdvanceSeconds: max(
                0,
                endFrontierUnix - startFrontierUnix
            )
        )
    }

    /// Slice-progress baseline for oldest-first RAW / idle-window drain.
    /// Never the display `drainedThroughUnix` footer: a later HR-history
    /// watermark must not zero `frontier_advance_s` for ACK'd older pages.
    nonisolated static func connectedHistorySliceStartFrontierUnix(
        oldestFirstDrainCursorUnix: TimeInterval
    ) -> TimeInterval {
        guard oldestFirstDrainCursorUnix.isFinite,
              oldestFirstDrainCursorUnix > 0 else {
            return 0
        }
        return oldestFirstDrainCursorUnix
    }

    /// Same monotonic-max / future-reject rules as the display frontier, but
    /// `existing` is the oldest-first ACK cursor. A page newer than that
    /// cursor is forward progress even when it is still behind the display
    /// footer.
    nonisolated static func advancedOldestFirstHistoryDrainCursor(
        existing: TimeInterval,
        durableEffectiveUnix: [UInt32],
        now: Date,
        futureTolerance: TimeInterval = 5 * 60
    ) -> TimeInterval? {
        advancedDurableHistoricalFrontier(
            existing: existing,
            durableEffectiveUnix: durableEffectiveUnix,
            now: now,
            futureTolerance: futureTolerance
        )
    }

    /// Advances the display-only strap-history frontier exclusively from
    /// generation-fenced timestamps released by a successful canonical flush.
    /// Clock-corrupt future rows are ignored and the persisted value is never
    /// regressed. Returning nil means there is no newer trustworthy fact.
    nonisolated static func advancedDurableHistoricalFrontier(
        existing: TimeInterval,
        durableEffectiveUnix: [UInt32],
        now: Date,
        futureTolerance: TimeInterval = 5 * 60
    ) -> TimeInterval? {
        guard existing.isFinite,
              existing >= 0,
              now.timeIntervalSince1970.isFinite,
              futureTolerance.isFinite,
              futureTolerance >= 0 else { return nil }
        let ceiling = now.timeIntervalSince1970 + futureTolerance
        guard let newest = durableEffectiveUnix
            .map(TimeInterval.init)
            .filter({ $0 > 0 && $0 <= ceiling })
            .max(), newest > existing else { return nil }
        return newest
    }

    /// Coalesces a deferred transport request without erasing the authority
    /// which admitted it. This matters for debug/physical forced recovery:
    /// its evidence label is caller supplied and therefore cannot be recovered
    /// later by matching the ordinary UI-reason allowlist.
    nonisolated static func coalescedPendingOfflineHistoricalSyncRequest(
        existing: PendingOfflineHistoricalSyncRequest?,
        reason: String,
        force: Bool,
        explicitRequest: Bool,
        explicitPostWorkoutBankRequest: Bool = false,
        preserveConnectedRealtimeOwner: Bool = false
    ) -> PendingOfflineHistoricalSyncRequest {
        guard let existing else {
            return .init(reason: reason,
                         force: force,
                         explicitRequest: explicitRequest,
                         explicitPostWorkoutBankRequest:
                            explicitPostWorkoutBankRequest,
                         preserveConnectedRealtimeOwner:
                            preserveConnectedRealtimeOwner)
        }
        let incomingPriority = (explicitRequest ? 2 : 0) + (force ? 1 : 0)
        let existingPriority = (existing.explicitRequest ? 2 : 0)
            + (existing.force ? 1 : 0)
        return .init(
            reason: incomingPriority >= existingPriority
                ? reason
                : existing.reason,
            force: existing.force || force,
            explicitRequest: existing.explicitRequest || explicitRequest,
            explicitPostWorkoutBankRequest:
                existing.explicitPostWorkoutBankRequest
                    || explicitPostWorkoutBankRequest,
            preserveConnectedRealtimeOwner:
                existing.preserveConnectedRealtimeOwner
                    || preserveConnectedRealtimeOwner
        )
    }

    enum WorkoutHistoricalTransportPreemptionDisposition: Equatable {
        case noHistoryOwner
        case disconnectConnectedHistoryOwner
        case interruptOfflineHistoryOwner
    }

    /// Starting a workout outranks history commands. A local owner release is
    /// not proof that WHOOP stopped serving its current FIFO page, even when
    /// standard HR shares the link. Every connected history owner therefore
    /// crosses a physical disconnect fence before 69/01 can arm on a new epoch.
    nonisolated static func workoutHistoricalTransportPreemptionDisposition(
        syncInProgress: Bool,
        historyProbeActive: Bool,
        preservesConnectedRealtimeOwner: Bool,
        linkConnected: Bool
    ) -> WorkoutHistoricalTransportPreemptionDisposition {
        guard syncInProgress || historyProbeActive else {
            return .noHistoryOwner
        }
        _ = preservesConnectedRealtimeOwner
        return linkConnected
            ? .disconnectConnectedHistoryOwner
            : .interruptOfflineHistoryOwner
    }

    /// Retry is a state marker, not a recursion trace. Normalize any legacy
    /// chain already accumulated in memory so repeated scheduling remains
    /// bounded (`reason_retry`, never `reason_retry_retry...`).
    nonisolated static func stableRangeLossBackfillRetryReason(
        _ reason: String
    ) -> String {
        var base = reason
        while base.hasSuffix("_retry") {
            base.removeLast("_retry".count)
        }
        return "\(base)_retry"
    }

    /// A durable pending bit without its request record may be a legacy or
    /// partially-written value. Do not trade protected realtime transport for
    /// history unless the gap request has a plausible persisted timestamp.
    nonisolated static func hasValidRangeLossBackfillRequest(
        pending: Bool,
        requestedAt: Double?,
        now: Date
    ) -> Bool {
        guard pending,
              let requestedAt,
              requestedAt.isFinite,
              requestedAt > 0 else { return false }
        return requestedAt <= now.timeIntervalSince1970 + 5
    }

    /// Protected production mode may enter history transport automatically
    /// only while the radio is already down. This turns a natural reconnect
    /// into a one-shot history-first handoff without ever taking the command
    /// pipe away from healthy HR/R10. A deliberate UI request may run while
    /// connected, but it still cannot preempt an active workout or bypass the
    /// verified WHOOP 4-class capability gate.
    nonisolated static func shouldAllowProtectedHistoricalRecovery(
        linkConnected: Bool,
        exactGapPending: Bool,
        verifiedHistoryCapability: Bool,
        activeExplicitWorkout: Bool,
        syncInProgress: Bool,
        explicitUserRequest: Bool
    ) -> Bool {
        guard verifiedHistoryCapability,
              !activeExplicitWorkout,
              !syncInProgress else { return false }
        if explicitUserRequest { return true }
        // Once realtime has reconnected, the same link is the only dependable
        // place to run the queued drain. Requiring it to be disconnected races
        // the standing CoreBluetooth reconnect and starves recovery forever.
        _ = linkConnected
        return exactGapPending
    }

    nonisolated static func shouldDeferAutomaticOfflineSyncForConnectedLink(
        linkConnected: Bool,
        linkConnecting: Bool = false,
        explicitUserRequest: Bool,
        exactGapPending: Bool = false,
        verifiedMetricRecovery: Bool = false,
        automaticConnectedHandoffAllowed: Bool = false
    ) -> Bool {
        // A physical locked-phone soak disproved the former "stable connected
        // handoff": the aged gap retry cancelled an in-flight CoreBluetooth
        // reconnect, entered history twice, and left standard 2A37 stalled.
        // Connecting is never a safe history state, even for an explicit user
        // request. This subordinate policy still distinguishes explicit intent
        // from automatic work, but the global realtime-continuity gate queues
        // both until a genuinely disconnected maintenance opportunity.
        let verifiedAutomaticHandoff = automaticConnectedHandoffAllowed
            && exactGapPending
            && verifiedMetricRecovery
        return linkConnecting
            || (linkConnected && !explicitUserRequest && !verifiedAutomaticHandoff)
    }

    /// History recovery may retain and coalesce work while realtime owns (or
    /// is establishing) the physical link, but it must not start commands or
    /// manufacture a disconnect from that owner. This invariant also covers
    /// attended Sync actions and motion-bank work: user intent changes request
    /// priority, not the continuity contract. Only a history generation that
    /// is already active may continue; callback-local cutover state is never
    /// transport authority and cannot bypass a retained realtime connection.
    nonisolated static func shouldDeferHistoricalTransportForRealtimeContinuity(
        linkConnected: Bool,
        linkConnecting: Bool,
        syncInProgress: Bool
    ) -> Bool {
        (linkConnected || linkConnecting)
            && !syncInProgress
    }

    /// Admits one journal-checkpointed owner handoff from a proven healthy
    /// realtime epoch. The connected history slice keeps standard 2A37
    /// subscribed and releases the transport if accepted HR becomes stale, so
    /// a fresh sample is the safety precondition rather than a reason to starve
    /// the durable gap forever. A stale owner must first recover realtime; it
    /// cannot grant history ownership merely because its samples stopped.
    nonisolated static func shouldAttemptAutomaticConnectedHistoricalHandoff(
        linkConnected: Bool,
        exactGapPending: Bool,
        verifiedMetricRecovery: Bool,
        activeExplicitWorkout: Bool,
        syncInProgress: Bool,
        connectedAt: Date?,
        hasContact: Bool,
        acceptedSampleCount: Int,
        lastAcceptedHRAt: Date?,
        requestedAt: Date?,
        lastAttemptAt: Date?,
        now: Date,
        stableConnectionInterval: TimeInterval = 60,
        acceptedFreshnessWindow: TimeInterval = 45,
        minimumSamples: Int = 10,
        minimumGapAge: TimeInterval = 90,
        attemptCooldown: TimeInterval = 120
    ) -> Bool {
        guard linkConnected,
              exactGapPending,
              verifiedMetricRecovery,
              !activeExplicitWorkout,
              !syncInProgress,
              hasContact,
              acceptedSampleCount >= minimumSamples,
              let connectedAt,
              let lastAcceptedHRAt,
              let requestedAt else { return false }
        let connectionAge = now.timeIntervalSince(connectedAt)
        let acceptedAge = now.timeIntervalSince(lastAcceptedHRAt)
        let requestAge = now.timeIntervalSince(requestedAt)
        guard connectionAge >= stableConnectionInterval,
              acceptedAge >= 0,
              acceptedAge <= acceptedFreshnessWindow,
              requestAge >= minimumGapAge else { return false }
        if let lastAttemptAt {
            let attemptAge = now.timeIntervalSince(lastAttemptAt)
            guard attemptAge >= attemptCooldown else { return false }
        }
        return true
    }

    /// The connected-handoff admission above already enforces its own retry
    /// cooldown. Reapplying the ordinary range-loss retry interval in the
    /// transport request creates a contradictory second gate (observed as a
    /// five-minute eligible handoff immediately rejected by a ten-minute
    /// throttle). Both checks must use the same interval.
    nonisolated static func historicalAttemptMinimumInterval(
        automaticConnectedHandoff: Bool,
        ordinaryInterval: TimeInterval,
        connectedHandoffInterval: TimeInterval
    ) -> TimeInterval {
        automaticConnectedHandoff
            ? connectedHandoffInterval
            : ordinaryInterval
    }

    /// The production bootstrap must stay byte-for-byte aligned with the only
    /// physical WHOOP 4 trace that actually served historical rows:
    /// `22/00 -> post-response settle -> 16/00`. In particular, do not insert
    /// an R10/R11 stop between range and serve: that extra write was never part
    /// of the served trace and changes the strap command epoch. Standard 2A37
    /// remains subscribed throughout. High-frequency sync, abort, trim,
    /// rewind, and clock mutation are likewise excluded.
    nonisolated static func productionHistoricalRecoveryInitCommands() -> [[UInt8]] {
        [
            [Cmd.sendHistoricalData, 0x00],
        ]
    }

    /// A WHOOP historical row's inner UInt16 is a stored-record counter, not
    /// a BLE packet sequence. Full flash drains legitimately interleave record
    /// layouts and can jump that counter forward. Once the production 16/00
    /// write is confirmed and its HISTORY_START marker arrives, preserve such
    /// rows as raw, durable evidence. This grants no gap-coverage authority:
    /// timestamp/cadence proof still exclusively controls recovery settlement.
    nonisolated static func permitsRawFullDrainForwardDiscontinuity(
        fullDrainWriteConfirmed: Bool,
        historyStartReceived: Bool
    ) -> Bool {
        fullDrainWriteConfirmed && historyStartReceived
    }

    /// Stopping realtime is an invasive diagnostic precondition, not part of
    /// the production full-drain handshake. On the current physical strap it
    /// timed out and disconnected the link before history could start. Keep the
    /// healthy standard 2A37 path subscribed in production; explicit research
    /// probes retain the stop-first behavior in isolation. Idle-window drain
    /// unsubscribes 2A37 at the GATT CCCD; it must not send `0x0300` — soak
    /// 2026-08-23 03:14 confirmed 03 then failed the following 0x22 write
    /// (`history_write_22_callback_failed`, `stream5_rx=0`).
    nonisolated static func shouldStopRealtimeBeforeHistoricalRecovery(
        diagnosticSelectorOrRangeProbe: Bool,
        idleWindowStopRealtimeDrain: Bool = false
    ) -> Bool {
        // Idle-window already unsubscribed 2A37. `0x0300` is not part of
        // the served 22/00 -> 16/00 trace and poisons the next write.
        _ = idleWindowStopRealtimeDrain
        return diagnosticSelectorOrRangeProbe
    }

    /// GET_DATA_RANGE already provides the matched clock/cursor authority used
    /// by production. GET_CLOCK is optional on WHOOP 4.0 and has been observed
    /// to remain silent on a healthy strap, so it must never block serving.
    nonisolated static func shouldUseProductionHistoryReadPreflight(
        explicitRequest: Bool,
        force: Bool,
        reason: String
    ) -> Bool {
        _ = explicitRequest
        _ = force
        _ = reason
        return false
    }

    /// Offline replay is a transport operation, not a settings mutation. Restore
    /// the exact effective mode that was active before replay, including a
    /// temporary full-protocol calibration/step-capture override.
    nonisolated static func standardHROnlyModeAfterOfflineSync(
        modeBeforeSync: Bool
    ) -> Bool {
        modeBeforeSync
    }

    nonisolated static func rangeLossBackfillCanClear(newRows: Int) -> Bool {
        _ = newRows
        return false
    }

    nonisolated static func rangeLossBackfillCanClear(
        newRows: Int,
        hasRequestedWindow: Bool,
        requestedWindowMetricProgress: Bool,
        ledgerCoverageResolved: Bool = false
    ) -> Bool {
        _ = newRows
        _ = requestedWindowMetricProgress
        // Row count is never completion evidence. Ordinary disconnect recovery
        // clears only when metric-usable timestamps retired the exact durable
        // gap ledger. Exact workout recovery remains owned by SessionStore,
        // which rebuilds that workout and proves its coverage floor.
        return ledgerCoverageResolved && !hasRequestedWindow
    }

    nonisolated static func requestedRecoveryRowProvidesMetricProgress(
        metricUsable: Bool,
        effectiveUnix: UInt32?,
        requestedStart: Double,
        requestedEnd: Double
    ) -> Bool {
        guard metricUsable,
              let effectiveUnix,
              requestedStart > 0,
              requestedEnd >= requestedStart else { return false }
        let timestamp = Double(effectiveUnix)
        return timestamp >= requestedStart && timestamp <= requestedEnd
    }

    /// Uses process uptime so wall-clock corrections cannot prematurely abort
    /// an active flash transfer or postpone a genuinely stalled one forever.
    /// A missing or invalid progress marker fails closed as stalled.
    nonisolated static func historicalSyncHasStalled(
        lastProgressUptime: TimeInterval?,
        nowUptime: TimeInterval,
        idleTimeout: TimeInterval
    ) -> Bool {
        guard let lastProgressUptime,
              lastProgressUptime.isFinite,
              nowUptime.isFinite,
              idleTimeout.isFinite,
              lastProgressUptime >= 0,
              nowUptime >= lastProgressUptime,
              idleTimeout > 0 else { return true }
        return nowUptime - lastProgressUptime >= idleTimeout
    }

    /// The connected maintenance hold is intentionally stricter than the
    /// transaction watchdog. Only a recent *durable* boundary may suppress the
    /// live-HR-silence release; control traffic and retries use the broader
    /// watchdog clock but do not qualify here.
    nonisolated static func historicalSyncHasRecentDurableProgress(
        lastDurableProgressUptime: TimeInterval?,
        nowUptime: TimeInterval,
        silenceLimit: TimeInterval
    ) -> Bool {
        guard let lastDurableProgressUptime,
              lastDurableProgressUptime.isFinite,
              nowUptime.isFinite,
              silenceLimit.isFinite,
              lastDurableProgressUptime >= 0,
              nowUptime >= lastDurableProgressUptime,
              silenceLimit > 0 else { return false }
        return nowUptime - lastDurableProgressUptime < silenceLimit
    }

    /// A connected history transfer may keep producing useful archive rows
    /// after it has silenced the standard heart-rate characteristic. Progress
    /// is not permission to monopolize the user's live stream indefinitely.
    /// Release only after both a useful initial history slice and a sustained
    /// 2A37 silence; callers preserve the ingress spool and exact gap ticket.
    ///
    /// Drain-keeping P4: `productiveBacklogHold` suppresses this live-HR-silence
    /// teardown while the drain is genuinely productive and nobody is watching
    /// live HR (a real backlog, backgrounded/idle, settled + storm-free link —
    /// the P2 maintenance window — AND recent durable row progress). During a
    /// large backlog on a sleeping/still user, 2A37 is expected to be silent
    /// because history contends with it on the one pipe; tearing down a slice
    /// that is still pulling rows just forces a reconnect + cooldown and crushes
    /// the drain rate. A stalled (non-productive) slice never sets this hold, so
    /// it still releases here, and the independent GATT idle-timeout watchdog
    /// still drops a truly wedged link regardless — the durable prefix is always
    /// preserved either way.
    nonisolated static func shouldReleaseConnectedHistorySlice(
        sliceStartedAt: Date,
        lastAcceptedHeartRateAt: Date?,
        now: Date,
        minimumSliceDuration: TimeInterval,
        liveSilenceLimit: TimeInterval,
        productiveBacklogHold: Bool = false
    ) -> Bool {
        guard !productiveBacklogHold else { return false }
        guard sliceStartedAt.timeIntervalSince1970.isFinite,
              now.timeIntervalSince1970.isFinite,
              minimumSliceDuration.isFinite,
              liveSilenceLimit.isFinite,
              minimumSliceDuration > 0,
              liveSilenceLimit > 0,
              now >= sliceStartedAt,
              now.timeIntervalSince(sliceStartedAt) >= minimumSliceDuration
        else { return false }
        let liveReference = max(lastAcceptedHeartRateAt ?? sliceStartedAt,
                                sliceStartedAt)
        return now.timeIntervalSince(liveReference) >= liveSilenceLimit
    }

    /// A replayed frame proves that the BLE callback path is alive, but it does
    /// not prove that the strap cursor or our durable prefix advanced. Counting
    /// duplicate persistence as progress lets an endless replay suppress the
    /// idle reset forever.
    nonisolated static func historicalFrameRenewsIdleLease(
        persistenceSucceeded: Bool,
        insertedNewFrame: Bool
    ) -> Bool {
        persistenceSucceeded && insertedNewFrame
    }

    /// Historical offload shares the strap command pipe with realtime capture.
    /// Protect every healthy connected stream, not only the optional long-wear
    /// mode. A short connect grace prevents an old pending recovery request from
    /// seizing the pipe before the first fresh pulse can arrive after launch.
    nonisolated static func shouldProtectConnectedLinkForOfflineSync(
        connected: Bool,
        connectedAt: Date?,
        hasContact: Bool,
        acceptedSampleCount: Int,
        lastAcceptedHRAt: Date?,
        now: Date,
        connectGrace: TimeInterval = 60,
        minimumSamples: Int = 10,
        acceptedFreshnessWindow: TimeInterval = 30
    ) -> Bool {
        guard connected else { return false }
        if let connectedAt {
            let age = now.timeIntervalSince(connectedAt)
            if age >= 0, age <= connectGrace { return true }
        }
        guard hasContact,
              acceptedSampleCount >= minimumSamples,
              let lastAcceptedHRAt else { return false }
        let age = now.timeIntervalSince(lastAcceptedHRAt)
        return age >= 0 && age <= acceptedFreshnessWindow
    }
}
