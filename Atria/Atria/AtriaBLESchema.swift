import Foundation
import CoreBluetooth

/// Literal-only identifiers and persistence keys used by `AtriaBLEManager`.
///
/// Keeping these declarations nested preserves the existing API while moving
/// protocol schema away from the manager's stateful transport implementation.
extension AtriaBLEManager {
    // MARK: GATT identifiers (discovered from the device)

    enum UUIDs {
        // Standard services
        static let heartRateService   = CBUUID(string: "180D")
        static let heartRateMeasure   = CBUUID(string: "2A37")
        static let batteryService     = CBUUID(string: "180F")
        static let batteryLevel       = CBUUID(string: "2A19")
        static let batteryLevelStatus = CBUUID(string: "2A1B")
        static let deviceInfoService  = CBUUID(string: "180A")
        static let manufacturerName   = CBUUID(string: "2A29")
        static let modelNumber        = CBUUID(string: "2A24")
        static let firmwareRevision   = CBUUID(string: "2A26")
        static let hardwareRevision   = CBUUID(string: "2A27")

        // strap proprietary service + characteristics
        static let strapService = CBUUID(string: "61080001-8d6d-82b8-614a-1c8cb0f8dcc6")
        static let strapTX      = CBUUID(string: "61080002-8d6d-82b8-614a-1c8cb0f8dcc6") // write (commands)
        static let strapRX      = CBUUID(string: "61080003-8d6d-82b8-614a-1c8cb0f8dcc6") // notify (responses)
        static let strapStream4 = CBUUID(string: "61080004-8d6d-82b8-614a-1c8cb0f8dcc6") // notify (data)
        static let strapStream5 = CBUUID(string: "61080005-8d6d-82b8-614a-1c8cb0f8dcc6") // notify (data)
        static let strapStream7 = CBUUID(string: "61080007-8d6d-82b8-614a-1c8cb0f8dcc6") // notify (data)

        static let allNotify = [strapRX, strapStream4, strapStream5, strapStream7]
        /// Production full-drain needs only the command response and the
        /// physically verified historical-data channel. A direct WHOOP 4.0
        /// capture on 2026-07-19 delivered every type-47 row on stream 5 after
        /// `SEND_HISTORICAL_DATA(0x16/00)`; stream 4 carried none. Keep stream 7
        /// and the unrelated stream 4 CCCD untouched during retained-gap retry.
        /// Research selector/range probes may still opt into `allNotify`.
        static let productionHistoryNotify = [strapRX, strapStream5]
        /// Explicit physical-research profile. It changes CCCD subscriptions
        /// only: no realtime/high-frequency command is sent. Keeping this
        /// separate from `productionHistoryNotify` prevents an unproven
        /// historical-IMU channel from silently expanding the shipping drain.
        static func historyNotifyCharacteristics(observeMotionChannels: Bool) -> [CBUUID] {
            observeMotionChannels ? allNotify : productionHistoryNotify
        }
        /// A fresh production history owner is still the live-HR owner. Discover
        /// the standard services on that same link so waiting for history can
        /// never strand the active journal. Battery is discovery-only here; its
        /// existing history fence suppresses reads/CCCD repair while the drain
        /// owns the link.
        static let productionHistoryServices = [strapService, heartRateService, batteryService]
        static let scanServices = [strapService, heartRateService]
        static let discoveryServices = [heartRateService, batteryService, deviceInfoService, strapService]
    }

    enum CheckpointDefaults {
        static let armed = "atria.checkpoint.armed"
        static let interval = "atria.checkpoint.interval"
        static let label = "atria.checkpoint.label"
        static let source = "atria.checkpoint.source"
        static let lastStatus = "atria.checkpoint.lastStatus"
        static let lastIndex = "atria.checkpoint.lastIndex"
        static let lastSamples = "atria.checkpoint.lastSamples"
        static let lastDuration = "atria.checkpoint.lastDuration"
    }

