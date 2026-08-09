import XCTest
import UIKit
@testable import Atria

final class AtriaBackgroundProjectionTests: XCTestCase {

    // MARK: Environmental guard (pure)

    private func guarded(thermal: ProcessInfo.ThermalState,
                         lowPower: Bool,
                         battery: UIDevice.BatteryState,
                         level: Float) -> Bool {
        SessionStore.shouldStartBackgroundArchiveProjection(
            thermalState: thermal,
            isLowPowerModeEnabled: lowPower,
            batteryState: battery,
            batteryLevel: level)
    }

    func testGuardAllowsWhenCoolChargingNotLowPower() {
        XCTAssertTrue(guarded(thermal: .nominal, lowPower: false, battery: .charging, level: 0.9))
        XCTAssertTrue(guarded(thermal: .fair, lowPower: false, battery: .charging, level: 0.9))
        XCTAssertTrue(guarded(thermal: .nominal, lowPower: false, battery: .full, level: 0.3),
                      "a 'full' battery state counts as charging")
    }

    func testGuardBlocksUnderHeat() {
        XCTAssertFalse(guarded(thermal: .serious, lowPower: false, battery: .charging, level: 0.9))
        XCTAssertFalse(guarded(thermal: .critical, lowPower: false, battery: .charging, level: 0.9))
    }

    func testGuardBlocksUnderLowPowerMode() {
        XCTAssertFalse(guarded(thermal: .nominal, lowPower: true, battery: .charging, level: 0.9))
    }

    func testGuardBatteryFallbackWhenUnplugged() {
        XCTAssertTrue(guarded(thermal: .nominal, lowPower: false, battery: .unplugged, level: 0.60))
        XCTAssertTrue(guarded(thermal: .nominal, lowPower: false, battery: .unplugged, level: 0.50),
                      "boundary is inclusive (>= 0.5)")
        XCTAssertFalse(guarded(thermal: .nominal, lowPower: false, battery: .unplugged, level: 0.40))
    }

    func testGuardFailsClosedOnUnknownBattery() {
        // UIDevice reports -1 when the level is unknown; must not start.
        XCTAssertFalse(guarded(thermal: .nominal, lowPower: false, battery: .unknown, level: -1.0))
    }

    // MARK: Foreground admission

    func testOrdinaryColdLaunchAndArchiveUpdatesUseSafeBackgroundLane() {
        for reason in [
            "deferred_session_load",
            "archive_did_update",
            "archive_did_update_after_history_finalizer",
        ] {
            XCTAssertTrue(
                SessionStore
                    .shouldReserveAutomaticRecoveredDataProjectionForSafeBackground(
                        reason: reason,
                        isExactRecoveryPublication: false,
                        backgroundProjectionAllowed: false
                    ),
                "\(reason) must reuse durable app-facing caches in foreground"
            )
        }
    }

    func testOnlyExactAndExplicitUserProjectionBypassOrdinaryReservation() {
        XCTAssertFalse(
            SessionStore
                .shouldReserveAutomaticRecoveredDataProjectionForSafeBackground(
                    reason: "archive_did_update",
                    isExactRecoveryPublication: true,
                    backgroundProjectionAllowed: false
                ),
            "terminal exact recovery retains its completion-fenced projection"
        )
        XCTAssertTrue(
            SessionStore
                .shouldReserveAutomaticRecoveredDataProjectionForSafeBackground(
                    reason: "deferred_session_load",
                    isExactRecoveryPublication: false,
                    backgroundProjectionAllowed: true
                ),
            "ordinary cold-load freshness cannot mint a background ticket"
        )
        XCTAssertFalse(
            SessionStore
                .shouldReserveAutomaticRecoveredDataProjectionForSafeBackground(
                    reason: "explicit_user_repair",
                    isExactRecoveryPublication: false,
                    backgroundProjectionAllowed: false
                )
        )
    }

    func testMetadataTailCannotMintAnOrdinaryProjectionTicket() {
        XCTAssertTrue(
            SessionStore
                .shouldReserveAutomaticRecoveredDataProjectionForSafeBackground(
                    reason: "archive_did_update",
                    isExactRecoveryPublication: false,
                    backgroundProjectionAllowed: false
                ),
            "even a small tail fans out into global derived consumers"
        )
        XCTAssertTrue(
            SessionStore
                .shouldReserveAutomaticRecoveredDataProjectionForSafeBackground(
                    reason: "deferred_session_load",
                    isExactRecoveryPublication: false,
                    backgroundProjectionAllowed: false
                ),
            "cold launch remains background-only even if a stale caller claims a tail"
        )
    }

    func testAutomaticArchiveWideMaintenanceFailsClosedInRelease() {
        XCTAssertFalse(SessionStore.shouldExecuteArchiveWideMaintenance(
            explicitDebugOverride: false
        ))
        XCTAssertTrue(SessionStore.shouldExecuteArchiveWideMaintenance(
            explicitDebugOverride: true
        ), "only the explicit developer launch authority may enter the graph")
    }

