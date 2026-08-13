import XCTest
@testable import Atria

/// Handoff-9 CP2: the durable productive-slice receipt is the ONLY permission
/// for the fast (60 s) connected retry cadence. Everything else — a received
/// frame without durable frontier advance, a flush failure, an unchanged
/// frontier, a stale generation, a changed gap fingerprint, or no receipt at
/// all — keeps the existing 5-minute brake.
final class AtriaDurableProductiveSliceReceiptTests: XCTestCase {
    private let productive: TimeInterval = 60
    private let brake: TimeInterval = 300

    private func receipt(
        generation: UInt64 = 7,
        startFrontier: Double = 1_000,
        endFrontier: Double = 2_000,
        durableRows: Int = 500,
        liveRestoredAt: Double? = 5_000,
        gapFingerprint: String? = nil,
        status: AtriaHistoricalDurableProductiveSliceReceipt.Status = .productive
    ) -> AtriaHistoricalDurableProductiveSliceReceipt {
        .init(generation: generation,
              attemptStartedAtUnix: 4_000,
              startFrontierUnix: startFrontier,
              endFrontierUnix: endFrontier,
              durableRowsDelta: durableRows,
              flushBoundaryIdentity: "connected_raw_slice_test",
              liveRestoredAtUnix: liveRestoredAt,
              gapFingerprint: gapFingerprint,
              status: status,
              recordedAtUnix: 5_001)
    }

    private func interval(
        _ receipt: AtriaHistoricalDurableProductiveSliceReceipt?,
        currentGapFingerprint: String? = nil,
        lastCompletedGeneration: UInt64? = 7
    ) -> TimeInterval {
        AtriaBLEManager.connectedHandoffRetryInterval(
            receipt: receipt,
            currentGapFingerprint: currentGapFingerprint,
            lastCompletedGeneration: lastCompletedGeneration,
            productiveInterval: productive,
            brakeInterval: brake
        )
    }

    // MARK: - Earning the fast cadence

    func testExactDurableFrontierAdvanceWithLiveRestorationEarnsFastRetry() {
        XCTAssertEqual(interval(receipt()), productive)
    }

    func testMissingReceiptKeepsBrake() {
        XCTAssertEqual(interval(nil), brake)
    }

    // MARK: - A received frame is not progress

    func testRowsWithoutFrontierAdvanceKeepBrake() {
        // Stream5 frames arrived and even persisted rows, but the verified
        // frontier did not move past the attempt's captured start.
        XCTAssertEqual(
            interval(receipt(startFrontier: 2_000, endFrontier: 2_000)),
            brake
        )
        XCTAssertEqual(
            interval(receipt(startFrontier: 2_000, endFrontier: 1_500)),
            brake
        )
    }

    func testFlushFailureKeepsBrakeEvenWithRows() {
        XCTAssertEqual(interval(receipt(status: .failed)), brake)
    }

    func testNoProgressStatusKeepsBrake() {
        XCTAssertEqual(
            interval(receipt(durableRows: 0, status: .noProgress)),
            brake
        )
    }

    func testZeroDurableRowsKeepBrakeEvenIfMarkedProductive() {
        XCTAssertEqual(interval(receipt(durableRows: 0)), brake)
    }

    func testMissingLiveRestorationKeepsBrake() {
        XCTAssertEqual(interval(receipt(liveRestoredAt: nil)), brake)
    }

    func testNonFiniteFrontiersKeepBrake() {
        XCTAssertEqual(
            interval(receipt(startFrontier: .nan, endFrontier: 2_000)),
            brake
        )
        XCTAssertEqual(
            interval(receipt(startFrontier: 1_000, endFrontier: .infinity)),
            brake
        )
    }

    // MARK: - Scope invalidation

    func testStaleGenerationKeepsBrake() {
        XCTAssertEqual(
            interval(receipt(generation: 6), lastCompletedGeneration: 7),
            brake
        )
        XCTAssertEqual(interval(receipt(), lastCompletedGeneration: nil), brake)
    }

    func testChangedGapFingerprintKeepsBrake() {
        XCTAssertEqual(
            interval(receipt(gapFingerprint: "gap-a"),
                     currentGapFingerprint: "gap-b"),
            brake
        )
        XCTAssertEqual(
            interval(receipt(gapFingerprint: nil),
                     currentGapFingerprint: "gap-b"),
            brake
        )
        // Matching fingerprints (including nil == nil for the cursor-anchored
        // lane) preserve the earned cadence.
        XCTAssertEqual(
            interval(receipt(gapFingerprint: "gap-a"),
                     currentGapFingerprint: "gap-a"),
            productive
        )
    }

