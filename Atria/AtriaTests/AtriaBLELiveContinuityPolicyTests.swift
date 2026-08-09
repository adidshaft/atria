import XCTest
import CoreBluetooth
@testable import Atria

final class AtriaBLELiveContinuityPolicyTests: XCTestCase {
    func testEveryNewHistoryRequestDefersBehindRealtimeOwnership() {
        for (connected, connecting) in [
            (true, false),
            (false, true),
        ] {
            XCTAssertTrue(
                AtriaBLEManager
                    .shouldDeferHistoricalTransportForRealtimeContinuity(
                        linkConnected: connected,
                        linkConnecting: connecting,
                        syncInProgress: false
                    )
            )
        }

        XCTAssertFalse(
            AtriaBLEManager
                .shouldDeferHistoricalTransportForRealtimeContinuity(
                    linkConnected: false,
                    linkConnecting: false,
                    syncInProgress: false
                ),
            "a natural disconnect is the safe opportunity for queued history"
        )
        XCTAssertFalse(
            AtriaBLEManager
                .shouldDeferHistoricalTransportForRealtimeContinuity(
                    linkConnected: true,
                    linkConnecting: false,
                    syncInProgress: true
                ),
            "an already-active history generation must be able to finish"
        )

        let fence = AtriaBLECallbackEpochFence()
        let peripheralID = UUID()
        let exactObject = NSObject()
        XCTAssertFalse(fence.hasActiveOwner)
        _ = fence.activate(
            peripheralID: peripheralID,
            peripheralObjectID: ObjectIdentifier(exactObject)
        )
        XCTAssertTrue(fence.hasActiveOwner)
        XCTAssertTrue(
            AtriaBLEManager
                .shouldDeferHistoricalTransportForRealtimeContinuity(
                    linkConnected: fence.hasActiveOwner,
                    linkConnecting: false,
                    syncInProgress: false
                ),
            "a restored exact epoch must protect realtime before MainActor publishes the peripheral"
        )
        _ = fence.invalidate()
        XCTAssertFalse(fence.hasActiveOwner)
    }

    func testAttendedAndGeneralHistoryDeferWhileOnlyExactMotionBankTokenCanShareLive() throws {
        let source = try managerSource()
        let guardStart = try XCTUnwrap(source.range(
            of: "if connectedMotionBankRequestAuthority == nil,\n           Self.shouldDeferHistoricalTransportForRealtimeContinuity("
        ))
        let transactionStart = try XCTUnwrap(source.range(
            of: "return startOfflineHistoricalSync("
        ))
        XCTAssertLessThan(guardStart.lowerBound, transactionStart.lowerBound)

        let guardedTail = source[guardStart.lowerBound...]
        let guardedEnd = try XCTUnwrap(guardedTail.range(of: "return false"))
        let guardBody = guardedTail[..<guardedEnd.upperBound]
        XCTAssertTrue(guardBody.contains("explicitRequest: attendedHistoricalRequest"))
        XCTAssertTrue(guardBody.contains("explicitPostWorkoutBankRequest:"))
        XCTAssertTrue(guardBody.contains("preserveConnectedRealtimeOwner:"))
        XCTAssertTrue(guardBody.contains("no_history_command_no_cancel"))
        XCTAssertTrue(source.contains(
            "let exactRealtimeEpochOwned = bleCallbackEpochFence.hasActiveOwner"
        ))
        XCTAssertTrue(source.contains(
            "linkConnected: connectedLink || exactRealtimeEpochOwned"
        ))
        XCTAssertTrue(source.contains(
            "let transactionRealtimeEpochOwned = bleCallbackEpochFence.hasActiveOwner"
        ))
        XCTAssertTrue(source.contains(
            "let transactionStandingConnectOwned = connectedPeripheralRetainer"
        ))
        XCTAssertTrue(source.contains(
            ".claimHistoryTransportIfNoRetainedConnect("
        ))
        XCTAssertTrue(source.contains(
            "no_attempt_no_generation_no_phase_no_history_command_no_cancel"
        ))
        XCTAssertFalse(source.contains("deferred_realtime_owner_after_generation_arm"))
        XCTAssertFalse(
            source.contains("freshOwnerCutoverCompleted"),
            "callback-local cutover state must never bypass the global or atomic realtime-owner fences"
        )
        XCTAssertTrue(source.contains("let historyTransportClaimed: Bool"))
        XCTAssertTrue(source.contains(
            ".claimExclusiveConnectedCanonicalTransport("
        ))
        let requestStart = try XCTUnwrap(source.range(
            of: "func requestOfflineHistoricalSyncIfNeeded("
        ))
        let requestEnd = try XCTUnwrap(source.range(
            of: "private func armHistoryCapabilityQualification(",
            range: requestStart.upperBound..<source.endIndex
        ))
        let request = source[requestStart.lowerBound..<requestEnd.lowerBound]
        XCTAssertFalse(request.contains("shouldUseFreshHistoryOwnerCutover("))
        XCTAssertFalse(request.contains("beginFreshHistoryOwnerCutover("))

        let atomicRefusal = try XCTUnwrap(source.range(
            of: "guard historyTransportClaimed else {"
        ))
        let firstGenerationMutation = try XCTUnwrap(source.range(
            of: "// The launch intent is now represented by the active generation",
            range: atomicRefusal.upperBound..<source.endIndex
        ))
        let refusalBody = source[atomicRefusal.lowerBound..<firstGenerationMutation.lowerBound]
        XCTAssertFalse(refusalBody.contains("finishOfflineHistoricalSync"))
        XCTAssertFalse(refusalBody.contains("cancelPeripheralConnection"))
        XCTAssertFalse(refusalBody.contains("postHistoryLiveRestoration"))
    }

    func testConnectedAutomaticHistoryDefersUntilAnAllowedOwnerAlreadyExists() {
        XCTAssertTrue(
            AtriaBLEManager.shouldDeferAutomaticHistoryForLiveContinuity(
                linkConnected: true,
                syncInProgress: false,
                attendedRequest: false
            ),
            "automatic backlog work must not manufacture a gap in a healthy live link"
        )

        XCTAssertFalse(
            AtriaBLEManager.shouldDeferAutomaticHistoryForLiveContinuity(
                linkConnected: false,
                syncInProgress: false,
                attendedRequest: false
            ),
            "a natural link boundary may service queued history"
        )
        XCTAssertFalse(
            AtriaBLEManager.shouldDeferAutomaticHistoryForLiveContinuity(
                linkConnected: true,
                syncInProgress: true,
                attendedRequest: false
            ),
            "an already-current history owner must be allowed to continue"
        )
        XCTAssertFalse(
            AtriaBLEManager.shouldDeferAutomaticHistoryForLiveContinuity(
                linkConnected: true,
                syncInProgress: false,
                attendedRequest: true
            ),
            "the legacy automatic prefilter records attended priority; the global realtime-owner gate above still defers the transport"
        )
        XCTAssertFalse(
            AtriaBLEManager.shouldDeferAutomaticHistoryForLiveContinuity(
                linkConnected: true,
                syncInProgress: false,
                attendedRequest: false,
                nonDestructiveConnectedHistoryAllowed: true
            ),
            "the legacy automatic prefilter may pass a no-cancel request; the global realtime-owner gate above still defers every new history transport"
        )
    }

