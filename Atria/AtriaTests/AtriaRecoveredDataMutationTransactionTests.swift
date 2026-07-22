import XCTest
@testable import Atria

@MainActor
final class AtriaRecoveredDataMutationTransactionTests: XCTestCase {
    private typealias Ticket = AtriaRecoveredDataRecomputeCoordinator.Ticket

    func testInjectedFailureRollsEveryCompletedMutationBackInReverseOrder() {
        let transaction = AtriaRecoveredDataMutationTransaction()
        let ticket = Ticket(generation: 7, archiveRevision: 41, reason: "fault_after_sleep")
        var state = ["published"]
        var rollbackOrder: [String] = []

        XCTAssertTrue(transaction.begin(ticket: ticket))
        for component in ["projection", "sleep", "rollup"] {
            let previous = state
            XCTAssertTrue(transaction.registerRollback(ticket: ticket) {
                rollbackOrder.append(component)
                state = previous
            })
            state.append(component)
        }

        XCTAssertEqual(state, ["published", "projection", "sleep", "rollup"])
        XCTAssertTrue(transaction.rollback(ticket: ticket))
        XCTAssertEqual(state, ["published"])
        XCTAssertEqual(rollbackOrder, ["rollup", "sleep", "projection"])
        XCTAssertNil(transaction.activeTicket)
    }

    func testFaultInjectionAfterEveryPipelineBoundaryRestoresPublishedImage() {
        let components = ["projection", "workout", "sleep", "history", "trends"]
        for faultAfter in 1...components.count {
            let transaction = AtriaRecoveredDataMutationTransaction()
            let ticket = Ticket(generation: UInt64(100 + faultAfter),
                                archiveRevision: UInt64(200 + faultAfter),
                                reason: "fault_\(faultAfter)")
            var state = ["published"]
            XCTAssertTrue(transaction.begin(ticket: ticket))

            for component in components.prefix(faultAfter) {
                let previous = state
                XCTAssertTrue(transaction.registerRollback(ticket: ticket) {
                    state = previous
                })
                state.append(component)
            }

            XCTAssertTrue(transaction.rollback(ticket: ticket), "fault boundary \(faultAfter)")
            XCTAssertEqual(state, ["published"], "fault boundary \(faultAfter)")
        }
    }

    func testCommitMakesPreparedMutationPermanentAndCannotLaterRollback() {
        let transaction = AtriaRecoveredDataMutationTransaction()
        let ticket = Ticket(generation: 8, archiveRevision: 42, reason: "success")
        var value = 1

        XCTAssertTrue(transaction.begin(ticket: ticket))
        XCTAssertTrue(transaction.registerRollback(ticket: ticket) { value = 1 })
        value = 2

        var commitCount = 0
        XCTAssertTrue(transaction.registerCommit(ticket: ticket) { commitCount += 1 })
        XCTAssertTrue(transaction.commit(ticket: ticket))
        XCTAssertFalse(transaction.rollback(ticket: ticket))
        XCTAssertEqual(value, 2)
        XCTAssertEqual(commitCount, 1)
    }

    func testStaleTicketCannotRegisterCommitOrRollbackReplacement() {
        let transaction = AtriaRecoveredDataMutationTransaction()
        let old = Ticket(generation: 9, archiveRevision: 43, reason: "old")
        let replacement = Ticket(generation: 10, archiveRevision: 44, reason: "replacement")
        var value = 0

        XCTAssertTrue(transaction.begin(ticket: old))
        XCTAssertTrue(transaction.registerRollback(ticket: old) { value = 0 })
        value = 1
        XCTAssertTrue(transaction.rollback(ticket: old))

        XCTAssertTrue(transaction.begin(ticket: replacement))
        XCTAssertFalse(transaction.registerRollback(ticket: old) { value = -1 })
        XCTAssertFalse(transaction.commit(ticket: old))
        XCTAssertFalse(transaction.rollback(ticket: old))
        XCTAssertEqual(transaction.activeTicket, replacement)
        XCTAssertEqual(value, 0)
    }

