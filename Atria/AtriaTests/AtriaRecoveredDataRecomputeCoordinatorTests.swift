import XCTest
@testable import Atria

final class AtriaRecoveredDataRecomputeCoordinatorTests: XCTestCase {
    private typealias Coordinator = AtriaRecoveredDataRecomputeCoordinator

    func testPublishesExactlyOnceAfterProjectionAndEveryDerivedCompletion() throws {
        var coordinator = Coordinator()
        let start = coordinator.request(archiveRevision: 10, reason: "history_end")
        let ticket = try startProjectionTicket(start)

        XCTAssertEqual(
            coordinator.projectionCompleted(ticket: ticket),
            [.startDerived(ticket, Coordinator.sessionStoreComponents)]
        )

        let ordered = Coordinator.Component.allCases.filter {
            Coordinator.sessionStoreComponents.contains($0)
        }
        for component in ordered.dropLast() {
            XCTAssertTrue(
                coordinator.componentCompleted(ticket: ticket, component: component).isEmpty
            )
        }
        XCTAssertEqual(
            coordinator.componentCompleted(ticket: ticket, component: try XCTUnwrap(ordered.last)),
            [.publish(ticket)]
        )
        XCTAssertEqual(coordinator.phase, .idle)
        XCTAssertTrue(
            coordinator.componentCompleted(ticket: ticket, component: ordered[0]).isEmpty,
            "a duplicate completion must not produce a second publication"
        )
    }

    func testRecoveredSleepSettlementIsARequiredPublicationComponent() throws {
        XCTAssertTrue(Coordinator.sessionStoreComponents.contains(.sleepSettlement))
        XCTAssertLessThan(
            try XCTUnwrap(Coordinator.Component.allCases.firstIndex(of: .sleepSettlement)),
            try XCTUnwrap(Coordinator.Component.allCases.firstIndex(of: .historySleepAndDailyRollups))
        )
    }

    func testProjectionBurstCoalescesToNewestRevisionWithoutPublishingOldRun() throws {
        var coordinator = Coordinator()
        let first = try startProjectionTicket(
            coordinator.request(archiveRevision: 20, reason: "batch_20")
        )

        XCTAssertTrue(coordinator.request(archiveRevision: 21, reason: "batch_21").isEmpty)
        XCTAssertTrue(coordinator.request(archiveRevision: 22, reason: "batch_22").isEmpty)
        XCTAssertEqual(coordinator.coalescedRequestCount, 1)

        let now = Date(timeIntervalSince1970: 1_785_000_000)
        let effects = coordinator.projectionCompleted(ticket: first, now: now)
        // 2026-08-04 inter-cycle rest: the trailing request no longer starts
        // back-to-back — the coordinator rests, then the scheduled wake
        // starts the newest queued revision.
        XCTAssertEqual(effects, [
            .superseded(first),
            .scheduleTrailingStart(afterSeconds: Coordinator.interCycleRestSeconds),
        ])
        XCTAssertTrue(coordinator.startPendingTrailing(now: now).isEmpty,
                      "the wake must not fire before the rest elapses")
        let newest = try startProjectionTicket(coordinator.startPendingTrailing(
            now: now.addingTimeInterval(Coordinator.interCycleRestSeconds)))
        XCTAssertEqual(newest.archiveRevision, 22)
        XCTAssertEqual(newest.reason, "batch_22")
        XCTAssertGreaterThan(newest.generation, first.generation)
    }

