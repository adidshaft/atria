import XCTest
@testable import Atria

final class AtriaBLERecoveryCadenceTests: XCTestCase {
    func testMotionDiagnosticRequiresProfileConsentForR10IMUSequence() {
        let base = [
            AtriaBLEManager.MotionHandshakeDiagnosticConfiguration.enableArgument,
            AtriaBLEManager.MotionHandshakeDiagnosticConfiguration.confirmationArgument,
            AtriaBLEManager.MotionHandshakeDiagnosticConfiguration.runIDArgument,
            "profile-test"
        ]

        XCTAssertNil(AtriaBLEManager.MotionHandshakeDiagnosticConfiguration.parse(
            arguments: base + [
                AtriaBLEManager.MotionHandshakeDiagnosticConfiguration
                    .r10IMUSequenceConsentArgument
            ]
        ))

        let configuration = AtriaBLEManager.MotionHandshakeDiagnosticConfiguration.parse(
            arguments: base + [
                AtriaBLEManager.MotionHandshakeDiagnosticConfiguration
                    .responseEventDataProfileArgument,
                AtriaBLEManager.MotionHandshakeDiagnosticConfiguration
                    .r10IMUSequenceConsentArgument,
                AtriaBLEManager.MotionHandshakeDiagnosticConfiguration.addHRDelayArgument,
                "15"
            ]
        )
        XCTAssertEqual(configuration?.runID, "profile-test")
        XCTAssertEqual(configuration?.addHRDelay, 15)
        XCTAssertEqual(configuration?.useResponseEventDataProfile, true)
        XCTAssertEqual(configuration?.sendR10IMUSequence, true)
        XCTAssertEqual(configuration?.sendSingleR10Activation, false)
    }

    func testMotionDiagnosticProfileSubscribesResponseEventThenData() {
        XCTAssertEqual(
            AtriaBLEManager.motionHandshakeNotifyOrder(
                useResponseEventDataProfile: true
            ),
            [AtriaBLEManager.UUIDs.strapRX,
             AtriaBLEManager.UUIDs.strapStream4,
             AtriaBLEManager.UUIDs.strapStream5]
        )
        XCTAssertEqual(
            AtriaBLEManager.motionHandshakeNotifyOrder(
                useResponseEventDataProfile: false
            ),
            [AtriaBLEManager.UUIDs.strapStream5]
        )
    }

    func testProtectedV9UsesPhysicallyProvenProfileAndTiming() {
        XCTAssertEqual(
            AtriaBLEManager.protectedR10ResponseEventDataNotifyOrder,
            [AtriaBLEManager.UUIDs.strapRX,
             AtriaBLEManager.UUIDs.strapStream4,
             AtriaBLEManager.UUIDs.strapStream5]
        )
        XCTAssertEqual(AtriaBLEManager.protectedR10CommandPacingDelay,
                       0.120,
                       accuracy: 0.000_1)
        XCTAssertEqual(AtriaBLEManager.protectedR10StandardDiscoveryDelay, 15)
        XCTAssertEqual(
            AtriaBLEManager.protectedStandardHRStrapCharacteristics(
                streamSuppressed: false,
                cleanOwner: .protectedV9
            ),
            [AtriaBLEManager.UUIDs.strapRX,
             AtriaBLEManager.UUIDs.strapStream4,
             AtriaBLEManager.UUIDs.strapStream5,
             AtriaBLEManager.UUIDs.strapTX]
        )
    }

    func testAlwaysOnLongWearMigrationRepairsOrphanedDisabledCapture() throws {
        let suite = "AtriaBLERecoveryCadenceTests.alwaysOn.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: AtriaBLEManager.CaptureDefaults.configured)
        defaults.set(false, forKey: AtriaBLEManager.LongWearDefaults.enabled)
        defaults.set(true, forKey: AtriaBLEManager.LongWearDefaults.userSelected)

        XCTAssertTrue(AtriaBLEManager.migrateAlwaysOnLongWearIfNeeded(
            defaults: defaults,
            arguments: []
        ))
        XCTAssertTrue(defaults.bool(forKey: AtriaBLEManager.LongWearDefaults.enabled))
        XCTAssertFalse(defaults.bool(forKey: AtriaBLEManager.LongWearDefaults.userSelected))
        XCTAssertTrue(defaults.bool(forKey: AtriaBLEManager.CaptureDefaults.alwaysOnLongWearMigrated))
        XCTAssertFalse(AtriaBLEManager.migrateAlwaysOnLongWearIfNeeded(
            defaults: defaults,
            arguments: []
        ), "the migration must be one-shot")
    }

    func testAlwaysOnLongWearMigrationDoesNotMutateDiagnosticLaunch() throws {
        let suite = "AtriaBLERecoveryCadenceTests.alwaysOnDiagnostic.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: AtriaBLEManager.CaptureDefaults.configured)
        defaults.set(false, forKey: AtriaBLEManager.LongWearDefaults.enabled)

        XCTAssertFalse(AtriaBLEManager.migrateAlwaysOnLongWearIfNeeded(
            defaults: defaults,
            arguments: ["--atria-full-protocol-mode"]
        ))
        XCTAssertFalse(defaults.bool(forKey: AtriaBLEManager.LongWearDefaults.enabled))
        XCTAssertFalse(defaults.bool(forKey: AtriaBLEManager.CaptureDefaults.alwaysOnLongWearMigrated))
    }

    func testStrapStepCheckpointIsBoundedByCountAndTime() {
        let now = Date(timeIntervalSince1970: 10_000)

        XCTAssertFalse(AtriaBLEManager.shouldCheckpointStrapSteps(
            currentSteps: 111,
            persistedSteps: 100,
            lastCheckpointAt: now.addingTimeInterval(-14.9),
            now: now
        ), "Eleven fresh steps inside fifteen seconds stay in the bounded in-memory window")
        XCTAssertTrue(AtriaBLEManager.shouldCheckpointStrapSteps(
            currentSteps: 112,
            persistedSteps: 100,
            lastCheckpointAt: now.addingTimeInterval(-1),
            now: now
        ), "The twelfth confirmed step must force a durable checkpoint")
        XCTAssertTrue(AtriaBLEManager.shouldCheckpointStrapSteps(
            currentSteps: 101,
            persistedSteps: 100,
            lastCheckpointAt: now.addingTimeInterval(-15),
            now: now
        ), "A small trailing remainder must not wait indefinitely for twelve steps")
    }

    func testStrapStepCheckpointNeverInventsProgressAndFailsSafeOnClockEdges() {
        let now = Date(timeIntervalSince1970: 20_000)

        XCTAssertFalse(AtriaBLEManager.shouldCheckpointStrapSteps(
            currentSteps: 100,
            persistedSteps: 100,
            lastCheckpointAt: now.addingTimeInterval(-1_000),
            now: now
        ))
        XCTAssertFalse(AtriaBLEManager.shouldCheckpointStrapSteps(
            currentSteps: 99,
            persistedSteps: 100,
            lastCheckpointAt: nil,
            now: now
        ), "A regressed/stale snapshot is not new step evidence")
        XCTAssertTrue(AtriaBLEManager.shouldCheckpointStrapSteps(
            currentSteps: 101,
            persistedSteps: 100,
            lastCheckpointAt: nil,
            now: now
        ), "The first confirmed step after an absent checkpoint establishes durability")
        XCTAssertTrue(AtriaBLEManager.shouldCheckpointStrapSteps(
            currentSteps: 101,
            persistedSteps: 100,
            lastCheckpointAt: now.addingTimeInterval(60),
            now: now
        ), "A future checkpoint clock must not suppress writes indefinitely")
    }

    func testCleanOwnerV7MigrationCutsSuppressedUsersToFreshProtectedV7Once() throws {
        let suite = "AtriaBLERecoveryCadenceTests.cleanOwnerV7.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "atria.protectedR10.streamSuppressed")
        defaults.set(3, forKey: "atria.protectedR10.passiveReprobeFailureCount")
        defaults.set(123.0, forKey: "atria.protectedR10.passiveReprobeAttemptAt")
        defaults.set(true, forKey: "atria.protectedR10.passiveReprobePending")
        defaults.set(true, forKey: "atria.protectedR10.passiveRetryMigrationV4")

        XCTAssertEqual(
            AtriaBLEManager.prepareProtectedR10CleanOwnerAtLaunch(defaults: defaults),
            .migratedToProtectedV7
        )
        XCTAssertEqual(defaults.string(forKey: "atria.protectedR10.cleanOwner"),
                       "protected_v7")
        XCTAssertEqual(defaults.string(forKey: "atria.protectedR10.cleanOwnerState"),
                       "protected_launch_pending")
        XCTAssertFalse(defaults.bool(forKey: "atria.protectedR10.streamSuppressed"))
        XCTAssertFalse(defaults.bool(forKey: "atria.protectedR10.rollback"))
        XCTAssertFalse(defaults.bool(forKey: "atria.protectedR10.cleanOwnerConnectionCutoverV7"))
        XCTAssertEqual(defaults.integer(forKey: "atria.protectedR10.passiveReprobeFailureCount"), 0)
        XCTAssertNil(defaults.object(forKey: "atria.protectedR10.passiveReprobeAttemptAt"))
        XCTAssertFalse(defaults.bool(forKey: "atria.protectedR10.passiveReprobePending"))

        defaults.set(2, forKey: "atria.protectedR10.passiveReprobeFailureCount")
        XCTAssertEqual(AtriaBLEManager.prepareProtectedR10CleanOwnerAtLaunch(defaults: defaults),
                       .none)
        XCTAssertEqual(defaults.integer(forKey: "atria.protectedR10.passiveReprobeFailureCount"), 2,
                       "the one-time launch migration must not erase later proof failures")
    }

    func testPhysicallyProvenV9MigratesSuppressedPureHRV8ExactlyOnce() throws {
        let suite = "AtriaBLERecoveryCadenceTests.cleanOwnerV7Retry.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "atria.protectedR10.cleanOwnerMigrationV6")
        defaults.set("pure_hr_v8", forKey: "atria.protectedR10.cleanOwner")
        defaults.set("fallback_pending", forKey: "atria.protectedR10.cleanOwnerState")
        defaults.set("clean_owner_stream5_notification_lost",
                     forKey: "atria.protectedR10.cleanOwnerFailureReason")
        defaults.set(true, forKey: "atria.protectedR10.streamSuppressed")

        XCTAssertEqual(AtriaBLEManager.prepareProtectedR10CleanOwnerAtLaunch(defaults: defaults),
                       .migratedPureHRV8ToProtectedV9)
        XCTAssertEqual(defaults.string(forKey: "atria.protectedR10.cleanOwner"),
                       "protected_redp_v9")
        XCTAssertEqual(defaults.string(forKey: "atria.protectedR10.cleanOwnerState"),
                       "protected_launch_pending")
        XCTAssertFalse(defaults.bool(forKey: "atria.protectedR10.streamSuppressed"))
        XCTAssertTrue(defaults.bool(forKey: "atria.protectedR10.responseEventDataMigrationV9"))
        XCTAssertFalse(defaults.bool(forKey: "atria.protectedR10.responseEventDataConnectionCutoverV9"))
        XCTAssertFalse(defaults.bool(forKey: "atria.protectedR10.responseEventDataSequenceSentV9"))

        XCTAssertEqual(AtriaBLEManager.prepareProtectedR10CleanOwnerAtLaunch(defaults: defaults),
                       .none,
                       "the physically-proven owner migration must be one-shot")
    }

    func testCleanOwnerMigrationLeavesUnsuppressedLegacyOwnerUnchanged() throws {
        let suite = "AtriaBLERecoveryCadenceTests.cleanOwnerLegacy.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "atria.protectedR10.streamSuppressed")

        XCTAssertEqual(AtriaBLEManager.prepareProtectedR10CleanOwnerAtLaunch(defaults: defaults),
                       .none)
        XCTAssertNil(defaults.string(forKey: "atria.protectedR10.cleanOwner"))
        XCTAssertTrue(defaults.bool(forKey: "atria.protectedR10.cleanOwnerMigrationV7"))
    }

    func testCleanOwnerFallbackActivatesPureHRV8OnlyAtNextProcessLaunch() throws {
        let suite = "AtriaBLERecoveryCadenceTests.cleanOwnerFallback.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "atria.protectedR10.cleanOwnerMigrationV7")
        defaults.set("pure_hr_v8", forKey: "atria.protectedR10.cleanOwner")
        defaults.set("fallback_pending", forKey: "atria.protectedR10.cleanOwnerState")
        defaults.set(false, forKey: "atria.protectedR10.streamSuppressed")

        XCTAssertEqual(AtriaBLEManager.prepareProtectedR10CleanOwnerAtLaunch(defaults: defaults),
                       .activatedPureHRV8Fallback)
        XCTAssertEqual(defaults.string(forKey: "atria.protectedR10.cleanOwnerState"),
                       "fallback_active")
        XCTAssertTrue(defaults.bool(forKey: "atria.protectedR10.streamSuppressed"))
        XCTAssertTrue(defaults.bool(forKey: "atria.protectedR10.rollback"))
    }

