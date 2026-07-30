import Foundation

/// Transport and cache admission policy for strap battery projections.
///
/// `AtriaBLEManager` remains the sole owner of CoreBluetooth objects, timers,
/// callbacks and published state. This extension contains only deterministic
/// decisions, parsers and explicit `UserDefaults` cache migrations.
extension AtriaBLEManager {
    enum StandardBatteryRefreshAction: Equatable {
        case read
        case subscribe
        case awaitNotification
        case unavailable
    }

    enum BatteryNotificationRecoveryAction: Equatable {
        case retryDisable
        case enable
        case rediscover
        case reconnect
        case waitForConnection
    }

    enum ExistingBatteryNotificationAction: Equatable {
        case awaitCurrentEpoch
        case refreshUnconfirmedEpoch
        case awaitRecovery
    }

    nonisolated static func shouldRequestBatteryRefresh(
        lastRequestedAt: Date?,
        now: Date,
        interval: TimeInterval = batteryRefreshInterval
    ) -> Bool {
        guard let lastRequestedAt else { return true }
        return now >= lastRequestedAt && now.timeIntervalSince(lastRequestedAt) >= interval
    }

    /// A bounded standard 2A19 read is a freshness repair for firmware that
    /// does not emit another percentage notification for a long time. It is
    /// deliberately unavailable while proprietary history owns the link and
    /// is single-flight/rate-limited so it cannot become a polling loop.
    nonisolated static func shouldPerformCurrentLinkBatteryLevelRead(
        canonicalLinkConnected: Bool,
        historyTransportOwnsLink: Bool,
        characteristicReadable: Bool,
        readInFlight: Bool,
        lastReadAt: Date?,
        now: Date,
        minimumInterval: TimeInterval = 60
    ) -> Bool {
        guard canonicalLinkConnected,
              !historyTransportOwnsLink,
              characteristicReadable,
              !readInFlight,
              minimumInterval >= 0 else { return false }
        guard let lastReadAt else { return true }
        guard now >= lastReadAt else { return false }
        return now.timeIntervalSince(lastReadAt) >= minimumInterval
    }

    /// A proprietary battery query is allowed only after the already-proven R10
    /// transport has remained dense and fresh on this connection, then survived
    /// an additional quiet grace. The command pipe remains entirely untouched
    /// during workouts, history work, cooldown, or an open failure circuit.
    nonisolated static func shouldRequestProprietaryBatteryRefresh(
        standardHROnlyMode: Bool,
        stableTransportProven: Bool,
        connected: Bool,
        currentConnectionR10Frames: Int,
        lastR10FrameAt: Date?,
        transportQualifiedAt: Date?,
        batteryIsFresh: Bool,
        activeWorkout: Bool,
        historyActive: Bool,
        requestPending: Bool,
        lastAttemptAt: Date?,
        circuitOpenUntil: Date?,
        now: Date,
        successCooldown: TimeInterval = proprietaryBatteryRefreshCooldown,
        qualificationGrace: TimeInterval = proprietaryBatteryPostQualificationGrace
    ) -> Bool {
        guard standardHROnlyMode,
              stableTransportProven,
              connected,
              currentConnectionR10Frames >= 75,
              let lastR10FrameAt,
              now >= lastR10FrameAt,
              now.timeIntervalSince(lastR10FrameAt) <= 5,
              let transportQualifiedAt,
              now >= transportQualifiedAt,
              now.timeIntervalSince(transportQualifiedAt) >= qualificationGrace,
              !batteryIsFresh,
              !activeWorkout,
              !historyActive,
              !requestPending else { return false }
        if let circuitOpenUntil, now < circuitOpenUntil { return false }
        if let lastAttemptAt {
            guard now >= lastAttemptAt,
                  now.timeIntervalSince(lastAttemptAt) >= successCooldown else { return false }
        }
        return true
    }