    func testMotionBankOffloadUsesTypedExactAuthorityNotConnectedHandoffFlag() throws {
        let source = try managerSource()
        let methodStart = try XCTUnwrap(source.range(
            of: "private func resumePendingWorkoutHistoricalMotionBankOffloadIfNeeded"
        ))
        let methodEnd = try XCTUnwrap(source.range(
            of: "/// Builds one replacement ticket",
            range: methodStart.upperBound..<source.endIndex
        ))
        let method = String(source[methodStart.lowerBound..<methodEnd.lowerBound])
        let requestStart = try XCTUnwrap(method.range(
            of: "let started: Bool = {"
        ))
        let requestEnd = try XCTUnwrap(method.range(
            of: "let updatedAttempts",
            range: requestStart.upperBound..<method.endIndex
        ))
        let request = String(method[requestStart.lowerBound..<requestEnd.lowerBound])

        XCTAssertTrue(request.contains("allowConnectedAutomaticHandoff: false"))
        XCTAssertFalse(request.contains("allowConnectedAutomaticHandoff: true"))
        XCTAssertTrue(request.contains("preserveConnectedRealtimeOwner: true"))
        XCTAssertTrue(request.contains(
            "transientConnectedMotionBankHistoryRequestAuthority"
        ))
        XCTAssertTrue(method.contains(
            "makeConnectedMotionBankHistoryRequestAuthority("
        ))
    }

    func testNonDestructiveHistoryFailureRetiresOnlyTheExactConnectedGeneration() {
        XCTAssertTrue(
            AtriaBLEManager.shouldFinishHistoricalFailureWithoutDisconnect(
                preservesConnectedRealtimeOwner: true,
                syncInProgress: true,
                expectedGeneration: 41,
                activeGeneration: 41,
                linkConnected: true
            )
        )
        XCTAssertFalse(
            AtriaBLEManager.shouldFinishHistoricalFailureWithoutDisconnect(
                preservesConnectedRealtimeOwner: false,
                syncInProgress: true,
                expectedGeneration: 41,
                activeGeneration: 41,
                linkConnected: true
            )
        )
        XCTAssertFalse(
            AtriaBLEManager.shouldFinishHistoricalFailureWithoutDisconnect(
                preservesConnectedRealtimeOwner: true,
                syncInProgress: true,
                expectedGeneration: 40,
                activeGeneration: 41,
                linkConnected: true
            )
        )
        XCTAssertFalse(
            AtriaBLEManager.shouldFinishHistoricalFailureWithoutDisconnect(
                preservesConnectedRealtimeOwner: true,
                syncInProgress: true,
                expectedGeneration: 41,
                activeGeneration: 41,
                linkConnected: false
            )
        )
    }

    func testConnectedMotionBankHistoryBudgetProtectsLiveHRAndHasAbsoluteCap() {
        let started = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(
            AtriaBLEManager.connectedMotionBankHistoryBudgetDisposition(
                startedAt: started,
                lastAcceptedHeartRateAt: started.addingTimeInterval(6),
                now: started.addingTimeInterval(7),
                liveSilenceLimit: 8,
                absoluteLimit: 90
            ),
            .keepServing
        )
        XCTAssertEqual(
            AtriaBLEManager.connectedMotionBankHistoryBudgetDisposition(
                startedAt: started,
                lastAcceptedHeartRateAt: started.addingTimeInterval(2),
                now: started.addingTimeInterval(10),
                liveSilenceLimit: 8,
                absoluteLimit: 90
            ),
            .finishForLiveHeartRateSilence
        )
        XCTAssertEqual(
            AtriaBLEManager.connectedMotionBankHistoryBudgetDisposition(
                startedAt: started,
                lastAcceptedHeartRateAt: started.addingTimeInterval(90),
                now: started.addingTimeInterval(90),
                liveSilenceLimit: 8,
                absoluteLimit: 90
            ),
            .finishForAbsoluteBudget
        )
        XCTAssertEqual(
            AtriaBLEManager.connectedMotionBankHistoryBudgetDisposition(
                startedAt: started,
                lastAcceptedHeartRateAt: started.addingTimeInterval(1),
                now: started.addingTimeInterval(2),
                liveSilenceLimit: 8,
                absoluteLimit: 90,
                powerPressureActive: true
            ),
            .finishForPowerPressure
        )
    }

    func testConnectedMotionBankPowerPressureParksAtBoundedCadence() {
        XCTAssertFalse(
            AtriaBLEManager
                .shouldParkConnectedMotionBankHistoryForPowerPressure(
                    thermalState: .nominal,
                    lowPowerModeEnabled: false
                )
        )
        XCTAssertTrue(
            AtriaBLEManager
                .shouldParkConnectedMotionBankHistoryForPowerPressure(
                    thermalState: .serious,
                    lowPowerModeEnabled: false
                )
        )
        XCTAssertTrue(
            AtriaBLEManager
                .shouldParkConnectedMotionBankHistoryForPowerPressure(
                    thermalState: .critical,
                    lowPowerModeEnabled: false
                )
        )
        XCTAssertTrue(
            AtriaBLEManager
                .shouldParkConnectedMotionBankHistoryForPowerPressure(
                    thermalState: .nominal,
                    lowPowerModeEnabled: true
                )
        )

        let now = Date(timeIntervalSince1970: 1_000)
        let first = AtriaBLEManager
            .connectedMotionBankHistoryPowerRetryNotBefore(
                existing: nil,
                now: now,
                interval: 60
            )
        XCTAssertEqual(first, now.addingTimeInterval(60))
        XCTAssertEqual(
            AtriaBLEManager.connectedMotionBankHistoryPowerRetryNotBefore(
                existing: first.addingTimeInterval(30),
                now: now,
                interval: 60
            ),
            first.addingTimeInterval(30),
            "a later episode deadline must never be shortened"
        )
    }

    func testPendingMotionBankMetadataSurvivesButCannotRecreateSameLinkAuthority() throws {
        let bank = AtriaBLEManager
            .coalescedPendingOfflineHistoricalSyncRequest(
                existing: nil,
                reason: "workout_motion_bank_offload",
                force: true,
                explicitRequest: false,
                explicitPostWorkoutBankRequest: true,
                preserveConnectedRealtimeOwner: true
            )
        let retained = AtriaBLEManager
            .coalescedPendingOfflineHistoricalSyncRequest(
                existing: bank,
                reason: "archive_warmup",
                force: false,
                explicitRequest: false
            )

        XCTAssertTrue(retained.force)
        XCTAssertTrue(retained.explicitPostWorkoutBankRequest)
        XCTAssertTrue(retained.preserveConnectedRealtimeOwner)
        XCTAssertEqual(retained.reason, "workout_motion_bank_offload")

        let source = try managerSource()
        XCTAssertTrue(source.contains(
            "transientConnectedRealtimeOwnerPreservation"
        ))
        XCTAssertFalse(
            source.contains(
                "let connectedMotionBankHistoryRequestAuthority: ConnectedMotionBankHistoryRequestAuthority"
            ),
            "the exact object/epoch token must never be persisted in the pending request"
        )
        XCTAssertEqual(
            source.components(
                separatedBy: "pending.preserveConnectedRealtimeOwner"
            ).count - 1,
            8,
            "every pending bank reissue must restore no-cutover/no-cancel authority"
        )
    }