    func testV10FallbackActivatesOnlyAtNextProcessLaunch() throws {
        let suite = "AtriaBLERecoveryCadenceTests.cleanOwnerV10Fallback.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "atria.protectedR10.responseEventDataMigrationV9")
        defaults.set("pure_hr_v10", forKey: "atria.protectedR10.cleanOwner")
        defaults.set("fallback_pending", forKey: "atria.protectedR10.cleanOwnerState")

        XCTAssertEqual(AtriaBLEManager.prepareProtectedR10CleanOwnerAtLaunch(defaults: defaults),
                       .activatedPureHRV10Fallback)
        XCTAssertEqual(defaults.string(forKey: "atria.protectedR10.cleanOwnerState"),
                       "fallback_active")
        XCTAssertTrue(defaults.bool(forKey: "atria.protectedR10.streamSuppressed"))
        XCTAssertTrue(defaults.bool(forKey: "atria.protectedR10.rollback"))
    }

    func testInterruptedV9ProofSelectsFreshPureHRV10WithoutReplayingCommands() throws {
        let suite = "AtriaBLERecoveryCadenceTests.interruptedV9.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "atria.protectedR10.responseEventDataMigrationV9")
        defaults.set(true, forKey: "atria.protectedR10.responseEventDataSequenceSentV9")
        defaults.set("protected_redp_v9", forKey: "atria.protectedR10.cleanOwner")
        defaults.set("proving", forKey: "atria.protectedR10.cleanOwnerState")

        XCTAssertEqual(AtriaBLEManager.prepareProtectedR10CleanOwnerAtLaunch(defaults: defaults),
                       .activatedPureHRV10Fallback)
        XCTAssertEqual(defaults.string(forKey: "atria.protectedR10.cleanOwner"),
                       "pure_hr_v10")
        XCTAssertEqual(defaults.string(forKey: "atria.protectedR10.cleanOwnerState"),
                       "fallback_active")
        XCTAssertTrue(defaults.bool(forKey: "atria.protectedR10.streamSuppressed"))
        XCTAssertTrue(defaults.bool(forKey: "atria.protectedR10.rollback"))
        XCTAssertTrue(defaults.bool(forKey: "atria.protectedR10.responseEventDataSequenceSentV9"),
                      "the persisted command lease remains consumed")
    }

    func testInterruptedV7ProofRestartsPassiveEpochWithoutBreakingCommandLease() throws {
        let suite = "AtriaBLERecoveryCadenceTests.cleanOwnerResume.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "atria.protectedR10.cleanOwnerMigrationV7")
        defaults.set("protected_v7", forKey: "atria.protectedR10.cleanOwner")
        defaults.set("proving", forKey: "atria.protectedR10.cleanOwnerState")
        defaults.set(123.0, forKey: "atria.protectedR10.cleanOwnerProofStartedAt")
        defaults.set(456.0, forKey: "atria.protectedR10.activationSentAt")

        XCTAssertEqual(AtriaBLEManager.prepareProtectedR10CleanOwnerAtLaunch(defaults: defaults),
                       .resumedProtectedV7Proof)
        XCTAssertEqual(defaults.string(forKey: "atria.protectedR10.cleanOwnerState"),
                       "protected_launch_pending")
        XCTAssertNil(defaults.object(forKey: "atria.protectedR10.cleanOwnerProofStartedAt"))
        XCTAssertEqual(defaults.double(forKey: "atria.protectedR10.activationSentAt"), 456,
                       "process recovery must preserve the persisted 3F01 lease")
    }

    func testCleanOwnerNamespacePolicyIsExplicitAndNeverReusesContaminatedOwner() {
        XCTAssertEqual(AtriaBLEManager.protectedR10CentralRestoreIdentifier(
            diagnosticRestoreIdentifier: "diagnostic-owner",
            cleanOwner: .protectedV7,
            streamSuppressed: false
        ), "diagnostic-owner")
        XCTAssertEqual(AtriaBLEManager.protectedR10CentralRestoreIdentifier(
            diagnosticRestoreIdentifier: nil,
            cleanOwner: .protectedV7,
            streamSuppressed: false
        ), "com.adidshaft.atria.ble-central-v7-protected")
        XCTAssertEqual(AtriaBLEManager.protectedR10CentralRestoreIdentifier(
            diagnosticRestoreIdentifier: nil,
            cleanOwner: .pureHRV8,
            streamSuppressed: true
        ), "com.adidshaft.atria.ble-central-v8-pure-hr")
        XCTAssertEqual(AtriaBLEManager.protectedR10CentralRestoreIdentifier(
            diagnosticRestoreIdentifier: nil,
            cleanOwner: .protectedV9,
            streamSuppressed: false
        ), "com.adidshaft.atria.ble-central-v9-response-event-data")
        XCTAssertEqual(AtriaBLEManager.protectedR10CentralRestoreIdentifier(
            diagnosticRestoreIdentifier: nil,
            cleanOwner: .pureHRV10,
            streamSuppressed: true
        ), "com.adidshaft.atria.ble-central-v10-pure-hr")
        XCTAssertEqual(AtriaBLEManager.protectedR10CentralRestoreIdentifier(
            diagnosticRestoreIdentifier: nil,
            cleanOwner: .legacy,
            streamSuppressed: true
        ), "com.adidshaft.atria.ble-central-v6-pure-hr")
    }

    func testCleanOwnerFencesAutomaticHistoryAcrossDisconnectAndFallback() {
        for owner in [AtriaBLEManager.ProtectedR10CleanOwner.protectedV7,
                      .pureHRV8, .protectedV9, .pureHRV10] {
            for state in [AtriaBLEManager.ProtectedR10CleanOwnerState.protectedLaunchPending,
                          .proving, .qualified, .fallbackPending, .fallbackActive] {
                XCTAssertTrue(AtriaBLEManager.shouldDeferAutomaticHistoryForCleanOwner(
                    cleanOwner: owner,
                    state: state,
                    explicitUserRequest: false
                ))
                XCTAssertFalse(AtriaBLEManager.shouldDeferAutomaticHistoryForCleanOwner(
                    cleanOwner: owner,
                    state: state,
                    explicitUserRequest: true
                ))
            }
        }
        XCTAssertFalse(AtriaBLEManager.shouldDeferAutomaticHistoryForCleanOwner(
            cleanOwner: .legacy,
            state: .none,
            explicitUserRequest: false
        ))
    }

    func testCleanOwnerProofWindowExpiresBoundedly() {
        XCTAssertFalse(AtriaBLEManager.protectedR10CleanOwnerProofHasExpired(
            proofActive: false,
            attemptAge: 10_000
        ))
        XCTAssertFalse(AtriaBLEManager.protectedR10CleanOwnerProofHasExpired(
            proofActive: true,
            attemptAge: 119.9
        ))
        XCTAssertFalse(AtriaBLEManager.protectedR10CleanOwnerProofHasExpired(
            proofActive: true,
            attemptAge: 120
        ))
        XCTAssertTrue(AtriaBLEManager.protectedR10CleanOwnerProofHasExpired(
            proofActive: true,
            attemptAge: 150
        ))
        XCTAssertTrue(AtriaBLEManager.protectedR10CleanOwnerProofHasExpired(
            proofActive: true,
            attemptAge: nil
        ))
        XCTAssertTrue(AtriaBLEManager.protectedR10CleanOwnerProofHasExpired(
            proofActive: true,
            attemptAge: -1
        ), "a future/corrupt attempt epoch must fail closed")
    }

    func testCleanOwnerRuntimeNeverTogglesStream5OrStartsHistoryOnProofFailure() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let source = try String(contentsOf: testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaBLEManager.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(
            of: "private func beginProtectedR10CleanOwnerProofIfNeeded"
        ))
        let end = try XCTUnwrap(source.range(
            of: "/// Stream 5 may be subscribed exactly once",
            range: start.upperBound..<source.endIndex
        ))
        let body = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertFalse(body.contains("setNotifyValue"))
        XCTAssertFalse(body.contains("discoverServices"))
        XCTAssertFalse(body.contains("discoverCharacteristics"))
        XCTAssertFalse(body.contains("cancelPeripheralConnection"))
        XCTAssertFalse(body.contains("startOfflineHistoricalSync"))
        XCTAssertTrue(source.contains("sendProtectedR10ActivationIfReady"))
        XCTAssertTrue(source.contains("ProtectedR10RecoveryDecision"))
        XCTAssertTrue(source.contains("sendSingleLeasedActivation"))
        XCTAssertFalse(source.contains("beginProtectedR10PassiveReprobeIfEligible"))
        XCTAssertFalse(source.contains("resuppressProtectedR10Recovery"))
        XCTAssertTrue(source.contains("action=keep_current_link_untouched_select_fresh_pure_hr_next_process_no_history"))
        XCTAssertTrue(body.contains("protectedR10CleanOwnerState == .protectedLaunchPending"))
        XCTAssertTrue(body.contains("strapStream5NotifyConfirmed"))
        XCTAssertTrue(body.contains("forKey: Self.protectedR10CleanOwnerProofStartedAtKey"))

        let repairStart = try XCTUnwrap(source.range(
            of: "private func reassertR10NotificationIfConnected"
        ))
        let firstServiceLookup = try XCTUnwrap(source.range(
            of: "guard let strapService",
            range: repairStart.upperBound..<source.endIndex
        ))
        let protectedRepairGate = String(source[repairStart.lowerBound..<firstServiceLookup.lowerBound])
        XCTAssertTrue(protectedRepairGate.contains("if standardHROnlyMode"))
        XCTAssertTrue(protectedRepairGate.contains("return"))
        XCTAssertFalse(protectedRepairGate.contains("setNotifyValue"))
        XCTAssertFalse(protectedRepairGate.contains("discoverServices"))
        XCTAssertFalse(protectedRepairGate.contains("persistProtectedR10CleanOwnerFallback"))
        XCTAssertTrue(source.contains("persistProtectedR10FallbackForStream5Callback"))
        XCTAssertTrue(source.contains("clean_owner_stream5_notification_error"))
        XCTAssertTrue(source.contains("clean_owner_stream5_notification_inactive"))

        let cutoverStart = try XCTUnwrap(source.range(
            of: "private func beginProtectedR10LaunchConnectionCutoverIfNeeded"
        ))
        let cutoverEnd = try XCTUnwrap(source.range(
            of: "/// Explicit user action",
            range: cutoverStart.upperBound..<source.endIndex
        ))
        let cutoverBody = String(source[cutoverStart.lowerBound..<cutoverEnd.lowerBound])
        XCTAssertTrue(cutoverBody.contains("protectedR10CleanOwnerState == .protectedLaunchPending"))
        XCTAssertTrue(cutoverBody.contains("protectedR10CleanOwnerConnectionCutoverKey"))
        XCTAssertTrue(cutoverBody.contains("central.cancelPeripheralConnection(peripheral)"))
        XCTAssertFalse(cutoverBody.contains("startOfflineHistoricalSync"))
        XCTAssertTrue(source.contains("allowCleanOwnerLaunchCutover: true"))

        let protectedDiscoveryStart = try XCTUnwrap(source.range(
            of: "if discoveryUsesProtectedStandardHR,\n                   !protectedR10StreamSuppressed,\n                   ch.uuid == Self.UUIDs.strapStream5"
        ))
        let protectedDiscoveryEnd = try XCTUnwrap(source.range(
            of: "} else if discoveryUsesProtectedStandardHR, UUIDs.allNotify.contains(ch.uuid)",
            range: protectedDiscoveryStart.upperBound..<source.endIndex
        ))
        let protectedDiscovery = String(source[
            protectedDiscoveryStart.lowerBound..<protectedDiscoveryEnd.lowerBound
        ])
        XCTAssertTrue(protectedDiscovery.contains("protectedStream5NeedingInitialSubscribe = ch"))
        XCTAssertFalse(protectedDiscovery.contains("setNotifyValue"))

