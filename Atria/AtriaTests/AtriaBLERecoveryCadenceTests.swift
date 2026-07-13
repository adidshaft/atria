import XCTest
@testable import Atria

final class AtriaBLERecoveryCadenceTests: XCTestCase {
    func testProductionBatteryProbeRemainsDisabledUntilItPreservesR10() {
        XCTAssertFalse(AtriaBLEManager.proprietaryBatteryRefreshEnabled)
    }

    func testAutomaticHistoryNeverSeizesQualifiedProtectedR10Transport() {
        XCTAssertTrue(AtriaBLEManager.shouldDeferAutomaticOfflineSyncForProtectedR10Continuity(
            standardHROnlyMode: true,
            explicitUserRequest: false
        ), "qualification must not release automatic history onto the live proprietary pipe")
        XCTAssertFalse(AtriaBLEManager.shouldDeferAutomaticOfflineSyncForProtectedR10Continuity(
            standardHROnlyMode: true,
            explicitUserRequest: true
        ), "a deliberate user request may proceed through the later capability gates")
        XCTAssertFalse(AtriaBLEManager.shouldDeferAutomaticOfflineSyncForProtectedR10Continuity(
            standardHROnlyMode: false,
            explicitUserRequest: false
        ))
    }

    func testProprietaryBatteryRefreshRequiresQualifiedQuietTransport() {
        let now = Date(timeIntervalSince1970: 20_000)
        let qualified = now.addingTimeInterval(-120)
        let common = (
            lastFrame: now.addingTimeInterval(-1),
            lastAttempt: Optional<Date>.none,
            circuit: Optional<Date>.none
        )

        XCTAssertTrue(AtriaBLEManager.shouldRequestProprietaryBatteryRefresh(
            standardHROnlyMode: true,
            stableTransportProven: true,
            connected: true,
            currentConnectionR10Frames: 120,
            lastR10FrameAt: common.lastFrame,
            transportQualifiedAt: qualified,
            batteryIsFresh: false,
            activeWorkout: false,
            historyActive: false,
            requestPending: false,
            lastAttemptAt: common.lastAttempt,
            circuitOpenUntil: common.circuit,
            now: now
        ))
        XCTAssertFalse(AtriaBLEManager.shouldRequestProprietaryBatteryRefresh(
            standardHROnlyMode: true,
            stableTransportProven: true,
            connected: true,
            currentConnectionR10Frames: 120,
            lastR10FrameAt: common.lastFrame,
            transportQualifiedAt: now.addingTimeInterval(-119.999),
            batteryIsFresh: false,
            activeWorkout: false,
            historyActive: false,
            requestPending: false,
            lastAttemptAt: nil,
            circuitOpenUntil: nil,
            now: now
        ), "the extra two-minute post-qualification grace is strict")
    }

    func testProprietaryBatteryRefreshFailsClosedForSensitiveStatesAndCooldowns() {
        let now = Date(timeIntervalSince1970: 30_000)
        func eligible(workout: Bool = false,
                      history: Bool = false,
                      pending: Bool = false,
                      batteryFresh: Bool = false,
                      lastAttempt: Date? = nil,
                      circuit: Date? = nil) -> Bool {
            AtriaBLEManager.shouldRequestProprietaryBatteryRefresh(
                standardHROnlyMode: true,
                stableTransportProven: true,
                connected: true,
                currentConnectionR10Frames: 180,
                lastR10FrameAt: now,
                transportQualifiedAt: now.addingTimeInterval(-300),
                batteryIsFresh: batteryFresh,
                activeWorkout: workout,
                historyActive: history,
                requestPending: pending,
                lastAttemptAt: lastAttempt,
                circuitOpenUntil: circuit,
                now: now
            )
        }
        XCTAssertFalse(eligible(workout: true))
        XCTAssertFalse(eligible(history: true))
        XCTAssertFalse(eligible(pending: true))
        XCTAssertFalse(eligible(batteryFresh: true))
        XCTAssertFalse(eligible(lastAttempt: now.addingTimeInterval(-30 * 60 + 1)))
        XCTAssertFalse(eligible(circuit: now.addingTimeInterval(1)))
        XCTAssertTrue(eligible(lastAttempt: now.addingTimeInterval(-30 * 60)))
        XCTAssertTrue(eligible(circuit: now))
    }

    func testProprietaryBatteryResponseParsesOnlyMatchingValidatedCommand() {
        let response: [UInt8] = [0x24, 0x23, 0x1A, 0x0A, 0x01, 0xFF, 0x00,
                                 0x00, 0x00, 0x00, 0x00, 0x00]
        XCTAssertEqual(AtriaBLEManager.parseProprietaryBatteryResponse(
            response,
            expectedSequence: 0x23
        ), 26)
        XCTAssertNil(AtriaBLEManager.parseProprietaryBatteryResponse(
            response,
            expectedSequence: 0x22
        ))
        XCTAssertNil(AtriaBLEManager.parseProprietaryBatteryResponse(
            [0x24, 0x23, 0x1A, 0x0A, 0x00, 0xFF, 0x00],
            expectedSequence: 0x23
        ))
        XCTAssertNil(AtriaBLEManager.parseProprietaryBatteryResponse(
            [0x24, 0x23, 0x1A, 0x0A, 0x01, 0xE9, 0x03],
            expectedSequence: 0x23
        ), "100.1% is outside the protocol range")
    }

    func testProtectedR10OwnsTransportAcrossQualificationForAutomaticRecovery() {
        XCTAssertTrue(AtriaBLEManager.shouldDeferOfflineSyncForProtectedR10Qualification(
            standardHROnlyMode: true,
            stableTransportProven: false
        ), "history must not contaminate the protected R10 stability trial")
        XCTAssertTrue(AtriaBLEManager.shouldDeferOfflineSyncForProtectedR10Qualification(
            standardHROnlyMode: true,
            stableTransportProven: true
        ), "automatic history must not seize the proprietary pipe after qualification")
        XCTAssertFalse(AtriaBLEManager.shouldDeferOfflineSyncForProtectedR10Qualification(
            standardHROnlyMode: true,
            stableTransportProven: true,
            explicitUserRequest: true
        ), "an explicit action may deliberately enter the separately guarded history path")
        XCTAssertFalse(AtriaBLEManager.shouldDeferOfflineSyncForProtectedR10Qualification(
            standardHROnlyMode: false,
            stableTransportProven: false
        ))
    }

    func testProtectedR10StabilityRequiresDenseFreshCurrentEpochFrames() {
        let activation = Date(timeIntervalSince1970: 1_000)
        let now = activation.addingTimeInterval(90)
        XCTAssertTrue(AtriaBLEManager.protectedR10StabilityWindowIsProven(
            framesAfterActivation: 88,
            lastFrameAt: now.addingTimeInterval(-1),
            connectedAt: activation.addingTimeInterval(-5),
            activationAt: activation,
            now: now
        ))
        XCTAssertFalse(AtriaBLEManager.protectedR10StabilityWindowIsProven(
            framesAfterActivation: 1,
            lastFrameAt: activation.addingTimeInterval(1),
            connectedAt: activation.addingTimeInterval(-5),
            activationAt: activation,
            now: now
        ), "one early frame must not qualify a silent transport")
        XCTAssertFalse(AtriaBLEManager.protectedR10StabilityWindowIsProven(
            framesAfterActivation: 88,
            lastFrameAt: now.addingTimeInterval(-10),
            connectedAt: activation.addingTimeInterval(-5),
            activationAt: activation,
            now: now
        ), "the final frame must still be fresh")
        XCTAssertFalse(AtriaBLEManager.protectedR10StabilityWindowIsProven(
            framesAfterActivation: 88,
            lastFrameAt: activation.addingTimeInterval(-1),
            connectedAt: activation.addingTimeInterval(-5),
            activationAt: activation,
            now: now
        ), "a restored frame from before this arm cannot qualify")
    }

    func testProtectedR10RollbackNeedsRepeatedEarlyDisconnects() {
        XCTAssertFalse(AtriaBLEManager.shouldLatchProtectedR10RollbackForEarlyDisconnect(
            activationSent: true,
            connectedDuration: 30,
            previousEarlyDisconnects: 0
        ))
        XCTAssertTrue(AtriaBLEManager.shouldLatchProtectedR10RollbackForEarlyDisconnect(
            activationSent: true,
            connectedDuration: 30,
            previousEarlyDisconnects: 1
        ))
        XCTAssertFalse(AtriaBLEManager.shouldLatchProtectedR10RollbackForEarlyDisconnect(
            activationSent: true,
            connectedDuration: 91,
            previousEarlyDisconnects: 4
        ))
        XCTAssertFalse(AtriaBLEManager.shouldLatchProtectedR10RollbackForEarlyDisconnect(
            activationSent: false,
            connectedDuration: 10,
            previousEarlyDisconnects: 4
        ))
    }

    func testProtectedR10MissingFrameRollbackRequiresSentActivationAndZeroFrames() {
        XCTAssertTrue(AtriaBLEManager.shouldLatchProtectedR10RollbackForMissingFrames(
            activationSent: true,
            framesAfterActivation: 0
        ))
        XCTAssertFalse(AtriaBLEManager.shouldLatchProtectedR10RollbackForMissingFrames(
            activationSent: true,
            framesAfterActivation: 1
        ))
        XCTAssertFalse(AtriaBLEManager.shouldLatchProtectedR10RollbackForMissingFrames(
            activationSent: false,
            framesAfterActivation: 0
        ))
    }

    func testProtectedR10ClassifiesPassiveFrameEpochWithoutTreatingItAsSessionArm() {
        let connectedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
        XCTAssertTrue(AtriaBLEManager.protectedR10FrameBelongsToCurrentConnection(
            lastFrameAt: connectedAt.addingTimeInterval(0.2),
            connectedAt: connectedAt
        ))
        XCTAssertFalse(AtriaBLEManager.protectedR10FrameBelongsToCurrentConnection(
            lastFrameAt: connectedAt.addingTimeInterval(-0.1),
            connectedAt: connectedAt
        ))
        XCTAssertFalse(AtriaBLEManager.protectedR10FrameBelongsToCurrentConnection(
            lastFrameAt: nil,
            connectedAt: connectedAt
        ))
    }

    func testProtectedR10ActivationLeaseSurvivesReconnect() {
        let now = Date(timeIntervalSince1970: 50_000)

        XCTAssertEqual(AtriaBLEManager.protectedR10ActivationLeaseDelay(
            lastActivationAt: nil,
            now: now,
            minimumInterval: 600
        ), 0)
        XCTAssertEqual(AtriaBLEManager.protectedR10ActivationLeaseDelay(
            lastActivationAt: now.addingTimeInterval(-125),
            now: now,
            minimumInterval: 600
        ), 475,
        accuracy: 0.001)
        XCTAssertEqual(AtriaBLEManager.protectedR10ActivationLeaseDelay(
            lastActivationAt: now.addingTimeInterval(-900),
            now: now,
            minimumInterval: 600
        ), 0)
    }