    enum LinkDefaults {
        static let attempts = "atria.link.attempts"
        static let disconnects = "atria.link.disconnects"
        static let successes = "atria.link.successes"
        static let failures = "atria.link.failures"
        static let lastStatus = "atria.link.lastStatus"
        static let lastReason = "atria.link.lastReason"
        static let lastError = "atria.link.lastError"
        static let lastAutoSaveStatus = "atria.link.lastAutoSaveStatus"
        static let lastAutoSaveSamples = "atria.link.lastAutoSaveSamples"
        static let lastAutoSaveDuration = "atria.link.lastAutoSaveDuration"
        static let lastDisconnectCause = "atria.link.lastDisconnectCause"
        static let lastDisconnectAt = "atria.link.lastDisconnectAt"
        static let disconnectsThisLaunch = "atria.link.disconnectsThisLaunch"
        static let officialAppCoexistenceRisk = "atria.link.officialAppCoexistenceRisk"
        static let officialAppCoexistenceReason = "atria.link.officialAppCoexistenceReason"
        /// The CoreBluetooth identifier of the strap the user paired with. Once set,
        /// Atria maintains a standing pending connection to it forever (reconnects
        /// across range loss + app relaunch) until the user explicitly forgets it.
        static let savedPeripheralUUID = "atria.link.savedPeripheralUUID"
    }

    enum SampleDefaults {
        static let rawNotifications = "atria.sample.rawNotifications"
        static let acceptedSamples = "atria.sample.acceptedSamples"
        static let zeroSamples = "atria.sample.zeroSamples"
        static let heldArtifacts = "atria.sample.heldArtifacts"
        static let droppedArtifacts = "atria.sample.droppedArtifacts"
        static let rawGaps = "atria.sample.rawGaps"
        static let acceptedGaps = "atria.sample.acceptedGaps"
        static let maxRawGap = "atria.sample.maxRawGap"
        static let maxAcceptedGap = "atria.sample.maxAcceptedGap"
        static let lastStatus = "atria.sample.lastStatus"
        static let lastReason = "atria.sample.lastReason"
        static let lastRawNotificationAt = "atria.sample.lastRawNotificationAt"
    }

    enum StrapStreamDefaults {
        static let state = "atria.strapStream.state"
        static let reason = "atria.strapStream.reason"
        static let packetAge = "atria.strapStream.packetAge"
        static let batteryLevel = "atria.strapStream.batteryLevel"
        static let notifying = "atria.strapStream.notifying"
        static let gattReadsOK = "atria.strapStream.gattReadsOK"
        static let updatedAt = "atria.strapStream.updatedAt"
        static let lowBatteryReconnectSuppressed = "atria.strapStream.lowBatteryReconnectSuppressed"
        static let lowBatteryReconnectSuppressedAt = "atria.strapStream.lowBatteryReconnectSuppressedAt"
        static let lowBatteryReconnectSuppressionReason = "atria.strapStream.lowBatteryReconnectSuppressionReason"
        static let lowBatteryReconnectSuppressionCount = "atria.strapStream.lowBatteryReconnectSuppressionCount"
        static let lowBatteryReconnectRearmedAt = "atria.strapStream.lowBatteryReconnectRearmedAt"
        static let accessibilityLabel = "atria.strapStream.accessibilityLabel"
    }

    /// Callback-stage breadcrumbs for locked reconnect forensics.
    /// State-restoration relaunches carry no debug launch arguments, so the
    /// rolling trail records every lease stage executed before suspension.
    enum ReconnectLeaseDefaults {
        /// Rolling newline-separated `unix|stage|detail` tail.
        static let trail = "atria.reconnectLease.trail"
    }

    enum BackgroundHRDiscoveryDefaults {
        static let stage = "atria.backgroundHRDiscovery.stage"
        static let at = "atria.backgroundHRDiscovery.at"
        static let epoch = "atria.backgroundHRDiscovery.epoch"
        static let peripheralID = "atria.backgroundHRDiscovery.peripheralID"
        static let cachedService = "atria.backgroundHRDiscovery.cachedService"
        static let cachedCharacteristic = "atria.backgroundHRDiscovery.cachedCharacteristic"
        static let notifying = "atria.backgroundHRDiscovery.notifying"
        static let error = "atria.backgroundHRDiscovery.error"
    }

    enum HRContinuityDefaults {
        static let status = "atria.hrContinuity.status"
        static let action = "atria.hrContinuity.action"
        static let rawGap = "atria.hrContinuity.rawGap"
        static let acceptedGap = "atria.hrContinuity.acceptedGap"
        static let timeout = "atria.hrContinuity.timeout"
        static let samples = "atria.hrContinuity.samples"
        static let label = "atria.hrContinuity.label"
        static let notifying = "atria.hrContinuity.notifying"
        static let at = "atria.hrContinuity.at"
    }

