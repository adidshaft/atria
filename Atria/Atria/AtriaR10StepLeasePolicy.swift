import Foundation

/// R10 can provide strap-side steps, but it may never compete with heart-rate
/// collection or historical recovery. A lease is deliberately limited to one
/// user-started workout (Walking included), one BLE epoch, and fresh accepted
/// HR evidence.
enum AtriaR10StepLeasePolicy {
    enum Revocation: Equatable, Sendable {
        case noManualWorkout
        case historyOwnsTransport
        case disconnected
        case connectionChanged
        case heartRateNotFresh
        case expired
    }

    enum Decision: Equatable, Sendable {
        case grant
        case keep
        case revoke(Revocation)
    }

    /// A stale persisted workout must not own dense proprietary transport
    /// indefinitely. The workout record has its own recovery lifetime; the
    /// live R10 evidence lease is intentionally much shorter.
    static let maximumDuration: TimeInterval = 3 * 60 * 60
    static let heartRateFreshness: TimeInterval = 15

    static func decision(
        manualWorkoutActive: Bool,
        historyOwnsTransport: Bool,
        connected: Bool,
        connectionStartedAt: Date?,
        leaseConnectionStartedAt: Date?,
        leaseStartedAt: Date?,
        lastAcceptedHeartRateAt: Date?,
        now: Date,
        maximumDuration: TimeInterval = maximumDuration,
        heartRateFreshness: TimeInterval = heartRateFreshness
    ) -> Decision {
        guard manualWorkoutActive else { return .revoke(.noManualWorkout) }
        guard !historyOwnsTransport else { return .revoke(.historyOwnsTransport) }
        guard connected, let connectionStartedAt else { return .revoke(.disconnected) }
        if let leaseConnectionStartedAt, leaseConnectionStartedAt != connectionStartedAt {
            return .revoke(.connectionChanged)
        }
        guard let leaseStartedAt,
              now >= leaseStartedAt,
              now.timeIntervalSince(leaseStartedAt) <= maximumDuration else {
            return .revoke(.expired)
        }
        guard let lastAcceptedHeartRateAt,
              lastAcceptedHeartRateAt >= connectionStartedAt,
              now >= lastAcceptedHeartRateAt,
              now.timeIntervalSince(lastAcceptedHeartRateAt) <= heartRateFreshness else {
            return .revoke(.heartRateNotFresh)
        }
        return leaseConnectionStartedAt == nil ? .grant : .keep
    }
}
