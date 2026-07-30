import Foundation

/// Transport-independent battery and external-power policy for WHOOP-class
/// straps. `AtriaBLEManager` owns CoreBluetooth objects, timers and published
/// state; this extension owns only deterministic parsing, admission and state
/// transition decisions.
extension AtriaBLEManager {
    enum BatteryChargeStatus: String, Equatable {
        case levelOnly
        case charging
        case notCharging
        case full

        var label: String {
            switch self {
            case .levelOnly: return "Charger unknown"
            case .charging: return "Charging"
            case .notCharging: return "Not charging"
            case .full: return "Full"
            }
        }
    }

    struct BatteryDropCandidate: Equatable {
        let level: Int
        let firstSeenAt: Date
        let lastSeenAt: Date
        let confirmations: Int
    }

    struct BatteryRiseCandidate: Equatable {
        let startLevel: Int
        let startAt: Date
        let lastLevel: Int
        let lastAt: Date
        let confirmations: Int
    }

    struct BatteryEventReading: Equatable {
        let level: Int
        let millivolts: Int
        let isCharging: Bool
    }

    enum BatteryLevelAcceptanceDecision: Equatable {
        case accept
        case quarantine(BatteryDropCandidate)
    }

    enum BatteryChargeLeaseDecision: Equatable {
        case inactive
        case retain(remaining: TimeInterval)
        case expire
    }

    nonisolated static func shouldQuarantineBatteryLevel(
        previousLevel: Int,
        previousAcceptedAt: Date?,
        incomingLevel: Int,
        receivedAt: Date
    ) -> Bool {
        guard previousLevel >= 0,
              (0...100).contains(incomingLevel),
              abs(previousLevel - incomingLevel) >= implausibleBatteryDropThreshold else {
            return false
        }
        return previousAcceptedAt.map { receivedAt >= $0 } ?? true
    }

    nonisolated static func batteryLevelAcceptanceDecision(
        previousLevel: Int,
        previousAcceptedAt: Date?,
        incomingLevel: Int,
        receivedAt: Date,
        pending: BatteryDropCandidate?,
        previousIsCached: Bool = false,
        requiresFreshConfirmation: Bool = false,
        trustedCurrentConnectionNotification: Bool = false
    ) -> BatteryLevelAcceptanceDecision {
        if isBatterySentinel(incomingLevel) {
            return corroboratedBatteryLevelDecision(
                incomingLevel: incomingLevel,
                receivedAt: receivedAt,
                pending: pending,
                minimumSpan: .infinity
            )
        }
        if requiresFreshConfirmation,
           trustedCurrentConnectionNotification,
           !isBatterySentinel(incomingLevel) {
            return .accept
        }
        if requiresFreshConfirmation {
            return corroboratedBatteryLevelDecision(
                incomingLevel: incomingLevel,
                receivedAt: receivedAt,
                pending: pending,
                minimumSpan: freshBatteryMinimumConfirmationSpan(incomingLevel: incomingLevel)
            )
        }
        if previousIsCached {
            if previousLevel >= 0,
               abs(incomingLevel - previousLevel) >= implausibleBatteryDropThreshold {
                return corroboratedBatteryLevelDecision(
                    incomingLevel: incomingLevel,
                    receivedAt: receivedAt,
                    pending: pending,
                    minimumSpan: transitionBatteryMinimumConfirmationSpan(
                        incomingLevel: incomingLevel
                    )
                )
            }
            return .accept
        }
        guard shouldQuarantineBatteryLevel(
            previousLevel: previousLevel,
            previousAcceptedAt: previousAcceptedAt,
            incomingLevel: incomingLevel,
            receivedAt: receivedAt
        ) else {
            return .accept
        }
        return corroboratedBatteryLevelDecision(
            incomingLevel: incomingLevel,
            receivedAt: receivedAt,
            pending: pending,
            minimumSpan: transitionBatteryMinimumConfirmationSpan(incomingLevel: incomingLevel)
        )
    }