    /// COMMAND_RESPONSE layout observed for GET_BATTERY_LEVEL:
    /// [0x24, sequence, 0x1A, 0x0A, 0x01, SOC-low, SOC-high, ...].
    /// SOC is tenths of one percent. Reject every unexpected status, sequence,
    /// or range instead of projecting a sentinel or unrelated response.
    nonisolated static func parseProprietaryBatteryResponse(
        _ payload: [UInt8],
        expectedSequence: UInt8
    ) -> Int? {
        guard payload.count >= 7,
              payload[0] == 0x24,
              payload[1] == expectedSequence,
              payload[2] == Cmd.getBatteryLevel,
              payload[3] == 0x0A,
              payload[4] == 0x01 else { return nil }
        let rawSOC = Int(payload[5]) | (Int(payload[6]) << 8)
        guard rawSOC <= 1_000 else { return nil }
        return Int((Double(rawSOC) / 10).rounded())
    }

    /// Bounded recovery ladder for a failed 2A19 CCCD off/on cycle. A failed
    /// `setNotify(false)` commonly leaves `isNotifying == true`; treating that
    /// callback as terminal strands battery updates for the rest of the link.
    /// Retry once, then rebuild discovery, then replace the connection.
    nonisolated static func batteryNotificationRecoveryAction(
        connected: Bool,
        isNotifying: Bool,
        attempt: Int
    ) -> BatteryNotificationRecoveryAction {
        guard connected else { return .waitForConnection }
        switch max(0, attempt) {
        case 0:
            return isNotifying ? .retryDisable : .enable
        case 1:
            return .rediscover
        default:
            return .reconnect
        }
    }

    /// Physical A/B evidence on 2026-07-13 showed explicit 2A19 reads repeatedly
    /// disconnect this strap. Production therefore subscribes once and waits
    /// for spontaneous standard notifications. Explicit reads remain available
    /// only to an isolated research caller and are never automatic.
    nonisolated static func standardBatteryRefreshAction(
        canRead: Bool,
        canNotify: Bool,
        isNotifying: Bool,
        explicitReadResearchEnabled: Bool = false
    ) -> StandardBatteryRefreshAction {
        if canNotify && isNotifying { return .awaitNotification }
        if canNotify && !isNotifying { return .subscribe }
        if canRead && explicitReadResearchEnabled { return .read }
        return .unavailable
    }

    /// History owns the proprietary transport for the duration of a drain, but
    /// subscribing to the independent standard Battery Level characteristic is
    /// safe. Never turn an existing subscription off, issue a read, rediscover,
    /// or reconnect from this policy.
    nonisolated static func historyOwnedBatteryRefreshAction(
        canNotify: Bool,
        isNotifying: Bool
    ) -> StandardBatteryRefreshAction {
        guard canNotify else { return .unavailable }
        return isNotifying ? .awaitNotification : .subscribe
    }

    /// `CBCharacteristic.isNotifying` can be cached across a genuinely new BLE
    /// link. It is not proof that this connection completed its own CCCD
    /// subscription. Waiting on that flag alone strands a change-driven 2A19
    /// characteristic until the integer percentage happens to change.
    nonisolated static func existingBatteryNotificationAction(
        currentEpochConfirmed: Bool,
        recoveryInFlight: Bool
    ) -> ExistingBatteryNotificationAction {
        if recoveryInFlight { return .awaitRecovery }
        return currentEpochConfirmed ? .awaitCurrentEpoch : .refreshUnconfirmedEpoch
    }

    nonisolated static func batteryLevelIsFresh(
        lastAcceptedAt: Date?,
        now: Date,
        maxAge: TimeInterval = batteryDisplayFreshnessLimit
    ) -> Bool {
        guard let lastAcceptedAt, now >= lastAcceptedAt else { return false }
        return now.timeIntervalSince(lastAcceptedAt) <= maxAge
    }

    /// CoreBluetooth may briefly restore the connected peripheral before its
    /// cached 2A19 characteristic is reattached to this manager. Preserve a
    /// previously accepted mid-range value only for the bounded lifetime of a
    /// lease created in this same process/connection epoch. Launch hydration
    /// clears old leases before setting `requiresFreshConfirmation`.
    nonisolated static func notificationLeaseSupportsBatteryDisplay(
        level: Int,
        source: String,
        requiresFreshConfirmation: Bool,
        linkConnected: Bool,
        notificationLeaseAt: Date?,
        now: Date,
        maximumAge: TimeInterval = batteryDisplayFreshnessLimit
    ) -> Bool {
        guard (11...99).contains(level),
              source == "live_2A19",
              !requiresFreshConfirmation,
              linkConnected,
              let notificationLeaseAt,
              now >= notificationLeaseAt else { return false }
        return now.timeIntervalSince(notificationLeaseAt) <= maximumAge
    }

