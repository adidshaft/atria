import XCTest
@testable import Atria

/// Truth table for `AtriaBLEManager.resumableMotionBankOffloadPending` — the
/// signal the BGProcessing lane uses to drive a MOTION offload when HR is caught
/// up or only soft-behind (2026-08-08 motion-offload fix). Motion/step coverage
/// stalled ~48% because motion offload rode the same single BLE transport as HR
/// but had no dedicated background wake; this predicate + the BGProcessing branch
/// give it one. Resumable == a pending ledger ticket that is neither attempt-
/// exhausted (>= 4) nor over the 36 h blocking age.
final class AtriaMotionOffloadResumeTests: XCTestCase {
    private let strapKey = "atria.offlineSync.verifiedHistoryPeripheralID"
    private let strap = "MOTION-TEST-STRAP"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeSuite() throws -> (UserDefaults, String) {
        let name = "atria.motionoffload.test.\(UUID().uuidString)"
        let s = try XCTUnwrap(UserDefaults(suiteName: name))
        AtriaWhoop4MotionBankCoverageLedger.reset(defaults: s)
        return (s, name)
    }

    /// Opens then closes a bank so exactly one pending offload exists, ending at
    /// `end`. Returns its id so the test can age its attempts.
    @discardableResult
    private func seedPendingOffload(_ s: UserDefaults, end: Date) throws -> String {
        AtriaWhoop4MotionBankCoverageLedger.open(
            at: end.addingTimeInterval(-200), strapIdentifier: strap, defaults: s)
        AtriaWhoop4MotionBankCoverageLedger.close(
            at: end, strapIdentifier: strap, defaults: s)
        let ticket = try XCTUnwrap(
            AtriaWhoop4MotionBankCoverageLedger.nextPendingOffload(
                strapIdentifier: strap, defaults: s))
        return ticket.id
    }

    private func resumable(_ s: UserDefaults) -> Bool {
        AtriaBLEManager.resumableMotionBankOffloadPending(now: now, defaults: s)
    }

    func testFreshUnexhaustedTicketIsResumable() throws {
        let (s, n) = try makeSuite(); defer { s.removePersistentDomain(forName: n) }
        s.set(strap, forKey: strapKey)
        try seedPendingOffload(s, end: now.addingTimeInterval(-60 * 60)) // 1 h ago, attempts 0
        XCTAssertTrue(resumable(s), "pending, attempts 0, well within 36 h -> resumable")
    }

    func testExhaustedTicketIsNotResumable() throws {
        let (s, n) = try makeSuite(); defer { s.removePersistentDomain(forName: n) }
        s.set(strap, forKey: strapKey)
        let id = try seedPendingOffload(s, end: now.addingTimeInterval(-60 * 60))
        for _ in 0..<4 { // reach attempts == workoutHistoricalMotionBankMaximumOffloadAttempts (4)
            _ = AtriaWhoop4MotionBankCoverageLedger.markOffloadAttempt(
                id: id, at: now, defaults: s)
        }
        XCTAssertFalse(resumable(s), "attempts == 4 -> exhausted -> not resumable")
    }

    func testOverAgeTicketIsNotResumable() throws {
        let (s, n) = try makeSuite(); defer { s.removePersistentDomain(forName: n) }
        s.set(strap, forKey: strapKey)
        try seedPendingOffload(s, end: now.addingTimeInterval(-40 * 60 * 60)) // 40 h ago > 36 h
        XCTAssertFalse(resumable(s), "ended > 36 h ago -> over blocking age -> not resumable")
    }

    func testNoVerifiedStrapIsNotResumable() throws {
        let (s, n) = try makeSuite(); defer { s.removePersistentDomain(forName: n) }
        try seedPendingOffload(s, end: now.addingTimeInterval(-60 * 60)) // ticket exists...
        // ...but no verifiedHistoryPeripheralID set, so the predicate can't bind a strap.
        XCTAssertFalse(resumable(s), "no verified strap -> not resumable")
    }

    func testNoPendingTicketIsNotResumable() throws {
        let (s, n) = try makeSuite(); defer { s.removePersistentDomain(forName: n) }
        s.set(strap, forKey: strapKey)
        XCTAssertFalse(resumable(s), "verified strap but empty ledger -> not resumable")
    }
}