    func testMotionHandshakeDiagnosticRequiresDoubleConsentAndUniqueRunID() throws {
        let type = AtriaBLEManager.MotionHandshakeDiagnosticConfiguration.self
        XCTAssertNil(type.parse(arguments: [type.enableArgument]))
        XCTAssertNil(type.parse(arguments: [
            type.enableArgument, type.confirmationArgument
        ]))
        XCTAssertNil(type.parse(arguments: [
            type.enableArgument, type.confirmationArgument,
            type.runIDArgument, "invalid/run"
        ]))

        let configuration = try XCTUnwrap(type.parse(arguments: [
            type.enableArgument, type.confirmationArgument,
            type.runIDArgument, "trial-001",
            type.addHRDelayArgument, "75"
        ]))
        XCTAssertEqual(configuration.runID, "trial-001")
        XCTAssertEqual(configuration.addHRDelay, 75)
        XCTAssertFalse(configuration.sendSingleR10Activation)
        XCTAssertEqual(configuration.restoreIdentifier,
                       "com.adidshaft.atria.ble-motion-diagnostic-trial-001")

        let activated = try XCTUnwrap(type.parse(arguments: [
            type.enableArgument, type.confirmationArgument,
            type.runIDArgument, "trial-002",
            type.activationConsentArgument
        ]))
        XCTAssertTrue(activated.sendSingleR10Activation)
    }

    func testMotionHandshakeDiagnosticBoundsHRDelay() throws {
        let type = AtriaBLEManager.MotionHandshakeDiagnosticConfiguration.self
        let arguments = [
            type.enableArgument, type.confirmationArgument,
            type.runIDArgument, "bounded",
            type.addHRDelayArgument, "2"
        ]
        XCTAssertEqual(try XCTUnwrap(type.parse(arguments: arguments)).addHRDelay, 60)
    }

    func testProtectedStandardHRKeepsPhysicallyUnstablePassiveR10Disabled() {
        XCTAssertFalse(AtriaBLEManager.shouldObservePassiveR10InProtectedStandardHR(
            characteristicUUID: AtriaBLEManager.UUIDs.strapStream5
        ))
        XCTAssertTrue(AtriaBLEManager.shouldObservePassiveR10InProtectedStandardHR(
            characteristicUUID: AtriaBLEManager.UUIDs.strapStream5,
            researchEnabled: true
        ))
        XCTAssertFalse(AtriaBLEManager.shouldObservePassiveR10InProtectedStandardHR(
            characteristicUUID: AtriaBLEManager.UUIDs.strapRX,
            researchEnabled: true
        ))
        XCTAssertFalse(AtriaBLEManager.shouldObservePassiveR10InProtectedStandardHR(
            characteristicUUID: AtriaBLEManager.UUIDs.strapStream4,
            researchEnabled: true
        ))
        XCTAssertFalse(AtriaBLEManager.shouldObservePassiveR10InProtectedStandardHR(
            characteristicUUID: AtriaBLEManager.UUIDs.strapStream7,
            researchEnabled: true
        ))
        XCTAssertFalse(AtriaBLEManager.shouldObservePassiveR10InProtectedStandardHR(
            characteristicUUID: AtriaBLEManager.UUIDs.strapTX,
            researchEnabled: true
        ))
    }

    func testProtectedBackgroundPreservesPersistedSafeRadioMode() {
        XCTAssertTrue(AtriaBLEManager.shouldUseStandardHROnlyInProtectedBackground(
            userSelectedBatterySaver: false,
            persistedStandardHROnly: true
        ), "A background edge must not undo the production-safe HR transport")
        XCTAssertFalse(AtriaBLEManager.shouldUseStandardHROnlyInProtectedBackground(
            userSelectedBatterySaver: true,
            persistedStandardHROnly: false
        ))
        XCTAssertTrue(AtriaBLEManager.shouldUseStandardHROnlyInProtectedBackground(
            userSelectedBatterySaver: true,
            persistedStandardHROnly: true
        ), "An explicit battery-saver choice remains authoritative")
    }

    func testLongWearSupervisorRunsInFullProtocolAndBatterySaverModes() {
        XCTAssertTrue(AtriaBLEManager.shouldRunLongWearSupervisor(
            longWearEnabled: true,
            standardHROnlyMode: false
        ), "Full protocol must retain checkpoints, workout analysis and watchdog recovery")
        XCTAssertTrue(AtriaBLEManager.shouldRunLongWearSupervisor(
            longWearEnabled: true,
            standardHROnlyMode: true
        ))
        XCTAssertFalse(AtriaBLEManager.shouldRunLongWearSupervisor(
            longWearEnabled: false,
            standardHROnlyMode: false
        ))
    }

    func testUnexpectedDisconnectPreservesExplicitWorkoutWithoutLongWear() {
        XCTAssertTrue(AtriaBLEManager.shouldPreserveSessionOnUnexpectedDisconnect(
            longWearEnabled: false,
            activeExplicitWorkout: true,
            userRequestedDisconnect: false
        ))
        XCTAssertFalse(AtriaBLEManager.shouldPreserveSessionOnUnexpectedDisconnect(
            longWearEnabled: false,
            activeExplicitWorkout: true,
            userRequestedDisconnect: true
        ))
        XCTAssertTrue(AtriaBLEManager.shouldPreserveSessionOnUnexpectedDisconnect(
            longWearEnabled: false,
            activeExplicitWorkout: false,
            userRequestedDisconnect: false
        ), "transient reconnects must not create hundreds of sub-minute saved fragments")
    }

    func testExplicitWorkoutAlwaysDefersHistoricalRadioTakeover() {
        XCTAssertTrue(AtriaBLEManager.shouldDeferOfflineSyncForExplicitWorkout(
            activeExplicitWorkout: true
        ))
        XCTAssertFalse(AtriaBLEManager.shouldDeferOfflineSyncForExplicitWorkout(
            activeExplicitWorkout: false
        ))
    }

    func testAutomaticHistoricalRecoveryNeverTakesOverConnectedRealtimeLink() {
        XCTAssertTrue(AtriaBLEManager.shouldDeferAutomaticOfflineSyncForConnectedLink(
            linkConnected: true,
            explicitUserRequest: false
        ), "aged/forced automatic retries must not interrupt a healthy connected stream")
        XCTAssertFalse(AtriaBLEManager.shouldDeferAutomaticOfflineSyncForConnectedLink(
            linkConnected: false,
            explicitUserRequest: false
        ), "pending recovery may arm before reconnect when the transport is already down")
        XCTAssertFalse(AtriaBLEManager.shouldDeferAutomaticOfflineSyncForConnectedLink(
            linkConnected: true,
            explicitUserRequest: true
        ), "a deliberate user sync remains authoritative")
    }

    func testOnlyDeliberateUIActionsCountAsConnectedHistoricalSyncIntent() {
        XCTAssertTrue(AtriaBLEManager.isExplicitUserOfflineSyncReason("manual_user_request"))
        XCTAssertTrue(AtriaBLEManager.isExplicitUserOfflineSyncReason("pull_to_refresh"))
        XCTAssertTrue(AtriaBLEManager.isExplicitUserOfflineSyncReason("home_missed_data_banner"))
        XCTAssertFalse(AtriaBLEManager.isExplicitUserOfflineSyncReason("confirmed_workout_archive_gap"))
        XCTAssertFalse(AtriaBLEManager.isExplicitUserOfflineSyncReason("sleep_auto_confirm_retry"))
        XCTAssertFalse(AtriaBLEManager.isExplicitUserOfflineSyncReason("bg_processing"))
    }

    func testProtectedHistoryRecoveryOwnsOnlyAnAlreadyDisconnectedGapReconnect() {
        XCTAssertTrue(AtriaBLEManager.shouldAllowProtectedHistoricalRecovery(
            linkConnected: false,
            exactGapPending: true,
            verifiedHistoryCapability: true,
            activeExplicitWorkout: false,
            syncInProgress: false,
            explicitUserRequest: false
        ))
        XCTAssertFalse(AtriaBLEManager.shouldAllowProtectedHistoricalRecovery(
            linkConnected: true,
            exactGapPending: true,
            verifiedHistoryCapability: true,
            activeExplicitWorkout: false,
            syncInProgress: false,
            explicitUserRequest: false
        ), "automatic recovery must never seize a healthy live HR/R10 pipe")
        XCTAssertFalse(AtriaBLEManager.shouldAllowProtectedHistoricalRecovery(
            linkConnected: false,
            exactGapPending: false,
            verifiedHistoryCapability: true,
            activeExplicitWorkout: false,
            syncInProgress: false,
            explicitUserRequest: false
        ))
    }

    func testProtectedHistoryRecoveryNeverPreemptsWorkoutOrUnverifiedHardware() {
        XCTAssertFalse(AtriaBLEManager.shouldAllowProtectedHistoricalRecovery(
            linkConnected: false,
            exactGapPending: true,
            verifiedHistoryCapability: true,
            activeExplicitWorkout: true,
            syncInProgress: false,
            explicitUserRequest: false
        ))
        XCTAssertFalse(AtriaBLEManager.shouldAllowProtectedHistoricalRecovery(
            linkConnected: false,
            exactGapPending: true,
            verifiedHistoryCapability: false,
            activeExplicitWorkout: false,
            syncInProgress: false,
            explicitUserRequest: false
        ))
        XCTAssertFalse(AtriaBLEManager.shouldAllowProtectedHistoricalRecovery(
            linkConnected: false,
            exactGapPending: true,
            verifiedHistoryCapability: true,
            activeExplicitWorkout: false,
            syncInProgress: true,
            explicitUserRequest: false
        ))
    }

    func testExplicitProtectedHistoryRequestStillHonorsSafetyGates() {
        XCTAssertTrue(AtriaBLEManager.shouldAllowProtectedHistoricalRecovery(
            linkConnected: true,
            exactGapPending: false,
            verifiedHistoryCapability: true,
            activeExplicitWorkout: false,
            syncInProgress: false,
            explicitUserRequest: true
        ))
        XCTAssertFalse(AtriaBLEManager.shouldAllowProtectedHistoricalRecovery(
            linkConnected: true,
            exactGapPending: false,
            verifiedHistoryCapability: true,
            activeExplicitWorkout: true,
            syncInProgress: false,
            explicitUserRequest: true
        ))
    }

    func testProductionHistoricalRecoveryUsesPlainSendHistoryHandshake() {
        let commands = AtriaBLEManager.productionHistoricalRecoveryInitCommands()

        XCTAssertEqual(commands, [[AtriaBLEManager.Cmd.sendHistoricalData, 0x00]])
        XCTAssertFalse(commands.contains { $0.first == AtriaBLEManager.Cmd.abortHistoricalTransmits })
        XCTAssertFalse(commands.contains { $0.first == AtriaBLEManager.Cmd.enterHighFreqSync })
    }