    func testPowerPressureParksExactTicketBeforeHistoryRequestAndFinishesActiveLaneLocally() throws {
        let source = try managerSource()
        let selectorStart = try XCTUnwrap(source.range(
            of: "private func resumePendingWorkoutHistoricalMotionBankOffloadIfNeeded"
        ))
        let selectorEnd = try XCTUnwrap(source.range(
            of: "/// Builds one replacement ticket",
            range: selectorStart.upperBound..<source.endIndex
        ))
        let selector = String(
            source[selectorStart.lowerBound..<selectorEnd.lowerBound]
        )
        let powerPark = try XCTUnwrap(selector.range(
            of: "if powerPressureActive,\n           Self.historicalMotionBankOffloadEligible("
        ))
        let request = try XCTUnwrap(selector.range(
            of: "let started: Bool = {",
            range: powerPark.upperBound..<selector.endIndex
        ))
        XCTAssertLessThan(powerPark.lowerBound, request.lowerBound)
        let parkedTail = selector[powerPark.lowerBound...]
        let parkReturn = try XCTUnwrap(parkedTail.range(of: "return false"))
        let parked = parkedTail[..<parkReturn.upperBound]
        XCTAssertTrue(parked.contains(
            "workoutHistoricalMotionBankTransportDeferredTicketIDKey"
        ))
        XCTAssertTrue(parked.contains(
            "connectedMotionBankHistoryPowerRetryNotBefore("
        ))
        XCTAssertTrue(parked.contains(
            "armWorkoutHistoricalMotionBankIfPossible("
        ))
        XCTAssertTrue(parked.contains(
            "prioritizePresentCaptureOverProcessRetry: true"
        ))
        XCTAssertTrue(parked.contains("return false"))
        XCTAssertFalse(parked.contains("requestOfflineHistoricalSyncIfNeeded("))
        XCTAssertFalse(parked.contains("markOffloadAttempt("))
        XCTAssertFalse(parked.contains(
            "workoutHistoricalMotionBankLastOffloadStartedAtKey"
        ))
        XCTAssertFalse(parked.contains("cancelPeripheralConnection("))
        XCTAssertFalse(parked.contains("rebuildCentralForWedgedSessionOnce("))
        XCTAssertTrue(source.contains(
            "reason: \"fresh_accepted_hr_prearm\",\n                    prioritizePresentCaptureOverProcessRetry: Self"
        ), "the post-stop throttle edge must still rearm present capture under power pressure")
        XCTAssertTrue(source.contains(
            "if !workoutHistoricalMotionBankArmed {\n                armWorkoutHistoricalMotionBankIfPossible("
        ), "an already-armed bank must not rewrite duty-cycle defaults on every HR")

        let budgetStart = try XCTUnwrap(source.range(
            of: "private func armConnectedMotionBankHistoryBudget("
        ))
        let budgetEnd = try XCTUnwrap(source.range(
            of: "private func resumePendingWorkoutHistoricalMotionBankOffloadIfNeeded",
            range: budgetStart.upperBound..<source.endIndex
        ))
        let budget = String(source[budgetStart.lowerBound..<budgetEnd.lowerBound])
        XCTAssertTrue(budget.contains("case .finishForPowerPressure:"))
        XCTAssertTrue(budget.contains(
            "connected_motion_bank_power_pressure"
        ))
        XCTAssertTrue(budget.contains(
            "finishConnectedHistoryFailureWithoutDisconnectIfNeeded("
        ))
        XCTAssertFalse(budget.contains("cancelPeripheralConnection("))
        XCTAssertFalse(budget.contains("rebuildCentralForWedgedSessionOnce("))
    }

    func testWorkoutPreemptionEndsSharedHistoryWithoutDisconnectingHeartRate() throws {
        XCTAssertEqual(
            AtriaBLEManager.workoutHistoricalTransportPreemptionDisposition(
                syncInProgress: true,
                historyProbeActive: false,
                preservesConnectedRealtimeOwner: true,
                linkConnected: true
            ),
            .finishPreservingRealtimeOwner
        )
        XCTAssertEqual(
            AtriaBLEManager.workoutHistoricalTransportPreemptionDisposition(
                syncInProgress: true,
                historyProbeActive: false,
                preservesConnectedRealtimeOwner: false,
                linkConnected: true
            ),
            .disconnectConnectedHistoryOwner
        )
        XCTAssertEqual(
            AtriaBLEManager.workoutHistoricalTransportPreemptionDisposition(
                syncInProgress: true,
                historyProbeActive: false,
                preservesConnectedRealtimeOwner: true,
                linkConnected: false
            ),
            .interruptOfflineHistoryOwner
        )
        XCTAssertEqual(
            AtriaBLEManager.workoutHistoricalTransportPreemptionDisposition(
                syncInProgress: false,
                historyProbeActive: false,
                preservesConnectedRealtimeOwner: false,
                linkConnected: true
            ),
            .noHistoryOwner
        )

        let source = try managerSource()
        let start = try XCTUnwrap(source.range(
            of: "private func yieldHistoricalTransportToExplicitWorkoutIfNeeded("
        ))
        let end = try XCTUnwrap(source.range(
            of: "/// Release the lease on successful workout stop",
            range: start.upperBound..<source.endIndex
        ))
        let method = String(source[start.lowerBound..<end.lowerBound])
        let localFinish = try XCTUnwrap(method.range(
            of: "finishConnectedHistoryFailureWithoutDisconnectIfNeeded("
        ))
        let radioCancel = try XCTUnwrap(method.range(
            of: "cancelPeripheralConnection("
        ))
        XCTAssertLessThan(localFinish.lowerBound, radioCancel.lowerBound)
        XCTAssertTrue(method.contains(
            "Never fall through to a physical cancel"
        ))
        XCTAssertTrue(method.contains(
            "preserveConnectedRealtimeOwner: preservesRealtimeOwner"
        ))
    }

    func testNonDestructiveHistoryFailuresCannotReachARadioCancel() throws {
        let source = try managerSource()
        XCTAssertTrue(source.contains(
            "offlineHistoricalSyncPreservesConnectedRealtimeOwner ="
        ))
        XCTAssertTrue(source.contains(
            "offlineHistoricalSyncPreservesConnectedRealtimeOwner =\n            activeConnectedMotionBankHistoryAuthority("
        ))
        for failure in [
            "history_background_lease_expired_preserve_realtime",
            "history_idle_timeout_gatt_heartbeat_preserve_realtime",
            "history_connected_slice_live_silence_preserve_realtime",
            "history_idle_timeout_preserve_realtime",
            "history_realtime_stop_write_timeout_preserve_realtime",
            "history_start_timeout_preserve_realtime",
            "history_first_frame_timeout_preserve_realtime",
            "history_drain_failed_preserve_realtime"
        ] {
            XCTAssertTrue(
                source.contains(failure),
                "\(failure) must retire local history before a cancel path"
            )
        }
        XCTAssertTrue(source.contains(
            "if !preservesConnectedRealtimeOwner,\n                   !reconnectRequested"
        ))
    }