    func testNewRevisionDuringDerivedWorkSuppressesPartialPublish() throws {
        let components: Set<Coordinator.Component> = [.overviewTrends, .trainingLoad]
        var coordinator = Coordinator(requiredComponents: components)
        let first = try startProjectionTicket(
            coordinator.request(archiveRevision: 30, reason: "batch_30")
        )
        XCTAssertEqual(coordinator.projectionCompleted(ticket: first),
                       [.startDerived(first, components)])
        XCTAssertTrue(coordinator.request(archiveRevision: 31, reason: "batch_31").isEmpty)
        XCTAssertTrue(coordinator.componentCompleted(ticket: first,
                                                     component: .overviewTrends).isEmpty)

        let now = Date(timeIntervalSince1970: 1_785_000_000)
        let effects = coordinator.componentCompleted(ticket: first,
                                                     component: .trainingLoad,
                                                     now: now)
        XCTAssertEqual(effects, [
            .superseded(first),
            .scheduleTrailingStart(afterSeconds: Coordinator.interCycleRestSeconds),
        ])
        XCTAssertFalse(effects.contains(.publish(first)))
        XCTAssertEqual(try startProjectionTicket(coordinator.startPendingTrailing(
            now: now.addingTimeInterval(Coordinator.interCycleRestSeconds)
        )).archiveRevision, 31)
    }

    func testStaleProjectionAndComponentCallbacksAreRejected() throws {
        let components: Set<Coordinator.Component> = [.trainingLoad]
        var coordinator = Coordinator(requiredComponents: components)
        let first = try startProjectionTicket(
            coordinator.request(archiveRevision: 40, reason: "first")
        )
        XCTAssertTrue(coordinator.request(archiveRevision: 41, reason: "second").isEmpty)
        let now = Date(timeIntervalSince1970: 1_785_000_000)
        _ = coordinator.projectionCompleted(ticket: first, now: now)
        let second = try startProjectionTicket(coordinator.startPendingTrailing(
            now: now.addingTimeInterval(Coordinator.interCycleRestSeconds)))

        XCTAssertTrue(coordinator.projectionCompleted(ticket: first).isEmpty)
        XCTAssertEqual(coordinator.projectionCompleted(ticket: second),
                       [.startDerived(second, components)])
        XCTAssertTrue(coordinator.componentCompleted(ticket: first,
                                                     component: .trainingLoad).isEmpty)
        XCTAssertEqual(coordinator.componentCompleted(ticket: second,
                                                      component: .trainingLoad),
                       [.publish(second)])
    }

    func testDerivedFailureFailsClosedAndRejectsLateSuccess() throws {
        let components: Set<Coordinator.Component> = [.overviewTrends, .trainingLoad]
        var coordinator = Coordinator(requiredComponents: components)
        let ticket = try startProjectionTicket(
            coordinator.request(archiveRevision: 50, reason: "batch")
        )
        _ = coordinator.projectionCompleted(ticket: ticket)

        let failure = Coordinator.Failure(component: .trainingLoad,
                                          reason: "revision_superseded")
        XCTAssertEqual(coordinator.componentCompleted(ticket: ticket,
                                                      component: .trainingLoad,
                                                      failureReason: failure.reason),
                       [.failed(ticket, failure)])
        XCTAssertEqual(coordinator.phase, .failed(ticket, failure))
        XCTAssertTrue(coordinator.componentCompleted(ticket: ticket,
                                                     component: .overviewTrends).isEmpty)
    }

    func testTimeoutFailsClosedAndStartsNewestQueuedInputAfterRest() throws {
        var coordinator = Coordinator()
        let first = try startProjectionTicket(
            coordinator.request(archiveRevision: 60, reason: "first")
        )
        XCTAssertTrue(coordinator.request(archiveRevision: 61, reason: "trailing").isEmpty)

        let effects = coordinator.timedOut(ticket: first)
        XCTAssertEqual(effects, [
            .failed(first, .init(component: nil, reason: "timed_out")),
            .scheduleTrailingStart(afterSeconds: Coordinator.interCycleRestSeconds),
        ])
        let second = try startProjectionTicket(coordinator.startPendingTrailing(
            now: Date().addingTimeInterval(Coordinator.interCycleRestSeconds + 1)))
        XCTAssertEqual(second.archiveRevision, 61)
        XCTAssertTrue(coordinator.projectionCompleted(ticket: first).isEmpty)
    }