    /// CoreBluetooth can replace the restored `CBCharacteristic` instance even
    /// after it has reported a successful CCCD subscription. Treat that object
    /// flag as a convenience, not the sole durable proof: a confirmation from
    /// this connection epoch remains authoritative until an inactive/error
    /// callback removes it and records an error.
    nonisolated static func batteryNotificationConfirmationSupportsCurrentConnection(
        confirmedAt: Date?,
        lastError: String?,
        connectionStartedAt: Date?,
        linkConnected: Bool,
        now: Date,
        restoredConfirmationMaximumAge: TimeInterval = batteryRestoredNotificationConfirmationMaximumAge
    ) -> Bool {
        guard linkConnected,
              lastError == nil,
              let confirmedAt,
              confirmedAt <= now else { return false }
        if let connectionStartedAt {
            // `didConnect` proves a genuinely new link epoch. Its subscription
            // must be confirmed again; never inherit the old link's CCCD proof.
            return confirmedAt >= connectionStartedAt
        }
        // State restoration can resume the exact connected peripheral without
        // calling didConnect in this process. Keep the bounded persisted CCCD
        // confirmation for that path; current HR + connected link are required
        // separately by the promotion gate.
        return now.timeIntervalSince(confirmedAt) <= restoredConfirmationMaximumAge
    }

    nonisolated static func batteryNotificationTransportEvidenceIsUsable(
        characteristicIsNotifying: Bool,
        confirmationSupportsCurrentConnection: Bool,
        lastError: String?
    ) -> Bool {
        lastError == nil
            && (characteristicIsNotifying || confirmationSupportsCurrentConnection)
    }

    nonisolated static func batteryRestorationPreservesNotificationEpoch(
        restoredPeripheralIdentifier: UUID,
        savedPeripheralIdentifier: UUID?,
        restoredPeripheralIsConnected: Bool
    ) -> Bool {
        restoredPeripheralIsConnected
            && savedPeripheralIdentifier == restoredPeripheralIdentifier
    }

    /// `CBCharacteristic.isNotifying` is restored cache, not a successful CCCD
    /// callback in this process. It may reuse an epoch only when restoration
    /// proved the exact connected saved peripheral and the bounded persisted
    /// confirmation is itself current and error-free.
    nonisolated static func restoredCachedBatteryNotificationCanReuseEpoch(
        characteristicIsNotifying: Bool,
        restoredSamePeripheral: Bool,
        confirmedAt: Date?,
        lastError: String?,
        linkConnected: Bool,
        now: Date
    ) -> Bool {
        guard characteristicIsNotifying, restoredSamePeripheral else { return false }
        return batteryNotificationConfirmationSupportsCurrentConnection(
            confirmedAt: confirmedAt,
            lastError: lastError,
            connectionStartedAt: nil,
            linkConnected: linkConnected,
            now: now
        )
    }

    /// A genuine reconnect may not receive a 2A19 callback until the integer
    /// percentage changes. Keep a recent, already-validated mid-range baseline
    /// visible as *Recent* when live HR proves the same saved strap is currently
    /// connected. This is display-only evidence: callers must not clear
    /// `requiresFreshConfirmation`, renew a live lease, or schedule battery
    /// alerts from it. A disputed/rejected callback belongs to the *new*
    /// notification epoch; it must block promotion, but it must not erase the
    /// separately accepted baseline. Keeping that baseline visible as Recent
    /// avoids a permanent Pending UI while a false restoration sentinel is
    /// quarantined.
    nonisolated static func recentReconnectBatteryBaselineIsDisplayEligible(
        level: Int,
        acceptedAt: Date?,
        source: String,
        displayedIsCached: Bool,
        requiresFreshConfirmation: Bool,
        linkConnected: Bool,
        sameSavedPeripheral: Bool,
        currentConnectionHasHeartRate: Bool,
        hasPendingDisputedReading: Bool,
        currentNotificationEpochHadRejectedCallback: Bool,
        now: Date,
        maximumAge: TimeInterval = reconnectBatteryBaselineMaximumAge
    ) -> Bool {
        guard displayedIsCached,
              requiresFreshConfirmation,
              linkConnected,
              sameSavedPeripheral,
              currentConnectionHasHeartRate,
              (11...99).contains(level),
              batteryReconnectBaselineSourceIsLeaseEligible(source),
              let acceptedAt,
              acceptedAt <= now else { return false }
        _ = hasPendingDisputedReading
        _ = currentNotificationEpochHadRejectedCallback
        return now.timeIntervalSince(acceptedAt) <= maximumAge
    }

