import XCTest
@testable import Atria

final class AtriaWhoop4MotionBankCoverageLedgerTests: XCTestCase {
    func testRestoresClearedTicketOnlyInsideDurablyClosedBank() throws {
        let strap = "strap-a"
        let bankStart = Date(timeIntervalSince1970: 1_000)
        let bankEnd = Date(timeIntervalSince1970: 1_200)
        AtriaWhoop4MotionBankCoverageLedger.open(
            at: bankStart,
            strapIdentifier: strap,
            defaults: defaults
        )
        AtriaWhoop4MotionBankCoverageLedger.close(
            at: bankEnd,
            strapIdentifier: strap,
            defaults: defaults
        )
        let original = try XCTUnwrap(
            AtriaWhoop4MotionBankCoverageLedger.nextPendingOffload(
                strapIdentifier: strap,
                defaults: defaults
            )
        )
        AtriaWhoop4MotionBankCoverageLedger.resolveOffload(
            id: original.id,
            defaults: defaults
        )

        XCTAssertNotNil(
            AtriaWhoop4MotionBankCoverageLedger.restorePendingOffloadIfCovered(
                start: Date(timeIntervalSince1970: 1_020),
                end: Date(timeIntervalSince1970: 1_180),
                strapIdentifier: strap,
                defaults: defaults
            )
        )
        XCTAssertNil(
            AtriaWhoop4MotionBankCoverageLedger.restorePendingOffloadIfCovered(
                start: Date(timeIntervalSince1970: 900),
                end: Date(timeIntervalSince1970: 1_180),
                strapIdentifier: strap,
                defaults: defaults
            )
        )
    }