    func testAutomaticFullBackgroundProjectionFailsClosedInRelease() {
        XCTAssertFalse(
            SessionStore.shouldExecuteAutomaticFullBackgroundProjection()
        )
        XCTAssertTrue(
            SessionStore
                .shouldReserveAutomaticRecoveredDataProjectionForSafeBackground(
                    reason: "archive_did_update",
                    isExactRecoveryPublication: false,
                    backgroundProjectionAllowed: false
                ),
            "ordinary archive updates persist intent and mint no ticket"
        )
    }

    func testColdAutomaticWorkoutUpdateWaitsForBoundedRecoveredProjection() {
        XCTAssertTrue(SessionStore
            .shouldDeferAutomaticWorkoutRehydrationUntilRecoveredProjection(
                reason: "archive_did_update",
                isRequiredRecoveredPublication: false,
                recoveredProjectionWasSupplied: false,
                cachedRecoveredProjectionAvailable: false
            ), "idle/cold automatic updates must never use the raw 1.5M scan")
        XCTAssertFalse(SessionStore
            .shouldDeferAutomaticWorkoutRehydrationUntilRecoveredProjection(
                reason: "archive_did_update",
                isRequiredRecoveredPublication: false,
                recoveredProjectionWasSupplied: true,
                cachedRecoveredProjectionAvailable: false
            ))
        XCTAssertFalse(SessionStore
            .shouldDeferAutomaticWorkoutRehydrationUntilRecoveredProjection(
                reason: "archive_did_update",
                isRequiredRecoveredPublication: false,
                recoveredProjectionWasSupplied: false,
                cachedRecoveredProjectionAvailable: true
            ))
    }

    private func compactionAdmitted(
        reason: String = "bg_processing",
        isBackground: Bool = true,
        thermal: ProcessInfo.ThermalState = .nominal,
        lowPower: Bool = false,
        battery: UIDevice.BatteryState = .charging,
        level: Float = 0.9,
        exactOwner: Bool = false,
        recoveredOwner: Bool = false
    ) -> Bool {
        SessionStore.shouldAdmitAutomaticArchiveCompaction(
            reason: reason,
            applicationIsBackground: isBackground,
            thermalState: thermal,
            isLowPowerModeEnabled: lowPower,
            batteryState: battery,
            batteryLevel: level,
            exactRecoveryOwnsPriority: exactOwner,
            recoveredCycleEngaged: recoveredOwner
        )
    }

    func testArchiveCompactionAdmitsOnlyGuardedBGProcessing() {
        XCTAssertTrue(compactionAdmitted())
        XCTAssertTrue(compactionAdmitted(thermal: .fair))
        XCTAssertTrue(compactionAdmitted(
            battery: .unplugged,
            level: 0.5
        ))

        for reason in [
            "deferred_session_load",
            "archive_did_update",
            "bg_app_refresh",
            "foreground_scene_active",
            "manual",
        ] {
            XCTAssertFalse(
                compactionAdmitted(reason: reason),
                "\(reason) must not enumerate retention inputs"
            )
        }
        XCTAssertFalse(
            compactionAdmitted(isBackground: false),
            "even a real BGProcessing reason expires when the app foregrounds"
        )
    }

    func testArchiveCompactionCapPressureKeepsLeaseButTimerRetryDoesNot() {
        XCTAssertTrue(compactionAdmitted(
            reason: "bg_processing_cap_pressure"
        ))
        XCTAssertFalse(compactionAdmitted(
            reason: "bg_processing_cap_pressure",
            isBackground: false
        ))
        XCTAssertFalse(compactionAdmitted(
            reason: "bg_processing_retention_retry"
        ), "yielded work must wait for a new live BGProcessing task")
        XCTAssertFalse(compactionAdmitted(
            reason: "bg_processing_cap_pressure_retention_retry"
        ))
    }

