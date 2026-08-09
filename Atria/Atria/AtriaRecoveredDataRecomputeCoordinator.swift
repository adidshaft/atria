import Foundation

/// A fail-closed completion fence for archive-backed analytics recomputation.
///
/// `HistoricalArchive.didUpdateNotification` is allowed to arrive while an
/// earlier archive scan or its derived cache fan-out is still running. This
/// reducer keeps at most one run active and one latest trailing request. A run
/// may publish only after its projection and every required derived component
/// have explicitly completed, and only when no newer archive revision is
/// waiting. Callers should own and mutate it on one executor (SessionStore uses
/// the main actor); the value itself performs no work and owns no timers.
struct AtriaRecoveredDataRecomputeCoordinator: Sendable {
    enum Component: String, CaseIterable, Hashable, Sendable {
        /// Archive diagnostics and the bounded cycle-HR cache.
        case archiveStatusAndCycleHeartRate
        /// Confirmed workouts rebuilt from exact-timestamp recovered samples.
        case confirmedWorkouts
        /// Recovered canonical sessions must settle confirmed sleep before any
        /// wake-day history or readiness projection is allowed to publish.
        case sleepSettlement
        /// History + sleep snapshots and their nested daily metric/rollup write.
        case historySleepAndDailyRollups
        case overviewTrends
        case trainingLoad
        case todayHeartRateZones
        /// Journal correlations whose day inputs are written by the history pass.
        case behaviorInsights
    }

    static let sessionStoreComponents = Set(Component.allCases)

    struct Ticket: Equatable, Sendable {
        let generation: UInt64
        let archiveRevision: UInt64
        let reason: String
    }

    struct Failure: Equatable, Sendable {
        let component: Component?
        let reason: String
    }

    enum Effect: Equatable, Sendable {
        /// Start the off-main archive read and recovered-session projection.
        case startProjection(Ticket)
        /// Start every listed computation and report each result separately.
        case startDerived(Ticket, Set<Component>)
        /// The run was intentionally discarded because newer durable input won.
        case superseded(Ticket)
        /// An automatic freshness ticket was admitted from cheap metadata, but
        /// its authoritative worker plan was no longer reuse/small-incremental.
        /// The durable archive remains queued for the guarded BGProcessing lane;
        /// this is an intentional retirement, not a recovery failure.
        case reservedForSafeBackground(Ticket)
        /// No dashboard/widget publication is authorized for this run.
        case failed(Ticket, Failure)
        /// The sole effect that authorizes one dashboard/widget publication.
        case publish(Ticket)
        /// Ask the owner to call `startPendingTrailing()` after this delay.
        /// Inter-cycle REST (2026-08-04): during drain catch-up a new archive
        /// revision lands while every cycle runs, so trailing requests used
        /// to start back-to-back forever — and on the iOS 27 beta each
        /// cycle's ~1GB of transient projection garbage is only reclaimed at
        /// thread teardown, so uninterrupted cycles crept the footprint into
        /// the 3.4GB jetsam ceiling. Resting between cycles bounds the creep
        /// and costs only freshness-latency, never data.
        case scheduleTrailingStart(afterSeconds: TimeInterval)
    }

    enum Phase: Equatable, Sendable {
        case idle
        case projecting(Ticket)
        case deriving(Ticket, pending: Set<Component>)
        case failed(Ticket, Failure)
    }

    private struct Request: Equatable, Sendable {
        let archiveRevision: UInt64
        let reason: String
    }

    // 20s, was 12 (2026-08-04): reclaim after a cycle is gradual; trailing
    // cycles that started from a ~1GB baseline still crossed the ceiling.
    static let interCycleRestSeconds: TimeInterval = 20

    private(set) var phase: Phase = .idle
    private(set) var latestRequestedArchiveRevision: UInt64?
    private var restingUntil: Date?
    private(set) var coalescedRequestCount = 0
    private var nextGeneration: UInt64 = 0
    private var trailingRequest: Request?
    private let requiredComponents: Set<Component>