    private var defaults: UserDefaults!
    private let strap = "TEST-STRAP-A"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(
            suiteName: "AtriaWhoop4MotionBankCoverageLedgerTests.\(UUID().uuidString)"
        )
        AtriaWhoop4MotionBankCoverageLedger.reset(defaults: defaults)
    }

    override func tearDown() {
        AtriaWhoop4MotionBankCoverageLedger.reset(defaults: defaults)
        defaults = nil
        super.tearDown()
    }

    func testRepeatedOpenPreservesEarliestPhysicalBoundary() {
        let start = Date(timeIntervalSince1970: 1_000)
        AtriaWhoop4MotionBankCoverageLedger.open(
            at: start,
            strapIdentifier: strap,
            defaults: defaults
        )
        AtriaWhoop4MotionBankCoverageLedger.open(
            at: start.addingTimeInterval(30),
            strapIdentifier: strap,
            defaults: defaults
        )

        XCTAssertEqual(
            AtriaWhoop4MotionBankCoverageLedger.intervals(
                intersecting: .init(
                    start: start.addingTimeInterval(-10),
                    end: start.addingTimeInterval(60)
                ),
                strapIdentifier: strap,
                now: start.addingTimeInterval(60),
                defaults: defaults
            ),
            [.init(start: start, end: start.addingTimeInterval(60))]
        )
    }

    func testProjectionAuthorityIgnoresWallClockButChangesForCoverageFacts() throws {
        let start = Date(timeIntervalSince1970: 1_500)
        AtriaWhoop4MotionBankCoverageLedger.open(
            at: start,
            strapIdentifier: strap,
            defaults: defaults
        )
        let first = try XCTUnwrap(
            AtriaWhoop4MotionBankCoverageLedger.projectionAuthority(
                intersecting: .init(
                    start: start.addingTimeInterval(-30),
                    end: start.addingTimeInterval(120)
                ),
                strapIdentifier: strap,
                defaults: defaults
            )
        )
        let laterWallClockWindow = try XCTUnwrap(
            AtriaWhoop4MotionBankCoverageLedger.projectionAuthority(
                intersecting: .init(
                    start: start.addingTimeInterval(-30),
                    end: start.addingTimeInterval(600)
                ),
                strapIdentifier: strap,
                defaults: defaults
            )
        )
        XCTAssertEqual(first.stableIdentifier, laterWallClockWindow.stableIdentifier)

        AtriaWhoop4MotionBankCoverageLedger.close(
            at: start.addingTimeInterval(60),
            strapIdentifier: strap,
            defaults: defaults
        )
        let closed = try XCTUnwrap(
            AtriaWhoop4MotionBankCoverageLedger.projectionAuthority(
                intersecting: .init(
                    start: start.addingTimeInterval(-30),
                    end: start.addingTimeInterval(600)
                ),
                strapIdentifier: strap,
                defaults: defaults
            )
        )
        XCTAssertNotEqual(first.stableIdentifier, closed.stableIdentifier)
    }

    func testClosedAndReopenedCoverageDoesNotFillRealGap() {
        let start = Date(timeIntervalSince1970: 2_000)
        AtriaWhoop4MotionBankCoverageLedger.open(
            at: start,
            strapIdentifier: strap,
            defaults: defaults
        )
        AtriaWhoop4MotionBankCoverageLedger.close(
            at: start.addingTimeInterval(60),
            strapIdentifier: strap,
            defaults: defaults
        )
        AtriaWhoop4MotionBankCoverageLedger.open(
            at: start.addingTimeInterval(90),
            strapIdentifier: strap,
            defaults: defaults
        )

        XCTAssertEqual(
            AtriaWhoop4MotionBankCoverageLedger.intervals(
                intersecting: .init(
                    start: start,
                    end: start.addingTimeInterval(150)
                ),
                strapIdentifier: strap,
                now: start.addingTimeInterval(150),
                defaults: defaults
            ),
            [
                .init(start: start, end: start.addingTimeInterval(60)),
                .init(
                    start: start.addingTimeInterval(90),
                    end: start.addingTimeInterval(150)
                ),
            ]
        )
    }

    func testRepairsPersistedBankThatCrossedPhysicalConnectionEpoch() throws {
        let staleStart = Date(timeIntervalSince1970: 2_500)
        let currentEpoch = staleStart.addingTimeInterval(300)
        let end = currentEpoch.addingTimeInterval(90)
        AtriaWhoop4MotionBankCoverageLedger.open(
            at: staleStart,
            strapIdentifier: strap,
            defaults: defaults
        )
        AtriaWhoop4MotionBankCoverageLedger.close(
            at: end,
            strapIdentifier: strap,
            armedConnectionStartedAt: currentEpoch,
            defaults: defaults
        )
        let stale = try XCTUnwrap(
            AtriaWhoop4MotionBankCoverageLedger.nextPendingOffload(
                strapIdentifier: strap,
                defaults: defaults
            )
        )
        _ = AtriaWhoop4MotionBankCoverageLedger.markOffloadAttempt(
            id: stale.id,
            at: end.addingTimeInterval(1),
            defaults: defaults
        )

        XCTAssertEqual(
            AtriaWhoop4MotionBankCoverageLedger
                .repairCrossConnectionCoverage(defaults: defaults),
            1
        )

        let repaired = try XCTUnwrap(
            AtriaWhoop4MotionBankCoverageLedger.nextPendingOffload(
                strapIdentifier: strap,
                defaults: defaults
            )
        )
        XCTAssertEqual(repaired.start, currentEpoch)
        XCTAssertEqual(repaired.end, end)
        XCTAssertEqual(repaired.armedConnectionStartedAt, currentEpoch)
        XCTAssertEqual(repaired.attempts, 0)
        XCTAssertEqual(
            AtriaWhoop4MotionBankCoverageLedger.intervals(
                intersecting: .init(start: staleStart, end: end),
                strapIdentifier: strap,
                now: end,
                defaults: defaults
            ),
            [.init(start: currentEpoch, end: end)]
        )
        XCTAssertEqual(
            AtriaWhoop4MotionBankCoverageLedger
                .repairCrossConnectionCoverage(defaults: defaults),
            0
        )
    }

    func testDropsCrossConnectionTicketWithNoProvableEpoch() {
        let staleStart = Date(timeIntervalSince1970: 2_900)
        let end = staleStart.addingTimeInterval(60)
        AtriaWhoop4MotionBankCoverageLedger.open(
            at: staleStart,
            strapIdentifier: strap,
            defaults: defaults
        )
        AtriaWhoop4MotionBankCoverageLedger.close(
            at: end,
            strapIdentifier: strap,
            armedConnectionStartedAt: end,
            defaults: defaults
        )

        XCTAssertEqual(
            AtriaWhoop4MotionBankCoverageLedger
                .repairCrossConnectionCoverage(defaults: defaults),
            1
        )
        XCTAssertNil(
            AtriaWhoop4MotionBankCoverageLedger.nextPendingOffload(
                strapIdentifier: strap,
                defaults: defaults
            )
        )
        XCTAssertTrue(
            AtriaWhoop4MotionBankCoverageLedger.intervals(
                intersecting: .init(start: staleStart, end: end),
                strapIdentifier: strap,
                now: end,
                defaults: defaults
            ).isEmpty
        )
    }

    func testRetiresOrphanedProcessBankAtLastDurableObservation() throws {
        let start = Date(timeIntervalSince1970: 3_100)
        let lastObserved = start.addingTimeInterval(75)
        AtriaWhoop4MotionBankCoverageLedger.open(
            at: start,
            strapIdentifier: strap,
            defaults: defaults
        )

        XCTAssertTrue(
            AtriaWhoop4MotionBankCoverageLedger
                .retireOrphanedOpenCoverage(
                    lastObservedAt: lastObserved,
                    strapIdentifier: strap,
                    defaults: defaults
                )
        )

        let ticket = try XCTUnwrap(
            AtriaWhoop4MotionBankCoverageLedger.nextPendingOffload(
                strapIdentifier: strap,
                defaults: defaults
            )
        )
        XCTAssertEqual(ticket.start, start)
        XCTAssertEqual(ticket.end, lastObserved)
        XCTAssertEqual(ticket.armedConnectionStartedAt, start)
        XCTAssertEqual(
            AtriaWhoop4MotionBankCoverageLedger.intervals(
                intersecting: .init(
                    start: start,
                    end: lastObserved.addingTimeInterval(60)
                ),
                strapIdentifier: strap,
                now: lastObserved.addingTimeInterval(60),
                defaults: defaults
            ),
            [.init(start: start, end: lastObserved)]
        )
    }

    func testOrphanedProcessBankDoesNotInventUnobservedTail() {
        let start = Date(timeIntervalSince1970: 3_300)
        AtriaWhoop4MotionBankCoverageLedger.open(
            at: start,
            strapIdentifier: strap,
            defaults: defaults
        )

        XCTAssertTrue(
            AtriaWhoop4MotionBankCoverageLedger
                .retireOrphanedOpenCoverage(
                    lastObservedAt: start.addingTimeInterval(-1),
                    strapIdentifier: strap,
                    defaults: defaults
                )
        )
        XCTAssertNil(
            AtriaWhoop4MotionBankCoverageLedger.nextPendingOffload(
                strapIdentifier: strap,
                defaults: defaults
            )
        )
        XCTAssertTrue(
            AtriaWhoop4MotionBankCoverageLedger.intervals(
                intersecting: .init(
                    start: start,
                    end: start.addingTimeInterval(60)
                ),
                strapIdentifier: strap,
                now: start.addingTimeInterval(60),
                defaults: defaults
            ).isEmpty
        )
    }

    func testDifferentStrapCannotReadOrExtendExistingCoverage() {
        let start = Date(timeIntervalSince1970: 3_000)
        AtriaWhoop4MotionBankCoverageLedger.open(
            at: start,
            strapIdentifier: strap,
            defaults: defaults
        )

        XCTAssertTrue(
            AtriaWhoop4MotionBankCoverageLedger.intervals(
                intersecting: .init(start: start,
                                    end: start.addingTimeInterval(60)),
                strapIdentifier: "TEST-STRAP-B",
                now: start.addingTimeInterval(60),
                defaults: defaults
            ).isEmpty
        )
    }

    func testArmedStateIsScopedToOnePhysicalConnectionEpoch() {
        let epoch = Date(timeIntervalSince1970: 4_000)
        XCTAssertTrue(
            AtriaBLEManager.historicalMotionBankIsArmedForCurrentConnection(
                armed: true,
                armedConnectionStartedAt: epoch,
                currentConnectionStartedAt: epoch
            )
        )
        XCTAssertFalse(
            AtriaBLEManager.historicalMotionBankIsArmedForCurrentConnection(
                armed: true,
                armedConnectionStartedAt: epoch,
                currentConnectionStartedAt: epoch.addingTimeInterval(1)
            )
        )
        XCTAssertFalse(
            AtriaBLEManager.historicalMotionBankIsArmedForCurrentConnection(
                armed: false,
                armedConnectionStartedAt: epoch,
                currentConnectionStartedAt: epoch
            )
        )
    }

    func testWorkoutBoundaryPreservesEarlierAllDayBankInOffloadTicket() {
        let bankStart = Date(timeIntervalSince1970: 5_000)
        let workoutStart = bankStart.addingTimeInterval(30)
        let end = workoutStart.addingTimeInterval(90)
        let epoch = bankStart.addingTimeInterval(-5)
        AtriaWhoop4MotionBankCoverageLedger.open(
            at: bankStart,
            strapIdentifier: strap,
            defaults: defaults
        )
        AtriaWhoop4MotionBankCoverageLedger.close(
            at: end,
            strapIdentifier: strap,
            armedConnectionStartedAt: epoch,
            defaults: defaults
        )

        let ticket = AtriaWhoop4MotionBankCoverageLedger.nextPendingOffload(
            strapIdentifier: strap,
            defaults: defaults
        )
        XCTAssertEqual(
            ticket?.start,
            bankStart,
            "a later workout may close the all-day bank but must not erase its autonomous prefix"
        )
        XCTAssertEqual(ticket?.end, end)
        XCTAssertEqual(ticket?.armedConnectionStartedAt, epoch)
        XCTAssertEqual(ticket?.attempts, 0)

        let attempted = AtriaWhoop4MotionBankCoverageLedger.markOffloadAttempt(
            id: try! XCTUnwrap(ticket?.id),
            at: end.addingTimeInterval(1),
            defaults: defaults
        )
        XCTAssertEqual(attempted?.attempts, 1)

        AtriaWhoop4MotionBankCoverageLedger.resolveOffload(
            id: try! XCTUnwrap(ticket?.id),
            defaults: defaults
        )
        XCTAssertNil(
            AtriaWhoop4MotionBankCoverageLedger.nextPendingOffload(
                strapIdentifier: strap,
                defaults: defaults
            )
        )
    }

    func testRepairsLegacyWorkoutSuffixTicketToFullClosedBank() throws {
        let bankStart = Date(timeIntervalSince1970: 8_000)
        let workoutStart = bankStart.addingTimeInterval(600)
        let end = workoutStart.addingTimeInterval(90)
        AtriaWhoop4MotionBankCoverageLedger.open(
            at: bankStart,
            strapIdentifier: strap,
            defaults: defaults
        )
        // Reproduce the legacy suffix ticket using a closed full interval and
        // a manually restored subrange ticket.
        AtriaWhoop4MotionBankCoverageLedger.close(
            at: end,
            strapIdentifier: strap,
            defaults: defaults
        )
        let full = try XCTUnwrap(
            AtriaWhoop4MotionBankCoverageLedger.nextPendingOffload(
                strapIdentifier: strap,
                defaults: defaults
            )
        )
        AtriaWhoop4MotionBankCoverageLedger.resolveOffload(
            id: full.id,
            defaults: defaults
        )
        let suffix = try XCTUnwrap(
            AtriaWhoop4MotionBankCoverageLedger
                .restorePendingOffloadIfCovered(
                    start: workoutStart,
                    end: end,
                    strapIdentifier: strap,
                    defaults: defaults
                )
        )
        XCTAssertEqual(suffix.start, workoutStart)

        XCTAssertEqual(
            AtriaWhoop4MotionBankCoverageLedger
                .repairWorkoutTruncatedOffloadCoverage(defaults: defaults),
            1
        )
        let repaired = try XCTUnwrap(
            AtriaWhoop4MotionBankCoverageLedger.nextPendingOffload(
                strapIdentifier: strap,
                defaults: defaults
            )
        )
        XCTAssertEqual(repaired.start, bankStart)
        XCTAssertEqual(repaired.end, end)
        XCTAssertEqual(repaired.attempts, 0)
        XCTAssertEqual(
            AtriaWhoop4MotionBankCoverageLedger
                .repairWorkoutTruncatedOffloadCoverage(defaults: defaults),
            0,
            "repair must be idempotent"
        )
    }

    func testResolvedOffloadPublishesDailyReceiptRefreshBoundary() throws {
        let start = Date(timeIntervalSince1970: 5_250)
        let end = start.addingTimeInterval(90)
        AtriaWhoop4MotionBankCoverageLedger.open(
            at: start,
            strapIdentifier: strap,
            defaults: defaults
        )
        AtriaWhoop4MotionBankCoverageLedger.close(
            at: end,
            strapIdentifier: strap,
            defaults: defaults
        )
        let ticket = try XCTUnwrap(
            AtriaWhoop4MotionBankCoverageLedger.nextPendingOffload(
                strapIdentifier: strap,
                defaults: defaults
            )
        )
        let notification = expectation(
            forNotification: AtriaWhoop4MotionBankCoverageLedger
                .didResolveOffloadNotification,
            object: nil
        ) { note in
            note.object as? String == ticket.id
        }

        AtriaWhoop4MotionBankCoverageLedger.resolveOffload(
            id: ticket.id,
            defaults: defaults
        )

        wait(for: [notification], timeout: 1)
        XCTAssertNil(
            AtriaWhoop4MotionBankCoverageLedger.nextPendingOffload(
                strapIdentifier: strap,
                defaults: defaults
            )
        )
    }

    func testExhaustedOffloadPreservesMissingCoverageWithoutClaimingResolution() throws {
        let start = Date(timeIntervalSince1970: 5_400)
        let end = start.addingTimeInterval(90)
        AtriaWhoop4MotionBankCoverageLedger.open(
            at: start,
            strapIdentifier: strap,
            defaults: defaults
        )
        AtriaWhoop4MotionBankCoverageLedger.close(
            at: end,
            strapIdentifier: strap,
            defaults: defaults
        )
        let ticket = try XCTUnwrap(
            AtriaWhoop4MotionBankCoverageLedger.nextPendingOffload(
                strapIdentifier: strap,
                defaults: defaults
            )
        )
        let finalized = expectation(
            forNotification: AtriaWhoop4MotionBankCoverageLedger
                .didFinalizeOffloadNotification,
            object: nil
        ) { note in
            note.object as? String == ticket.id
        }
        let falselyResolved = expectation(
            forNotification: AtriaWhoop4MotionBankCoverageLedger
                .didResolveOffloadNotification,
            object: nil
        ) { note in
            note.object as? String == ticket.id
                || (note.object as? [String])?.contains(ticket.id) == true
        }
        falselyResolved.isInverted = true

        XCTAssertTrue(
            AtriaWhoop4MotionBankCoverageLedger.exhaustOffload(
                id: ticket.id,
                defaults: defaults
            )
        )

        wait(for: [finalized, falselyResolved], timeout: 0.2)
        XCTAssertNil(
            AtriaWhoop4MotionBankCoverageLedger.nextPendingOffload(
                strapIdentifier: strap,
                defaults: defaults
            )
        )
        XCTAssertEqual(
            AtriaWhoop4MotionBankCoverageLedger.intervals(
                intersecting: .init(
                    start: start.addingTimeInterval(-1),
                    end: end.addingTimeInterval(1)
                ),
                strapIdentifier: strap,
                now: end,
                defaults: defaults
            ),
            [.init(start: start, end: end)]
        )
    }

    func testStaleOffloadBatchExhaustionRetainsIntervalsAndNeverResolves()
        throws
    {
        let firstStart = Date(timeIntervalSince1970: 5_600)
        let firstEnd = firstStart.addingTimeInterval(90)
        let secondStart = firstEnd.addingTimeInterval(10)
        let secondEnd = secondStart.addingTimeInterval(90)
        for (start, end) in [
            (firstStart, firstEnd),
            (secondStart, secondEnd),
        ] {
            AtriaWhoop4MotionBankCoverageLedger.open(
                at: start,
                strapIdentifier: strap,
                defaults: defaults
            )
            AtriaWhoop4MotionBankCoverageLedger.close(
                at: end,
                strapIdentifier: strap,
                defaults: defaults
            )
        }
        let expectedIDs = Set(
            AtriaWhoop4MotionBankCoverageLedger.pendingOffloads(
                strapIdentifier: strap,
                defaults: defaults
            ).map(\.id)
        )
        let falselyResolved = expectation(
            forNotification: AtriaWhoop4MotionBankCoverageLedger
                .didResolveOffloadNotification,
            object: nil
        ) { note in
            if let id = note.object as? String {
                return expectedIDs.contains(id)
            }
            if let ids = note.object as? [String] {
                return !expectedIDs.isDisjoint(with: ids)
            }
            return false
        }
        falselyResolved.isInverted = true

        let exhausted =
            AtriaWhoop4MotionBankCoverageLedger.exhaustOffloads(
                endingAtOrBefore: secondEnd,
                strapIdentifier: strap,
                defaults: defaults
            )

        wait(for: [falselyResolved], timeout: 0.2)
        XCTAssertEqual(exhausted.count, 2)
        XCTAssertTrue(
            AtriaWhoop4MotionBankCoverageLedger.pendingOffloads(
                strapIdentifier: strap,
                defaults: defaults
            ).isEmpty
        )
        XCTAssertEqual(
            AtriaWhoop4MotionBankCoverageLedger.intervals(
                intersecting: .init(
                    start: firstStart.addingTimeInterval(-1),
                    end: secondEnd.addingTimeInterval(1)
                ),
                strapIdentifier: strap,
                now: secondEnd,
                defaults: defaults
            ),
            [
                .init(start: firstStart, end: firstEnd),
                .init(start: secondStart, end: secondEnd),
            ]
        )
    }

    func testNewWorkoutGetsFirstAttemptBeforeOlderRetry() throws {
        let firstStart = Date(timeIntervalSince1970: 5_500)
        let firstEnd = firstStart.addingTimeInterval(90)
        AtriaWhoop4MotionBankCoverageLedger.open(
            at: firstStart,
            strapIdentifier: strap,
            defaults: defaults
        )
        AtriaWhoop4MotionBankCoverageLedger.close(
            at: firstEnd,
            strapIdentifier: strap,
            defaults: defaults
        )
        let first = try XCTUnwrap(
            AtriaWhoop4MotionBankCoverageLedger.nextPendingOffload(
                strapIdentifier: strap,
                defaults: defaults
            )
        )
        _ = AtriaWhoop4MotionBankCoverageLedger.markOffloadAttempt(
            id: first.id,
            at: firstEnd.addingTimeInterval(1),
            defaults: defaults
        )

        let secondStart = firstEnd.addingTimeInterval(30)
        let secondEnd = secondStart.addingTimeInterval(90)
        AtriaWhoop4MotionBankCoverageLedger.open(
            at: secondStart,
            strapIdentifier: strap,
            defaults: defaults
        )
        AtriaWhoop4MotionBankCoverageLedger.close(
            at: secondEnd,
            strapIdentifier: strap,
            defaults: defaults
        )

        let selected = try XCTUnwrap(
            AtriaWhoop4MotionBankCoverageLedger.nextPendingOffload(
                strapIdentifier: strap,
                defaults: defaults
            )
        )
        XCTAssertEqual(selected.start, secondStart)
        XCTAssertEqual(selected.end, secondEnd)
        XCTAssertEqual(selected.attempts, 0)
    }

    func testNewestUnattemptedWorkoutIsSelectedThenRetriesReturnOldestFirst() throws {
        let starts = [6_000.0, 6_200.0, 6_400.0].map {
            Date(timeIntervalSince1970: $0)
        }
        for start in starts {
            AtriaWhoop4MotionBankCoverageLedger.open(
                at: start,
                strapIdentifier: strap,
                defaults: defaults
            )
            AtriaWhoop4MotionBankCoverageLedger.close(
                at: start.addingTimeInterval(90),
                strapIdentifier: strap,
                defaults: defaults
            )
        }

        var attemptedIDs: [String] = []
        for expectedStart in starts.reversed() {
            let selected = try XCTUnwrap(
                AtriaWhoop4MotionBankCoverageLedger.nextPendingOffload(
                    strapIdentifier: strap,
                    defaults: defaults
                )
            )
            XCTAssertEqual(selected.start, expectedStart)
            attemptedIDs.append(selected.id)
            _ = AtriaWhoop4MotionBankCoverageLedger.markOffloadAttempt(
                id: selected.id,
                at: starts.last!.addingTimeInterval(100),
                defaults: defaults
            )
        }

        let retry = try XCTUnwrap(
            AtriaWhoop4MotionBankCoverageLedger.nextPendingOffload(
                strapIdentifier: strap,
                defaults: defaults
            )
        )
        XCTAssertEqual(retry.start, starts.first)
        XCTAssertEqual(Set(attemptedIDs).count, starts.count)
    }

    func testLargestUnattemptedWindowOutranksNewestChurnFragment() throws {
        let longStart = Date(timeIntervalSince1970: 7_000)
        AtriaWhoop4MotionBankCoverageLedger.open(
            at: longStart,
            strapIdentifier: strap,
            defaults: defaults
        )
        AtriaWhoop4MotionBankCoverageLedger.close(
            at: longStart.addingTimeInterval(600),
            strapIdentifier: strap,
            defaults: defaults
        )
        let shortStart = longStart.addingTimeInterval(700)
        AtriaWhoop4MotionBankCoverageLedger.open(
            at: shortStart,
            strapIdentifier: strap,
            defaults: defaults
        )
        AtriaWhoop4MotionBankCoverageLedger.close(
            at: shortStart.addingTimeInterval(19),
            strapIdentifier: strap,
            defaults: defaults
        )

        XCTAssertEqual(
            AtriaWhoop4MotionBankCoverageLedger.nextPendingOffload(
                strapIdentifier: strap,
                defaults: defaults
            )?.start,
            longStart
        )
    }

    func testSubTenSecondBankRemainsMissingCoverageWithoutImpossibleTicket() {
        let start = Date(timeIntervalSince1970: 8_000)
        AtriaWhoop4MotionBankCoverageLedger.open(
            at: start,
            strapIdentifier: strap,
            defaults: defaults
        )
        AtriaWhoop4MotionBankCoverageLedger.close(
            at: start.addingTimeInterval(9),
            strapIdentifier: strap,
            defaults: defaults
        )

        XCTAssertNil(
            AtriaWhoop4MotionBankCoverageLedger.nextPendingOffload(
                strapIdentifier: strap,
                defaults: defaults
            )
        )
        XCTAssertEqual(
            AtriaWhoop4MotionBankCoverageLedger.intervals(
                intersecting: .init(
                    start: start,
                    end: start.addingTimeInterval(10)
                ),
                strapIdentifier: strap,
                now: start.addingTimeInterval(10),
                defaults: defaults
            ),
            [.init(start: start, end: start.addingTimeInterval(9))]
        )
    }

    func testUnresolvedTicketsAreNotSilentlyTruncatedAt128() {
        let origin = Date(timeIntervalSince1970: 9_000)
        for index in 0..<160 {
            let start = origin.addingTimeInterval(TimeInterval(index * 30))
            AtriaWhoop4MotionBankCoverageLedger.open(
                at: start,
                strapIdentifier: strap,
                defaults: defaults
            )
            AtriaWhoop4MotionBankCoverageLedger.close(
                at: start.addingTimeInterval(15),
                strapIdentifier: strap,
                defaults: defaults
            )
        }
        XCTAssertEqual(
            AtriaWhoop4MotionBankCoverageLedger.pendingOffloads(
                strapIdentifier: strap,
                defaults: defaults
            ).count,
            160
        )
    }

    func testBatchResolutionPublishesOneRefreshBoundary() throws {
        let starts = [14_000.0, 14_200.0].map {
            Date(timeIntervalSince1970: $0)
        }
        for start in starts {
            AtriaWhoop4MotionBankCoverageLedger.open(
                at: start,
                strapIdentifier: strap,
                defaults: defaults
            )
            AtriaWhoop4MotionBankCoverageLedger.close(
                at: start.addingTimeInterval(90),
                strapIdentifier: strap,
                defaults: defaults
            )
        }
        let tickets = AtriaWhoop4MotionBankCoverageLedger.pendingOffloads(
            strapIdentifier: strap,
            defaults: defaults
        )
        XCTAssertEqual(tickets.count, 2)
        let notification = expectation(
            forNotification: AtriaWhoop4MotionBankCoverageLedger
                .didResolveOffloadNotification,
            object: nil
        ) { note in
            Set(note.object as? [String] ?? []) == Set(tickets.map(\.id))
        }

        AtriaWhoop4MotionBankCoverageLedger.resolveOffloads(
            ids: Set(tickets.map(\.id)),
            defaults: defaults
        )

        wait(for: [notification], timeout: 1)
        XCTAssertTrue(
            AtriaWhoop4MotionBankCoverageLedger.pendingOffloads(
                strapIdentifier: strap,
                defaults: defaults
            ).isEmpty
        )
    }

    func testOffloadRetryBackoffIsBounded() {
        XCTAssertEqual(
            AtriaBLEManager.workoutHistoricalMotionBankOffloadRetryDelay(
                attempts: 0
            ),
            0
        )
        XCTAssertEqual(
            AtriaBLEManager.workoutHistoricalMotionBankOffloadRetryDelay(
                attempts: 1
            ),
            3
        )
        XCTAssertEqual(
            AtriaBLEManager.workoutHistoricalMotionBankOffloadRetryDelay(
                attempts: 99
            ),
            60
        )
    }

    func testBackgroundMotionBankRetriesStayBoundedByExhaustCap() {
        XCTAssertTrue(
            AtriaBLEManager.historicalMotionBankTicketAttemptEligible(
                attempts: 0,
                applicationIsActive: false
            )
        )
        // 2026-07-31: locked-overnight phones must be able to credit banked
        // coverage; retries below the exhaust cap run in background too.
        XCTAssertTrue(
            AtriaBLEManager.historicalMotionBankTicketAttemptEligible(
                attempts: 1,
                applicationIsActive: false
            )
        )
        XCTAssertTrue(
            AtriaBLEManager.historicalMotionBankTicketAttemptEligible(
                attempts: 3,
                applicationIsActive: false
            )
        )
        XCTAssertFalse(
            AtriaBLEManager.historicalMotionBankTicketAttemptEligible(
                attempts: 4,
                applicationIsActive: false
            )
        )
        XCTAssertFalse(
            AtriaBLEManager.historicalMotionBankTicketAttemptEligible(
                attempts: 99,
                applicationIsActive: false
            )
        )
        XCTAssertTrue(
            AtriaBLEManager.historicalMotionBankTicketAttemptEligible(
                attempts: 1,
                applicationIsActive: true
            )
        )
    }

    func testAutomaticTicketEvaluationNeverScansLifetimeArchive() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaBLEManager.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let start = try XCTUnwrap(source.range(
            of: "private func evaluatePendingWorkoutHistoricalMotionBankOffload("
        ))
        let end = try XCTUnwrap(source.range(
            of: "nonisolated static func shouldRunWorkoutMotionBankCoverageEvaluation(",
            range: start.upperBound..<source.endIndex
        ))
        let body = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(body.contains("let coverage = compactCoverage"))
        XCTAssertFalse(body.contains(
            "HistoricalArchive.motionBankTransportCoverage("
        ))
    }

    func testNewGenerationPreservesAttemptedBindingAheadOfNewerTicket() {
        let bound = offloadTicket(
            id: "bound",
            start: 1_000,
            attempts: 2
        )
        let next = offloadTicket(
            id: "next",
            start: 2_000,
            attempts: 0
        )

        XCTAssertEqual(
            AtriaBLEManager
                .historicalMotionBankOffloadTicketForNewGeneration(
                    bound: bound,
                    next: next
                )?.id,
            bound.id
        )
    }

    func testMaintenanceBoundaryGivesNewBankItsFirstAttemptBeforeOldRetry() {
        let bound = offloadTicket(
            id: "bound",
            start: 1_000,
            attempts: 2
        )
        let next = offloadTicket(
            id: "next",
            start: 2_000,
            attempts: 0
        )

        XCTAssertEqual(
            AtriaBLEManager
                .historicalMotionBankOffloadTicketForNewGeneration(
                    bound: bound,
                    next: next,
                    maintenanceWindow: true
                )?.id,
            next.id
        )
    }

    func testProcessInterruptedBindingOutranksStaleMaintenanceHint() {
        let bound = offloadTicket(
            id: "interrupted-bound",
            start: 1_000,
            attempts: 1
        )
        let maintenance = offloadTicket(
            id: "new-maintenance",
            start: 2_000,
            attempts: 0
        )

        XCTAssertEqual(
            AtriaBLEManager
                .historicalMotionBankOffloadTicketForNewGeneration(
                    bound: bound,
                    next: maintenance,
                    maintenanceWindow: true,
                    processInterruptedBoundRetry: true
                )?.id,
            bound.id
        )
    }

    func testDeferredMaintenanceBoundaryRetainsPriorityUntilTransportStarts() {
        XCTAssertTrue(
            AtriaBLEManager.historicalMotionBankEffectiveMaintenanceWindow(
                requested: true,
                deferred: false
            )
        )
        XCTAssertTrue(
            AtriaBLEManager.historicalMotionBankEffectiveMaintenanceWindow(
                requested: false,
                deferred: true
            )
        )
        XCTAssertFalse(
            AtriaBLEManager.historicalMotionBankEffectiveMaintenanceWindow(
                requested: false,
                deferred: false
            )
        )
    }

    func testMaintenancePriorityClearsOnlyAfterHistoryGenerationStarts() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaBLEManager.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let resumeStart = try XCTUnwrap(source.range(
            of: "private func resumePendingWorkoutHistoricalMotionBankOffloadIfNeeded("
        ))
        let resumeEnd = try XCTUnwrap(source.range(
            of: "/// Builds one replacement ticket",
            range: resumeStart.upperBound..<source.endIndex
        ))
        let resumeBody = String(
            source[resumeStart.lowerBound..<resumeEnd.lowerBound]
        )
        XCTAssertFalse(resumeBody.contains("markOffloadAttempt("))
        XCTAssertFalse(resumeBody.contains(
            "workoutHistoricalMotionBankMaintenancePendingKey"
        ))

        let generationStart = try XCTUnwrap(source.range(
            of: "offlineHistoricalSyncInProgress = true"
        ))
        let mark = try XCTUnwrap(source.range(
            of: "markActiveWorkoutHistoricalMotionBankAttemptForStartedGeneration(",
            range: generationStart.upperBound..<source.endIndex
        ))
        XCTAssertGreaterThan(mark.lowerBound, generationStart.lowerBound)

        let markerHelper = try XCTUnwrap(source.range(
            of: "private func markActiveWorkoutHistoricalMotionBankAttemptForStartedGeneration("
        ))
        let markerEnd = try XCTUnwrap(source.range(
            of: "private func ",
            range: markerHelper.upperBound..<source.endIndex
        ))
        let markerBody = String(
            source[markerHelper.lowerBound..<markerEnd.lowerBound]
        )
        XCTAssertTrue(markerBody.contains("markOffloadAttempt("))
        XCTAssertTrue(markerBody.contains(
            "workoutHistoricalMotionBankMaintenanceTicketIDKey"
        ))
    }

    func testExactDeferredMaintenanceTicketBlocksPrematureRearm() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaBLEManager.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let start = try XCTUnwrap(source.range(
            of: "private func armWorkoutHistoricalMotionBankIfPossible("
        ))
        let end = try XCTUnwrap(source.range(
            of: "private func checkpointDailyHistoricalMotionBankIfNeeded(",
            range: start.upperBound..<source.endIndex
        ))
        let body = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(body.contains(
            "pendingWorkoutHistoricalMotionBankMaintenanceTicket("
        ))
        XCTAssertTrue(body.contains(
            "maintenanceWindow: maintenanceTicket != nil"
        ))
        XCTAssertTrue(body.contains(
            "pendingOffloadAttempts: selectedPendingOffload?.attempts"
        ))
    }

    func testDisconnectClosedBankPersistsFirstAttemptMaintenanceAuthority()
        throws
    {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaBLEManager.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let start = try XCTUnwrap(source.range(
            of: "// Firmware bank state dies with the physical BLE connection."
        ))
        let end = try XCTUnwrap(source.range(
            of: "defaults.removeObject(",
            range: start.upperBound..<source.endIndex
        ))
        let disconnectClose = String(source[start.lowerBound..<end.lowerBound])

        let close = try XCTUnwrap(disconnectClose.range(
            of: "AtriaWhoop4MotionBankCoverageLedger.close("
        ))
        let persist = try XCTUnwrap(disconnectClose.range(
            of: "persistNextUnattemptedMotionBankMaintenanceTicketIfNeeded("
        ))
        XCTAssertLessThan(close.lowerBound, persist.lowerBound)

        let helperStart = try XCTUnwrap(source.range(
            of: "private func persistNextUnattemptedMotionBankMaintenanceTicketIfNeeded("
        ))
        let helperEnd = try XCTUnwrap(source.range(
            of: "private func pendingWorkoutHistoricalMotionBankMaintenanceTicket(",
            range: helperStart.upperBound..<source.endIndex
        ))
        let helper = String(source[helperStart.lowerBound..<helperEnd.lowerBound])
        XCTAssertTrue(helper.contains("nextPendingOffload("))
        XCTAssertTrue(helper.contains("ticket.attempts == 0"))
        XCTAssertTrue(helper.contains(
            "workoutHistoricalMotionBankMaintenanceTicketIDKey"
        ))

        let acceptedStart = try XCTUnwrap(source.range(
            of: "// Give a previously closed durable bank first refusal"
        ))
        let acceptedEnd = try XCTUnwrap(source.range(
            of: "let bankOffloadStarted =",
            range: acceptedStart.upperBound..<source.endIndex
        ))
        let acceptedPath = String(
            source[acceptedStart.lowerBound..<acceptedEnd.lowerBound]
        )
        XCTAssertTrue(acceptedPath.contains(
            "if !workoutHistoricalMotionBankArmed"
        ))
        XCTAssertTrue(acceptedPath.contains(
            "persistNextUnattemptedMotionBankMaintenanceTicketIfNeeded("
        ))
    }

    func testBankThermalDeferralRetainsBankAuthorityWithoutAttendedUpgrade()
        throws
    {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaBLEManager.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let start = try XCTUnwrap(source.range(
            of: "if Self.shouldDeferAutomaticOfflineSyncForThermalPressure("
        ))
        let end = try XCTUnwrap(source.range(
            of: "// Never turn a pending CoreBluetooth reconnect",
            range: start.upperBound..<source.endIndex
        ))
        let body = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(body.contains(
            "explicitRequest: attendedHistoricalRequest"
        ))
        XCTAssertFalse(body.contains(
            "explicitRequest: explicitHistoricalRequest"
        ))
    }

    func testNewGenerationPreservesBindingWhenItIsAlreadyNext() {
        let bound = offloadTicket(
            id: "same",
            start: 1_000,
            attempts: 1
        )

        XCTAssertEqual(
            AtriaBLEManager
                .historicalMotionBankOffloadTicketForNewGeneration(
                    bound: bound,
                    next: bound
                )?.id,
            bound.id
        )
    }

    func testNewGenerationUsesLedgerSelectionWithoutBinding() {
        let next = offloadTicket(
            id: "next",
            start: 2_000,
            attempts: 0
        )

        XCTAssertEqual(
            AtriaBLEManager
                .historicalMotionBankOffloadTicketForNewGeneration(
                    bound: nil,
                    next: next
                )?.id,
            next.id
        )
    }

    func testNewGenerationPreservesAttemptedBindingWhenNoUnattemptedExists() {
        let bound = offloadTicket(
            id: "bound",
            start: 1_000,
            attempts: 2
        )
        let retry = offloadTicket(
            id: "retry",
            start: 2_000,
            attempts: 1
        )

        XCTAssertEqual(
            AtriaBLEManager
                .historicalMotionBankOffloadTicketForNewGeneration(
                    bound: bound,
                    next: retry
                )?.id,
            bound.id
        )
    }

    func testExactWindowCoverageRequiresNinetyPercentAndBoundedHole() {
        let start = Date(timeIntervalSince1970: 6_000)
        XCTAssertTrue(
            HistoricalArchive.MotionBankTransportCoverage(
                observedSeconds: 91,
                expectedSeconds: 92,
                densityPercent: 99,
                maximumMissingRunSeconds: 1,
                firstCapturedAt: start,
                capturedThrough: start.addingTimeInterval(90)
            ).satisfiesNinetyPercentExactWindow
        )
        XCTAssertFalse(
            HistoricalArchive.MotionBankTransportCoverage(
                observedSeconds: 83,
                expectedSeconds: 92,
                densityPercent: 90,
                maximumMissingRunSeconds: 10,
                firstCapturedAt: start,
                capturedThrough: start.addingTimeInterval(90)
            ).satisfiesNinetyPercentExactWindow
        )
    }

    // Drain-on-glance (2026-08-01): opening the app closes a >10-minute bank
    // immediately so fresh steps credit within ~1-2 minutes, bounded by a
    // persisted 10-minute glance fence and blocked while a history sync owns
    // the radio or the live link lacks accepted HR.
    func testGlanceCheckpointRequiresTenMinutesOfBankedMotion() {
        XCTAssertTrue(AtriaBLEManager.historicalMotionBankGlanceCheckpointEligible(
            bankOpenSeconds: 11 * 60,
            secondsSinceLastGlanceCheckpoint: nil,
            historySyncInProgress: false,
            connectedWithAcceptedHR: true))
        XCTAssertFalse(AtriaBLEManager.historicalMotionBankGlanceCheckpointEligible(
            bankOpenSeconds: 10 * 60,
            secondsSinceLastGlanceCheckpoint: nil,
            historySyncInProgress: false,
            connectedWithAcceptedHR: true),
                       "exactly ten minutes is not yet >10 minutes of banked motion")
        XCTAssertFalse(AtriaBLEManager.historicalMotionBankGlanceCheckpointEligible(
            bankOpenSeconds: 4 * 60,
            secondsSinceLastGlanceCheckpoint: nil,
            historySyncInProgress: false,
            connectedWithAcceptedHR: true))
    }

    func testGlanceCheckpointKeepsTenMinuteCooldownBetweenGlances() {
        XCTAssertFalse(AtriaBLEManager.historicalMotionBankGlanceCheckpointEligible(
            bankOpenSeconds: 45 * 60,
            secondsSinceLastGlanceCheckpoint: 9 * 60,
            historySyncInProgress: false,
            connectedWithAcceptedHR: true),
                       "repeated app opens must not churn the bank")
        XCTAssertTrue(AtriaBLEManager.historicalMotionBankGlanceCheckpointEligible(
            bankOpenSeconds: 45 * 60,
            secondsSinceLastGlanceCheckpoint: 10 * 60,
            historySyncInProgress: false,
            connectedWithAcceptedHR: true))
    }

    func testGlanceCheckpointYieldsToHistorySyncAndRequiresAcceptedHR() {
        XCTAssertFalse(AtriaBLEManager.historicalMotionBankGlanceCheckpointEligible(
            bankOpenSeconds: 45 * 60,
            secondsSinceLastGlanceCheckpoint: nil,
            historySyncInProgress: true,
            connectedWithAcceptedHR: true))
        XCTAssertFalse(AtriaBLEManager.historicalMotionBankGlanceCheckpointEligible(
            bankOpenSeconds: 45 * 60,
            secondsSinceLastGlanceCheckpoint: nil,
            historySyncInProgress: false,
            connectedWithAcceptedHR: false))
    }

    private func offloadTicket(
        id: String,
        start: TimeInterval,
        attempts: Int
    ) -> AtriaWhoop4MotionBankCoverageLedger.OffloadTicket {
        let start = Date(timeIntervalSince1970: start)
        return .init(
            id: id,
            strapIdentifier: strap,
            start: start,
            end: start.addingTimeInterval(90),
            armedConnectionStartedAt: start,
            attempts: attempts,
            lastAttemptAt:
                attempts > 0 ? start.addingTimeInterval(91) : nil
        )
    }
}