    /// Launch hydration must not turn a fresh, already-validated percentage
    /// into an indefinite Pending state merely because the change-driven 2A19
    /// characteristic has not emitted the same integer again. This narrower
    /// gate is only for the first minutes after acceptance: it requires the
    /// same connected strap, a non-boundary value, and provenance from a live
    /// level-bearing packet. It is display-only and never clears the fresh-
    /// confirmation flag or renews a notification lease.
    nonisolated static func freshConnectedCachedBatteryBaselineIsDisplayEligible(
        level: Int,
        acceptedAt: Date?,
        source: String,
        displayedIsCached: Bool,
        requiresFreshConfirmation: Bool,
        linkConnected: Bool,
        sameSavedPeripheral: Bool,
        now: Date,
        maximumAge: TimeInterval = batteryDisplayFreshnessLimit
    ) -> Bool {
        guard displayedIsCached,
              requiresFreshConfirmation,
              linkConnected,
              sameSavedPeripheral,
              (11...99).contains(level),
              batteryReconnectBaselineSourceIsLeaseEligible(source),
              let acceptedAt,
              acceptedAt <= now else { return false }
        return now.timeIntervalSince(acceptedAt) <= maximumAge
    }

    /// Keep an already-validated mid-range baseline in memory while a freshly
    /// connected strap is proving its HR + 2A19 notification paths. The
    /// foreground keepalive can tick before the first HR packet; clearing the
    /// value during that short race makes later promotion impossible and leaves
    /// the UI on `Battery pending` until the percentage changes. This is a
    /// retention gate only: it does not make the value displayable, refresh its
    /// timestamp, or authorize battery alerts.
    nonisolated static func reconnectBatteryBaselineIsAwaitingProof(
        level: Int,
        acceptedAt: Date?,
        source: String,
        displayedIsCached: Bool,
        requiresFreshConfirmation: Bool,
        linkConnected: Bool,
        sameSavedPeripheral: Bool,
        validationStartedAt: Date,
        now: Date,
        proofGrace: TimeInterval = 90,
        maximumAge: TimeInterval = activeBatterySubscriptionBaselineMaximumAge
    ) -> Bool {
        guard displayedIsCached,
              requiresFreshConfirmation,
              linkConnected,
              sameSavedPeripheral,
              (11...99).contains(level),
              batteryReconnectBaselineSourceIsLeaseEligible(source),
              let acceptedAt,
              acceptedAt <= now,
              validationStartedAt <= now else { return false }
        return now.timeIntervalSince(acceptedAt) <= maximumAge
            && now.timeIntervalSince(validationStartedAt) <= proofGrace
    }

    nonisolated static func reconnectBatteryDisplayLevel(
        currentLevel: Int,
        credibleLevel: Int?,
        credibleAt: Date?,
        now: Date,
        maxAge: TimeInterval = batteryDisplayFreshnessLimit
    ) -> Int {
        guard isBatterySentinel(currentLevel) else { return currentLevel }
        guard let credibleLevel,
              let credibleAt,
              !isBatterySentinel(credibleLevel),
              batteryLevelIsFresh(lastAcceptedAt: credibleAt, now: now, maxAge: maxAge) else {
            return -1
        }
        return credibleLevel
    }