    func testPreexistingDelayedRecoveryRetiresExactMotionBankLocally() throws {
        let source = try managerSource()
        let methodStart = try XCTUnwrap(source.range(
            of: "private func requestFreshScanReconnect(peripheral target: CBPeripheral,"
        ))
        let methodEnd = try XCTUnwrap(source.range(
            of: "private func recoveryReconnectDelay(",
            range: methodStart.upperBound..<source.endIndex
        ))
        let method = String(source[methodStart.lowerBound..<methodEnd.lowerBound])
        let exactGuard = try XCTUnwrap(method.range(
            of: "activeConnectedMotionBankHistoryAuthority("
        ))
        let localFinish = try XCTUnwrap(method.range(
            of: "delayed_recovery_preempted_connected_motion_bank_preserve_realtime",
            range: exactGuard.upperBound..<method.endIndex
        ))
        let firstGattMutation = try XCTUnwrap(method.range(
            of: "self.realtimeArmed = false",
            range: localFinish.upperBound..<method.endIndex
        ))
        XCTAssertLessThan(exactGuard.lowerBound, localFinish.lowerBound)
        XCTAssertLessThan(localFinish.lowerBound, firstGattMutation.lowerBound)
        XCTAssertTrue(
            String(method[localFinish.lowerBound..<firstGattMutation.lowerBound])
                .contains("return"),
            "an old delayed task must stop before GATT mutation, cancel, scan, or rebuild"
        )
    }

    func testExactMotionBankShareIsCanonicalGenerationBoundAndCompactOnly() throws {
        let source = try managerSource()
        XCTAssertTrue(source.contains(
            "private struct ConnectedMotionBankHistoryRequestAuthority"
        ))
        XCTAssertTrue(source.contains("let ticketID: String"))
        XCTAssertTrue(source.contains("let strapIdentifier: String"))
        XCTAssertTrue(source.contains(
            "let callbackSource: AtriaBLECallbackEpochFence.Source"
        ))
        XCTAssertTrue(source.contains(
            "private struct ConnectedMotionBankHistoryGenerationAuthority"
        ))
        XCTAssertTrue(source.contains(
            ".claimExclusiveConnectedCanonicalTransport("
        ))
        XCTAssertTrue(source.contains(
            "activeConnectedMotionBankHistoryGenerationAuthority = .init("
        ))
        XCTAssertTrue(source.contains(
            "connectedMotionBankHistoryRequestAuthorityIsValid("
        ))
        XCTAssertTrue(source.contains(
            "connected_motion_bank_authority_lost_before_command"
        ))
        XCTAssertTrue(source.contains(
            "if !compactMotionBankOnly,\n           terminalAndLiveRestored && offlineHistoricalSyncReachedTerminal"
        ))
        XCTAssertTrue(source.contains(
            "continue_exact_ticket_compact_only_no_projection_scan"
        ))
        XCTAssertTrue(source.contains(
            "Standard 2A37 HR/RR remains live"
        ))
    }

    func testForegroundGlanceRetryConsumesOneFreshHeartRateEdgeOnly() {
        var gate = AtriaBLEForegroundGlanceCheckpointRetryGate()

        gate.recordForegroundAttempt(started: false)
        XCTAssertTrue(gate.isAwaitingFreshHeartRate)
        XCTAssertFalse(
            gate.consumeAfterAcceptedHeartRate(applicationIsActive: false),
            "a packet received after backgrounding must not reopen glance work"
        )
        XCTAssertFalse(gate.isAwaitingFreshHeartRate)
        XCTAssertFalse(
            gate.consumeAfterAcceptedHeartRate(applicationIsActive: true),
            "the background packet must consume the edge instead of leaving a hot-loop retry"
        )

        gate.recordForegroundAttempt(started: false)
        XCTAssertTrue(
            gate.consumeAfterAcceptedHeartRate(applicationIsActive: true),
            "the first foreground accepted HR gets the one retry"
        )
        XCTAssertFalse(gate.isAwaitingFreshHeartRate)
        XCTAssertFalse(
            gate.consumeAfterAcceptedHeartRate(applicationIsActive: true),
            "later one-Hz HR packets must not retry"
        )

        gate.recordForegroundAttempt(started: true)
        XCTAssertFalse(gate.isAwaitingFreshHeartRate)
        XCTAssertFalse(
            gate.consumeAfterAcceptedHeartRate(applicationIsActive: true),
            "a successful first foreground attempt must not arm a redundant retry"
        )
    }

    func testArchiveWarmFirstRefusalRetriesExactlyOnceBeforeEightSecondLimit() {
        let now = Date(timeIntervalSince1970: 10_000)
        var gate = AtriaBLEConnectedMotionBankArchiveWarmRetryGate()
        gate.hold(ticketID: "ticket-a", now: now, waitLimit: 8)

        XCTAssertTrue(gate.isHolding)
        XCTAssertTrue(gate.shouldSuppressHotPath(
            now: now.addingTimeInterval(7.999),
            applicationIsActive: true,
            archiveStillWarming: true
        ))
        XCTAssertEqual(
            gate.resolveWarmReady(now: now.addingTimeInterval(7.999)),
            .retry(ticketID: "ticket-a")
        )
        XCTAssertEqual(gate.resolveWarmReady(now: now), .none)
        XCTAssertFalse(gate.isHolding)
    }

    func testArchiveWarmFirstRefusalFallsBackAtLimitFailureAndBackground() {
        let now = Date(timeIntervalSince1970: 20_000)
        var timedOut = AtriaBLEConnectedMotionBankArchiveWarmRetryGate()
        timedOut.hold(ticketID: "timeout", now: now, waitLimit: 8)
        XCTAssertFalse(timedOut.shouldSuppressHotPath(
            now: now.addingTimeInterval(8),
            applicationIsActive: true,
            archiveStillWarming: true
        ))
        XCTAssertEqual(
            timedOut.resolveWarmReady(now: now.addingTimeInterval(8)),
            .rearm(ticketID: "timeout")
        )

        var failed = AtriaBLEConnectedMotionBankArchiveWarmRetryGate()
        failed.hold(ticketID: "failed", now: now, waitLimit: 8)
        XCTAssertEqual(
            failed.resolveFallback(),
            .rearm(ticketID: "failed")
        )
        XCTAssertEqual(failed.resolveFallback(), .none)

        var backgrounded = AtriaBLEConnectedMotionBankArchiveWarmRetryGate()
        backgrounded.hold(ticketID: "background", now: now, waitLimit: 8)
        XCTAssertFalse(backgrounded.shouldSuppressHotPath(
            now: now.addingTimeInterval(1),
            applicationIsActive: false,
            archiveStillWarming: true
        ))
        XCTAssertEqual(
            backgrounded.resolveFallback(expectedTicketID: "background"),
            .rearm(ticketID: "background")
        )
    }

