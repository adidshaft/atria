import Foundation

/// R10 can provide strap-side steps, but it may never compete with heart-rate
/// collection. A lease is one user-started workout (Walking included) and
/// fresh accepted HR. Reconnects rebind the same workout; they do not revoke.
/// History may not own proprietary transport while that workout is still
/// active — `r10_step_lease_revoked_history_owner` is only legal after it ends.
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

    /// History wins the radio only when no manual workout is still running.
    static func historyOwnsTransportForStepLease(
        manualWorkoutActive: Bool,
        historySyncInProgress: Bool
    ) -> Bool {
        !manualWorkoutActive && historySyncInProgress
    }

    /// Implicit (and explicit) history drain must not claim proprietary
    /// transport while a user-started workout still holds the live R10 lease.
    static func shouldClaimHistoryTransport(manualWorkoutActive: Bool) -> Bool {
        !manualWorkoutActive
    }

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
        // A live workout keeps the R10 lease. History must not have claimed
        // transport (`shouldClaimHistoryTransport`); if a generation is still
        // marked in-progress, wait rather than revoke IMU mid-session.
        _ = historyOwnsTransport
        guard connected, let connectionStartedAt else { return .revoke(.disconnected) }
        guard let leaseStartedAt,
              now >= leaseStartedAt,
              now.timeIntervalSince(leaseStartedAt) <= maximumDuration else {
            return .revoke(.expired)
        }
        // Wall-clock freshness only. Requiring HR after `connectionStartedAt`
        // revoked on every BLE blip (2026-09-08 gym: 20–47 s 2A37 holes)
        // before the first sample of the new epoch arrived.
        guard let lastAcceptedHeartRateAt,
              now >= lastAcceptedHeartRateAt,
              now.timeIntervalSince(lastAcceptedHeartRateAt) <= heartRateFreshness else {
            return .revoke(.heartRateNotFresh)
        }
        if leaseConnectionStartedAt == nil {
            return .grant
        }
        if leaseConnectionStartedAt != connectionStartedAt {
            // Same workout, new BLE epoch: rebind. Do not revoke.
            return .grant
        }
        return .keep
    }
}