    // MARK: - Persistence

    // MARK: - Slice-start receipt + process-interruption self-heal (handoff-10 CP2B)

    private func startedReceipt(
        generation: UInt64 = 12,
        processInstanceID: String? = "process-a"
    ) -> AtriaHistoricalDurableProductiveSliceReceipt {
        var value = receipt(generation: generation,
                            endFrontier: 0,
                            durableRows: 0,
                            liveRestoredAt: nil,
                            status: .started)
        value.processInstanceID = processInstanceID
        return value
    }

    func testStartedReceiptFromAnotherProcessIsAnOrphanAndReArmsScheduling() throws {
        let orphan = startedReceipt(processInstanceID: "dead-process")
        XCTAssertTrue(orphan.isOrphanedStart(currentProcessInstanceID: "live-process"))
        XCTAssertFalse(orphan.isOrphanedStart(currentProcessInstanceID: "dead-process"),
                       "A .started row from the CURRENT process is in-flight, not orphaned")

        let suiteName = "AtriaSliceStartReArm-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        // A recent frontier + no ticket + no fresh debt normally reads .none —
        // the exact state a mid-slice kill leaves behind.
        defaults.set(Date().timeIntervalSince1970 - 60,
                     forKey: AtriaBLEManager.OfflineSyncDefaults.drainedThroughUnix)
        XCTAssertEqual(
            AtriaBLEManager.strapBacklogReason(defaults: defaults,
                                               processInstanceID: "live-process"),
            .none
        )
        AtriaBLEManager.storeDurableProductiveSliceReceipt(
            startedReceipt(processInstanceID: "dead-process"), defaults: defaults
        )
        XCTAssertEqual(
            AtriaBLEManager.strapBacklogReason(defaults: defaults,
                                               processInstanceID: "live-process"),
            .unresolvedSliceStart,
            "An orphaned slice start must keep catch-up scheduling armed"
        )
        // The same receipt seen by the writing process is NOT an orphan.
        XCTAssertEqual(
            AtriaBLEManager.strapBacklogReason(defaults: defaults,
                                               processInstanceID: "dead-process"),
            .none
        )
    }