    private nonisolated static func corroboratedBatteryLevelDecision(
        incomingLevel: Int,
        receivedAt: Date,
        pending: BatteryDropCandidate?,
        minimumSpan: TimeInterval = implausibleBatteryDropMinimumConfirmationSpan
    ) -> BatteryLevelAcceptanceDecision {
        let candidateMaxAge = max(
            implausibleBatteryDropCandidateMaxAge,
            minimumSpan + (2 * batteryConfirmationRetryDelay(incomingLevel: incomingLevel))
        )
        let candidate: BatteryDropCandidate
        if let pending,
           abs(pending.level - incomingLevel) <= 2,
           receivedAt >= pending.lastSeenAt,
           receivedAt.timeIntervalSince(pending.firstSeenAt) <= candidateMaxAge {
            candidate = BatteryDropCandidate(
                level: incomingLevel,
                firstSeenAt: pending.firstSeenAt,
                lastSeenAt: receivedAt,
                confirmations: pending.confirmations + 1
            )
        } else {
            candidate = BatteryDropCandidate(
                level: incomingLevel,
                firstSeenAt: receivedAt,
                lastSeenAt: receivedAt,
                confirmations: 1
            )
        }
        let span = candidate.lastSeenAt.timeIntervalSince(candidate.firstSeenAt)
        if candidate.confirmations >= implausibleBatteryDropRequiredConfirmations,
           span >= minimumSpan {
            return .accept
        }
        return .quarantine(candidate)
    }

    nonisolated static func freshBatteryMinimumConfirmationSpan(
        incomingLevel: Int
    ) -> TimeInterval {
        (incomingLevel <= 10 || incomingLevel >= 100)
            ? freshBoundaryBatteryConfirmationMinimumSpan
            : freshBatteryConfirmationMinimumSpan
    }

    nonisolated static func transitionBatteryMinimumConfirmationSpan(
        incomingLevel: Int
    ) -> TimeInterval {
        (incomingLevel <= 10 || incomingLevel >= 100)
            ? freshBoundaryBatteryConfirmationMinimumSpan
            : implausibleBatteryDropMinimumConfirmationSpan
    }

    /// Powered state is a short, independently renewed lease. Missing or
    /// future-dated evidence fails closed; no percentage callback, reconnect or
    /// cached value is allowed to extend the lease implicitly.
    nonisolated static func batteryChargeLeaseDecision(
        status: BatteryChargeStatus,
        lastEvidenceAt: Date?,
        now: Date,
        maximumAge: TimeInterval = activeBatteryChargeDisplayMaxAge
    ) -> BatteryChargeLeaseDecision {
        guard status == .charging else { return .inactive }
        guard maximumAge >= 0,
              let lastEvidenceAt,
              now >= lastEvidenceAt else { return .expire }
        let age = now.timeIntervalSince(lastEvidenceAt)
        guard age <= maximumAge else { return .expire }
        return .retain(remaining: max(0, maximumAge - age))
    }

    nonisolated static func batteryValueBelongsToCurrentConnection(
        peripheralConnected: Bool,
        connectionStartedAt: Date?,
        receivedAt: Date
    ) -> Bool {
        guard peripheralConnected,
              let connectionStartedAt else { return false }
        return receivedAt >= connectionStartedAt
    }

    /// Historical/proprietary frames are an archive transport, not a current
    /// Battery Service authority. Some WHOOP 4 drains contain event-shaped
    /// payloads with an old SOC; allowing those to overwrite 2A19 made the
    /// visible percentage jump during a history repair. Current 2A19/2A1B
    /// callbacks remain independently accepted on their own paths.
    nonisolated static func batteryEventMayUpdateProjection(
        historyTransportActive: Bool
    ) -> Bool {
        !historyTransportActive
    }

    /// A 2A1B notification is usable as a present-power indication only if its
    /// CCCD enable completed in this process and (when known) after the current
    /// link began.
    nonisolated static func batteryStatusNotificationCanAuthorizeCharging(
        peripheralConnected: Bool,
        connectionStartedAt: Date?,
        notificationConfirmedAt: Date?,
        statusReceivedAt: Date
    ) -> Bool {
        guard peripheralConnected,
              let notificationConfirmedAt,
              notificationConfirmedAt <= statusReceivedAt else { return false }
        guard let connectionStartedAt else { return true }
        return notificationConfirmedAt >= connectionStartedAt
    }

