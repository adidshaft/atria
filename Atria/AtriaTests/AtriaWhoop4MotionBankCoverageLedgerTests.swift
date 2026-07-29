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

    func testClosedWorkoutCreatesDurableExactOffloadTicket() {
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
            offloadStart: workoutStart,
            armedConnectionStartedAt: epoch,
            defaults: defaults
        )

        let ticket = AtriaWhoop4MotionBankCoverageLedger.nextPendingOffload(
            strapIdentifier: strap,
            defaults: defaults
        )
        XCTAssertEqual(ticket?.start, workoutStart)
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
}