    func testRequestDuringPostPublishRestQueuesAndReArmsWake() throws {
        let components: Set<Coordinator.Component> = [.trainingLoad]
        var coordinator = Coordinator(requiredComponents: components)
        let now = Date(timeIntervalSince1970: 1_785_000_000)
        let ticket = try startProjectionTicket(
            coordinator.request(archiveRevision: 70, reason: "first", now: now)
        )
        _ = coordinator.projectionCompleted(ticket: ticket, now: now)
        XCTAssertEqual(coordinator.componentCompleted(ticket: ticket,
                                                      component: .trainingLoad,
                                                      now: now),
                       [.publish(ticket)])

        // A fresh drain revision one second after publish must WAIT out the
        // rest, not start a back-to-back cycle.
        let during = coordinator.request(archiveRevision: 71,
                                         reason: "drain_chunk",
                                         now: now.addingTimeInterval(1))
        XCTAssertEqual(during, [.scheduleTrailingStart(
            afterSeconds: Coordinator.interCycleRestSeconds - 1)])
        XCTAssertTrue(coordinator.startPendingTrailing(
            now: now.addingTimeInterval(2)).isEmpty)
        let next = try startProjectionTicket(coordinator.startPendingTrailing(
            now: now.addingTimeInterval(Coordinator.interCycleRestSeconds)))
        XCTAssertEqual(next.archiveRevision, 71)
    }

    func testWakeWithNothingQueuedOrWhileBusyIsANoOp() throws {
        var coordinator = Coordinator()
        XCTAssertTrue(coordinator.startPendingTrailing().isEmpty)
        _ = try startProjectionTicket(
            coordinator.request(archiveRevision: 80, reason: "first")
        )
        XCTAssertTrue(coordinator.startPendingTrailing(
            now: Date().addingTimeInterval(60)).isEmpty,
            "a wake during an active cycle must not double-start")
    }

    func testDerivedProgressExposesRemainingComponentsAndAttributesTimeout() throws {
        let components: Set<Coordinator.Component> = [.confirmedWorkouts, .sleepSettlement]
        var coordinator = Coordinator(requiredComponents: components)
        let ticket = try startProjectionTicket(
            coordinator.request(archiveRevision: 62, reason: "progress")
        )
        _ = coordinator.projectionCompleted(ticket: ticket)
        XCTAssertEqual(coordinator.pendingComponents(ticket: ticket), components)

        XCTAssertTrue(coordinator.componentCompleted(ticket: ticket,
                                                     component: .confirmedWorkouts).isEmpty)
        XCTAssertEqual(coordinator.pendingComponents(ticket: ticket), [.sleepSettlement])
        XCTAssertEqual(coordinator.timedOut(ticket: ticket,
                                            component: .sleepSettlement),
                       [.failed(ticket,
                                .init(component: .sleepSettlement,
                                      reason: "timed_out"))])
    }

    func testFailedRevisionCanBeRetriedWithNewGeneration() throws {
        var coordinator = Coordinator()
        let first = try startProjectionTicket(
            coordinator.request(archiveRevision: 70, reason: "first")
        )
        _ = coordinator.projectionCompleted(ticket: first, failureReason: "archive_read_failed")

        let retry = try startProjectionTicket(coordinator.retryFailed(reason: "manual_retry"))
        XCTAssertEqual(retry.archiveRevision, first.archiveRevision)
        XCTAssertEqual(retry.reason, "manual_retry")
        XCTAssertGreaterThan(retry.generation, first.generation)
    }

    func testDuplicateAndRegressedArchiveRevisionsAreIgnored() throws {
        var coordinator = Coordinator()
        _ = try startProjectionTicket(
            coordinator.request(archiveRevision: 80, reason: "new")
        )
        XCTAssertTrue(coordinator.request(archiveRevision: 80, reason: "duplicate").isEmpty)
        XCTAssertTrue(coordinator.request(archiveRevision: 79, reason: "regressed").isEmpty)
        XCTAssertEqual(coordinator.latestRequestedArchiveRevision, 80)
    }