    enum RRPresenceDefaults {
        static let status = "atria.rrPresence.status"
        static let action = "atria.rrPresence.action"
        static let rrGap = "atria.rrPresence.rrGap"
        static let acceptedGap = "atria.rrPresence.acceptedGap"
        static let timeout = "atria.rrPresence.timeout"
        static let samples = "atria.rrPresence.samples"
        static let rrValues = "atria.rrPresence.rrValues"
        static let consecutive = "atria.rrPresence.consecutive"
        static let label = "atria.rrPresence.label"
        static let lastPacketRRFlagPresent = "atria.rrPresence.lastPacketRRFlagPresent"
        static let lastPacketContactSupported = "atria.rrPresence.lastPacketContactSupported"
        static let lastPacketContactDetected = "atria.rrPresence.lastPacketContactDetected"
        static let at = "atria.rrPresence.at"
    }

    enum WatchdogRecoveryDefaults {
        static let noDataCount = "atria.watchdog.noDataCount"
        static let hrContinuityCount = "atria.watchdog.hrContinuityCount"
        static let acceptedHRCount = "atria.watchdog.acceptedHRCount"
        static let rrPresenceCount = "atria.watchdog.rrPresenceCount"
        static let lastStatus = "atria.watchdog.lastStatus"
        static let lastSource = "atria.watchdog.lastSource"
        static let lastAction = "atria.watchdog.lastAction"
        static let lastRawGap = "atria.watchdog.lastRawGap"
        static let lastAcceptedGap = "atria.watchdog.lastAcceptedGap"
        static let lastSamples = "atria.watchdog.lastSamples"
        static let lastCheckpoint = "atria.watchdog.lastCheckpoint"
        static let lastAt = "atria.watchdog.lastAt"
    }

    enum BatteryDefaults {
        static let level = "atria.battery.level"
        static let at = "atria.battery.at"
        static let source = "atria.battery.source"
        /// Last accepted non-sentinel 2A19 value. Boundary packets are known to
        /// replay during restoration, so this survives their quarantine and is
        /// the only safe baseline for judging a later 0/10/100 transition.
        static let credibleLevel = "atria.battery.credibleLevel"
        static let credibleAt = "atria.battery.credibleAt"
        static let chargeStatus = "atria.battery.chargeStatus"
        static let chargeAt = "atria.battery.chargeAt"
        static let previousLevel = "atria.battery.previousLevel"
        static let previousAt = "atria.battery.previousAt"
        static let dropAt = "atria.battery.dropAt"
        static let dropDelta = "atria.battery.dropDelta"
        static let requiresFreshConfirmation = "atria.battery.requiresFreshConfirmation"
        /// Renewed only while an error-free 2A19 value from this connection has
        /// already been accepted and its notification subscription remains
        /// active. BAS notifications are change-driven, so silence while the
        /// CCCD is active means the integer percentage has not changed.
        static let notificationLeaseAt = "atria.battery.notificationLeaseAt"
        static let notificationRequestedAt = "atria.battery.notificationRequestedAt"
        static let notificationConfirmedAt = "atria.battery.notificationConfirmedAt"
        static let notificationLastError = "atria.battery.notificationLastError"
        static let notificationLastCallbackAt = "atria.battery.notificationLastCallbackAt"
        static let statusProperties = "atria.battery.status.properties"
        static let statusReadRequestedAt = "atria.battery.status.readRequestedAt"
        static let statusReadCallbackAt = "atria.battery.status.readCallbackAt"
        static let statusReadLastError = "atria.battery.status.readLastError"
        static let statusNotificationRequestedAt = "atria.battery.status.notificationRequestedAt"
        static let statusNotificationConfirmedAt = "atria.battery.status.notificationConfirmedAt"
        static let proprietaryRefreshLastAttemptAt = "atria.battery.proprietaryRefresh.lastAttemptAt"
        static let proprietaryRefreshLastSuccessAt = "atria.battery.proprietaryRefresh.lastSuccessAt"
        static let proprietaryRefreshCircuitOpenUntil = "atria.battery.proprietaryRefresh.circuitOpenUntil"
        static let proprietaryRefreshPending = "atria.battery.proprietaryRefresh.pending"
        static let proprietaryRefreshLastFailure = "atria.battery.proprietaryRefresh.lastFailure"
        static let proprietaryRefreshRecoveryMigrated = "atria.battery.proprietaryRefresh.recoveryMigratedV2"
        static let proprietaryRefreshRecoveryPending = "atria.battery.proprietaryRefresh.recoveryPending"
    }