    func testHistoryDrainWaitsForEveryPersistenceAndDurableFlushBeforeACK() {
        var gate = AtriaBLEManager.HistoryDrainGate()
        gate.begin(generation: 7)
        XCTAssertTrue(gate.enqueueFrame(generation: 7))
        XCTAssertTrue(gate.enqueueFrame(generation: 7))
        gate.endReceived = true

        XCTAssertFalse(gate.mayFlush)
        XCTAssertFalse(gate.maySendACK)
        XCTAssertTrue(gate.finishPersistence(generation: 7, succeeded: true))
        XCTAssertFalse(gate.mayFlush)
        XCTAssertTrue(gate.finishPersistence(generation: 7, succeeded: true))
        XCTAssertTrue(gate.mayFlush)
        XCTAssertFalse(gate.maySendACK)
        gate.durableFlushCompleted = true
        XCTAssertTrue(gate.maySendACK)
    }

    func testHistoryDrainFailureAndStaleGenerationCanNeverACK() {
        var gate = AtriaBLEManager.HistoryDrainGate()
        gate.begin(generation: 9)
        XCTAssertFalse(gate.enqueueFrame(generation: 8))
        XCTAssertTrue(gate.enqueueFrame(generation: 9))
        gate.endReceived = true
        XCTAssertFalse(gate.finishPersistence(generation: 8, succeeded: true))
        XCTAssertTrue(gate.finishPersistence(generation: 9, succeeded: false))
        gate.durableFlushCompleted = true
        XCTAssertFalse(gate.mayFlush)
        XCTAssertFalse(gate.maySendACK)
    }

    func testHistoryTerminalIsNeverEnoughUntilACKWriteCompletes() {
        var gate = AtriaBLEManager.HistoryDrainGate()
        gate.begin(generation: 11)
        gate.endReceived = true
        gate.terminalReceived = true
        gate.durableFlushCompleted = true
        XCTAssertFalse(gate.mayFinishTerminal)
        gate.ackWriteInFlight = true
        XCTAssertFalse(gate.mayFinishTerminal)
        gate.ackWriteInFlight = false
        gate.ackWriteCompleted = true
        XCTAssertTrue(gate.mayFinishTerminal)

        var empty = AtriaBLEManager.HistoryDrainGate()
        empty.begin(generation: 12)
        empty.terminalReceived = true
        XCTAssertTrue(empty.mayFinishTerminal, "terminal has no ACK of its own")
    }

    func testHistoricalRecoveryCapabilityFailsClosedExceptVerifiedFourClass() {
        XCTAssertFalse(AtriaBLEManager.supportsVerifiedHistoricalRecovery(model: .unknown,
                                                                           previouslyVerified: false))
        XCTAssertFalse(AtriaBLEManager.supportsVerifiedHistoricalRecovery(model: .strap5,
                                                                           previouslyVerified: false))
        XCTAssertTrue(AtriaBLEManager.supportsVerifiedHistoricalRecovery(model: .strap4Class,
                                                                          previouslyVerified: false))
        XCTAssertTrue(AtriaBLEManager.supportsVerifiedHistoricalRecovery(model: .strap4,
                                                                          previouslyVerified: false))
        XCTAssertTrue(AtriaBLEManager.supportsVerifiedHistoricalRecovery(model: .unknown,
                                                                          previouslyVerified: true))
    }

    func testHistoricalRecoveryRestoresTheExactPreSyncRadioMode() {
        XCTAssertFalse(AtriaBLEManager.standardHROnlyModeAfterOfflineSync(
            modeBeforeSync: false
        ), "A full-protocol step stream must not be downgraded after recovery")
        XCTAssertTrue(AtriaBLEManager.standardHROnlyModeAfterOfflineSync(
            modeBeforeSync: true
        ), "An explicit Battery Saver mode must also survive recovery")
    }

    func testLegacyAutomaticHeartRateOnlyModeIsRepairedForStrapSteps() {
        XCTAssertTrue(AtriaBLEManager.shouldRepairLegacyAutomaticStandardHROnly(
            migrationWasRecorded: true,
            userSelectedBatterySaver: false,
            persistedStandardHROnly: true
        ), "an old automatic sync downgrade must not permanently disable R10 steps")
        XCTAssertTrue(AtriaBLEManager.shouldRepairLegacyAutomaticStandardHROnly(
            migrationWasRecorded: false,
            userSelectedBatterySaver: false,
            persistedStandardHROnly: false
        ))
        XCTAssertFalse(AtriaBLEManager.shouldRepairLegacyAutomaticStandardHROnly(
            migrationWasRecorded: true,
            userSelectedBatterySaver: true,
            persistedStandardHROnly: true
        ), "an explicit Battery Saver choice remains authoritative")
        XCTAssertFalse(AtriaBLEManager.shouldRepairLegacyAutomaticStandardHROnly(
            migrationWasRecorded: true,
            userSelectedBatterySaver: false,
            persistedStandardHROnly: false
        ))

        XCTAssertFalse(AtriaBLEManager.standardHROnlyModeAfterFullProtocolOverride(
            modeBeforeOverride: true,
            userSelectedBatterySaver: false
        ), "calibration expiry must not restore an obsolete automatic downgrade")
        XCTAssertTrue(AtriaBLEManager.standardHROnlyModeAfterFullProtocolOverride(
            modeBeforeOverride: true,
            userSelectedBatterySaver: true
        ))
        XCTAssertFalse(AtriaBLEManager.standardHROnlyModeAfterFullProtocolOverride(
            modeBeforeOverride: false,
            userSelectedBatterySaver: true
        ))
    }

    func testBackgroundRadioDowngradeIsSuppressedDuringExplicitWorkout() {
        XCTAssertFalse(AtriaBLEManager.shouldRestoreProtectedLongWearRadioInBackground(
            activeExplicitWorkout: true
        ))
        XCTAssertTrue(AtriaBLEManager.shouldRestoreProtectedLongWearRadioInBackground(
            activeExplicitWorkout: false
        ))
    }

    func testExplicitWorkoutOwnsBLEContinuityWithoutLongWear() {
        XCTAssertTrue(AtriaBLEManager.isBLEContinuityRelevant(
            longWearEnabled: false,
            activeExplicitWorkout: true
        ))
        XCTAssertTrue(AtriaBLEManager.isBLEContinuityRelevant(
            longWearEnabled: true,
            activeExplicitWorkout: false
        ))
        XCTAssertFalse(AtriaBLEManager.isBLEContinuityRelevant(
            longWearEnabled: false,
            activeExplicitWorkout: false
        ))
    }

    func testRangeLossBackfillNeedsRowsFromCurrentAttemptBeforeClearing() {
        XCTAssertFalse(AtriaBLEManager.rangeLossBackfillCanClear(newRows: 0))
        XCTAssertTrue(AtriaBLEManager.rangeLossBackfillCanClear(newRows: 1))
        XCTAssertFalse(AtriaBLEManager.rangeLossBackfillCanClear(
            newRows: 20,
            hasRequestedWindow: true,
            requestedWindowMetricProgress: false
        ))
        XCTAssertFalse(AtriaBLEManager.rangeLossBackfillCanClear(
            newRows: 1,
            hasRequestedWindow: true,
            requestedWindowMetricProgress: true
        ), "Exact workout recovery must wait for coverage-aware rehydration")
    }

    func testRequestedRecoveryProgressRequiresMetricUsableRowInsideExactWindow() {
        let start = 1_783_768_620.0
        let end = start + 3_000

        XCTAssertFalse(AtriaBLEManager.requestedRecoveryRowProvidesMetricProgress(
            metricUsable: false,
            effectiveUnix: UInt32(start + 60),
            requestedStart: start,
            requestedEnd: end
        ), "An overlapping diagnostic frame cannot resolve or advance HR recovery")
        XCTAssertFalse(AtriaBLEManager.requestedRecoveryRowProvidesMetricProgress(
            metricUsable: true,
            effectiveUnix: UInt32(start - 1),
            requestedStart: start,
            requestedEnd: end
        ))
        XCTAssertTrue(AtriaBLEManager.requestedRecoveryRowProvidesMetricProgress(
            metricUsable: true,
            effectiveUnix: UInt32(start + 60),
            requestedStart: start,
            requestedEnd: end
        ))
    }

    func testRestoredProprietaryNotificationStateIncludesAlreadyActiveStream() {
        let active = AtriaBLEManager.alreadyActiveProprietaryNotifications([
            (AtriaBLEManager.UUIDs.strapRX, true),
            (AtriaBLEManager.UUIDs.strapStream5, true),
            (AtriaBLEManager.UUIDs.strapStream7, false),
            (AtriaBLEManager.UUIDs.heartRateMeasure, true),
        ])

        XCTAssertEqual(active, [
            AtriaBLEManager.UUIDs.strapRX,
            AtriaBLEManager.UUIDs.strapStream5,
        ])
    }

    func testR10ArmHealthRejectsFrameFromBeforeCurrentArm() {
        let arm = Date(timeIntervalSinceReferenceDate: 800_000_000)

        XCTAssertFalse(AtriaBLEManager.r10FrameConfirmsCurrentArm(
            lastFrameAt: arm.addingTimeInterval(-0.1),
            armSentAt: arm,
            now: arm.addingTimeInterval(4)
        ), "A just-received frame from the old stream must not suppress reconnect recovery")
        XCTAssertTrue(AtriaBLEManager.r10FrameConfirmsCurrentArm(
            lastFrameAt: arm.addingTimeInterval(0.1),
            armSentAt: arm,
            now: arm.addingTimeInterval(4)
        ))
    }

    func testR10ArmHealthRejectsStaleOrFutureFrames() {
        let arm = Date(timeIntervalSinceReferenceDate: 800_000_000)

        XCTAssertFalse(AtriaBLEManager.r10FrameConfirmsCurrentArm(
            lastFrameAt: arm.addingTimeInterval(1),
            armSentAt: arm,
            now: arm.addingTimeInterval(7)
        ))
        XCTAssertFalse(AtriaBLEManager.r10FrameConfirmsCurrentArm(
            lastFrameAt: arm.addingTimeInterval(5),
            armSentAt: arm,
            now: arm.addingTimeInterval(4)
        ))
    }

    func testR10FramePermanentlyProvesCurrentArmEpoch() {
        let arm = Date(timeIntervalSinceReferenceDate: 800_000_000)

        XCTAssertFalse(AtriaBLEManager.r10FrameProvesCurrentArm(
            lastFrameAt: nil,
            evidenceEpoch: arm,
            now: arm.addingTimeInterval(120)
        ))
        XCTAssertFalse(AtriaBLEManager.r10FrameProvesCurrentArm(
            lastFrameAt: arm.addingTimeInterval(-0.001),
            evidenceEpoch: arm,
            now: arm.addingTimeInterval(120)
        ))
        XCTAssertTrue(AtriaBLEManager.r10FrameProvesCurrentArm(
            lastFrameAt: arm.addingTimeInterval(60),
            evidenceEpoch: arm,
            now: arm.addingTimeInterval(120)
        ))
        XCTAssertFalse(AtriaBLEManager.r10FrameProvesCurrentArm(
            lastFrameAt: arm.addingTimeInterval(121),
            evidenceEpoch: arm,
            now: arm.addingTimeInterval(120)
        ))
    }