    func testEmptyDerivedSetPublishesOnlyAfterProjection() throws {
        var coordinator = Coordinator(requiredComponents: [])
        let ticket = try startProjectionTicket(
            coordinator.request(archiveRevision: 90, reason: "projection_only")
        )
        XCTAssertEqual(coordinator.projectionCompleted(ticket: ticket), [.publish(ticket)])
    }

    func testProjectingTicketDefersAndResumesExactlyOnceWithCapturedScope()
        throws {
        var coordinator = Coordinator()
        let cutoff = Date(timeIntervalSince1970: 1_786_420_800)
        let first = try startProjectionTicket(coordinator.request(
            archiveRevision: 100,
            reason: "archive_did_update",
            scope: .automaticCurrentCycle(since: cutoff)
        ))

        XCTAssertEqual(
            coordinator.deferActiveUntilForeground(ticket: first),
            [.deferredUntilForeground(first)]
        )
        XCTAssertEqual(coordinator.phase, .idle)
        XCTAssertTrue(coordinator.startPendingTrailing().isEmpty)

        let retry = try startProjectionTicket(
            coordinator.startDeferredForegroundRetry()
        )
        XCTAssertEqual(retry.archiveRevision, first.archiveRevision)
        XCTAssertEqual(retry.scope, .automaticCurrentCycle(since: cutoff))
        XCTAssertGreaterThan(retry.generation, first.generation)
        XCTAssertTrue(
            coordinator.startDeferredForegroundRetry().isEmpty,
            "one scene-active edge may consume the retained request once"
        )
    }

    func testUnsafeEdgeParksQueuedInterCycleRequestAndTimerCannotStartIt()
        throws {
        var coordinator = Coordinator(requiredComponents: [])
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cutoff = now.addingTimeInterval(-43_200)
        let first = try startProjectionTicket(coordinator.request(
            archiveRevision: 101,
            reason: "first",
            scope: .automaticCurrentCycle(since: cutoff),
            now: now
        ))
        XCTAssertTrue(coordinator.request(
            archiveRevision: 102,
            reason: "newest_durable_frontier",
            scope: .automaticCurrentCycle(
                since: cutoff.addingTimeInterval(3_600)
            ),
            now: now
        ).isEmpty)
        XCTAssertEqual(
            coordinator.projectionCompleted(ticket: first, now: now),
            [
                .superseded(first),
                .scheduleTrailingStart(
                    afterSeconds: Coordinator.interCycleRestSeconds
                ),
            ]
        )

        coordinator.parkTrailingUntilForeground()
        XCTAssertTrue(
            coordinator.startPendingTrailing(
                now: now.addingTimeInterval(10_000)
            ).isEmpty,
            "the already-queued timer must be harmless while unsafe"
        )
        let retry = try startProjectionTicket(
            coordinator.startDeferredForegroundRetry()
        )
        XCTAssertEqual(retry.archiveRevision, 102)
        XCTAssertEqual(
            retry.scope,
            .automaticCurrentCycle(
                since: cutoff.addingTimeInterval(3_600)
            )
        )
        XCTAssertGreaterThan(retry.generation, first.generation)
        XCTAssertTrue(coordinator.startDeferredForegroundRetry().isEmpty)
    }