    /// Charge-pattern learning (docs/24 §14.2 deferred item): a rolling record of
    /// the local hour-of-day whenever the strap is newly observed to start
    /// charging, so LocalNotificationScheduler can nudge the user near their
    /// usual charge time once a low-battery reading lands outside a charge.
    enum ChargePatternDefaults {
        static let hours = "atria.chargePattern.hours"
        static let lastRecordedAt = "atria.chargePattern.lastRecordedAt"
    }

    enum RadioDefaults {
        static let standardHROnly = "atria.radio.standardHROnly"
        static let standardHROnlyUserSelected = "atria.radio.standardHROnlyUserSelected"
        static let mode = "atria.radio.mode"
        static let customNotifySkipped = "atria.radio.customNotifySkipped"
        static let customNotifyEnabled = "atria.radio.customNotifyEnabled"
        static let txSkipped = "atria.radio.txSkipped"
        static let realtimeStartSkipped = "atria.radio.realtimeStartSkipped"
        static let lastReason = "atria.radio.lastReason"
        static let passiveR10Status = "atria.radio.passiveR10Status"
        static let passiveR10SubscribedAt = "atria.radio.passiveR10SubscribedAt"
        static let passiveR10FirstValidAt = "atria.radio.passiveR10FirstValidAt"
        static let passiveR10LastValidAt = "atria.radio.passiveR10LastValidAt"
        static let passiveR10ValidFrames = "atria.radio.passiveR10ValidFrames"
    }

    enum WorkoutMotionDefaults {
        static let ownerStartedAt = "atria.workoutMotion.ownerStartedAt"
        static let status = "atria.workoutMotion.status"
        static let statusAt = "atria.workoutMotion.statusAt"
        static let gapStartedAt = "atria.workoutMotion.gapStartedAt"
        static let firstLiveFrameAt = "atria.workoutMotion.firstLiveFrameAt"
        static let lastLiveFrameAt = "atria.workoutMotion.lastLiveFrameAt"
        static let activationAttemptAt = "atria.workoutMotion.activationAttemptAt"
        static let activationConnectionAt = "atria.workoutMotion.activationConnectionAt"
        static let activationAttempts = "atria.workoutMotion.activationAttempts"
        static let boundaryStartedAt = "atria.workoutMotion.boundaryStartedAt"
        static let backfillPending = "atria.workoutMotion.backfillPending"
        static let backfillReason = "atria.workoutMotion.backfillReason"
        static let allDayEnabled = "atria.allDayMotion.enabled"
        static let allDaySuspendedForBattery = "atria.allDayMotion.suspendedForBattery"
    }

    enum CaptureDefaults {
        static let configured = "atria.capture.defaultsConfigured"
        static let protectedLongWearMigrated = "atria.capture.protectedLongWearMigrated"
        /// The old Settings surface exposed an all-day capture toggle. That
        /// control was removed when continuous strap collection became Atria's
        /// core behavior, but existing installs could remain silently disabled
        /// forever. Migrate that orphaned state exactly once.
        static let alwaysOnLongWearMigrated = "atria.capture.alwaysOnLongWearMigratedV1"
        static let strapStepFullProtocolMigrated = "atria.capture.strapStepFullProtocolMigrated"
        /// V2 replaces the unstable broad proprietary profile with the
        /// physically verified minimal 2A37 + stream-5 R10 transport. Keep a
        /// separate key because every existing install already consumed the
        /// older full-protocol migration.
        static let stableR10TransportMigrated = "atria.capture.stableR10TransportMigratedV2"
    }

    enum LongWearDefaults {
        static let enabled = "atria.longWear.enabled"
        static let userSelected = "atria.longWear.userSelected"
        static let checkpointInterval = "atria.longWear.checkpointInterval"
        static let diagnosticInterval = "atria.longWear.diagnosticInterval"
        static let workoutAutoSaveInterval = "atria.longWear.workoutAutoSaveInterval"
        static let noDataTimeout = "atria.longWear.noDataTimeout"
        static let noDataCheckInterval = "atria.longWear.noDataCheckInterval"
        static let acceptedHRTimeout = "atria.longWear.acceptedHRTimeout"
        static let label = "atria.longWear.label"
    }