    /// Some WHOOP 4 firmware restores 2A1B without emitting an initial value.
    /// One standard read on the current link is equivalent present-power
    /// evidence only for its short request/response window.
    nonisolated static func batteryStatusReadCanAuthorizeCharging(
        peripheralConnected: Bool,
        connectionStartedAt: Date?,
        readRequestedAt: Date?,
        statusReceivedAt: Date,
        maximumLatency: TimeInterval = 15
    ) -> Bool {
        guard peripheralConnected,
              let readRequestedAt,
              statusReceivedAt >= readRequestedAt,
              statusReceivedAt.timeIntervalSince(readRequestedAt) <= maximumLatency else {
            return false
        }
        guard let connectionStartedAt else { return true }
        return readRequestedAt >= connectionStartedAt
    }

    nonisolated static func batteryEventAcceptanceDecision(
        previousLevel: Int,
        previousAcceptedAt: Date?,
        reading: BatteryEventReading,
        receivedAt: Date,
        pending: BatteryDropCandidate?,
        previousIsCached: Bool = false,
        requiresFreshConfirmation: Bool = false,
        previousChargeStatus: BatteryChargeStatus = .levelOnly
    ) -> BatteryLevelAcceptanceDecision {
        guard isBatterySentinel(reading.level) else { return .accept }
        if batteryBoundaryEventIsIndependentlyCorroborated(
            previousLevel: previousLevel,
            previousAcceptedAt: previousAcceptedAt,
            previousChargeStatus: previousChargeStatus,
            reading: reading,
            receivedAt: receivedAt
        ) {
            return .accept
        }
        return batteryLevelAcceptanceDecision(
            previousLevel: previousLevel,
            previousAcceptedAt: previousAcceptedAt,
            incomingLevel: reading.level,
            receivedAt: receivedAt,
            pending: pending,
            previousIsCached: previousIsCached,
            requiresFreshConfirmation: requiresFreshConfirmation
        )
    }

    nonisolated static func batteryBoundaryEventIsIndependentlyCorroborated(
        previousLevel: Int,
        previousAcceptedAt: Date?,
        previousChargeStatus: BatteryChargeStatus = .levelOnly,
        reading: BatteryEventReading,
        receivedAt: Date
    ) -> Bool {
        guard isBatterySentinel(reading.level),
              (3_000...4_300).contains(reading.millivolts) else { return false }

        let hasRecentPrior = previousAcceptedAt.map {
            receivedAt >= $0 &&
                receivedAt.timeIntervalSince($0) <= reconnectBatteryBaselineMaximumAge
        } ?? false

        switch reading.level {
        case 100:
            let unmistakablyFullCell = reading.millivolts >= 4_200
            let recentNearFullTrajectory = hasRecentPrior &&
                (95...100).contains(previousLevel) &&
                reading.millivolts >= 4_050
            let recentPoweredTrajectory = hasRecentPrior &&
                (previousChargeStatus == .charging || previousChargeStatus == .full) &&
                previousLevel >= 90 &&
                reading.millivolts >= 4_050
            if reading.isCharging {
                return unmistakablyFullCell || recentNearFullTrajectory || recentPoweredTrajectory
            }
            return reading.millivolts >= 4_180 && recentNearFullTrajectory
        case 10:
            return !reading.isCharging &&
                reading.millivolts <= 3_550 &&
                hasRecentPrior &&
                (11...15).contains(previousLevel)
        case 0:
            return !reading.isCharging &&
                reading.millivolts <= 3_250 &&
                hasRecentPrior &&
                (1...5).contains(previousLevel)
        default:
            return false
        }
    }

    nonisolated static func parseBatteryLevelEventFrame(_ frame: [UInt8]) -> BatteryEventReading? {
        guard frame.count > 26,
              frame[0] == 0xAA,
              frame[4] == Packet.event,
              frame[6] == 0x03 else { return nil }
        let rawSOC = Int(frame[17]) | (Int(frame[18]) << 8)
        let millivolts = Int(frame[21]) | (Int(frame[22]) << 8)
        let chargeByte = frame[26]
        guard rawSOC <= 1_000,
              (3_000...4_300).contains(millivolts),
              chargeByte <= 1 else { return nil }
        return BatteryEventReading(level: Int((Double(rawSOC) / 10).rounded()),
                                   millivolts: millivolts,
                                   isCharging: chargeByte == 1)
    }

    nonisolated static func isBatterySentinel(_ level: Int) -> Bool {
        level <= 10 || level >= 100
    }

