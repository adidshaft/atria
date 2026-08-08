import XCTest
@testable import Atria

/// Truth table for `AtriaBLEManager.drainableStrapBacklogPendingFromDefaults` —
/// the robust backlog signal the wake-driven lanes now use instead of the raw
/// `rangeLossBackfillPending` ticket (2026-08-08 background-stall fix). The
/// ticket can be falsely cleared by publication while records remain on the
/// strap; this predicate also catches fresh non-caught-up flush debt and a
/// >= 30-min-stale drain frontier.
final class AtriaBackgroundDrainBacklogTests: XCTestCase {
    private let ticketKey = "atria.offlineSync.rangeLossBackfillPending"
    private let debtObservedKey = "atria.offlineSync.flushDebtObservedAt.v1"
    private let debtRecordsKey = "atria.offlineSync.flushDebtPendingRecords.v1"
    private let frontierKey = "atria.offlineSync.drainedThroughUnix.v1"

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeSuite() throws -> (UserDefaults, String) {
        let name = "atria.drainbacklog.test.\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: name)), name)
    }

    private func pending(_ s: UserDefaults) -> Bool {
        AtriaBLEManager.drainableStrapBacklogPendingFromDefaults(now: now, defaults: s)
    }

    func testTicketAloneIsBacklog() throws {
        let (s, n) = try makeSuite(); defer { s.removePersistentDomain(forName: n) }
        s.set(true, forKey: ticketKey)
        XCTAssertTrue(pending(s))
    }

    func testFreshNonCaughtUpDebtIsBacklog_theObservedIncidentState() throws {
        let (s, n) = try makeSuite(); defer { s.removePersistentDomain(forName: n) }
        s.set(now.timeIntervalSince1970 - 5 * 60, forKey: debtObservedKey) // fresh
        s.set(267, forKey: debtRecordsKey)                                 // > 120 floor
        XCTAssertTrue(pending(s), "267 pending, fresh, no ticket -> backlog (the observed stall)")
    }

    func testFreshCaughtUpDebtIsNotBacklog() throws {
        let (s, n) = try makeSuite(); defer { s.removePersistentDomain(forName: n) }
        s.set(now.timeIntervalSince1970 - 5 * 60, forKey: debtObservedKey)
        s.set(100, forKey: debtRecordsKey) // <= 120 floor -> caught up
        XCTAssertFalse(pending(s))
    }

    func testStaleFrontierIsBacklog() throws {
        let (s, n) = try makeSuite(); defer { s.removePersistentDomain(forName: n) }
        s.set(now.timeIntervalSince1970 - 40 * 60, forKey: frontierKey) // 40 min behind
        XCTAssertTrue(pending(s), "frontier >= 30 min stale -> backlog")
    }

    func testFreshFrontierIsNotBacklog() throws {
        let (s, n) = try makeSuite(); defer { s.removePersistentDomain(forName: n) }
        s.set(now.timeIntervalSince1970 - 20 * 60, forKey: frontierKey) // 20 min behind
        XCTAssertFalse(pending(s), "frontier < 30 min -> not backlog")
    }

    func testStaleDebtIsIgnoredAndFallsToFrontier() throws {
        let (s, n) = try makeSuite(); defer { s.removePersistentDomain(forName: n) }
        s.set(now.timeIntervalSince1970 - 20 * 60, forKey: debtObservedKey) // STALE (> 15 min)
        s.set(267, forKey: debtRecordsKey)                                  // would be backlog if fresh
        s.set(now.timeIntervalSince1970 - 20 * 60, forKey: frontierKey)     // frontier only 20 min
        XCTAssertFalse(pending(s), "stale debt is ignored; fresh-enough frontier -> not backlog")
    }

    func testEmptyStateIsNotBacklog() throws {
        let (s, n) = try makeSuite(); defer { s.removePersistentDomain(forName: n) }
        XCTAssertFalse(pending(s), "no ticket, no debt, no frontier -> not backlog")
    }
}
