import XCTest
@testable import Atria

/// Clean-slate durability: after the user taps "Start fresh" to abandon an
/// un-drainable banked backlog, the backlog detectors must stop chasing the
/// pre-reset records (the history reads a degraded strap drops the link on),
/// yet must resume normally once genuinely new post-reset data drains — and
/// must be completely inert for any strap that never ran Start fresh.
final class AtriaCleanSlateBacklogSuppressionTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "atria.cleanslate.tests"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private typealias K = AtriaBLEManager.OfflineSyncDefaults

    override func setUp() {
        super.setUp()
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
    }
    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = nil
        super.tearDown()
    }

    private func reason() -> AtriaBLEManager.StrapBacklogReason {
        AtriaBLEManager.strapBacklogReason(now: now, defaults: defaults,
                                           processInstanceID: "test-proc")
    }

    // Healthy strap that never ran Start fresh: fresh large debt → .freshDebt.
    func testFreshDebtDetectedWhenNotAbandoned() {
        defaults.set(50_000, forKey: K.flushDebtPendingRecords)
        defaults.set(now.timeIntervalSince1970, forKey: K.flushDebtObservedAt)
        XCTAssertFalse(AtriaBLEManager.historyAbandonedSuppressesBacklog(defaults: defaults))
        XCTAssertEqual(reason(), .freshDebt)
    }

    // After Start fresh (abandon=now, frontier=now), the same fresh large debt
    // is suppressed → .none (stops the read that drops the link).
    func testFreshDebtSuppressedAfterStartFresh() {
        defaults.set(now.timeIntervalSince1970, forKey: K.historyAbandonedThroughUnix)
        defaults.set(now.timeIntervalSince1970, forKey: K.drainedThroughUnix)
        defaults.set(50_000, forKey: K.flushDebtPendingRecords)
        defaults.set(now.timeIntervalSince1970, forKey: K.flushDebtObservedAt)
        XCTAssertTrue(AtriaBLEManager.historyAbandonedSuppressesBacklog(defaults: defaults))
        XCTAssertEqual(reason(), .none)
    }

    // Stale frontier normally → .frontierStale; suppressed after Start fresh.
    func testFrontierStaleSuppressedAfterStartFresh() {
        // Frontier 2h behind now.
        let staleFrontier = now.addingTimeInterval(-2 * 3600).timeIntervalSince1970
        defaults.set(staleFrontier, forKey: K.drainedThroughUnix)
        XCTAssertEqual(reason(), .frontierStale)
        // Abandon at (frontier) so frontier <= abandon → suppressed.
        defaults.set(staleFrontier, forKey: K.historyAbandonedThroughUnix)
        XCTAssertTrue(AtriaBLEManager.historyAbandonedSuppressesBacklog(defaults: defaults))
        XCTAssertEqual(reason(), .none)
    }

    // Suppression LIFTS once real new data drains past the abandoned instant.
    func testSuppressionLiftsWhenFrontierAdvancesPastAbandon() {
        let abandon = now.addingTimeInterval(-3 * 3600).timeIntervalSince1970
        defaults.set(abandon, forKey: K.historyAbandonedThroughUnix)
        // Frontier advanced 10 min past the abandon instant = genuine new data.
        defaults.set(abandon + 600, forKey: K.drainedThroughUnix)
        XCTAssertFalse(AtriaBLEManager.historyAbandonedSuppressesBacklog(defaults: defaults))
        // Fresh large debt now detected again (real post-reset backlog).
        defaults.set(50_000, forKey: K.flushDebtPendingRecords)
        defaults.set(now.timeIntervalSince1970, forKey: K.flushDebtObservedAt)
        XCTAssertEqual(reason(), .freshDebt)
    }

    // A genuine new-gap ticket still wins even while abandoned (small recent
    // window that should still drain).
    func testTicketStillWinsWhileAbandoned() {
        defaults.set(now.timeIntervalSince1970, forKey: K.historyAbandonedThroughUnix)
        defaults.set(now.timeIntervalSince1970, forKey: K.drainedThroughUnix)
        defaults.set(true, forKey: K.rangeLossBackfillPending)
        XCTAssertEqual(reason(), .ticket)
    }

    // Boundary: frontier exactly at abandon (within 1s) is still suppressed;
    // frontier just past (>1s) is not.
    func testFrontierBoundary() {
        let abandon = now.timeIntervalSince1970
        defaults.set(abandon, forKey: K.historyAbandonedThroughUnix)
        defaults.set(abandon + 1, forKey: K.drainedThroughUnix)
        XCTAssertTrue(AtriaBLEManager.historyAbandonedSuppressesBacklog(defaults: defaults))
        defaults.set(abandon + 2, forKey: K.drainedThroughUnix)
        XCTAssertFalse(AtriaBLEManager.historyAbandonedSuppressesBacklog(defaults: defaults))
    }
}

