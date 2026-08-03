import XCTest
@testable import Atria

final class AtriaBLEHistoricalRecoveryPolicyStructureTests: XCTestCase {
    func testEveryConnectedHistoryExitRestoresFreshLiveData() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let appDirectory = testsDirectory.deletingLastPathComponent().appendingPathComponent("Atria")
        let manager = try String(
            contentsOf: appDirectory.appendingPathComponent("AtriaBLEManager.swift"),
            encoding: .utf8
        )

        let finishStart = try XCTUnwrap(manager.range(
            of: "private func finishOfflineHistoricalSync("
        )?.lowerBound)
        let finishEnd = try XCTUnwrap(manager.range(
            of: "private func finalizeOfflineHistoricalSyncAfterLiveRestoration(",
            range: finishStart..<manager.endIndex
        )?.lowerBound)
        let finish = String(manager[finishStart..<finishEnd])

        XCTAssertFalse(
            finish.contains("guard completedDrain,"),
            "a timeout or empty post-workout offload must not bypass live restoration"
        )
        XCTAssertTrue(finish.contains("acceptedAt > restorationRequestedAt"))
        XCTAssertTrue(finish.contains("offline_sync_live_restore_rebuild_"))
        XCTAssertTrue(finish.contains("cancel_once_then_reconnect_known"))
        XCTAssertTrue(finish.contains(
            "restoreRealtimeAfterHistoryGeneration: generation"
        ), "the terminal rebuild must install a synchronous locked reconnect")
        XCTAssertTrue(
            finish.contains("terminalAndLiveRestored: completedDrain && restored"),
            "live restoration must not falsely promote an incomplete history drain"
        )
    }

    func testDurableAdmissionLedgerIsPreparedBeforeHistoryOwnerCutover() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let appDirectory = testsDirectory.deletingLastPathComponent().appendingPathComponent("Atria")
        let manager = try String(
            contentsOf: appDirectory.appendingPathComponent("AtriaBLEManager.swift"),
            encoding: .utf8
        )

        let preparationStart = try XCTUnwrap(manager.range(
            of: "private func prepareHistoricalAdmissionLedgerIfNeeded("
        )?.lowerBound)
        let preparationEnd = try XCTUnwrap(manager.range(
            of: "private func resumePendingForcedHistoricalSyncAfterLivePersistenceIfNeeded(",
            range: preparationStart..<manager.endIndex
        )?.lowerBound)
        let preparation = String(manager[preparationStart..<preparationEnd])
        XCTAssertTrue(preparation.contains("Task.detached("),
                      "legacy SQLite open/migration must not block CoreBluetooth's main queue")
        XCTAssertTrue(preparation.contains("keep_live_owner_open_sqlite_off_main"))
        XCTAssertTrue(preparation.contains(
            "resumePendingForcedHistoricalSyncAfterLivePersistenceIfNeeded("
        ))
        XCTAssertTrue(preparation.contains(
            "resumePendingFullDrainPublicationIfNeeded("
        ), "a restored terminal drain must resume after its admission ledger opens")
        XCTAssertTrue(preparation.contains("scheduleRangeLossBackfillIfNeeded("))

        let resumeStart = try XCTUnwrap(manager.range(
            of: "func resumePendingFullDrainPublicationIfNeeded("
        )?.lowerBound)
        let resumeEnd = try XCTUnwrap(manager.range(
            of: "private func scheduleTerminalConsumerMaterializationIfAuthorized(",
            range: resumeStart..<manager.endIndex
        )?.lowerBound)
        let resume = String(manager[resumeStart..<resumeEnd])
        XCTAssertTrue(resume.contains(
            "prepareHistoricalAdmissionLedgerIfNeeded("
        ), "terminal publication cannot start without durable admission identity")
        XCTAssertTrue(resume.contains("preparing_terminal_admission_ledger"))
        XCTAssertTrue(resume.contains(
            "shouldRunTerminalConsumerMaterialization("
        ), "background Bluetooth restoration must not start a full archive projection")
        XCTAssertTrue(resume.contains(
            "terminal_consumer_materialization_deferred_foreground"
        ))
        XCTAssertTrue(resume.contains(
            "action=preserve_live_wait_for_foreground"
        ))
        XCTAssertTrue(manager.contains(
            "action=retain_terminal_journal_preserve_live_no_ble_rearm"
        ), "terminal consumer publication must not reclaim BLE after a local projection failure")
        let materializationFinishStart = try XCTUnwrap(manager.range(
            of: "private func finishHistoricalConsumerMaterialization("
        )?.lowerBound)
        let materializationFinishEnd = try XCTUnwrap(manager.range(
            of: "private func schedulePendingConsumerFollowupScanMaterialization(",
            range: materializationFinishStart..<manager.endIndex
        )?.lowerBound)
        let materializationFinish = String(
            manager[materializationFinishStart..<materializationFinishEnd]
        )
        let terminalStop = try XCTUnwrap(materializationFinish.range(
            of: "action=retain_terminal_journal_preserve_live_no_ble_rearm"
        ))
        let transportRearm = try XCTUnwrap(materializationFinish.range(
            of: "reason: \"terminal_materialization_finished_\\(reason)\""
        ))
        XCTAssertLessThan(
            terminalStop.lowerBound,
            transportRearm.lowerBound,
            "the durable terminal-authority return must precede normal newer-gap transport scheduling"
        )

        let selectionStart = try XCTUnwrap(manager.range(
            of: "let persistedFullDrainAuthority = try?"
        )?.lowerBound)
        let selectionEnd = try XCTUnwrap(manager.range(
            of: "fullDrainTransportNonce =",
            range: selectionStart..<manager.endIndex
        )?.lowerBound)
        let selection = String(manager[selectionStart..<selectionEnd])
        XCTAssertFalse(selection.contains(
            "explicitRequest\n                    ? AtriaHistoricalGapLedger.oldestClosedRecoveryCandidate"
        ), "normal manual recovery must not ignore the newest user-visible gap")
        XCTAssertTrue(selection.contains(
            "selectedFullDrainGap = AtriaHistoricalGapLedger\n                    .newestClosedRecoveryCandidate()"
        ))

        let requestStart = try XCTUnwrap(manager.range(
            of: "func requestOfflineHistoricalSyncIfNeeded("
        )?.lowerBound)
        let requestEnd = try XCTUnwrap(manager.range(
            of: "private func armHistoryCapabilityQualification(",
            range: requestStart..<manager.endIndex
        )?.lowerBound)
        let request = String(manager[requestStart..<requestEnd])
        let readiness = try XCTUnwrap(request.range(
            of: "prepareHistoricalAdmissionLedgerIfNeeded(reason: reason)"
        ))
        let cutover = try XCTUnwrap(request.range(
            of: "beginFreshHistoryOwnerCutover(reason: reason)"
        ))
        XCTAssertLessThan(
            readiness.lowerBound,
            cutover.lowerBound,
            "the live owner must remain intact until durable admission authority is ready"
        )
        XCTAssertTrue(request.contains("preparing_durable_history_ledger"))
        XCTAssertTrue(request.contains("retainPendingOfflineHistoricalSyncRequest("))
        let terminalFence = try XCTUnwrap(request.range(
            of: "terminal_consumer_materialization"
        ))
        XCTAssertLessThan(
            terminalFence.lowerBound,
            readiness.lowerBound,
            "a terminal durable journal must be diverted to local publication before transport admission"
        )
        XCTAssertTrue(request.contains(
            "action=preserve_live_resume_local_publication"
        ))
    }

    func testTerminalConsumerMaterializationUsesForegroundCPUBudget() {
        XCTAssertTrue(AtriaBLEManager.shouldRunTerminalConsumerMaterialization(
            applicationIsActive: true
        ))
        XCTAssertFalse(AtriaBLEManager.shouldRunTerminalConsumerMaterialization(
            applicationIsActive: false
        ))
        XCTAssertTrue(SessionStore.shouldStartAutomaticArchiveProjection(
            applicationIsActive: true
        ))
        XCTAssertFalse(SessionStore.shouldStartAutomaticArchiveProjection(
            applicationIsActive: false
        ))
        XCTAssertTrue(AtriaBLEManager.shouldRunWorkoutMotionBankCoverageEvaluation(
            applicationIsActive: true
        ))
        XCTAssertFalse(AtriaBLEManager.shouldRunWorkoutMotionBankCoverageEvaluation(
            applicationIsActive: false
        ))
    }

    func testTerminalJournalDoesNotStarveDurableMotionBankOffload() {
        typealias Status =
            AtriaHistoricalFullDrainCoverageStore.Authority.Status
        typealias Disposition =
            AtriaBLEManager.TerminalHistoryRequestDisposition

        for status in [
            Status.historyComplete,
            .coverageProven,
            .gapResolvedConsumersPending,
            .consumersCommitted
        ] {
            XCTAssertEqual(
                AtriaBLEManager.terminalHistoryRequestDisposition(
                    authorityStatus: status,
                    explicitPostWorkoutBankRequest: false
                ),
                Disposition.resumeLocalPublicationAndReturn
            )
            XCTAssertEqual(
                AtriaBLEManager.terminalHistoryRequestDisposition(
                    authorityStatus: status,
                    explicitPostWorkoutBankRequest: true
                ),
                Disposition.resumeLocalPublicationAndContinueMotionBank
            )
        }

        for status in [Status.draining, .resolved] {
            XCTAssertEqual(
                AtriaBLEManager.terminalHistoryRequestDisposition(
                    authorityStatus: status,
                    explicitPostWorkoutBankRequest: false
                ),
                Disposition.continueNormally
            )
            XCTAssertEqual(
                AtriaBLEManager.terminalHistoryRequestDisposition(
                    authorityStatus: status,
                    explicitPostWorkoutBankRequest: true
                ),
                Disposition.continueNormally
            )
        }

        // P0a drain-keeping: a parked terminal-consumer-pending authority must
        // NOT block the range-loss RAW catch-up lane. Motion-bank keeps
        // precedence; range-loss raw drain passes through; otherwise blocked.
        for status in [
            Status.historyComplete,
            .coverageProven,
            .gapResolvedConsumersPending,
            .consumersCommitted
        ] {
            XCTAssertEqual(
                AtriaBLEManager.terminalHistoryRequestDisposition(
                    authorityStatus: status,
                    explicitPostWorkoutBankRequest: false,
                    rangeLossRawDrainPending: true
                ),
                Disposition.resumeLocalPublicationAndContinueRawDrain
            )
            // Motion-bank authorization keeps precedence over range-loss.
            XCTAssertEqual(
                AtriaBLEManager.terminalHistoryRequestDisposition(
                    authorityStatus: status,
                    explicitPostWorkoutBankRequest: true,
                    rangeLossRawDrainPending: true
                ),
                Disposition.resumeLocalPublicationAndContinueMotionBank
            )
            // Without either authorization the terminal journal still blocks.
            XCTAssertEqual(
                AtriaBLEManager.terminalHistoryRequestDisposition(
                    authorityStatus: status,
                    explicitPostWorkoutBankRequest: false,
                    rangeLossRawDrainPending: false
                ),
                Disposition.resumeLocalPublicationAndReturn
            )
        }

        // A draining/resolved authority is unaffected by the range-loss flag.
        for status in [Status.draining, .resolved] {
            XCTAssertEqual(
                AtriaBLEManager.terminalHistoryRequestDisposition(
                    authorityStatus: status,
                    explicitPostWorkoutBankRequest: false,
                    rangeLossRawDrainPending: true
                ),
                Disposition.continueNormally
            )
        }
    }

    func testConnectedRangeLossCatchUpIsGuardedButAllowedWhenSettled() {
        typealias State = AtriaBLEManager.ProtectedR10CleanOwnerState
        func allow(
            pending: Bool = true,
            state: State = .fallbackActive,
            storm: Bool = false,
            verified: Bool = true,
            workout: Bool = false,
            sync: Bool = false
        ) -> Bool {
            AtriaBLEManager.shouldAllowConnectedRangeLossCatchUp(
                rangeLossBackfillPending: pending,
                cleanOwnerState: state,
                recentDisconnectStorm: storm,
                verifiedHistoryCapability: verified,
                activeExplicitWorkout: workout,
                syncInProgress: sync
            )
        }
        // Settled owner + real backlog + no storm → connected catch-up allowed.
        XCTAssertTrue(allow(state: .fallbackActive))
        XCTAssertTrue(allow(state: .qualified))
        XCTAssertTrue(allow(state: .none))
        // Active proof/cutover genuinely owns the radio → never preempt.
        XCTAssertFalse(allow(state: .proving))
        XCTAssertFalse(allow(state: .protectedLaunchPending))
        XCTAssertFalse(allow(state: .fallbackPending))
        // Storm back-off, no backlog, active workout, or in-flight sync → refuse.
        XCTAssertFalse(allow(storm: true))
        XCTAssertFalse(allow(pending: false))
        XCTAssertFalse(allow(workout: true))
        XCTAssertFalse(allow(sync: true))
        XCTAssertFalse(allow(verified: false))
    }

    func testFlushMaintenanceWindowRelaxesGuardsOnlyWhenBackgroundedAndSettled() {
        typealias State = AtriaBLEManager.ProtectedR10CleanOwnerState
        func window(
            pending: Bool = true,
            foreground: Bool = false,
            state: State = .fallbackActive,
            workout: Bool = false,
            storm: Bool = false
        ) -> Bool {
            AtriaBLEManager.isFlushMaintenanceWindow(
                rangeLossBackfillPending: pending,
                foregroundInteractive: foreground,
                cleanOwnerState: state,
                activeExplicitWorkout: workout,
                recentDisconnectStorm: storm
            )
        }
        // Backgrounded + backlog + settled + no storm/workout → maintenance flush.
        XCTAssertTrue(window(state: .fallbackActive))
        XCTAssertTrue(window(state: .qualified))
        XCTAssertTrue(window(state: .none))
        // Foreground-interactive (user may be watching live HR) → never.
        XCTAssertFalse(window(foreground: true))
        // No backlog, active workout, storm back-off, or active proof → never.
        XCTAssertFalse(window(pending: false))
        XCTAssertFalse(window(workout: true))
        XCTAssertFalse(window(storm: true))
        XCTAssertFalse(window(state: .proving))
        XCTAssertFalse(window(state: .protectedLaunchPending))
        XCTAssertFalse(window(state: .fallbackPending))
    }

    func testMaintenanceTickerReArmsOnlyAfterTheNormalLoopHasGoneSilent() {
        let floor: TimeInterval = 120
        func rearm(
            pending: Bool = true,
            sync: Bool = false,
            connected: Bool = true,
            eligible: Bool = true,
            since: TimeInterval? = nil,
            floorOverride: TimeInterval = floor
        ) -> Bool {
            AtriaBLEManager.shouldReArmRangeLossBackfillOnMaintenanceTick(
                rangeLossBackfillPending: pending,
                syncInProgress: sync,
                linkConnected: connected,
                flushEligible: eligible,
                sinceLastReArm: since,
                reArmFloor: floorOverride
            )
        }
        // Never re-armed this backlog (nil) + eligible → the backstop re-arms now.
        XCTAssertTrue(rearm(since: nil))
        // Normal loop has been silent past the floor → HR-independent re-arm.
        XCTAssertTrue(rearm(since: floor))
        XCTAssertTrue(rearm(since: floor + 60))
        // A real re-arm within the floor keeps the ticker quiet (anti-churn).
        XCTAssertFalse(rearm(since: floor - 1))
        XCTAssertFalse(rearm(since: 0))
        // No backlog, an active drain, a dropped link, or an ineligible context
        // (foreground / storm / active proof, surfaced as flushEligible=false) all
        // refuse — never preempt a running drain or churn an unhealthy link.
        XCTAssertFalse(rearm(pending: false, since: floor + 60))
        XCTAssertFalse(rearm(sync: true, since: floor + 60))
        XCTAssertFalse(rearm(connected: false, since: floor + 60))
        XCTAssertFalse(rearm(eligible: false, since: floor + 60))
        // Degenerate floors and a non-finite elapsed reading fail closed.
        XCTAssertFalse(rearm(since: floor + 60, floorOverride: 0))
        XCTAssertFalse(rearm(since: floor + 60, floorOverride: .infinity))
        XCTAssertFalse(rearm(since: .infinity))
        XCTAssertFalse(rearm(since: .nan))
    }

    func testPhoneChargeEdgeResumesDrainOnlyOnRisingEdgeWithBacklog() {
        // Rising edge (unplugged → charging) with a backlog → resume.
        XCTAssertTrue(AtriaBLEManager.shouldResumeDrainOnPhoneChargeEdge(
            previousCharging: false, nowCharging: true, rangeLossBackfillPending: true
        ))
        // Already charging (level edge while plugged in) → do not re-trigger.
        XCTAssertFalse(AtriaBLEManager.shouldResumeDrainOnPhoneChargeEdge(
            previousCharging: true, nowCharging: true, rangeLossBackfillPending: true
        ))
        // Unplugging, or no backlog → never.
        XCTAssertFalse(AtriaBLEManager.shouldResumeDrainOnPhoneChargeEdge(
            previousCharging: true, nowCharging: false, rangeLossBackfillPending: true
        ))
        XCTAssertFalse(AtriaBLEManager.shouldResumeDrainOnPhoneChargeEdge(
            previousCharging: false, nowCharging: true, rangeLossBackfillPending: false
        ))
        // Charging classification includes .full (topped off, still on power).
        XCTAssertTrue(AtriaBLEManager.phoneStateIsCharging(.charging))
        XCTAssertTrue(AtriaBLEManager.phoneStateIsCharging(.full))
        XCTAssertFalse(AtriaBLEManager.phoneStateIsCharging(.unplugged))
        XCTAssertFalse(AtriaBLEManager.phoneStateIsCharging(.unknown))
    }

    func testTerminalProjectionFailureReleasesOnlyAuthorizedMotionBankRequest() {
        typealias Status =
            AtriaHistoricalFullDrainCoverageStore.Authority.Status
        typealias Disposition =
            AtriaBLEManager.TerminalMaterializationReleaseDisposition

        for status in [
            Status.historyComplete,
            .coverageProven,
            .gapResolvedConsumersPending,
            .consumersCommitted
        ] {
            XCTAssertEqual(
                AtriaBLEManager.terminalMaterializationReleaseDisposition(
                    wasInFlight: true,
                    rangeLossBackfillPending: true,
                    offlineHistoricalSyncInProgress: false,
                    authorityStatus: status,
                    hasPendingMotionBankRequest: false
                ),
                Disposition.retainTerminalJournal
            )
            XCTAssertEqual(
                AtriaBLEManager.terminalMaterializationReleaseDisposition(
                    wasInFlight: true,
                    rangeLossBackfillPending: true,
                    offlineHistoricalSyncInProgress: false,
                    authorityStatus: status,
                    hasPendingMotionBankRequest: true
                ),
                Disposition.resumePendingMotionBank
            )
        }

        XCTAssertEqual(
            AtriaBLEManager.terminalMaterializationReleaseDisposition(
                wasInFlight: true,
                rangeLossBackfillPending: true,
                offlineHistoricalSyncInProgress: false,
                authorityStatus: .draining,
                hasPendingMotionBankRequest: true
            ),
            Disposition.scheduleRangeLossBackfill
        )
        XCTAssertEqual(
            AtriaBLEManager.terminalMaterializationReleaseDisposition(
                wasInFlight: false,
                rangeLossBackfillPending: true,
                offlineHistoricalSyncInProgress: false,
                authorityStatus: .gapResolvedConsumersPending,
                hasPendingMotionBankRequest: true
            ),
            Disposition.noAction
        )
        XCTAssertEqual(
            AtriaBLEManager.terminalMaterializationReleaseDisposition(
                wasInFlight: true,
                rangeLossBackfillPending: true,
                offlineHistoricalSyncInProgress: true,
                authorityStatus: .gapResolvedConsumersPending,
                hasPendingMotionBankRequest: true
            ),
            Disposition.noAction
        )
    }

    func testReleasedMotionBankBypassesOnlyTheFailedLocalProjection() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        let appDirectory = testsDirectory.deletingLastPathComponent()
            .appendingPathComponent("Atria")
        let manager = try String(
            contentsOf: appDirectory.appendingPathComponent(
                "AtriaBLEManager.swift"
            ),
            encoding: .utf8
        )
        let finishStart = try XCTUnwrap(manager.range(
            of: "private func finishHistoricalConsumerMaterialization("
        )?.lowerBound)
        let finishEnd = try XCTUnwrap(manager.range(
            of: "private func schedulePendingConsumerFollowupScanMaterialization(",
            range: finishStart..<manager.endIndex
        )?.lowerBound)
        let finish = String(manager[finishStart..<finishEnd])

        XCTAssertTrue(finish.contains(
            "terminalMaterializationReleaseDisposition("
        ))
        XCTAssertTrue(finish.contains(
            "takePendingOfflineHistoricalSyncRequest()"
        ))
        XCTAssertTrue(finish.contains(
            "terminalMaterializationMotionBankReleaseInProgress = true"
        ))
        XCTAssertTrue(finish.contains(
            "release_authorized_motion_bank_no_local_projection_retry"
        ))
        XCTAssertTrue(finish.contains(
            "action=retain_terminal_journal_preserve_live_no_ble_rearm"
        ))
    }

    func testTerminalJournalMotionBankExceptionStaysInsideNormalAdmissionGates() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        let appDirectory = testsDirectory.deletingLastPathComponent()
            .appendingPathComponent("Atria")
        let manager = try String(
            contentsOf: appDirectory.appendingPathComponent(
                "AtriaBLEManager.swift"
            ),
            encoding: .utf8
        )
        let requestStart = try XCTUnwrap(manager.range(
            of: "func requestOfflineHistoricalSyncIfNeeded("
        )?.lowerBound)
        let requestEnd = try XCTUnwrap(manager.range(
            of: "private func armHistoryCapabilityQualification(",
            range: requestStart..<manager.endIndex
        )?.lowerBound)
        let request = String(manager[requestStart..<requestEnd])

        let terminalPassThrough = try XCTUnwrap(request.range(
            of: "terminal_publication_parallel_motion_bank"
        ))
        let thermalGate = try XCTUnwrap(request.range(
            of: "shouldDeferAutomaticOfflineSyncForThermalPressure"
        ))
        let transportAdmission = try XCTUnwrap(request.range(
            of: "beginFreshHistoryOwnerCutover(reason: reason)"
        ))
        XCTAssertLessThan(terminalPassThrough.lowerBound, thermalGate.lowerBound)
        XCTAssertLessThan(terminalPassThrough.lowerBound, transportAdmission.lowerBound)
        XCTAssertTrue(request.contains(
            "explicitPostWorkoutBankRequest: explicitPostWorkoutBankRequest"
        ))
        XCTAssertFalse(request.contains(
            "explicitUserRequest\n                ? .resumeLocalPublicationAndContinueMotionBank"
        ))
        XCTAssertFalse(request.contains(
            "explicitResearchRequest\n                ? .resumeLocalPublicationAndContinueMotionBank"
        ))
    }

    func testFreshOwnerCutoverCarriesMotionBankAuthorityAcrossDisconnect() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        let appDirectory = testsDirectory.deletingLastPathComponent()
            .appendingPathComponent("Atria")
        let manager = try String(
            contentsOf: appDirectory.appendingPathComponent(
                "AtriaBLEManager.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(manager.contains(
            "explicitPostWorkoutBankRequest:\n                    explicitPostWorkoutBankRequest"
        ))
        XCTAssertTrue(manager.contains(
            "explicitPostWorkoutBankRequest\n                    || transientMotionBankRequestAuthorization"
        ))
        XCTAssertTrue(manager.contains(
            "explicitPostWorkoutBankRequest:\n                            pending.explicitPostWorkoutBankRequest"
        ))
    }

    func testTerminalDependencyMismatchIsCachedBeforeTheGeneralArchiveFailure() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        let appDirectory = testsDirectory.deletingLastPathComponent()
            .appendingPathComponent("Atria")
        let manager = try String(
            contentsOf: appDirectory.appendingPathComponent(
                "AtriaBLEManager.swift"
            ),
            encoding: .utf8
        )
        let materializationStart = try XCTUnwrap(manager.range(
            of: "private func scheduleFullDrainConsumerMaterialization("
        )?.lowerBound)
        let materializationEnd = try XCTUnwrap(manager.range(
            of: "private func finishHistoricalConsumerMaterialization(",
            range: materializationStart..<manager.endIndex
        )?.lowerBound)
        let materialization = String(
            manager[materializationStart..<materializationEnd]
        )

        let mismatchCatch = try XCTUnwrap(materialization.range(
            of: "catch AtriaHistoricalConsumerProjectionCoordinator"
        ))
        let generalCatch = try XCTUnwrap(materialization.range(
            of: "} catch {",
            range: mismatchCatch.upperBound..<materialization.endIndex
        ))
        XCTAssertLessThan(mismatchCatch.lowerBound, generalCatch.lowerBound)
        XCTAssertTrue(materialization.contains(
            "CoordinatorError.pendingDependencyMismatch"
        ))
        XCTAssertTrue(materialization.contains(
            "terminalConsumerDependencyMismatchKey"
        ))
        XCTAssertTrue(materialization.contains(
            "terminalConsumerDependencyMismatchAtKey"
        ))
        XCTAssertTrue(materialization.contains(
            "terminal_dependency_model_mismatch"
        ))
        XCTAssertTrue(materialization.contains(
            "scheduleTerminalConsumerDependencyRetry()"
        ))
    }

    func testCachedTerminalDependencyMismatchReleasesArchiveLaneBeforeRescan() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        let appDirectory = testsDirectory.deletingLastPathComponent()
            .appendingPathComponent("Atria")
        let manager = try String(
            contentsOf: appDirectory.appendingPathComponent(
                "AtriaBLEManager.swift"
            ),
            encoding: .utf8
        )
        let resumeStart = try XCTUnwrap(manager.range(
            of: "func resumePendingFullDrainPublicationIfNeeded("
        )?.lowerBound)
        let resumeEnd = try XCTUnwrap(manager.range(
            of: "nonisolated static func shouldRunTerminalConsumerMaterialization(",
            range: resumeStart..<manager.endIndex
        )?.lowerBound)
        let resume = String(manager[resumeStart..<resumeEnd])

        let mismatchFingerprint = try XCTUnwrap(resume.range(
            of: "terminalConsumerDependencyFingerprint("
        ))
        let materialization = try XCTUnwrap(resume.range(
            of: "scheduleFullDrainConsumerMaterialization("
        ))
        XCTAssertLessThan(
            mismatchFingerprint.lowerBound,
            materialization.lowerBound
        )
        XCTAssertTrue(resume.contains(
            "pending_dependency_model_mismatch_cached"
        ))
        XCTAssertTrue(resume.contains(
            "terminal_consumer_dependency_incompatible"
        ))
    }

    func testTerminalDependencyMismatchBackoffExpiresAndModelChangesRetry() {
        let now = Date(timeIntervalSince1970: 10_000)

        XCTAssertTrue(
            AtriaBLEManager.shouldSuppressTerminalConsumerDependencyRetry(
                cachedFingerprint: "model-v2|gap",
                currentFingerprint: "model-v2|gap",
                cachedAt: now.addingTimeInterval(-60),
                now: now,
                retryInterval: 15 * 60
            )
        )
        XCTAssertFalse(
            AtriaBLEManager.shouldSuppressTerminalConsumerDependencyRetry(
                cachedFingerprint: "model-v2|gap",
                currentFingerprint: "model-v2|gap",
                cachedAt: now.addingTimeInterval(-(15 * 60)),
                now: now,
                retryInterval: 15 * 60
            ),
            "an unchanged durable terminal journal must get a bounded retry"
        )
        XCTAssertFalse(
            AtriaBLEManager.shouldSuppressTerminalConsumerDependencyRetry(
                cachedFingerprint: "model-v1|gap",
                currentFingerprint: "model-v2|gap",
                cachedAt: now,
                now: now,
                retryInterval: 15 * 60
            ),
            "a publication-model change must invalidate the old mismatch"
        )
        XCTAssertFalse(
            AtriaBLEManager.shouldSuppressTerminalConsumerDependencyRetry(
                cachedFingerprint: "model-v2|gap",
                currentFingerprint: "model-v2|gap",
                cachedAt: nil,
                now: now,
                retryInterval: 15 * 60
            ),
            "legacy fingerprints without a bounded lease cannot block forever"
        )
    }

    func testUnchangedTerminalCoverageFailureSuppressesRepeatFullScan() throws {
        let first = try XCTUnwrap(
            terminalCoverageFailureFingerprint()
        )
        let same = try XCTUnwrap(
            terminalCoverageFailureFingerprint()
        )

        XCTAssertEqual(first, same)
        XCTAssertTrue(
            AtriaBLEManager
                .shouldSuppressUnchangedTerminalConsumerCoverageFailure(
                    cachedFingerprint: first,
                    currentFingerprint: same
                )
        )
        // This deterministic failure has no time-based expiry: elapsed wall
        // time cannot change immutable terminal/archive authority.
        XCTAssertTrue(
            AtriaBLEManager
                .shouldSuppressUnchangedTerminalConsumerCoverageFailure(
                    cachedFingerprint: first,
                    currentFingerprint: same
                )
        )
        XCTAssertFalse(
            AtriaBLEManager
                .shouldSuppressUnchangedTerminalConsumerCoverageFailure(
                    cachedFingerprint: nil,
                    currentFingerprint: same
                ),
            "missing durable failure identity must fail open"
        )
    }

    func testChangedCatalogCoverageFailureRetriesAtMostDaily() {
        // Physical 2026-07-31: background drains advance the catalog identity
        // continuously; each fingerprint change re-armed the doomed archive
        // projection in the foreground until the frontmost app hit its 3.4 GB
        // jetsam limit. A changed catalog within 24h of the last identical
        // failure stays suppressed; the daily window (failure timestamp
        // refreshes on each failure) and the projection-model escape remain.
        let now = Date(timeIntervalSince1970: 2_000_000)
        XCTAssertTrue(
            AtriaBLEManager
                .shouldSuppressUnchangedTerminalConsumerCoverageFailure(
                    cachedFingerprint: "catalog-a",
                    currentFingerprint: "catalog-b",
                    cachedAt: now.addingTimeInterval(-60 * 60),
                    now: now
                ),
            "a catalog change one hour after an identical failure must not re-run the projection"
        )
        XCTAssertFalse(
            AtriaBLEManager
                .shouldSuppressUnchangedTerminalConsumerCoverageFailure(
                    cachedFingerprint: "catalog-a",
                    currentFingerprint: "catalog-b",
                    cachedAt: now.addingTimeInterval(-25 * 60 * 60),
                    now: now
                ),
            "after the daily window one bounded retry is allowed"
        )
        XCTAssertFalse(
            AtriaBLEManager
                .shouldSuppressUnchangedTerminalConsumerCoverageFailure(
                    cachedFingerprint: "catalog-a",
                    currentFingerprint: "catalog-b",
                    cachedAt: nil,
                    now: now
                ),
            "no failure timestamp keeps the pre-aging behavior: changed catalog retries"
        )
    }

    func testTerminalCoverageFailureRetriesForChangedCatalogFullScanOrModel() throws {
        let original = try XCTUnwrap(
            terminalCoverageFailureFingerprint()
        )
        let changedCatalog = try XCTUnwrap(
            terminalCoverageFailureFingerprint(
                currentCatalogFingerprint: "catalog-v2"
            )
        )
        let changedFullScan = try XCTUnwrap(
            terminalCoverageFailureFingerprint(
                fullScanGeneration: 8
            )
        )
        let changedCursor = try XCTUnwrap(
            terminalCoverageFailureFingerprint(
                cursorWatermark: Date(timeIntervalSince1970: 2_100)
            )
        )
        let changedModel = try XCTUnwrap(
            terminalCoverageFailureFingerprint(
                dependencyFingerprint: "projection-model-v3"
            )
        )

        for changed in [
            changedCatalog,
            changedFullScan,
            changedCursor,
            changedModel,
        ] {
            XCTAssertNotEqual(original, changed)
            XCTAssertFalse(
                AtriaBLEManager
                    .shouldSuppressUnchangedTerminalConsumerCoverageFailure(
                        cachedFingerprint: original,
                        currentFingerprint: changed
                    )
            )
        }
    }

    func testPersistedCompletionMismatchDiagnosticSeedsWithoutFirstRescan() {
        XCTAssertTrue(
            AtriaBLEManager
                .shouldSeedTerminalConsumerCoverageFailureFromDiagnostic(
                    cachedFingerprint: nil,
                    currentFingerprint: "current-terminal-snapshot",
                    persistedFailureDiagnostic:
                        "AtriaHistoricalActivityInspectionProofFactory.FactoryError.completionCoverageMismatch"
                )
        )
        XCTAssertFalse(
            AtriaBLEManager
                .shouldSeedTerminalConsumerCoverageFailureFromDiagnostic(
                    cachedFingerprint: "already-seeded",
                    currentFingerprint: "current-terminal-snapshot",
                    persistedFailureDiagnostic:
                        "AtriaHistoricalActivityInspectionProofFactory.FactoryError.completionCoverageMismatch"
                )
        )
        XCTAssertFalse(
            AtriaBLEManager
                .shouldSeedTerminalConsumerCoverageFailureFromDiagnostic(
                    cachedFingerprint: nil,
                    currentFingerprint: "current-terminal-snapshot",
                    persistedFailureDiagnostic: "transientIOFailure"
                )
        )
    }

    func testCompletionCoverageMismatchIsCachedBeforeGenericTerminalFailure() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        let appDirectory = testsDirectory.deletingLastPathComponent()
            .appendingPathComponent("Atria")
        let manager = try String(
            contentsOf: appDirectory.appendingPathComponent(
                "AtriaBLEManager.swift"
            ),
            encoding: .utf8
        )
        let materializationStart = try XCTUnwrap(manager.range(
            of: "private func scheduleFullDrainConsumerMaterialization("
        )?.lowerBound)
        let materializationEnd = try XCTUnwrap(manager.range(
            of: "private func finishHistoricalConsumerMaterialization(",
            range: materializationStart..<manager.endIndex
        )?.lowerBound)
        let materialization = String(
            manager[materializationStart..<materializationEnd]
        )
        let typedCatch = try XCTUnwrap(materialization.range(
            of: "FactoryError.completionCoverageMismatch"
        ))
        let genericCatch = try XCTUnwrap(materialization.range(
            of: "} catch {\n                UserDefaults.standard.set(",
            options: .backwards
        ))

        XCTAssertLessThan(typedCatch.lowerBound, genericCatch.lowerBound)
        XCTAssertTrue(materialization.contains(
            "terminalConsumerCoverageFailureFingerprint("
        ))
        XCTAssertTrue(materialization.contains(
            "cache_unchanged_terminal_snapshot_release_archive_lane"
        ))

        let resumeStart = try XCTUnwrap(manager.range(
            of: "func resumePendingFullDrainPublicationIfNeeded("
        )?.lowerBound)
        let resumeEnd = try XCTUnwrap(manager.range(
            of: "nonisolated static func shouldRunTerminalConsumerMaterialization(",
            range: resumeStart..<manager.endIndex
        )?.lowerBound)
        let resume = String(manager[resumeStart..<resumeEnd])
        let suppression = try XCTUnwrap(resume.range(
            of: "shouldSuppressUnchangedTerminalConsumerCoverageFailure("
        ))
        let fullScan = try XCTUnwrap(resume.range(
            of: "scheduleFullDrainConsumerMaterialization("
        ))
        XCTAssertLessThan(suppression.lowerBound, fullScan.lowerBound)
        XCTAssertTrue(resume.contains(
            "shouldSeedTerminalConsumerCoverageFailureFromDiagnostic("
        ))
        XCTAssertTrue(resume.contains(
            "seed_unchanged_terminal_snapshot_without_rescan"
        ))
        XCTAssertTrue(resume.contains(
            "skip_full_archive_rescan"
        ))
    }

    private func terminalCoverageFailureFingerprint(
        dependencyFingerprint: String = "projection-model-v2",
        fullScanGeneration: UInt64 = 7,
        cursorWatermark: Date = Date(timeIntervalSince1970: 2_000),
        currentCatalogFingerprint: String = "catalog-v1"
    ) -> String? {
        AtriaBLEManager.terminalConsumerCoverageFailureFingerprint(
            dependencyFingerprint: dependencyFingerprint,
            fullScanVersion: 1,
            fullScanGeneration: fullScanGeneration,
            fullScanTransportGeneration: 6,
            sourceChunkID: "source-chunk",
            sourceRawSHA256: String(repeating: "a", count: 64),
            observedArchiveFirstTimestamp:
                Date(timeIntervalSince1970: 1_000),
            cursorWatermark: cursorWatermark,
            catalogGeneration: 3,
            catalogSnapshotSHA256: String(repeating: "b", count: 64),
            aggregateSnapshotSHA256: String(repeating: "c", count: 64),
            currentCatalogFingerprint: currentCatalogFingerprint
        )
    }

    func testNoRowsFingerprintSuppressesOnlyAutomaticRetryForUnchangedGap() {
        let fingerprint = "gap-v1"

        XCTAssertTrue(AtriaBLEManager.shouldSuppressAutomaticHistoricalNoRowsRetry(
            exactGapPending: true,
            explicitUserRequest: false,
            currentGapFingerprint: fingerprint,
            noRowsGapFingerprint: fingerprint
        ))
        XCTAssertFalse(AtriaBLEManager.shouldSuppressAutomaticHistoricalNoRowsRetry(
            exactGapPending: true,
            explicitUserRequest: true,
            currentGapFingerprint: fingerprint,
            noRowsGapFingerprint: fingerprint
        ), "a deliberate retry must remain available")
        XCTAssertFalse(AtriaBLEManager.shouldSuppressAutomaticHistoricalNoRowsRetry(
            exactGapPending: true,
            explicitUserRequest: false,
            currentGapFingerprint: "gap-v2",
            noRowsGapFingerprint: fingerprint
        ), "a materially new closed gap must be eligible")
        XCTAssertFalse(AtriaBLEManager.shouldSuppressAutomaticHistoricalNoRowsRetry(
            exactGapPending: false,
            explicitUserRequest: false,
            currentGapFingerprint: fingerprint,
            noRowsGapFingerprint: fingerprint
        ))
        XCTAssertFalse(AtriaBLEManager.shouldSuppressAutomaticHistoricalNoRowsRetry(
            exactGapPending: true,
            explicitUserRequest: false,
            currentGapFingerprint: nil,
            noRowsGapFingerprint: fingerprint
        ))
    }

    func testHistoryStartTimeoutCircuitBreakerKeepsGapAndManualRepairAvailable() {
        let fingerprint = "gap-v1"

        XCTAssertTrue(AtriaBLEManager.shouldSuppressAutomaticHistoryStartTimeoutRetry(
            exactGapPending: true,
            explicitUserRequest: false,
            currentGapFingerprint: fingerprint,
            historyStartTimeoutGapFingerprint: fingerprint
        ))
        XCTAssertFalse(AtriaBLEManager.shouldSuppressAutomaticHistoryStartTimeoutRetry(
            exactGapPending: true,
            explicitUserRequest: true,
            currentGapFingerprint: fingerprint,
            historyStartTimeoutGapFingerprint: fingerprint
        ), "manual repair must remain available after an automatic timeout")
        XCTAssertFalse(AtriaBLEManager.shouldSuppressAutomaticHistoryStartTimeoutRetry(
            exactGapPending: true,
            explicitUserRequest: false,
            currentGapFingerprint: "gap-v2",
            historyStartTimeoutGapFingerprint: fingerprint
        ), "a new durable gap must get a fresh automatic opportunity")
        XCTAssertFalse(AtriaBLEManager.shouldSuppressAutomaticHistoryStartTimeoutRetry(
            exactGapPending: false,
            explicitUserRequest: false,
            currentGapFingerprint: fingerprint,
            historyStartTimeoutGapFingerprint: fingerprint
        ))
    }

    func testTimeoutCircuitMigrationRequiresOneConfirmedHistoryOwnerEpoch() {
        XCTAssertTrue(AtriaBLEManager.shouldMigrateHistoryStartTimeoutCircuitBreaker(
            lastAppCancelReason: "history_start_timeout_transport_reset",
            lastAppCancelAtUnix: 1_120,
            handshakeStatus: "full_drain_write_confirmed",
            handshakeAtUnix: 1_045,
            backfillStartedAtUnix: 1_000,
            newestClosedGapEndUnix: 999
        ))

        XCTAssertFalse(AtriaBLEManager.shouldMigrateHistoryStartTimeoutCircuitBreaker(
            lastAppCancelReason: "user_requested",
            lastAppCancelAtUnix: 1_120,
            handshakeStatus: "full_drain_write_confirmed",
            handshakeAtUnix: 1_045,
            backfillStartedAtUnix: 1_000,
            newestClosedGapEndUnix: 999
        ), "an unrelated app cancellation cannot seed the circuit breaker")
        XCTAssertFalse(AtriaBLEManager.shouldMigrateHistoryStartTimeoutCircuitBreaker(
            lastAppCancelReason: "history_start_timeout_transport_reset",
            lastAppCancelAtUnix: 1_120,
            handshakeStatus: "bond_write_confirmed",
            handshakeAtUnix: 1_045,
            backfillStartedAtUnix: 1_000,
            newestClosedGapEndUnix: 999
        ), "the full-drain write must be confirmed")
        XCTAssertFalse(AtriaBLEManager.shouldMigrateHistoryStartTimeoutCircuitBreaker(
            lastAppCancelReason: "history_start_timeout_transport_reset",
            lastAppCancelAtUnix: 1_120,
            handshakeStatus: "full_drain_write_confirmed",
            handshakeAtUnix: 1_045,
            backfillStartedAtUnix: 1_000,
            newestClosedGapEndUnix: 1_060
        ), "a newer closed gap needs its own automatic recovery opportunity")
        XCTAssertFalse(AtriaBLEManager.shouldMigrateHistoryStartTimeoutCircuitBreaker(
            lastAppCancelReason: "history_start_timeout_transport_reset",
            lastAppCancelAtUnix: 1_400,
            handshakeStatus: "full_drain_write_confirmed",
            handshakeAtUnix: 1_045,
            backfillStartedAtUnix: 1_000,
            newestClosedGapEndUnix: 999
        ), "the cancellation must be inside the same bounded history epoch")
    }

    func testNoRowsRecoveryIsDurablyScopedToTheAdmittedGapAndNeverBlocksManualRetry() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let appDirectory = testsDirectory.deletingLastPathComponent().appendingPathComponent("Atria")
        let manager = try String(
            contentsOf: appDirectory.appendingPathComponent("AtriaBLEManager.swift"),
            encoding: .utf8
        )

        let requestStart = try XCTUnwrap(manager.range(
            of: "func requestOfflineHistoricalSyncIfNeeded("
        )?.lowerBound)
        let requestEnd = try XCTUnwrap(manager.range(
            of: "private func armHistoryCapabilityQualification(",
            range: requestStart..<manager.endIndex
        )?.lowerBound)
        let request = String(manager[requestStart..<requestEnd])
        XCTAssertTrue(request.contains("shouldSuppressAutomaticHistoricalNoRowsRetry("))
        XCTAssertTrue(request.contains("explicitUserRequest: explicitHistoricalRequest"))
        XCTAssertTrue(request.contains("no_rows_gap_retained"))
        XCTAssertTrue(request.contains("action=suppress_automatic_reentry_preserve_live_radio"))
        XCTAssertTrue(request.contains(
            "shouldSuppressAutomaticHistoryStartTimeoutRetry("
        ))
        XCTAssertTrue(request.contains("history_start_timeout_gap_retained"))
        XCTAssertTrue(request.contains("preserve_live_r10"))
        XCTAssertTrue(request.contains(
            "shouldMigrateHistoryStartTimeoutCircuitBreaker("
        ))
        XCTAssertTrue(request.contains("history_start_timeout_gap_migrated"))

        let finalizerStart = try XCTUnwrap(manager.range(
            of: "private func finalizeOfflineHistoricalSyncAfterLiveRestoration("
        )?.lowerBound)
        let finalizerEnd = try XCTUnwrap(manager.range(
            of: "private func interruptOfflineHistoricalSyncForTransportLoss(",
            range: finalizerStart..<manager.endIndex
        )?.lowerBound)
        let finalizer = String(manager[finalizerStart..<finalizerEnd])
        XCTAssertTrue(finalizer.contains("offlineHistoricalSyncReachedTerminal"))
        XCTAssertTrue(finalizer.contains("OfflineSyncDefaults.noRowsGapFingerprint"))
        // 2026-07-31: 0f30390c moved the no-rows reentry guard into the typed
        // policy below; pin the finalizer's use of it plus the policy's own
        // `!noRowsForDurableGap` term instead of the old inline literal.
        XCTAssertTrue(finalizer.contains(
            "Self.shouldRetryUnresolvedRangeLossAfterTerminal("
        ), "a no-rows result must not schedule an automatic reentry")
        XCTAssertTrue(finalizer.contains(
            "noRowsForDurableGap: noRowsForDurableGap"
        ), "the finalizer must feed the durable no-rows fact into the policy")
        XCTAssertTrue(manager.contains("&& !noRowsForDurableGap"),
                      "the retry policy itself must veto no-rows reentry")
        XCTAssertTrue(finalizer.contains(
            "OfflineSyncDefaults.historyStartTimeoutGapFingerprint"
        ), "successful coverage must release only the matching timeout circuit")
    }

    func testGate2ExactRequestReconcilesOnlyStaleDrainingAuthorityBeforeConflictGate() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let appDirectory = testsDirectory.deletingLastPathComponent().appendingPathComponent("Atria")
        let manager = try String(
            contentsOf: appDirectory.appendingPathComponent("AtriaBLEManager.swift"),
            encoding: .utf8
        )

        let helperStart = try XCTUnwrap(manager.range(
            of: "private func reconcileStaleDrainingFullDrainAuthority("
        )?.lowerBound)
        let requestStart = try XCTUnwrap(manager.range(
            of: "func requestOfflineHistoricalSyncIfNeeded("
        )?.lowerBound)
        let helper = String(manager[helperStart..<requestStart])
        XCTAssertTrue(helper.contains("authority.status == .draining"))
        XCTAssertTrue(helper.contains("recoveryCandidate("))
        XCTAssertTrue(helper.contains("== nil"))
        XCTAssertTrue(helper.contains("clearUnresolvedAuthorityIfGapNoLongerPending("))
        XCTAssertTrue(helper.contains("abandonDrainingAuthorityIfGapFingerprintChanged("))

        let requestEnd = try XCTUnwrap(manager.range(
            of: "private func armHistoryCapabilityQualification(",
            range: requestStart..<manager.endIndex
        )?.lowerBound)
        let request = String(manager[requestStart..<requestEnd])
        let reconcile = try XCTUnwrap(request.range(
            of: "reconcileStaleDrainingFullDrainAuthority("
        )?.lowerBound)
        let conflict = try XCTUnwrap(request.range(
            of: "reason=other_drain_authority"
        )?.lowerBound)
        XCTAssertLessThan(
            reconcile,
            conflict,
            "a retired exact authority must be cleared before it can reject the new gap"
        )
        let attendedRelease = try XCTUnwrap(request.range(
            of: "status=previous_authority_released"
        )?.lowerBound)
        XCTAssertLessThan(
            attendedRelease,
            conflict,
            "an attended exact-gap proof must release only an interrupted competing transport owner before rejecting the selected target"
        )
        XCTAssertTrue(request.contains(
            "releaseInterruptedDrainingAuthorityWhenResumeDisabled("
        ))
        XCTAssertTrue(request.contains(
            "action=preserve_previous_gap_and_rows_run_selected_exact_gap"
        ))
    }

    func testDurableHistoryACKActuallyArmsBoundedPageContinuation() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let appDirectory = testsDirectory.deletingLastPathComponent().appendingPathComponent("Atria")
        let manager = try String(
            contentsOf: appDirectory.appendingPathComponent("AtriaBLEManager.swift"),
            encoding: .utf8
        )

        let acceptedStart = try XCTUnwrap(manager.range(
            of: "ATRIADBG historyAck status=accepted"
        )?.lowerBound)
        let acceptedEnd = try XCTUnwrap(manager.range(
            of: "private func reackDurableHistoricalReplay(",
            range: acceptedStart..<manager.endIndex
        )?.lowerBound)
        let accepted = String(manager[acceptedStart..<acceptedEnd])
        XCTAssertTrue(accepted.contains(
            "armHistoricalPageContinuationAfterACK("
        ))
        XCTAssertTrue(accepted.contains(
            "generation: ackIdentity.generation"
        ))
        XCTAssertTrue(accepted.contains(
            "boundaryID: ackIdentity.boundaryID"
        ))

        let replayStart = acceptedEnd
        let replayEnd = try XCTUnwrap(manager.range(
            of: "private func armHistoricalPageContinuationAfterACK(",
            range: replayStart..<manager.endIndex
        )?.lowerBound)
        let replay = String(manager[replayStart..<replayEnd])
        XCTAssertTrue(replay.contains("if result == .confirmed"))
        XCTAssertTrue(replay.contains(
            "historicalPageContinuationReplayBackoffStep + 1"
        ))
        XCTAssertTrue(replay.contains(
            "armHistoricalPageContinuationAfterACK("
        ))
    }

    func testInFlightOrphanReplayRetainsConsumedExactRequest() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let appDirectory = testsDirectory.deletingLastPathComponent().appendingPathComponent("Atria")
        let manager = try String(
            contentsOf: appDirectory.appendingPathComponent("AtriaBLEManager.swift"),
            encoding: .utf8
        )
        let helperStart = try XCTUnwrap(manager.range(
            of: "private func archiveOrphanHistoricalIngressIfNeeded("
        )?.lowerBound)
        let helperEnd = try XCTUnwrap(manager.range(
            of: "private func noteOfflineHistoricalSyncProgress(",
            range: helperStart..<manager.endIndex
        )?.lowerBound)
        let helper = String(manager[helperStart..<helperEnd])
        let inFlight = try XCTUnwrap(helper.range(
            of: "if orphanHistoricalIngressArchiveInFlight"
        )?.lowerBound)
        let retain = try XCTUnwrap(helper.range(
            of: "retainPendingOfflineHistoricalSyncRequest(",
            range: inFlight..<helper.endIndex
        )?.lowerBound)
        let returnTrue = try XCTUnwrap(helper.range(
            of: "return true",
            range: retain..<helper.endIndex
        )?.lowerBound)
        XCTAssertLessThan(inFlight, retain)
        XCTAssertLessThan(retain, returnTrue)
        XCTAssertTrue(helper.contains(
            "status=replay_in_flight_request_retained"
        ))
        XCTAssertTrue(helper.contains(
            "action=resume_after_orphan_retirement"
        ))
    }

    func testHistoryArmCannotCancelOrMutateBeforeRealtimeReconnectFence() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let appDirectory = testsDirectory.deletingLastPathComponent().appendingPathComponent("Atria")
        let manager = try String(
            contentsOf: appDirectory.appendingPathComponent("AtriaBLEManager.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(manager.contains("offline_sync_force_while_connecting"))

        let startMarker = "private func startOfflineHistoricalSync(reason: String,\n                                            force: Bool,\n                                            explicitRequest: Bool,\n                                            connectedChunkedBackfill: Bool,"
        let endMarker = "private func noteOfflineHistoricalSyncProgress("
        guard let start = manager.range(of: startMarker)?.lowerBound,
              let end = manager.range(of: endMarker, range: start..<manager.endIndex)?.lowerBound else {
            return XCTFail("expected bounded history-arm implementation")
        }
        let body = String(manager[start..<end])
        let fence = try XCTUnwrap(body.range(of: "guard peripheral?.state != .connecting")?.lowerBound)
        let attempts = try XCTUnwrap(body.range(of: "OfflineSyncDefaults.attempts")?.lowerBound)
        let lease = try XCTUnwrap(body.range(of: "beginOfflineHistoricalSyncBackgroundLease")?.lowerBound)
        XCTAssertLessThan(fence, attempts, "reconnect fence must precede attempt mutation")
        XCTAssertLessThan(fence, lease, "reconnect fence must precede background lease acquisition")
        XCTAssertFalse(body.contains("cancelPeripheralConnection"),
                       "history arm must never cancel a reconnecting realtime transport")
        XCTAssertTrue(body.contains("action=no_attempt_no_lease_no_cancel"))
        XCTAssertTrue(body.contains("action=unwind_no_cancel"))
    }

    func testEveryConnectedHistoryExitReassertsStandardHRBeforeOptionalRealtimeArm() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let appDirectory = testsDirectory.deletingLastPathComponent().appendingPathComponent("Atria")
        let manager = try String(
            contentsOf: appDirectory.appendingPathComponent("AtriaBLEManager.swift"),
            encoding: .utf8
        )

        let startMarker = "private func finishOfflineHistoricalSync("
        let endMarker = "private func interruptOfflineHistoricalSyncForTransportLoss("
        guard let start = manager.range(of: startMarker)?.lowerBound,
              let end = manager.range(of: endMarker, range: start..<manager.endIndex)?.lowerBound else {
            return XCTFail("expected bounded history completion implementation")
        }
        let body = String(manager[start..<end])
        let connectedExit = try XCTUnwrap(
            body.range(of: "if peripheral?.state == .connected")?.lowerBound
        )
        let hrRestore = try XCTUnwrap(
            body.range(of: "reassertHeartRateNotificationsIfConnected(")?.lowerBound
        )
        let proprietaryRestore = try XCTUnwrap(body.range(of: "armRealtime()")?.lowerBound)

        XCTAssertLessThan(connectedExit, hrRestore)
        XCTAssertLessThan(hrRestore, proprietaryRestore,
                          "standard 2A37 must be restored before optional proprietary realtime")
    }

    func testHistoryIdleTimeoutRebuildsConnectedTransportWithoutACKOrAbort() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let appDirectory = testsDirectory.deletingLastPathComponent().appendingPathComponent("Atria")
        let manager = try String(
            contentsOf: appDirectory.appendingPathComponent("AtriaBLEManager.swift"),
            encoding: .utf8
        )

        let start = try XCTUnwrap(
            manager.range(of: "private func armOfflineHistoricalSyncIdleWatchdog(")?.lowerBound
        )
        let end = try XCTUnwrap(
            manager.range(
                of: "private func bindExactHistoricalRequestAuthorityIfAvailable(",
                range: start..<manager.endIndex
            )?.lowerBound
        )
        let watchdog = String(manager[start..<end])
        let connectedFence = try XCTUnwrap(
            watchdog.range(of: "stalledPeripheral.state == .connected")?.lowerBound
        )
        let disconnect = try XCTUnwrap(
            watchdog.range(of: "cancelPeripheralConnection(")?.lowerBound
        )
        let disconnectedFinish = try XCTUnwrap(
            watchdog.range(of: "finishOfflineHistoricalSync(")?.lowerBound
        )

        XCTAssertLessThan(connectedFence, disconnect)
        XCTAssertLessThan(disconnect, disconnectedFinish)
        XCTAssertTrue(watchdog.contains("disconnect_without_ack_or_abort_retain_durable_prefix"))
        XCTAssertFalse(watchdog.contains("sendCommand("))
        XCTAssertFalse(watchdog.contains("Cmd.historicalDataResult"))
        XCTAssertFalse(watchdog.contains("Cmd.abortHistoricalTransmits"))
        XCTAssertFalse(watchdog.contains("armRealtime()"))
    }

    func testEveryStartedHistoryNonterminalFailureRebuildsTransportWithoutACKOrAbort() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let appDirectory = testsDirectory.deletingLastPathComponent().appendingPathComponent("Atria")
        let manager = try String(
            contentsOf: appDirectory.appendingPathComponent("AtriaBLEManager.swift"),
            encoding: .utf8
        )

        let startTimeout = try XCTUnwrap(
            manager.range(of: "guard acceptedHistoryStartSequence != nil else {")
        )
        let startTimeoutEnd = try XCTUnwrap(
            manager.range(
                of: "historyServe status=history_start_confirmed",
                range: startTimeout.upperBound..<manager.endIndex
            )?.lowerBound
        )
        let startTimeoutBody = String(manager[startTimeout.lowerBound..<startTimeoutEnd])
        XCTAssertTrue(startTimeoutBody.contains("cancelPeripheralConnection("))
        XCTAssertTrue(startTimeoutBody.contains("interruptOfflineHistoricalSyncForTransportLoss("))
        XCTAssertFalse(startTimeoutBody.contains("finishOfflineHistoricalSync("))
        XCTAssertFalse(startTimeoutBody.contains("Cmd.historicalDataResult"))
        XCTAssertFalse(startTimeoutBody.contains("Cmd.abortHistoricalTransmits"))

        let effectProcessor = try XCTUnwrap(
            manager.range(of: "private func processHistoricalDrainEffects(")?.lowerBound
        )
        let processorEnd = try XCTUnwrap(
            manager.range(
                of: "private func scheduleHistorySequenceConfirmationRetry(",
                range: effectProcessor..<manager.endIndex
            )?.lowerBound
        )
        let processor = String(manager[effectProcessor..<processorEnd])
        let failed = try XCTUnwrap(processor.range(of: "case .failed(let generation, let failure):"))
        let failedBody = String(processor[failed.lowerBound...])
        let disconnect = try XCTUnwrap(
            failedBody.range(of: "cancelPeripheralConnection(")?.lowerBound
        )
        let disconnectedFinish = try XCTUnwrap(
            failedBody.range(of: "finishOfflineHistoricalSync(")?.lowerBound
        )
        XCTAssertLessThan(disconnect, disconnectedFinish)
        XCTAssertTrue(failedBody.contains("rebuild_link_without_ack_or_abort_retain_gap"))
        XCTAssertFalse(failedBody.contains("Cmd.historicalDataResult"))
        XCTAssertFalse(failedBody.contains("Cmd.abortHistoricalTransmits"))
        XCTAssertFalse(failedBody.contains("armRealtime()"))
    }

    func testHistoryCompletionAndPublicationRemainBehindFreshHRBarrier() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let appDirectory = testsDirectory.deletingLastPathComponent().appendingPathComponent("Atria")
        let manager = try String(
            contentsOf: appDirectory.appendingPathComponent("AtriaBLEManager.swift"),
            encoding: .utf8
        )
        let finishStart = try XCTUnwrap(
            manager.range(of: "private func finishOfflineHistoricalSync(")?.lowerBound
        )
        let finalizerStart = try XCTUnwrap(
            manager.range(
                of: "private func finalizeOfflineHistoricalSyncAfterLiveRestoration(",
                range: finishStart..<manager.endIndex
            )?.lowerBound
        )
        let interruptStart = try XCTUnwrap(
            manager.range(
                of: "private func interruptOfflineHistoricalSyncForTransportLoss(",
                range: finalizerStart..<manager.endIndex
            )?.lowerBound
        )
        let finish = String(manager[finishStart..<finalizerStart])
        let finalizer = String(manager[finalizerStart..<interruptStart])

        XCTAssertTrue(finish.contains("acceptedAt > restorationRequestedAt"))
        XCTAssertTrue(finish.contains(
            "bleCallbackEpochFence.epoch == restorationEpoch"
        ))
        XCTAssertTrue(finish.contains("samePeripheral"))
        XCTAssertFalse(finish.contains("reconcileRangeLossBackfillPendingWithArchive("))
        XCTAssertTrue(finalizer.contains("let rangeLossResolved = terminalAndLiveRestored\n            && reconcileRangeLossBackfillPendingWithArchive("))
        XCTAssertTrue(finalizer.contains("if terminalAndLiveRestored && offlineHistoricalSyncReachedTerminal"))
        XCTAssertTrue(finalizer.contains("scheduleFullDrainConsumerMaterialization(transportGeneration: generation)"))
        XCTAssertTrue(finalizer.contains("lastCompletedHistoricalSyncReachedTerminal = terminalAndLiveRestored\n            && offlineHistoricalSyncReachedTerminal"))
        XCTAssertTrue(finalizer.contains("lastCompletedHistoricalSyncHasOnboardingAuthority = terminalAndLiveRestored\n            && onboardingTransportAuthority"))
    }

    func testHistoryOwnerSuppressesWorkoutMotionChurnAndFinalizerResumesLease() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let appDirectory = testsDirectory.deletingLastPathComponent().appendingPathComponent("Atria")
        let manager = try String(
            contentsOf: appDirectory.appendingPathComponent("AtriaBLEManager.swift"),
            encoding: .utf8
        )

        func body(from startMarker: String, to endMarker: String) throws -> String {
            let start = try XCTUnwrap(manager.range(of: startMarker)?.lowerBound)
            let end = try XCTUnwrap(
                manager.range(of: endMarker, range: start..<manager.endIndex)?.lowerBound
            )
            return String(manager[start..<end])
        }

        let start = try body(
            from: "private func startOfflineHistoricalSync(reason: String,\n                                            force: Bool,\n                                            explicitRequest: Bool,",
            to: "private func noteOfflineHistoricalSyncProgress("
        )
        let schedule = try body(
            from: "private func scheduleWorkoutMotionLeaseEvaluation(",
            to: "private func evaluateWorkoutMotionLease("
        )
        let evaluate = try body(
            from: "private func evaluateWorkoutMotionLease(",
            to: "private func sendWorkoutMotionActivationPair("
        )
        let activation = try body(
            from: "private func sendWorkoutMotionActivationPair(",
            to: "private func suspendWorkoutMotionLeaseForHistoricalSync("
        )
        let suspend = try body(
            from: "private func suspendWorkoutMotionLeaseForHistoricalSync(",
            to: "private func resumeWorkoutMotionLeaseAfterHistoricalSync("
        )
        let resume = try body(
            from: "private func resumeWorkoutMotionLeaseAfterHistoricalSync(",
            to: "private func recordWorkoutMotionFrameIfNeeded("
        )
        let finishStart = try XCTUnwrap(
            manager.range(of: "private func finalizeOfflineHistoricalSyncAfterLiveRestoration(")?.lowerBound
        )
        let finishEnd = try XCTUnwrap(
            manager.range(
                of: "private func interruptOfflineHistoricalSyncForTransportLoss(",
                range: finishStart..<manager.endIndex
            )?.lowerBound
        )
        let finalizer = String(manager[finishStart..<finishEnd])

        let ownership = try XCTUnwrap(start.range(
            of: "historyTransportPhaseFence.activate("
        ))
        let inProgress = try XCTUnwrap(start.range(
            of: "offlineHistoricalSyncInProgress = true",
            range: ownership.upperBound..<start.endIndex
        ))
        let suspension = try XCTUnwrap(start.range(
            of: "suspendWorkoutMotionLeaseForHistoricalSync()",
            range: inProgress.upperBound..<start.endIndex
        ))
        XCTAssertLessThan(ownership.lowerBound, inProgress.lowerBound)
        XCTAssertLessThan(inProgress.lowerBound, suspension.lowerBound)
        for guardedBody in [schedule, evaluate, activation] {
            XCTAssertTrue(
                guardedBody.contains("guard !historyOnlyProbeMode, !offlineHistoricalSyncInProgress else { return }"),
                "every workout-motion entry point must yield to the history owner"
            )
        }
        XCTAssertTrue(
            finalizer.contains("resumeWorkoutMotionLeaseAfterHistoricalSync("),
            "all history exits must re-arm through the common finalizer"
        )
        XCTAssertEqual(
            finalizer.components(separatedBy: "resumeWorkoutMotionLeaseAfterHistoricalSync(").count - 1,
            1,
            "the common finalizer must re-arm the lease once"
        )
        XCTAssertTrue(suspend.contains("workoutMotionActivationTask?.cancel()"))
        XCTAssertTrue(suspend.contains("workoutMotionCommandTask?.cancel()"))
        XCTAssertTrue(resume.contains("guard !historyOnlyProbeMode, !offlineHistoricalSyncInProgress else { return }"))
        XCTAssertTrue(resume.contains("scheduleWorkoutMotionLeaseEvaluation(reason: reason)"))
    }

    func testHistoryOwnerAlsoFencesHRFirstAndProtectedMotionDiscovery() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let appDirectory = testsDirectory.deletingLastPathComponent().appendingPathComponent("Atria")
        let manager = try String(
            contentsOf: appDirectory.appendingPathComponent("AtriaBLEManager.swift"),
            encoding: .utf8
        )

        let hrStart = try XCTUnwrap(
            manager.range(of: "private func beginHRFirstDenseBringUpIfNeeded(")?.lowerBound
        )
        let protectedStart = try XCTUnwrap(
            manager.range(
                of: "private func beginProtectedR10BringUpForCurrentEpoch(",
                range: hrStart..<manager.endIndex
            )?.lowerBound
        )
        let protectedEnd = try XCTUnwrap(
            manager.range(
                of: "private func beginProtectedR10LaunchConnectionCutoverIfNeeded(",
                range: protectedStart..<manager.endIndex
            )?.lowerBound
        )
        let hrBringUp = String(manager[hrStart..<protectedStart])
        let protectedBringUp = String(manager[protectedStart..<protectedEnd])

        for guardedBody in [hrBringUp, protectedBringUp] {
            XCTAssertTrue(guardedBody.contains("!historyOnlyProbeMode"))
            XCTAssertTrue(guardedBody.contains("!offlineHistoricalSyncInProgress"))
        }
    }

    func testHistoricalRecoveryPolicyIsExtractedAndRemainsPure() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let appDirectory = testsDirectory.deletingLastPathComponent().appendingPathComponent("Atria")
        let manager = try String(
            contentsOf: appDirectory.appendingPathComponent("AtriaBLEManager.swift"),
            encoding: .utf8
        )
        let policy = try String(
            contentsOf: appDirectory.appendingPathComponent("AtriaBLEHistoricalRecoveryPolicy.swift"),
            encoding: .utf8
        )

        let functionNames = [
            "supportsVerifiedHistoricalRecovery",
            "supportsDecodedHistoricalMetricLayout",
            "supportsVerifiedHistoricalTransactionRecovery",
            "shouldQualifyPendingHistoryByServiceDiscovery",
            "historicalSyncCompletionStatus",
            "shouldAttemptRawOnlyHistoricalRecovery",
            "historicalGapFingerprint",
            "shouldBindExactHistoricalRequestAuthority",
            "shouldScheduleStaleRangeLossReconciliation",
            "shouldDeferOfflineSyncForExplicitWorkout",
            "isExplicitUserOfflineSyncReason",
            "hasValidRangeLossBackfillRequest",
            "shouldAllowProtectedHistoricalRecovery",
            "shouldDeferAutomaticOfflineSyncForConnectedLink",
            "shouldUseFreshHistoryOwnerCutover",
            "shouldAttemptAutomaticConnectedHistoricalHandoff",
            "productionHistoricalRecoveryInitCommands",
            "permitsRawFullDrainForwardDiscontinuity",
            "shouldStopRealtimeBeforeHistoricalRecovery",
            "standardHROnlyModeAfterOfflineSync",
            "rangeLossBackfillCanClear",
            "requestedRecoveryRowProvidesMetricProgress",
            "shouldProtectConnectedLinkForOfflineSync",
        ]

        for name in functionNames {
            let declaration = "nonisolated static func \(name)("
            XCTAssertFalse(
                manager.contains(declaration),
                "AtriaBLEManager.swift must not regain the extracted \(name) policy"
            )
            XCTAssertTrue(
                policy.contains(declaration),
                "AtriaBLEHistoricalRecoveryPolicy.swift must own \(name)"
            )
        }

        let constantNames = [
            "productionHistoricalExactRangeTransportEnabledAndProven",
            "productionHistoricalClockAuthorityEnabledAndProven",
            "productionHistoricalFullDrainGapRecoveryEnabled",
        ]
        for name in constantNames {
            let declaration = "nonisolated static let \(name)"
            XCTAssertFalse(
                manager.contains(declaration),
                "AtriaBLEManager.swift must not regain the extracted \(name) policy"
            )
            XCTAssertTrue(
                policy.contains(declaration),
                "AtriaBLEHistoricalRecoveryPolicy.swift must own \(name)"
            )
        }

        XCTAssertEqual(
            policy.components(separatedBy: "nonisolated static func historicalGapFingerprint(").count - 1,
            2,
            "Both gap-identity overloads must stay in the policy extension"
        )
        XCTAssertEqual(
            policy.components(separatedBy: "nonisolated static func rangeLossBackfillCanClear(").count - 1,
            2,
            "Both fail-closed completion overloads must stay in the policy extension"
        )

        let statefulAPIs = [
            "import CoreBluetooth",
            "import UIKit",
            "@Published",
            "UserDefaults",
            "FileManager",
            "NotificationCenter",
            "DispatchQueue",
            "Task {",
            "Task.detached",
            "CBCentralManager",
            "CBPeripheral",
            "CBCharacteristic",
            "URLSession",
            "NSFileCoordinator",
            ".write(to:",
            ".set(",
            "removeObject(",
            "assignIfChanged(",
            "AtriaDebugLog(",
        ]
        for api in statefulAPIs {
            XCTAssertFalse(
                policy.contains(api),
                "Historical recovery policy must remain pure; found stateful API \(api)"
            )
        }

        let managerPolicy = String(policy[try XCTUnwrap(
            policy.range(of: "extension AtriaBLEManager {")?.lowerBound
        )...])
        let nonStaticDeclarations = managerPolicy
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter {
                $0.hasPrefix("func ")
                    || $0.hasPrefix("private func ")
                    || $0.hasPrefix("fileprivate func ")
                    || $0.hasPrefix("static func ")
            }
        XCTAssertTrue(
            nonStaticDeclarations.isEmpty,
            "Every extracted policy entry point must remain nonisolated static: \(nonStaticDeclarations)"
        )
    }

    func testFreshHistoryOwnerCutoverIsDurabilityGatedAndReusesDisconnectedPath() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let appDirectory = testsDirectory.deletingLastPathComponent().appendingPathComponent("Atria")
        let manager = try String(
            contentsOf: appDirectory.appendingPathComponent("AtriaBLEManager.swift"),
            encoding: .utf8
        )
        let begin = try XCTUnwrap(
            manager.range(of: "private func beginFreshHistoryOwnerCutover(")?.lowerBound
        )
        let end = try XCTUnwrap(
            manager.range(
                of: "/// Starts (or joins) a historical drain",
                range: begin..<manager.endIndex
            )?.lowerBound
        )
        let body = String(manager[begin..<end])
        let journalGate = try XCTUnwrap(
            body.range(of: "lastActiveJournalSavedSessionSampleCount")?.lowerBound
        )
        let stepGate = try XCTUnwrap(
            body.range(of: "lastStrapStepLedgerSavedRawSteps")?.lowerBound
        )
        let disconnect = try XCTUnwrap(
            body.range(of: "cancelPeripheralConnection(")?.lowerBound
        )
        XCTAssertLessThan(journalGate, disconnect)
        XCTAssertLessThan(stepGate, disconnect)
        XCTAssertTrue(body.contains("action=keep_live_link_retain_explicit_request_latch_no_packet_retry"))
        XCTAssertEqual(body.components(separatedBy: "cancelPeripheralConnection(").count - 1, 1)
        XCTAssertTrue(body.contains("let boundarySessionID = liveSessionID"))
        XCTAssertTrue(body.contains("let boundarySessionSampleCount = session.count"))
        XCTAssertTrue(body.contains("let boundaryRRCount = rrArchive.count"))
        XCTAssertTrue(body.contains(">= boundarySessionSampleCount"))
        XCTAssertTrue(body.contains(">= boundaryRRCount"))
        XCTAssertTrue(body.contains("self.liveSessionID == boundarySessionID"))
        XCTAssertFalse(body.contains(">= self.session.count"),
                       "continuous input must not move the fsync proof target")

        XCTAssertTrue(manager.contains("action=reuse_disconnected_history_path"))
        XCTAssertTrue(manager.contains("force: pending.force"))
        XCTAssertTrue(manager.contains("explicitResearchRequest: pending.explicitRequest"))
        XCTAssertTrue(manager.contains("!freshHistoryOwnerBoundaryFailureLatched"),
                      "accepted HR callbacks must not restart a failed boundary attempt")
    }

    func testFreshHistoryOwnerConnectionResumesArmedGenerationBeforeLiveDiscovery() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let appDirectory = testsDirectory.deletingLastPathComponent().appendingPathComponent("Atria")
        let manager = try String(
            contentsOf: appDirectory.appendingPathComponent("AtriaBLEManager.swift"),
            encoding: .utf8
        )
        let resumeStart = try XCTUnwrap(
            manager.range(of: "private func resumeFreshHistoryOwnerConnectionIfNeeded(")?.lowerBound
        )
        let resumeEnd = try XCTUnwrap(
            manager.range(
                of: "/// Starts (or joins) a historical drain",
                range: resumeStart..<manager.endIndex
            )?.lowerBound
        )
        let resume = String(manager[resumeStart..<resumeEnd])
        XCTAssertTrue(resume.contains("offlineHistoricalSyncGeneration == generation"))
        XCTAssertTrue(resume.contains("historyTransportPhaseFence.activate("))
        XCTAssertTrue(resume.contains("generation: generation"))
        XCTAssertTrue(resume.contains(
            "usesExplicitHistoryProfile: usesExplicitHistoryProfile"
        ))
        XCTAssertTrue(resume.contains("peripheral.discoverServices(Self.UUIDs.productionHistoryServices)"))
        XCTAssertTrue(resume.contains("commands=0"))
        XCTAssertFalse(resume.contains("sendCommand("))
        XCTAssertFalse(resume.contains("cancelPeripheralConnection("))

        let didConnectStart = try XCTUnwrap(
            manager.range(of: "didConnect peripheral: CBPeripheral")?.lowerBound
        )
        let didConnectEnd = try XCTUnwrap(
            manager.range(
                of: "didDisconnectPeripheral peripheral: CBPeripheral",
                range: didConnectStart..<manager.endIndex
            )?.lowerBound
        )
        let didConnect = String(manager[didConnectStart..<didConnectEnd])
        let historyResume = try XCTUnwrap(
            didConnect.range(of: "resumeFreshHistoryOwnerConnectionIfNeeded")?.lowerBound
        )
        let batteryRecovery = try XCTUnwrap(
            didConnect.range(of: "beginRetiredBatteryProbeRecoveryIfNeeded")?.lowerBound
        )
        XCTAssertLessThan(historyResume, batteryRecovery)

        XCTAssertTrue(manager.contains("|| freshHistoryOwnerCutoverPending"),
                      "the intentional cutover must not become official-app coexistence evidence")
        XCTAssertTrue(manager.contains("freshHistoryOwnerConnectionGeneration =\n                            self.offlineHistoricalSyncGeneration"))
    }

    func testFreshHistoryOwnerKeepsStandardHeartRateLiveWithoutExpandingHistoryPipe() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let appDirectory = testsDirectory.deletingLastPathComponent().appendingPathComponent("Atria")
        let manager = try String(
            contentsOf: appDirectory.appendingPathComponent("AtriaBLEManager.swift"),
            encoding: .utf8
        )

        XCTAssertEqual(AtriaBLEManager.UUIDs.productionHistoryServices, [
            AtriaBLEManager.UUIDs.strapService,
            AtriaBLEManager.UUIDs.heartRateService,
            AtriaBLEManager.UUIDs.batteryService,
        ])
        XCTAssertEqual(AtriaBLEManager.UUIDs.productionHistoryNotify, [
            AtriaBLEManager.UUIDs.strapRX,
            AtriaBLEManager.UUIDs.strapStream5,
        ], "standard HR continuity must not expand the proprietary history characteristic set")

        let servicesStart = try XCTUnwrap(manager.range(
            of: "nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?)"
        )?.lowerBound)
        let servicesEnd = try XCTUnwrap(manager.range(
            of: "didDiscoverCharacteristicsFor service: CBService",
            range: servicesStart..<manager.endIndex
        )?.lowerBound)
        let services = String(manager[servicesStart..<servicesEnd])
        let historyBranch = try XCTUnwrap(services.range(of: "} else if historyOnlyProbeMode {")?.lowerBound)
        let branch = String(services[historyBranch...])
        XCTAssertTrue(branch.contains("case Self.UUIDs.heartRateService:"))
        XCTAssertTrue(branch.contains("characteristics = [Self.UUIDs.heartRateMeasure]"))
        XCTAssertTrue(branch.contains("case Self.UUIDs.batteryService:"))
        XCTAssertTrue(branch.contains("characteristics = [Self.UUIDs.batteryLevel]"))
        XCTAssertTrue(branch.contains("[Self.UUIDs.strapTX] + requiredNotifications"))

        let valuesStart = try XCTUnwrap(manager.range(
            of: "didUpdateValueFor characteristic: CBCharacteristic"
        )?.lowerBound)
        let values = String(manager[valuesStart...])
        let heartRateReturn = try XCTUnwrap(values.range(of: "if uuid == UUIDs.heartRateMeasure")?.lowerBound)
        let batteryReturn = try XCTUnwrap(values.range(of: "if uuid == UUIDs.batteryLevel")?.lowerBound)
        let historyDecode = try XCTUnwrap(values.range(of: "if uuid == UUIDs.strapStream7")?.lowerBound)
        XCTAssertLessThan(heartRateReturn, batteryReturn)
        XCTAssertLessThan(heartRateReturn, historyDecode,
                          "2A37 must exit through standard HR ingestion before proprietary history decoding")

        let characteristicsStart = try XCTUnwrap(manager.range(
            of: "didDiscoverCharacteristicsFor service: CBService"
        )?.lowerBound)
        let characteristicsEnd = try XCTUnwrap(manager.range(
            of: "didWriteValueFor characteristic: CBCharacteristic",
            range: characteristicsStart..<manager.endIndex
        )?.lowerBound)
        let characteristics = String(manager[characteristicsStart..<characteristicsEnd])
        XCTAssertTrue(characteristics.contains("case UUIDs.heartRateMeasure, UUIDs.batteryLevel"))
        XCTAssertTrue(characteristics.contains("peripheral.setNotifyValue(true, for: ch)"),
                      "the discovered 2A37 must be enabled on the fresh history-owner link")
    }
}
