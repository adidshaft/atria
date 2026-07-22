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

    /// Delegate-queue authority for the one radio action that cannot wait for
    /// MainActor after a locked-phone disconnect: reinstalling CoreBluetooth's
    /// standing connection request. Every app-owned cancellation is consumed
    /// once, so history cutovers, explicit disconnects and controlled rebuilds
    /// continue through their existing MainActor state machines instead of being
    /// stolen by the realtime fast lane.
    final class BackgroundReconnectFence: @unchecked Sendable {
        enum Disposition: Equatable {
            case reconnectRealtime
            case suppressAppOwnedCancellation
            case suppressHistoryOwner
            case suppressDiagnostic
            case suppressCaptureInactive
        }

        private let lock = NSLock()
        private var appOwnedCancellations: [UUID: Date] = [:]
        private let markerMaximumAge: TimeInterval

        init(markerMaximumAge: TimeInterval = 30) {
            self.markerMaximumAge = max(1, markerMaximumAge)
        }

        func markAppOwnedCancellation(peripheralID: UUID, at date: Date = Date()) {
            lock.lock()
            appOwnedCancellations[peripheralID] = date
            lock.unlock()
        }

        func consumeDisposition(
            peripheralID: UUID,
            continuousCaptureWanted: Bool,
            historyTransportActive: Bool,
            diagnosticActive: Bool,
            now: Date = Date()
        ) -> Disposition {
            lock.lock()
            let markedAt = appOwnedCancellations.removeValue(forKey: peripheralID)
            appOwnedCancellations = appOwnedCancellations.filter {
                let age = now.timeIntervalSince($0.value)
                return age >= 0 && age <= markerMaximumAge
            }
            lock.unlock()

            if let markedAt {
                let age = now.timeIntervalSince(markedAt)
                // A future clock is conflicting evidence. Suppress once rather
                // than turning an app-owned cutover into a realtime reconnect.
                if age < 0 || age <= markerMaximumAge {
                    return .suppressAppOwnedCancellation
                }
            }
            if historyTransportActive { return .suppressHistoryOwner }
            if diagnosticActive { return .suppressDiagnostic }
            guard continuousCaptureWanted else { return .suppressCaptureInactive }
            return .reconnectRealtime
        }
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
        retryAlreadyIssued: Bool
    ) -> Bool {
        peripheralMatches
            && peripheralConnected
            && supportsNotifications
            && !isNotifying
            && !sparseSentinel
            && !retryAlreadyIssued
    }

    nonisolated static func shouldSynchronouslyEnableDiscoveredHeartRateNotification(
        continuousCaptureWanted: Bool,
        supportsNotifications: Bool,
        isNotifying: Bool
    ) -> Bool {
        continuousCaptureWanted && supportsNotifications && !isNotifying
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

    nonisolated static func shouldSuppressWatchdogForStrapStreamState(
        _ state: StrapStreamState
    ) -> Bool {
        state == .lowBatteryShutoff
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

        // A prolonged HR-specific outage is itself sufficient evidence after
        // the soft read/rediscovery window. Low-battery and deliberate sparse
        // modes are suppressed by the callers before this policy is applied.
        if rawHeartRateGap >= 180 {
            return .rebuildConnection
        }
        // Recover sooner when the entire GATT connection is silent.
        if rawHeartRateGap >= 120, usefulGattGap >= 120 {
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
            // Fresh CRC-valid R10 with stale accepted HR proves the link is
            // alive but 2A37 is not delivering useful samples. Restart
            // discovery without ever disabling an active HR CCCD.
            return denseStreamFresh && acceptedHeartRateIsStale
                ? .rediscoverHeartRateService
                : .observe
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
