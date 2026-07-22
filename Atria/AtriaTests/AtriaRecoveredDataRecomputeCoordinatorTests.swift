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

        let ordered = Coordinator.Component.allCases
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

        let effects = coordinator.projectionCompleted(ticket: first)
        XCTAssertEqual(effects.first, .superseded(first))
        let newest = try startProjectionTicket(Array(effects.dropFirst()))
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

        let effects = coordinator.componentCompleted(ticket: first,
                                                     component: .trainingLoad)
        XCTAssertEqual(effects.first, .superseded(first))
        XCTAssertEqual(try startProjectionTicket(Array(effects.dropFirst())).archiveRevision, 31)
        XCTAssertFalse(effects.contains(.publish(first)))
    }

    func testStaleProjectionAndComponentCallbacksAreRejected() throws {
        let components: Set<Coordinator.Component> = [.trainingLoad]
        var coordinator = Coordinator(requiredComponents: components)
        let first = try startProjectionTicket(
            coordinator.request(archiveRevision: 40, reason: "first")
        )
        XCTAssertTrue(coordinator.request(archiveRevision: 41, reason: "second").isEmpty)
        let replacementEffects = coordinator.projectionCompleted(ticket: first)
        let second = try startProjectionTicket(Array(replacementEffects.dropFirst()))

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

    func testTimeoutFailsClosedButImmediatelyStartsNewestQueuedInput() throws {
        var coordinator = Coordinator()
        let first = try startProjectionTicket(
            coordinator.request(archiveRevision: 60, reason: "first")
        )
        XCTAssertTrue(coordinator.request(archiveRevision: 61, reason: "trailing").isEmpty)

        let effects = coordinator.timedOut(ticket: first)
        XCTAssertEqual(effects.first,
                       .failed(first, .init(component: nil, reason: "timed_out")))
        let second = try startProjectionTicket(Array(effects.dropFirst()))
        XCTAssertEqual(second.archiveRevision, 61)
        XCTAssertTrue(coordinator.projectionCompleted(ticket: first).isEmpty)
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
