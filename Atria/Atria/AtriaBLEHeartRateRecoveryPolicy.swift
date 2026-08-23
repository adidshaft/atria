import Foundation

/// Pure recovery decisions for the standard heart-rate stream.
///
/// Keeping these rules separate from CoreBluetooth delegate handling makes the
/// escalation ladder and notification coalescing independently testable. The
/// manager remains the sole owner of BLE side effects.
extension AtriaBLEManager {
    /// Thread-safe shadow of the MainActor duty-cycle intent. CoreBluetooth's
    /// nonisolated discovery callback reads it before yielding to MainActor so
    /// the initial 2A37 CCCD write cannot be lost to background suspension.
    final class HeartRateCaptureIntent: @unchecked Sendable {
        private let lock = NSLock()
        private var continuousCaptureWanted = true

        func update(continuousCaptureWanted: Bool) {
            lock.lock()
            self.continuousCaptureWanted = continuousCaptureWanted
            lock.unlock()
        }

        func snapshot() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return continuousCaptureWanted
        }
    }

    /// Nonisolated arm bit for the idle-window / natural-gap stop-realtime
    /// drain. `didDisconnect` sets it on the callback queue so `didConnect`
    /// can suppress the 2A37 fast lane in the same execution slice — the
    /// MainActor `naturalGapDrainArmed` flag loses that race and HR restarts
    /// before the drain can claim the pipe.
    final class IdleWindowDrainArmFence: @unchecked Sendable {
        private let lock = NSLock()
        private var armed = false
        private var inFlight = false

        func arm() {
            lock.lock()
            armed = true
            lock.unlock()
        }

        func markInFlight() {
            lock.lock()
            inFlight = true
            armed = false
            lock.unlock()
        }

        /// Drain-owned `didDisconnect`: consume the in-flight bit without
        /// re-arming. The MainActor hop must not set `naturalGapDrainArmed`.
        func consumeDrainOwnedDisconnect() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard inFlight else { return false }
            inFlight = false
            armed = false
            return true
        }

        func clear() {
            lock.lock()
            armed = false
            inFlight = false
            lock.unlock()
        }

        func snapshot() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return armed
        }

        func isInFlight() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return inFlight
        }
    }

    /// Delegate-queue authority for the one radio action that cannot wait for
    /// MainActor after a locked-phone disconnect: reinstalling CoreBluetooth's
    /// standing connection request. Every app-owned cancellation is consumed
    /// once, so history cutovers, explicit disconnects and controlled rebuilds
    /// continue through their existing MainActor state machines instead of being
    /// stolen by the realtime fast lane.
    final class BackgroundReconnectFence: @unchecked Sendable {
        enum Disposition: Equatable {
            case reconnectRealtime
            case reconnectRealtimeAfterHistoryRelease(generation: UInt64)
            case suppressAppOwnedCancellation
            case suppressHistoryOwner
            case suppressDiagnostic
            case suppressCaptureInactive

            var requestsRealtimeReconnect: Bool {
                switch self {
                case .reconnectRealtime,
                     .reconnectRealtimeAfterHistoryRelease:
                    return true
                case .suppressAppOwnedCancellation,
                     .suppressHistoryOwner,
                     .suppressDiagnostic,
                     .suppressCaptureInactive:
                    return false
                }
            }
        }

        private struct AppOwnedCancellation {
            let markedAt: Date
            let restoreRealtimeAfterHistoryGeneration: UInt64?
        }

        private let lock = NSLock()
        private var appOwnedCancellations:
            [UUID: AppOwnedCancellation] = [:]
        private let markerMaximumAge: TimeInterval

        init(markerMaximumAge: TimeInterval = 30) {
            self.markerMaximumAge = max(1, markerMaximumAge)
        }

        func markAppOwnedCancellation(
            peripheralID: UUID,
            restoreRealtimeAfterHistoryGeneration: UInt64? = nil,
            at date: Date = Date()
        ) {
            lock.lock()
            appOwnedCancellations[peripheralID] = .init(
                markedAt: date,
                restoreRealtimeAfterHistoryGeneration:
                    restoreRealtimeAfterHistoryGeneration
            )
            lock.unlock()
        }

        func consumeDisposition(
            peripheralID: UUID,
            continuousCaptureWanted: Bool,
            historyTransportActive: Bool,
            activeHistoryTransportGeneration: UInt64? = nil,
            diagnosticActive: Bool,
            now: Date = Date()
        ) -> Disposition {
            lock.lock()
            let cancellation = appOwnedCancellations.removeValue(
                forKey: peripheralID
            )
            appOwnedCancellations = appOwnedCancellations.filter {
                let age = now.timeIntervalSince($0.value.markedAt)
                return age >= 0 && age <= markerMaximumAge
            }
            lock.unlock()

            if let cancellation {
                let age = now.timeIntervalSince(cancellation.markedAt)
                // A future clock is conflicting evidence. Suppress once rather
                // than turning an app-owned cutover into a realtime reconnect.
                if age < 0 {
                    return .suppressAppOwnedCancellation
                }
                if age <= markerMaximumAge {
                    guard let interruptedGeneration =
                            cancellation
                                .restoreRealtimeAfterHistoryGeneration else {
                        return .suppressAppOwnedCancellation
                    }
                    if diagnosticActive { return .suppressDiagnostic }
                    guard continuousCaptureWanted else {
                        return .suppressCaptureInactive
                    }
                    if historyTransportActive,
                       activeHistoryTransportGeneration
                        != interruptedGeneration {
                        // A different generation is a newer history owner. The
                        // stale cancellation may not retire or overlap it.
                        return .suppressHistoryOwner
                    }
                    // This marker is reserved for the exact history generation
                    // which elected to relinquish ownership because accepted
                    // 2A37 went stale. The delegate callback atomically retires
                    // that generation before reinstalling realtime.
                    return .reconnectRealtimeAfterHistoryRelease(
                        generation: interruptedGeneration
                    )
                }
            }
            if diagnosticActive { return .suppressDiagnostic }
            guard continuousCaptureWanted else { return .suppressCaptureInactive }
            if historyTransportActive {
                // didDisconnect/didFailToConnect are physical terminal
                // callbacks: the proprietary history owner no longer has a
                // link to protect. Retire only its exact generation and
                // reinstall realtime before yielding to MainActor. Without
                // this handoff a locked app can be suspended in the gap
                // between the callback and delayed history cleanup.
                guard let activeHistoryTransportGeneration else {
                    return .suppressHistoryOwner
                }
                return .reconnectRealtimeAfterHistoryRelease(
                    generation: activeHistoryTransportGeneration
                )
            }
            return .reconnectRealtime
        }
    }

    nonisolated static func shouldSynchronouslyReconnectAfterFailedConnect(
        disposition: BackgroundReconnectFence.Disposition,
        failedPeripheralIsSaved: Bool,
        peripheralIsDisconnected: Bool
    ) -> Bool {
        disposition.requestsRealtimeReconnect
            && failedPeripheralIsSaved
            && peripheralIsDisconnected
    }

    nonisolated static func acceptsFailedConnectCallback(
        trackedPeripheralIsFailedInstance: Bool,
        trackedPeripheralIsAbsent: Bool,
        synchronousReconnectIssued: Bool,
        callbackEpochIsCurrent: Bool
    ) -> Bool {
        callbackEpochIsCurrent
            && (
                trackedPeripheralIsFailedInstance
                    || (synchronousReconnectIssued && trackedPeripheralIsAbsent)
            )
    }

    nonisolated static func acceptsDisconnectCallbackFollowup(
        trackedPeripheralIsDisconnectedInstance: Bool,
        terminalEpochIsCurrent: Bool
    ) -> Bool {
        trackedPeripheralIsDisconnectedInstance && terminalEpochIsCurrent
    }

    enum AutomaticRecoveryIntent: Int, Equatable {
        case repairPipeline
        case rebuildConnection
    }

    enum RecoveryBackoffResetEvidence: Equatable {
        case connected
        case characteristicValue
    }

    enum HeartRateContinuityRecoveryDisposition: Equatable {
        case observe
        case readHeartRate
        case enableHeartRateNotifications
        case rediscoverHeartRateService
        case rebuildConnection
        case reconnectKnownPeripheral
    }

    enum HeartRateNotificationEnableDisposition: Equatable {
        case request
        case waitForInFlight
        case alreadyActive
        case unavailable
    }

    nonisolated static func heartRateNotificationEnableDisposition(
        peripheralConnected: Bool,
        supportsNotifications: Bool,
        isNotifying: Bool,
        requestInFlight: Bool
    ) -> HeartRateNotificationEnableDisposition {
        if isNotifying { return .alreadyActive }
        guard peripheralConnected, supportsNotifications else { return .unavailable }
        return requestInFlight ? .waitForInFlight : .request
    }

    /// CoreBluetooth can restore a bonded link and briefly deliver 2A37 before
    /// reporting the restored CCCD inactive. That callback is the only reliable
    /// background execution opportunity; a timer-based watchdog may remain
    /// suspended while the phone is locked. Allow one immediate callback-driven
    /// enable per inactive episode. A second inactive completion is left to the
    /// paced recovery pipeline so a refusing peripheral cannot create a tight
    /// callback loop.
    nonisolated static func shouldImmediatelyReenableInactiveHeartRateNotification(
        peripheralMatches: Bool,
        peripheralConnected: Bool,
        supportsNotifications: Bool,
        isNotifying: Bool,
        sparseSentinel: Bool,
        retryAlreadyIssued: Bool,
        idleWindowDrainOwnsLink: Bool = false
    ) -> Bool {
        peripheralMatches
            && peripheralConnected
            && supportsNotifications
            && !isNotifying
            && !sparseSentinel
            && !retryAlreadyIssued
            && !idleWindowDrainOwnsLink
    }

    nonisolated static func shouldSynchronouslyEnableDiscoveredHeartRateNotification(
        continuousCaptureWanted: Bool,
        supportsNotifications: Bool,
        isNotifying: Bool,
        idleWindowDrainOwnsLink: Bool = false
    ) -> Bool {
        continuousCaptureWanted
            && supportsNotifications
            && !isNotifying
            && !idleWindowDrainOwnsLink
    }

    /// A locked return-to-range may receive only the CoreBluetooth connection
    /// callback before iOS suspends ordinary actor work again. Start the
    /// standard HR discovery transaction in that callback execution slice for
    /// production continuous capture. Explicit history and diagnostic links
    /// retain their deliberately restricted discovery profiles.
    nonisolated static func shouldSynchronouslyDiscoverHeartRateAfterConnect(
        continuousCaptureWanted: Bool,
        peripheralConnected: Bool,
        historyRecoveryActive: Bool,
        diagnosticActive: Bool
    ) -> Bool {
        continuousCaptureWanted
            && peripheralConnected
            && !historyRecoveryActive
            && !diagnosticActive
    }

    nonisolated static func shouldPerformForegroundKeepaliveHardRebuild(
        isSparseSentinel: Bool,
        disposition: HeartRateContinuityRecoveryDisposition
    ) -> Bool {
        !isSparseSentinel && disposition == .rebuildConnection
    }

    /// In the background there may be only one watchdog execution slice. If
    /// both 2A37 and every other app-observed GATT channel are already stale,
    /// spending that slice on a soft rediscovery can strand the app forever.
    /// Replace the client session immediately; foreground recovery retains the
    /// gentler staged policy because it is guaranteed another evaluation.
    nonisolated static func shouldReplaceCoreBluetoothSessionForSilentStream(
        applicationActive: Bool,
        peripheralConnected: Bool,
        rawHeartRateGap: TimeInterval,
        usefulGattGap: TimeInterval,
        adaptiveTimeout: TimeInterval
    ) -> Bool {
        !applicationActive
            && peripheralConnected
            && rawHeartRateGap >= max(0, adaptiveTimeout)
            && usefulGattGap >= max(0, adaptiveTimeout)
    }

    nonisolated static func shouldSuppressWatchdogForStrapStreamState(
        _ state: StrapStreamState
    ) -> Bool {
        state == .lowBatteryShutoff
    }

    /// Proprietary R10 notifications keep granting the app background
    /// execution even when the standard 2A37 stream has silently stopped.
    /// Use those real callbacks as the watchdog clock: ordinary `Task.sleep`
    /// timers can remain suspended indefinitely while the phone is locked.
    nonisolated static func shouldRunCallbackDrivenHeartRateAudit(
        rawHeartRateGap: TimeInterval,
        timeout: TimeInterval,
        lastAuditAt: Date?,
        now: Date,
        minimumInterval: TimeInterval = stalledStreamRepairCooldown
    ) -> Bool {
        guard rawHeartRateGap >= max(0, timeout) else { return false }
        guard let lastAuditAt else { return true }
        let age = now.timeIntervalSince(lastAuditAt)
        return age >= max(1, minimumInterval)
    }

    enum HRContinuityHistoryOwnershipDisposition: Equatable {
        case repairNormally
        case deferExclusiveHistory
        case preemptConnectedRawHistory
    }

    /// Exclusive history keeps its existing no-interleaving guarantee. An
    /// exact connected-raw generation is different: it was admitted only on
    /// the promise that standard 2A37 remains the realtime owner. Once that
    /// promise is observably false, continuing to defer the HR watchdog can
    /// strand a locked-phone link until an unstructured budget task happens to
    /// resume. Preempt only that typed owner; workout/motion-bank and ordinary
    /// history retain the original deferral semantics.
    nonisolated static func hrContinuityHistoryOwnershipDisposition(
        historyTransportActive: Bool,
        exactConnectedRawHistoryActive: Bool,
        rawHeartRateGap: TimeInterval,
        adaptiveTimeout: TimeInterval
    ) -> HRContinuityHistoryOwnershipDisposition {
        guard historyTransportActive else { return .repairNormally }
        guard exactConnectedRawHistoryActive else {
            return .deferExclusiveHistory
        }
        guard rawHeartRateGap.isFinite,
              adaptiveTimeout.isFinite,
              rawHeartRateGap >= max(1, adaptiveTimeout) else {
            return .deferExclusiveHistory
        }
        return .preemptConnectedRawHistory
    }

    struct HeartRateNotificationEnableGate {
        private var requestedAt: Date?
        private var peripheralID: UUID?
        nonisolated static let requestTimeout: TimeInterval = 30

        mutating func disposition(
            now: Date,
            peripheralID: UUID,
            peripheralConnected: Bool,
            supportsNotifications: Bool,
            isNotifying: Bool
        ) -> HeartRateNotificationEnableDisposition {
            if isNotifying {
                settle(peripheralID: peripheralID)
                return .alreadyActive
            }
            let requestInFlight: Bool
            if self.peripheralID == peripheralID, let requestedAt {
                let age = now.timeIntervalSince(requestedAt)
                requestInFlight = age >= 0 && age < Self.requestTimeout
            } else {
                requestInFlight = false
            }
            let disposition = AtriaBLEManager.heartRateNotificationEnableDisposition(
                peripheralConnected: peripheralConnected,
                supportsNotifications: supportsNotifications,
                isNotifying: isNotifying,
                requestInFlight: requestInFlight
            )
            if disposition == .request {
                self.requestedAt = now
                self.peripheralID = peripheralID
            }
            return disposition
        }

        mutating func settle(peripheralID: UUID) {
            guard self.peripheralID == peripheralID else { return }
            requestedAt = nil
            self.peripheralID = nil
        }

        mutating func reset() {
            requestedAt = nil
            peripheralID = nil
        }
    }

    /// Pure policy for a silent 2A37 stream. Other fresh GATT traffic (including
    /// CRC-valid R10 motion) initially proves the connected link is alive, so
    /// an HR-only gap first prompts a read/subscription repair. It cannot veto
    /// recovery forever: a real history-stop failure can leave battery/R10
    /// healthy while 2A37 remains silent until the connection is rebuilt.
    /// Active notifications are intentionally left active: toggling their CCCD
    /// at the first threshold caused the physical disconnect/reconnect loop.
    nonisolated static func heartRateContinuityRecoveryDisposition(
        rawHeartRateGap: TimeInterval,
        usefulGattGap: TimeInterval,
        adaptiveTimeout: TimeInterval,
        peripheralConnected: Bool,
        hasHeartRateCharacteristic: Bool,
        heartRateIsNotifying: Bool,
        canReadHeartRate: Bool,
        canNotifyHeartRate: Bool,
        denseStreamFresh: Bool = false,
        acceptedHeartRateGap: TimeInterval? = nil
    ) -> HeartRateContinuityRecoveryDisposition {
        guard peripheralConnected else { return .reconnectKnownPeripheral }
        let timeout = max(0, adaptiveTimeout)
        let acceptedHeartRateIsStale = acceptedHeartRateGap.map { $0 >= timeout } ?? false
        guard rawHeartRateGap >= timeout
                || (denseStreamFresh && acceptedHeartRateIsStale) else { return .observe }

        // Escalate the HR-specific outage in bounded stages even while motion
        // or battery traffic proves the GATT link itself is alive:
        //
        //   1x timeout: one non-destructive read/enable;
        //   2x timeout: rediscover the standard HR service;
        //   3x timeout: rebuild the connection.
        //
        // Without these bounds a readable-but-dead 2A37 characteristic was
        // read forever and fresh R10 traffic vetoed reconnection until 180 s.
        // The physical 2026-07-26 run then retained a healthy BLE link while
        // accepted HR stopped for minutes.
        let rediscoveryThreshold = max(60, timeout * 2)
        let rebuildThreshold = max(90, timeout * 3)
        if rawHeartRateGap >= rebuildThreshold {
            return .rebuildConnection
        }
        if rawHeartRateGap >= rediscoveryThreshold,
           hasHeartRateCharacteristic {
            return .rediscoverHeartRateService
        }
        // Recover the entire silent link sooner than the HR-specific staged
        // rebuild when no other GATT evidence exists.
        if rawHeartRateGap >= 60, usefulGattGap >= 60 {
            return .rebuildConnection
        }
        guard hasHeartRateCharacteristic else {
            return .rediscoverHeartRateService
        }
        if !heartRateIsNotifying, canNotifyHeartRate {
            return .enableHeartRateNotifications
        }
        if heartRateIsNotifying {
            if canReadHeartRate { return .readHeartRate }
            // A notifying 2A37 characteristic without read support has no
            // soft probe available. Once its stream itself crosses the
            // timeout, rediscover the HR service to re-arm the pipeline. This
            // intentionally leaves the active CCCD untouched; callers defer
            // while history owns the transport and suppress low-battery
            // shutoff before reaching this policy.
            return .rediscoverHeartRateService
        }
        if canReadHeartRate { return .readHeartRate }
        return denseStreamFresh && acceptedHeartRateIsStale
            ? .rediscoverHeartRateService
            : .observe
    }

    nonisolated static func mergedRecoveryIntent(
        _ current: AutomaticRecoveryIntent,
        _ requested: AutomaticRecoveryIntent
    ) -> AutomaticRecoveryIntent {
        current.rawValue >= requested.rawValue ? current : requested
    }

    nonisolated static func shouldResetRecoveryBackoff(
        for evidence: RecoveryBackoffResetEvidence
    ) -> Bool {
        evidence == .characteristicValue
    }

    nonisolated static func shouldEnableNotifications(isNotifying: Bool) -> Bool {
        !isNotifying
    }
}
