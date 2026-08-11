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
        /// Bounded publication for the current physiological cycle and newest
        /// sleep only. This component deliberately excludes archive diagnostics,
        /// workout repair, lifetime history, trends, and other global fan-out.
        case currentCycleAndLatestNight
    }

    static let sessionStoreComponents: Set<Component> = [
        .archiveStatusAndCycleHeartRate,
        .confirmedWorkouts,
        .sleepSettlement,
        .historySleepAndDailyRollups,
        .overviewTrends,
        .trainingLoad,
        .todayHeartRateZones,
        .behaviorInsights,
    ]

    enum Scope: Equatable, Sendable {
        case full
        /// The associated cutoff is captured before metadata admission and is
        /// carried through the worker/derived boundary as immutable authority.
        case automaticCurrentCycle(since: Date)
    }

    enum ExecutionDomain: Equatable, Sendable {
        case foreground
        case explicitBackground
    }

    struct Ticket: Equatable, Sendable {
        let generation: UInt64
        let archiveRevision: UInt64
        let reason: String
        let scope: Scope
        let executionDomain: ExecutionDomain

        init(
            generation: UInt64,
            archiveRevision: UInt64,
            reason: String,
            scope: Scope = .full,
            executionDomain: ExecutionDomain = .foreground
        ) {
            self.generation = generation
            self.archiveRevision = archiveRevision
            self.reason = reason
            self.scope = scope
            self.executionDomain = executionDomain
        }
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
        /// Foreground authority was revoked while this exact ticket was either
        /// projecting or deriving. The owner must synchronously roll back the
        /// provisional transaction, but must not fail its publication fence or
        /// start the retained retry until a later foreground-resume edge.
        case deferredUntilForeground(Ticket)
        /// An automatic freshness ticket was admitted from cheap metadata, but
        /// its authoritative worker plan was no longer reuse/small-incremental.
        /// The durable archive remains queued for the guarded BGProcessing lane;
        /// this is an intentional retirement, not a recovery failure.
        case reservedForSafeBackground(Ticket)
        /// A leased background ticket lost its exact throttle generation after
        /// provisional mutation began. Roll back fully, retain durable bootstrap
        /// intent, and never launder this work into an ordinary foreground retry.
        case cancelledForSafeBackground(Ticket)
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
        let scope: Scope
        let executionDomain: ExecutionDomain
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
    /// One newest-wins request retained across a lifecycle/thermal/power pause.
    /// It is deliberately separate from the inter-cycle trailing request: no
    /// timer is allowed to start this work while the app remains backgrounded.
    private var foregroundDeferredRequest: Request?
    private let requiredComponents: Set<Component>
    private let automaticCurrentCycleComponents: Set<Component>

    init(
        requiredComponents: Set<Component> = Self.sessionStoreComponents,
        automaticCurrentCycleComponents: Set<Component> = [
            .currentCycleAndLatestNight,
        ]
    ) {
        self.requiredComponents = requiredComponents
        self.automaticCurrentCycleComponents = automaticCurrentCycleComponents
    }

    /// Registers a newly durable archive revision. Duplicate or regressed
    /// revisions are ignored. While work is active, only the newest request is
    /// retained; the active run is allowed to finish but can no longer publish.
    mutating func request(archiveRevision: UInt64,
                          reason: String,
                          scope: Scope = .full,
                          executionDomain: ExecutionDomain = .foreground,
                          now: Date = Date()) -> [Effect] {
        if executionDomain == .explicitBackground {
            // A BGProcessing caller owns a newly minted exact throttle lease
            // and therefore may report success only when it starts now. Never
            // queue that lease behind, or overwrite, a retained foreground
            // request whose retry must keep its exact cutoff/revision.
            guard foregroundDeferredRequest == nil,
                  trailingRequest == nil,
                  restingUntil.map({ now >= $0 }) ?? true else { return [] }
            switch phase {
            case .idle, .failed:
                break
            case .projecting, .deriving:
                return []
            }
        }
        if let latestRequestedArchiveRevision,
           archiveRevision <= latestRequestedArchiveRevision {
            return []
        }
        latestRequestedArchiveRevision = archiveRevision
        let request = Request(
            archiveRevision: archiveRevision,
            reason: reason,
            scope: scope,
            executionDomain: executionDomain
        )

        if foregroundDeferredRequest != nil {
            if let current = foregroundDeferredRequest,
               request.archiveRevision <= current.archiveRevision {
                return []
            }
            coalescedRequestCount &+= 1
            foregroundDeferredRequest = request
            return []
        }

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
        guard foregroundDeferredRequest == nil else { return [] }
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

    /// Parks a rest-window request behind the next safe foreground edge. The
    /// already-scheduled timer is intentionally left harmless: with the
    /// request moved out of `trailingRequest`, its callback becomes a no-op.
    /// Active work is not retired here; `deferActiveUntilForeground` performs
    /// that exact ticket transition immediately afterward.
    mutating func parkTrailingUntilForeground() {
        guard let trailingRequest else { return }
        if let deferred = foregroundDeferredRequest,
           deferred.archiveRevision >= trailingRequest.archiveRevision {
            self.trailingRequest = nil
            restingUntil = nil
            return
        }
        foregroundDeferredRequest = trailingRequest
        self.trailingRequest = nil
        restingUntil = nil
        if case .failed = phase { phase = .idle }
    }

    /// Synchronously retires the exact active foreground ticket and keeps only
    /// the newest active/trailing revision for one later foreground retry. Both
    /// projecting and deriving phases are valid: the owner decides whether the
    /// transaction is still empty or needs its full rollback image. Moving to
    /// idle before returning rejects every late callback from the old generation.
    mutating func deferActiveUntilForeground(ticket: Ticket) -> [Effect] {
        switch phase {
        case .projecting(let active):
            guard active == ticket else { return [] }
        case .deriving(let active, _):
            guard active == ticket else { return [] }
        case .idle, .failed:
            return []
        }

        let activeRequest = Request(
            archiveRevision: ticket.archiveRevision,
            reason: ticket.reason,
            scope: ticket.scope,
            executionDomain: ticket.executionDomain
        )
        let candidates = [activeRequest, trailingRequest,
                          foregroundDeferredRequest].compactMap { $0 }
        foregroundDeferredRequest = candidates.max {
            $0.archiveRevision < $1.archiveRevision
        }
        trailingRequest = nil
        phase = .idle
        restingUntil = nil
        return [.deferredUntilForeground(ticket)]
    }

    /// Scene-active is the sole authority that consumes the retained lifecycle
    /// request. `start` increments the generation, making the replacement token
    /// and every callback identity strictly newer than the revoked run.
    mutating func startDeferredForegroundRetry() -> [Effect] {
        guard case .idle = phase,
              let request = foregroundDeferredRequest else { return [] }
        foregroundDeferredRequest = nil
        restingUntil = nil
        return start(request)
    }

    /// Retries the last failed durable input without pretending that a new
    /// archive batch arrived. The new ticket rejects late callbacks from the
    /// failed generation.
    mutating func retryFailed(reason: String) -> [Effect] {
        guard case let .failed(ticket, _) = phase else { return [] }
        restingUntil = nil
        return start(Request(archiveRevision: ticket.archiveRevision,
                             reason: reason,
                             scope: ticket.scope,
                             executionDomain: ticket.executionDomain))
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
        let components: Set<Component>
        switch ticket.scope {
        case .full:
            components = requiredComponents
        case .automaticCurrentCycle:
            components = automaticCurrentCycleComponents
        }
        guard !components.isEmpty else {
            phase = .idle
            restingUntil = now.addingTimeInterval(Self.interCycleRestSeconds)
            return [.publish(ticket)]
        }
        phase = .deriving(ticket, pending: components)
        return [.startDerived(ticket, components)]
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

    mutating func cancelActiveForSafeBackground(ticket: Ticket) -> [Effect] {
        switch phase {
        case .projecting(let active):
            guard active == ticket else { return [] }
        case .deriving(let active, _):
            guard active == ticket else { return [] }
        case .idle, .failed:
            return []
        }
        // A lost exact BG lease is not ordinary foreground authority. Do not
        // launder either this ticket or a coalesced automatic request into a
        // foreground scan; the owner retains the durable bootstrap intent and
        // a later BGProcessing lease starts from that checkpoint.
        trailingRequest = nil
        phase = .idle
        restingUntil = nil
        return [.cancelledForSafeBackground(ticket)]
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
            return trailingRequest != nil || foregroundDeferredRequest != nil
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
                            reason: request.reason,
                            scope: request.scope,
                            executionDomain: request.executionDomain)
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