    /// Standard Battery Service notifications are change-driven. Requiring a
    /// second value packet after every reconnect can therefore leave a correct
    /// mid-range percentage stuck on Pending forever when the level has not
    /// changed. Promote the recent credible baseline only after this exact
    /// connection has delivered accepted HR or a CRC-valid R10 motion frame,
    /// and CoreBluetooth confirms the 2A19 notification remains active. R10 is
    /// link proof only; it is never decoded as battery data. Restoration
    /// sentinels and unknown sources can never cross this boundary.
    nonisolated static func shouldPromoteReconnectBatteryBaseline(
        level: Int,
        acceptedAt: Date?,
        source: String,
        displayedIsCached: Bool,
        requiresFreshConfirmation: Bool,
        notificationActive: Bool,
        linkConnected: Bool,
        currentConnectionHasHeartRate: Bool,
        currentConnectionHasValidatedR10: Bool = false,
        hasPendingDisputedReading: Bool = false,
        currentNotificationEpochHadRejectedCallback: Bool = false,
        now: Date,
        maximumAge: TimeInterval = activeBatterySubscriptionBaselineMaximumAge
    ) -> Bool {
        guard displayedIsCached,
              requiresFreshConfirmation,
              notificationActive,
              linkConnected,
              currentConnectionHasHeartRate || currentConnectionHasValidatedR10,
              !hasPendingDisputedReading,
              !currentNotificationEpochHadRejectedCallback,
              (11...99).contains(level),
              batteryReconnectBaselineSourceIsLeaseEligible(source),
              let acceptedAt,
              now >= acceptedAt else { return false }
        return now.timeIntervalSince(acceptedAt) <= maximumAge
    }

    /// A current standard Battery Service subscription may carry forward only
    /// a recent percentage that already came from a level-bearing, validated
    /// live source. The autonomous battery event is stronger than bare 2A19
    /// (CRC + SOC + cell voltage), so excluding it left an otherwise truthful
    /// mid-range value stuck on Pending after reconnect until the next event.
    /// The retired one-shot proprietary command remains excluded because its
    /// transport can interrupt R10 and is disabled in production.
    nonisolated static func batteryReconnectBaselineSourceIsLeaseEligible(
        _ source: String
    ) -> Bool {
        source == "live_2A19" || source == "live_battery_event"
    }

    nonisolated static func batteryConfirmationRetryDelay(incomingLevel: Int) -> TimeInterval {
        incomingLevel <= 10 || incomingLevel >= 100 ? 30 : 6
    }

    /// No currently decoded packet is authoritative current external-power
    /// evidence: stream-4 replays a latched charge byte and 2A1B powered bits
    /// can remain asserted after unplug. Legacy persisted powered states must
    /// therefore be downgraded to level-only on read.
    nonisolated static func batteryChargeSourceCanAuthorizeCharging(_ source: String) -> Bool {
        _ = source
        return false
    }

    /// Cross-process consumers (widgets and asynchronous notification
    /// scheduling) cannot inspect CoreBluetooth objects, but they can verify a
    /// lease that the live app renews only while the same 2A19 subscription is
    /// proven. This never refreshes the level packet's timestamp and never
    /// admits the observed restoration sentinels 0/10/100.
    nonisolated static func persistedBatteryNotificationLeaseSupportsDisplay(
        level: Int,
        source: String,
        requiresFreshConfirmation: Bool,
        notificationLeaseAt: Date?,
        notificationConfirmedAt: Date?,
        now: Date,
        leaseMaximumAge: TimeInterval = batteryDisplayFreshnessLimit
    ) -> Bool {
        guard (11...99).contains(level),
              batteryReconnectBaselineSourceIsLeaseEligible(source),
              !requiresFreshConfirmation,
              let notificationLeaseAt,
              let notificationConfirmedAt,
              notificationLeaseAt <= now,
              notificationConfirmedAt <= notificationLeaseAt else { return false }
        // The foreground app renews this lease only after re-verifying the
        // current notification epoch; disconnect and didConnect both revoke it.
        // Therefore a fresh lease is the cross-process corroboration. Re-aging
        // the original CCCD callback separately made healthy long-lived links
        // turn Pending after one hour even while the live app renewed the lease.
        return now.timeIntervalSince(notificationLeaseAt) <= leaseMaximumAge
    }

    nonisolated static func batteryCacheSourceIsDisplayEligible(_ source: String) -> Bool {
        switch source {
        case "live_2A19", "live_battery_event", "live_proprietary_1a":
            return true
        default:
            return false
        }
    }