    func testDerivingTicketDefersWithoutPublishingAndRejectsOldCallbacks()
        throws {
        let components: Set<Coordinator.Component> = [.overviewTrends]
        var coordinator = Coordinator(requiredComponents: components)
        let first = try startProjectionTicket(coordinator.request(
            archiveRevision: 110,
            reason: "exact"
        ))
        XCTAssertEqual(
            coordinator.projectionCompleted(ticket: first),
            [.startDerived(first, components)]
        )
        XCTAssertEqual(
            coordinator.deferActiveUntilForeground(ticket: first),
            [.deferredUntilForeground(first)]
        )
        XCTAssertTrue(coordinator.componentCompleted(
            ticket: first,
            component: .overviewTrends
        ).isEmpty)
        XCTAssertTrue(coordinator.projectionCompleted(ticket: first).isEmpty)

        let retry = try startProjectionTicket(
            coordinator.startDeferredForegroundRetry()
        )
        XCTAssertGreaterThan(retry.generation, first.generation)
        XCTAssertEqual(retry.archiveRevision, first.archiveRevision)
    }

    func testNewestDurableRevisionWinsWhileForegroundRetryIsDeferred()
        throws {
        var coordinator = Coordinator()
        let oldCutoff = Date(timeIntervalSince1970: 1_786_400_000)
        let first = try startProjectionTicket(coordinator.request(
            archiveRevision: 120,
            reason: "old",
            scope: .automaticCurrentCycle(since: oldCutoff)
        ))
        XCTAssertTrue(coordinator.request(
            archiveRevision: 121,
            reason: "middle",
            scope: .automaticCurrentCycle(
                since: oldCutoff.addingTimeInterval(600)
            )
        ).isEmpty)
        _ = coordinator.deferActiveUntilForeground(ticket: first)

        let newestCutoff = oldCutoff.addingTimeInterval(3_600)
        XCTAssertTrue(coordinator.request(
            archiveRevision: 122,
            reason: "frontier_after_second_wake_tail",
            scope: .automaticCurrentCycle(since: newestCutoff)
        ).isEmpty)
        let retry = try startProjectionTicket(
            coordinator.startDeferredForegroundRetry()
        )
        XCTAssertEqual(retry.archiveRevision, 122)
        XCTAssertEqual(
            retry.scope,
            .automaticCurrentCycle(since: newestCutoff)
        )
        XCTAssertGreaterThan(retry.generation, first.generation)
    }

    func testEndedBackgroundTicketCancelsWithoutForegroundRetry() throws {
        var coordinator = Coordinator()
        let ticket = try startProjectionTicket(coordinator.request(
            archiveRevision: 130,
            reason: "bg_projection_current_window_bootstrap_test",
            scope: .automaticCurrentCycle(
                since: Date(timeIntervalSince1970: 1_786_420_800)
            ),
            executionDomain: .explicitBackground
        ))
        XCTAssertEqual(
            coordinator.cancelActiveForSafeBackground(ticket: ticket),
            [.cancelledForSafeBackground(ticket)]
        )
        XCTAssertEqual(coordinator.phase, .idle)
        XCTAssertTrue(coordinator.startDeferredForegroundRetry().isEmpty)
        XCTAssertTrue(coordinator.projectionCompleted(ticket: ticket).isEmpty)
    }

    func testExplicitBackgroundRequestCannotOverwriteDeferredForegroundRetry()
        throws {
        var coordinator = Coordinator()
        let cutoff = Date(timeIntervalSince1970: 1_786_420_800)
        let foreground = try startProjectionTicket(coordinator.request(
            archiveRevision: 140,
            reason: "archive_did_update",
            scope: .automaticCurrentCycle(since: cutoff)
        ))
        _ = coordinator.deferActiveUntilForeground(ticket: foreground)

        let rejectedBackground = coordinator.request(
            archiveRevision: 141,
            reason: "bg_projection_current_window_bootstrap_race",
            scope: .automaticCurrentCycle(
                since: cutoff.addingTimeInterval(3_600)
            ),
            executionDomain: .explicitBackground
        )
        XCTAssertTrue(rejectedBackground.isEmpty)
        XCTAssertEqual(coordinator.latestRequestedArchiveRevision, 140)

        let retry = try startProjectionTicket(
            coordinator.startDeferredForegroundRetry()
        )
        XCTAssertEqual(retry.archiveRevision, foreground.archiveRevision)
        XCTAssertEqual(retry.scope, foreground.scope)
        XCTAssertEqual(retry.executionDomain, .foreground)
        XCTAssertGreaterThan(retry.generation, foreground.generation)
        XCTAssertTrue(coordinator.startDeferredForegroundRetry().isEmpty)
    }