    init(requiredComponents: Set<Component> = Self.sessionStoreComponents) {
        self.requiredComponents = requiredComponents
    }

    /// Registers a newly durable archive revision. Duplicate or regressed
    /// revisions are ignored. While work is active, only the newest request is
    /// retained; the active run is allowed to finish but can no longer publish.
    mutating func request(archiveRevision: UInt64,
                          reason: String,
                          now: Date = Date()) -> [Effect] {
        if let latestRequestedArchiveRevision,
           archiveRevision <= latestRequestedArchiveRevision {
            return []
        }
        latestRequestedArchiveRevision = archiveRevision
        let request = Request(archiveRevision: archiveRevision, reason: reason)

        switch phase {
        case .idle, .failed:
            if let restingUntil, now < restingUntil {
                // Mid-rest: queue as the (newest-wins) trailing request and
                // re-arm the wake. Extra wakes are harmless — the start call
                // is idempotent.
                if trailingRequest != nil {
                    coalescedRequestCount &+= 1
                }
                trailingRequest = request
                return [.scheduleTrailingStart(
                    afterSeconds: restingUntil.timeIntervalSince(now))]
            }
            trailingRequest = nil
            return start(request)
        case .projecting, .deriving:
            if trailingRequest != nil {
                coalescedRequestCount &+= 1
            }
            trailingRequest = request
            return []
        }
    }

    /// Starts the queued trailing request once the inter-cycle rest elapses.
    /// Idempotent: with no queued work, or with a cycle already active
    /// (a manual retry can race the wake), this is a no-op.
    mutating func startPendingTrailing(now: Date = Date()) -> [Effect] {
        if let restingUntil, now < restingUntil { return [] }
        restingUntil = nil
        switch phase {
        case .idle, .failed:
            guard let trailingRequest else { return [] }
            self.trailingRequest = nil
            return start(trailingRequest)
        case .projecting, .deriving:
            return []
        }
    }

    /// Retries the last failed durable input without pretending that a new
    /// archive batch arrived. The new ticket rejects late callbacks from the
    /// failed generation.
    mutating func retryFailed(reason: String) -> [Effect] {
        guard case let .failed(ticket, _) = phase else { return [] }
        restingUntil = nil
        return start(Request(archiveRevision: ticket.archiveRevision,
                             reason: reason))
    }

    /// Projection success means the recovered sessions have been installed and
    /// synchronous invalidations have committed. Derived fan-out starts only
    /// then. A queued newer archive revision skips this obsolete fan-out.
    mutating func projectionCompleted(
        ticket: Ticket,
        failureReason: String? = nil,
        now: Date = Date()
    ) -> [Effect] {
        guard case let .projecting(active) = phase, active == ticket else {
            return []
        }
        if let failureReason {
            return fail(ticket: ticket,
                        failure: Failure(component: nil, reason: failureReason),
                        now: now)
        }
        if trailingRequest != nil {
            return restThenStartTrailing(ticket, now: now)
        }
        guard !requiredComponents.isEmpty else {
            phase = .idle
            restingUntil = now.addingTimeInterval(Self.interCycleRestSeconds)
            return [.publish(ticket)]
        }
        phase = .deriving(ticket, pending: requiredComponents)
        return [.startDerived(ticket, requiredComponents)]
    }

    /// Retires one exact projecting ticket whose authoritative pre-scan plan
    /// exceeded the automatic freshness budget. No scan or mutation has run,
    /// so there is no allocator-rest penalty; a newer coalesced request may
    /// start immediately. Late callbacks are rejected by the usual ticket
    /// identity check because `phase` has already moved on.
    mutating func projectionReservedForSafeBackground(
        ticket: Ticket
    ) -> [Effect] {
        guard case let .projecting(active) = phase, active == ticket else {
            return []
        }
        let retired = Effect.reservedForSafeBackground(ticket)
        phase = .idle
        restingUntil = nil
        guard let trailingRequest else { return [retired] }
        self.trailingRequest = nil
        return [retired] + start(trailingRequest)
    }

