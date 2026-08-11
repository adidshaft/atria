import Foundation

/// Sticky, ticket-scoped authority for recovered-data work admitted while the
/// app is interactive.
///
/// Scene, thermal, and Low Power transitions revoke this object instead of
/// merely cancelling the coordinator's timeout. Every worker captures the same
/// instance, so a stale callback can never become valid again after conditions
/// recover or after a newer coordinator generation starts.
final class AtriaRecoveredDataExecutionLease: @unchecked Sendable {
    struct Identity: Equatable, Sendable {
        let generation: UInt64
        let archiveRevision: UInt64
    }

    private let lock = NSLock()
    let identity: Identity
    private var revoked = false
    private var revocationReason: String?

    init(generation: UInt64, archiveRevision: UInt64) {
        identity = Identity(
            generation: generation,
            archiveRevision: archiveRevision
        )
    }

    @discardableResult
    func revoke(reason: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !revoked else { return false }
        revoked = true
        revocationReason = reason
        return true
    }

    /// Environmental failure is itself a sticky revocation. This closes the
    /// notification-delivery race: an off-main checkpoint that observes heat,
    /// LPM, or the process-wide scene gate invalidates every later callback even
    /// if the environment recovers before the main actor handles the deferral.
    func shouldContinue() -> Bool {
        lock.lock()
        if revoked {
            lock.unlock()
            return false
        }
        let reason: String?
        let thermal = ProcessInfo.processInfo.thermalState
        if AtriaHistoricalProjectionForegroundGate.isBackgrounded {
            reason = "application_background"
        } else if thermal == .serious || thermal == .critical {
            reason = "thermal_\(thermal.rawValue)"
        } else if ProcessInfo.processInfo.isLowPowerModeEnabled {
            reason = "low_power_mode"
        } else {
            reason = nil
        }
        if let reason {
            revoked = true
            revocationReason = reason
            lock.unlock()
            return false
        }
        lock.unlock()
        return true
    }

    var isRevoked: Bool {
        lock.lock()
        defer { lock.unlock() }
        return revoked
    }

    var recordedRevocationReason: String? {
        lock.lock()
        defer { lock.unlock() }
        return revocationReason
    }
}