    enum OfflineSyncDefaults {
        static let enabled = "atria.offlineSync.enabled"
        static let lastAttemptAt = "atria.offlineSync.lastAttemptAt"
        static let lastStatus = "atria.offlineSync.lastStatus"
        static let lastReason = "atria.offlineSync.lastReason"
        static let attempts = "atria.offlineSync.attempts"
        static let rangeLossBackfillPending = "atria.offlineSync.rangeLossBackfillPending"
        static let rangeLossBackfillRequestedAt = "atria.offlineSync.rangeLossBackfillRequestedAt"
        static let rangeLossBackfillStartedAt = "atria.offlineSync.rangeLossBackfillStartedAt"
        static let rangeLossBackfillReason = "atria.offlineSync.rangeLossBackfillReason"
        static let recoveryWindowStart = "atria.offlineSync.recoveryWindowStart"
        static let recoveryWindowEnd = "atria.offlineSync.recoveryWindowEnd"
        static let verifiedHistoryPeripheralID = "atria.offlineSync.verifiedHistoryPeripheralID"
        static let rawArchivedGapFingerprint = "atria.offlineSync.rawArchivedGapFingerprint.v1"
        static let rawArchivedGapAt = "atria.offlineSync.rawArchivedGapAt.v1"
        /// A terminal, live-restored history transaction returned no durable
        /// rows for this exact gap set. Retain the gap and diagnostic evidence,
        /// but do not let automatic reconnect recovery seize the radio again
        /// until the gap fingerprint changes. Explicit user retries bypass it.
        static let noRowsGapFingerprint = "atria.offlineSync.noRowsGapFingerprint.v1"
        static let noRowsGapAt = "atria.offlineSync.noRowsGapAt.v1"
        /// Convergence state for a drain that repeatedly dies on the same
        /// flash sequence discontinuity (`history_sequence_gap_*`) for the
        /// same exact durable gap set (observed re-arming 2026-08-06 →
        /// 2026-08-13). Attempts are counted per gap fingerprint; at the
        /// budget the ticket parks as a truthful TERMINAL unavailable
        /// interval: pending stays true (data-quality truth, excluded from
        /// "Synced"), but the automatic lane stops re-arming. A changed gap
        /// fingerprint or a materially newer drained frontier mints exactly
        /// one fresh attempt; a minute ticker, relaunch, charging edge, or
        /// unchanged replay does not. Explicit user repair always bypasses.
        static let sequenceGapFingerprint = "atria.offlineSync.sequenceGapFingerprint.v1"
        static let sequenceGapAttempts = "atria.offlineSync.sequenceGapAttempts.v1"
        static let sequenceGapParkedAt = "atria.offlineSync.sequenceGapParkedAt.v1"
        static let sequenceGapParkedFrontierUnix = "atria.offlineSync.sequenceGapParkedFrontierUnix.v1"
        static let sequenceGapLastReason = "atria.offlineSync.sequenceGapLastReason.v1"
        /// A confirmed full-drain request can still time out before HISTORY_START.
        /// That is not proof the strap has no data, so the gap remains pending;
        /// it is, however, enough evidence that automatic ownership must not
        /// keep disconnecting a healthy live link for this unchanged gap.
        /// Explicit user repairs intentionally bypass this circuit breaker.
        static let historyStartTimeoutGapFingerprint =
            "atria.offlineSync.historyStartTimeoutGapFingerprint.v1"
        static let historyStartTimeoutGapAt =
            "atria.offlineSync.historyStartTimeoutGapAt.v1"
        /// Binds a timeout circuit-breaker to the exact non-mutating bootstrap
        /// profile that produced it. A later profile correction gets one fresh
        /// recovery opportunity for the retained gap; the same profile does
        /// not repeatedly churn a healthy live connection.
        static let historyStartTimeoutProfileVersion =
            "atria.offlineSync.historyStartTimeoutProfileVersion.v1"
        /// An iOS process expiry can interrupt an otherwise valid full-drain
        /// transaction after HISTORY_START. Remember the exact durable gap
        /// that has consumed the one automatic post-reconnect re-acquisition,
        /// so restoring live HR never turns into a reconnect loop.
        static let interruptedFullDrainReacquisitionGapFingerprint =
            "atria.offlineSync.interruptedFullDrainReacquisitionGapFingerprint.v1"
        static let interruptedFullDrainReacquisitionAt =
            "atria.offlineSync.interruptedFullDrainReacquisitionAt.v1"
        /// True when the most recent drain attempt received at least one
        /// stream-5 row. A productive strap is exempt from the reacquisition
        /// cooldown; only a no-rows attempt is throttled.
        static let lastDrainAttemptYieldedRows =
            "atria.offlineSync.lastDrainAttemptYieldedRows.v1"
        static let backgroundLeaseStatus = "atria.offlineSync.backgroundLeaseStatus.v1"
        static let backgroundLeaseAt = "atria.offlineSync.backgroundLeaseAt.v1"
        /// A connected history serve may continue making archive progress
        /// after standard 2A37 has gone silent. Bound that ownership epoch,
        /// preserve its durable prefix, and give live HR a cooldown before a
        /// later background slice retries.
        static let connectedSliceStatus =
            "atria.offlineSync.connectedSliceStatus.v1"
        static let connectedSliceAt =
            "atria.offlineSync.connectedSliceAt.v1"
        static let connectedSliceCooldownUntil =
            "atria.offlineSync.connectedSliceCooldownUntil.v1"
        static let handshakeStatus = "atria.offlineSync.handshakeStatus.v1"
        static let handshakeAt = "atria.offlineSync.handshakeAt.v1"
        static let lastWriteErrorDomain = "atria.offlineSync.lastWriteErrorDomain.v1"
        static let lastWriteErrorCode = "atria.offlineSync.lastWriteErrorCode.v1"
        static let lastWriteErrorDescription = "atria.offlineSync.lastWriteErrorDescription.v1"
        static let lastWriteErrorAt = "atria.offlineSync.lastWriteErrorAt.v1"
        static let lastDrainFailure = "atria.offlineSync.lastDrainFailure.v1"
        static let lastDrainFailureAt = "atria.offlineSync.lastDrainFailureAt.v1"
        static let lastDrainFailureGeneration = "atria.offlineSync.lastDrainFailureGeneration.v1"
        static let lastDrainFailurePhase = "atria.offlineSync.lastDrainFailurePhase.v1"
        static let lastDrainFailurePendingPersistence = "atria.offlineSync.lastDrainFailurePendingPersistence.v1"
        static let lastDrainFailurePersistedFrames = "atria.offlineSync.lastDrainFailurePersistedFrames.v1"
        static let lastDrainFailureAcknowledgedBatches = "atria.offlineSync.lastDrainFailureAcknowledgedBatches.v1"
        static let lastDurableFlushError = "atria.offlineSync.lastDurableFlushError.v1"
        static let lastDurableFlushErrorAt = "atria.offlineSync.lastDurableFlushErrorAt.v1"
        static let lastDurableFlushBoundary = "atria.offlineSync.lastDurableFlushBoundary.v1"
        // Truthful "last durable flush SUCCEEDED at" timestamp. lastDurableFlushBoundary
        // above is a last-ERROR value (froze while segments still landed → misleading
        // for triage); this is the success-path progress signal.
        static let lastDurableFlushBoundaryOKAt = "atria.offlineSync.lastDurableFlushBoundaryOKAt.v1"
        // Drain frontier: the newest strap-history record durably in the local
        // archive (corrected unix). Written by the archive-status refresh so
        // the sync-progress footer can show "synced through …" without asking
        // BLE anything. Display-only — never a drain decision input.
        static let drainedThroughUnix = "atria.offlineSync.drainedThroughUnix.v1"
        // Oldest-first persist-before-ACK cursor. Distinct from
        // `drainedThroughUnix` (newest-ever display footer). WHOOP 4.0 has no
        // seek; ACK'd pages climb this key even when their timestamps sit
        // behind the display frontier. Slice `frontier_advance_s` is this
        // cursor, not the display key (charging soak 2026-08-23: persisted>0
        // with frontier_advance_s=0.000 on every slice).
        static let historyDrainCursorUnix =
            "atria.offlineSync.historyDrainCursorUnix.v1"
        /// Last idle-window 0x22 taken before a confirmed ACK. The next
        /// slice's 0x22 is the after-ACK snapshot (intra-slice 0x22 after
        /// ACK does not get a WHOOP 4.0 command response).
        static let idleWindowAckedRangeWriteCursor =
            "atria.offlineSync.idleWindowAckedRange.writeCursor.v1"
        static let idleWindowAckedRangeReadCursor =
            "atria.offlineSync.idleWindowAckedRange.readCursor.v1"
        static let idleWindowAckedRangePending =
            "atria.offlineSync.idleWindowAckedRange.pending.v1"
        // Clean-slate durability (2026-08-22): the instant the user tapped
        // "Start fresh" to abandon an unrecoverable, un-drainable banked
        // backlog. Monotonic (only ever moves forward), per verified-history
        // peripheral. While set AND the drain frontier has not advanced past it
        // (no genuinely new post-reset data), the backlog detectors treat the
        // strap's re-presented pre-reset records as .none so the app stops
        // initiating the history reads that a degraded strap drops the link on —
        // stopping the self-sustaining "history incomplete" storm at its source.
        static let historyAbandonedThroughUnix =
            "atria.offlineSync.historyAbandonedThroughUnix.v1"
        /// Drain cursor at the moment a terminal zero-row stall was accepted.
        /// `markRangeLossBackfillRequired` must not re-arm the same unfillable
        /// interval until this cursor actually advances. Distinct from Start
        /// fresh's `historyAbandonedThroughUnix` — that watermark is `now` and
        /// must not be shown as "newest record".
        static let unrecoverableHistoryAcceptedCursorUnix =
            "atria.offlineSync.unrecoverableHistoryAcceptedCursorUnix.v1"
        // Clean-slate auto-surfacing: persisted mirror of the in-memory
        // consecutive zero-progress catch-up slice counter. A degraded strap
        // that drops the link on every history read accumulates these (each
        // slice yields durable_rows=0 / no frontier advance); any real progress
        // resets it to 0. This is the un-foolable "history isn't draining"
        // signal — unlike flush/frontier timestamps, which 0-row offloads and
        // live data keep fresh. Drives the "Strap can't catch up → Start fresh"
        // offer once it crosses the terminal threshold.
        static let consecutiveZeroProgressSlices =
            "atria.offlineSync.consecutiveZeroProgressSlices.v1"
        // Drain-keeping P3: last time the HR-independent maintenance ticker
        // re-armed the range-loss drain because the normal (accepted-HR-driven)
        // re-arm loop had gone silent past its floor. A moving value here while a
        // backlog persists is the on-device signal that the anti-divergence
        // backstop is carrying the drain through an HR-sparse (asleep) window.
        static let lastMaintenanceReArmAt = "atria.offlineSync.lastMaintenanceReArmAt.v1"
        // Drain-keeping P6 (flush-debt tracker): the strap-side backlog made a
        // first-class, persisted signal. `flushDebtPendingRecords` is the last
        // observed ring-buffer pending_records (0x22 getDataRange); at the ~1 Hz
        // banking cadence a record is roughly one second of banked data, so this
        // doubles as an approximate time-behind. `flushDebtLevel` is the
        // classified level (caught_up / low / high) that escalation keys off.
        static let flushDebtPendingRecords = "atria.offlineSync.flushDebtPendingRecords.v1"
        static let flushDebtObservedAt = "atria.offlineSync.flushDebtObservedAt.v1"
        static let flushDebtLevel = "atria.offlineSync.flushDebtLevel.v1"
        // Handoff-9 CP2: JSON-encoded AtriaHistoricalDurableProductiveSliceReceipt —
        // the exact generation-scoped proof of the last finished history slice.
        // Written only from the final durable boundary; the sole permission for
        // the fast connected retry cadence.
        static let durableProductiveSliceReceipt =
            "atria.offlineSync.durableProductiveSliceReceipt.v1"
        /// Durable receipt for a materialization-lane ceiling release.
        /// The release path logged only to ATRIADBG (stdout), which made a
        /// firing unprovable after the fact — see the 2026-08-19 field note.
        static let materializationLaneCeilingReceipt =
            "atria.offlineSync.materializationLaneCeilingReceipt.v1"
    }