    /// Records one real derived completion. Duplicate, out-of-order, and stale
    /// callbacks are ignored. Any failure closes the publication gate.
    mutating func componentCompleted(
        ticket: Ticket,
        component: Component,
        failureReason: String? = nil,
        now: Date = Date()
    ) -> [Effect] {
        guard case let .deriving(active, pending) = phase,
              active == ticket,
              pending.contains(component) else {
            return []
        }
        if let failureReason {
            return fail(ticket: ticket,
                        failure: Failure(component: component, reason: failureReason),
                        now: now)
        }

        var remaining = pending
        remaining.remove(component)
        guard remaining.isEmpty else {
            phase = .deriving(ticket, pending: remaining)
            return []
        }
        if trailingRequest != nil {
            return restThenStartTrailing(ticket, now: now)
        }
        phase = .idle
        restingUntil = now.addingTimeInterval(Self.interCycleRestSeconds)
        return [.publish(ticket)]
    }

    func pendingComponents(ticket: Ticket) -> Set<Component>? {
        guard case let .deriving(active, pending) = phase,
              active == ticket else { return nil }
        return pending
    }

    /// True while a recompute cycle is running OR one is queued behind the
    /// inter-cycle rest (2026-08-05 heavy-lane fix): after a supersede the
    /// phase goes .idle for the 20s rest with trailing work queued — the
    /// retained recovered working set (~1.3GB) is still resident, so external
    /// heavy passes must keep deferring through that window. A quiet idle
    /// (no trailing request) frees the lane.
    var heavyCycleEngaged: Bool {
        switch phase {
        case .projecting, .deriving:
            return true
        case .idle, .failed:
            return trailingRequest != nil
        }
    }

    /// The owner schedules a bounded timeout for every ticket. A hung archive
    /// read or missing callback must retain the previous dashboard/widget image,
    /// never authorize a partial publication.
    mutating func timedOut(
        ticket: Ticket,
        component: Component? = nil
    ) -> [Effect] {
        let failureComponent: Component?
        switch phase {
        case .projecting(let active):
            guard active == ticket else { return [] }
            failureComponent = nil
        case .deriving(let active, let pending):
            guard active == ticket else { return [] }
            failureComponent = component.flatMap { pending.contains($0) ? $0 : nil }
        case .idle, .failed:
            return []
        }
        return fail(ticket: ticket,
                    failure: Failure(component: failureComponent, reason: "timed_out"))
    }

    private mutating func start(_ request: Request) -> [Effect] {
        nextGeneration &+= 1
        let ticket = Ticket(generation: nextGeneration,
                            archiveRevision: request.archiveRevision,
                            reason: request.reason)
        phase = .projecting(ticket)
        return [.startProjection(ticket)]
    }

    private mutating func fail(ticket: Ticket,
                               failure: Failure,
                               now: Date = Date()) -> [Effect] {
        let failedEffect = Effect.failed(ticket, failure)
        phase = .failed(ticket, failure)
        guard trailingRequest != nil else {
            return [failedEffect]
        }
        // Trailing work survives the failure but honors the same rest.
        restingUntil = now.addingTimeInterval(Self.interCycleRestSeconds)
        return [failedEffect,
                .scheduleTrailingStart(afterSeconds: Self.interCycleRestSeconds)]
    }

    private mutating func restThenStartTrailing(_ ticket: Ticket,
                                                now: Date) -> [Effect] {
        guard trailingRequest != nil else { return [] }
        phase = .idle
        restingUntil = now.addingTimeInterval(Self.interCycleRestSeconds)
        return [.superseded(ticket),
                .scheduleTrailingStart(afterSeconds: Self.interCycleRestSeconds)]
    }
}