    func testQueuedCompactionWorkerRefusesLeaseAfterTaskBodyEnds() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertTrue(SessionStore.archiveCompactionWorkerLeaseIsCurrent(
            leaseGeneration: 7,
            activeLeaseGeneration: 7,
            now: now,
            leaseExpiresAt: now.addingTimeInterval(1)
        ))
        XCTAssertFalse(SessionStore.archiveCompactionWorkerLeaseIsCurrent(
            leaseGeneration: 7,
            activeLeaseGeneration: nil,
            now: now,
            leaseExpiresAt: now.addingTimeInterval(1)
        ), "normal task exit/expiration revokes queued work")
        XCTAssertFalse(SessionStore.archiveCompactionWorkerLeaseIsCurrent(
            leaseGeneration: 7,
            activeLeaseGeneration: 8,
            now: now,
            leaseExpiresAt: now.addingTimeInterval(1)
        ))
        XCTAssertFalse(SessionStore.archiveCompactionWorkerLeaseIsCurrent(
            leaseGeneration: 7,
            activeLeaseGeneration: 7,
            now: now,
            leaseExpiresAt: now.addingTimeInterval(-0.001)
        ))
    }

    func testArchiveCompactionTokenStopsForForegroundHeatAndLowPower() {
        let foregroundToken =
            SessionStore.ArchiveCompactionCancellationToken()
        XCTAssertTrue(foregroundToken.shouldContinue(
            thermalState: .nominal,
            isLowPowerModeEnabled: false
        ))
        foregroundToken.revoke() // scene-active / BGTask expiration
        XCTAssertFalse(foregroundToken.shouldContinue(
            thermalState: .nominal,
            isLowPowerModeEnabled: false
        ))

        XCTAssertFalse(
            SessionStore.ArchiveCompactionCancellationToken()
                .shouldContinue(
                    thermalState: .serious,
                    isLowPowerModeEnabled: false
                )
        )
        XCTAssertFalse(
            SessionStore.ArchiveCompactionCancellationToken()
                .shouldContinue(
                    thermalState: .nominal,
                    isLowPowerModeEnabled: true
                )
        )
    }

    func testArchiveCompactionLeaseCompletionIsConsumedExactlyOnce() {
        for firstExit in [
            "admission_invalidated",
            "operation_in_flight",
            "task_expired",
        ] {
            var pendingGeneration: Int? = 7
            var callbackCount = 0
            func finish() {
                guard SessionStore
                    .shouldConsumeArchiveCompactionLeaseCompletion(
                        pendingGeneration: pendingGeneration,
                        requestedGeneration: 7
                    ) else { return }
                pendingGeneration = nil
                callbackCount += 1
            }

            finish() // first synchronous/expiration exit
            finish() // normal task-body defer
            finish() // a queued worker observes the invalidated lease later
            XCTAssertEqual(callbackCount, 1, firstExit)
            XCTAssertNil(pendingGeneration, firstExit)
        }
    }

    func testArchiveCompactionRejectsUnsafePowerHeatAndHeavyOwners() {
        XCTAssertFalse(compactionAdmitted(thermal: .serious))
        XCTAssertFalse(compactionAdmitted(thermal: .critical))
        XCTAssertFalse(compactionAdmitted(lowPower: true))
        XCTAssertFalse(compactionAdmitted(
            battery: .unplugged,
            level: 0.49
        ))
        XCTAssertFalse(compactionAdmitted(
            battery: .unknown,
            level: -1
        ))
        XCTAssertFalse(compactionAdmitted(exactOwner: true))
        XCTAssertFalse(compactionAdmitted(recoveredOwner: true))
    }

    private func incrementalSource(
        size: UInt64,
        startOffset: UInt64,
        pathExtension: String = "jsonl"
    ) -> AtriaHistoricalJSONLRecentScanner.Source {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(pathExtension)
        return .init(
            descriptor: .init(
                url: url,
                size: size,
                modificationTime: 1,
                resourceIdentifier: UUID().uuidString
            ),
            startOffset: startOffset
        )
    }

    private func recoveredProjectionTicket(
        _ effects: [AtriaRecoveredDataRecomputeCoordinator.Effect],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> AtriaRecoveredDataRecomputeCoordinator.Ticket {
        guard effects.count == 1,
              case .startProjection(let ticket) = effects[0] else {
            XCTFail(
                "expected exactly one startProjection effect, got \(effects)",
                file: file,
                line: line
            )
            throw ProjectionTestError.missingTicket
        }
        return ticket
    }

    private enum ProjectionTestError: Error {
        case missingTicket
    }

    func testAutomaticRecoveredProjectionAdmitsCacheReuse() {
        XCTAssertTrue(
            HistoricalArchive.automaticRecoveredDataProjectionPlanIsBounded(
                .reuse,
                maximumIncrementalBytes: 4_096
            )
        )
    }

    func testAutomaticRecoveredProjectionAdmitsBoundedIncrementalTail() {
        XCTAssertTrue(
            HistoricalArchive.automaticRecoveredDataProjectionPlanIsBounded(
                .incremental([
                    incrementalSource(size: 10_000, startOffset: 6_000),
                ]),
                maximumIncrementalBytes: 4_096
            )
        )
    }

    func testAutomaticRecoveredProjectionBoundaryIsInclusive() {
        XCTAssertTrue(
            HistoricalArchive.automaticRecoveredDataProjectionPlanIsBounded(
                .incremental([
                    incrementalSource(size: 5_096, startOffset: 1_000),
                ]),
                maximumIncrementalBytes: 4_096
            )
        )
        XCTAssertFalse(
            HistoricalArchive.automaticRecoveredDataProjectionPlanIsBounded(
                .incremental([
                    incrementalSource(size: 5_097, startOffset: 1_000),
                ]),
                maximumIncrementalBytes: 4_096
            ),
            "boundary + 1 byte belongs to the guarded background lane"
        )
    }

    func testAutomaticRecoveredProjectionDefersRebuildAndCompressedTail() {
        let source = incrementalSource(size: 4_096, startOffset: 0)
        XCTAssertFalse(
            HistoricalArchive.automaticRecoveredDataProjectionPlanIsBounded(
                .rebuild([source]),
                maximumIncrementalBytes: 4_096
            )
        )
        XCTAssertFalse(
            HistoricalArchive.automaticRecoveredDataProjectionPlanIsBounded(
                .incremental([
                    incrementalSource(
                        size: 1_024,
                        startOffset: 0,
                        pathExtension:
                            AtriaHistoricalSealedJSONLCompression
                                .artifactExtension
                    ),
                ]),
                maximumIncrementalBytes: 4_096
            ),
            "compressed expansion is not bounded by on-disk byte count"
        )
    }

    func testWorkerReadmissionRefusesTailThatGrewOrWasReplacedAfterPreflight() {
        let maximum: UInt64 = 4_096
        let admitted = incrementalSource(size: 5_096, startOffset: 1_000)
        XCTAssertTrue(
            HistoricalArchive.automaticRecoveredDataProjectionPlanIsBounded(
                .incremental([admitted]),
                maximumIncrementalBytes: maximum
            ),
            "the notification preflight may admit the exact 4 KiB boundary"
        )

        let grewByOne = AtriaHistoricalJSONLRecentScanner.Source(
            descriptor: .init(
                url: admitted.descriptor.url,
                size: admitted.descriptor.size + 1,
                modificationTime: admitted.descriptor.modificationTime + 1,
                resourceIdentifier: admitted.descriptor.resourceIdentifier
            ),
            startOffset: admitted.startOffset
        )
        XCTAssertFalse(
            HistoricalArchive.automaticRecoveredDataProjectionPlanIsBounded(
                .incremental([grewByOne]),
                maximumIncrementalBytes: maximum
            ),
            "a tail that reaches boundary + 1 before its worker starts must defer"
        )
        XCTAssertFalse(
            HistoricalArchive.automaticRecoveredDataProjectionPlanIsBounded(
                .rebuild([admitted]),
                maximumIncrementalBytes: maximum
            ),
            "replacement between preflight and worker admission must defer"
        )
    }

    func testUnboundedAutomaticTicketRetiresWithoutRecoveryFailureAndStartsTrailing()
        throws {
        var coordinator = AtriaRecoveredDataRecomputeCoordinator(
            requiredComponents: []
        )
        let firstEffects = coordinator.request(
            archiveRevision: 1,
            reason: "archive_did_update"
        )
        let first = try recoveredProjectionTicket(firstEffects)
        XCTAssertTrue(coordinator.request(
            archiveRevision: 2,
            reason: "exact_terminal"
        ).isEmpty)

        let retirement = coordinator.projectionReservedForSafeBackground(
            ticket: first
        )
        XCTAssertEqual(
            retirement.first,
            AtriaRecoveredDataRecomputeCoordinator.Effect
                .reservedForSafeBackground(first)
        )
        XCTAssertFalse(retirement.contains { effect in
            if case .failed = effect { return true }
            return false
        }, "budget refusal is an intentional freshness deferral, not failure")
        guard retirement.count == 2,
              case .startProjection(let trailing) = retirement[1] else {
            return XCTFail("expected the newest trailing request to start")
        }
        XCTAssertEqual(trailing.archiveRevision, 2)
        XCTAssertEqual(trailing.reason, "exact_terminal")
        XCTAssertEqual(coordinator.phase, .projecting(trailing))
    }

    func testColdLaunchGatePrecedesProjectionRequestAndMotionUsesEventualSafeLane()
        throws {
        let testsURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        let sourcesURL = testsURL.deletingLastPathComponent()
            .appendingPathComponent("Atria")
        let sessions = try String(
            contentsOf: sourcesURL.appendingPathComponent("Sessions.swift"),
            encoding: .utf8
        )
        let requestStart = try XCTUnwrap(sessions.range(
            of: "private func requestRecoveredDataRecomputation("
        ))
        let requestEnd = try XCTUnwrap(sessions.range(
            of: "nonisolated static func shouldStartAutomaticArchiveProjection(",
            range: requestStart.upperBound..<sessions.endIndex
        ))
        let request = String(
            sessions[requestStart.lowerBound..<requestEnd.lowerBound]
        )
        let reservation = try XCTUnwrap(request.range(
            of: "shouldReserveAutomaticRecoveredDataProjectionForSafeBackground("
        ))
        let coordinatorRequest = try XCTUnwrap(request.range(
            of: "recoveredDataRecompute.request("
        ))
        let revisionFence = try XCTUnwrap(request.range(
            of: "recoveredDataPublicationFence.recordArchiveUpdate()"
        ))
        let workoutRehydrationOffer = try XCTUnwrap(request.range(
            of: "scheduleConfirmedWorkoutArchiveRehydration(reason: reason)"
        ))
        XCTAssertLessThan(
            reservation.lowerBound,
            revisionFence.lowerBound,
            "ordinary freshness must return before minting a revision"
        )
        XCTAssertLessThan(
            reservation.lowerBound,
            coordinatorRequest.lowerBound,
            "ordinary freshness must return before a coordinator ticket exists"
        )
        XCTAssertLessThan(
            coordinatorRequest.lowerBound,
            workoutRehydrationOffer.lowerBound,
            "projection ownership must exist before workout repair is offered"
        )
        XCTAssertTrue(request.contains(
            "status=reserved_for_safe_background"
        ))
        let observerStart = try XCTUnwrap(sessions.range(
            of: "self.historicalArchiveStatusObserver ="
        ))
        let observerEnd = try XCTUnwrap(sessions.range(
            of: "self.motionBankOffloadObserver =",
            range: observerStart.upperBound..<sessions.endIndex
        ))
        let observer = String(
            sessions[observerStart.lowerBound..<observerEnd.lowerBound]
        )
        XCTAssertTrue(observer.contains(
            "reserveAutomaticRecoveredProjectionFreshness("
        ))
        XCTAssertTrue(observer.contains(
            "reserveArchiveCompactionForSafeBackground()"
        ))
        XCTAssertFalse(observer.contains(
            "compactHistoricalArchiveIfUseful("
        ), "archive callbacks must only retain a future BGProcessing intent")
        XCTAssertFalse(observer.contains(
            "requestRecoveredDataRecomputation(reason: \"archive_did_update\")"
        ), "archive notifications must persist intent without a ticket")
        XCTAssertFalse(sessions.contains(
            "scheduleAutomaticArchiveUpdateProjectionAdmission("
        ))
        XCTAssertFalse(sessions.contains(
            "automaticIncrementalProjectionArchiveRevisions"
        ))
        let fullBackgroundStart = try XCTUnwrap(sessions.range(
            of: "func requestBackgroundArchiveProjectionIfSafe("
        ))
        let fullBackgroundEnd = try XCTUnwrap(sessions.range(
            of: "func endBackgroundArchiveProjectionThrottle()",
            range: fullBackgroundStart.upperBound..<sessions.endIndex
        ))
        let fullBackground = String(
            sessions[fullBackgroundStart.lowerBound..<fullBackgroundEnd.lowerBound]
        )
        let fullBackgroundFence = try XCTUnwrap(fullBackground.range(
            of: "guard Self.shouldExecuteAutomaticFullBackgroundProjection() else {"
        ))
        let throttleBegin = try XCTUnwrap(fullBackground.range(
            of: "AtriaBackgroundProjectionThrottle.shared.begin("
        ))
        let unboundedRequest = try XCTUnwrap(fullBackground.range(
            of: "requestRecoveredDataRecomputation("
        ))
        XCTAssertLessThan(fullBackgroundFence.lowerBound, throttleBegin.lowerBound)
        XCTAssertLessThan(fullBackgroundFence.lowerBound, unboundedRequest.lowerBound)
        XCTAssertTrue(fullBackground.contains(
            "status=reserved_automatic_full_disabled"
        ))
        let workoutRehydrationStart = try XCTUnwrap(sessions.range(
            of: "private func scheduleConfirmedWorkoutArchiveRehydration("
        ))
        let workoutRehydrationEnd = try XCTUnwrap(sessions.range(
            of: "private func scheduleConfirmedWorkoutStepEvidencePublication(",
            range: workoutRehydrationStart.upperBound..<sessions.endIndex
        ))
        let workoutRehydrationRange = workoutRehydrationStart.lowerBound..<workoutRehydrationEnd.lowerBound
        let workoutRehydration = String(sessions[workoutRehydrationRange])
        let coldAutomaticFence = try XCTUnwrap(workoutRehydration.range(
            of: "shouldDeferAutomaticWorkoutRehydrationUntilRecoveredProjection("
        ))
        let rawHeartRateRead = try XCTUnwrap(workoutRehydration.range(
            of: "HistoricalArchive.metricHeartRatePoints("
        ))
        XCTAssertLessThan(
            coldAutomaticFence.lowerBound,
            rawHeartRateRead.lowerBound,
            "cold automatic archive updates must fail closed before raw HR I/O"
        )
        let compactionStart = try XCTUnwrap(sessions.range(
            of: "func compactHistoricalArchiveIfUseful("
        ))
        let compactionEnd = try XCTUnwrap(sessions.range(
            of: "nonisolated static func shouldBypassDailyArchiveCompactionLease(",
            range: compactionStart.upperBound..<sessions.endIndex
        ))
        let compaction = String(
            sessions[compactionStart.lowerBound..<compactionEnd.lowerBound]
        )
        let releaseFence = try XCTUnwrap(compaction.range(
            of: "guard Self.shouldExecuteArchiveWideMaintenance("
        ))
        let compactionWorkerReadmission = try XCTUnwrap(compaction.range(
            of: "archiveCompactionAdmissionRemainsValidAtWorkerBoundary("
        ))
        let archiveRewrite = try XCTUnwrap(compaction.range(
            of: "HistoricalArchive.compactArchiveConverging("
        ))
        XCTAssertLessThan(
            releaseFence.lowerBound,
            archiveRewrite.lowerBound,
            "automatic callers must return before entering any archive-wide work"
        )
        XCTAssertLessThan(
            compactionWorkerReadmission.lowerBound,
            archiveRewrite.lowerBound,
            "the exact lease/environment must be rechecked after queueing"
        )
        XCTAssertTrue(compaction.contains(
            "shouldContinue: shouldContinue"
        ), "the explicit developer lane retains cooperative cancellation")
        XCTAssertTrue(compaction.contains(
            "status=reserved_automatic_execution_disabled"
        ))
        XCTAssertTrue(compaction.contains(
            "finishArchiveCompactionLeaseCompletion("
        ), "the rejected BGProcessing offer must settle exactly once")
        XCTAssertFalse(compaction.contains(
            "scheduleArchiveCapPressureProbe("
        ))
        XCTAssertTrue(compaction.contains(
            "installArchiveCompactionLeaseCompletionIfNeeded("
        ), "task expiration must be able to settle an awaiting offer")
        XCTAssertFalse(compaction.contains("Task.sleep"))
        XCTAssertFalse(compaction.contains("_retention_retry"))
        XCTAssertFalse(compaction.contains(
            "refreshHistoricalArchiveStatus(reason: \"archive_compaction\")"
        ), "retention completion cannot chain an unbound diagnostics walk")

        XCTAssertEqual(
            sessions.components(separatedBy:
                "HistoricalArchive.compactArchiveConverging(").count - 1,
            1,
            "only the explicit-debug-fenced driver may call the compactor"
        )
        XCTAssertFalse(sessions.contains(
            "HistoricalArchive.highVolumeMaintenancePressure("
        ), "production must have no automatic archive-wide pressure probe")

        XCTAssertFalse(sessions.contains(
            "archiveCompactionDeferredUntilForeground"
        ))
        let foregroundResumeStart = try XCTUnwrap(sessions.range(
            of: "func resumeDeferredForegroundArchiveWork(reason: String)"
        ))
        let foregroundResumeEnd = try XCTUnwrap(sessions.range(
            of: "private func finishConfirmedWorkoutRehydrationCompletions(",
            range: foregroundResumeStart.upperBound..<sessions.endIndex
        ))
        let foregroundResumeRange =
            foregroundResumeStart.lowerBound..<foregroundResumeEnd.lowerBound
        let foregroundResume = String(sessions[foregroundResumeRange])
        XCTAssertFalse(foregroundResume.contains(
            "compactHistoricalArchiveIfUseful("
        ))

        let deferredLoadStart = try XCTUnwrap(sessions.range(
            of: "private func continueDeferredLoadFollowUp("
        ))
        let debugCompactionGate = try XCTUnwrap(sessions.range(
            of: "if ProcessInfo.processInfo.arguments.contains(\"--atria-compact-archive\")",
            range: deferredLoadStart.upperBound..<sessions.endIndex
        ))
        let normalColdLoad = String(
            sessions[deferredLoadStart.lowerBound..<debugCompactionGate.lowerBound]
        )
        XCTAssertTrue(normalColdLoad.contains(
            "reserveArchiveCompactionForSafeBackground()"
        ))
        XCTAssertFalse(normalColdLoad.contains(
            "compactHistoricalArchiveIfUseful("
        ), "cold launch must be structurally unable to enumerate retention")

        let backgroundMaintenanceStart = try XCTUnwrap(sessions.range(
            of: "func performBackgroundMaintenance(reason: String,\n                                      now: Date,"
        ))
        let backgroundMaintenanceEnd = try XCTUnwrap(sessions.range(
            of: "func generateWeeklyReportProductionFixtureFromLaunchIfRequested(",
            range: backgroundMaintenanceStart.upperBound..<sessions.endIndex
        ))
        let backgroundMaintenanceRange =
            backgroundMaintenanceStart.lowerBound..<backgroundMaintenanceEnd.lowerBound
        let backgroundMaintenance = String(
            sessions[backgroundMaintenanceRange]
        )
        XCTAssertFalse(backgroundMaintenance.contains(
            "compactHistoricalArchiveIfUseful("
        ), "early backup maintenance runs before BLE drain and cannot compact")
        let workerStart = try XCTUnwrap(sessions.range(
            of: "private func runRecoveredHeartRateProjection("
        ))
        let workerEnd = try XCTUnwrap(sessions.range(
            of: "nonisolated static func shouldRenewRecoveredProjectionLease(",
            range: workerStart.upperBound..<sessions.endIndex
        ))
        let worker = String(
            sessions[workerStart.lowerBound..<workerEnd.lowerBound]
        )
        XCTAssertTrue(worker.contains("HistoricalArchive.diagnostics()"))
        XCTAssertFalse(worker.contains(
            "automaticRecoveredDataProjectionHasBoundedIncrementalPlan("
        ))
        XCTAssertFalse(worker.contains(
            "makeAutomaticallyAdmittedRecoveredDataSnapshot("
        ))
        XCTAssertTrue(worker.contains(
            "projectionReservedForSafeBackground(ticket: ticket)"
        ))

        let app = try String(
            contentsOf: sourcesURL.appendingPathComponent("AtriaApp.swift"),
            encoding: .utf8
        )
        let motionStart = try XCTUnwrap(app.range(of: "var motionDrained = false"))
        let hrStart = try XCTUnwrap(app.range(
            of: "// HR drain:",
            range: motionStart.upperBound..<app.endIndex
        ))
        let motion = String(app[motionStart.lowerBound..<hrStart.lowerBound])
        XCTAssertFalse(
            motion.contains("awaitRecoveredDataPublication("),
            "motion compact success must not synchronously await a full projection"
        )
        let backgroundProjection = try XCTUnwrap(app.range(
            of: "requestBackgroundArchiveProjectionIfSafe(reason: \"bg_projection\")",
            range: hrStart.upperBound..<app.endIndex
        ))
        XCTAssertLessThan(
            motionStart.lowerBound,
            backgroundProjection.lowerBound,
            "the same processing task must still offer eventual guarded projection"
        )
        let offlineDrain = try XCTUnwrap(app.range(
            of: "requestOfflineHistoricalSyncAwaitingCompletion("
        ))
        let leaseBegin = try XCTUnwrap(app.range(
            of: "beginArchiveCompactionBGProcessingLeaseIfSafe("
        ))
        let sameLinkFence = try XCTUnwrap(app.range(
            of: "if !ble.historicalRadioTransportOwnsLink,",
            range: backgroundProjection.upperBound..<leaseBegin.lowerBound
        ))
        let awaitingOffer = try XCTUnwrap(app.range(
            of: "await withCheckedContinuation",
            range: leaseBegin.upperBound..<app.endIndex
        ))
        let compactionOffer = try XCTUnwrap(app.range(
            of: "store.compactHistoricalArchiveIfUseful(",
            range: awaitingOffer.upperBound..<app.endIndex
        ))
        let widgetPublish = try XCTUnwrap(app.range(
            of: "WidgetSnapshotPublisher.publish(",
            range: compactionOffer.upperBound..<app.endIndex
        ))
        XCTAssertLessThan(
            offlineDrain.lowerBound,
            leaseBegin.lowerBound,
            "motion/HR drain must settle before retention gets a lease"
        )
        XCTAssertLessThan(
            backgroundProjection.lowerBound,
            leaseBegin.lowerBound,
            "app-facing guarded projection keeps precedence over retention"
        )
        XCTAssertLessThan(
            sameLinkFence.lowerBound,
            leaseBegin.lowerBound,
            "an active same-link history owner must prevent lease minting"
        )
        XCTAssertLessThan(leaseBegin.lowerBound, awaitingOffer.lowerBound)
        XCTAssertLessThan(awaitingOffer.lowerBound, compactionOffer.lowerBound)
        XCTAssertLessThan(
            compactionOffer.lowerBound,
            widgetPublish.lowerBound,
            "the BG task must await the queued operation before exiting"
        )
        XCTAssertTrue(app.contains(
            "store.endArchiveCompactionBGProcessingLease("
        ))
        XCTAssertTrue(app.contains(
            "store.invalidateArchiveCompactionBGProcessingLease("
        ), "BGTask expiration must immediately revoke queued authority")
        XCTAssertTrue(app.contains(
            "reason: \"scene_active\""
        ), "foreground entry must revoke an already-running cooperative pass")
    }

    func testProductionHasNoAutomaticArchiveWideMaintenanceCallSite() throws {
        let testsURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        let sourceRoot = testsURL.deletingLastPathComponent()
            .appendingPathComponent("Atria")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ))
        var compactorCallers: [String] = []
        var pressureProbeCallers: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            let compactorCount = source.components(
                separatedBy: "HistoricalArchive.compactArchiveConverging("
            ).count - 1
            compactorCallers.append(contentsOf:
                Array(repeating: url.lastPathComponent, count: compactorCount)
            )
            let pressureCount = source.components(
                separatedBy: "HistoricalArchive.highVolumeMaintenancePressure("
            ).count - 1
            pressureProbeCallers.append(contentsOf:
                Array(repeating: url.lastPathComponent, count: pressureCount)
            )
        }
        XCTAssertEqual(compactorCallers, ["Sessions.swift"])
        XCTAssertTrue(pressureProbeCallers.isEmpty)

        let sessions = try String(
            contentsOf: sourceRoot.appendingPathComponent("Sessions.swift"),
            encoding: .utf8
        )
        let driverStart = try XCTUnwrap(sessions.range(
            of: "func compactHistoricalArchiveIfUseful("
        ))
        let driverEnd = try XCTUnwrap(sessions.range(
            of: "nonisolated static func shouldBypassDailyArchiveCompactionLease(",
            range: driverStart.upperBound..<sessions.endIndex
        ))
        let driver = String(
            sessions[driverStart.lowerBound..<driverEnd.lowerBound]
        )
        let releaseFence = try XCTUnwrap(driver.range(
            of: "guard Self.shouldExecuteArchiveWideMaintenance("
        ))
        let archiveEntry = try XCTUnwrap(driver.range(
            of: "HistoricalArchive.compactArchiveConverging("
        ))
        XCTAssertLessThan(releaseFence.lowerBound, archiveEntry.lowerBound)
        XCTAssertTrue(driver.contains(
            "status=reserved_automatic_execution_disabled"
        ))
    }

    // MARK: Cooperative throttle
    //
    // The checkpoint no-ops on the main thread by design, so drive it off-main.

    private func checkpointOffMain(_ throttle: AtriaBackgroundProjectionThrottle,
                                   processedDelta: Int = 1) -> Bool {
        let exp = expectation(description: "off-main checkpoint")
        var result = false
        DispatchQueue.global(qos: .utility).async {
            result = throttle.cooperativeCheckpointShouldAbort(processedDelta: processedDelta)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 3)
        return result
    }

    private func leasedCheckpointOffMain(
        _ throttle: AtriaBackgroundProjectionThrottle,
        lease: AtriaBackgroundProjectionThrottle.ActiveLease,
        processedDelta: Int = 1
    ) -> Bool {
        let exp = expectation(description: "leased off-main checkpoint")
        var result = false
        DispatchQueue.global(qos: .utility).async {
            result = throttle.cooperativeCheckpointShouldAbort(
                lease: lease,
                processedDelta: processedDelta
            )
            exp.fulfill()
        }
        wait(for: [exp], timeout: 3)
        return result
    }

    func testThrottleInactiveNeverAborts() {
        let throttle = AtriaBackgroundProjectionThrottle()
        XCTAssertFalse(checkpointOffMain(throttle), "no begin() → inactive → never aborts, never sleeps")
    }

    func testThrottleAbortsWhenBudgetAlreadyElapsed() {
        let throttle = AtriaBackgroundProjectionThrottle()
        throttle.begin(budgetSeconds: 0)
        XCTAssertTrue(checkpointOffMain(throttle), "zero budget → deadline already passed → abort")
    }

    func testThrottleAbortsWhenCancelled() {
        let throttle = AtriaBackgroundProjectionThrottle()
        throttle.begin(budgetSeconds: 600)
        throttle.cancel()
        XCTAssertTrue(checkpointOffMain(throttle))
    }

    func testCapturedThrottleLeaseRemainsRevokedAfterSceneEnd() throws {
        let throttle = AtriaBackgroundProjectionThrottle()
        throttle.begin(budgetSeconds: 600)
        let lease = try XCTUnwrap(throttle.captureActiveLease())
        XCTAssertFalse(leasedCheckpointOffMain(throttle, lease: lease))
        throttle.end()
        XCTAssertTrue(
            leasedCheckpointOffMain(throttle, lease: lease),
            "end must revoke the old pass while inactive foreground work stays free"
        )
        XCTAssertFalse(checkpointOffMain(throttle))
    }

    func testThrottleEnvironmentRevokesForHeatAndLowPower() {
        XCTAssertFalse(AtriaBackgroundProjectionThrottle
            .environmentRequiresAbort(
                thermalState: .nominal,
                isLowPowerModeEnabled: false
            ))
        XCTAssertTrue(AtriaBackgroundProjectionThrottle
            .environmentRequiresAbort(
                thermalState: .serious,
                isLowPowerModeEnabled: false
            ))
        XCTAssertTrue(AtriaBackgroundProjectionThrottle
            .environmentRequiresAbort(
                thermalState: .critical,
                isLowPowerModeEnabled: false
            ))
        XCTAssertTrue(AtriaBackgroundProjectionThrottle
            .environmentRequiresAbort(
                thermalState: .nominal,
                isLowPowerModeEnabled: true
            ))
    }

    func testThrottleWithinBudgetAndFewFramesDoesNotAbort() {
        let throttle = AtriaBackgroundProjectionThrottle()
        throttle.begin(budgetSeconds: 600)
        // Fewer than the 64-frame cooperative batch → no sleep, no abort.
        XCTAssertFalse(checkpointOffMain(throttle, processedDelta: 10))
    }

    func testThrottleMainThreadIsAlwaysNoOp() {
        let throttle = AtriaBackgroundProjectionThrottle()
        throttle.begin(budgetSeconds: 0)
        // On the main (test) thread the guard short-circuits regardless of state.
        XCTAssertFalse(throttle.cooperativeCheckpointShouldAbort(processedDelta: 1000))
    }

    func testThrottleEndDeactivates() {
        let throttle = AtriaBackgroundProjectionThrottle()
        throttle.begin(budgetSeconds: 600)
        throttle.end()
        XCTAssertFalse(throttle.isActive)
        XCTAssertFalse(checkpointOffMain(throttle, processedDelta: 1000),
                       "after end() the throttle is inactive again")
    }
}