    enum KeepaliveDefaults {
        static let armed = "atria.keepalive.armed"
        static let armedAt = "atria.keepalive.armedAt"
        static let lastStatus = "atria.keepalive.lastStatus"
        static let lastReason = "atria.keepalive.lastReason"
        static let lastAction = "atria.keepalive.lastAction"
        static let lastSilence = "atria.keepalive.lastSilence"
        static let tickStartedAt = "atria.keepalive.tickStartedAt"
        static let lastTickAt = "atria.keepalive.lastTickAt"
        static let lastPeripheralState = "atria.keepalive.lastPeripheralState"
        static let lastRawNotifications = "atria.keepalive.lastRawNotifications"
        static let lastRawNotificationDelta = "atria.keepalive.lastRawNotificationDelta"
        static let lastSampleCheckAt = "atria.keepalive.lastSampleCheckAt"
        static let ticks = "atria.keepalive.ticks"
        static let stallReconnects = "atria.keepalive.stallReconnects"
        static let lastStallReconnectAt = "atria.keepalive.lastStallReconnectAt"
        static let lastReadPollAt = "atria.keepalive.lastReadPollAt"
        static let lastReadPollResultAt = "atria.keepalive.lastReadPollResultAt"
        static let lastReadPollResultStatus = "atria.keepalive.lastReadPollResultStatus"
        static let lastReadPollResultBPM = "atria.keepalive.lastReadPollResultBPM"
        static let lastReadPollResultRRValues = "atria.keepalive.lastReadPollResultRRValues"
    }

