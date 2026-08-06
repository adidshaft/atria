import Foundation

/// A fail-closed barrier in front of the first WHOOP history command.
/// CoreBluetooth accepts characteristic writes before its queued CCCD writes
/// have completed, so TX discovery alone is not history-transport readiness.
struct AtriaBLEHistoryNotificationReadinessGate<Identifier: Hashable> {
    enum Decision: Equatable {
        case waitingForConnectedLink
        case waitingForTX
        case waitingForNotifications(missing: Set<Identifier>)
        case ready
    }

    let requiredNotifications: Set<Identifier>

    func decision(
        linkConnected: Bool,
        txAvailable: Bool,
        activeNotifications: Set<Identifier>
    ) -> Decision {
        guard linkConnected else { return .waitingForConnectedLink }
        guard txAvailable else { return .waitingForTX }
        let missing = requiredNotifications.subtracting(activeNotifications)
        guard missing.isEmpty else {
            return .waitingForNotifications(missing: missing)
        }
        return .ready
    }
}

/// CoreBluetooth may defer a WHOOP write-with-response callback while its
/// notification setup queue settles. Physical WHOOP 4 evidence reached 8.6s;
/// this bounded window preserves exact-callback confirmation without treating
/// that observed latency as failure or permitting a same-connection retry.
enum AtriaBLEHistoryWriteConfirmationPolicy {
    /// The successful physical drain left 2.77s between the final stream-7
    /// notification callback and 03/00. Failed runs wrote after only ~0.155s.
    static let postNotificationSettleInterval: TimeInterval = 3
    static let timeout: TimeInterval = 15
    static let pollInterval: TimeInterval = 0.1
    static let maximumPollAttempts = Int(timeout / pollInterval)
}