        let restoredStreamStart = try XCTUnwrap(source.range(
            of: "if let cachedStream5, cachedStream5.properties.contains(.notify)"
        ))
        let restoredStreamEnd = try XCTUnwrap(source.range(
            of: "if let cachedBattery",
            range: restoredStreamStart.upperBound..<source.endIndex
        ))
        let restoredStreamBody = String(source[
            restoredStreamStart.lowerBound..<restoredStreamEnd.lowerBound
        ])
        XCTAssertTrue(restoredStreamBody.contains("requestProtectedR10InitialProfileNotificationIfAllowed"))
        XCTAssertFalse(restoredStreamBody.contains("setNotifyValue"))
    }

    func testProtectedV9SequenceAndV10CutoverAreSingleBoundedOperations() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaBLEManager.swift"), encoding: .utf8)

        let sequenceStart = try XCTUnwrap(source.range(
            of: "private func sendProtectedR10ResponseEventDataSequenceIfReady"
        ))
        let sequenceEnd = try XCTUnwrap(source.range(
            of: "private func scheduleProtectedR10StandardDiscovery",
            range: sequenceStart.upperBound..<source.endIndex
        ))
        let sequenceBody = String(source[sequenceStart.lowerBound..<sequenceEnd.lowerBound])
        XCTAssertEqual(sequenceBody.components(separatedBy: "Cmd.sendR10R11Realtime").count - 1, 1)
        XCTAssertEqual(sequenceBody.components(separatedBy: "Cmd.toggleIMUMode").count - 1, 1)
        XCTAssertTrue(sequenceBody.contains("protectedR10CommandPacingDelay"))
        XCTAssertFalse(sequenceBody.contains("cancelPeripheralConnection"))
        XCTAssertFalse(sequenceBody.contains("startOfflineHistoricalSync"))

        let cutoverStart = try XCTUnwrap(source.range(
            of: "private func beginProtectedR10PureHRV10InProcessCutoverIfNeeded"
        ))
        let cutoverEnd = try XCTUnwrap(source.range(
            of: "/// A diagnostic restoration identifier",
            range: cutoverStart.upperBound..<source.endIndex
        ))
        let cutoverBody = String(source[cutoverStart.lowerBound..<cutoverEnd.lowerBound])
        XCTAssertEqual(cutoverBody.components(separatedBy: "CBCentralManager(").count - 1, 1)
        XCTAssertTrue(cutoverBody.contains("protectedR10PureHRV10InProcessCutoverKey"))
        XCTAssertTrue(cutoverBody.contains("fallbackActive.rawValue"))
        XCTAssertFalse(cutoverBody.contains("central.connect"))
        XCTAssertFalse(cutoverBody.contains("cancelPeripheralConnection"))
        XCTAssertFalse(cutoverBody.contains("writeValue"))
        XCTAssertFalse(cutoverBody.contains("startOfflineHistoricalSync"))
    }

    func testProtectedR10RecoveryDecisionIsPassiveFirstAndLeaseBounded() {
        typealias Decision = AtriaBLEManager.ProtectedR10RecoveryDecision
        func decide(age: TimeInterval = 20,
                    lease: TimeInterval = 0,
                    hrAge: TimeInterval? = 1,
                    battery: Int = 50,
                    notifying: Bool = true) -> Decision {
            AtriaBLEManager.protectedR10RecoveryDecision(
                pending: true,
                connected: true,
                stream5Notifying: notifying,
                activationSent: false,
                passiveObservationAge: age,
                activationAge: nil,
                activationLeaseRemaining: lease,
                stableHRDuration: 180,
                latestHRAge: hrAge,
                batteryLevel: battery,
                isCharging: false,
                frames: 0,
                lastFrameAge: nil
            )
        }

        XCTAssertEqual(decide(age: 19.9), .observePassive)
        XCTAssertEqual(decide(lease: 1), .observePassive)
        XCTAssertEqual(decide(hrAge: 10.1), .observePassive)
        XCTAssertEqual(decide(battery: 10), .observePassive)
        XCTAssertEqual(decide(notifying: false), .observePassive)
        XCTAssertEqual(decide(), .sendSingleLeasedActivation)
    }

    func testProtectedR10RecoveryDecisionRequiresDenseFreshProofOrResuppresses() {
        func decide(connected: Bool = true,
                    activationAge: TimeInterval? = 90,
                    frames: Int,
                    lastFrameAge: TimeInterval?) -> AtriaBLEManager.ProtectedR10RecoveryDecision {
            AtriaBLEManager.protectedR10RecoveryDecision(
                pending: true,
                connected: connected,
                stream5Notifying: true,
                activationSent: true,
                passiveObservationAge: 110,
                activationAge: activationAge,
                activationLeaseRemaining: 0,
                stableHRDuration: 300,
                latestHRAge: 1,
                batteryLevel: 50,
                isCharging: false,
                frames: frames,
                lastFrameAge: lastFrameAge
            )
        }

        XCTAssertEqual(decide(connected: false, frames: 0, lastFrameAge: nil), .resuppress)
        XCTAssertEqual(decide(activationAge: 19.9, frames: 0, lastFrameAge: nil), .awaitDensityProof)
        XCTAssertEqual(decide(activationAge: 20, frames: 0, lastFrameAge: nil), .resuppress)
        XCTAssertEqual(decide(frames: 74, lastFrameAge: 1), .resuppress)
        XCTAssertEqual(decide(frames: 75, lastFrameAge: 5.1), .resuppress)
        XCTAssertEqual(decide(frames: 75, lastFrameAge: 5), .qualify)
        XCTAssertEqual(AtriaBLEManager.protectedR10RecoveryDecision(
            pending: false,
            connected: true,
            stream5Notifying: true,
            activationSent: false,
            passiveObservationAge: 20,
            activationAge: nil,
            activationLeaseRemaining: 0,
            stableHRDuration: 300,
            latestHRAge: 1,
            batteryLevel: 50,
            isCharging: false,
            frames: 0,
            lastFrameAge: nil
        ), .none)
    }

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

    func testAutonomousBatteryEventParsesCorroboratedFieldsAndRejectsMalformedFrames() throws {
        var frame = [UInt8](repeating: 0, count: 27)
        frame[0] = 0xAA
        frame[4] = 0x30
        frame[6] = 0x03
        frame[17] = 0xAE // 43.0% == 430 tenths
        frame[18] = 0x01
        frame[21] = 0x74 // 3700 mV
        frame[22] = 0x0E
        frame[26] = 1
        XCTAssertEqual(AtriaBLEManager.parseBatteryLevelEventFrame(frame),
                       AtriaBLEManager.BatteryEventReading(level: 43,
                                                           millivolts: 3_700,
                                                           isCharging: true))

        var wrongEvent = frame
        wrongEvent[6] = 0x04
        XCTAssertNil(AtriaBLEManager.parseBatteryLevelEventFrame(wrongEvent))
        var badSOC = frame
        badSOC[17] = 0xE9
        badSOC[18] = 0x03 // 100.1%
        XCTAssertNil(AtriaBLEManager.parseBatteryLevelEventFrame(badSOC))
        var badVoltage = frame
        badVoltage[21] = 0xB7
        badVoltage[22] = 0x0B // 2999 mV
        XCTAssertNil(AtriaBLEManager.parseBatteryLevelEventFrame(badVoltage))
        var badCharge = frame
        badCharge[26] = 2
        XCTAssertNil(AtriaBLEManager.parseBatteryLevelEventFrame(badCharge))
    }

    func testAutonomousMidrangeBatteryEventIsImmediatelyTrustedButContradictoryBoundaryIsNot() {
        let now = Date(timeIntervalSince1970: 50_000)
        XCTAssertEqual(AtriaBLEManager.batteryEventAcceptanceDecision(
            previousLevel: 65,
            previousAcceptedAt: now.addingTimeInterval(-86_400),
            reading: .init(level: 43, millivolts: 3_700, isCharging: false),
            receivedAt: now,
            pending: nil,
            previousIsCached: true,
            requiresFreshConfirmation: true
        ), .accept)

        guard case .quarantine = AtriaBLEManager.batteryEventAcceptanceDecision(
            previousLevel: 43,
            previousAcceptedAt: now.addingTimeInterval(-60),
            reading: .init(level: 100, millivolts: 4_100, isCharging: true),
            receivedAt: now,
            pending: nil,
            previousIsCached: true,
            requiresFreshConfirmation: true
        ) else {
            return XCTFail("a 100% event at only 4.1 V without a near-full trajectory must remain quarantined")
        }
    }

    func testAutonomousBatteryEventAcceptsTrueFullAfterChargeEvidence() {
        let now = Date(timeIntervalSince1970: 50_000)
        XCTAssertEqual(AtriaBLEManager.batteryEventAcceptanceDecision(
            previousLevel: 97,
            previousAcceptedAt: now.addingTimeInterval(-8 * 60),
            reading: .init(level: 100, millivolts: 4_110, isCharging: true),
            receivedAt: now,
            pending: nil,
            previousIsCached: false,
            requiresFreshConfirmation: false,
            previousChargeStatus: .charging
        ), .accept, "CRC-backed SOC, high voltage, active charging and a near-full trajectory prove full")

        XCTAssertEqual(AtriaBLEManager.batteryEventAcceptanceDecision(
            previousLevel: 43,
            previousAcceptedAt: now.addingTimeInterval(-8 * 60),
            reading: .init(level: 100, millivolts: 4_220, isCharging: true),
            receivedAt: now,
            pending: nil,
            previousIsCached: true,
            requiresFreshConfirmation: true
        ), .accept, "an unmistakable near-4.2 V charging event can prove full after an app-off charge")

        XCTAssertEqual(AtriaBLEManager.batteryEventAcceptanceDecision(
            previousLevel: 99,
            previousAcceptedAt: now.addingTimeInterval(-8 * 60),
            reading: .init(level: 100, millivolts: 4_190, isCharging: false),
            receivedAt: now,
            pending: nil,
            previousIsCached: false,
            requiresFreshConfirmation: false,
            previousChargeStatus: .charging
        ), .accept, "full remains provable immediately after the charger clears its charging bit")
    }

    func testAutonomousBatteryEventAcceptsGradualLowAndEmptyOnlyWithElectricalProof() {
        let now = Date(timeIntervalSince1970: 50_000)
        XCTAssertEqual(AtriaBLEManager.batteryEventAcceptanceDecision(
            previousLevel: 14,
            previousAcceptedAt: now.addingTimeInterval(-10 * 60),
            reading: .init(level: 10, millivolts: 3_480, isCharging: false),
            receivedAt: now,
            pending: nil
        ), .accept)
        XCTAssertEqual(AtriaBLEManager.batteryEventAcceptanceDecision(
            previousLevel: 4,
            previousAcceptedAt: now.addingTimeInterval(-10 * 60),
            reading: .init(level: 0, millivolts: 3_180, isCharging: false),
            receivedAt: now,
            pending: nil
        ), .accept)

        for reading in [
            AtriaBLEManager.BatteryEventReading(level: 10, millivolts: 3_800, isCharging: false),
            AtriaBLEManager.BatteryEventReading(level: 10, millivolts: 3_480, isCharging: true),
            AtriaBLEManager.BatteryEventReading(level: 0, millivolts: 3_600, isCharging: false),
        ] {
            guard case .quarantine = AtriaBLEManager.batteryEventAcceptanceDecision(
                previousLevel: reading.level == 0 ? 4 : 14,
                previousAcceptedAt: now.addingTimeInterval(-10 * 60),
                reading: reading,
                receivedAt: now,
                pending: nil
            ) else {
                return XCTFail("electrically contradictory low/empty events must remain quarantined: \(reading)")
            }
        }
    }

    func testAutonomousBoundaryEventRejectsStaleOrImplausibleTrajectory() {
        let now = Date(timeIntervalSince1970: 50_000)
        let candidates: [(Int, Date?, AtriaBLEManager.BatteryEventReading)] = [
            (89, now.addingTimeInterval(-60), .init(level: 10, millivolts: 3_450, isCharging: false)),
            (14, now.addingTimeInterval(-(7 * 60 * 60)), .init(level: 10, millivolts: 3_450, isCharging: false)),
            (43, now.addingTimeInterval(-60), .init(level: 0, millivolts: 3_150, isCharging: false)),
            (43, now.addingTimeInterval(-60), .init(level: 100, millivolts: 4_220, isCharging: false)),
        ]
        for (previous, previousAt, reading) in candidates {
            guard case .quarantine = AtriaBLEManager.batteryEventAcceptanceDecision(
                previousLevel: previous,
                previousAcceptedAt: previousAt,
                reading: reading,
                receivedAt: now,
                pending: nil,
                previousIsCached: true,
                requiresFreshConfirmation: true
            ) else {
                return XCTFail("restoration-like boundary event must remain quarantined: \(reading)")
            }
        }
    }

    func testRelaunchNotificationCannotPromoteBoundaryButStrongEventCan() {
        let now = Date(timeIntervalSince1970: 50_000)
        guard case .quarantine = AtriaBLEManager.batteryLevelAcceptanceDecision(
            previousLevel: 96,
            previousAcceptedAt: now.addingTimeInterval(-5 * 60),
            incomingLevel: 100,
            receivedAt: now,
            pending: nil,
            previousIsCached: true,
            requiresFreshConfirmation: true,
            trustedCurrentConnectionNotification: true
        ) else {
            return XCTFail("a current 2A19 notification is transport proof, not electrical boundary proof")
        }

        XCTAssertEqual(AtriaBLEManager.batteryEventAcceptanceDecision(
            previousLevel: 96,
            previousAcceptedAt: now.addingTimeInterval(-5 * 60),
            reading: .init(level: 100, millivolts: 4_100, isCharging: true),
            receivedAt: now,
            pending: nil,
            previousIsCached: true,
            requiresFreshConfirmation: true,
            previousChargeStatus: .charging
        ), .accept, "the same relaunch may accept independently corroborated autonomous boundary truth")
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

    func testProtectedStandardHRObservesOnlyProductionR10Stream() {
        XCTAssertTrue(AtriaBLEManager.shouldObservePassiveR10InProtectedStandardHR(
            characteristicUUID: AtriaBLEManager.UUIDs.strapStream5
        ))
        XCTAssertFalse(AtriaBLEManager.shouldObservePassiveR10InProtectedStandardHR(
            characteristicUUID: AtriaBLEManager.UUIDs.strapRX
        ))
        XCTAssertFalse(AtriaBLEManager.shouldObservePassiveR10InProtectedStandardHR(
            characteristicUUID: AtriaBLEManager.UUIDs.strapStream4
        ))
        XCTAssertFalse(AtriaBLEManager.shouldObservePassiveR10InProtectedStandardHR(
            characteristicUUID: AtriaBLEManager.UUIDs.strapStream7
        ))
        XCTAssertFalse(AtriaBLEManager.shouldObservePassiveR10InProtectedStandardHR(
            characteristicUUID: AtriaBLEManager.UUIDs.strapTX
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
        let now = Date(timeIntervalSince1970: 20_000)
        XCTAssertTrue(AtriaBLEManager.hasValidRangeLossBackfillRequest(
            pending: true,
            requestedAt: now.timeIntervalSince1970 - 30,
            now: now
        ))
        XCTAssertFalse(AtriaBLEManager.hasValidRangeLossBackfillRequest(
            pending: true,
            requestedAt: nil,
            now: now
        ), "a stranded pending bit is not enough to seize the history transport")
        XCTAssertFalse(AtriaBLEManager.hasValidRangeLossBackfillRequest(
            pending: true,
            requestedAt: now.timeIntervalSince1970 + 60,
            now: now
        ), "a corrupt future request must fail closed")

        let disconnectedGapAllowed = AtriaBLEManager.shouldAllowProtectedHistoricalRecovery(
            linkConnected: false,
            exactGapPending: true,
            verifiedHistoryCapability: true,
            activeExplicitWorkout: false,
            syncInProgress: false,
            explicitUserRequest: false
        )
        XCTAssertTrue(disconnectedGapAllowed)
        let continuityDeferred = !disconnectedGapAllowed
            && AtriaBLEManager.shouldDeferAutomaticOfflineSyncForProtectedR10Continuity(
                standardHROnlyMode: true,
                explicitUserRequest: false
            )
        let qualificationDeferred = !disconnectedGapAllowed
            && AtriaBLEManager.shouldDeferOfflineSyncForProtectedR10Qualification(
                standardHROnlyMode: true,
                stableTransportProven: true,
                explicitUserRequest: false
            )
        XCTAssertFalse(continuityDeferred)
        XCTAssertFalse(qualificationDeferred,
                       "the protected guards must not make the admitted history-first reconnect unreachable")
        XCTAssertTrue(AtriaBLEManager.shouldDeferOfflineSyncForProtectedR10Qualification(
            standardHROnlyMode: true,
            stableTransportProven: true,
            explicitUserRequest: false
        ), "without the narrow admission, protected realtime remains authoritative")
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

    func testRawHistoryTransportIsNotMisrepresentedAsMetricRecovery() {
        XCTAssertTrue(AtriaBLEManager.supportsVerifiedHistoricalRecovery(
            model: .strap4Class,
            previouslyVerified: false
        ))
        XCTAssertFalse(AtriaBLEManager.supportsVerifiedHistoricalMetricRecovery(
            model: .strap4Class,
            previouslyVerified: false,
            hasValidatedMetricLayout: false
        ), "raw archive support cannot repair HR or steps without a validated layout")
        XCTAssertTrue(AtriaBLEManager.supportsVerifiedHistoricalMetricRecovery(
            model: .strap4Class,
            previouslyVerified: false,
            hasValidatedMetricLayout: true
        ))
        XCTAssertFalse(AtriaBLEManager.supportsVerifiedHistoricalMetricRecovery(
            model: .unknown,
            previouslyVerified: false,
            hasValidatedMetricLayout: true
        ), "a decoder alone cannot assert an unverified hardware transport")
    }

    func testRawOnlyGapArchiveRunsOnceAtASafeNaturalDisconnect() {
        XCTAssertTrue(AtriaBLEManager.shouldAttemptRawOnlyHistoricalRecovery(
            exactGapPending: true,
            rawHistoryVerified: true,
            metricHistoryVerified: false,
            linkConnected: false,
            activeExplicitWorkout: false,
            explicitUserRequest: false,
            rawGapAlreadyArchived: false
        ))

        let unsafeVariants: [(Bool, Bool, Bool, Bool, Bool, Bool, Bool)] = [
            (false, true, false, false, false, false, false),
            (true, false, false, false, false, false, false),
            (true, true, true, false, false, false, false),
            (true, true, false, true, false, false, false),
            (true, true, false, false, true, false, false),
            (true, true, false, false, false, true, false),
            (true, true, false, false, false, false, true),
        ]
        for variant in unsafeVariants {
            XCTAssertFalse(AtriaBLEManager.shouldAttemptRawOnlyHistoricalRecovery(
                exactGapPending: variant.0,
                rawHistoryVerified: variant.1,
                metricHistoryVerified: variant.2,
                linkConnected: variant.3,
                activeExplicitWorkout: variant.4,
                explicitUserRequest: variant.5,
                rawGapAlreadyArchived: variant.6
            ))
        }
    }

    func testHistoricalGapFingerprintIsStableAndChangesWithExactRange() throws {
        let firstID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let secondID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let first = AtriaHistoricalGapLedger.Window(
            id: firstID,
            start: Date(timeIntervalSince1970: 100),
            end: Date(timeIntervalSince1970: 130),
            reason: "disconnect"
        )
        let second = AtriaHistoricalGapLedger.Window(
            id: secondID,
            start: Date(timeIntervalSince1970: 200),
            end: Date(timeIntervalSince1970: 260),
            reason: "accepted_hr_gap"
        )

        let forward = try XCTUnwrap(AtriaBLEManager.historicalGapFingerprint([first, second]))
        XCTAssertEqual(forward,
                       AtriaBLEManager.historicalGapFingerprint([second, first]))
        var changed = second
        changed.end = Date(timeIntervalSince1970: 261)
        XCTAssertNotEqual(forward,
                          AtriaBLEManager.historicalGapFingerprint([first, changed]))
        XCTAssertNil(AtriaBLEManager.historicalGapFingerprint([]))
    }

    func testLegacyRequestedGapAlsoHasAStableOneShotFingerprint() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let end = Date(timeIntervalSince1970: 1_300)
        let first = try XCTUnwrap(AtriaBLEManager.historicalGapFingerprint(
            windows: [],
            recoveryStart: start,
            recoveryEnd: end,
            requestedAt: 900
        ))
        XCTAssertEqual(first, AtriaBLEManager.historicalGapFingerprint(
            windows: [],
            recoveryStart: start,
            recoveryEnd: end,
            requestedAt: 900
        ))
        XCTAssertNotEqual(first, AtriaBLEManager.historicalGapFingerprint(
            windows: [],
            recoveryStart: start,
            recoveryEnd: end.addingTimeInterval(1),
            requestedAt: 900
        ))
        XCTAssertNil(AtriaBLEManager.historicalGapFingerprint(
            windows: [],
            recoveryStart: nil,
            recoveryEnd: nil,
            requestedAt: nil
        ))
    }

    func testSameLevelBatteryReadPreservesOnlyFreshIndependentChargingProof() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertTrue(AtriaBLEManager.shouldPreserveFreshChargingEvidence(
            currentStatus: .charging,
            lastEvidenceAt: now.addingTimeInterval(-480),
            receivedAt: now,
            maximumAge: 600
        ), "a percentage-only callback must not erase the physical event between its normal reports")
        XCTAssertFalse(AtriaBLEManager.shouldPreserveFreshChargingEvidence(
            currentStatus: .charging,
            lastEvidenceAt: now.addingTimeInterval(-601),
            receivedAt: now,
            maximumAge: 600
        ))
        XCTAssertFalse(AtriaBLEManager.shouldPreserveFreshChargingEvidence(
            currentStatus: .levelOnly,
            lastEvidenceAt: now,
            receivedAt: now,
            maximumAge: 600
        ), "2A19 cannot originate charging state")
        XCTAssertFalse(AtriaBLEManager.shouldPreserveFreshChargingEvidence(
            currentStatus: .charging,
            lastEvidenceAt: nil,
            receivedAt: now,
            maximumAge: 600
        ))
        XCTAssertTrue(AtriaBLEManager.hasFreshBatteryRiseEvidence(
            lastRiseAt: now.addingTimeInterval(-599),
            receivedAt: now,
            maximumAge: 600
        ))
        XCTAssertFalse(AtriaBLEManager.hasFreshBatteryRiseEvidence(
            lastRiseAt: now.addingTimeInterval(-601),
            receivedAt: now,
            maximumAge: 600
        ))
        XCTAssertFalse(AtriaBLEManager.hasFreshBatteryRiseEvidence(
            lastRiseAt: nil,
            receivedAt: now,
            maximumAge: 600
        ))
    }

    func testChargingTrajectoryNeedsMultipleAcceptedMidrangeRisesAcrossTime() throws {
        let start = Date(timeIntervalSince1970: 20_000)
        let first = try XCTUnwrap(AtriaBLEManager.updatedBatteryRiseCandidate(
            current: nil,
            previousLevel: 22,
            previousAcceptedAt: start,
            newLevel: 23,
            receivedAt: start.addingTimeInterval(20)
        ))
        XCTAssertFalse(AtriaBLEManager.batteryRiseCandidateProvesCharging(first))
        let second = try XCTUnwrap(AtriaBLEManager.updatedBatteryRiseCandidate(
            current: first,
            previousLevel: 23,
            previousAcceptedAt: start.addingTimeInterval(20),
            newLevel: 24,
            receivedAt: start.addingTimeInterval(65)
        ))
        XCTAssertFalse(AtriaBLEManager.batteryRiseCandidateProvesCharging(second))
        let third = try XCTUnwrap(AtriaBLEManager.updatedBatteryRiseCandidate(
            current: second,
            previousLevel: 24,
            previousAcceptedAt: start.addingTimeInterval(65),
            newLevel: 25,
            receivedAt: start.addingTimeInterval(100)
        ))
        XCTAssertTrue(AtriaBLEManager.batteryRiseCandidateProvesCharging(third))
        XCTAssertNil(AtriaBLEManager.updatedBatteryRiseCandidate(
            current: third,
            previousLevel: 25,
            previousAcceptedAt: start.addingTimeInterval(100),
            newLevel: 24,
            receivedAt: start.addingTimeInterval(125)
        ), "a decline immediately revokes the charge trajectory")
    }

    func testReconnectBaselineDoesNotEraseFreshPersistedChargingTruth() {
        let now = Date(timeIntervalSince1970: 15_000)
        XCTAssertTrue(AtriaBLEManager.shouldRetainPersistedChargingAcrossReconnect(
            persistedStatus: .charging,
            persistedAt: now.addingTimeInterval(-599),
            batteryRecentlyDropping: false,
            now: now,
            maximumAge: 600
        ))
        XCTAssertFalse(AtriaBLEManager.shouldRetainPersistedChargingAcrossReconnect(
            persistedStatus: .charging,
            persistedAt: now.addingTimeInterval(-601),
            batteryRecentlyDropping: false,
            now: now,
            maximumAge: 600
        ))
        XCTAssertFalse(AtriaBLEManager.shouldRetainPersistedChargingAcrossReconnect(
            persistedStatus: .levelOnly,
            persistedAt: now,
            batteryRecentlyDropping: false,
            now: now,
            maximumAge: 600
        ))
        XCTAssertFalse(AtriaBLEManager.shouldRetainPersistedChargingAcrossReconnect(
            persistedStatus: .charging,
            persistedAt: now,
            batteryRecentlyDropping: true,
            now: now,
            maximumAge: 600
        ))
    }

    func testRiseCandidateSurvivesOnlySameStrapShortReconnect() throws {
        let start = Date(timeIntervalSince1970: 16_000)
        let strapID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let otherID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let candidate = try XCTUnwrap(AtriaBLEManager.updatedBatteryRiseCandidate(
            current: nil,
            previousLevel: 30,
            previousAcceptedAt: start,
            newLevel: 31,
            receivedAt: start.addingTimeInterval(20)
        ))

        XCTAssertEqual(AtriaBLEManager.batteryRiseCandidateAfterReconnect(
            candidate,
            candidatePeripheralID: strapID,
            connectedPeripheralID: strapID,
            now: start.addingTimeInterval(40),
            maximumAge: 600
        ), candidate)
        XCTAssertNil(AtriaBLEManager.batteryRiseCandidateAfterReconnect(
            candidate,
            candidatePeripheralID: strapID,
            connectedPeripheralID: otherID,
            now: start.addingTimeInterval(40),
            maximumAge: 600
        ))
        XCTAssertNil(AtriaBLEManager.batteryRiseCandidateAfterReconnect(
            candidate,
            candidatePeripheralID: strapID,
            connectedPeripheralID: strapID,
            now: start.addingTimeInterval(621),
            maximumAge: 600
        ))
        XCTAssertNil(AtriaBLEManager.batteryRiseCandidateAfterReconnect(
            candidate,
            candidatePeripheralID: strapID,
            connectedPeripheralID: strapID,
            now: start,
            maximumAge: 600
        ))
    }

    func testChargingTrajectoryRejectsSingleJumpSentinelsAndFastCorrections() throws {
        let start = Date(timeIntervalSince1970: 30_000)
        let jump = try XCTUnwrap(AtriaBLEManager.updatedBatteryRiseCandidate(
            current: nil,
            previousLevel: 22,
            previousAcceptedAt: start,
            newLevel: 34,
            receivedAt: start.addingTimeInterval(90)
        ))
        XCTAssertFalse(AtriaBLEManager.batteryRiseCandidateProvesCharging(jump),
                       "one large correction cannot claim external power")
        XCTAssertNil(AtriaBLEManager.updatedBatteryRiseCandidate(
            current: nil,
            previousLevel: 99,
            previousAcceptedAt: start,
            newLevel: 100,
            receivedAt: start.addingTimeInterval(60)
        ))
        let rapidSecond = try XCTUnwrap(AtriaBLEManager.updatedBatteryRiseCandidate(
            current: jump,
            previousLevel: 34,
            previousAcceptedAt: start.addingTimeInterval(90),
            newLevel: 35,
            receivedAt: start.addingTimeInterval(95)
        ))
        XCTAssertFalse(AtriaBLEManager.batteryRiseCandidateProvesCharging(rapidSecond),
                       "one correction plus one later rise cannot claim charging with production defaults")
        let sustainedThird = try XCTUnwrap(AtriaBLEManager.updatedBatteryRiseCandidate(
            current: rapidSecond,
            previousLevel: 35,
            previousAcceptedAt: start.addingTimeInterval(95),
            newLevel: 36,
            receivedAt: start.addingTimeInterval(130)
        ))
        XCTAssertTrue(AtriaBLEManager.batteryRiseCandidateProvesCharging(sustainedThird),
                      "two post-correction rises may establish a new trajectory")
    }

    func testExplicitNotChargingAndFullResetBatteryRiseTrajectory() throws {
        let start = Date(timeIntervalSince1970: 40_000)
        let candidate = try XCTUnwrap(AtriaBLEManager.updatedBatteryRiseCandidate(
            current: nil,
            previousLevel: 42,
            previousAcceptedAt: start,
            newLevel: 43,
            receivedAt: start.addingTimeInterval(30)
        ))

        XCTAssertNil(AtriaBLEManager.batteryRiseCandidateAfterExplicitChargeStatus(
            .notCharging,
            current: candidate
        ))
        XCTAssertNil(AtriaBLEManager.batteryRiseCandidateAfterExplicitChargeStatus(
            .full,
            current: candidate
        ))
        XCTAssertEqual(AtriaBLEManager.batteryRiseCandidateAfterExplicitChargeStatus(
            .charging,
            current: candidate
        ), candidate)
        XCTAssertEqual(AtriaBLEManager.batteryRiseCandidateAfterExplicitChargeStatus(
            .levelOnly,
            current: candidate
        ), candidate)
    }

    func testHistoryCompletionStatusReportsRawOnlyAndExactCoverageTruthfully() {
        XCTAssertEqual(AtriaBLEManager.historicalSyncCompletionStatus(
            newRows: 0,
            requestedWindowMetricProgress: false,
            ledgerCoverageResolved: false,
            hasValidatedMetricLayout: false
        ), "no_rows")
        XCTAssertEqual(AtriaBLEManager.historicalSyncCompletionStatus(
            newRows: 20,
            requestedWindowMetricProgress: false,
            ledgerCoverageResolved: false,
            hasValidatedMetricLayout: false
        ), "raw_archived_metric_unverified")
        XCTAssertEqual(AtriaBLEManager.historicalSyncCompletionStatus(
            newRows: 20,
            requestedWindowMetricProgress: false,
            ledgerCoverageResolved: false,
            hasValidatedMetricLayout: true
        ), "archived_gap_unresolved")
        XCTAssertEqual(AtriaBLEManager.historicalSyncCompletionStatus(
            newRows: 20,
            requestedWindowMetricProgress: true,
            ledgerCoverageResolved: false,
            hasValidatedMetricLayout: true
        ), "metric_progress")
        XCTAssertEqual(AtriaBLEManager.historicalSyncCompletionStatus(
            newRows: 20,
            requestedWindowMetricProgress: true,
            ledgerCoverageResolved: true,
            hasValidatedMetricLayout: true
        ), "gap_recovered")
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

    func testAutomaticRadioModeMigratesOnceToStableHRPlusR10() {
        XCTAssertTrue(AtriaBLEManager.shouldMigrateAutomaticModeToProtectedR10(
            migrationWasRecorded: false,
            userSelectedRadioMode: false
        ))
        XCTAssertFalse(AtriaBLEManager.shouldMigrateAutomaticModeToProtectedR10(
            migrationWasRecorded: true,
            userSelectedRadioMode: false
        ))
        XCTAssertFalse(AtriaBLEManager.shouldMigrateAutomaticModeToProtectedR10(
            migrationWasRecorded: false,
            userSelectedRadioMode: true
        ))

        XCTAssertTrue(AtriaBLEManager.standardHROnlyModeAfterFullProtocolOverride(
            modeBeforeOverride: true,
            userSelectedBatterySaver: false
        ), "diagnostic expiry must restore the stable automatic HR + R10 profile")
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

    func testRangeLossBackfillNeedsExactLedgerCoverageBeforeClearing() {
        XCTAssertFalse(AtriaBLEManager.rangeLossBackfillCanClear(newRows: 0))
        XCTAssertFalse(AtriaBLEManager.rangeLossBackfillCanClear(newRows: 1),
                       "row count alone is never recovery evidence")
        XCTAssertTrue(AtriaBLEManager.rangeLossBackfillCanClear(
            newRows: 1,
            hasRequestedWindow: false,
            requestedWindowMetricProgress: false,
            ledgerCoverageResolved: true
        ))
        XCTAssertFalse(AtriaBLEManager.rangeLossBackfillCanClear(
            newRows: 20,
            hasRequestedWindow: true,
            requestedWindowMetricProgress: false,
            ledgerCoverageResolved: true
        ))
        XCTAssertFalse(AtriaBLEManager.rangeLossBackfillCanClear(
            newRows: 1,
            hasRequestedWindow: true,
            requestedWindowMetricProgress: true,
            ledgerCoverageResolved: true
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

    func testBareStandardBatteryBoundaryRemainsQuarantinedDespiteNearbyPrior() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        guard case .quarantine = AtriaBLEManager.batteryLevelAcceptanceDecision(
            previousLevel: 99,
            previousAcceptedAt: now.addingTimeInterval(-120),
            incomingLevel: 100,
            receivedAt: now,
            pending: nil
        ) else {
            return XCTFail("a nearby prior does not independently prove a bare restoration 100% value")
        }
        guard case .quarantine = AtriaBLEManager.batteryLevelAcceptanceDecision(
            previousLevel: 4,
            previousAcceptedAt: now.addingTimeInterval(-120),
            incomingLevel: 0,
            receivedAt: now,
            pending: nil
        ) else {
            return XCTFail("a bare 0% BAS value must wait for CRC-backed voltage and trajectory proof")
        }
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
        XCTAssertNil(AtriaBLEManager.chargeEvidenceFromBatteryLevelChange(
            previousLevel: 82, newLevel: 83
        ), "one percentage-point rise cannot claim the strap is charging")
        XCTAssertEqual(AtriaBLEManager.chargeEvidenceFromBatteryLevelChange(
            previousLevel: 82, newLevel: 81
        ), .notCharging)
        XCTAssertEqual(AtriaBLEManager.chargeEvidenceFromBatteryLevelChange(
            previousLevel: 99, newLevel: 100
        ), .full)
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
        XCTAssertFalse(LocalNotificationScheduler.batterySnapshot(
            liveLevel: 10,
            liveChargeStatus: .notCharging,
            defaults: defaults,
            now: now
        ).usable, "a cached boundary value cannot retain live trajectory proof")

        defaults.set(43, forKey: AtriaBLEManager.BatteryDefaults.level)
        XCTAssertTrue(LocalNotificationScheduler.batterySnapshot(
            liveLevel: 43,
            liveChargeStatus: .notCharging,
            defaults: defaults,
            now: now
        ).usable)

        defaults.set(true, forKey: AtriaBLEManager.BatteryDefaults.requiresFreshConfirmation)
        XCTAssertFalse(LocalNotificationScheduler.batterySnapshot(
            liveLevel: 43,
            liveChargeStatus: .notCharging,
            defaults: defaults,
            now: now
        ).usable, "a reconnect cache is comparison evidence, not display truth")
        defaults.removeObject(forKey: AtriaBLEManager.BatteryDefaults.requiresFreshConfirmation)

        defaults.removeObject(forKey: AtriaBLEManager.BatteryDefaults.at)
        XCTAssertFalse(LocalNotificationScheduler.batterySnapshot(
            liveLevel: 43,
            liveChargeStatus: .levelOnly,
            defaults: defaults,
            now: now
        ).usable)
    }

    @MainActor
    func testBatteryNotificationAndWidgetConsumersHonorActiveMidrangeLease() throws {
        let suite = "AtriaBLERecoveryCadenceTests.notificationBatteryLease.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        defaults.set(12, forKey: AtriaBLEManager.BatteryDefaults.level)
        defaults.set("live_2A19", forKey: AtriaBLEManager.BatteryDefaults.source)
        defaults.set(now.addingTimeInterval(-40 * 60).timeIntervalSince1970,
                     forKey: AtriaBLEManager.BatteryDefaults.at)
        defaults.set(now.addingTimeInterval(-20).timeIntervalSince1970,
                     forKey: AtriaBLEManager.BatteryDefaults.notificationLeaseAt)
        defaults.set(now.addingTimeInterval(-5 * 60).timeIntervalSince1970,
                     forKey: AtriaBLEManager.BatteryDefaults.notificationConfirmedAt)

        XCTAssertTrue(AtriaBLEManager.cachedBattery(
            maxAge: 10 * 60,
            defaults: defaults,
            now: now,
            permitActiveNotificationLease: true
        ).usable)
        XCTAssertTrue(LocalNotificationScheduler.batterySnapshot(
            liveLevel: 12,
            liveChargeStatus: .levelOnly,
            defaults: defaults,
            now: now
        ).usable)

        defaults.set(true, forKey: AtriaBLEManager.BatteryDefaults.requiresFreshConfirmation)
        XCTAssertFalse(AtriaBLEManager.cachedBattery(
            maxAge: 10 * 60,
            defaults: defaults,
            now: now,
            permitActiveNotificationLease: true
        ).usable)
        defaults.set(false, forKey: AtriaBLEManager.BatteryDefaults.requiresFreshConfirmation)
        defaults.set(10, forKey: AtriaBLEManager.BatteryDefaults.level)
        XCTAssertFalse(AtriaBLEManager.cachedBattery(
            maxAge: 10 * 60,
            defaults: defaults,
            now: now,
            permitActiveNotificationLease: true
        ).usable, "restoration sentinels must remain unavailable even under an active lease")
    }

    @MainActor
    func testCachedBatteryAcceptsOnlyVerifiedLivePercentageSources() throws {
        let suite = "AtriaBLERecoveryCadenceTests.batterySource.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        defaults.set(43, forKey: AtriaBLEManager.BatteryDefaults.level)
        defaults.set(now.timeIntervalSince1970, forKey: AtriaBLEManager.BatteryDefaults.at)

        for source in ["live_2A19", "live_battery_event", "live_proprietary_1a"] {
            defaults.set(source, forKey: AtriaBLEManager.BatteryDefaults.source)
            XCTAssertTrue(AtriaBLEManager.cachedBattery(defaults: defaults, now: now).usable,
                          source)
        }

        for source in ["cached_2A19", "disputed_boundary_sentinel", "unknown"] {
            defaults.set(source, forKey: AtriaBLEManager.BatteryDefaults.source)
            XCTAssertFalse(AtriaBLEManager.cachedBattery(defaults: defaults, now: now).usable,
                           source)
        }
    }

    @MainActor
    func testCachedBoundaryBatteryNeverLeaksToWidgetsOrNotifications() throws {
        let suite = "AtriaBLERecoveryCadenceTests.batteryBoundary.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        defaults.set("live_2A19", forKey: AtriaBLEManager.BatteryDefaults.source)
        defaults.set(now.timeIntervalSince1970, forKey: AtriaBLEManager.BatteryDefaults.at)

        for level in [0, 10, 100] {
            defaults.set(level, forKey: AtriaBLEManager.BatteryDefaults.level)
            XCTAssertFalse(AtriaBLEManager.cachedBattery(defaults: defaults, now: now).usable,
                           "\(level)% is a physically observed replay sentinel")
        }
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

    func testFirstTrustedMidrangeNotificationResolvesPendingButSentinelsDoNot() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        XCTAssertEqual(AtriaBLEManager.batteryLevelAcceptanceDecision(
            previousLevel: -1,
            previousAcceptedAt: nil,
            incomingLevel: 43,
            receivedAt: now,
            pending: nil,
            requiresFreshConfirmation: true,
            trustedCurrentConnectionNotification: true
        ), .accept)

        for level in [0, 10, 100] {
            guard case .quarantine = AtriaBLEManager.batteryLevelAcceptanceDecision(
                previousLevel: -1,
                previousAcceptedAt: nil,
                incomingLevel: level,
                receivedAt: now,
                pending: nil,
                requiresFreshConfirmation: true,
                trustedCurrentConnectionNotification: true
            ) else {
                return XCTFail("A restoration sentinel must remain hidden: \(level)")
            }
        }
    }

    @MainActor
    func testActiveBatteryNotificationLeaseDoesNotRewriteLevelSampleAge() throws {
        let suite = "AtriaBLERecoveryCadenceTests.battery-notification-lease"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        defaults.set(43, forKey: AtriaBLEManager.BatteryDefaults.level)
        defaults.set("live_2A19", forKey: AtriaBLEManager.BatteryDefaults.source)
        defaults.set(now.addingTimeInterval(-3_600).timeIntervalSince1970,
                     forKey: AtriaBLEManager.BatteryDefaults.at)
        defaults.set(now.addingTimeInterval(-30).timeIntervalSince1970,
                     forKey: AtriaBLEManager.BatteryDefaults.notificationLeaseAt)
        defaults.set(false,
                     forKey: AtriaBLEManager.BatteryDefaults.requiresFreshConfirmation)

        let cached = AtriaBLEManager.cachedBattery(maxAge: 10 * 60,
                                                   defaults: defaults,
                                                   now: now)
        XCTAssertFalse(cached.usable,
                       "a transport lease must not make a one-hour-old percentage fresh")
        XCTAssertEqual(cached.age, 3_600, accuracy: 0.001)
        defaults.set(true,
                     forKey: AtriaBLEManager.BatteryDefaults.requiresFreshConfirmation)
        XCTAssertFalse(AtriaBLEManager.cachedBattery(maxAge: 10 * 60,
                                                      defaults: defaults,
                                                      now: now).usable)
    }

    func testNotificationLeaseBridgesOnlyAConnectedMidrangeLive2A19Restoration() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let leaseAt = now.addingTimeInterval(-30)
        XCTAssertTrue(AtriaBLEManager.notificationLeaseSupportsBatteryDisplay(
            level: 43,
            source: "live_2A19",
            requiresFreshConfirmation: false,
            linkConnected: true,
            notificationLeaseAt: leaseAt,
            now: now
        ))
        for level in [0, 10, 100] {
            XCTAssertFalse(AtriaBLEManager.notificationLeaseSupportsBatteryDisplay(
                level: level,
                source: "live_2A19",
                requiresFreshConfirmation: false,
                linkConnected: true,
                notificationLeaseAt: leaseAt,
                now: now
            ))
        }
        XCTAssertFalse(AtriaBLEManager.notificationLeaseSupportsBatteryDisplay(
            level: 43,
            source: "live_battery_event",
            requiresFreshConfirmation: false,
            linkConnected: true,
            notificationLeaseAt: leaseAt,
            now: now
        ))
        XCTAssertFalse(AtriaBLEManager.notificationLeaseSupportsBatteryDisplay(
            level: 43,
            source: "live_2A19",
            requiresFreshConfirmation: true,
            linkConnected: true,
            notificationLeaseAt: leaseAt,
            now: now
        ))
        XCTAssertFalse(AtriaBLEManager.notificationLeaseSupportsBatteryDisplay(
            level: 43,
            source: "live_2A19",
            requiresFreshConfirmation: false,
            linkConnected: false,
            notificationLeaseAt: leaseAt,
            now: now
        ))
        XCTAssertFalse(AtriaBLEManager.notificationLeaseSupportsBatteryDisplay(
            level: 43,
            source: "live_2A19",
            requiresFreshConfirmation: false,
            linkConnected: true,
            notificationLeaseAt: now.addingTimeInterval(-601),
            now: now
        ))
    }

    func testBatteryHydrationRevokesOldLeaseAndNotifyActivationRetriesPromotion() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let source = try String(contentsOf: testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaBLEManager.swift"), encoding: .utf8)
        let hydrateStart = try XCTUnwrap(source.range(of: "private func hydrateCachedBatteryStateIfFresh"))
        let hydrateEnd = try XCTUnwrap(source.range(
            of: "private func promoteReconnectBatteryBaselineIfSafe",
            range: hydrateStart.upperBound..<source.endIndex
        ))
        let hydrateBody = String(source[hydrateStart.lowerBound..<hydrateEnd.lowerBound])
        XCTAssertTrue(hydrateBody.contains("defaults.removeObject(forKey: BatteryDefaults.notificationLeaseAt)"))
        XCTAssertTrue(hydrateBody.contains("defaults.set(true, forKey: BatteryDefaults.requiresFreshConfirmation)"))
        XCTAssertTrue(hydrateBody.contains("permitPendingReconnectBaseline: true"))

        XCTAssertTrue(source.contains("reason: \"2A19_notify_became_active\""))
        XCTAssertTrue(source.contains("reason: \"2A19_restored_cache_notify_active\""))
        XCTAssertTrue(source.contains("reason: \"2A19_existing_notify_active\""))
    }

    @MainActor
    func testHydrationMayRetainOnlyTrustedMidrangeWhileFreshConfirmationIsPending() {
        let suite = "AtriaBLERecoveryCadenceTests.pendingHydration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 50_000)

        defaults.set(18, forKey: AtriaBLEManager.BatteryDefaults.level)
        defaults.set(now.addingTimeInterval(-25 * 60).timeIntervalSince1970,
                     forKey: AtriaBLEManager.BatteryDefaults.at)
        defaults.set("live_battery_event", forKey: AtriaBLEManager.BatteryDefaults.source)
        defaults.set(true, forKey: AtriaBLEManager.BatteryDefaults.requiresFreshConfirmation)

        XCTAssertFalse(AtriaBLEManager.cachedBattery(
            maxAge: 36 * 60 * 60,
            defaults: defaults,
            now: now
        ).usable, "ordinary consumers must still fail closed while confirmation is pending")
        XCTAssertTrue(AtriaBLEManager.cachedBattery(
            maxAge: 36 * 60 * 60,
            defaults: defaults,
            now: now,
            permitPendingReconnectBaseline: true
        ).usable, "launch hydration must retain accepted 18% as an aged reconnect baseline")

        defaults.set(100, forKey: AtriaBLEManager.BatteryDefaults.level)
        XCTAssertFalse(AtriaBLEManager.cachedBattery(
            maxAge: 36 * 60 * 60,
            defaults: defaults,
            now: now,
            permitPendingReconnectBaseline: true
        ).usable, "restored boundary sentinels remain ineligible")

        defaults.set(18, forKey: AtriaBLEManager.BatteryDefaults.level)
        defaults.set("disputed_rapid_transition", forKey: AtriaBLEManager.BatteryDefaults.source)
        XCTAssertFalse(AtriaBLEManager.cachedBattery(
            maxAge: 36 * 60 * 60,
            defaults: defaults,
            now: now,
            permitPendingReconnectBaseline: true
        ).usable, "disputed sources remain ineligible")
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
            credibleAt: now.addingTimeInterval(-6 * 60 * 60 - 1),
            now: now,
            maxAge: AtriaBLEManager.reconnectBatteryBaselineMaximumAge
        ), -1)
        XCTAssertEqual(AtriaBLEManager.reconnectBatteryDisplayLevel(
            currentLevel: 0,
            credibleLevel: 43,
            credibleAt: now.addingTimeInterval(-20 * 60),
            now: now,
            maxAge: AtriaBLEManager.reconnectBatteryBaselineMaximumAge
        ), 43, "cold launch must retain the same bounded baseline promotion can safely lease")
        XCTAssertEqual(AtriaBLEManager.reconnectBatteryDisplayLevel(
            currentLevel: 43,
            credibleLevel: 70,
            credibleAt: now,
            now: now
        ), 43)
    }

    func testStableNotificationReconnectPromotesRecentValidatedMidrangeBaseline() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let acceptedAt = now.addingTimeInterval(-20 * 60)
        XCTAssertTrue(AtriaBLEManager.shouldPromoteReconnectBatteryBaseline(
            level: 30,
            acceptedAt: acceptedAt,
            source: "live_2A19",
            displayedIsCached: true,
            requiresFreshConfirmation: true,
            notificationActive: true,
            linkConnected: true,
            currentConnectionHasHeartRate: true,
            hasPendingDisputedReading: false,
            currentNotificationEpochHadRejectedCallback: false,
            now: now
        ), "change-driven 2A19 must not leave a recent trusted value Pending forever")

        for sentinel in [0, 10, 100] {
            XCTAssertFalse(AtriaBLEManager.shouldPromoteReconnectBatteryBaseline(
                level: sentinel,
                acceptedAt: acceptedAt,
                source: "live_2A19",
                displayedIsCached: true,
                requiresFreshConfirmation: true,
                notificationActive: true,
                linkConnected: true,
                currentConnectionHasHeartRate: true,
                hasPendingDisputedReading: false,
                currentNotificationEpochHadRejectedCallback: false,
                now: now
            ), "restoration sentinel \(sentinel) must remain quarantined")
        }

        let common = (
            level: 30,
            acceptedAt: Optional(acceptedAt),
            source: "live_2A19",
            displayedIsCached: true,
            requiresFreshConfirmation: true,
            notificationActive: true,
            linkConnected: true,
            currentConnectionHasHeartRate: true
        )
        XCTAssertTrue(AtriaBLEManager.shouldPromoteReconnectBatteryBaseline(
            level: common.level,
            acceptedAt: now.addingTimeInterval(-6 * 60 * 60 - 1),
            source: common.source,
            displayedIsCached: common.displayedIsCached,
            requiresFreshConfirmation: common.requiresFreshConfirmation,
            notificationActive: common.notificationActive,
            linkConnected: common.linkConnected,
            currentConnectionHasHeartRate: common.currentConnectionHasHeartRate,
            hasPendingDisputedReading: false,
            currentNotificationEpochHadRejectedCallback: false,
            now: now
        ), "a proven current 2A19 subscription must not turn a valid mid-range level Pending after six hours")
        XCTAssertFalse(AtriaBLEManager.shouldPromoteReconnectBatteryBaseline(
            level: common.level,
            acceptedAt: now.addingTimeInterval(-36 * 60 * 60 - 1),
            source: common.source,
            displayedIsCached: common.displayedIsCached,
            requiresFreshConfirmation: common.requiresFreshConfirmation,
            notificationActive: common.notificationActive,
            linkConnected: common.linkConnected,
            currentConnectionHasHeartRate: common.currentConnectionHasHeartRate,
            hasPendingDisputedReading: false,
            currentNotificationEpochHadRejectedCallback: false,
            now: now
        ), "a transport lease cannot make a percentage older than the overnight bridge current")
        XCTAssertFalse(AtriaBLEManager.shouldPromoteReconnectBatteryBaseline(
            level: common.level,
            acceptedAt: now.addingTimeInterval(
                -AtriaBLEManager.activeBatterySubscriptionBaselineMaximumAge - 1
            ),
            source: common.source,
            displayedIsCached: common.displayedIsCached,
            requiresFreshConfirmation: common.requiresFreshConfirmation,
            notificationActive: common.notificationActive,
            linkConnected: common.linkConnected,
            currentConnectionHasHeartRate: common.currentConnectionHasHeartRate,
            hasPendingDisputedReading: false,
            currentNotificationEpochHadRejectedCallback: false,
            now: now
        ), "even a proven subscription must not carry a percentage beyond the bounded overnight bridge")
        XCTAssertFalse(AtriaBLEManager.shouldPromoteReconnectBatteryBaseline(
            level: common.level,
            acceptedAt: common.acceptedAt,
            source: "unknown",
            displayedIsCached: common.displayedIsCached,
            requiresFreshConfirmation: common.requiresFreshConfirmation,
            notificationActive: common.notificationActive,
            linkConnected: common.linkConnected,
            currentConnectionHasHeartRate: common.currentConnectionHasHeartRate,
            hasPendingDisputedReading: false,
            currentNotificationEpochHadRejectedCallback: false,
            now: now
        ))
        XCTAssertFalse(AtriaBLEManager.shouldPromoteReconnectBatteryBaseline(
            level: common.level,
            acceptedAt: common.acceptedAt,
            source: common.source,
            displayedIsCached: common.displayedIsCached,
            requiresFreshConfirmation: common.requiresFreshConfirmation,
            notificationActive: false,
            linkConnected: common.linkConnected,
            currentConnectionHasHeartRate: common.currentConnectionHasHeartRate,
            hasPendingDisputedReading: false,
            currentNotificationEpochHadRejectedCallback: false,
            now: now
        ))
        XCTAssertFalse(AtriaBLEManager.shouldPromoteReconnectBatteryBaseline(
            level: common.level,
            acceptedAt: common.acceptedAt,
            source: common.source,
            displayedIsCached: common.displayedIsCached,
            requiresFreshConfirmation: common.requiresFreshConfirmation,
            notificationActive: common.notificationActive,
            linkConnected: common.linkConnected,
            currentConnectionHasHeartRate: false,
            hasPendingDisputedReading: false,
            currentNotificationEpochHadRejectedCallback: false,
            now: now
        ))

        XCTAssertTrue(AtriaBLEManager.shouldPromoteReconnectBatteryBaseline(
            level: common.level,
            acceptedAt: common.acceptedAt,
            source: "live_battery_event",
            displayedIsCached: common.displayedIsCached,
            requiresFreshConfirmation: common.requiresFreshConfirmation,
            notificationActive: common.notificationActive,
            linkConnected: common.linkConnected,
            currentConnectionHasHeartRate: common.currentConnectionHasHeartRate,
            hasPendingDisputedReading: false,
            currentNotificationEpochHadRejectedCallback: false,
            now: now
        ), "a recent CRC + voltage validated battery event is safe recent baseline truth")

        for rejectedSource in ["live_proprietary_1a", "cached_2A19", "unknown"] {
            XCTAssertFalse(AtriaBLEManager.shouldPromoteReconnectBatteryBaseline(
                level: common.level,
                acceptedAt: common.acceptedAt,
                source: rejectedSource,
                displayedIsCached: common.displayedIsCached,
                requiresFreshConfirmation: common.requiresFreshConfirmation,
                notificationActive: common.notificationActive,
                linkConnected: common.linkConnected,
                currentConnectionHasHeartRate: common.currentConnectionHasHeartRate,
                hasPendingDisputedReading: false,
                currentNotificationEpochHadRejectedCallback: false,
                now: now
            ), "an unqualified source must never inherit the standard notification lease")
        }

        for (pending, rejectedEpochCallback) in [(true, false), (false, true)] {
            XCTAssertFalse(AtriaBLEManager.shouldPromoteReconnectBatteryBaseline(
                level: common.level,
                acceptedAt: common.acceptedAt,
                source: common.source,
                displayedIsCached: common.displayedIsCached,
                requiresFreshConfirmation: common.requiresFreshConfirmation,
                notificationActive: common.notificationActive,
                linkConnected: common.linkConnected,
                currentConnectionHasHeartRate: common.currentConnectionHasHeartRate,
                hasPendingDisputedReading: pending,
                currentNotificationEpochHadRejectedCallback: rejectedEpochCallback,
                now: now
            ), "a disputed or unadjudicated current-link callback must remain Pending")
        }
    }

    func testKeepaliveRetainsReconnectBatteryBaselineUntilProofCanArrive() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let acceptedAt = now.addingTimeInterval(-25 * 60)
        let validationStartedAt = now.addingTimeInterval(-8)

        XCTAssertTrue(AtriaBLEManager.reconnectBatteryBaselineIsAwaitingProof(
            level: 12,
            acceptedAt: acceptedAt,
            source: "live_2A19",
            displayedIsCached: true,
            requiresFreshConfirmation: true,
            linkConnected: true,
            sameSavedPeripheral: true,
            validationStartedAt: validationStartedAt,
            now: now
        ), "the first keepalive tick must not erase a valid baseline before HR promotion")

        XCTAssertFalse(AtriaBLEManager.reconnectBatteryBaselineIsAwaitingProof(
            level: 12,
            acceptedAt: acceptedAt,
            source: "live_2A19",
            displayedIsCached: true,
            requiresFreshConfirmation: true,
            linkConnected: true,
            sameSavedPeripheral: true,
            validationStartedAt: now.addingTimeInterval(-91),
            now: now
        ), "a failed reconnect must not retain an undisplayable baseline indefinitely")

        for sentinel in [0, 10, 100] {
            XCTAssertFalse(AtriaBLEManager.reconnectBatteryBaselineIsAwaitingProof(
                level: sentinel,
                acceptedAt: acceptedAt,
                source: "live_2A19",
                displayedIsCached: true,
                requiresFreshConfirmation: true,
                linkConnected: true,
                sameSavedPeripheral: true,
                validationStartedAt: validationStartedAt,
                now: now
            ))
        }
    }

    func testTrustedCurrentConnectionBatteryNotificationIsRadioProfileIndependent() throws {
        XCTAssertTrue(AtriaBLEManager.batteryReconnectBaselineSourceIsLeaseEligible("live_2A19"))
        XCTAssertTrue(AtriaBLEManager.batteryReconnectBaselineSourceIsLeaseEligible("live_battery_event"))
        XCTAssertFalse(AtriaBLEManager.batteryReconnectBaselineSourceIsLeaseEligible("live_proprietary_1a"))
        XCTAssertFalse(AtriaBLEManager.batteryReconnectBaselineSourceIsLeaseEligible("disputed_boundary_sentinel"))

        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaBLEManager.swift"), encoding: .utf8)
        let callbackStart = try XCTUnwrap(source.range(of: "if uuid == UUIDs.batteryLevel"))
        let callbackEnd = try XCTUnwrap(source.range(
            of: "if uuid == UUIDs.batteryLevelStatus",
            range: callbackStart.upperBound..<source.endIndex
        ))
        let callback = String(source[callbackStart.lowerBound..<callbackEnd.lowerBound])
        XCTAssertTrue(callback.contains("trustedCurrentConnectionNotification: characteristic.isNotifying"))
        XCTAssertFalse(callback.contains("&& self.standardHROnlyMode"),
                       "standard 2A19 validity must not depend on the unrelated R10 radio profile")
    }

    func testRelaunchChainKeepsConfirmedNotificationLeaseWhenCoreBluetoothReplacesCharacteristic() {
        let acceptedAt = Date(timeIntervalSince1970: 10_000)
        let relaunchedAt = acceptedAt.addingTimeInterval(12 * 60)
        let confirmedAt = relaunchedAt.addingTimeInterval(1)
        let liveHRAt = confirmedAt.addingTimeInterval(1)

        XCTAssertTrue(AtriaBLEManager.batteryNotificationConfirmationSupportsCurrentConnection(
            confirmedAt: confirmedAt,
            lastError: nil,
            connectionStartedAt: relaunchedAt,
            linkConnected: true,
            now: liveHRAt
        ), "a current-epoch CCCD confirmation survives replacement of the restored characteristic object")
        XCTAssertTrue(AtriaBLEManager.shouldPromoteReconnectBatteryBaseline(
            level: 26,
            acceptedAt: acceptedAt,
            source: "live_2A19",
            displayedIsCached: true,
            requiresFreshConfirmation: true,
            notificationActive: true,
            linkConnected: true,
            currentConnectionHasHeartRate: true,
            now: liveHRAt
        ))

        XCTAssertFalse(AtriaBLEManager.batteryNotificationConfirmationSupportsCurrentConnection(
            confirmedAt: confirmedAt,
            lastError: "inactive",
            connectionStartedAt: relaunchedAt,
            linkConnected: true,
            now: liveHRAt
        ))
        XCTAssertFalse(AtriaBLEManager.batteryNotificationConfirmationSupportsCurrentConnection(
            confirmedAt: relaunchedAt.addingTimeInterval(-1),
            lastError: nil,
            connectionStartedAt: relaunchedAt,
            linkConnected: true,
            now: liveHRAt
        ), "a confirmation from the previous process/connection cannot cross the launch boundary")
        XCTAssertFalse(AtriaBLEManager.batteryNotificationConfirmationSupportsCurrentConnection(
            confirmedAt: confirmedAt,
            lastError: nil,
            connectionStartedAt: relaunchedAt,
            linkConnected: false,
            now: liveHRAt
        ))

        let restoredProcessAt = confirmedAt.addingTimeInterval(20 * 60)
        let savedID = UUID()
        XCTAssertTrue(AtriaBLEManager.batteryRestorationPreservesNotificationEpoch(
            restoredPeripheralIdentifier: savedID,
            savedPeripheralIdentifier: savedID,
            restoredPeripheralIsConnected: true
        ))
        XCTAssertFalse(AtriaBLEManager.batteryRestorationPreservesNotificationEpoch(
            restoredPeripheralIdentifier: UUID(),
            savedPeripheralIdentifier: savedID,
            restoredPeripheralIsConnected: true
        ))
        XCTAssertFalse(AtriaBLEManager.batteryRestorationPreservesNotificationEpoch(
            restoredPeripheralIdentifier: savedID,
            savedPeripheralIdentifier: savedID,
            restoredPeripheralIsConnected: false
        ))
        XCTAssertTrue(AtriaBLEManager.batteryNotificationConfirmationSupportsCurrentConnection(
            confirmedAt: confirmedAt,
            lastError: nil,
            connectionStartedAt: nil,
            linkConnected: true,
            now: restoredProcessAt
        ), "CoreBluetooth restoration may resume the same subscribed link without didConnect")
        XCTAssertFalse(AtriaBLEManager.batteryNotificationConfirmationSupportsCurrentConnection(
            confirmedAt: confirmedAt,
            lastError: nil,
            connectionStartedAt: nil,
            linkConnected: true,
            now: confirmedAt.addingTimeInterval(61 * 60)
        ), "a persisted restoration proof remains bounded")

        XCTAssertFalse(AtriaBLEManager.batteryNotificationConfirmationSupportsCurrentConnection(
            confirmedAt: confirmedAt,
            lastError: nil,
            connectionStartedAt: restoredProcessAt,
            linkConnected: true,
            now: restoredProcessAt.addingTimeInterval(1)
        ), "the same timestamps must fail for a genuine didConnect epoch")
    }

    func testRestoredSamePeripheralExplicitlyBypassesSyntheticConnectedAtForBatteryProof() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaBLEManager.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains(
            "connectionStartedAt: batteryConnectionRestoredSamePeripheral ? nil : connectedAt"
        ))
        XCTAssertTrue(source.contains("self.batteryConnectionRestoredSamePeripheral ="))
        XCTAssertTrue(source.contains("restoredPeripheralIdentifier: restoredPeripheral.identifier"))
        XCTAssertTrue(source.contains("self.batteryConnectionRestoredSamePeripheral = false"))
        XCTAssertTrue(source.contains("defaults.removeObject(forKey: BatteryDefaults.notificationConfirmedAt)"))
        XCTAssertTrue(source.contains("forKey: BatteryDefaults.notificationLastError"))
    }

    func testRecentValidatedMidrangeBaselineRemainsVisibleAcrossGenuineReconnectWithoutBecomingLive() {
        let acceptedAt = Date(timeIntervalSince1970: 10_000)
        let now = acceptedAt.addingTimeInterval(10 * 60 + 35)
        XCTAssertTrue(AtriaBLEManager.recentReconnectBatteryBaselineIsDisplayEligible(
            level: 25,
            acceptedAt: acceptedAt,
            source: "live_2A19",
            displayedIsCached: true,
            requiresFreshConfirmation: true,
            linkConnected: true,
            sameSavedPeripheral: true,
            currentConnectionHasHeartRate: true,
            hasPendingDisputedReading: false,
            currentNotificationEpochHadRejectedCallback: false,
            now: now
        ))

        for sentinel in [0, 10, 100] {
            XCTAssertFalse(AtriaBLEManager.recentReconnectBatteryBaselineIsDisplayEligible(
                level: sentinel,
                acceptedAt: acceptedAt,
                source: "live_2A19",
                displayedIsCached: true,
                requiresFreshConfirmation: true,
                linkConnected: true,
                sameSavedPeripheral: true,
                currentConnectionHasHeartRate: true,
                hasPendingDisputedReading: false,
                currentNotificationEpochHadRejectedCallback: false,
                now: now
            ))
        }

        for (sameSaved, liveHR) in [
            (false, true),
            (true, false)
        ] {
            XCTAssertFalse(AtriaBLEManager.recentReconnectBatteryBaselineIsDisplayEligible(
                level: 25,
                acceptedAt: acceptedAt,
                source: "live_2A19",
                displayedIsCached: true,
                requiresFreshConfirmation: true,
                linkConnected: true,
                sameSavedPeripheral: sameSaved,
                currentConnectionHasHeartRate: liveHR,
                hasPendingDisputedReading: false,
                currentNotificationEpochHadRejectedCallback: false,
                now: now
            ))
        }
        for (pending, rejected) in [(true, false), (false, true), (true, true)] {
            XCTAssertTrue(AtriaBLEManager.recentReconnectBatteryBaselineIsDisplayEligible(
                level: 25,
                acceptedAt: acceptedAt,
                source: "live_2A19",
                displayedIsCached: true,
                requiresFreshConfirmation: true,
                linkConnected: true,
                sameSavedPeripheral: true,
                currentConnectionHasHeartRate: true,
                hasPendingDisputedReading: pending,
                currentNotificationEpochHadRejectedCallback: rejected,
                now: now
            ), "current-epoch disputes must block promotion, not the explicitly Recent baseline")
        }
        XCTAssertFalse(AtriaBLEManager.recentReconnectBatteryBaselineIsDisplayEligible(
            level: 25,
            acceptedAt: acceptedAt,
            source: "live_2A19",
            displayedIsCached: true,
            requiresFreshConfirmation: true,
            linkConnected: true,
            sameSavedPeripheral: true,
            currentConnectionHasHeartRate: true,
            hasPendingDisputedReading: false,
            currentNotificationEpochHadRejectedCallback: false,
            now: acceptedAt.addingTimeInterval(6 * 60 * 60 + 1)
        ))
        XCTAssertFalse(AtriaBLEManager.recentReconnectBatteryBaselineIsDisplayEligible(
            level: 25,
            acceptedAt: acceptedAt,
            source: "cached_2A19",
            displayedIsCached: true,
            requiresFreshConfirmation: true,
            linkConnected: true,
            sameSavedPeripheral: true,
            currentConnectionHasHeartRate: true,
            hasPendingDisputedReading: false,
            currentNotificationEpochHadRejectedCallback: false,
            now: now
        ))
    }

    func testRecentReconnectBaselineIsDisplayOnlyAndSurvivesKeepaliveStalenessGate() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaBLEManager.swift"), encoding: .utf8)
        let displayStart = try XCTUnwrap(source.range(of: "func displayableBatteryLevel"))
        let displayEnd = try XCTUnwrap(source.range(
            of: "nonisolated static func reconnectBatteryDisplayLevel",
            range: displayStart.upperBound..<source.endIndex
        ))
        let displayBody = String(source[displayStart.lowerBound..<displayEnd.lowerBound])
        XCTAssertTrue(displayBody.contains("if recentReconnectBaseline { return batteryLevel }"))
        XCTAssertFalse(displayBody.contains("removeObject(forKey: BatteryDefaults.requiresFreshConfirmation)"))

        let keepaliveStart = try XCTUnwrap(source.range(of: "private func runForegroundKeepaliveTick"))
        let keepaliveEnd = try XCTUnwrap(source.range(
            of: "private func stopForegroundKeepaliveWatchdog",
            range: keepaliveStart.upperBound..<source.endIndex
        ))
        let keepaliveBody = String(source[keepaliveStart.lowerBound..<keepaliveEnd.lowerBound])
        XCTAssertTrue(keepaliveBody.contains("!recentReconnectBatteryBaselineDisplayable"))
    }

    func testFreshConnectedCachedBatteryBaselineDisplaysDuringSilentLiveRefresh() {
        let now = Date(timeIntervalSince1970: 1_800_200_000)

        XCTAssertTrue(AtriaBLEManager.freshConnectedCachedBatteryBaselineIsDisplayEligible(
            level: 14,
            acceptedAt: now.addingTimeInterval(-30),
            source: "live_2A19",
            displayedIsCached: true,
            requiresFreshConfirmation: true,
            linkConnected: true,
            sameSavedPeripheral: true,
            now: now
        ))

        for invalidLevel in [0, 10, 100] {
            XCTAssertFalse(AtriaBLEManager.freshConnectedCachedBatteryBaselineIsDisplayEligible(
                level: invalidLevel,
                acceptedAt: now.addingTimeInterval(-30),
                source: "live_2A19",
                displayedIsCached: true,
                requiresFreshConfirmation: true,
                linkConnected: true,
                sameSavedPeripheral: true,
                now: now
            ))
        }
        XCTAssertFalse(AtriaBLEManager.freshConnectedCachedBatteryBaselineIsDisplayEligible(
            level: 14,
            acceptedAt: now.addingTimeInterval(-AtriaBLEManager.batteryDisplayFreshnessLimit - 1),
            source: "live_2A19",
            displayedIsCached: true,
            requiresFreshConfirmation: true,
            linkConnected: true,
            sameSavedPeripheral: true,
            now: now
        ))
        XCTAssertFalse(AtriaBLEManager.freshConnectedCachedBatteryBaselineIsDisplayEligible(
            level: 14,
            acceptedAt: now.addingTimeInterval(-30),
            source: "cached_2A19",
            displayedIsCached: true,
            requiresFreshConfirmation: true,
            linkConnected: true,
            sameSavedPeripheral: true,
            now: now
        ))
        XCTAssertFalse(AtriaBLEManager.freshConnectedCachedBatteryBaselineIsDisplayEligible(
            level: 14,
            acceptedAt: now.addingTimeInterval(-30),
            source: "live_2A19",
            displayedIsCached: true,
            requiresFreshConfirmation: true,
            linkConnected: false,
            sameSavedPeripheral: true,
            now: now
        ))
    }

    func testFirstAcceptedHRPublishesRecentBatteryBaselineProjectionOnce() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaBLEManager.swift"), encoding: .utf8)
        let methodStart = try XCTUnwrap(source.range(
            of: "private func publishRecentReconnectBatteryBaselineIfNeeded"
        ))
        let methodEnd = try XCTUnwrap(source.range(
            of: "private func revokeBatteryNotificationLease",
            range: methodStart.upperBound..<source.endIndex
        ))
        let method = String(source[methodStart.lowerBound..<methodEnd.lowerBound])
        XCTAssertTrue(method.contains("!recentReconnectBatteryBaselineProjectionPublished"))
        XCTAssertTrue(method.contains("recentReconnectBatteryBaselineIsDisplayable(now: now)"))
        XCTAssertTrue(method.contains("recentReconnectBatteryBaselineProjectionPublished = true"))
        XCTAssertTrue(method.contains("batteryProjectionRevision &+= 1"))

        let acceptedStart = try XCTUnwrap(source.range(of: "private func recordAcceptedHRSample"))
        let acceptedEnd = try XCTUnwrap(source.range(
            of: "fileprivate func record(_ rate:",
            range: acceptedStart.upperBound..<source.endIndex
        ))
        let accepted = String(source[acceptedStart.lowerBound..<acceptedEnd.lowerBound])
        XCTAssertTrue(accepted.contains("publishRecentReconnectBatteryBaselineIfNeeded(now: sampleTime)"))
    }

    func testKeepaliveUsesDurableBatteryNotificationTransportProof() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaBLEManager.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private func runForegroundKeepaliveTick"))
        let end = try XCTUnwrap(source.range(
            of: "private func stopForegroundKeepaliveWatchdog",
            range: start.upperBound..<source.endIndex
        ))
        let body = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("let batteryNotificationTransportActive = batteryNotificationTransportIsActive"))
        XCTAssertTrue(body.contains("!(batteryNotificationTransportActive"))
        XCTAssertTrue(body.contains("batteryNotificationTransportActive,"))
        XCTAssertFalse(body.contains("batteryLevelCharacteristic?.isNotifying == true"),
                       "the stale-value watchdog must not revoke a confirmed lease because CoreBluetooth replaced its object")
    }

    func testRestoredConnectionUsesProcessBatteryValidationEpochWhenDidConnectIsAbsent() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaBLEManager.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("let connectionStartedAt = connectedAt ?? batteryBaselineValidationStartedAt"))
        XCTAssertTrue(source.contains("let currentConnectionHasHeartRate = heartRateReceivedAt >= connectionStartedAt"))
        XCTAssertTrue(source.contains("batteryBaselineValidationStartedAt = Date()"))
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

    func testLowBatteryPreservesHeartRateUntilMotionTransportIsSafe() {
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

    func testMotionChargingOverrideRequiresTypedAndBooleanAgreement() {
        XCTAssertFalse(AtriaBLEManager.hasCredibleChargingForMotion(
            isCharging: true,
            chargeStatus: .levelOnly
        ))
        XCTAssertFalse(AtriaBLEManager.hasCredibleChargingForMotion(
            isCharging: false,
            chargeStatus: .charging
        ))
        XCTAssertTrue(AtriaBLEManager.hasCredibleChargingForMotion(
            isCharging: true,
            chargeStatus: .charging
        ))
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

    func testLearningHRVFailureRetriesOnlyAfterFourHours() {
        let attempt = Date(timeIntervalSince1970: 50_000)
        let fourHours: TimeInterval = 4 * 60 * 60

        XCTAssertFalse(AtriaBLEManager.shouldAttemptHRVAnalysis(
            now: attempt.addingTimeInterval(fourHours - 0.001),
            lastReadyAnalysisAt: nil,
            lastAttemptAt: attempt,
            isRecording: false,
            hasReadySnapshot: false,
            cleanWindowSeconds: 300,
            foregroundInteractive: false
        ))
        XCTAssertTrue(AtriaBLEManager.shouldAttemptHRVAnalysis(
            now: attempt.addingTimeInterval(fourHours),
            lastReadyAnalysisAt: nil,
            lastAttemptAt: attempt,
            isRecording: false,
            hasReadySnapshot: false,
            cleanWindowSeconds: 300,
            foregroundInteractive: false
        ))
    }

    func testFailedAutomaticRefreshWithOlderReadySnapshotStillWaitsFourHours() {
        let ready = Date(timeIntervalSince1970: 50_000)
        let failedAttempt = ready.addingTimeInterval(4 * 60 * 60)

        XCTAssertFalse(AtriaBLEManager.shouldAttemptHRVAnalysis(
            now: failedAttempt.addingTimeInterval(4 * 60 * 60 - 0.001),
            lastReadyAnalysisAt: ready,
            lastAttemptAt: failedAttempt,
            isRecording: false,
            hasReadySnapshot: true,
            cleanWindowSeconds: 300,
            foregroundInteractive: true
        ))
        XCTAssertTrue(AtriaBLEManager.shouldAttemptHRVAnalysis(
            now: failedAttempt.addingTimeInterval(4 * 60 * 60),
            lastReadyAnalysisAt: ready,
            lastAttemptAt: failedAttempt,
            isRecording: false,
            hasReadySnapshot: true,
            cleanWindowSeconds: 300,
            foregroundInteractive: true
        ))
    }

    func testNormalWearAttemptMarkerPersistsAcrossRelaunch() throws {
        let suiteName = "AtriaBLERecoveryCadenceTests.hrv.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let attempt = Date(timeIntervalSince1970: 55_000)

        XCTAssertNil(AtriaBLEManager.readNormalWearHRVAnalysisAttemptDate(
            userDefaults: defaults
        ))
        AtriaBLEManager.persistNormalWearHRVAnalysisAttemptDate(
            attempt,
            userDefaults: defaults
        )
        XCTAssertEqual(AtriaBLEManager.readNormalWearHRVAnalysisAttemptDate(
            userDefaults: defaults
        ), attempt)
        XCTAssertFalse(AtriaBLEManager.shouldAttemptHRVAnalysis(
            now: attempt.addingTimeInterval(60),
            lastReadyAnalysisAt: nil,
            lastAttemptAt: AtriaBLEManager.readNormalWearHRVAnalysisAttemptDate(
                userDefaults: defaults
            ),
            isRecording: false,
            hasReadySnapshot: false,
            cleanWindowSeconds: 300,
            foregroundInteractive: false
        ))
    }

    func testExplicitCaptureCadenceIgnoresPersistedNormalWearAttempt() {
        let captureAttempt = Date(timeIntervalSince1970: 58_000)

        XCTAssertFalse(AtriaBLEManager.shouldAttemptHRVAnalysis(
            now: captureAttempt.addingTimeInterval(1.499),
            lastReadyAnalysisAt: nil,
            lastAttemptAt: captureAttempt,
            isRecording: true,
            hasReadySnapshot: false,
            cleanWindowSeconds: 0,
            foregroundInteractive: true
        ))
        XCTAssertTrue(AtriaBLEManager.shouldAttemptHRVAnalysis(
            now: captureAttempt.addingTimeInterval(1.5),
            lastReadyAnalysisAt: nil,
            lastAttemptAt: captureAttempt,
            isRecording: true,
            hasReadySnapshot: false,
            cleanWindowSeconds: 0,
            foregroundInteractive: true
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

    func testNormalWearHRVCadenceRecoversFromClockRollback() {
        let now = Date(timeIntervalSince1970: 80_000)
        let futureMarker = now.addingTimeInterval(60 * 60)

        XCTAssertTrue(AtriaBLEManager.shouldRefreshHRVAnalysis(
            now: now,
            lastAnalysisAt: futureMarker,
            isRecording: false,
            foregroundInteractive: false
        ))
        XCTAssertTrue(AtriaBLEManager.shouldAttemptHRVAnalysis(
            now: now,
            lastReadyAnalysisAt: futureMarker,
            lastAttemptAt: futureMarker,
            isRecording: false,
            hasReadySnapshot: true,
            cleanWindowSeconds: 300,
            foregroundInteractive: false
        ))
    }

    func testLearningHRVRetryRecoversFromClockRollback() {
        let now = Date(timeIntervalSince1970: 90_000)
        let futureAttempt = now.addingTimeInterval(60 * 60)

        XCTAssertTrue(AtriaBLEManager.shouldAttemptHRVAnalysis(
            now: now,
            lastReadyAnalysisAt: nil,
            lastAttemptAt: futureAttempt,
            isRecording: false,
            hasReadySnapshot: false,
            cleanWindowSeconds: 300,
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
        XCTAssertTrue(source.contains("return [UUIDs.batteryLevel]"))
        XCTAssertFalse(source.contains("detail=protected_r10_minimal_no_battery_gatt"))
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