    enum CollectionProfileDefaults {
        static let profile = "atria.collection.profile"
        /// Whether the user-triggered "catch up faster" boost is currently on
        /// (temporarily forces the Coverage profile to drain a large backlog).
        static let catchUpBoostActive = "atria.collection.catchUpBoost.active.v1"
        /// The profile raw value to restore when the boost auto-reverts after
        /// the strap catches up.
        static let catchUpBoostRestoreProfile =
            "atria.collection.catchUpBoost.restoreProfile.v1"
    }

    enum DutyCycleDefaults {
        static let enabled = "atria.dutycycle.enabled"
        static let focusFullCapture = "atria.dutycycle.focusFullCapture"
        static let sleepWindowStartMin = "atria.dutycycle.sleepWindowStartMin"
        static let sleepWindowEndMin = "atria.dutycycle.sleepWindowEndMin"
    }

    enum Packet {
        static let command: UInt8 = 0x23
        static let realtime: UInt8 = 0x28
        static let realtimeRaw: UInt8 = 0x2B
        static let historical: UInt8 = 0x2f
        static let event: UInt8 = 0x30
        static let metadata: UInt8 = 0x31
        static let imu: UInt8 = 0x33
    }

    enum ProtocolDefaults {
        static let packets = "atria.protocol.packets"
        static let imuFrames = "atria.protocol.imuFrames"
        static let diagnosticFrames = "atria.protocol.diagnosticFrames"
        static let eventFrames = "atria.protocol.eventFrames"
        static let unknownFrames = "atria.protocol.unknownFrames"
        static let lastPacketType = "atria.protocol.lastPacketType"
        static let lastPacketKind = "atria.protocol.lastPacketKind"
        static let lastPacketLength = "atria.protocol.lastPacketLength"
    }