    func testAdmissionLedgerFirstRefusalRetriesOnceOrFallsBackAtEightSeconds() {
        let now = Date(timeIntervalSince1970: 25_000)
        var ready = AtriaBLEConnectedMotionBankArchiveWarmRetryGate()
        ready.hold(ticketID: "ledger-ready", now: now, waitLimit: 8)
        XCTAssertEqual(
            ready.resolveReady(now: now.addingTimeInterval(0.2)),
            .retry(ticketID: "ledger-ready")
        )
        XCTAssertEqual(ready.resolveReady(now: now), .none)

        var timedOut = AtriaBLEConnectedMotionBankArchiveWarmRetryGate()
        timedOut.hold(ticketID: "ledger-timeout", now: now, waitLimit: 8)
        XCTAssertEqual(
            timedOut.resolveReady(now: now.addingTimeInterval(8)),
            .rearm(ticketID: "ledger-timeout")
        )

        var failed = AtriaBLEConnectedMotionBankArchiveWarmRetryGate()
        failed.hold(ticketID: "ledger-failed", now: now, waitLimit: 8)
        XCTAssertEqual(
            failed.resolveFallback(expectedTicketID: "ledger-failed"),
            .rearm(ticketID: "ledger-failed")
        )
        XCTAssertEqual(failed.resolveFallback(), .none)
    }

    func testPreFreshHRArmFirstRefusalIsOneShotAndBounded() {
        let now = Date(timeIntervalSince1970: 30_000)
        var gate = AtriaBLEConnectedMotionBankPreFreshHRArmGate()

        XCTAssertTrue(gate.hold(
            ticketID: "ticket-a",
            now: now,
            waitLimit: 8
        ))
        XCTAssertFalse(gate.hold(
            ticketID: "ticket-a",
            now: now.addingTimeInterval(1),
            waitLimit: 8
        ), "one-Hz callbacks must not extend the reservation")
        XCTAssertTrue(gate.blocksArm(
            ticketID: "ticket-a",
            now: now.addingTimeInterval(7.999)
        ))
        XCTAssertEqual(
            gate.consumeForAcceptedHeartRate(),
            "ticket-a"
        )
        XCTAssertNil(gate.consumeForAcceptedHeartRate())
        XCTAssertFalse(gate.isHolding)

        XCTAssertTrue(gate.hold(
            ticketID: "ticket-b",
            now: now,
            waitLimit: 8
        ))
        XCTAssertFalse(gate.blocksArm(
            ticketID: "ticket-b",
            now: now.addingTimeInterval(8)
        ))
        XCTAssertEqual(
            gate.resolveFallback(expectedTicketID: "ticket-b"),
            "ticket-b"
        )
        XCTAssertNil(gate.resolveFallback())
    }

    func testPreFreshHRReservationPrecedesSuccessorArmAndTypedSelector()
        throws {
        let source = try managerSource()
        let armStart = try XCTUnwrap(source.range(
            of: "private func armWorkoutHistoricalMotionBankIfPossible("
        ))
        let armEnd = try XCTUnwrap(source.range(
            of: "private func checkpointDailyHistoricalMotionBankIfNeeded(",
            range: armStart.upperBound..<source.endIndex
        ))
        let arm = String(source[armStart.lowerBound..<armEnd.lowerBound])
        let deferred = try XCTUnwrap(arm.range(
            of: "let firstAttemptTransportDeferred"
        ))
        let reservation = try XCTUnwrap(arm.range(
            of: "connectedMotionBankPreFreshHRArmGate.blocksArm("
        ))
        let radioWrite = try XCTUnwrap(arm.range(
            of: "Cmd.toggleIMUModeHistorical"
        ))
        XCTAssertLessThan(deferred.lowerBound, reservation.lowerBound)
        XCTAssertLessThan(reservation.lowerBound, radioWrite.lowerBound)

        let acceptedStart = try XCTUnwrap(source.range(
            of: "private func acceptHeartRate(_ rate: Int, at sampleTime: Date)"
        ))
        let acceptedEnd = try XCTUnwrap(source.range(
            of: "private func beginAcceptedHeartRateBatch()",
            range: acceptedStart.upperBound..<source.endIndex
        ))
        let accepted = String(
            source[acceptedStart.lowerBound..<acceptedEnd.lowerBound]
        )
        let consume = try XCTUnwrap(accepted.range(
            of: "consumeConnectedMotionBankPreFreshHRFirstRefusalForSelector()"
        ))
        let selector = try XCTUnwrap(accepted.range(
            of: "resumePendingWorkoutHistoricalMotionBankOffloadIfNeeded("
        ))
        XCTAssertLessThan(consume.lowerBound, selector.lowerBound)
        XCTAssertFalse(arm.contains("cancelPeripheralConnection("))
        XCTAssertFalse(arm.contains("rebuildCentralForWedgedSessionOnce("))
    }

    func testArchiveWarmFirstRefusalIsTypedBoundedAndNonDestructive() throws {
        let source = try managerSource()
        let ready = try XCTUnwrap(source.range(
            of: "self.historicalArchiveWarmState = .ready"
        ))
        let typedRetry = try XCTUnwrap(source.range(
            of: "self.resumeConnectedMotionBankAfterArchiveWarmReadyIfNeeded()",
            range: ready.upperBound..<source.endIndex
        ))
        let genericRetry = try XCTUnwrap(source.range(
            of: "self.resumePendingForcedHistoricalSyncAfterLivePersistenceIfNeeded(",
            range: typedRetry.upperBound..<source.endIndex
        ))
        XCTAssertLessThan(typedRetry.lowerBound, genericRetry.lowerBound)

        let selectorStart = try XCTUnwrap(source.range(
            of: "private func resumePendingWorkoutHistoricalMotionBankOffloadIfNeeded("
        ))
        let selectorEnd = try XCTUnwrap(source.range(
            of: "private func repairTransportOnlyClearedWorkoutMotionTicketIfNeeded",
            range: selectorStart.upperBound..<source.endIndex
        ))
        let selector = String(
            source[selectorStart.lowerBound..<selectorEnd.lowerBound]
        )
        let expectedGate = try XCTUnwrap(selector.range(
            of: "ticket?.id != expectedArchiveWarmTicketID"
        ))
        let authority = try XCTUnwrap(selector.range(
            of: "makeConnectedMotionBankHistoryRequestAuthority("
        ))
        let request = try XCTUnwrap(selector.range(
            of: "requestOfflineHistoricalSyncIfNeeded("
        ))
        XCTAssertLessThan(expectedGate.lowerBound, authority.lowerBound)
        XCTAssertLessThan(authority.lowerBound, request.lowerBound)
        XCTAssertTrue(selector.contains("warmFirstRefusalHeld"))
        XCTAssertTrue(selector.contains("|| warmFirstRefusalHeld"))
        XCTAssertTrue(selector.contains(
            "transientConnectedMotionBankArchiveWarmDeferredTicketID"
        ))

        let helperStart = try XCTUnwrap(source.range(
            of: "private func releaseConnectedMotionBankArchiveWarmFirstRefusal("
        ))
        let helperEnd = try XCTUnwrap(source.range(
            of: "private func resumePendingWorkoutHistoricalMotionBankOffloadIfNeeded(",
            range: helperStart.upperBound..<source.endIndex
        ))
        let helpers = String(source[helperStart.lowerBound..<helperEnd.lowerBound])
        XCTAssertTrue(helpers.contains("historicalArchiveWarmReplayWaitLimit"))
        XCTAssertTrue(helpers.contains(
            "resumePendingWorkoutHistoricalMotionBankOffloadIfNeeded("
        ))
        XCTAssertFalse(helpers.contains("requestOfflineHistoricalSyncIfNeeded("))
        XCTAssertFalse(helpers.contains("cancelPeripheralConnection("))
        XCTAssertFalse(helpers.contains("rebuildCentralForWedgedSessionOnce("))
        XCTAssertFalse(helpers.contains("HistoricalArchive."))
    }