    func testSessionStoreReportsExplicitBackgroundStartOnlyForActualStartEffect()
        throws {
        XCTAssertFalse(SessionStore.explicitBackgroundProjectionDidStart([]))
        var coordinator = Coordinator()
        let effects = coordinator.request(
            archiveRevision: 150,
            reason: "bg_projection_current_window_bootstrap",
            scope: .automaticCurrentCycle(
                since: Date(timeIntervalSince1970: 1_786_420_800)
            ),
            executionDomain: .explicitBackground
        )
        let ticket = try startProjectionTicket(effects)
        XCTAssertEqual(ticket.executionDomain, .explicitBackground)
        XCTAssertTrue(SessionStore.explicitBackgroundProjectionDidStart(effects))
        XCTAssertFalse(SessionStore.explicitBackgroundProjectionDidStart(
            [.deferredUntilForeground(ticket)]
        ))
    }

    func testThermalAndLowPowerOverlapResumesDeferredTicketExactlyOnce()
        throws {
        XCTAssertEqual(
            SessionStore.recoveredExecutionEnvironmentAction(
                applicationIsActive: true,
                thermalState: .serious,
                isLowPowerModeEnabled: false
            ),
            .suspend
        )
        XCTAssertEqual(
            SessionStore.recoveredExecutionEnvironmentAction(
                applicationIsActive: true,
                thermalState: .nominal,
                isLowPowerModeEnabled: true
            ),
            .suspend
        )
        XCTAssertEqual(
            SessionStore.recoveredExecutionEnvironmentAction(
                applicationIsActive: true,
                thermalState: .nominal,
                isLowPowerModeEnabled: false
            ),
            .resume
        )

        var coordinator = Coordinator(requiredComponents: [])
        let old = try startProjectionTicket(coordinator.request(
            archiveRevision: 160,
            reason: "environment_overlap"
        ))
        XCTAssertEqual(
            coordinator.deferActiveUntilForeground(ticket: old),
            [.deferredUntilForeground(old)]
        )
        // A nominal thermal notification while LPM remains enabled must not
        // consume the retained retry.
        XCTAssertTrue(coordinator.startPendingTrailing().isEmpty)

        let fresh = try startProjectionTicket(
            coordinator.startDeferredForegroundRetry()
        )
        XCTAssertGreaterThan(fresh.generation, old.generation)
        XCTAssertTrue(coordinator.startDeferredForegroundRetry().isEmpty)
        XCTAssertTrue(coordinator.projectionCompleted(ticket: old).isEmpty)
        XCTAssertEqual(
            coordinator.projectionCompleted(ticket: fresh),
            [.publish(fresh)]
        )
        XCTAssertTrue(coordinator.projectionCompleted(ticket: fresh).isEmpty)
    }

    func testEnvironmentRecoveryWhileInactiveDoesNotStartRetry() {
        XCTAssertEqual(
            SessionStore.recoveredExecutionEnvironmentAction(
                applicationIsActive: false,
                thermalState: .nominal,
                isLowPowerModeEnabled: false
            ),
            .none
        )
    }

    private func startProjectionTicket(
        _ effects: [Coordinator.Effect],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Coordinator.Ticket {
        guard effects.count == 1,
              case let .startProjection(ticket) = effects[0] else {
            XCTFail("expected exactly one startProjection effect, got \(effects)",
                    file: file,
                    line: line)
            throw TestError.missingTicket
        }
        return ticket
    }

    private enum TestError: Error {
        case missingTicket
    }
}