    func testDuplicateBeginFailsClosedInsteadOfDroppingExistingUndoJournal() {
        let transaction = AtriaRecoveredDataMutationTransaction()
        let first = Ticket(generation: 11, archiveRevision: 45, reason: "first")
        let second = Ticket(generation: 12, archiveRevision: 46, reason: "second")
        var value = 3

        XCTAssertTrue(transaction.begin(ticket: first))
        XCTAssertTrue(transaction.registerRollback(ticket: first) { value = 3 })
        value = 4
        XCTAssertFalse(transaction.begin(ticket: second))
        XCTAssertEqual(transaction.activeTicket, first)
        XCTAssertTrue(transaction.rollback(ticket: first))
        XCTAssertEqual(value, 3)
    }

    func testFailureDropsDeferredCommitSideEffects() {
        let transaction = AtriaRecoveredDataMutationTransaction()
        let ticket = Ticket(generation: 13, archiveRevision: 47, reason: "persist_failed")
        var commitCount = 0

        XCTAssertTrue(transaction.begin(ticket: ticket))
        XCTAssertTrue(transaction.registerCommit(ticket: ticket) { commitCount += 1 })
        XCTAssertTrue(transaction.rollback(ticket: ticket))
        XCTAssertEqual(commitCount, 0)
    }

    func testSessionStoreWiresEveryTerminalCoordinatorEffectThroughTransaction() throws {
        let testsURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsURL.deletingLastPathComponent()
            .appendingPathComponent("Atria/Sessions.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("guard beginRecoveredDataMutationTransaction(ticket: ticket)"))
        XCTAssertTrue(source.contains("guard self.registerRecoveredDataMutationSnapshot(ticket: ticket)"))
        XCTAssertTrue(source.contains("rollbackRecoveredDataMutationTransaction(ticket: ticket)"))
        XCTAssertTrue(source.contains("guard commitRecoveredDataMutationTransaction(ticket: ticket)"))
        XCTAssertTrue(source.contains("pendingDailyMetricSaveWorkItem?.cancel()"))
        XCTAssertTrue(source.contains("confirmedWorkoutRehydrationGeneration &+= 1"))
        XCTAssertTrue(source.contains("foregroundSleepSettlementGeneration &+= 1"))
        XCTAssertTrue(source.contains("behaviorInsightsGeneration &+= 1"))
        XCTAssertTrue(source.contains("scheduleDailyMetricPersist(reason: \"recovered_transaction_commit\""))
        XCTAssertTrue(source.contains("recoveredDataMutationTransaction.registerCommit"))
        XCTAssertTrue(source.contains("publishDailyRollupSideEffects(preparation:"))
        XCTAssertTrue(source.contains("publishHistoricalRecoveryWindow("))
        XCTAssertTrue(source.contains("dailyRollupStore.beginRecoveredDataPublicationFence()"))
        XCTAssertTrue(source.contains("dailyRollupStore.endRecoveredDataPublicationFence()"))
    }

    func testNestedRecoveredAndRestoreRollupFencesPersistOnlyAfterBothEnd() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("atria-recovered-rollup-fence-\(UUID().uuidString).json")
        let store = DailyRollupStore(url: url, loadPersisted: false)
        let row = DailyRollupStoreEntry(day: Date(timeIntervalSince1970: 1_783_000_000),
                                        recovery: 77)

        store.beginRecoveredDataPublicationFence()
        await store.beginPersistenceFence()
        store.replaceAll([row])
        store.endRecoveredDataPublicationFence()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "ending one nested owner must not leak the prepared file")

        store.endPersistenceFence()
        let deadline = Date().addingTimeInterval(1)
        var decoded: [DailyRollupStoreEntry] = []
        while Date() < deadline {
            if let data = try? Data(contentsOf: url),
               let rows = try? JSONDecoder().decode([DailyRollupStoreEntry].self, from: data) {
                decoded = rows
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.recovery, row.recovery)
        XCTAssertEqual(decoded.first?.day, row.day)
    }
}
