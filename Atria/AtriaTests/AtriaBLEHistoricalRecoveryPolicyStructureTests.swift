import XCTest
@testable import Atria

final class AtriaBLEHistoricalRecoveryPolicyStructureTests: XCTestCase {
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
        XCTAssertTrue(finalizer.contains("!noRowsForDurableGap"),
                      "a no-rows result must not schedule an automatic reentry")
        XCTAssertTrue(finalizer.contains(
            "OfflineSyncDefaults.historyStartTimeoutGapFingerprint"
        ), "successful coverage must release only the matching timeout circuit")
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
        XCTAssertTrue(finish.contains("sameEpoch"))
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

        XCTAssertTrue(start.contains("offlineHistoricalSyncInProgress = true\n        suspendWorkoutMotionLeaseForHistoricalSync()"))
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
        XCTAssertTrue(resume.contains("historyTransportPhaseFence.activate(generation: generation)"))
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