    nonisolated static func isPlausibleBatterySentinelTransition(
        previousLevel: Int,
        incomingLevel: Int
    ) -> Bool {
        guard (0...100).contains(previousLevel), isBatterySentinel(incomingLevel) else {
            return false
        }
        return abs(previousLevel - incomingLevel) <= 5
    }

    /// A 2A1B power-state update is useful only after this connection has
    /// successfully enabled that characteristic's notifications. This excludes
    /// restored/cache callbacks while still letting an attached charger appear
    /// immediately (SOC can legitimately remain unchanged for a long time).
    /// The caller still gives it a short lease, so a missing unplug update can
    /// never leave the bolt on indefinitely. Full is accepted only after an
    /// independently admitted 100% level.
    nonisolated static func acceptedBatteryChargeStatus(
        _ incoming: BatteryChargeStatus,
        batteryLevel: Int,
        hasPlausibleRiseEvidence: Bool,
        currentConnectionPowerStateConfirmed: Bool = false
    ) -> BatteryChargeStatus? {
        _ = hasPlausibleRiseEvidence
        switch incoming {
        case .notCharging, .levelOnly:
            return incoming
        case .charging:
            return currentConnectionPowerStateConfirmed ? .charging : nil
        case .full:
            return batteryLevel == 100 ? .full : nil
        }
    }

    /// Stream-4 charge bytes can replay a pre-unplug value and therefore carry
    /// level/voltage information only.
    nonisolated static func acceptedBatteryEventChargeStatus(
        reportedIsCharging: Bool,
        batteryLevel: Int
    ) -> BatteryChargeStatus {
        _ = reportedIsCharging
        _ = batteryLevel
        return .levelOnly
    }

    nonisolated static func chargeEvidenceFromBatteryLevelChange(
        previousLevel: Int,
        newLevel: Int
    ) -> BatteryChargeStatus? {
        guard previousLevel >= 0 else { return newLevel >= 100 ? .full : nil }
        if newLevel >= 100 { return .full }
        return newLevel < previousLevel ? .notCharging : nil
    }

    nonisolated static func shouldPreserveFreshChargingEvidence(
        currentStatus: BatteryChargeStatus,
        lastEvidenceAt: Date?,
        receivedAt: Date,
        maximumAge: TimeInterval = activeBatteryChargeDisplayMaxAge
    ) -> Bool {
        if case .retain = batteryChargeLeaseDecision(
            status: currentStatus,
            lastEvidenceAt: lastEvidenceAt,
            now: receivedAt,
            maximumAge: maximumAge
        ) {
            return true
        }
        return false
    }

    nonisolated static func hasFreshBatteryRiseEvidence(
        lastRiseAt: Date?,
        receivedAt: Date,
        maximumAge: TimeInterval = activeBatteryChargeEvidenceMaxAge
    ) -> Bool {
        guard let lastRiseAt, receivedAt >= lastRiseAt else { return false }
        return receivedAt.timeIntervalSince(lastRiseAt) <= maximumAge
    }

    nonisolated static func shouldRetainPersistedChargingAcrossReconnect(
        persistedStatus: BatteryChargeStatus,
        persistedAt: Date?,
        batteryRecentlyDropping: Bool,
        now: Date,
        maximumAge: TimeInterval = activeBatteryChargeEvidenceMaxAge
    ) -> Bool {
        guard !batteryRecentlyDropping else { return false }
        return shouldPreserveFreshChargingEvidence(
            currentStatus: persistedStatus,
            lastEvidenceAt: persistedAt,
            receivedAt: now,
            maximumAge: maximumAge
        )
    }

    nonisolated static func updatedBatteryRiseCandidate(
        current: BatteryRiseCandidate?,
        previousLevel: Int,
        previousAcceptedAt: Date?,
        newLevel: Int,
        receivedAt: Date,
        maximumSpan: TimeInterval = batteryRiseCandidateMaximumSpan
    ) -> BatteryRiseCandidate? {
        guard (0...99).contains(previousLevel),
              (1...99).contains(newLevel),
              newLevel >= previousLevel,
              previousAcceptedAt.map({ receivedAt >= $0 }) ?? true else { return nil }
        if let current,
           receivedAt >= current.lastAt,
           receivedAt.timeIntervalSince(current.startAt) <= maximumSpan {
            if newLevel == current.lastLevel { return current }
            guard newLevel > current.lastLevel else { return nil }
            return BatteryRiseCandidate(startLevel: current.startLevel,
                                        startAt: current.startAt,
                                        lastLevel: newLevel,
                                        lastAt: receivedAt,
                                        confirmations: current.confirmations + 1)
        }
        guard newLevel > previousLevel else { return nil }
        return BatteryRiseCandidate(startLevel: previousLevel,
                                    startAt: previousAcceptedAt ?? receivedAt,
                                    lastLevel: newLevel,
                                    lastAt: receivedAt,
                                    confirmations: 1)
    }