    func testAdmissionLedgerReadyGivesExactMotionTicketFirstRefusal() throws {
        let source = try managerSource()
        let ready = try XCTUnwrap(source.range(
            of: "self.historicalAdmissionLedger = ledger"
        ))
        let typedRetry = try XCTUnwrap(source.range(
            of: "self.resumeConnectedMotionBankAfterAdmissionLedgerReadyIfNeeded()",
            range: ready.upperBound..<source.endIndex
        ))
        let genericRetry = try XCTUnwrap(source.range(
            of: "self.resumePendingForcedHistoricalSyncAfterLivePersistenceIfNeeded(",
            range: typedRetry.upperBound..<source.endIndex
        ))
        XCTAssertLessThan(typedRetry.lowerBound, genericRetry.lowerBound)

        let selectorStart = try XCTUnwrap(source.range(
            of: "private func resumePendingWorkoutHistoricalMotionBankOffloadIfNeeded("
        ))
        let selectorEnd = try XCTUnwrap(source.range(
            of: "private func repairTransportOnlyClearedWorkoutMotionTicketIfNeeded",
            range: selectorStart.upperBound..<source.endIndex
        ))
        let selector = String(
            source[selectorStart.lowerBound..<selectorEnd.lowerBound]
        )
        let exactTicket = try XCTUnwrap(selector.range(
            of: "ticket?.id != expectedAdmissionLedgerTicketID"
        ))
        let authority = try XCTUnwrap(selector.range(
            of: "makeConnectedMotionBankHistoryRequestAuthority("
        ))
        XCTAssertLessThan(exactTicket.lowerBound, authority.lowerBound)
        XCTAssertTrue(selector.contains(
            "requestResult.admissionLedgerDeferredTicketID == ticket.id"
        ))
        XCTAssertTrue(selector.contains("admissionLedgerFirstRefusalHeld"))
        XCTAssertTrue(selector.contains("|| admissionLedgerFirstRefusalHeld"))

        let requestGate = try XCTUnwrap(source.range(
            of: "if !offlineHistoricalSyncInProgress,\n           !prepareHistoricalAdmissionLedgerIfNeeded(reason: reason)"
        ))
        let requestGateBody = String(
            source[requestGate.lowerBound...].prefix(1_600)
        )
        XCTAssertTrue(requestGateBody.contains(
            "historicalAdmissionLedgerPreparationTask != nil"
        ))
        XCTAssertTrue(requestGateBody.contains(
            "transientConnectedMotionBankHistoryRequestAuthority"
        ))
        XCTAssertTrue(requestGateBody.contains(
            "transientConnectedMotionBankAdmissionLedgerDeferredTicketID"
        ))

        let helperStart = try XCTUnwrap(source.range(
            of: "private func releaseConnectedMotionBankAdmissionLedgerFirstRefusal("
        ))
        let helperEnd = try XCTUnwrap(source.range(
            of: "private func resumePendingWorkoutHistoricalMotionBankOffloadIfNeeded(",
            range: helperStart.upperBound..<source.endIndex
        ))
        let helpers = String(source[helperStart.lowerBound..<helperEnd.lowerBound])
        XCTAssertTrue(helpers.contains("historicalArchiveWarmReplayWaitLimit"))
        XCTAssertTrue(helpers.contains(
            "resumePendingWorkoutHistoricalMotionBankOffloadIfNeeded("
        ))
        XCTAssertFalse(helpers.contains("requestOfflineHistoricalSyncIfNeeded("))
        XCTAssertFalse(helpers.contains("cancelPeripheralConnection("))
        XCTAssertFalse(helpers.contains("rebuildCentralForWedgedSessionOnce("))
        XCTAssertFalse(helpers.contains("HistoricalArchive."))
    }

    func testLocalDependenciesResumeOnlyThroughExpectedMotionTicket() throws {
        let source = try managerSource()
        let selectorStart = try XCTUnwrap(source.range(
            of: "private func resumePendingWorkoutHistoricalMotionBankOffloadIfNeeded("
        ))
        let selectorEnd = try XCTUnwrap(source.range(
            of: "private func repairTransportOnlyClearedWorkoutMotionTicketIfNeeded",
            range: selectorStart.upperBound..<source.endIndex
        ))
        let selector = String(
            source[selectorStart.lowerBound..<selectorEnd.lowerBound]
        )
        let expected = try XCTUnwrap(selector.range(
            of: "ticket?.id != expectedLocalDependencyTicketID"
        ))
        let authority = try XCTUnwrap(selector.range(
            of: "makeConnectedMotionBankHistoryRequestAuthority("
        ))
        XCTAssertLessThan(expected.lowerBound, authority.lowerBound)
        XCTAssertTrue(selector.contains("requestResult.localDependency"))
        XCTAssertTrue(selector.contains("localDependencyFirstRefusal"))
        XCTAssertTrue(selector.contains("|| localDependencyFirstRefusal != nil"))

        XCTAssertTrue(source.contains("dependency: .orphanArchive"))
        XCTAssertTrue(source.contains("dependency: .terminalMaterialization"))
        XCTAssertTrue(source.contains("dependency: .capabilityQualification"))
        XCTAssertTrue(source.contains(
            "transientConnectedMotionBankHistoryRequestAuthority"
        ))

        let localHelperStart = try XCTUnwrap(source.range(
            of: "private func releaseConnectedMotionBankLocalDependencyFirstRefusal("
        ))
        let localHelperEnd = try XCTUnwrap(source.range(
            of: "private func resumePendingWorkoutHistoricalMotionBankOffloadIfNeeded(",
            range: localHelperStart.upperBound..<source.endIndex
        ))
        let helpers = String(
            source[localHelperStart.lowerBound..<localHelperEnd.lowerBound]
        )
        XCTAssertTrue(helpers.contains("historicalArchiveWarmReplayWaitLimit"))
        XCTAssertTrue(helpers.contains("expectedLocalDependencyTicketID"))
        XCTAssertTrue(helpers.contains(
            "terminalMaterializationMotionBankReleaseInProgress = true"
        ))
        XCTAssertFalse(helpers.contains("requestOfflineHistoricalSyncIfNeeded("))
        XCTAssertFalse(helpers.contains("cancelPeripheralConnection("))
        XCTAssertFalse(helpers.contains("rebuildCentralForWedgedSessionOnce("))
        XCTAssertFalse(helpers.contains("HistoricalArchive."))
    }