    func testBacklogAuthorityOutranksOrphanedStart() throws {
        let suiteName = "AtriaSliceStartPriority-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        AtriaBLEManager.storeDurableProductiveSliceReceipt(
            startedReceipt(processInstanceID: "dead-process"), defaults: defaults
        )
        // A real range-loss ticket wins.
        defaults.set(true, forKey: AtriaBLEManager.OfflineSyncDefaults.rangeLossBackfillPending)
        XCTAssertEqual(
            AtriaBLEManager.strapBacklogReason(defaults: defaults,
                                               processInstanceID: "live-process"),
            .ticket
        )
        defaults.set(false, forKey: AtriaBLEManager.OfflineSyncDefaults.rangeLossBackfillPending)
        // A fresh verified caught-up cursor still reads caught-up: the strap
        // itself says there is nothing to drain right now, and the orphan
        // grants no backlog authority of its own.
        defaults.set(Date().timeIntervalSince1970,
                     forKey: AtriaBLEManager.OfflineSyncDefaults.flushDebtObservedAt)
        defaults.set(0, forKey: AtriaBLEManager.OfflineSyncDefaults.flushDebtPendingRecords)
        XCTAssertEqual(
            AtriaBLEManager.strapBacklogReason(defaults: defaults,
                                               processInstanceID: "live-process"),
            .none
        )
    }

    func testStartedReceiptNeverEarnsTheFastCadence() {
        XCTAssertEqual(
            interval(startedReceipt(), lastCompletedGeneration: 12),
            brake,
            "A slice start proves nothing about durable progress"
        )
    }

    func testTerminalReceiptReplacesSameGenerationStart() throws {
        let suiteName = "AtriaSliceStartTerminal-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        AtriaBLEManager.storeDurableProductiveSliceReceipt(
            startedReceipt(generation: 9), defaults: defaults
        )
        AtriaBLEManager.storeDurableProductiveSliceReceipt(
            receipt(generation: 9, status: .productive), defaults: defaults
        )
        XCTAssertEqual(
            AtriaBLEManager.loadDurableProductiveSliceReceipt(defaults: defaults)?.status,
            .productive
        )
        // And a NEWER generation's start replaces an older terminal.
        AtriaBLEManager.storeDurableProductiveSliceReceipt(
            startedReceipt(generation: 10), defaults: defaults
        )
        XCTAssertEqual(
            AtriaBLEManager.loadDurableProductiveSliceReceipt(defaults: defaults)?.status,
            .started
        )
        // A stale older-generation terminal FROM THE SAME PROCESS can never
        // restore itself.
        var staleSameProcess = receipt(generation: 9, status: .failed)
        staleSameProcess.processInstanceID = "process-a"
        AtriaBLEManager.storeDurableProductiveSliceReceipt(
            staleSameProcess, defaults: defaults
        )
        XCTAssertEqual(
            AtriaBLEManager.loadDurableProductiveSliceReceipt(defaults: defaults)?
                .generation,
            10
        )
    }

    /// Slice generations are process-local and reset at relaunch — physically
    /// observed: a prior run's generation-390 receipt swallowed every fresh
    /// process's gen-1..n writes. A different process instance's receipt is
    /// always replaceable; forward-only ordering applies within one process.
    func testNewProcessReceiptReplacesPriorProcessHighGeneration() throws {
        let suiteName = "AtriaSliceCrossProcess-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var oldProcess = receipt(generation: 390, status: .productive)
        oldProcess.processInstanceID = "old-process"
        AtriaBLEManager.storeDurableProductiveSliceReceipt(oldProcess, defaults: defaults)
        var newProcess = receipt(generation: 1, status: .productive)
        newProcess.processInstanceID = "new-process"
        AtriaBLEManager.storeDurableProductiveSliceReceipt(newProcess, defaults: defaults)
        let stored = try XCTUnwrap(
            AtriaBLEManager.loadDurableProductiveSliceReceipt(defaults: defaults)
        )
        XCTAssertEqual(stored.generation, 1)
        XCTAssertEqual(stored.processInstanceID, "new-process",
                       "The current process's truth supersedes a dead process's receipt")
        // Legacy (nil-process) rows are likewise replaceable by a tagged writer.
        defaults.removeObject(forKey: AtriaBLEManager.OfflineSyncDefaults.durableProductiveSliceReceipt)
        AtriaBLEManager.storeDurableProductiveSliceReceipt(
            receipt(generation: 390, status: .productive), defaults: defaults
        )
        AtriaBLEManager.storeDurableProductiveSliceReceipt(newProcess, defaults: defaults)
        XCTAssertEqual(
            AtriaBLEManager.loadDurableProductiveSliceReceipt(defaults: defaults)?
                .processInstanceID,
            "new-process"
        )
    }

    func testLegacyReceiptWithoutProcessFieldDecodesAndIsNeverAnOrphan() throws {
        // A handoff-9 era payload has no processInstanceID and no .started
        // status — it must decode and behave exactly as before.
        let legacyJSON = """
        {"generation":7,"attemptStartedAtUnix":4000,"startFrontierUnix":1000,
         "endFrontierUnix":2000,"durableRowsDelta":500,
         "flushBoundaryIdentity":"connected_raw_slice_test",
         "liveRestoredAtUnix":5000,"status":"productive","recordedAtUnix":5001}
        """
        let decoded = try JSONDecoder().decode(
            AtriaHistoricalDurableProductiveSliceReceipt.self,
            from: Data(legacyJSON.utf8)
        )
        XCTAssertEqual(decoded.status, .productive)
        XCTAssertNil(decoded.processInstanceID)
        XCTAssertFalse(decoded.isOrphanedStart(currentProcessInstanceID: "any"))
        XCTAssertEqual(interval(decoded), productive,
                       "Legacy productive receipts keep earning the fast cadence")
    }

    func testStoreReplacesForwardOnlyAndStaleGenerationCannotOverwrite() throws {
        let suiteName = "AtriaDurableProductiveSliceReceiptTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertNil(AtriaBLEManager.loadDurableProductiveSliceReceipt(defaults: defaults))
        let newer = receipt(generation: 9)
        AtriaBLEManager.storeDurableProductiveSliceReceipt(newer, defaults: defaults)
        XCTAssertEqual(
            AtriaBLEManager.loadDurableProductiveSliceReceipt(defaults: defaults),
            newer
        )

        // A stale callback from an older generation must not overwrite.
        AtriaBLEManager.storeDurableProductiveSliceReceipt(
            receipt(generation: 8, status: .failed), defaults: defaults
        )
        XCTAssertEqual(
            AtriaBLEManager.loadDurableProductiveSliceReceipt(defaults: defaults)?
                .generation,
            9
        )

        // The same generation's exact final boundary may replace (e.g. the
        // definitive terminal after an interim write).
        let sameGenerationFinal = receipt(generation: 9, status: .noProgress)
        AtriaBLEManager.storeDurableProductiveSliceReceipt(
            sameGenerationFinal, defaults: defaults
        )
        XCTAssertEqual(
            AtriaBLEManager.loadDurableProductiveSliceReceipt(defaults: defaults)?
                .status,
            .noProgress
        )

        // Corrupt payload fails closed to nil (→ brake at the gates).
        defaults.set(Data("garbage".utf8),
                     forKey: AtriaBLEManager.OfflineSyncDefaults.durableProductiveSliceReceipt)
        XCTAssertNil(AtriaBLEManager.loadDurableProductiveSliceReceipt(defaults: defaults))
    }

    // MARK: - Blocked admission states stay blocked regardless of cadence

    func testActiveWorkoutAndStaleHRRemainBlockedEvenWithFastCadence() {
        let now = Date(timeIntervalSince1970: 10_000)
        // Active explicit workout blocks admission outright.
        XCTAssertFalse(AtriaBLEManager.shouldAttemptAutomaticConnectedHistoricalHandoff(
            linkConnected: true,
            exactGapPending: true,
            verifiedMetricRecovery: true,
            activeExplicitWorkout: true,
            syncInProgress: false,
            connectedAt: now.addingTimeInterval(-600),
            hasContact: true,
            acceptedSampleCount: 100,
            lastAcceptedHRAt: now.addingTimeInterval(-5),
            requestedAt: now.addingTimeInterval(-600),
            lastAttemptAt: now.addingTimeInterval(-120),
            now: now,
            attemptCooldown: 60
        ))
        // Stale accepted HR blocks admission outright.
        XCTAssertFalse(AtriaBLEManager.shouldAttemptAutomaticConnectedHistoricalHandoff(
            linkConnected: true,
            exactGapPending: true,
            verifiedMetricRecovery: true,
            activeExplicitWorkout: false,
            syncInProgress: false,
            connectedAt: now.addingTimeInterval(-600),
            hasContact: true,
            acceptedSampleCount: 100,
            lastAcceptedHRAt: now.addingTimeInterval(-300),
            requestedAt: now.addingTimeInterval(-600),
            lastAttemptAt: now.addingTimeInterval(-120),
            now: now,
            attemptCooldown: 60
        ))
        // The earned 60-second cadence admits a productive follow-up attempt
        // that the 5-minute brake would still hold.
        XCTAssertTrue(AtriaBLEManager.shouldAttemptAutomaticConnectedHistoricalHandoff(
            linkConnected: true,
            exactGapPending: true,
            verifiedMetricRecovery: true,
            activeExplicitWorkout: false,
            syncInProgress: false,
            connectedAt: now.addingTimeInterval(-600),
            hasContact: true,
            acceptedSampleCount: 100,
            lastAcceptedHRAt: now.addingTimeInterval(-5),
            requestedAt: now.addingTimeInterval(-600),
            lastAttemptAt: now.addingTimeInterval(-90),
            now: now,
            attemptCooldown: 60
        ))
        XCTAssertFalse(AtriaBLEManager.shouldAttemptAutomaticConnectedHistoricalHandoff(
            linkConnected: true,
            exactGapPending: true,
            verifiedMetricRecovery: true,
            activeExplicitWorkout: false,
            syncInProgress: false,
            connectedAt: now.addingTimeInterval(-600),
            hasContact: true,
            acceptedSampleCount: 100,
            lastAcceptedHRAt: now.addingTimeInterval(-5),
            requestedAt: now.addingTimeInterval(-600),
            lastAttemptAt: now.addingTimeInterval(-90),
            now: now,
            attemptCooldown: 300
        ), "The 5-minute brake still holds a 90-second-old attempt")
    }

    /// Both connected-handoff gates must read the one receipt-computed
    /// interval — reintroducing a hardcoded cooldown at either site recreates
    /// the contradictory double gate this pass removed.
    func testBothGatesReadTheSharedReceiptComputedInterval() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria")
        let source = try String(
            contentsOf: root.appendingPathComponent("AtriaBLEManager.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains(
            "attemptCooldown: automaticConnectedHistoryRetryInterval()"
        ), "Eligibility gate must use the shared receipt-computed interval")
        XCTAssertTrue(source.contains(
            "connectedHandoffInterval: automaticConnectedHistoryRetryInterval()"
        ), "Transport throttle gate must use the shared receipt-computed interval")
    }
}
