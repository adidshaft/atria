import Foundation

/// Presentation-layer debounce: hold the last good value briefly instead of
/// hard-blanking a populated surface.
///
/// A metric that vanishes and comes back a second later reads as a broken
/// product even when the underlying pipeline is behaving correctly. Atria's
/// status and metric surfaces are recomputed on transient inputs — a drain
/// slice pausing 2A37, a sync generation starting, a projection republishing —
/// and several of them fail closed to an empty/"waiting"/"partial" state for
/// the width of that recompute. Observed on device 2026-08-24: the Home banner
/// flipping "Recovery partial · 40 saved" ↔ "Strap data gap · history
/// incomplete", and the Vitals live reading flipping "5 min of continuous
/// signal" ↔ "Waiting for a fresh strap signal", both within a minute and
/// neither reflecting a real change in the underlying value.
///
/// HONESTY CONTRACT — the hold is a debounce, never a freshness claim:
/// * Only a DOWNGRADE is ever held. An upgrade renders immediately.
/// * The hold is BOUNDED by `grace`. Once a downgrade has persisted for the
///   grace window, the honest lower state renders and stays.
/// * Nothing is fabricated. The held value is one this surface genuinely
///   showed a moment ago; the policy only chooses *when* to stop showing it.
///
/// This is deliberately a pure value type with an injected `now` so every
/// surface that adopts it is unit-testable without a clock.
enum AtriaHoldLastGoodPresentation {

    /// Default grace window. Long enough to cover a drain slice's status
    /// churn and a projection republish, short enough that a genuinely
    /// unavailable metric is honest well inside a glance.
    static let defaultGrace: TimeInterval = 6

    /// The outcome of one resolve pass.
    struct Resolution<Value: Equatable>: Equatable {
        /// What the surface should render right now.
        let value: Value
        /// Carry this back into the next `resolve` call.
        let state: State<Value>
        /// True while a downgrade is being suppressed. Surfaces may use this
        /// to show a subtle "updating" affordance — never to claim freshness.
        let isHoldingLastGood: Bool
    }

    /// Opaque carry-over state. Start with `.initial`.
    struct State<Value: Equatable>: Equatable {
        fileprivate var shown: Value?
        fileprivate var shownRank: Int
        fileprivate var downgradeSince: Date?

        static var initial: State<Value> {
            State(shown: nil, shownRank: Int.min, downgradeSince: nil)
        }
    }

    /// Resolve what to render.
    ///
    /// - Parameters:
    ///   - incoming: the freshly computed state.
    ///   - rank: how informative `incoming` is. Higher is more informative; a
    ///     drop below the currently shown rank is the downgrade that may be
    ///     held. Ranks only need to be consistent within one surface.
    ///   - state: the carry-over from the previous call.
    ///   - now: injected clock.
    ///   - grace: how long a downgrade may be suppressed.
    static func resolve<Value: Equatable>(
        incoming: Value,
        rank: Int,
        state: State<Value>,
        now: Date,
        grace: TimeInterval = defaultGrace
    ) -> Resolution<Value> {
        // First value ever, or an identical repeat: nothing to debounce.
        guard let shown = state.shown else {
            return Resolution(
                value: incoming,
                state: State(shown: incoming,
                             shownRank: rank,
                             downgradeSince: nil),
                isHoldingLastGood: false
            )
        }

        // Same-or-better information always renders immediately. This also
        // covers a recovery back to the held value, which clears the hold.
        if rank >= state.shownRank {
            return Resolution(
                value: incoming,
                state: State(shown: incoming,
                             shownRank: rank,
                             downgradeSince: nil),
                isHoldingLastGood: false
            )
        }

        // A downgrade. Keep showing the last good value until the grace
        // window measured from the FIRST downgrade in this run expires.
        let since = state.downgradeSince ?? now
        let held = now.timeIntervalSince(since)
        guard held >= 0, held < grace else {
            // Grace spent (or the clock moved backwards — fail honest).
            return Resolution(
                value: incoming,
                state: State(shown: incoming,
                             shownRank: rank,
                             downgradeSince: nil),
                isHoldingLastGood: false
            )
        }

        return Resolution(
            value: shown,
            state: State(shown: shown,
                         shownRank: state.shownRank,
                         downgradeSince: since),
            isHoldingLastGood: true
        )
    }
}

/// Adopted by a presentation type that can be held by
/// `AtriaHoldLastGoodPresentation`.
///
/// `atriaHoldRank` orders states by how much real information they carry. A
/// scored/populated state outranks a partial one, which outranks an
/// empty/"waiting" one. Only rank ordering matters; the absolute values are
/// private to each surface.
protocol AtriaHoldableStatus: Equatable {
    var atriaHoldRank: Int { get }
}

extension AtriaHoldLastGoodPresentation {
    /// Convenience overload for types that carry their own rank.
    static func resolve<Value: AtriaHoldableStatus>(
        incoming: Value,
        state: State<Value>,
        now: Date,
        grace: TimeInterval = defaultGrace
    ) -> Resolution<Value> {
        resolve(incoming: incoming,
                rank: incoming.atriaHoldRank,
                state: state,
                now: now,
                grace: grace)
    }
}

/// Rank for the strap-history recovery banner shared by Today, Activity and
/// Vitals. Device 2026-08-24: this state oscillated between `.partial` and
/// `.needsAttention` inside a minute, so the banner flipped "Recovery partial
/// · 40 saved" ↔ "Strap data gap · history incomplete" — and, because each tab
/// renders at its own instant, two tabs could show two different messages for
/// one underlying state. Debouncing it at the single source fixes the flicker
/// and the cross-tab disagreement together.
extension AtriaBLEManager.HistoricalRecoveryPresentation: AtriaHoldableStatus {
    var atriaHoldRank: Int {
        switch self {
        case .verified: return 4
        case .syncing: return 3
        case .partial: return 2
        case .needsAttention: return 1
        case .idle: return 0
        }
    }
}