    enum Cmd {
        static let linkValid: UInt8 = 0x01
        static let toggleRealtimeHR: UInt8 = 0x03
        static let setClock: UInt8 = 0x0A
        static let getClock: UInt8 = 0x0B
        static let abortHistoricalTransmits: UInt8 = 0x14
        /// Official WHOOP 4 FORCE_TRIM / erase-device (payload FE×8 + 00).
        static let forceTrim: UInt8 = 0x19
        static let getBatteryLevel: UInt8 = 0x1A
        static let sendHistoricalData: UInt8 = 0x16
        static let historicalDataResult: UInt8 = 0x17
        static let getDataRange: UInt8 = 0x22
        static let sendR10R11Realtime: UInt8 = 0x3F
        static let runHapticsPattern: UInt8 = 0x4F
        static let startRawData: UInt8 = 0x51
        static let stopRawData: UInt8 = 0x52
        static let toggleIMUModeHistorical: UInt8 = 0x69
        static let toggleIMUMode: UInt8 = 0x6A
        /// Observed normal GEN4 compact-HR/IMU sequence. This intentionally
        /// excludes the Labs raw-capture command (0x51) and the separate raw
        /// flood switch (0x3F).
        static let officialGen4CompactMotionBodies: [[UInt8]] = [
            [toggleRealtimeHR, 0x01],
            [toggleIMUMode, 0x01],
            [abortHistoricalTransmits, 0x00],
        ]
        /// START_RAW_DATA takes a u32 little-endian duration in milliseconds,
        /// not a boolean. Six hours bounds long workouts; STOP_RAW_DATA still
        /// closes the stream on ordinary workout release.
        static let workoutRawCaptureDurationMilliseconds: UInt32 = 6 * 60 * 60 * 1_000

        static func rawCaptureDurationPayload(
            milliseconds: UInt32 = workoutRawCaptureDurationMilliseconds
        ) -> [UInt8] {
            [
                UInt8(milliseconds & 0xFF),
                UInt8((milliseconds >> 8) & 0xFF),
                UInt8((milliseconds >> 16) & 0xFF),
                UInt8((milliseconds >> 24) & 0xFF),
            ]
        }
        static let stopHaptics: UInt8 = 0x7A
        static let enterHighFreqSync: UInt8 = 0x60
        static let exitHighFreqSync: UInt8 = 0x61
    }
}