/// Auto-surfacing of the clean slate: a degraded strap that can't drain must be
/// OFFERED "Start fresh" automatically, not nag forever. Pure decision tests.
final class AtriaGapTerminalStallTests: XCTestCase {
    private let window = AtriaMissedDataBannerPresentation.terminalStallWindow // 4h
    private typealias P = AtriaMissedDataBannerPresentation

    func testNotStalledWithoutBacklog() {
        XCTAssertFalse(P.gapIsTerminallyStalled(
            backlogPending: false, activelyDraining: false,
            sequenceGapParkedTerminal: false,
            secondsSinceLastDurableFlush: 10 * 3600,
            secondsSinceRangeLossRequested: 10 * 3600))
    }

    func testNotStalledWhileActivelyDraining() {
        XCTAssertFalse(P.gapIsTerminallyStalled(
            backlogPending: true, activelyDraining: true,
            sequenceGapParkedTerminal: true,
            secondsSinceLastDurableFlush: 10 * 3600,
            secondsSinceRangeLossRequested: 10 * 3600))
    }

    func testStalledWhenSequenceGapParked() {
        XCTAssertTrue(P.gapIsTerminallyStalled(
            backlogPending: true, activelyDraining: false,
            sequenceGapParkedTerminal: true,
            secondsSinceLastDurableFlush: nil,
            secondsSinceRangeLossRequested: 60))
    }

    func testStalledWhenNoProgressForWindow() {
        XCTAssertTrue(P.gapIsTerminallyStalled(
            backlogPending: true, activelyDraining: false,
            sequenceGapParkedTerminal: false,
            secondsSinceLastDurableFlush: window + 60,
            secondsSinceRangeLossRequested: window + 60))
    }

    // Never flushed (nil) but request is old enough → stalled.
    func testStalledWhenNeverFlushedAndRequestOld() {
        XCTAssertTrue(P.gapIsTerminallyStalled(
            backlogPending: true, activelyDraining: false,
            sequenceGapParkedTerminal: false,
            secondsSinceLastDurableFlush: nil,
            secondsSinceRangeLossRequested: window + 1))
    }

    // Transient reconnect blip: request younger than the window → NOT stalled,
    // even with no recent flush.
    func testNotStalledWhenRequestIsRecent() {
        XCTAssertFalse(P.gapIsTerminallyStalled(
            backlogPending: true, activelyDraining: false,
            sequenceGapParkedTerminal: false,
            secondsSinceLastDurableFlush: 10 * 3600,
            secondsSinceRangeLossRequested: 5 * 60))
    }

    // Recent durable flush = real progress → NOT stalled.
    func testNotStalledWhenRecentFlush() {
        XCTAssertFalse(P.gapIsTerminallyStalled(
            backlogPending: true, activelyDraining: false,
            sequenceGapParkedTerminal: false,
            secondsSinceLastDurableFlush: 10 * 60,
            secondsSinceRangeLossRequested: window + 60))
    }
}
