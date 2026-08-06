import Foundation

/// A single immutable view of the small policy surface read synchronously by
/// CoreBluetooth's private delegate queue. MainActor owns the higher-level
/// state machines; this lock prevents their callback-facing mode bits from
/// being observed as a torn mixture during discovery.
final class AtriaBLECallbackPolicyState: @unchecked Sendable {
    struct Snapshot: Equatable, Sendable {
        var standardHROnly: Bool
        var onboardingPairingPreflight: Bool
        var historySkipsDataRange: Bool
        var protectedProfileIsEmpty: Bool
        var protectedStandardDiscoveryStarted: Bool
    }

    private let lock = NSLock()
    private var value: Snapshot

    init(
        standardHROnly: Bool,
        onboardingPairingPreflight: Bool = false,
        historySkipsDataRange: Bool = false,
        protectedProfileIsEmpty: Bool = true,
        protectedStandardDiscoveryStarted: Bool = false
    ) {
        value = Snapshot(
            standardHROnly: standardHROnly,
            onboardingPairingPreflight: onboardingPairingPreflight,
            historySkipsDataRange: historySkipsDataRange,
            protectedProfileIsEmpty: protectedProfileIsEmpty,
            protectedStandardDiscoveryStarted: protectedStandardDiscoveryStarted
        )
    }

    func snapshot() -> Snapshot {
        lock.withLock { value }
    }

    func update(_ mutation: (inout Snapshot) -> Void) {
        lock.withLock {
            mutation(&value)
        }
    }
}