    func testStepCalibrationOverridesLowBatteryMotionDeferral() {
        XCTAssertFalse(AtriaBLEManager.shouldArmHighFrequencyMotion(
            batteryLevel: 10,
            isCharging: false
        ))
        XCTAssertTrue(AtriaBLEManager.shouldArmHighFrequencyMotion(
            batteryLevel: 10,
            isCharging: false,
            calibrationActive: true
        ), "An explicitly armed calibration must capture motion even at low battery")
    }

    func testR10LivenessIgnoresFreshFramesAndIneligibleModes() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        XCTAssertEqual(AtriaBLEManager.r10LivenessAction(
            eligible: true,
            connected: true,
            realtimeArmed: true,
            lastFrameAt: now.addingTimeInterval(-2),
            lastRearmAt: nil,
            lastRediscoveryAt: nil,
            now: now
        ), .none)
        XCTAssertEqual(AtriaBLEManager.r10LivenessAction(
            eligible: false,
            connected: true,
            realtimeArmed: true,
            lastFrameAt: nil,
            lastRearmAt: nil,
            lastRediscoveryAt: nil,
            now: now
        ), .none)
        XCTAssertEqual(AtriaBLEManager.r10LivenessAction(
            eligible: true,
            connected: false,
            realtimeArmed: true,
            lastFrameAt: nil,
            lastRearmAt: nil,
            lastRediscoveryAt: nil,
            now: now
        ), .none)
    }

    func testR10LivenessRearmsAStaleStreamDespiteHealthyHRLink() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        XCTAssertEqual(AtriaBLEManager.r10LivenessAction(
            eligible: true,
            connected: true,
            realtimeArmed: true,
            lastFrameAt: now.addingTimeInterval(-61),
            lastRearmAt: nil,
            lastRediscoveryAt: nil,
            now: now
        ), .rearm)
    }

    func testR10LivenessEscalatesAfterGraceAndHonorsRediscoveryCooldown() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let staleFrame = now.addingTimeInterval(-61)
        let rearm = now.addingTimeInterval(-61)
        XCTAssertEqual(AtriaBLEManager.r10LivenessAction(
            eligible: true,
            connected: true,
            realtimeArmed: true,
            lastFrameAt: staleFrame,
            lastRearmAt: rearm,
            lastRediscoveryAt: nil,
            now: now
        ), .rediscover)
        XCTAssertEqual(AtriaBLEManager.r10LivenessAction(
            eligible: true,
            connected: true,
            realtimeArmed: true,
            lastFrameAt: staleFrame,
            lastRearmAt: rearm,
            lastRediscoveryAt: now.addingTimeInterval(-30),
            now: now
        ), .none)
        XCTAssertEqual(AtriaBLEManager.r10LivenessAction(
            eligible: true,
            connected: true,
            realtimeArmed: true,
            lastFrameAt: staleFrame,
            lastRearmAt: now.addingTimeInterval(-601),
            lastRediscoveryAt: now.addingTimeInterval(-30),
            now: now
        ), .rearm, "A command re-arm is rate-limited to once per ten minutes")
    }

    func testImplausibleBatteryDropRequiresCorroborationEvenWithOlderCache() {
        let acceptedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)

        XCTAssertTrue(AtriaBLEManager.shouldQuarantineBatteryLevel(
            previousLevel: 100,
            previousAcceptedAt: acceptedAt,
            incomingLevel: 10,
            receivedAt: acceptedAt.addingTimeInterval(5)
        ))
        XCTAssertTrue(AtriaBLEManager.shouldQuarantineBatteryLevel(
            previousLevel: 100,
            previousAcceptedAt: acceptedAt,
            incomingLevel: 10,
            receivedAt: acceptedAt.addingTimeInterval(60)
        ))
        XCTAssertFalse(AtriaBLEManager.shouldQuarantineBatteryLevel(
            previousLevel: 74,
            previousAcceptedAt: acceptedAt,
            incomingLevel: 73,
            receivedAt: acceptedAt.addingTimeInterval(5)
        ))
    }

    func testFirstOppositeExtremeLiveReadDoesNotReplaceHydratedDisplayCache() {
        let cachedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let decision = AtriaBLEManager.batteryLevelAcceptanceDecision(
            previousLevel: 100,
            previousAcceptedAt: cachedAt,
            incomingLevel: 10,
            receivedAt: cachedAt.addingTimeInterval(5),
            pending: nil,
            previousIsCached: true
        )
        guard case .quarantine(let candidate) = decision else {
            return XCTFail("A reconnect must not flash cached 100% down to a one-off 10% read")
        }
        XCTAssertEqual(candidate.level, 10)
        XCTAssertEqual(candidate.confirmations, 1)
    }

    func testCachedLowBatteryRejectsOneOffHundredPercentSpike() {
        let cachedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let firstAt = cachedAt.addingTimeInterval(5)
        let first = AtriaBLEManager.batteryLevelAcceptanceDecision(
            previousLevel: 10,
            previousAcceptedAt: cachedAt,
            incomingLevel: 100,
            receivedAt: firstAt,
            pending: nil,
            previousIsCached: true
        )
        guard case .quarantine(let candidate) = first else {
            return XCTFail("A one-off cached-low to 100% jump must not flash as full")
        }
        XCTAssertEqual(candidate.level, 100)
        XCTAssertEqual(candidate.confirmations, 1)
    }

    func testCachedLowBatteryNeverAcceptsHundredPercentFromRepetitionAlone() {
        let cachedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let firstAt = cachedAt.addingTimeInterval(5)
        let first = AtriaBLEManager.batteryLevelAcceptanceDecision(
            previousLevel: 10,
            previousAcceptedAt: cachedAt,
            incomingLevel: 100,
            receivedAt: firstAt,
            pending: nil,
            previousIsCached: true
        )
        guard case .quarantine(let firstCandidate) = first else {
            return XCTFail("Expected initial upward spike quarantine")
        }
        let second = AtriaBLEManager.batteryLevelAcceptanceDecision(
            previousLevel: 10,
            previousAcceptedAt: cachedAt,
            incomingLevel: 100,
            receivedAt: firstAt.addingTimeInterval(30),
            pending: firstCandidate,
            previousIsCached: true
        )
        guard case .quarantine(let secondCandidate) = second else {
            return XCTFail("Expected second upward reading to remain quarantined")
        }
        guard case .quarantine(let finalCandidate) = AtriaBLEManager.batteryLevelAcceptanceDecision(
            previousLevel: 10,
            previousAcceptedAt: cachedAt,
            incomingLevel: 100,
            receivedAt: firstAt.addingTimeInterval(15 * 60),
            pending: secondCandidate,
            previousIsCached: true
        ) else {
            return XCTFail("A physically disproven 100% sentinel must not become truth through repetition")
        }
        XCTAssertGreaterThanOrEqual(finalCandidate.confirmations, 3)
    }

    func testImplausibleBatteryDropRequiresThreeReadingsAcrossOneMinute() {
        let acceptedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let firstAt = acceptedAt.addingTimeInterval(5)

        let first = AtriaBLEManager.batteryLevelAcceptanceDecision(
            previousLevel: 100,
            previousAcceptedAt: acceptedAt,
            incomingLevel: 10,
            receivedAt: firstAt,
            pending: nil
        )
        guard case .quarantine(let firstCandidate) = first else {
            return XCTFail("The first implausible drop must remain quarantined")
        }

        let second = AtriaBLEManager.batteryLevelAcceptanceDecision(
            previousLevel: 100,
            previousAcceptedAt: acceptedAt,
            incomingLevel: 10,
            receivedAt: firstAt.addingTimeInterval(7.6),
            pending: firstCandidate
        )
        guard case .quarantine(let secondCandidate) = second else {
            return XCTFail("A repeated transient reading after 7.6 seconds must not replace 100%")
        }
        XCTAssertEqual(secondCandidate.confirmations, 2)

        let earlyThird = AtriaBLEManager.batteryLevelAcceptanceDecision(
            previousLevel: 100,
            previousAcceptedAt: acceptedAt,
            incomingLevel: 10,
            receivedAt: firstAt.addingTimeInterval(30),
            pending: secondCandidate
        )
        guard case .quarantine(let thirdCandidate) = earlyThird else {
            return XCTFail("Three readings inside one minute must remain quarantined")
        }

        guard case .quarantine = AtriaBLEManager.batteryLevelAcceptanceDecision(
            previousLevel: 100,
            previousAcceptedAt: acceptedAt,
            incomingLevel: 10,
            receivedAt: firstAt.addingTimeInterval(15 * 60),
            pending: thirdCandidate
        ) else {
            return XCTFail("A 100% to 10% restoration sentinel must remain quarantined")
        }
    }

    func testLiveMidrangeToTenPercentCannotBecomeTruthAfterOneMinute() {
        let acceptedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let first = AtriaBLEManager.batteryLevelAcceptanceDecision(
            previousLevel: 89,
            previousAcceptedAt: acceptedAt,
            incomingLevel: 10,
            receivedAt: acceptedAt.addingTimeInterval(5),
            pending: nil
        )
        guard case .quarantine(let firstCandidate) = first else {
            return XCTFail("A live 89% to 10% jump must be treated as a restoration sentinel")
        }
        let oneMinute = AtriaBLEManager.batteryLevelAcceptanceDecision(
            previousLevel: 89,
            previousAcceptedAt: acceptedAt,
            incomingLevel: 10,
            receivedAt: acceptedAt.addingTimeInterval(66),
            pending: firstCandidate
        )
        guard case .quarantine(let sustainedCandidate) = oneMinute else {
            return XCTFail("A repeated boundary sentinel must remain hidden after one minute")
        }
        guard case .quarantine = AtriaBLEManager.batteryLevelAcceptanceDecision(
            previousLevel: 89,
            previousAcceptedAt: acceptedAt,
            incomingLevel: 10,
            receivedAt: acceptedAt.addingTimeInterval(15 * 60 + 5),
            pending: sustainedCandidate
        ) else {
            return XCTFail("A repeated 10% sentinel must not replace the credible 89% level")
        }
    }

    func testPlausibleBatteryChangeClearsAnyPendingDrop() {
        let acceptedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let pending = AtriaBLEManager.BatteryDropCandidate(level: 10,
                                                           firstSeenAt: acceptedAt,
                                                           lastSeenAt: acceptedAt,
                                                           confirmations: 1)
        XCTAssertEqual(AtriaBLEManager.batteryLevelAcceptanceDecision(
            previousLevel: 100,
            previousAcceptedAt: acceptedAt,
            incomingLevel: 99,
            receivedAt: acceptedAt.addingTimeInterval(5),
            pending: pending
        ), .accept)
    }

    func testCachedRapidTransitionInvalidatesBothValuesAndRequiresFreshConfirmation() throws {
        let suite = "AtriaBLERecoveryCadenceTests.battery.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(10, forKey: AtriaBLEManager.BatteryDefaults.level)
        defaults.set(89, forKey: AtriaBLEManager.BatteryDefaults.previousLevel)
        defaults.set(1_000.0, forKey: AtriaBLEManager.BatteryDefaults.previousAt)
        defaults.set(1_094.0, forKey: AtriaBLEManager.BatteryDefaults.dropAt)
        defaults.set(79, forKey: AtriaBLEManager.BatteryDefaults.dropDelta)

        defaults.set(AtriaBLEManager.BatteryChargeStatus.full.rawValue,
                     forKey: AtriaBLEManager.BatteryDefaults.chargeStatus)
        defaults.set(1_000.0, forKey: AtriaBLEManager.BatteryDefaults.chargeAt)
        defaults.set(AtriaBLEManager.StrapStreamState.lowBatteryShutoff.rawValue,
                     forKey: AtriaBLEManager.StrapStreamDefaults.state)
        defaults.set(0, forKey: AtriaBLEManager.StrapStreamDefaults.batteryLevel)
        defaults.set(true, forKey: AtriaBLEManager.StrapStreamDefaults.lowBatteryReconnectSuppressed)

        XCTAssertTrue(AtriaBLEManager.invalidateImplausibleCachedBatteryTransitionIfNeeded(defaults: defaults))
        XCTAssertNil(defaults.object(forKey: AtriaBLEManager.BatteryDefaults.level))
        XCTAssertNil(defaults.object(forKey: AtriaBLEManager.BatteryDefaults.at))
        XCTAssertNil(defaults.object(forKey: AtriaBLEManager.BatteryDefaults.previousLevel))
        XCTAssertNil(defaults.object(forKey: AtriaBLEManager.BatteryDefaults.previousAt))
        XCTAssertNil(defaults.object(forKey: AtriaBLEManager.BatteryDefaults.dropDelta))
        XCTAssertNil(defaults.object(forKey: AtriaBLEManager.BatteryDefaults.dropAt))
        XCTAssertNil(defaults.object(forKey: AtriaBLEManager.BatteryDefaults.chargeStatus))
        XCTAssertNil(defaults.object(forKey: AtriaBLEManager.BatteryDefaults.chargeAt))
        XCTAssertEqual(defaults.string(forKey: AtriaBLEManager.BatteryDefaults.source),
                       "disputed_rapid_transition")
        XCTAssertTrue(defaults.bool(forKey: AtriaBLEManager.BatteryDefaults.requiresFreshConfirmation))
        XCTAssertEqual(defaults.string(forKey: AtriaBLEManager.StrapStreamDefaults.state),
                       AtriaBLEManager.StrapStreamState.unknown.rawValue)
        XCTAssertEqual(defaults.integer(forKey: AtriaBLEManager.StrapStreamDefaults.batteryLevel), -1)
        XCTAssertFalse(defaults.bool(forKey: AtriaBLEManager.StrapStreamDefaults.lowBatteryReconnectSuppressed))
    }

    func testDisputedBatterySourceCancelsNotificationFallout() throws {
        let notificationSource = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Atria/LocalNotificationScheduler.swift"), encoding: .utf8)

        XCTAssertTrue(notificationSource.contains("if !battery.usable, battery.source == \"disputed_rapid_transition\""))
        XCTAssertTrue(notificationSource.contains("removePendingNotificationRequests(withIdentifiers: identifiers)"))
        XCTAssertTrue(notificationSource.contains("removeDeliveredNotifications(withIdentifiers: identifiers)"))
        XCTAssertTrue(notificationSource.contains("defaults.removeObject(forKey: strapChargeReminderLastScheduledKey)"))
    }

    func testAsyncBatteryAlertIsRevalidatedBeforeDelivery() {
        XCTAssertFalse(LocalNotificationScheduler.batteryAlertStillValid(level: -1,
                                                                         usable: false,
                                                                         isCharging: false))
        XCTAssertFalse(LocalNotificationScheduler.batteryAlertStillValid(level: 10,
                                                                         usable: true,
                                                                         isCharging: true))
        XCTAssertFalse(LocalNotificationScheduler.batteryAlertStillValid(level: 43,
                                                                         usable: true,
                                                                         isCharging: false))
        XCTAssertTrue(LocalNotificationScheduler.batteryAlertStillValid(level: 10,
                                                                        usable: true,
                                                                        isCharging: false))
    }

    func testDisputedCachedTransitionNeedsFreshStableSeriesEvenWithoutPreviousLevel() {
        let firstAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let first = AtriaBLEManager.batteryLevelAcceptanceDecision(
            previousLevel: -1,
            previousAcceptedAt: nil,
            incomingLevel: 74,
            receivedAt: firstAt,
            pending: nil,
            requiresFreshConfirmation: true
        )
        guard case .quarantine(let firstCandidate) = first else {
            return XCTFail("A disputed cache must not accept the first fresh level")
        }

        let second = AtriaBLEManager.batteryLevelAcceptanceDecision(
            previousLevel: -1,
            previousAcceptedAt: nil,
            incomingLevel: 75,
            receivedAt: firstAt.addingTimeInterval(6),
            pending: firstCandidate,
            requiresFreshConfirmation: true
        )
        guard case .quarantine(let secondCandidate) = second else {
            return XCTFail("A disputed cache must remain unavailable before one minute")
        }

        XCTAssertEqual(AtriaBLEManager.batteryLevelAcceptanceDecision(
            previousLevel: -1,
            previousAcceptedAt: nil,
            incomingLevel: 74,
            receivedAt: firstAt.addingTimeInterval(12),
            pending: secondCandidate,
            requiresFreshConfirmation: true
        ), .accept)
    }

    func testFreshLaunchRejectsTransientHundredAndZeroBeforeStableLiveLevel() {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let hundred = AtriaBLEManager.batteryLevelAcceptanceDecision(
            previousLevel: -1, previousAcceptedAt: nil, incomingLevel: 100,
            receivedAt: start, pending: nil, requiresFreshConfirmation: true
        )
        guard case .quarantine(let hundredCandidate) = hundred else {
            return XCTFail("A launch-time 100% read must stay hidden")
        }
        let zero = AtriaBLEManager.batteryLevelAcceptanceDecision(
            previousLevel: -1, previousAcceptedAt: nil, incomingLevel: 0,
            receivedAt: start.addingTimeInterval(5), pending: hundredCandidate,
            requiresFreshConfirmation: true
        )
        guard case .quarantine(let zeroCandidate) = zero else {
            return XCTFail("A transient 0% read must stay hidden")
        }
        XCTAssertEqual(zeroCandidate.confirmations, 1)

        let live1 = AtriaBLEManager.batteryLevelAcceptanceDecision(
            previousLevel: -1, previousAcceptedAt: nil, incomingLevel: 43,
            receivedAt: start.addingTimeInterval(8), pending: zeroCandidate,
            requiresFreshConfirmation: true
        )
        guard case .quarantine(let liveCandidate1) = live1 else {
            return XCTFail("The first correct live read still needs corroboration")
        }
        let live2 = AtriaBLEManager.batteryLevelAcceptanceDecision(
            previousLevel: -1, previousAcceptedAt: nil, incomingLevel: 43,
            receivedAt: start.addingTimeInterval(14), pending: liveCandidate1,
            requiresFreshConfirmation: true
        )
        guard case .quarantine(let liveCandidate2) = live2 else {
            return XCTFail("The correct series must span the stability window")
        }
        XCTAssertEqual(AtriaBLEManager.batteryLevelAcceptanceDecision(
            previousLevel: -1, previousAcceptedAt: nil, incomingLevel: 43,
            receivedAt: start.addingTimeInterval(20), pending: liveCandidate2,
            requiresFreshConfirmation: true
        ), .accept)
    }

    func testFreshLaunchBoundaryValuesNeedExtendedStabilityBeforeDisplay() {
        XCTAssertEqual(AtriaBLEManager.freshBatteryMinimumConfirmationSpan(incomingLevel: 0), 15 * 60)
        XCTAssertEqual(AtriaBLEManager.freshBatteryMinimumConfirmationSpan(incomingLevel: 10), 15 * 60)
        XCTAssertEqual(AtriaBLEManager.freshBatteryMinimumConfirmationSpan(incomingLevel: 100), 15 * 60)
        XCTAssertEqual(AtriaBLEManager.freshBatteryMinimumConfirmationSpan(incomingLevel: 43), 12)

        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let first = AtriaBLEManager.batteryLevelAcceptanceDecision(
            previousLevel: -1, previousAcceptedAt: nil, incomingLevel: 10,
            receivedAt: start, pending: nil, requiresFreshConfirmation: true
        )
        guard case .quarantine(let firstCandidate) = first else {
            return XCTFail("A launch-time 10% read must remain hidden")
        }
        let second = AtriaBLEManager.batteryLevelAcceptanceDecision(
            previousLevel: -1, previousAcceptedAt: nil, incomingLevel: 10,
            receivedAt: start.addingTimeInterval(6), pending: firstCandidate,
            requiresFreshConfirmation: true
        )
        guard case .quarantine(let secondCandidate) = second else {
            return XCTFail("A repeated 10% read must remain hidden")
        }
        let atTwelve = AtriaBLEManager.batteryLevelAcceptanceDecision(
            previousLevel: -1, previousAcceptedAt: nil, incomingLevel: 10,
            receivedAt: start.addingTimeInterval(12), pending: secondCandidate,
            requiresFreshConfirmation: true
        )
        guard case .quarantine = atTwelve else {
            return XCTFail("The transient boundary must not use the mid-range 12-second gate")
        }

        var candidate = secondCandidate
        for elapsed in [4, 8, 12].map({ TimeInterval($0 * 60) }) {
            let decision = AtriaBLEManager.batteryLevelAcceptanceDecision(
                previousLevel: -1, previousAcceptedAt: nil, incomingLevel: 10,
                receivedAt: start.addingTimeInterval(elapsed), pending: candidate,
                requiresFreshConfirmation: true
            )
            guard case .quarantine(let next) = decision else {
                return XCTFail("A boundary reading must remain hidden before fifteen minutes")
            }
            XCTAssertEqual(next.firstSeenAt, start, "The long-lived boundary candidate must not reset at five minutes")
            candidate = next
        }

        guard case .quarantine = AtriaBLEManager.batteryLevelAcceptanceDecision(
            previousLevel: -1, previousAcceptedAt: nil, incomingLevel: 10,
            receivedAt: start.addingTimeInterval(15 * 60), pending: candidate,
            requiresFreshConfirmation: true
        ) else {
            return XCTFail("A launch sentinel without a credible trajectory must remain hidden")
        }

        let changedBoundary = AtriaBLEManager.batteryLevelAcceptanceDecision(
            previousLevel: -1, previousAcceptedAt: nil, incomingLevel: 100,
            receivedAt: start.addingTimeInterval(13 * 60), pending: candidate,
            requiresFreshConfirmation: true
        )
        guard case .quarantine(let restarted) = changedBoundary else {
            return XCTFail("A conflicting boundary value must restart confirmation")
        }
        XCTAssertEqual(restarted.confirmations, 1)
        XCTAssertEqual(restarted.firstSeenAt, start.addingTimeInterval(13 * 60))
    }

    func testBoundaryRequiresPlausibleGradualTrajectory() {
        XCTAssertFalse(AtriaBLEManager.isPlausibleBatterySentinelTransition(
            previousLevel: 82, incomingLevel: 100
        ))
        XCTAssertFalse(AtriaBLEManager.isPlausibleBatterySentinelTransition(
            previousLevel: 43, incomingLevel: 0
        ))
        XCTAssertFalse(AtriaBLEManager.isPlausibleBatterySentinelTransition(
            previousLevel: -1, incomingLevel: 100
        ))
        XCTAssertTrue(AtriaBLEManager.isPlausibleBatterySentinelTransition(
            previousLevel: 99, incomingLevel: 100
        ))
        XCTAssertTrue(AtriaBLEManager.isPlausibleBatterySentinelTransition(
            previousLevel: 5, incomingLevel: 0
        ))
        XCTAssertTrue(AtriaBLEManager.isPlausibleBatterySentinelTransition(
            previousLevel: 14, incomingLevel: 10
        ))
    }

    func testPlausibleFinalPercentCanStillBeAccepted() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        XCTAssertEqual(AtriaBLEManager.batteryLevelAcceptanceDecision(
            previousLevel: 99,
            previousAcceptedAt: now.addingTimeInterval(-120),
            incomingLevel: 100,
            receivedAt: now,
            pending: nil
        ), .accept)
        XCTAssertEqual(AtriaBLEManager.batteryLevelAcceptanceDecision(
            previousLevel: 4,
            previousAcceptedAt: now.addingTimeInterval(-120),
            incomingLevel: 0,
            receivedAt: now,
            pending: nil
        ), .accept)
    }

    func testPoweredChargeStatusCannotOriginateFromRawStatusPacket() {
        XCTAssertNil(AtriaBLEManager.acceptedBatteryChargeStatus(
            .charging, batteryLevel: 82, hasPlausibleRiseEvidence: false
        ))
        XCTAssertNil(AtriaBLEManager.acceptedBatteryChargeStatus(
            .full, batteryLevel: 100, hasPlausibleRiseEvidence: false
        ))
        XCTAssertNil(AtriaBLEManager.acceptedBatteryChargeStatus(
            .full, batteryLevel: 82, hasPlausibleRiseEvidence: true
        ))
        XCTAssertEqual(AtriaBLEManager.acceptedBatteryChargeStatus(
            .charging, batteryLevel: 83, hasPlausibleRiseEvidence: true
        ), .charging)
        XCTAssertEqual(AtriaBLEManager.acceptedBatteryChargeStatus(
            .full, batteryLevel: 100, hasPlausibleRiseEvidence: true
        ), .full)
        XCTAssertEqual(AtriaBLEManager.acceptedBatteryChargeStatus(
            .notCharging, batteryLevel: 82, hasPlausibleRiseEvidence: false
        ), .notCharging)
    }

    func testPersistedBoundaryIsInvalidatedWithoutDeletingLastCredibleLevel() throws {
        let suite = "AtriaBLERecoveryCadenceTests.boundary.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(100, forKey: AtriaBLEManager.BatteryDefaults.level)
        defaults.set(1_100.0, forKey: AtriaBLEManager.BatteryDefaults.at)
        defaults.set(82, forKey: AtriaBLEManager.BatteryDefaults.credibleLevel)
        defaults.set(1_000.0, forKey: AtriaBLEManager.BatteryDefaults.credibleAt)
        defaults.set(AtriaBLEManager.BatteryChargeStatus.full.rawValue,
                     forKey: AtriaBLEManager.BatteryDefaults.chargeStatus)
        defaults.set(true,
                     forKey: AtriaBLEManager.StrapStreamDefaults.lowBatteryReconnectSuppressed)

        XCTAssertTrue(AtriaBLEManager.invalidateUnverifiedCachedBatterySentinelIfNeeded(
            defaults: defaults
        ))
        XCTAssertNil(defaults.object(forKey: AtriaBLEManager.BatteryDefaults.level))
        XCTAssertNil(defaults.object(forKey: AtriaBLEManager.BatteryDefaults.at))
        XCTAssertNil(defaults.object(forKey: AtriaBLEManager.BatteryDefaults.chargeStatus))
        XCTAssertEqual(defaults.integer(forKey: AtriaBLEManager.BatteryDefaults.credibleLevel), 82)
        XCTAssertEqual(defaults.double(forKey: AtriaBLEManager.BatteryDefaults.credibleAt), 1_000)
        XCTAssertEqual(defaults.string(forKey: AtriaBLEManager.BatteryDefaults.source),
                       "disputed_boundary_sentinel")
        XCTAssertTrue(defaults.bool(forKey: AtriaBLEManager.BatteryDefaults.requiresFreshConfirmation))
        XCTAssertFalse(defaults.bool(
            forKey: AtriaBLEManager.StrapStreamDefaults.lowBatteryReconnectSuppressed
        ))
    }

    func testBatteryRefreshCadenceAndVisibleFreshnessFailClosed() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        XCTAssertTrue(AtriaBLEManager.shouldRequestBatteryRefresh(lastRequestedAt: nil, now: now))
        XCTAssertFalse(AtriaBLEManager.shouldRequestBatteryRefresh(
            lastRequestedAt: now.addingTimeInterval(-119), now: now
        ))
        XCTAssertTrue(AtriaBLEManager.shouldRequestBatteryRefresh(
            lastRequestedAt: now.addingTimeInterval(-120), now: now
        ))

        XCTAssertFalse(AtriaBLEManager.batteryLevelIsFresh(lastAcceptedAt: nil, now: now))
        XCTAssertTrue(AtriaBLEManager.batteryLevelIsFresh(
            lastAcceptedAt: now.addingTimeInterval(-600), now: now
        ))
        XCTAssertFalse(AtriaBLEManager.batteryLevelIsFresh(
            lastAcceptedAt: now.addingTimeInterval(-601), now: now
        ))
    }

    func testStaleLowBatteryCannotDisableMotionOrSteps() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        XCTAssertEqual(AtriaBLEManager.resolvedMotionBatteryLevel(
            liveLevel: 10,
            liveAcceptedAt: now.addingTimeInterval(-601),
            cachedLevel: 10,
            cachedAt: now.addingTimeInterval(-601),
            now: now
        ), -1)
        XCTAssertTrue(AtriaBLEManager.shouldArmHighFrequencyMotion(
            batteryLevel: -1,
            isCharging: false
        ))
        XCTAssertEqual(AtriaBLEManager.resolvedMotionBatteryLevel(
            liveLevel: 10,
            liveAcceptedAt: now.addingTimeInterval(-599),
            cachedLevel: nil,
            cachedAt: nil,
            now: now
        ), 10)
        XCTAssertFalse(AtriaBLEManager.shouldArmHighFrequencyMotion(
            batteryLevel: 10,
            isCharging: false
        ))
        XCTAssertTrue(AtriaBLEManager.shouldArmHighFrequencyMotion(
            batteryLevel: 10,
            isCharging: false,
            calibrationActive: true
        ))
    }

    @MainActor
    func testBatteryNotificationSnapshotRequiresFreshPersistedEvidence() throws {
        let suite = "AtriaBLERecoveryCadenceTests.notificationBattery.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        defaults.set(10, forKey: AtriaBLEManager.BatteryDefaults.level)
        defaults.set("live_2A19", forKey: AtriaBLEManager.BatteryDefaults.source)

        defaults.set(now.addingTimeInterval(-601).timeIntervalSince1970,
                     forKey: AtriaBLEManager.BatteryDefaults.at)
        XCTAssertFalse(LocalNotificationScheduler.batterySnapshot(
            liveLevel: 10,
            liveChargeStatus: .notCharging,
            defaults: defaults,
            now: now
        ).usable)

        defaults.set(now.addingTimeInterval(-599).timeIntervalSince1970,
                     forKey: AtriaBLEManager.BatteryDefaults.at)
        XCTAssertTrue(LocalNotificationScheduler.batterySnapshot(
            liveLevel: 10,
            liveChargeStatus: .notCharging,
            defaults: defaults,
            now: now
        ).usable)

        defaults.removeObject(forKey: AtriaBLEManager.BatteryDefaults.at)
        XCTAssertFalse(LocalNotificationScheduler.batterySnapshot(
            liveLevel: 43,
            liveChargeStatus: .levelOnly,
            defaults: defaults,
            now: now
        ).usable)
    }

    func testProductionBatteryRefreshNeverUsesPhysicallyUnstableExplicitRead() {
        XCTAssertEqual(AtriaBLEManager.standardBatteryRefreshAction(
            canRead: true, canNotify: true, isNotifying: true
        ), .awaitNotification)
        XCTAssertEqual(AtriaBLEManager.standardBatteryRefreshAction(
            canRead: true, canNotify: true, isNotifying: false
        ), .subscribe)
        XCTAssertEqual(AtriaBLEManager.standardBatteryRefreshAction(
            canRead: true,
            canNotify: false,
            isNotifying: false
        ), .unavailable)
        XCTAssertEqual(AtriaBLEManager.standardBatteryRefreshAction(
            canRead: true,
            canNotify: false,
            isNotifying: false,
            explicitReadResearchEnabled: true
        ), .read)
    }

    func testNonReadableBatteryRefreshOnlyStartsANewSubscriptionOnce() {
        XCTAssertEqual(AtriaBLEManager.standardBatteryRefreshAction(
            canRead: false, canNotify: true, isNotifying: false
        ), .subscribe)
        XCTAssertEqual(AtriaBLEManager.standardBatteryRefreshAction(
            canRead: false, canNotify: true, isNotifying: true
        ), .awaitNotification)
        XCTAssertEqual(AtriaBLEManager.standardBatteryRefreshAction(
            canRead: false, canNotify: false, isNotifying: false
        ), .unavailable)
    }

    func testReconnectEvictsBoundarySentinelAndRestoresRecentCredibleLevel() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        XCTAssertEqual(AtriaBLEManager.reconnectBatteryDisplayLevel(
            currentLevel: 100,
            credibleLevel: 43,
            credibleAt: now.addingTimeInterval(-60),
            now: now
        ), 43)
        XCTAssertEqual(AtriaBLEManager.reconnectBatteryDisplayLevel(
            currentLevel: 0,
            credibleLevel: 43,
            credibleAt: now.addingTimeInterval(-601),
            now: now
        ), -1)
        XCTAssertEqual(AtriaBLEManager.reconnectBatteryDisplayLevel(
            currentLevel: 43,
            credibleLevel: 70,
            credibleAt: now,
            now: now
        ), 43)
    }

    func testChargeStatusPacketDoesNotRefreshPersistedBatteryLevelEvidence() throws {
        let suite = "AtriaBLERecoveryCadenceTests.chargeStatus.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(43, forKey: AtriaBLEManager.BatteryDefaults.level)
        defaults.set(1_000.0, forKey: AtriaBLEManager.BatteryDefaults.at)
        defaults.set("live_2A19", forKey: AtriaBLEManager.BatteryDefaults.source)

        AtriaBLEManager.persistBatteryChargeStatusProjection(
            .notCharging,
            source: "live_2A1B",
            defaults: defaults,
            now: Date(timeIntervalSince1970: 2_000)
        )

        XCTAssertEqual(defaults.integer(forKey: AtriaBLEManager.BatteryDefaults.level), 43)
        XCTAssertEqual(defaults.double(forKey: AtriaBLEManager.BatteryDefaults.at), 1_000)
        XCTAssertEqual(defaults.string(forKey: AtriaBLEManager.BatteryDefaults.source), "live_2A19")
        XCTAssertEqual(defaults.string(forKey: AtriaBLEManager.BatteryDefaults.chargeStatus),
                       AtriaBLEManager.BatteryChargeStatus.notCharging.rawValue)
        XCTAssertEqual(defaults.double(forKey: AtriaBLEManager.BatteryDefaults.chargeAt), 2_000)
    }

    func testBatteryConfirmationRetriesAreBoundedInsteadOfTightLooping() {
        XCTAssertEqual(AtriaBLEManager.batteryConfirmationRetryDelay(incomingLevel: 43), 6)
        XCTAssertEqual(AtriaBLEManager.batteryConfirmationRetryDelay(incomingLevel: 0), 30)
        XCTAssertEqual(AtriaBLEManager.batteryConfirmationRetryDelay(incomingLevel: 10), 30)
        XCTAssertEqual(AtriaBLEManager.batteryConfirmationRetryDelay(incomingLevel: 100), 30)
    }

    func testDisputedCacheFreshConfirmationRestartsWhenReadingsDisagree() {
        let firstAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let first = AtriaBLEManager.batteryLevelAcceptanceDecision(
            previousLevel: -1,
            previousAcceptedAt: nil,
            incomingLevel: 74,
            receivedAt: firstAt,
            pending: nil,
            requiresFreshConfirmation: true
        )
        guard case .quarantine(let firstCandidate) = first else {
            return XCTFail("Expected a quarantined fresh candidate")
        }
        let disagreement = AtriaBLEManager.batteryLevelAcceptanceDecision(
            previousLevel: -1,
            previousAcceptedAt: nil,
            incomingLevel: 10,
            receivedAt: firstAt.addingTimeInterval(30),
            pending: firstCandidate,
            requiresFreshConfirmation: true
        )
        guard case .quarantine(let restarted) = disagreement else {
            return XCTFail("A disagreement must restart confirmation")
        }
        XCTAssertEqual(restarted.level, 10)
        XCTAssertEqual(restarted.confirmations, 1)
        XCTAssertEqual(restarted.firstSeenAt, firstAt.addingTimeInterval(30))
    }

    func testBatteryLevelParserRejectsMalformedPayloadsInsteadOfInventingZero() {
        XCTAssertNil(AtriaBLEManager.parseBatteryLevel(Data()))
        XCTAssertNil(AtriaBLEManager.parseBatteryLevel(Data([101])))
        XCTAssertNil(AtriaBLEManager.parseBatteryLevel(Data([80, 79])))
        XCTAssertEqual(AtriaBLEManager.parseBatteryLevel(Data([0])), 0)
        XCTAssertEqual(AtriaBLEManager.parseBatteryLevel(Data([80])), 80)
        XCTAssertEqual(AtriaBLEManager.parseBatteryLevel(Data([100])), 100)
    }

    func testDayScopedStrapStepsExcludeThePreviousDaysSessionTotal() {
        XCTAssertEqual(AtriaBLEManager.dayScopedStrapStepCount(sessionCount: 8_240,
                                                               dayBaseline: 8_000), 240)
        XCTAssertEqual(AtriaBLEManager.dayScopedStrapStepCount(sessionCount: 240,
                                                               dayBaseline: 0), 240)
        XCTAssertEqual(AtriaBLEManager.dayScopedStrapStepCount(sessionCount: 10,
                                                               dayBaseline: 20), 0)
    }

    func testLowerR10SnapshotCannotOverwritePersistedSessionStepPrefix() {
        let reconciled = AtriaBLEManager.monotonicStrapStepTotals(
            currentSteps: 123,
            currentRawSteps: 111,
            incomingSteps: 4,
            incomingRawSteps: 4
        )

        XCTAssertEqual(reconciled, .init(steps: 123, rawSteps: 111))
    }

    func testFreshR10SnapshotAdvancesBothCumulativeStepCounters() {
        let reconciled = AtriaBLEManager.monotonicStrapStepTotals(
            currentSteps: 123,
            currentRawSteps: 111,
            incomingSteps: 140,
            incomingRawSteps: 126
        )

        XCTAssertEqual(reconciled, .init(steps: 140, rawSteps: 126))
    }

    func testStepReconciliationClampsMalformedNegativeSnapshotWithoutLosingState() {
        let reconciled = AtriaBLEManager.monotonicStrapStepTotals(
            currentSteps: 123,
            currentRawSteps: 111,
            incomingSteps: -1,
            incomingRawSteps: -1
        )

        XCTAssertEqual(reconciled, .init(steps: 123, rawSteps: 111))
        XCTAssertEqual(AtriaBLEManager.monotonicStrapStepTotals(currentSteps: 0,
                                                                 currentRawSteps: 0,
                                                                 incomingSteps: -1,
                                                                 incomingRawSteps: -1),
                       .init(steps: 0, rawSteps: 0))
    }

    func testRecoveryHRVEligibilityUsesMeasurementTimeInsteadOfScreenOpenHour() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        let morning = calendar.date(from: DateComponents(year: 2026,
                                                         month: 7,
                                                         day: 10,
                                                         hour: 7))!
        let afternoon = calendar.date(from: DateComponents(year: 2026,
                                                           month: 7,
                                                           day: 10,
                                                           hour: 17))!
        let daytimeMeasurement = calendar.date(from: DateComponents(year: 2026,
                                                                    month: 7,
                                                                    day: 10,
                                                                    hour: 14))!

        XCTAssertTrue(readyHRVSnapshot(measurementEnd: morning).isRecoveryEligible(
            on: afternoon,
            calendar: calendar
        ))
        XCTAssertFalse(readyHRVSnapshot(measurementEnd: daytimeMeasurement).isRecoveryEligible(
            on: afternoon,
            calendar: calendar
        ))
        XCTAssertFalse(readyHRVSnapshot(measurementEnd: morning).isRecoveryEligible(
            on: calendar.date(byAdding: .day, value: 1, to: afternoon)!,
            calendar: calendar
        ))
    }

    func testReadyHRVSnapshotRoundTripsAndExpiresFromRelaunchCache() throws {
        let measuredAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let snapshot = readyHRVSnapshot(measurementEnd: measuredAt)
        let data = try XCTUnwrap(AtriaBLEManager.encodedReadyHRVSnapshot(snapshot))

        XCTAssertEqual(AtriaBLEManager.decodedReadyHRVSnapshot(
            data,
            now: measuredAt.addingTimeInterval(4 * 60 * 60)
        ), snapshot)
        XCTAssertNil(AtriaBLEManager.decodedReadyHRVSnapshot(
            data,
            now: measuredAt.addingTimeInterval(AtriaBLEManager.maxPersistedReadyHRVAge + 1)
        ))
    }

    func testLiveStressRejectsPersistedOrOldReadyHRV() {
        let measuredAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let snapshot = readyHRVSnapshot(measurementEnd: measuredAt)

        XCTAssertTrue(snapshot.isLiveStressEligible(on: measuredAt.addingTimeInterval(599)))
        XCTAssertFalse(snapshot.isLiveStressEligible(on: measuredAt.addingTimeInterval(601)))

        let persisted = HRVSnapshot(rmssd: snapshot.rmssd,
                                    sdnn: snapshot.sdnn,
                                    pnn50: snapshot.pnn50,
                                    lnRMSSD: snapshot.lnRMSSD,
                                    confidence: snapshot.confidence,
                                    kept: snapshot.kept,
                                    raw: snapshot.raw,
                                    rejectedOutOfRange: snapshot.rejectedOutOfRange,
                                    rejectedDeltaOver20Percent: snapshot.rejectedDeltaOver20Percent,
                                    rejectedHRMismatch: snapshot.rejectedHRMismatch,
                                    interpolated: snapshot.interpolated,
                                    windowSeconds: snapshot.windowSeconds,
                                    maxRRGapSeconds: snapshot.maxRRGapSeconds,
                                    respiratoryRate: snapshot.respiratoryRate,
                                    measurementStart: snapshot.measurementStart,
                                    measurementEnd: snapshot.measurementEnd,
                                    analyzedAt: snapshot.analyzedAt,
                                    provenance: .unknown)
        XCTAssertFalse(persisted.isLiveStressEligible(on: measuredAt.addingTimeInterval(60)))
    }

    func testLinkValidOpcodeRemainsResearchOnlyWithoutProductionHeartbeat() throws {
        XCTAssertEqual(AtriaBLEManager.Cmd.linkValid, 0x01)
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaBLEManager.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertFalse(source.contains("func startProtocolHeartbeat"))
        XCTAssertFalse(source.contains("sendCommand(Cmd.linkValid"))
    }

    func testLowBatteryPreservesHeartRateInsteadOfForcingHighFrequencyMotion() {
        XCTAssertFalse(AtriaBLEManager.shouldArmHighFrequencyMotion(batteryLevel: 10,
                                                                   isCharging: false))
        XCTAssertFalse(AtriaBLEManager.shouldArmHighFrequencyMotion(batteryLevel: 25,
                                                                   isCharging: false))
        XCTAssertTrue(AtriaBLEManager.shouldArmHighFrequencyMotion(batteryLevel: 26,
                                                                  isCharging: false))
        XCTAssertTrue(AtriaBLEManager.shouldArmHighFrequencyMotion(batteryLevel: 10,
                                                                  isCharging: true))
        XCTAssertTrue(AtriaBLEManager.shouldArmHighFrequencyMotion(batteryLevel: -1,
                                                                  isCharging: false))
    }

    private func readyHRVSnapshot(measurementEnd: Date) -> HRVSnapshot {
        HRVSnapshot(rmssd: 54,
                    sdnn: 62,
                    pnn50: 18,
                    lnRMSSD: log(54),
                    confidence: 0.98,
                    kept: 300,
                    raw: 304,
                    rejectedOutOfRange: 2,
                    rejectedDeltaOver20Percent: 2,
                    rejectedHRMismatch: 0,
                    interpolated: 0,
                    windowSeconds: 300,
                    maxRRGapSeconds: 1.2,
                    respiratoryRate: 14.2,
                    measurementStart: measurementEnd.addingTimeInterval(-300),
                    measurementEnd: measurementEnd,
                    analyzedAt: measurementEnd,
                    provenance: .localRRWindow)
    }

    func testStalledStreamRepairCooldownIsSharedAndBoundaryInclusive() {
        let lastRepair = Date(timeIntervalSince1970: 10_000)
        let cooldown = AtriaBLEManager.stalledStreamRepairCooldown

        XCTAssertFalse(AtriaBLEManager.shouldBeginStalledStreamRepair(
            lastRepairAt: lastRepair,
            now: lastRepair.addingTimeInterval(cooldown - 0.001)
        ))
        XCTAssertTrue(AtriaBLEManager.shouldBeginStalledStreamRepair(
            lastRepairAt: lastRepair,
            now: lastRepair.addingTimeInterval(cooldown)
        ))
        XCTAssertTrue(AtriaBLEManager.shouldBeginStalledStreamRepair(
            lastRepairAt: nil,
            now: lastRepair
        ))
    }

    func testReconnectBackoffRequiresRealCharacteristicData() {
        XCTAssertFalse(AtriaBLEManager.shouldResetRecoveryBackoff(for: .connected))
        XCTAssertTrue(AtriaBLEManager.shouldResetRecoveryBackoff(for: .characteristicValue))
    }

    func testNotifyEnableIsIdempotent() {
        XCTAssertFalse(AtriaBLEManager.shouldEnableNotifications(isNotifying: true))
        XCTAssertTrue(AtriaBLEManager.shouldEnableNotifications(isNotifying: false))
    }

    func testForegroundReturnPreservesHealthyHeartRateSubscription() {
        let now = Date(timeIntervalSince1970: 20_000)

        XCTAssertTrue(AtriaBLEManager.shouldPreserveHeartRateNotificationOnForeground(
            isNotifying: true,
            lastRawNotificationAt: now.addingTimeInterval(-2),
            now: now
        ))
        XCTAssertTrue(AtriaBLEManager.shouldPreserveHeartRateNotificationOnForeground(
            isNotifying: true,
            lastRawNotificationAt: now.addingTimeInterval(-12),
            now: now
        ))
    }

    func testForegroundReturnRepairsMissingOrStaleHeartRateSubscription() {
        let now = Date(timeIntervalSince1970: 20_000)

        XCTAssertFalse(AtriaBLEManager.shouldPreserveHeartRateNotificationOnForeground(
            isNotifying: false,
            lastRawNotificationAt: now.addingTimeInterval(-1),
            now: now
        ))
        XCTAssertFalse(AtriaBLEManager.shouldPreserveHeartRateNotificationOnForeground(
            isNotifying: true,
            lastRawNotificationAt: nil,
            now: now
        ))
        XCTAssertFalse(AtriaBLEManager.shouldPreserveHeartRateNotificationOnForeground(
            isNotifying: true,
            lastRawNotificationAt: now.addingTimeInterval(-13),
            now: now
        ))
        XCTAssertFalse(AtriaBLEManager.shouldPreserveHeartRateNotificationOnForeground(
            isNotifying: true,
            lastRawNotificationAt: now.addingTimeInterval(1),
            now: now
        ))
    }

    func testNormalWearHRVAnalysisRunsEveryFourHoursInForegroundAndBackground() {
        let fourHours: TimeInterval = 4 * 60 * 60
        XCTAssertEqual(AtriaBLEManager.hrvRefreshMinimumInterval(
            isRecording: false,
            foregroundInteractive: true
        ), fourHours)
        XCTAssertEqual(AtriaBLEManager.hrvRefreshMinimumInterval(
            isRecording: false,
            foregroundInteractive: false
        ), fourHours)
    }

    func testNormalWearHRVGateSurvivesWindowResetAndIsNotThermallyStretched() {
        let lastAnalysis = Date(timeIntervalSince1970: 20_000)
        let fourHours: TimeInterval = 4 * 60 * 60

        XCTAssertFalse(AtriaBLEManager.shouldRefreshHRVAnalysis(
            now: lastAnalysis.addingTimeInterval(fourHours - 1),
            lastAnalysisAt: lastAnalysis,
            isRecording: false,
            foregroundInteractive: false
        ))
        XCTAssertTrue(AtriaBLEManager.shouldRefreshHRVAnalysis(
            now: lastAnalysis.addingTimeInterval(fourHours),
            lastAnalysisAt: lastAnalysis,
            isRecording: false,
            foregroundInteractive: false
        ))
    }

    func testExplicitRecordingHRVAnalysisRemainsOnePointFiveSeconds() {
        let lastAnalysis = Date(timeIntervalSince1970: 30_000)

        XCTAssertEqual(AtriaBLEManager.hrvRefreshMinimumInterval(
            isRecording: true,
            foregroundInteractive: false
        ), 1.5)
        XCTAssertFalse(AtriaBLEManager.shouldRefreshHRVAnalysis(
            now: lastAnalysis.addingTimeInterval(1.499),
            lastAnalysisAt: lastAnalysis,
            isRecording: true,
            foregroundInteractive: true
        ))
        XCTAssertTrue(AtriaBLEManager.shouldRefreshHRVAnalysis(
            now: lastAnalysis.addingTimeInterval(1.5),
            lastAnalysisAt: lastAnalysis,
            isRecording: true,
            foregroundInteractive: true
        ))
    }

    func testNormalWearWaitsForFiveMinuteCleanWindowBeforeFirstAnalysis() {
        let now = Date(timeIntervalSince1970: 40_000)

        XCTAssertFalse(AtriaBLEManager.shouldAttemptHRVAnalysis(
            now: now,
            lastReadyAnalysisAt: nil,
            lastAttemptAt: nil,
            isRecording: false,
            hasReadySnapshot: false,
            cleanWindowSeconds: 299.999,
            foregroundInteractive: true
        ))
        XCTAssertTrue(AtriaBLEManager.shouldAttemptHRVAnalysis(
            now: now,
            lastReadyAnalysisAt: nil,
            lastAttemptAt: nil,
            isRecording: false,
            hasReadySnapshot: false,
            cleanWindowSeconds: 300,
            foregroundInteractive: true
        ))
    }

    func testLearningHRVRetriesEveryFiveMinutesWithoutConsumingFourHourReadyGate() {
        let attempt = Date(timeIntervalSince1970: 50_000)

        XCTAssertFalse(AtriaBLEManager.shouldAttemptHRVAnalysis(
            now: attempt.addingTimeInterval(5 * 60 - 0.001),
            lastReadyAnalysisAt: nil,
            lastAttemptAt: attempt,
            isRecording: false,
            hasReadySnapshot: false,
            cleanWindowSeconds: 300,
            foregroundInteractive: false
        ))
        XCTAssertTrue(AtriaBLEManager.shouldAttemptHRVAnalysis(
            now: attempt.addingTimeInterval(5 * 60),
            lastReadyAnalysisAt: nil,
            lastAttemptAt: attempt,
            isRecording: false,
            hasReadySnapshot: false,
            cleanWindowSeconds: 300,
            foregroundInteractive: false
        ))
    }

    func testReadyNormalWearHRVStillUsesFourHourGate() {
        let ready = Date(timeIntervalSince1970: 60_000)

        XCTAssertFalse(AtriaBLEManager.shouldAttemptHRVAnalysis(
            now: ready.addingTimeInterval(4 * 60 * 60 - 1),
            lastReadyAnalysisAt: ready,
            lastAttemptAt: ready,
            isRecording: false,
            hasReadySnapshot: true,
            cleanWindowSeconds: 300,
            foregroundInteractive: true
        ))
        XCTAssertTrue(AtriaBLEManager.shouldAttemptHRVAnalysis(
            now: ready.addingTimeInterval(4 * 60 * 60),
            lastReadyAnalysisAt: ready,
            lastAttemptAt: ready,
            isRecording: false,
            hasReadySnapshot: true,
            cleanWindowSeconds: 300,
            foregroundInteractive: true
        ))
    }

    func testReadyNormalWearGateSurvivesSnapshotAndAttemptReset() {
        let ready = Date(timeIntervalSince1970: 70_000)

        XCTAssertFalse(AtriaBLEManager.shouldAttemptHRVAnalysis(
            now: ready.addingTimeInterval(10 * 60),
            lastReadyAnalysisAt: ready,
            lastAttemptAt: nil,
            isRecording: false,
            hasReadySnapshot: false,
            cleanWindowSeconds: 10 * 60,
            foregroundInteractive: true
        ))
        XCTAssertTrue(AtriaBLEManager.shouldAttemptHRVAnalysis(
            now: ready.addingTimeInterval(4 * 60 * 60),
            lastReadyAnalysisAt: ready,
            lastAttemptAt: nil,
            isRecording: false,
            hasReadySnapshot: false,
            cleanWindowSeconds: 10 * 60,
            foregroundInteractive: true
        ))
    }

    func testProductionBatteryCallSiteKeepsExplicitReadResearchDisabled() throws {
        let managerURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaBLEManager.swift")
        let source = try String(contentsOf: managerURL, encoding: .utf8)

        XCTAssertTrue(source.contains("explicitReadResearchEnabled: Bool = false"))
        XCTAssertFalse(source.contains("explicitReadResearchEnabled: true"))
        XCTAssertFalse(source.contains("readValue(for: batteryStatusCharacteristic)"))
        XCTAssertTrue(source.contains("detail=protected_r10_minimal_no_battery_gatt"))
        XCTAssertTrue(source.contains("source=2A19_existing_subscription"))
    }

    func testOfflineRecoveryNeverSeizesAHealthyConnectedRealtimePipe() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        XCTAssertTrue(AtriaBLEManager.shouldProtectConnectedLinkForOfflineSync(
            connected: true,
            connectedAt: now.addingTimeInterval(-20),
            hasContact: false,
            acceptedSampleCount: 0,
            lastAcceptedHRAt: nil,
            now: now
        ))
        XCTAssertTrue(AtriaBLEManager.shouldProtectConnectedLinkForOfflineSync(
            connected: true,
            connectedAt: now.addingTimeInterval(-120),
            hasContact: true,
            acceptedSampleCount: 30,
            lastAcceptedHRAt: now.addingTimeInterval(-5),
            now: now
        ))
        XCTAssertFalse(AtriaBLEManager.shouldProtectConnectedLinkForOfflineSync(
            connected: true,
            connectedAt: now.addingTimeInterval(-120),
            hasContact: false,
            acceptedSampleCount: 30,
            lastAcceptedHRAt: now.addingTimeInterval(-5),
            now: now
        ))
        XCTAssertFalse(AtriaBLEManager.shouldProtectConnectedLinkForOfflineSync(
            connected: false,
            connectedAt: nil,
            hasContact: true,
            acceptedSampleCount: 30,
            lastAcceptedHRAt: now,
            now: now
        ))
    }

}
