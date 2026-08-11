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
            of: "if !exactConnectedRealtimePreservingRequest,\n           Self.shouldDeferHistoricalTransportForRealtimeContinuity("
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

    private func connectedRawCatchUpAdmission(
        background: Bool = true,
        queuedPull: Bool = false,
        foregroundAutomatic: Bool = false,
        backlog: Bool = true,
        verified: Bool = true,
        exactSource: Bool = true,
        syncing: Bool = false,
        connected: Bool = true,
        thermal: Bool = false,
        connectedAgo: TimeInterval? = 61,
        samples: Int = 10,
        acceptedAgo: TimeInterval? = 1,
        workout: Bool = false
    ) -> Bool {
        let now = Date(timeIntervalSince1970: 10_000)
        return AtriaBLEManager.shouldMintConnectedRawHistoryCatchUpAuthority(
            applicationIsBackground: background,
            queuedPullIntent: queuedPull,
            foregroundAutomaticBacklog: foregroundAutomatic,
            strapBacklogPending: backlog,
            verifiedRawHistoryCapability: verified,
            exactCallbackSourceAvailable: exactSource,
            syncInProgress: syncing,
            linkConnected: connected,
            thermalPressureActive: thermal,
            connectedAt: connectedAgo.map { now.addingTimeInterval(-$0) },
            acceptedSampleCount: samples,
            lastAcceptedHRAt: acceptedAgo.map {
                now.addingTimeInterval(-$0)
            },
            activeExplicitWorkout: workout,
            now: now
        )
    }

    func testConnectedRawCatchUpMintsOnlyForStableExactLiveAuthority() {
        XCTAssertTrue(connectedRawCatchUpAdmission())
        XCTAssertTrue(connectedRawCatchUpAdmission(
            background: false,
            queuedPull: true
        ))
        XCTAssertTrue(connectedRawCatchUpAdmission(
            background: false,
            foregroundAutomatic: true
        ))
        XCTAssertFalse(connectedRawCatchUpAdmission(background: false))
        XCTAssertFalse(connectedRawCatchUpAdmission(backlog: false))
        XCTAssertFalse(connectedRawCatchUpAdmission(verified: false))
        XCTAssertFalse(connectedRawCatchUpAdmission(exactSource: false))
        XCTAssertFalse(connectedRawCatchUpAdmission(syncing: true))
        XCTAssertFalse(connectedRawCatchUpAdmission(connected: false))
        XCTAssertFalse(connectedRawCatchUpAdmission(connectedAgo: 59))
        XCTAssertFalse(connectedRawCatchUpAdmission(samples: 9))
        XCTAssertFalse(connectedRawCatchUpAdmission(acceptedAgo: 46))
        XCTAssertFalse(connectedRawCatchUpAdmission(workout: true))
        XCTAssertFalse(connectedRawCatchUpAdmission(thermal: true))
        XCTAssertFalse(
            AtriaBLEManager
                .shouldParkConnectedRawHistoryCatchUpForPowerPressure(
                    thermalState: .nominal
                ),
            "the durable raw lane has no Low Power Mode input and must remain eligible when thermally nominal"
        )
        XCTAssertFalse(
            AtriaBLEManager
                .shouldParkConnectedRawHistoryCatchUpForPowerPressure(
                    thermalState: .fair
                )
        )
        XCTAssertFalse(
            AtriaBLEManager
                .shouldParkConnectedRawHistoryCatchUpForPowerPressure(
                    thermalState: .serious
                ),
            "serious heat uses bounded duty instead of permanently stranding durable raw history"
        )
        XCTAssertTrue(
            AtriaBLEManager
                .shouldParkConnectedRawHistoryCatchUpForPowerPressure(
                    thermalState: .critical
                )
        )
    }

    func testExplicitMotionLeaseClosesTerminalIntentRaceForHistory() {
        XCTAssertFalse(
            AtriaBLEManager.explicitMotionOwnershipBlocksHistory(
                pendingWorkoutIntentActive: false,
                inMemoryLeaseHeld: false,
                calibrationHoldActive: false
            )
        )
        XCTAssertTrue(
            AtriaBLEManager.explicitMotionOwnershipBlocksHistory(
                pendingWorkoutIntentActive: true,
                inMemoryLeaseHeld: false,
                calibrationHoldActive: false
            )
        )
        XCTAssertTrue(
            AtriaBLEManager.explicitMotionOwnershipBlocksHistory(
                pendingWorkoutIntentActive: false,
                inMemoryLeaseHeld: true,
                calibrationHoldActive: false
            ),
            "raw cannot enter after terminal intent but before lease release"
        )
        XCTAssertTrue(
            AtriaBLEManager.explicitMotionOwnershipBlocksHistory(
                pendingWorkoutIntentActive: false,
                inMemoryLeaseHeld: false,
                calibrationHoldActive: true
            )
        )
    }

    func testWorkoutHistoryPreemptionSuccessorRequiresNewerExactHREpoch() {
        let strap = UUID()
        let otherStrap = UUID()
        let predecessorObject = NSObject()
        let successorObject = NSObject()
        let predecessor = AtriaBLECallbackEpochFence.Source(
            epoch: 40,
            peripheralID: strap,
            peripheralObjectID: ObjectIdentifier(predecessorObject)
        )
        var gate = AtriaBLEWorkoutHistoryPreemptionSuccessorGate()
        gate.install(predecessorSource: predecessor)

        XCTAssertFalse(gate.consumeAfterAcceptedHeartRate(
            source: predecessor,
            sourceIsCurrent: true
        ))
        XCTAssertFalse(gate.consumeAfterAcceptedHeartRate(
            source: .init(
                epoch: 41,
                peripheralID: otherStrap,
                peripheralObjectID: ObjectIdentifier(successorObject)
            ),
            sourceIsCurrent: true
        ))
        XCTAssertFalse(gate.consumeAfterAcceptedHeartRate(
            source: .init(
                epoch: 41,
                peripheralID: strap,
                peripheralObjectID: ObjectIdentifier(successorObject)
            ),
            sourceIsCurrent: false
        ))
        XCTAssertTrue(gate.isAwaitingReplacementAcceptedHeartRate)
        XCTAssertTrue(gate.consumeAfterAcceptedHeartRate(
            source: .init(
                epoch: 41,
                peripheralID: strap,
                peripheralObjectID: ObjectIdentifier(successorObject)
            ),
            sourceIsCurrent: true
        ))
        XCTAssertFalse(gate.isAwaitingReplacementAcceptedHeartRate)

        var replacementGate =
            AtriaBLEWorkoutHistoryPreemptionSuccessorGate()
        replacementGate.install(predecessorSource: predecessor)
        XCTAssertFalse(replacementGate.blocksArm(for: otherStrap))
        XCTAssertFalse(
            replacementGate.isAwaitingReplacementAcceptedHeartRate,
            "old-strap provenance must not black out a replacement strap"
        )
    }

    func testFailedContinuationAdmissionYieldsOneMeaningfulCaptureTurn()
        throws {
        let failedAt = Date(timeIntervalSince1970: 20_000)
        XCTAssertEqual(
            AtriaBLEManager.connectedRawNoRadioRetryNotBefore(
                priorContinuationPending: true,
                admissionStarted: false,
                historyOwnerActive: false,
                failedAt: failedAt
            ),
            failedAt.addingTimeInterval(120)
        )
        XCTAssertNil(
            AtriaBLEManager.connectedRawNoRadioRetryNotBefore(
                priorContinuationPending: false,
                admissionStarted: false,
                historyOwnerActive: false,
                failedAt: failedAt
            )
        )
        XCTAssertNil(
            AtriaBLEManager.connectedRawNoRadioRetryNotBefore(
                priorContinuationPending: true,
                admissionStarted: false,
                historyOwnerActive: true,
                failedAt: failedAt
            ),
            "a physical owner cannot be reclassified as a no-radio yield"
        )

        let armedAt = failedAt.addingTimeInterval(1)
        XCTAssertEqual(
            AtriaBLEManager.connectedRawPresentBankRetryNotBefore(
                bankArmedForCurrentConnection: true,
                bankArmedAt: armedAt,
                now: armedAt.addingTimeInterval(6)
            ),
            armedAt.addingTimeInterval(120),
            "the next callback cannot close a six-second bank"
        )
        XCTAssertNil(
            AtriaBLEManager.connectedRawPresentBankRetryNotBefore(
                bankArmedForCurrentConnection: true,
                bankArmedAt: armedAt,
                now: armedAt.addingTimeInterval(120)
            )
        )

        let source = try managerSource()
        let selectorStart = try XCTUnwrap(source.range(
            of: "private func resumePendingWorkoutHistoricalMotionBankOffloadIfNeeded("
        ))
        let selector = String(source[selectorStart.lowerBound...].prefix(3_500))
        XCTAssertTrue(selector.contains(
            "guard !connectedRawNoRadioCaptureTurnIsCurrent()"
        ), "a coexisting direct ticket must not consume the no-radio capture turn")
        XCTAssertTrue(selector.contains(
            "action=no_selector_no_attempt_no_cadence_mutation_rearm_present_bank_first"
        ))

        let acceptedStart = try XCTUnwrap(source.range(
            of: "private func acceptHeartRate("
        ))
        let acceptedEnd = try XCTUnwrap(source.range(
            of: "private func beginAcceptedHeartRateBatch()",
            range: acceptedStart.upperBound..<source.endIndex
        ))
        let accepted = String(
            source[acceptedStart.lowerBound..<acceptedEnd.lowerBound]
        )
        let captureTurn = try XCTUnwrap(accepted.range(
            of: "let noRadioPresentCaptureTurn ="
        ))
        let directSelector = try XCTUnwrap(accepted.range(
            of: "resumePendingWorkoutHistoricalMotionBankOffloadIfNeeded("
        ))
        let presentArm = try XCTUnwrap(accepted.range(
            of: "noRadioPresentCaptureTurn\n                            || Self"
        ))
        XCTAssertLessThan(captureTurn.lowerBound, directSelector.lowerBound)
        XCTAssertLessThan(directSelector.lowerBound, presentArm.lowerBound)

        let autonomousStart = try XCTUnwrap(source.range(
            of: "private func attemptAutonomousBackgroundCatchUpAfterAcceptedHRIfNeeded("
        ))
        let autonomousEnd = try XCTUnwrap(source.range(
            of: "/// The current flush-debt level",
            range: autonomousStart.upperBound..<source.endIndex
        ))
        let autonomous = String(
            source[autonomousStart.lowerBound..<autonomousEnd.lowerBound]
        )
        XCTAssertTrue(autonomous.contains(
            "|| connectedRawNoRadioCaptureTurnIsCurrent()"
        ), "forced/full-drain/range-loss fallbacks must stay fenced for the capture turn")

        let rawAttemptStart = try XCTUnwrap(source.range(
            of: "private func attemptConnectedRawHistoryCatchUpAfterAcceptedHRIfNeeded("
        ))
        let rawAttempt = String(
            source[rawAttemptStart.lowerBound..<autonomousStart.lowerBound]
        )
        let armedWindow = try XCTUnwrap(rawAttempt.range(
            of: "connectedRawPresentBankRetryNotBefore("
        ))
        let consumeDeferral = try XCTUnwrap(rawAttempt.range(
            of: "connectedRawNoRadioCaptureDeferral = nil",
            range: armedWindow.upperBound..<rawAttempt.endIndex
        ))
        XCTAssertLessThan(armedWindow.lowerBound, consumeDeferral.lowerBound)
    }

    func testGlobalFrontierEvaluationCoalescesOneFreshTrailingPass() {
        var gate = AtriaBLEManager.GlobalFrontierEvaluationCoalescer()
        XCTAssertTrue(gate.request(whileEvaluationInFlight: false))
        XCTAssertFalse(gate.request(whileEvaluationInFlight: true))
        XCTAssertFalse(gate.request(whileEvaluationInFlight: true))
        XCTAssertTrue(gate.consumeTrailingRequest())
        XCTAssertFalse(gate.consumeTrailingRequest())
    }

    func testConnectedRawCatchUpUsesAdaptiveThermalDutyAndProgressCadence() {
        let started = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(
            AtriaBLEManager.connectedRawHistoryCatchUpBudgetDisposition(
                startedAt: started,
                lastAcceptedHeartRateAt: started,
                now: started.addingTimeInterval(30),
                liveSilenceLimit: 45,
                thermalState: .nominal,
                durableBoundaryReached: false
            ),
            .keepServing,
            "a bounded multi-page burst must not be cut through a page"
        )
        XCTAssertEqual(
            AtriaBLEManager.connectedRawHistoryCatchUpBudgetDisposition(
                startedAt: started,
                lastAcceptedHeartRateAt: started.addingTimeInterval(6),
                now: started.addingTimeInterval(7),
                liveSilenceLimit: 45,
                thermalState: .serious,
                durableBoundaryReached: false
            ),
            .keepServing
        )
        XCTAssertEqual(
            AtriaBLEManager.connectedRawHistoryCatchUpBudgetDisposition(
                startedAt: started,
                lastAcceptedHeartRateAt: started.addingTimeInterval(9),
                now: started.addingTimeInterval(46),
                liveSilenceLimit: 45,
                thermalState: .serious,
                durableBoundaryReached: true
            ),
            .keepServing,
            "46 seconds plus durable progress must keep serving until the fourth exact ACK boundary"
        )
        XCTAssertEqual(
            AtriaBLEManager.connectedRawHistoryCatchUpBudgetDisposition(
                startedAt: started,
                lastAcceptedHeartRateAt: started,
                now: started.addingTimeInterval(45),
                liveSilenceLimit: 45,
                thermalState: .serious,
                durableBoundaryReached: false
            ),
            .keepServing,
            "the polling budget cannot cut a no-boundary page; the independent progress-clocked idle watchdog owns a genuine stall"
        )
        XCTAssertEqual(
            AtriaBLEManager.connectedRawHistoryCatchUpBudgetDisposition(
                startedAt: started,
                lastAcceptedHeartRateAt: started,
                now: started,
                liveSilenceLimit: 45,
                thermalState: .critical,
                durableBoundaryReached: false
            ),
            .finishForPowerPressure
        )
        XCTAssertFalse(
            AtriaBLEManager
                .shouldFinishConnectedRawHistoryCatchUpAtACKBoundary(
                    acknowledgedPages: 3
                )
        )
        XCTAssertTrue(
            AtriaBLEManager
                .shouldFinishConnectedRawHistoryCatchUpAtACKBoundary(
                    acknowledgedPages: 4
                )
        )
        XCTAssertEqual(
            AtriaBLEManager.connectedRawHistoryCatchUpTargetAcknowledgedPages(
                thermalState: .nominal
            ),
            16
        )
        XCTAssertEqual(
            AtriaBLEManager.connectedRawHistoryCatchUpTargetAcknowledgedPages(
                thermalState: .fair
            ),
            16
        )
        XCTAssertEqual(
            AtriaBLEManager.connectedRawHistoryCatchUpTargetAcknowledgedPages(
                thermalState: .serious
            ),
            4
        )
        XCTAssertEqual(
            AtriaBLEManager.connectedRawHistoryCatchUpTargetAcknowledgedPages(
                thermalState: .critical
            ),
            1
        )
        for thermalState in [
            ProcessInfo.ThermalState.nominal,
            .fair,
            .serious,
            .critical,
        ] {
            XCTAssertEqual(
                AtriaBLEManager
                    .connectedRawHistoryCatchUpTargetAcknowledgedPages(
                        thermalState: thermalState,
                        backgroundSlice: true
                    ),
                1,
                "a locked-background raw serve gets one clean ACK boundary"
            )
        }
        XCTAssertFalse(
            AtriaBLEManager
                .shouldFinishConnectedRawHistoryCatchUpAtACKBoundary(
                    acknowledgedPages: 15,
                    minimumAcknowledgedPages: 16
                )
        )
        XCTAssertTrue(
            AtriaBLEManager
                .shouldFinishConnectedRawHistoryCatchUpAtACKBoundary(
                    acknowledgedPages: 16,
                    minimumAcknowledgedPages: 16
                )
        )

        let preemptedAt = Date(timeIntervalSince1970: 10_000)
        XCTAssertEqual(
            AtriaBLEManager
                .connectedRawHistoryLivePreemptionRetryNotBefore(
                    now: preemptedAt,
                    connectedSliceCooldown: 60,
                    zeroProgressRetry: 120
                ),
            preemptedAt.addingTimeInterval(5 * 60)
        )
        XCTAssertEqual(
            AtriaBLEManager
                .connectedRawHistoryLivePreemptionRetryNotBefore(
                    now: preemptedAt,
                    connectedSliceCooldown: 420,
                    zeroProgressRetry: 120
                ),
            preemptedAt.addingTimeInterval(420)
        )
        XCTAssertEqual(
            AtriaBLEManager.connectedRawHistoryCatchUpContinuationDisposition(
                backlogPending: true,
                cursorCaughtUp: false,
                durableRows: 200,
                frontierAdvanceSeconds: 90,
                thermalState: .nominal,
                durableProgressAuthorized: true,
                thermalInterruption: false,
                consecutiveProductiveSlices: 0
            ),
            .resumeAfter(2)
        )
        XCTAssertEqual(
            AtriaBLEManager.connectedRawHistoryCatchUpContinuationDisposition(
                backlogPending: true,
                cursorCaughtUp: false,
                durableRows: 200,
                frontierAdvanceSeconds: 90,
                thermalState: .nominal,
                durableProgressAuthorized: true,
                thermalInterruption: false,
                consecutiveProductiveSlices: 7
            ),
            .resumeAfter(8)
        )
        XCTAssertEqual(
            AtriaBLEManager.connectedRawHistoryCatchUpContinuationDisposition(
                backlogPending: true,
                cursorCaughtUp: false,
                durableRows: 200,
                frontierAdvanceSeconds: 90,
                thermalState: .nominal,
                durableProgressAuthorized: true,
                thermalInterruption: false,
                consecutiveProductiveSlices: 0,
                publicationYieldNeeded: true
            ),
            .yieldForPublication(120),
            "one sixteen-page nominal slice is a sufficient quantum before app-facing work"
        )
        XCTAssertEqual(
            AtriaBLEManager.connectedRawHistoryCatchUpContinuationDisposition(
                backlogPending: true,
                cursorCaughtUp: false,
                durableRows: 20,
                frontierAdvanceSeconds: 8,
                thermalState: .serious,
                durableProgressAuthorized: true,
                thermalInterruption: true,
                consecutiveProductiveSlices: 0,
                publicationYieldNeeded: true
            ),
            .resumeAfter(2),
            "serious heat cannot run publication, so its proven four-page raw duty must continue without a 120-second empty yield"
        )
        XCTAssertEqual(
            AtriaBLEManager.connectedRawHistoryCatchUpContinuationDisposition(
                backlogPending: true,
                cursorCaughtUp: false,
                durableRows: 200,
                frontierAdvanceSeconds: 90,
                thermalState: .nominal,
                durableProgressAuthorized: true,
                thermalInterruption: false,
                consecutiveProductiveSlices: 0,
                publicationYieldNeeded: true,
                publicationYieldRunnable: false
            ),
            .resumeAfter(2),
            "a pending intent cannot pause raw transfer while lifecycle or Low Power Mode makes publication unrunnable"
        )
        XCTAssertEqual(
            AtriaBLEManager.connectedRawHistoryCatchUpContinuationDisposition(
                backlogPending: true,
                cursorCaughtUp: false,
                durableRows: 0,
                frontierAdvanceSeconds: 0,
                thermalState: .nominal,
                durableProgressAuthorized: false,
                thermalInterruption: false,
                consecutiveProductiveSlices: 0
            ),
            .retryAfter(120)
        )
        XCTAssertEqual(
            AtriaBLEManager.connectedRawHistoryCatchUpContinuationDisposition(
                backlogPending: true,
                cursorCaughtUp: false,
                durableRows: 20,
                frontierAdvanceSeconds: 8,
                thermalState: .serious,
                durableProgressAuthorized: true,
                thermalInterruption: true,
                consecutiveProductiveSlices: 0
            ),
            .resumeAfter(2),
            "fresh live HR after the burst is the thermal duty pause; serious heat must not add another fixed 20-second stall"
        )
        XCTAssertEqual(
            AtriaBLEManager.connectedRawHistoryCatchUpContinuationDisposition(
                backlogPending: true,
                cursorCaughtUp: false,
                durableRows: 20,
                frontierAdvanceSeconds: 8,
                thermalState: .critical,
                durableProgressAuthorized: true,
                thermalInterruption: true,
                consecutiveProductiveSlices: 0
            ),
            .awaitThermalRecovery
        )
        XCTAssertEqual(
            AtriaBLEManager.connectedRawHistoryCatchUpContinuationDisposition(
                backlogPending: true,
                cursorCaughtUp: true,
                durableRows: 0,
                frontierAdvanceSeconds: 0,
                thermalState: .nominal,
                durableProgressAuthorized: true,
                thermalInterruption: false,
                consecutiveProductiveSlices: 0
            ),
            .complete
        )
        XCTAssertEqual(
            AtriaBLEManager.connectedRawHistoryCatchUpContinuationDisposition(
                backlogPending: true,
                cursorCaughtUp: false,
                durableRows: 20,
                frontierAdvanceSeconds: 8,
                thermalState: .nominal,
                durableProgressAuthorized: false,
                thermalInterruption: false,
                consecutiveProductiveSlices: 0
            ),
            .retryAfter(120),
            "inserted rows from a nonterminal/failing generation cannot fast-chain without a durable ACK/terminal boundary"
        )
        XCTAssertEqual(
            AtriaBLEManager.connectedRawHistoryCatchUpContinuationDisposition(
                backlogPending: true,
                cursorCaughtUp: false,
                durableRows: 0,
                frontierAdvanceSeconds: 0,
                thermalState: .serious,
                durableProgressAuthorized: false,
                thermalInterruption: true,
                consecutiveProductiveSlices: 0
            ),
            .retryAfter(120),
            "serious heat never turns a zero-progress attempt into a 20-second command loop"
        )

        XCTAssertTrue(
            AtriaBLEManager
                .connectedRawHistoryCatchUpContinuationDefersProjection(
                    continuationPending: true,
                    publicationYieldActive: false
                )
        )
        XCTAssertFalse(
            AtriaBLEManager
                .connectedRawHistoryCatchUpContinuationDefersProjection(
                    continuationPending: true,
                    publicationYieldActive: true
                ),
            "the continuation stays pending during a yield without claiming projection ownership"
        )
        let yieldDeadline = started.addingTimeInterval(120)
        XCTAssertTrue(
            AtriaBLEManager
                .connectedRawHistoryCatchUpPublicationYieldShouldRemainActive(
                    publicationNeeded: true,
                    publicationSucceeded: false,
                    now: yieldDeadline.addingTimeInterval(-0.001),
                    deadline: yieldDeadline
                )
        )
        XCTAssertFalse(
            AtriaBLEManager
                .connectedRawHistoryCatchUpPublicationYieldShouldRemainActive(
                    publicationNeeded: true,
                    publicationSucceeded: false,
                    now: yieldDeadline,
                    deadline: yieldDeadline
                ),
            "the absolute deadline must release the process-local token"
        )
        XCTAssertFalse(
            AtriaBLEManager
                .connectedRawHistoryCatchUpPublicationYieldShouldRemainActive(
                    publicationNeeded: true,
                    publicationSucceeded: true,
                    now: yieldDeadline.addingTimeInterval(-30),
                    deadline: yieldDeadline
                )
        )
        XCTAssertFalse(
            AtriaBLEManager
                .connectedRawHistoryCatchUpPublicationYieldShouldRemainActive(
                    publicationNeeded: true,
                    publicationSucceeded: false,
                    publicationAttemptCompleted: true,
                    now: yieldDeadline.addingTimeInterval(-119),
                    deadline: yieldDeadline
                ),
            "one completed bounded offer must release raw immediately even when durable bootstrap intent remains"
        )
        XCTAssertFalse(
            AtriaBLEManager
                .connectedRawHistoryCatchUpPublicationYieldShouldRemainActive(
                    publicationNeeded: false,
                    publicationSucceeded: false,
                    now: yieldDeadline.addingTimeInterval(-30),
                    deadline: yieldDeadline
                )
        )

        let progress = AtriaBLEManager.connectedRawHistoryCatchUpSliceProgress(
            durableRows: 240,
            startedAt: started,
            finishedAt: started.addingTimeInterval(60),
            startFrontierUnix: 5_000,
            endFrontierUnix: 5_180
        )
        XCTAssertEqual(progress.durationSeconds, 60, accuracy: 0.001)
        XCTAssertEqual(progress.rowsPerSecond, 4, accuracy: 0.001)
        XCTAssertEqual(progress.frontierAdvanceSeconds, 180, accuracy: 0.001)

        XCTAssertEqual(
            AtriaBLEManager.advancedDurableHistoricalFrontier(
                existing: 5_000,
                durableEffectiveUnix: [4_900, 5_120, 5_100],
                now: Date(timeIntervalSince1970: 6_000)
            ),
            5_120
        )
        XCTAssertNil(
            AtriaBLEManager.advancedDurableHistoricalFrontier(
                existing: 5_120,
                durableEffectiveUnix: [5_100, 5_120],
                now: Date(timeIntervalSince1970: 6_000)
            ),
            "a durable flush never regresses or rewrites the frontier"
        )
        XCTAssertNil(
            AtriaBLEManager.advancedDurableHistoricalFrontier(
                existing: 5_120,
                durableEffectiveUnix: [6_301],
                now: Date(timeIntervalSince1970: 6_000),
                futureTolerance: 300
            ),
            "a clock-corrupt future row is not display-frontier authority"
        )
    }

    func testHistoryServeCutoverAlwaysClearsArmedStateAndRetainsPrearm() {
        XCTAssertEqual(
            AtriaBLEManager
                .historicalMotionBankStateAfterHistoryServeCutover(),
            .init(
                processArmed: false,
                persistedEnabled: false,
                prearmRequested: true
            )
        )
    }

    func testMotionBankRearmTracksRealRawOwnershipNotDurableTicketCount() {
        XCTAssertTrue(
            AtriaBLEManager.historicalMotionBankRearmBlockedByRawOwnership(
                historyTransportActive: true,
                rawContinuationPending: false,
                postHistoryRawRestorationActive: false,
                explicitPresentCapturePriority: true
            ),
            "manual priority cannot interleave 69/01 with a physical owner"
        )
        XCTAssertTrue(
            AtriaBLEManager.historicalMotionBankRearmBlockedByRawOwnership(
                historyTransportActive: false,
                rawContinuationPending: true,
                postHistoryRawRestorationActive: true,
                explicitPresentCapturePriority: false
            ),
            "between-slice restoration remains one logical FIFO episode"
        )
        XCTAssertFalse(
            AtriaBLEManager.historicalMotionBankRearmBlockedByRawOwnership(
                historyTransportActive: false,
                rawContinuationPending: true,
                postHistoryRawRestorationActive: false,
                explicitPresentCapturePriority: true
            ),
            "a workout may preempt only after physical transport released"
        )
        XCTAssertFalse(
            AtriaBLEManager.historicalMotionBankRearmBlockedByRawOwnership(
                historyTransportActive: false,
                rawContinuationPending: false,
                postHistoryRawRestorationActive: false,
                explicitPresentCapturePriority: false
            ),
            "an unrelated durable/local ticket is not radio ownership"
        )
    }

    func testAcceptedCurrentServeFrameCancelsOnlyItsMatchingContinuation() {
        XCTAssertTrue(
            AtriaBLEManager.shouldCancelHistoricalPageContinuationForFrame(
                activeGeneration: 41,
                continuationGeneration: 41,
                frameGeneration: 41,
                ingressAccepted: true,
                callbackCapturedCurrentServe: true
            )
        )
        XCTAssertFalse(
            AtriaBLEManager.shouldCancelHistoricalPageContinuationForFrame(
                activeGeneration: 41,
                continuationGeneration: 41,
                frameGeneration: 41,
                ingressAccepted: false,
                callbackCapturedCurrentServe: true
            ),
            "a callback rejected by the ingress gate must not cancel anything"
        )
        XCTAssertFalse(
            AtriaBLEManager.shouldCancelHistoricalPageContinuationForFrame(
                activeGeneration: 41,
                continuationGeneration: 41,
                frameGeneration: 41,
                ingressAccepted: true,
                callbackCapturedCurrentServe: false
            ),
            "a predecessor callback without this serve token is not page activity"
        )
        XCTAssertFalse(
            AtriaBLEManager.shouldCancelHistoricalPageContinuationForFrame(
                activeGeneration: 42,
                continuationGeneration: 41,
                frameGeneration: 41,
                ingressAccepted: true,
                callbackCapturedCurrentServe: true
            )
        )
        XCTAssertFalse(
            AtriaBLEManager.shouldCancelHistoricalPageContinuationForFrame(
                activeGeneration: 41,
                continuationGeneration: 42,
                frameGeneration: 41,
                ingressAccepted: true,
                callbackCapturedCurrentServe: true
            ),
            "an older frame cannot cancel a newer continuation generation"
        )
        XCTAssertFalse(
            AtriaBLEManager.shouldCancelHistoricalPageContinuationForFrame(
                activeGeneration: 41,
                continuationGeneration: nil,
                frameGeneration: 41,
                ingressAccepted: true,
                callbackCapturedCurrentServe: true
            )
        )
    }

    func testConnectedRawIngressRequiresCallbackCapturedServeAndAdmission() {
        XCTAssertTrue(AtriaBLEManager.shouldAcceptConnectedRawHistoryIngress(
            exactRawAuthorityActive: false,
            callbackCapturedCurrentServe: false,
            admissionAttemptAvailable: false
        ))
        XCTAssertFalse(AtriaBLEManager.shouldAcceptConnectedRawHistoryIngress(
            exactRawAuthorityActive: true,
            callbackCapturedCurrentServe: false,
            admissionAttemptAvailable: true
        ))
        XCTAssertFalse(AtriaBLEManager.shouldAcceptConnectedRawHistoryIngress(
            exactRawAuthorityActive: true,
            callbackCapturedCurrentServe: true,
            admissionAttemptAvailable: false
        ))
        XCTAssertTrue(AtriaBLEManager.shouldAcceptConnectedRawHistoryIngress(
            exactRawAuthorityActive: true,
            callbackCapturedCurrentServe: true,
            admissionAttemptAvailable: true
        ))
    }

    func testConnectedRawConsumedPrefixRetirementAllowsScheduledUnreadDrainOnly() {
        func safe(
            exactCleanACKFinish: Bool = true,
            pendingPersistence: Int = 0,
            inFlight: Bool = false,
            scheduled: Bool = true,
            deferred: Bool = false,
            flushing: Bool = false,
            pendingACK: Bool = false,
            ackGate: Bool = false
        ) -> Bool {
            AtriaBLEManager.shouldRetireConnectedRawConsumedPrefix(
                exactCleanACKFinishAuthority: exactCleanACKFinish,
                durableBoundaryReached: true,
                acknowledgedPages: 4,
                pendingPersistenceCount: pendingPersistence,
                admissionBatchInFlight: inFlight,
                admissionBatchScheduled: scheduled,
                hasDeferredEvent: deferred,
                durableFlushInFlight: flushing,
                hasPendingACK: pendingACK,
                ackGateDeferringCallbacks: ackGate
            )
        }

        XCTAssertTrue(
            safe(scheduled: true),
            "a merely scheduled MainActor drain has popped nothing and the unread suffix must be compactable"
        )
        XCTAssertFalse(
            safe(exactCleanACKFinish: false),
            "an earlier page ACK cannot retire a later page's dequeued prefix"
        )
        XCTAssertFalse(safe(pendingPersistence: 1))
        XCTAssertFalse(safe(inFlight: true))
        XCTAssertFalse(safe(deferred: true))
        XCTAssertFalse(safe(flushing: true))
        XCTAssertFalse(safe(pendingACK: true))
        XCTAssertFalse(safe(ackGate: true))
    }

    func testConnectedRawCatchUpIsExactGenerationBoundAndLocallyTerminal() throws {
        let source = try managerSource()
        XCTAssertTrue(source.contains(
            "private struct ConnectedRawHistoryCatchUpRequestAuthority"
        ))
        XCTAssertTrue(source.contains(
            "let callbackSource: AtriaBLECallbackEpochFence.Source"
        ))
        XCTAssertTrue(source.contains(
            "private struct ConnectedRawHistoryCatchUpGenerationAuthority"
        ))
        XCTAssertTrue(source.contains("let generation: UInt64"))
        XCTAssertTrue(source.contains("let startedAt: Date"))
        XCTAssertTrue(source.contains("let startFrontierUnix: TimeInterval"))
        XCTAssertTrue(source.contains(
            "authority.callbackSource.peripheralObjectID\n                == ObjectIdentifier(peripheral)"
        ))
        XCTAssertTrue(source.contains(
            "activeConnectedRawHistoryCatchUpGenerationAuthority = .init("
        ))
        XCTAssertTrue(source.contains(
            ".claimExclusiveConnectedCanonicalTransport("
        ))
        XCTAssertTrue(source.contains(
            "armConnectedRealtimePreservingHistoryBudget("
        ))
        XCTAssertTrue(source.contains(
            "connectedRawHistoryCatchUpForegroundLiveSilenceLimit: TimeInterval = 45"
        ))
        XCTAssertTrue(source.contains(
            "connectedRawHistoryCatchUpBackgroundLiveSilenceLimit: TimeInterval = 45"
        ))
        XCTAssertTrue(source.contains(
            "activeConnectedRawHistoryCatchUpGenerationAuthority = nil"
        ))
        XCTAssertTrue(source.contains(
            "shouldResumePendingSync = resumePendingSync\n            && !boundedConnectedRawCatchUp"
        ))
        XCTAssertTrue(source.contains(
            "if connectedRawHistoryCatchUpRequestAuthority == nil,\n           Self.shouldDeferAutomaticOfflineSyncForThermalPressure("
        ), "the generic serious-heat gate must not make the adaptive exact raw lane unreachable")
        XCTAssertTrue(source.contains(
            "if connectedRawHistoryCatchUpRequestAuthority == nil,\n           !flushMaintenanceWindow,\n           Self.shouldDeferAutomaticOfflineSyncForConnectedLink("
        ), "the legacy metric-gap connected guard must not reject exact raw-only catch-up")

        let budgetStart = try XCTUnwrap(source.range(
            of: "private func armConnectedRealtimePreservingHistoryBudget("
        ))
        let budgetEnd = try XCTUnwrap(source.range(
            of: "private func holdConnectedMotionBankBeforeFreshHRFirstRefusal(",
            range: budgetStart.upperBound..<source.endIndex
        ))
        let budget = String(source[budgetStart.lowerBound..<budgetEnd.lowerBound])
        let rawPowerBranchStart = try XCTUnwrap(budget.range(
            of: "if let rawAuthority ="
        ))
        let motionPowerBranchStart = try XCTUnwrap(budget.range(
            of: ".connectedMotionBankHistoryBudgetDisposition(",
            range: rawPowerBranchStart.upperBound..<budget.endIndex
        ))
        let rawPowerBranch = String(
            budget[rawPowerBranchStart.lowerBound..<motionPowerBranchStart.lowerBound]
        )
        XCTAssertTrue(rawPowerBranch.contains(
            "connectedRawHistoryCatchUpBudgetDisposition("
        ))
        XCTAssertFalse(rawPowerBranch.contains(
            "connectedMotionBankHistoryAbsoluteLimit"
        ))
        XCTAssertFalse(rawPowerBranch.contains("isLowPowerModeEnabled"))
        XCTAssertTrue(String(budget[motionPowerBranchStart.lowerBound...]).contains(
            "isLowPowerModeEnabled"
        ))
        XCTAssertTrue(String(budget[motionPowerBranchStart.lowerBound...]).contains(
            "connectedMotionBankHistoryAbsoluteLimit"
        ))
        XCTAssertTrue(budget.contains(
            "finishConnectedHistoryFailureWithoutDisconnectIfNeeded("
        ))
        XCTAssertFalse(budget.contains("cancelPeripheralConnection("))
        XCTAssertFalse(budget.contains("rebuildCentralForWedgedSessionOnce("))

        let failureStart = try XCTUnwrap(source.range(
            of: "private func finishConnectedHistoryFailureWithoutDisconnectIfNeeded("
        ))
        let failureEnd = try XCTUnwrap(source.range(
            of: "private func beginHistoricalArchiveWarmBackgroundLease(",
            range: failureStart.upperBound..<source.endIndex
        ))
        let failure = String(source[failureStart.lowerBound..<failureEnd.lowerBound])
        XCTAssertTrue(failure.contains(
            "activeConnectedRealtimePreservingHistoryAuthorityExists("
        ))
        XCTAssertFalse(failure.contains("cancelPeripheralConnection("))
        XCTAssertFalse(failure.contains("rebuildCentralForWedgedSessionOnce("))
    }

    func testConnectedRawCatchUpHotPathQueuesNoGenericAuthorityAndPreserves2A37() throws {
        let source = try managerSource()
        let queueStart = try XCTUnwrap(source.range(
            of: "func queueConnectedRawHistoryCatchUpIntent("
        ))
        let queueEnd = try XCTUnwrap(source.range(
            of: "private func attemptConnectedRawHistoryCatchUpAfterAcceptedHRIfNeeded(",
            range: queueStart.upperBound..<source.endIndex
        ))
        let queue = String(source[queueStart.lowerBound..<queueEnd.lowerBound])
        XCTAssertFalse(queue.contains("UserDefaults"))
        XCTAssertFalse(queue.contains("requestOfflineHistoricalSyncIfNeeded("))

        let retainStart = try XCTUnwrap(source.range(
            of: "private func retainPendingOfflineHistoricalSyncRequest("
        ))
        let retainEnd = try XCTUnwrap(source.range(
            of: "private func takePendingOfflineHistoricalSyncRequest(",
            range: retainStart.upperBound..<source.endIndex
        ))
        let retain = String(source[retainStart.lowerBound..<retainEnd.lowerBound])
        XCTAssertTrue(retain.contains(
            "if transientConnectedRawHistoryCatchUpRequestAuthority != nil"
        ))
        XCTAssertTrue(retain.contains("return retained"))
        XCTAssertTrue(source.contains(
            "Production WHOOP 4 recovery first quiets only the proprietary"
        ))
        XCTAssertTrue(source.contains("Standard 2A37 HR/RR remains live"))
        XCTAssertFalse(source.contains(
            "transientConnectedRawHistoryCatchUpRequestAuthority = pending"
        ))
        XCTAssertTrue(source.contains(
            "trigger: \"accepted_hr_batch\""
        ))
        XCTAssertFalse(source.contains(
            "connectedRawHistoryCatchUpAttemptCooldown"
        ))
        XCTAssertTrue(source.contains(
            "|| connectedRawHistoryCatchUpContinuationPending"
        ))
        XCTAssertTrue(source.contains(
            "|| connectedRawNoRadioCaptureTurnIsCurrent()"
        ), "a failed productive continuation admission must occupy the outer scheduling turn while present capture rearms")
        XCTAssertTrue(source.contains(
            "postHistoryLiveRestorationGeneration != nil,\n           connectedRawHistoryCatchUpContinuationPending"
        ))
        XCTAssertTrue(source.contains(
            "connectedRawHistoryCatchUpContinuationDefersProjection("
        ))
        XCTAssertTrue(source.contains(
            "publicationYieldActive:\n                connectedRawHistoryCatchUpPublicationYield != nil"
        ), "projection deferral must open only for the exact process-local yield token")
        XCTAssertTrue(source.contains(
            "var onConnectedRawCatchUpPublicationYield:"
        ))
        XCTAssertTrue(source.contains(
            "var connectedRawCatchUpPublicationYieldIsNeeded: (() -> Bool)?"
        ))
        XCTAssertTrue(source.contains(
            "func releaseConnectedRawCatchUpPublicationYieldForLifecycle("
        ))
        XCTAssertTrue(source.contains(
            "private struct ConnectedRawHistoryCatchUpPublicationYield"
        ))
        XCTAssertTrue(source.contains("let token: UUID"))
        XCTAssertTrue(source.contains("let deadline: Date"))
        XCTAssertTrue(source.contains(
            "scheduleConnectedRawHistoryCatchUpContinuation("
        ))
        XCTAssertTrue(source.contains("rows_per_s=%.3f"))
        XCTAssertTrue(source.contains("frontier_advance_s=%.3f"))
        let continuationStart = try XCTUnwrap(source.range(
            of: "private func scheduleConnectedRawHistoryCatchUpContinuation("
        ))
        let continuationEnd = try XCTUnwrap(source.range(
            of: "/// Runs the terminal consumer materialization lanes",
            range: continuationStart.upperBound..<source.endIndex
        ))
        let continuation = String(
            source[continuationStart.lowerBound..<continuationEnd.lowerBound]
        )
        XCTAssertFalse(continuation.contains(
            "requestOfflineHistoricalSyncIfNeeded("
        ))
        XCTAssertFalse(continuation.contains("cancelPeripheralConnection("))
        XCTAssertFalse(continuation.contains(
            "rebuildCentralForWedgedSessionOnce("
        ))
        XCTAssertTrue(continuation.contains(
            "beginConnectedRawHistoryCatchUpPublicationYield("
        ))
        XCTAssertTrue(continuation.contains(
            "publicationYieldRunnable: publicationYieldRunnable"
        ))
        XCTAssertTrue(continuation.contains(
            "publicationAttemptCompleted: true"
        ))
        XCTAssertTrue(continuation.contains(
            "connectedRawHistoryCatchUpContinuationPending = true"
        ))
        XCTAssertTrue(continuation.contains(
            "action=await_fresh_2a37_exact_authority_no_radio_command"
        ))

        let motionOffloadStart = try XCTUnwrap(source.range(
            of: "private func resumePendingWorkoutHistoricalMotionBankOffloadIfNeeded("
        ))
        let motionOffloadTail = String(source[motionOffloadStart.lowerBound...])
        XCTAssertTrue(motionOffloadTail.prefix(2_500).contains(
            "guard connectedRawHistoryCatchUpPublicationYield == nil"
        ))
        XCTAssertTrue(motionOffloadTail.prefix(2_500).contains(
            "allow_present_capture_rearm_no_history_command"
        ))

        let acceptedOrphanStart = try XCTUnwrap(source.range(
            of: "reason: \"first_accepted_hr_orphan_ingress_replay\""
        ))
        let acceptedOrphanTail = String(source[
            acceptedOrphanStart.lowerBound...
        ].prefix(320))
        XCTAssertTrue(acceptedOrphanTail.contains(
            "retainHistoricalRequest: false"
        ), "raw orphan archival on accepted HR must never mint a generic transport request")

        let flushStart = try XCTUnwrap(source.range(
            of: "let durableMetricFacts = self.historicalMetricDurabilityFence"
        ))
        let ackEffect = try XCTUnwrap(source.range(
            of: "let next = self.historyDrain.durableFlushCompleted(",
            range: flushStart.upperBound..<source.endIndex
        ))
        let flushToACK = String(source[flushStart.lowerBound..<ackEffect.lowerBound])
        XCTAssertTrue(flushToACK.contains(
            "commitDurableHistoricalRawFrontier("
        ))
        XCTAssertTrue(flushToACK.contains("if error == nil"))
        let successfulFlush = try XCTUnwrap(flushToACK.range(
            of: "if error == nil"
        ))
        let frontierCommit = try XCTUnwrap(flushToACK.range(
            of: "commitDurableHistoricalRawFrontier("
        ))
        XCTAssertLessThan(
            successfulFlush.lowerBound,
            frontierCommit.lowerBound,
            "frontier advancement must remain behind the successful canonical flush and before ACK reducer advancement"
        )

        let ackStart = try XCTUnwrap(source.range(
            of: "private func completeHistoricalACKAcceptance("
        ))
        let ackEnd = try XCTUnwrap(source.range(
            of: "private func reackDurableHistoricalReplay(",
            range: ackStart.upperBound..<source.endIndex
        ))
        let ack = String(source[ackStart.lowerBound..<ackEnd.lowerBound])
        let motionStop = try XCTUnwrap(ack.range(
            of: "shouldFinishConnectedMotionBankHistoryAtACKBoundary("
        ))
        let motionCleanACKBoundaryCapture = try XCTUnwrap(ack.range(
            of: "captureDurablyAcknowledgedPrefixBoundary()",
            range: motionStop.upperBound..<ack.endIndex
        ))
        let motionLocalACKFinish = try XCTUnwrap(ack.range(
            of: "finishConnectedHistoryFailureWithoutDisconnectIfNeeded(",
            range: motionCleanACKBoundaryCapture.upperBound..<ack.endIndex
        ))
        let burstStop = try XCTUnwrap(ack.range(
            of: "shouldFinishConnectedRawHistoryCatchUpAtACKBoundary("
        ))
        let cleanACKBoundaryCapture = try XCTUnwrap(ack.range(
            of: "captureDurablyAcknowledgedPrefixBoundary()",
            range: burstStop.upperBound..<ack.endIndex
        ))
        let localACKFinish = try XCTUnwrap(ack.range(
            of: "finishConnectedHistoryFailureWithoutDisconnectIfNeeded(",
            range: cleanACKBoundaryCapture.upperBound..<ack.endIndex
        ))
        let nextPage = try XCTUnwrap(ack.range(
            of: "armHistoricalPageContinuationAfterACK("
        ))
        XCTAssertLessThan(motionStop.lowerBound, motionCleanACKBoundaryCapture.lowerBound)
        XCTAssertLessThan(motionCleanACKBoundaryCapture.lowerBound, motionLocalACKFinish.lowerBound)
        XCTAssertLessThan(motionLocalACKFinish.lowerBound, nextPage.lowerBound)
        let motionBoundary = String(
            ack[motionStop.lowerBound..<burstStop.lowerBound]
        )
        XCTAssertFalse(motionBoundary.contains("sendCommand("))
        XCTAssertFalse(motionBoundary.contains("cancelPeripheralConnection("))
        XCTAssertFalse(motionBoundary.contains("rebuildCentralForWedgedSessionOnce("))
        XCTAssertFalse(motionBoundary.contains("Cmd.abortHistoricalTransmits"))
        XCTAssertLessThan(burstStop.lowerBound, cleanACKBoundaryCapture.lowerBound)
        XCTAssertLessThan(cleanACKBoundaryCapture.lowerBound, localACKFinish.lowerBound)
        XCTAssertLessThan(localACKFinish.lowerBound, nextPage.lowerBound)
        XCTAssertLessThan(burstStop.lowerBound, nextPage.lowerBound)
        XCTAssertTrue(ack.contains(
            "reason: \"exact_connected_raw_ack_burst_boundary\""
        ))
        XCTAssertTrue(ack.contains(
            "reason: \"exact_connected_motion_bank_background_ack_boundary\""
        ))
        XCTAssertFalse(ack.contains("cancelPeripheralConnection("))
        XCTAssertFalse(ack.contains("rebuildCentralForWedgedSessionOnce("))

        let finishStart = try XCTUnwrap(source.range(
            of: "private func finishOfflineHistoricalSync("
        ))
        let finishEnd = try XCTUnwrap(source.range(
            of: "private func finalizeOfflineHistoricalSyncAfterLiveRestoration(",
            range: finishStart.upperBound..<source.endIndex
        ))
        let finish = String(source[finishStart.lowerBound..<finishEnd.lowerBound])
        XCTAssertTrue(finish.contains(
            "connectedRawCleanACKFinishAuthority"
        ))
        XCTAssertTrue(finish.contains(
            "connectedMotionBankCleanACKFinishAuthority"
        ))
        XCTAssertGreaterThanOrEqual(
            finish.components(
                separatedBy:
                    "historicalIngressSpool.matches(\n                        authority.ingressBoundary"
            ).count - 1,
            2,
            "raw and motion clean-ACK authorities must both fail closed when their spool cursor becomes stale"
        )
        XCTAssertTrue(finish.contains(
            ".coversEntireJournal == true"
        ))
        XCTAssertTrue(finish.contains("connectedRawIngressFullyAcknowledged"))
        XCTAssertTrue(finish.contains("connectedMotionBankIngressFullyAcknowledged"))
        XCTAssertTrue(finish.contains("historicalIngressSpool?.remove()"))
        XCTAssertTrue(finish.contains("pendingHistoricalTransportEventCount == 0"))
        XCTAssertTrue(finish.contains("historyDrain.pendingPersistenceCount == 0"))
        XCTAssertTrue(finish.contains("!historicalAdmissionBatchInFlight"))
        XCTAssertTrue(finish.contains("connectedRawConsumedPrefixRetirementSafe"))
        XCTAssertTrue(finish.contains(
            "shouldRetireConnectedRawConsumedPrefix("
        ))
        XCTAssertTrue(finish.contains(
            "hasDeferredEvent:\n                    historicalIngressDeferredEvent != nil"
        ))
        XCTAssertTrue(finish.contains("!historyDurableFlushInFlight"))
        XCTAssertTrue(finish.contains("pendingHistoryEndACK == nil"))
        XCTAssertTrue(finish.contains("!historyACKGate.requiresHistoryCallbackDeferral"))
        XCTAssertTrue(finish.contains("retireConsumedPrefix("))
        XCTAssertTrue(finish.contains(
            "through: connectedCleanACKFinishAuthority"
        ))
        XCTAssertTrue(finish.contains(
            "!boundedConnectedRawCatchUp"
        ), "a connected-raw terminal without the exact clean-ACK finish authority must retain its full spool")

        let metadataStart = try XCTUnwrap(source.range(
            of: "private func handleHistoryMetadata("
        ))
        let dataStart = try XCTUnwrap(source.range(
            of: "private func handleHistoricalData(",
            range: metadataStart.upperBound..<source.endIndex
        ))
        let drainStart = try XCTUnwrap(source.range(
            of: "private func drainNextHistoricalTransportEventBurst(",
            range: dataStart.upperBound..<source.endIndex
        ))
        let metadata = String(source[metadataStart.lowerBound..<dataStart.lowerBound])
        let data = String(source[dataStart.lowerBound..<drainStart.lowerBound])
        for handler in [metadata, data] {
            XCTAssertTrue(handler.contains("shouldAcceptConnectedRawHistoryIngress("))
            XCTAssertTrue(handler.contains("historyTransportPhaseFence.acceptsServe("))
            XCTAssertTrue(handler.contains("historicalAdmissionAttempt != nil"))
            XCTAssertTrue(handler.contains("finishConnectedHistoryFailureWithoutDisconnectIfNeeded("))
            XCTAssertFalse(handler.contains("rebuildCentralForWedgedSessionOnce("))
        }
        let metadataIngressEnd = try XCTUnwrap(metadata.range(
            of: "private func enqueueHistoricalIngress("
        ))
        let metadataIngress = String(metadata[..<metadataIngressEnd.lowerBound])
        XCTAssertFalse(metadataIngress.contains("cancelPeripheralConnection("))
        XCTAssertFalse(data.contains("cancelPeripheralConnection("))
        let dataGate = try XCTUnwrap(data.range(
            of: "shouldAcceptConnectedRawHistoryIngress("
        ))
        let acceptedGate = try XCTUnwrap(data.range(
            of: "guard ingressAccepted else",
            range: dataGate.upperBound..<data.endIndex
        ))
        let pageContinuationCancellation = try XCTUnwrap(data.range(
            of: "cancelHistoricalPageContinuationForAcceptedCurrentServeFrameIfNeeded(",
            range: acceptedGate.upperBound..<data.endIndex
        ))
        let firstFrameMutation = try XCTUnwrap(data.range(
            of: "recordResearchProbeCandidate("
        ))
        XCTAssertLessThan(dataGate.lowerBound, firstFrameMutation.lowerBound)
        XCTAssertLessThan(acceptedGate.lowerBound, pageContinuationCancellation.lowerBound)
        XCTAssertLessThan(
            pageContinuationCancellation.lowerBound,
            firstFrameMutation.lowerBound,
            "only a frame that crossed the callback-captured ingress gate may cancel the silence fallback"
        )
        let cancellationStart = try XCTUnwrap(source.range(
            of: "private func cancelHistoricalPageContinuationForAcceptedCurrentServeFrameIfNeeded("
        ))
        let cancellationEnd = try XCTUnwrap(source.range(
            of: "private func scheduleHistoricalTransportEventDrain(",
            range: cancellationStart.upperBound..<source.endIndex
        ))
        let cancellation = String(
            source[cancellationStart.lowerBound..<cancellationEnd.lowerBound]
        )
        XCTAssertTrue(cancellation.contains(
            "shouldCancelHistoricalPageContinuationForFrame("
        ))
        XCTAssertTrue(cancellation.contains("historicalPageContinuationTask?.cancel()"))
        for forbiddenMutation in [
            "pendingHistoryEndACK",
            "historicalIngressSpool",
            "historyACKGate",
            "writeCompletionLedger",
            "sendCommand(",
            "sendHistoryCommandAwaitingWriteConfirmation(",
            "Cmd.sendHistoricalData",
            "Cmd.historicalDataResult",
            "captureDurablyAcknowledgedPrefixBoundary(",
            "retireConsumedPrefix(",
            "processHistoricalDrainEffects("
        ] {
            XCTAssertFalse(
                cancellation.contains(forbiddenMutation),
                "accepted-frame cancellation must not mutate ACK, spool, durability, or transport state: \(forbiddenMutation)"
            )
        }
        let continuationArmStart = try XCTUnwrap(source.range(
            of: "private func armHistoricalPageContinuationAfterACK("
        ))
        let continuationArmEnd = try XCTUnwrap(source.range(
            of: "private func submitGate4DailyBankRearmAtDurableBoundaryIfSafe(",
            range: continuationArmStart.upperBound..<source.endIndex
        ))
        let continuationArm = String(
            source[continuationArmStart.lowerBound..<continuationArmEnd.lowerBound]
        )
        let cancellationFence = try XCTUnwrap(continuationArm.range(
            of: "guard !Task.isCancelled,"
        ))
        let continuationSend = try XCTUnwrap(continuationArm.range(
            of: "command: Cmd.sendHistoricalData"
        ))
        XCTAssertLessThan(
            cancellationFence.lowerBound,
            continuationSend.lowerBound,
            "an accepted frame's synchronous task cancellation must fence the next 0x16 send"
        )
        XCTAssertTrue(metadata.contains(
            "action=no_spool_no_progress_no_flush_no_ack_keep_2a37"
        ))
        XCTAssertTrue(data.contains(
            "action=no_spool_no_first_frame_no_admission_no_progress_keep_2a37"
        ))
        XCTAssertTrue(source.contains(
            "live_restored=%d terminal_and_live_restored=%d"
        ))
        let reassembly = try XCTUnwrap(source.range(
            of: "let completeFrames = proprietaryFrameReassembler.feed("
        ))
        let reassemblyTail = String(source[reassembly.lowerBound...].prefix(520))
        XCTAssertTrue(reassemblyTail.contains(
            "historyGeneration: historyPhase.generation"
        ))
        XCTAssertTrue(reassemblyTail.contains(
            "historyServeToken: historyPhase.serveToken"
        ))
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
            of: "let requestResult: ("
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

    func testConnectedMotionBankBackgroundACKBoundaryStopsOnlyExactInactiveSlice() {
        XCTAssertTrue(
            AtriaBLEManager.shouldFinishConnectedMotionBankHistoryAtACKBoundary(
                applicationIsActive: false,
                exactMotionBankAuthorityActive: true
            )
        )
        XCTAssertFalse(
            AtriaBLEManager.shouldFinishConnectedMotionBankHistoryAtACKBoundary(
                applicationIsActive: true,
                exactMotionBankAuthorityActive: true
            ),
            "a foreground page may continue under the existing transport budget"
        )
        XCTAssertFalse(
            AtriaBLEManager.shouldFinishConnectedMotionBankHistoryAtACKBoundary(
                applicationIsActive: false,
                exactMotionBankAuthorityActive: false
            ),
            "background state alone cannot finish a generic history generation"
        )
    }

    func testHistoricalRecoveryProgressIsSilentInactiveAndBoundedForeground() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertFalse(
            AtriaBLEManager.shouldPublishHistoricalRecoveryProgress(
                applicationIsActive: false,
                savedRecords: 1_000,
                lastPublishedRecords: nil,
                lastPublishedAt: nil,
                now: start
            )
        )
        XCTAssertFalse(
            AtriaBLEManager.shouldPublishHistoricalRecoveryProgress(
                applicationIsActive: true,
                compactMotionBankOnly: true,
                savedRecords: 1_000,
                lastPublishedRecords: nil,
                lastPublishedAt: nil,
                now: start
            ),
            "compact motion transport has no recovery terminal state and must never publish Syncing"
        )
        XCTAssertTrue(
            AtriaBLEManager.shouldPublishHistoricalRecoveryProgress(
                applicationIsActive: true,
                savedRecords: 1_000,
                lastPublishedRecords: nil,
                lastPublishedAt: nil,
                now: start
            )
        )
        XCTAssertFalse(
            AtriaBLEManager.shouldPublishHistoricalRecoveryProgress(
                applicationIsActive: true,
                savedRecords: 1_000,
                lastPublishedRecords: 1_000,
                lastPublishedAt: start,
                now: start
            ),
            "the foreground catch-up emits the suppressed exact count once"
        )
        XCTAssertFalse(
            AtriaBLEManager.shouldPublishHistoricalRecoveryProgress(
                applicationIsActive: true,
                savedRecords: 100,
                lastPublishedRecords: 1,
                lastPublishedAt: start,
                now: start.addingTimeInterval(14),
                minimumInterval: 15,
                minimumRecordDelta: 250
            )
        )
        XCTAssertTrue(
            AtriaBLEManager.shouldPublishHistoricalRecoveryProgress(
                applicationIsActive: true,
                savedRecords: 251,
                lastPublishedRecords: 1,
                lastPublishedAt: start,
                now: start.addingTimeInterval(1),
                minimumInterval: 15,
                minimumRecordDelta: 250
            )
        )
        XCTAssertTrue(
            AtriaBLEManager.shouldPublishHistoricalRecoveryProgress(
                applicationIsActive: true,
                savedRecords: 2,
                lastPublishedRecords: 1,
                lastPublishedAt: start,
                now: start.addingTimeInterval(15),
                minimumInterval: 15,
                minimumRecordDelta: 250
            )
        )
        XCTAssertFalse(
            AtriaBLEManager.shouldPublishHistoricalRecoveryProgress(
                applicationIsActive: true,
                savedRecords: 1,
                lastPublishedRecords: 1,
                lastPublishedAt: start,
                now: start.addingTimeInterval(30)
            ),
            "an unchanged row count never emits objectWillChange"
        )

        let source = try managerSource()
        let catchUpStart = try XCTUnwrap(source.range(
            of: "func catchUpHistoricalRecoveryProgressForForeground("
        ))
        let catchUpEnd = try XCTUnwrap(source.range(
            of: "/// Duty-cycle attribution",
            range: catchUpStart.upperBound..<source.endIndex
        ))
        let catchUp = String(
            source[catchUpStart.lowerBound..<catchUpEnd.lowerBound]
        )
        XCTAssertTrue(catchUp.contains("guard offlineHistoricalSyncInProgress"))
        XCTAssertTrue(catchUp.contains(
            "publishHistoricalRecoveryProgressIfNeeded(now: now)"
        ))
    }

    func testMotionBankCleanACKCooldownReusesPersistedRetryCadenceAcrossRelaunch() throws {
        let pageACK = Date(timeIntervalSince1970: 10_000)
        XCTAssertFalse(
            AtriaBLEManager.historicalMotionBankOffloadCadenceEligible(
                attempts: 1,
                now: pageACK.addingTimeInterval(14 * 60),
                lastStartedAt: pageACK
            )
        )
        XCTAssertTrue(
            AtriaBLEManager.historicalMotionBankOffloadCadenceEligible(
                attempts: 1,
                now: pageACK.addingTimeInterval(15 * 60),
                lastStartedAt: pageACK
            )
        )
        XCTAssertTrue(
            AtriaBLEManager.historicalMotionBankOffloadCadenceEligible(
                attempts: 0,
                now: pageACK,
                lastStartedAt: pageACK
            ),
            "a genuinely new attempt-zero ticket remains an immediate factual interval"
        )

        let source = try managerSource()
        let cooldownStart = try XCTUnwrap(source.range(
            of: "private func recordConnectedMotionBankBackgroundPageCooldown("
        ))
        let cooldownEnd = try XCTUnwrap(source.range(
            of: "nonisolated static func terminalMaterializationReleaseDisposition(",
            range: cooldownStart.upperBound..<source.endIndex
        ))
        let cooldown = String(
            source[cooldownStart.lowerBound..<cooldownEnd.lowerBound]
        )
        XCTAssertTrue(cooldown.contains(
            "workoutHistoricalMotionBankMinimumOffloadInterval"
        ))
        XCTAssertTrue(cooldown.contains(
            "connectedMotionBankHistoryAdmissionRetryNotBefore"
        ))
        XCTAssertTrue(cooldown.contains(
            "workoutHistoricalMotionBankLastOffloadStartedAtKey"
        ), "the ACK fence must survive process relaunch without a redundant key")

        let selectorStart = try XCTUnwrap(source.range(
            of: "private func resumePendingWorkoutHistoricalMotionBankOffloadIfNeeded("
        ))
        let selectorEnd = try XCTUnwrap(source.range(
            of: "/// Builds one replacement ticket",
            range: selectorStart.upperBound..<source.endIndex
        ))
        let selector = String(
            source[selectorStart.lowerBound..<selectorEnd.lowerBound]
        )
        let processGate = try XCTUnwrap(selector.range(
            of: "connectedMotionBankHistoryAdmissionRetryNotBefore"
        ))
        let durableMaintenance = try XCTUnwrap(selector.range(
            of: "maintainPendingWorkoutMotionBankTickets("
        ))
        XCTAssertLessThan(processGate.lowerBound, durableMaintenance.lowerBound,
                          "cooldown must suppress per-HR preferences/ledger maintenance")
    }

    func testExhaustedMotionBankBypassesArmedAndCooldownHotReturns() throws {
        XCTAssertTrue(
            AtriaBLEManager
                .shouldEvaluateExhaustedMotionBankBeforeHotPathReturn(
                    bankArmed: true,
                    retryCooldownActive: false,
                    boundTicketAttempts: 4,
                    historyOwnerActive: false
                )
        )
        XCTAssertTrue(
            AtriaBLEManager
                .shouldEvaluateExhaustedMotionBankBeforeHotPathReturn(
                    bankArmed: false,
                    retryCooldownActive: true,
                    boundTicketAttempts: 4,
                    historyOwnerActive: false
                )
        )
        XCTAssertFalse(
            AtriaBLEManager
                .shouldEvaluateExhaustedMotionBankBeforeHotPathReturn(
                    bankArmed: true,
                    retryCooldownActive: true,
                    boundTicketAttempts: 3,
                    historyOwnerActive: false
                )
        )
        XCTAssertFalse(
            AtriaBLEManager
                .shouldEvaluateExhaustedMotionBankBeforeHotPathReturn(
                    bankArmed: true,
                    retryCooldownActive: true,
                    boundTicketAttempts: 4,
                    historyOwnerActive: true
                ),
            "an active history generation retains its exact ticket until transport exits"
        )

        let source = try managerSource()
        let selectorStart = try XCTUnwrap(source.range(
            of: "private func resumePendingWorkoutHistoricalMotionBankOffloadIfNeeded("
        ))
        let selectorEnd = try XCTUnwrap(source.range(
            of: "/// Builds one replacement ticket",
            range: selectorStart.upperBound..<source.endIndex
        ))
        let selector = String(
            source[selectorStart.lowerBound..<selectorEnd.lowerBound]
        )
        let hotGate = try XCTUnwrap(selector.range(
            of: "if workoutHistoricalMotionBankArmed || retryCooldownActive"
        ))
        let exhaustedEvaluation = try XCTUnwrap(selector.range(
            of: "evaluateExhaustedMotionBankBeforeHotPathReturnIfNeeded(",
            range: hotGate.upperBound..<selector.endIndex
        ))
        let hotReturn = try XCTUnwrap(selector.range(
            of: "return false",
            range: exhaustedEvaluation.upperBound..<selector.endIndex
        ))
        let maintenance = try XCTUnwrap(selector.range(
            of: "maintainPendingWorkoutMotionBankTickets("
        ))
        XCTAssertLessThan(hotGate.lowerBound, exhaustedEvaluation.lowerBound)
        XCTAssertLessThan(exhaustedEvaluation.lowerBound, hotReturn.lowerBound)
        XCTAssertLessThan(hotReturn.lowerBound, maintenance.lowerBound,
                          "exhaustion evaluates once without restoring queue maintenance churn")

        let helperStart = try XCTUnwrap(source.range(
            of: "private func evaluateExhaustedMotionBankBeforeHotPathReturnIfNeeded("
        ))
        let helperEnd = try XCTUnwrap(source.range(
            of: "nonisolated static func shouldRunWorkoutMotionBankCoverageEvaluation(",
            range: helperStart.upperBound..<source.endIndex
        ))
        let helper = String(source[helperStart.lowerBound..<helperEnd.lowerBound])
        let exactPredicate = try XCTUnwrap(helper.range(
            of: "shouldEvaluateExhaustedMotionBankBeforeHotPathReturn("
        ))
        let terminalEvaluation = try XCTUnwrap(helper.range(
            of: "evaluatePendingWorkoutHistoricalMotionBankOffload(",
            range: exactPredicate.upperBound..<helper.endIndex
        ))
        XCTAssertLessThan(exactPredicate.lowerBound, terminalEvaluation.lowerBound)
        XCTAssertTrue(helper.contains(
            "forKey: Self.workoutHistoricalMotionBankActiveTicketIDKey"
        ))
        XCTAssertTrue(helper.contains("allowRetry: false"))
    }

    func testHistoryContinuityPersistsRareChangedFrameBeforePersistenceAndACK() throws {
        let source = try managerSource()
        let frameStart = try XCTUnwrap(source.range(
            of: "private func processAdmittedHistoricalFrame("
        ))
        let boundaryHelper = try XCTUnwrap(source.range(
            of: "private func persistHistorySequenceContinuityAtBoundary()",
            range: frameStart.upperBound..<source.endIndex
        ))
        let framePath = String(
            source[frameStart.lowerBound..<boundaryHelper.lowerBound]
        )
        let priorSnapshot = try XCTUnwrap(framePath.range(
            of: "let priorContinuity = historyDrain.continuitySnapshot"
        ))
        let receiveFrame = try XCTUnwrap(framePath.range(
            of: "let effects = historyDrain.receiveFrame("
        ))
        let changedSave = try XCTUnwrap(framePath.range(
            of: "persistHistorySequenceContinuityIfChanged(from: priorContinuity)"
        ))
        let persistenceDispatch = try XCTUnwrap(framePath.range(
            of: "guard effects.contains(where:"
        ))
        XCTAssertLessThan(priorSnapshot.lowerBound, receiveFrame.lowerBound)
        XCTAssertLessThan(receiveFrame.lowerBound, changedSave.lowerBound)
        XCTAssertLessThan(changedSave.lowerBound, persistenceDispatch.lowerBound,
                          "a permitted pending jump must be durable before row persistence/ACK can progress")
        XCTAssertTrue(framePath.contains(
            "guard historyDrain.continuitySnapshot != prior else { return }"
        ), "contiguous frames perform only an equality check and no store I/O")

        let ackStart = try XCTUnwrap(source.range(
            of: "private func completeHistoricalACKAcceptance("
        ))
        let ackEnd = try XCTUnwrap(source.range(
            of: "private func reackDurableHistoricalReplay(",
            range: ackStart.upperBound..<source.endIndex
        ))
        let ack = String(source[ackStart.lowerBound..<ackEnd.lowerBound])
        let reducerACK = try XCTUnwrap(ack.range(
            of: "let postACKEffects = historyDrain.ackCompleted("
        ))
        let continuitySave = try XCTUnwrap(ack.range(
            of: "persistHistorySequenceContinuityAtBoundary()",
            range: reducerACK.upperBound..<ack.endIndex
        ))
        let effectProcessing = try XCTUnwrap(ack.range(
            of: "processHistoricalDrainEffects(postACKEffects)",
            range: continuitySave.upperBound..<ack.endIndex
        ))
        let nextPage = try XCTUnwrap(ack.range(
            of: "armHistoricalPageContinuationAfterACK("
        ))
        XCTAssertLessThan(reducerACK.lowerBound, continuitySave.lowerBound)
        XCTAssertLessThan(continuitySave.lowerBound, effectProcessing.lowerBound)
        XCTAssertLessThan(effectProcessing.lowerBound, nextPage.lowerBound)

        let effectsStart = try XCTUnwrap(source.range(
            of: "private func processHistoricalDrainEffects("
        ))
        let effectsEnd = try XCTUnwrap(source.range(
            of: "private func scheduleHistorySequenceConfirmationRetry(",
            range: effectsStart.upperBound..<source.endIndex
        ))
        let effects = String(
            source[effectsStart.lowerBound..<effectsEnd.lowerBound]
        )
        let finished = try XCTUnwrap(effects.range(of: "case .finished(let generation):"))
        let failed = try XCTUnwrap(effects.range(
            of: "case .failed(let generation, let failure):",
            range: finished.upperBound..<effects.endIndex
        ))
        let finishedBody = String(effects[finished.lowerBound..<failed.lowerBound])
        let failedBody = String(effects[failed.lowerBound...])
        XCTAssertTrue(finishedBody.contains(
            "persistHistorySequenceContinuityAtBoundary()"
        ), "a terminal tail without an ACK still checkpoints continuity")
        let failureSave = try XCTUnwrap(failedBody.range(
            of: "persistHistorySequenceContinuityAtBoundary()"
        ))
        let failureFinish = try XCTUnwrap(failedBody.range(
            of: "finishHistoricalAdmissionAttempt(succeeded: false"
        ))
        XCTAssertLessThan(failureSave.lowerBound, failureFinish.lowerBound,
                          "unconfirmed discontinuity proof must survive the failure exit")
    }

    func testPermittedFullDrainPendingDiscontinuityRestoresAcrossPreACKRelaunch() {
        let first: [UInt8] = [0x2f, 0, 0, 0x10, 0x00]
        let jump: [UInt8] = [0x2f, 0, 0, 0x12, 0x00]
        var original = AtriaWhoop4HistoryDrainState()
        _ = original.begin(generation: 41)
        _ = original.receiveFrame(
            generation: 41,
            frameKey: "first",
            payload: first
        )
        let beforeJump = original.continuitySnapshot
        XCTAssertEqual(
            original.receiveFrame(
                generation: 41,
                frameKey: "jump",
                payload: jump,
                permitsUnconfirmedForwardDiscontinuity: true
            ),
            [.persistFrame(
                generation: 41,
                frameKey: "jump",
                payload: jump
            )]
        )
        let preACKSnapshot = original.continuitySnapshot
        XCTAssertNotEqual(preACKSnapshot, beforeJump)
        XCTAssertNotNil(preACKSnapshot.pending,
                        "the permitted lane continues but still creates durable replay proof")

        var relaunched = AtriaWhoop4HistoryDrainState()
        XCTAssertTrue(relaunched.restoreContinuitySnapshot(preACKSnapshot))
        _ = relaunched.begin(generation: 42)
        XCTAssertEqual(
            relaunched.receiveFrame(
                generation: 42,
                frameKey: "jump",
                payload: jump
            ),
            [.persistFrame(
                generation: 42,
                frameKey: "jump",
                payload: jump
            )]
        )
        XCTAssertNil(relaunched.continuitySnapshot.pending)
        XCTAssertEqual(relaunched.continuitySnapshot.confirmed.count, 1)
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
            9,
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
            of: "let requestResult: (",
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
            "reason: \"fresh_accepted_hr_prearm\""
        ))
        XCTAssertTrue(source.contains(
            "noRadioPresentCaptureTurn\n                            || Self"
        ), "the post-stop throttle edge must still rearm present capture under power pressure")
        XCTAssertTrue(source.contains(
            "if !workoutHistoricalMotionBankArmed {\n                armWorkoutHistoricalMotionBankIfPossible("
        ), "an already-armed bank must not rewrite duty-cycle defaults on every HR")

        let budgetStart = try XCTUnwrap(source.range(
            of: "private func armConnectedRealtimePreservingHistoryBudget("
        ))
        let budgetEnd = try XCTUnwrap(source.range(
            of: "private func resumePendingWorkoutHistoricalMotionBankOffloadIfNeeded",
            range: budgetStart.upperBound..<source.endIndex
        ))
        let budget = String(source[budgetStart.lowerBound..<budgetEnd.lowerBound])
        XCTAssertTrue(budget.contains("case .finishForPowerPressure:"))
        XCTAssertTrue(budget.contains(
            "exact_connected_history_power_pressure"
        ))
        XCTAssertTrue(budget.contains(
            "finishConnectedHistoryFailureWithoutDisconnectIfNeeded("
        ))
        XCTAssertFalse(budget.contains("cancelPeripheralConnection("))
        XCTAssertFalse(budget.contains("rebuildCentralForWedgedSessionOnce("))
    }

    func testWorkoutPreemptionUsesPhysicalFenceBeforeMotionBankArm() throws {
        XCTAssertEqual(
            AtriaBLEManager.workoutHistoricalTransportPreemptionDisposition(
                syncInProgress: true,
                historyProbeActive: false,
                preservesConnectedRealtimeOwner: true,
                linkConnected: true
            ),
            .disconnectConnectedHistoryOwner,
            "local owner release cannot prove an in-flight FIFO page stopped"
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
        let radioCancel = try XCTUnwrap(method.range(
            of: "cancelPeripheralConnection("
        ))
        let successorFence = try XCTUnwrap(method.range(
            of: "workoutHistoryPreemptionSuccessorGate.install("
        ))
        XCTAssertLessThan(successorFence.lowerBound, radioCancel.lowerBound)
        XCTAssertFalse(method.contains(
            "finishConnectedHistoryFailureWithoutDisconnectIfNeeded("
        ))
        XCTAssertTrue(method.contains(
            "preserveConnectedRealtimeOwner: preservesRealtimeOwner"
        ))

        let beginStart = try XCTUnwrap(source.range(
            of: "func beginWorkoutMotionLease(startedAt: Date, reason: String) {"
        ))
        let beginEnd = try XCTUnwrap(source.range(
            of: "private func yieldHistoricalTransportToExplicitWorkoutIfNeeded(",
            range: beginStart.upperBound..<source.endIndex
        ))
        let begin = String(source[beginStart.lowerBound..<beginEnd.lowerBound])
        let arm = try XCTUnwrap(begin.range(
            of: "armWorkoutHistoricalMotionBankIfPossible(reason: reason)"
        ))
        let yield = try XCTUnwrap(begin.range(
            of: "yieldHistoricalTransportToExplicitWorkoutIfNeeded(reason: reason)"
        ))
        XCTAssertLessThan(arm.lowerBound, yield.lowerBound)
        XCTAssertEqual(
            begin.components(
                separatedBy: "armWorkoutHistoricalMotionBankIfPossible("
            ).count - 1,
            1,
            "mid-page preemption must not arm again before disconnect quiescence"
        )

        let stopStart = try XCTUnwrap(source.range(
            of: "private func stopWorkoutHistoricalMotionBankIfPossible("
        ))
        let stopEnd = try XCTUnwrap(source.range(
            of: "nonisolated static func workoutHistoricalMotionBankOffloadRetryDelay(",
            range: stopStart.upperBound..<source.endIndex
        ))
        let stop = String(source[stopStart.lowerBound..<stopEnd.lowerBound])
        let historyGuard = try XCTUnwrap(stop.range(
            of: "guard !offlineHistoricalSyncInProgress, !historyOnlyProbeMode"
        ))
        let write = try XCTUnwrap(stop.range(of: "peripheral.writeValue("))
        XCTAssertLessThan(historyGuard.lowerBound, write.lowerBound)

        let armStart = try XCTUnwrap(source.range(
            of: "private func armWorkoutHistoricalMotionBankIfPossible("
        ))
        let armEnd = try XCTUnwrap(source.range(
            of: "private func checkpointDailyHistoricalMotionBankIfNeeded(",
            range: armStart.upperBound..<source.endIndex
        ))
        let armMethod = String(source[armStart.lowerBound..<armEnd.lowerBound])
        let successorHRGuard = try XCTUnwrap(armMethod.range(
            of: "workoutHistoryPreemptionSuccessorGate.blocksArm("
        ))
        let armWrite = try XCTUnwrap(armMethod.range(
            of: "Cmd.toggleIMUModeHistorical"
        ))
        XCTAssertLessThan(successorHRGuard.lowerBound, armWrite.lowerBound)

        let acceptedStart = try XCTUnwrap(source.range(
            of: "private func acceptHeartRate("
        ))
        let acceptedEnd = try XCTUnwrap(source.range(
            of: "private func beginAcceptedHeartRateBatch()",
            range: acceptedStart.upperBound..<source.endIndex
        ))
        let accepted = String(
            source[acceptedStart.lowerBound..<acceptedEnd.lowerBound]
        )
        let acceptedPublish = try XCTUnwrap(accepted.range(
            of: "lastAcceptedHRAt = sampleTime"
        ))
        let consumeSuccessor = try XCTUnwrap(accepted.range(
            of: ".consumeAfterAcceptedHeartRate("
        ))
        let acceptedArm = try XCTUnwrap(accepted.range(
            of: "armWorkoutHistoricalMotionBankIfPossible("
        ))
        XCTAssertLessThan(acceptedPublish.lowerBound, consumeSuccessor.lowerBound)
        XCTAssertLessThan(consumeSuccessor.lowerBound, acceptedArm.lowerBound)
    }

    func testNonDestructiveHistoryFailuresCannotReachARadioCancel() throws {
        let source = try managerSource()
        XCTAssertTrue(source.contains(
            "offlineHistoricalSyncPreservesConnectedRealtimeOwner ="
        ))
        XCTAssertTrue(source.contains(
            "offlineHistoricalSyncPreservesConnectedRealtimeOwner =\n            activeConnectedRealtimePreservingHistoryAuthorityExists("
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
            of: "activeConnectedRealtimePreservingHistoryAuthorityExists("
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
            "exact_connected_history_authority_lost_before_command"
        ))
        XCTAssertTrue(source.contains(
            "if !compactMotionBankOnly,\n           !connectedRawHistoryCatchUpContinuationPending,\n           terminalAndLiveRestored && offlineHistoricalSyncReachedTerminal"
        ))
        XCTAssertTrue(source.contains(
            "continue_bounded_transport_no_projection_scan"
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
            of: "private func acceptHeartRate("
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
            of: "private func acceptHeartRate("
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
            of: "private static func registerBackgroundTasks",
            range: transitionStart.upperBound..<app.endIndex
        ))
        let transition = String(
            app[transitionStart.lowerBound..<transitionEnd.lowerBound]
        )
        XCTAssertTrue(transition.contains("ble.handleInteractiveForeground("))
        XCTAssertTrue(transition.contains(
            "UIApplication.shared.applicationState == .active"
        ))
        XCTAssertTrue(transition.contains(
            "AtriaHistoricalProjectionForegroundGate.isBackgrounded"
        ))
        XCTAssertTrue(transition.contains(
            "foregroundBLETransitionAuthority.isCurrent(ticket)"
        ))
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
