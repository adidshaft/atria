import XCTest
@testable import Atria

final class AtriaRecoveredDataExecutionLeaseTests: XCTestCase {
    func testForegroundRevocationIsStickyAcrossEnvironmentRecovery() {
        let previous = AtriaHistoricalProjectionForegroundGate.isBackgrounded
        defer {
            AtriaHistoricalProjectionForegroundGate.isBackgrounded = previous
        }
        AtriaHistoricalProjectionForegroundGate.isBackgrounded = false
        let lease = AtriaRecoveredDataExecutionLease(
            generation: 7,
            archiveRevision: 41
        )

        AtriaHistoricalProjectionForegroundGate.isBackgrounded = true
        XCTAssertFalse(lease.shouldContinue())
        XCTAssertEqual(
            lease.recordedRevocationReason,
            "application_background"
        )

        AtriaHistoricalProjectionForegroundGate.isBackgrounded = false
        XCTAssertFalse(
            lease.shouldContinue(),
            "one unsafe observation permanently retires this ticket"
        )
    }

    func testConcurrentRevokeHasExactlyOneWinningEdge() {
        let lease = AtriaRecoveredDataExecutionLease(
            generation: 8,
            archiveRevision: 42
        )
        let queue = DispatchQueue(
            label: "atria.tests.recovered-lease",
            attributes: .concurrent
        )
        let group = DispatchGroup()
        let lock = NSLock()
        var winners = 0
        for index in 0..<128 {
            group.enter()
            queue.async {
                let won = lease.revoke(reason: "edge_\(index)")
                if won {
                    lock.lock()
                    winners += 1
                    lock.unlock()
                }
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(winners, 1)
        XCTAssertTrue(lease.isRevoked)
        XCTAssertFalse(lease.shouldContinue())
    }

    func testLeaseIdentityIsTicketScoped() {
        let lease = AtriaRecoveredDataExecutionLease(
            generation: 19,
            archiveRevision: 120
        )
        XCTAssertEqual(lease.identity.generation, 19)
        XCTAssertEqual(lease.identity.archiveRevision, 120)
    }

    // 2026-10-02: a notification glance / Control Center made the scene
    // inactive and threw away the ~70 s recovered fence. Inactive now counts
    // as active for the fence; real background revokes at once, and an
    // inactive spell only after a short grace.
    func testInactiveGlanceDoesNotRevokeRecoveredWork() throws {
        XCTAssertTrue(SessionStore.recoveredExecutionTreatsApplicationAsActive(.active))
        XCTAssertTrue(SessionStore.recoveredExecutionTreatsApplicationAsActive(.inactive))
        XCTAssertFalse(SessionStore.recoveredExecutionTreatsApplicationAsActive(.background))
        XCTAssertGreaterThan(AtriaSceneInactiveGrace.seconds, 1)
        XCTAssertLessThanOrEqual(AtriaSceneInactiveGrace.seconds, 5,
                                 "a real departure must still stop work promptly")
        let app = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaApp.swift"), encoding: .utf8)
        XCTAssertTrue(app.contains("enterBackgroundedLifecycle(phase: .background)"))
        XCTAssertTrue(app.contains("for: .seconds(AtriaSceneInactiveGrace.seconds)"))
    }
}
