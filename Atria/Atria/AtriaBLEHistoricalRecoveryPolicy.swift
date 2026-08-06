import Foundation

/// Read-only WHOOP 4 ring-buffer cursor observation returned by
/// GET_DATA_RANGE (0x22/00). These offsets are relative to the decoded command
/// response payload `[24,responseSeq,22,requestSeq,data...]` and mirror the
/// physically verified W/U/T layout. The observation never authorizes a trim,
/// acknowledgement, rewind, or local gap deletion.
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
            || reason == "pull_to_refresh"
            || reason == "home_missed_data_banner"
            || reason == "onboarding_initial_import"
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
        explicitPostWorkoutBankRequest: Bool = false
    ) -> PendingOfflineHistoricalSyncRequest {
        guard let existing else {
            return .init(reason: reason,
                         force: force,
                         explicitRequest: explicitRequest,
                         explicitPostWorkoutBankRequest:
                            explicitPostWorkoutBankRequest)
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
                    || explicitPostWorkoutBankRequest
        )
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
        // request; queue it until didConnect finishes. Once connected, only a
        // deliberate user action may take ownership of the shared command pipe.
        // Automatic recovery remains durable in the gap ledger and waits for a
        // genuinely disconnected maintenance opportunity.
        let verifiedAutomaticHandoff = automaticConnectedHandoffAllowed
            && exactGapPending
            && verifiedMetricRecovery
        return linkConnecting
            || (linkConnected && !explicitUserRequest && !verifiedAutomaticHandoff)
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
    /// probes retain the stop-first behavior in isolation.
    nonisolated static func shouldStopRealtimeBeforeHistoricalRecovery(
        diagnosticSelectorOrRangeProbe: Bool
    ) -> Bool {
        diagnosticSelectorOrRangeProbe
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