    nonisolated static func batteryRiseCandidateProvesCharging(
        _ candidate: BatteryRiseCandidate,
        minimumRise: Int = 1,
        minimumSpan: TimeInterval = 30,
        maximumSpan: TimeInterval = batteryRiseCandidateMaximumSpan
    ) -> Bool {
        let span = candidate.lastAt.timeIntervalSince(candidate.startAt)
        let rise = candidate.lastLevel - candidate.startLevel
        // 2A19 is change-driven and each value has already passed the
        // current-link and transition truth gates. A bounded increase across
        // real time is therefore sufficient external-power evidence; waiting
        // for three integer changes made Charging lag for many minutes. Keep
        // large corrections rejected and retain the short presentation lease
        // so unplugging still fails closed.
        let boundedRise = (minimumRise...10).contains(rise)
        return candidate.confirmations >= 1
            && boundedRise
            && span >= minimumSpan
            && span <= maximumSpan
    }

    nonisolated static func batteryRiseCandidateAfterExplicitChargeStatus(
        _ status: BatteryChargeStatus,
        current: BatteryRiseCandidate?
    ) -> BatteryRiseCandidate? {
        switch status {
        case .notCharging, .full:
            return nil
        case .charging, .levelOnly:
            return current
        }
    }

    nonisolated static func batteryRiseCandidateAfterReconnect(
        _ candidate: BatteryRiseCandidate?,
        candidatePeripheralID: UUID?,
        connectedPeripheralID: UUID,
        now: Date,
        maximumAge: TimeInterval = batteryRiseCandidateMaximumSpan
    ) -> BatteryRiseCandidate? {
        guard let candidate,
              candidatePeripheralID == connectedPeripheralID,
              now >= candidate.lastAt,
              now.timeIntervalSince(candidate.lastAt) <= maximumAge else { return nil }
        return candidate
    }

    nonisolated static func parseBatteryLevel(_ data: Data) -> Int? {
        guard data.count == 1, let byte = data.first, byte <= 100 else { return nil }
        return Int(byte)
    }

    nonisolated static func parseBatteryChargeStatus(_ data: Data) -> BatteryChargeStatus? {
        let bytes = [UInt8](data)
        guard let powerState = batteryPowerStateByte(fromBatteryLevelStatus: bytes) else { return nil }
        let wiredExternalPower = (powerState >> 2) & 0x03
        let wirelessExternalPower = (powerState >> 4) & 0x03
        let chargeState = (powerState >> 6) & 0x03
        if chargeState == 0x03 { return .charging }
        if chargeState == 0x02 { return .notCharging }
        if wiredExternalPower == 0x03 || wirelessExternalPower == 0x03 { return .charging }
        if wiredExternalPower == 0x02 && wirelessExternalPower == 0x02 { return .notCharging }
        return nil
    }

    private nonisolated static func batteryPowerStateByte(
        fromBatteryLevelStatus bytes: [UInt8]
    ) -> UInt8? {
        guard let flags = bytes.first else { return nil }
        if bytes.count >= 3 { return bytes[2] }
        if bytes.count == 2, flags & 0x01 == 0 { return bytes[1] }
        return nil
    }

    /// Persists charge-state evidence without touching the separately timed
    /// battery level. This prevents a stale charge-only packet from making an
    /// old percentage look current.
    nonisolated static func persistBatteryChargeStatusProjection(
        _ status: BatteryChargeStatus,
        source: String,
        defaults: UserDefaults,
        now: Date = Date()
    ) {
        defaults.set(status.rawValue, forKey: BatteryDefaults.chargeStatus)
        defaults.set(now.timeIntervalSince1970, forKey: BatteryDefaults.chargeAt)
        defaults.set(source, forKey: "atria.battery.chargeSource")
    }
}