    func testCapabilityQualificationTerminalCallbacksPermitOneLaterRetry() {
        let error = AtriaBLEManager
            .historyCapabilityQualificationCallbackDisposition(
                callbackMatchesQualification: true,
                targetedDiscoveryIssued: true,
                hasStrapService: false,
                hasError: true
            )
        XCTAssertEqual(error, .terminalFailure)

        let targetedNoService = AtriaBLEManager
            .historyCapabilityQualificationCallbackDisposition(
                callbackMatchesQualification: true,
                targetedDiscoveryIssued: true,
                hasStrapService: false,
                hasError: false
            )
        XCTAssertEqual(targetedNoService, .terminalFailure)

        for terminal in [error, targetedNoService] {
            XCTAssertEqual(terminal, .terminalFailure)
            XCTAssertEqual(
                AtriaBLEManager
                    .historyCapabilityQualificationCallbackDisposition(
                        callbackMatchesQualification: true,
                        targetedDiscoveryIssued: false,
                        hasStrapService: false,
                        hasError: false
                    ),
                .requestTargetedDiscovery,
                "terminal cleanup must reset the issued latch so the next intentional exact-ticket retry can discover once"
            )
        }
        XCTAssertEqual(
            AtriaBLEManager
                .historyCapabilityQualificationCallbackDisposition(
                    callbackMatchesQualification: false,
                    targetedDiscoveryIssued: true,
                    hasStrapService: false,
                    hasError: true
                ),
            .ignore,
            "an unrelated peripheral callback cannot release the exact ticket"
        )
    }

    func testCapabilityQualificationTerminalsClearBeforeTypedRelease() throws {
        let source = try managerSource()
        let cleanupStart = try XCTUnwrap(source.range(
            of: "private func clearHistoryCapabilityQualification("
        ))
        let armStart = try XCTUnwrap(source.range(
            of: "private func armHistoryCapabilityQualification(",
            range: cleanupStart.upperBound..<source.endIndex
        ))
        let cleanup = String(
            source[cleanupStart.lowerBound..<armStart.lowerBound]
        )
        XCTAssertTrue(cleanup.contains(
            "historyCapabilityQualificationFallbackTask?.cancel()"
        ))
        XCTAssertTrue(cleanup.contains(
            "historyCapabilityQualificationFallbackTask = nil"
        ))
        XCTAssertTrue(cleanup.contains(
            "historyCapabilityQualificationPeripheralID = nil"
        ))
        XCTAssertTrue(cleanup.contains(
            "historyCapabilityQualificationDiscoveryIssued = false"
        ))

        let callbackStart = try XCTUnwrap(source.range(
            of: "private func handleHistoryCapabilityServiceDiscovery("
        ))
        let callbackEnd = try XCTUnwrap(source.range(
            of: "private func beginFreshHistoryOwnerCutover(",
            range: callbackStart.upperBound..<source.endIndex
        ))
        let callback = String(
            source[callbackStart.lowerBound..<callbackEnd.lowerBound]
        )
        let successCleanup = try XCTUnwrap(callback.range(
            of: "clearHistoryCapabilityQualification("
        ))
        let typedResume = try XCTUnwrap(callback.range(
            of: "resumeConnectedMotionBankAfterLocalDependencyIfNeeded("
        ))
        let genericResume = try XCTUnwrap(callback.range(
            of: "scheduleRangeLossBackfillIfNeeded("
        ))
        XCTAssertLessThan(successCleanup.lowerBound, typedResume.lowerBound)
        XCTAssertLessThan(typedResume.lowerBound, genericResume.lowerBound)

        let terminal = try XCTUnwrap(callback.range(of: "case .terminalFailure:"))
        let terminalBody = String(callback[terminal.lowerBound...])
        let terminalCleanup = try XCTUnwrap(terminalBody.range(
            of: "clearHistoryCapabilityQualification("
        ))
        let terminalRelease = try XCTUnwrap(terminalBody.range(
            of: "releaseConnectedMotionBankLocalDependencyFirstRefusal("
        ))
        XCTAssertLessThan(terminalCleanup.lowerBound, terminalRelease.lowerBound)
        XCTAssertFalse(terminalBody.contains("requestOfflineHistoricalSyncIfNeeded("))
        XCTAssertFalse(terminalBody.contains("startOfflineHistoricalSync("))
        XCTAssertFalse(terminalBody.contains("cancelPeripheralConnection("))
        XCTAssertFalse(terminalBody.contains("rebuildCentralForWedgedSessionOnce("))
    }

    func testEveryTerminalMaterializationReleaseOffersTypedFirstRefusal() throws {
        let source = try managerSource()
        XCTAssertEqual(
            source.components(
                separatedBy:
                    "historicalConsumerMaterializationInFlight = false"
            ).count - 1,
            2,
            "only the property initializer and centralized release helper may write false"
        )
        let releaseStart = try XCTUnwrap(source.range(
            of: "private func releaseHistoricalConsumerMaterializationOwner("
        ))
        let finishStart = try XCTUnwrap(source.range(
            of: "private func finishHistoricalConsumerMaterialization(",
            range: releaseStart.upperBound..<source.endIndex
        ))
        let release = String(source[releaseStart.lowerBound..<finishStart.lowerBound])
        XCTAssertTrue(release.contains(
            "resumeConnectedMotionBankAfterLocalDependencyIfNeeded("
        ))
        XCTAssertTrue(release.contains(".terminalMaterialization"))

        let capabilityStart = try XCTUnwrap(source.range(
            of: "private func handleHistoryCapabilityServiceDiscovery("
        ))
        let capability = String(source[capabilityStart.lowerBound...].prefix(2_000))
        let typed = try XCTUnwrap(capability.range(
            of: "resumeConnectedMotionBankAfterLocalDependencyIfNeeded("
        ))
        let generic = try XCTUnwrap(capability.range(
            of: "scheduleRangeLossBackfillIfNeeded("
        ))
        XCTAssertLessThan(typed.lowerBound, generic.lowerBound)

        let orphanSuccess = try XCTUnwrap(source.range(
            of: "let exactMotionResumed = self\n                        .resumeConnectedMotionBankAfterLocalDependencyIfNeeded("
        ))
        let orphanGeneric = try XCTUnwrap(source.range(
            of: "let pending = self.takePendingOfflineHistoricalSyncRequest()",
            range: orphanSuccess.upperBound..<source.endIndex
        ))
        XCTAssertLessThan(orphanSuccess.lowerBound, orphanGeneric.lowerBound)
    }