    /// Invalidates state written by the old two-read confirmation rule. A rapid
    /// >=20-point transition makes *both* stored levels disputed: restoring the
    /// earlier value would merely replace one unverified reading with another.
    /// Leave battery unavailable until a fresh, stable live series is confirmed.
    @discardableResult
    nonisolated static func invalidateImplausibleCachedBatteryTransitionIfNeeded(
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard let level = defaults.object(forKey: BatteryDefaults.level) as? Int,
              let previous = defaults.object(forKey: BatteryDefaults.previousLevel) as? Int,
              let previousAt = defaults.object(forKey: BatteryDefaults.previousAt) as? Double,
              let dropAt = defaults.object(forKey: BatteryDefaults.dropAt) as? Double,
              abs(previous - level) >= implausibleBatteryDropThreshold,
              dropAt >= previousAt,
              dropAt - previousAt < transitionBatteryMinimumConfirmationSpan(
                  incomingLevel: level
              ) else {
            return false
        }
        defaults.removeObject(forKey: BatteryDefaults.level)
        defaults.removeObject(forKey: BatteryDefaults.at)
        defaults.removeObject(forKey: BatteryDefaults.previousLevel)
        defaults.removeObject(forKey: BatteryDefaults.previousAt)
        defaults.removeObject(forKey: BatteryDefaults.dropDelta)
        defaults.removeObject(forKey: BatteryDefaults.dropAt)
        defaults.removeObject(forKey: BatteryDefaults.chargeStatus)
        defaults.removeObject(forKey: BatteryDefaults.chargeAt)
        defaults.removeObject(forKey: BatteryDefaults.notificationLeaseAt)
        defaults.set("disputed_rapid_transition", forKey: BatteryDefaults.source)
        defaults.set(true, forKey: BatteryDefaults.requiresFreshConfirmation)
        defaults.set(StrapStreamState.unknown.rawValue, forKey: StrapStreamDefaults.state)
        defaults.set(-1, forKey: StrapStreamDefaults.batteryLevel)
        defaults.set("disputed_battery_transition", forKey: StrapStreamDefaults.reason)
        defaults.set(false, forKey: StrapStreamDefaults.lowBatteryReconnectSuppressed)
        defaults.removeObject(forKey: StrapStreamDefaults.lowBatteryReconnectSuppressedAt)
        defaults.removeObject(forKey: StrapStreamDefaults.lowBatteryReconnectSuppressionReason)
        defaults.removeObject(forKey: StrapStreamDefaults.accessibilityLabel)
        AtriaDebugLog(
            "ATRIADBG battery status=invalidated_cached_transition newer=%d earlier=%d span_s=%.1f action=require_fresh_stable_confirmation",
            level,
            previous,
            dropAt - previousAt
        )
        return true
    }

    /// Builds predating trajectory validation may have persisted a replayed
    /// 0/10/100 as live truth. Exact sentinel cache entries have no proof of how
    /// they were reached, so remove them at launch while retaining the separate
    /// last-credible mid-range baseline when one exists.
    @discardableResult
    nonisolated static func invalidateUnverifiedCachedBatterySentinelIfNeeded(
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard let level = defaults.object(forKey: BatteryDefaults.level) as? Int,
              isBatterySentinel(level) else { return false }
        defaults.removeObject(forKey: BatteryDefaults.level)
        defaults.removeObject(forKey: BatteryDefaults.at)
        defaults.removeObject(forKey: BatteryDefaults.chargeStatus)
        defaults.removeObject(forKey: BatteryDefaults.chargeAt)
        defaults.removeObject(forKey: BatteryDefaults.notificationLeaseAt)
        defaults.removeObject(forKey: BatteryDefaults.dropDelta)
        defaults.removeObject(forKey: BatteryDefaults.dropAt)
        defaults.set("disputed_boundary_sentinel", forKey: BatteryDefaults.source)
        defaults.set(true, forKey: BatteryDefaults.requiresFreshConfirmation)
        defaults.set(StrapStreamState.unknown.rawValue, forKey: StrapStreamDefaults.state)
        defaults.set(-1, forKey: StrapStreamDefaults.batteryLevel)
        defaults.set("disputed_battery_boundary", forKey: StrapStreamDefaults.reason)
        defaults.set(false, forKey: StrapStreamDefaults.lowBatteryReconnectSuppressed)
        defaults.removeObject(forKey: StrapStreamDefaults.lowBatteryReconnectSuppressedAt)
        defaults.removeObject(forKey: StrapStreamDefaults.lowBatteryReconnectSuppressionReason)
        defaults.removeObject(forKey: StrapStreamDefaults.accessibilityLabel)
        AtriaDebugLog(
            "ATRIADBG battery status=invalidated_cached_sentinel level=%d action=preserve_last_credible",
            level
        )
        return true
    }
}
