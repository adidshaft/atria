import Foundation

/// User-facing "catch up faster" affordance for the strap drain.
///
/// The WHOOP4 in all-day Saver mode banks motion to flash and drips it out over
/// an intermittent link, so after a long offline stretch the strap can sit
/// hours behind and steps/strain look stuck. The higher-cadence "Coverage"
/// profile (full-protocol motion streaming + a warmer link) drains far faster
/// but costs battery, so it must NOT be the always-on default. This policy
/// decides when to *offer* the boost, keep it running, or turn it back off —
/// so the user gets a one-tap "catch up" exactly when it helps and never has to
/// remember to undo it.
///
/// Pure and dependency-free so the whole state machine is unit-testable; the
/// BLE/UI layers only supply the three inputs and act on the decision.
enum AtriaCatchUpBoostDecision: String, Equatable, Sendable {
    /// Nothing to do: either caught up, or not far enough behind to bother.
    case idle
    /// The drain is hours behind and the boost is off — offer the one-tap CTA.
    case suggest
    /// The boost is on and there is still a backlog — keep boosting, show the
    /// "catching up…" state.
    case active
    /// The boost is on and the strap has caught up — turn it back off and
    /// restore the user's previous profile automatically.
    case autoRevert
}

enum AtriaCatchUpBoost {
    /// Only offer the boost once the drain is at least this far behind. A short
    /// lag is normal (oldest-first drip) and self-heals; the affordance is for
    /// the "hours behind after a long offline stretch" case the user hits.
    static let suggestBehindThreshold: TimeInterval = 4 * 60 * 60

    /// The boost auto-reverts once the strap is within this window of `now`
    /// (or reports no remaining backlog). Wider than the banner's own
    /// "synced" window so the revert fires slightly before the gap fully
    /// closes rather than flapping right at the boundary.
    static let caughtUpWithin: TimeInterval = 12 * 60

    /// - Parameters:
    ///   - behindSeconds: how far the durable drain frontier is behind `now`
    ///     (nil when unknown — treated as "not known to be far behind" for the
    ///     suggest gate, and as "not known to be caught up" for the revert gate,
    ///     so an unknown frontier never spuriously suggests nor spuriously
    ///     reverts).
    ///   - backlogPending: the robust backlog signal (strap still holds
    ///     undrained records). This is the authority for "is there work left".
    ///   - boostActive: whether the user has the catch-up boost currently on.
    static func decide(behindSeconds: TimeInterval?,
                       backlogPending: Bool,
                       boostActive: Bool) -> AtriaCatchUpBoostDecision {
        if boostActive {
            // Caught up when the strap reports no backlog, OR the frontier is
            // known to be within the caught-up window. A nil frontier keeps the
            // boost running (we don't know it's caught up) — but a cleared
            // backlog still reverts, so it can never latch on forever.
            let frontierCaughtUp = behindSeconds.map { $0 <= caughtUpWithin } ?? false
            if !backlogPending || frontierCaughtUp {
                return .autoRevert
            }
            return .active
        }
        // Off: only suggest when there is genuinely a backlog AND we KNOW the
        // frontier is hours behind. Unknown/near frontier stays idle.
        guard backlogPending, let behind = behindSeconds,
              behind >= suggestBehindThreshold else {
            return .idle
        }
        return .suggest
    }

    /// Human-readable "how far behind" for the CTA subtitle, e.g. "~6h behind".
    /// Returns nil below the suggest threshold so callers never under-sell it.
    static func behindDescription(behindSeconds: TimeInterval?) -> String? {
        guard let behind = behindSeconds, behind >= suggestBehindThreshold else {
            return nil
        }
        let hours = Int((behind / 3600).rounded())
        if hours >= 1 { return "~\(hours)h behind" }
        let minutes = max(1, Int((behind / 60).rounded()))
        return "~\(minutes)m behind"
    }
}