    func testInteractiveForegroundPrioritizesBoundedGlanceBeforeHeavyProjection() throws {
        let source = try managerSource()
        let methodStart = try XCTUnwrap(source.range(
            of: "func handleInteractiveForeground(rest: Int, maxHR: Int)"
        ))
        let methodEnd = try XCTUnwrap(source.range(
            of: "private func reassertHeartRateNotificationsIfConnected",
            range: methodStart.upperBound..<source.endIndex
        ))
        let method = String(source[methodStart.lowerBound..<methodEnd.lowerBound])

        let glance = try XCTUnwrap(method.range(
            of: "checkpointHistoricalMotionBankOnGlanceIfNeeded("
        ))
        let heavy = try XCTUnwrap(method.range(
            of: "resumeDeferredTerminalConsumerMaterializationIfNeeded("
        ))
        let retryArm = try XCTUnwrap(method.range(
            of: "foregroundGlanceCheckpointRetryGate.recordForegroundAttempt("
        ))
        XCTAssertLessThan(glance.lowerBound, heavy.lowerBound)
        XCTAssertLessThan(glance.lowerBound, retryArm.lowerBound)
        XCTAssertLessThan(retryArm.lowerBound, heavy.lowerBound)
        XCTAssertTrue(method.contains("if !motionBankGlanceCheckpointStarted"))
        XCTAssertTrue(method.contains(
            "!foregroundGlanceCheckpointRetryGate.isAwaitingFreshHeartRate"
        ))
        XCTAssertTrue(method.contains("!historicalRadioTransportOwnsLink"))

        let resumeStart = try XCTUnwrap(source.range(
            of: "func resumePendingFullDrainPublicationIfNeeded(reason: String)"
        ))
        let resumeBody = String(source[resumeStart.lowerBound...].prefix(1_200))
        XCTAssertTrue(resumeBody.contains(
            "guard !historicalRadioTransportOwnsLink,"
        ))
        XCTAssertTrue(resumeBody.contains(
            "!connectedMotionBankFirstAttemptOwnsForegroundPriority"
        ))
        XCTAssertTrue(resumeBody.contains(
            "resumeFullDrainPublicationAfterFreshHR = true"
        ))

        let acceptedHRStart = try XCTUnwrap(source.range(
            of: "private func acceptHeartRate(_ rate: Int, at sampleTime: Date)"
        ))
        let acceptedHRBody = String(
            source[acceptedHRStart.lowerBound...].prefix(1_600)
        )
        XCTAssertTrue(acceptedHRBody.contains(
            "if resumeFullDrainPublicationAfterFreshHR,\n           !historicalRadioTransportOwnsLink,\n           !connectedMotionBankFirstAttemptOwnsForegroundPriority"
        ), "accepted HR must retain the one pending publication edge while exact radio history is active")

        let acceptedHREnd = try XCTUnwrap(source.range(
            of: "private func beginAcceptedHeartRateBatch()",
            range: acceptedHRStart.upperBound..<source.endIndex
        ))
        let acceptedHR = String(
            source[acceptedHRStart.lowerBound..<acceptedHREnd.lowerBound]
        )
        let freshPublication = try XCTUnwrap(acceptedHR.range(
            of: "lastAcceptedHRAt = sampleTime"
        ))
        let glanceRetry = try XCTUnwrap(acceptedHR.range(
            of: "retryForegroundGlanceCheckpointAfterFreshHeartRateIfNeeded("
        ))
        let bankSelector = try XCTUnwrap(acceptedHR.range(
            of: "resumePendingWorkoutHistoricalMotionBankOffloadIfNeeded("
        ))
        XCTAssertLessThan(freshPublication.lowerBound, glanceRetry.lowerBound)
        XCTAssertLessThan(glanceRetry.lowerBound, bankSelector.lowerBound)

        let retryStart = try XCTUnwrap(source.range(
            of: "private func retryForegroundGlanceCheckpointAfterFreshHeartRateIfNeeded("
        ))
        let retryEnd = try XCTUnwrap(source.range(
            of: "private func scheduleGate4DailyBankRearmAfterHistoryStart(",
            range: retryStart.upperBound..<source.endIndex
        ))
        let retry = String(source[retryStart.lowerBound..<retryEnd.lowerBound])
        let consume = try XCTUnwrap(retry.range(
            of: "consumeAfterAcceptedHeartRate("
        ))
        let checkpoint = try XCTUnwrap(retry.range(
            of: "checkpointHistoricalMotionBankOnGlanceIfNeeded("
        ))
        XCTAssertLessThan(consume.lowerBound, checkpoint.lowerBound)
        XCTAssertTrue(retry.contains(
            "UIApplication.shared.applicationState == .active"
        ))
        XCTAssertFalse(retry.contains("UserDefaults"))
        XCTAssertEqual(
            source.components(
                separatedBy:
                    "retryForegroundGlanceCheckpointAfterFreshHeartRateIfNeeded("
            ).count - 1,
            2,
            "the helper must have one definition and one accepted-HR call site"
        )

        let app = try appSource()
        XCTAssertFalse(
            app.contains("ble.resumePendingFullDrainPublicationIfNeeded("),
            "AtriaApp must not bypass the manager's glance-first ordering during dependency setup or scene activation"
        )

        let transitionStart = try XCTUnwrap(app.range(
            of: "foregroundBLETransitionTask = Task { @MainActor in"
        ))
        let transitionEnd = try XCTUnwrap(app.range(
            of: "foregroundBLETransitionTask = nil",
            range: transitionStart.upperBound..<app.endIndex
        ))
        let transition = String(
            app[transitionStart.lowerBound..<transitionEnd.upperBound]
        )
        XCTAssertTrue(transition.contains("ble.handleInteractiveForeground("))
        XCTAssertFalse(transition.contains(
            "resumePendingFullDrainPublicationIfNeeded("
        ))
    }

    func testFirstUseScanRequiresWhoopSpecificIdentity() {
        XCTAssertFalse(
            AtriaBLEManager.scanCandidateHasStrapIdentity(
                advertisedServices: [CBUUID(string: "180D")],
                advertisedName: nil
            ),
            "180D alone is generic and must not become the saved first-use strap"
        )
        XCTAssertFalse(
            AtriaBLEManager.scanCandidateHasStrapIdentity(
                advertisedServices: [CBUUID(string: "180D")],
                advertisedName: "Polar H10"
            )
        )
        XCTAssertTrue(
            AtriaBLEManager.scanCandidateHasStrapIdentity(
                advertisedServices: [],
                advertisedName: "WHOOP 4.0"
            )
        )
        XCTAssertTrue(
            AtriaBLEManager.scanCandidateHasStrapIdentity(
                advertisedServices: [AtriaBLEManager.UUIDs.strapService],
                advertisedName: nil
            )
        )
    }

    private func managerSource() throws -> String {
        let managerURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaBLEManager.swift")
        return try String(contentsOf: managerURL, encoding: .utf8)
    }

    private func appSource() throws -> String {
        let appURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaApp.swift")
        return try String(contentsOf: appURL, encoding: .utf8)
    }
}
