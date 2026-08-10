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

    func testConnectedRawPublicationYieldRequiresCoolActiveForeground() {
        XCTAssertTrue(
            SessionStore.shouldStartConnectedRawCatchUpPublicationYield(
                applicationIsActive: true,
                thermalState: .nominal,
                isLowPowerModeEnabled: false
            )
        )
        XCTAssertTrue(
            SessionStore.shouldStartConnectedRawCatchUpPublicationYield(
                applicationIsActive: true,
                thermalState: .fair,
                isLowPowerModeEnabled: false
            )
        )
        XCTAssertFalse(
            SessionStore.shouldStartConnectedRawCatchUpPublicationYield(
                applicationIsActive: false,
                thermalState: .nominal,
                isLowPowerModeEnabled: false
            )
        )
        XCTAssertFalse(
            SessionStore.shouldStartConnectedRawCatchUpPublicationYield(
                applicationIsActive: true,
                thermalState: .serious,
                isLowPowerModeEnabled: false
            )
        )
        XCTAssertFalse(
            SessionStore.shouldStartConnectedRawCatchUpPublicationYield(
                applicationIsActive: true,
                thermalState: .critical,
                isLowPowerModeEnabled: false
            )
        )
        XCTAssertFalse(
            SessionStore.shouldStartConnectedRawCatchUpPublicationYield(
                applicationIsActive: true,
                thermalState: .nominal,
                isLowPowerModeEnabled: true
            )
        )
    }

    func testConnectedRawPublicationYieldWaitsForDurableCurrentCycleFrontier() {
        let cycleStart = Date(timeIntervalSince1970: 10_000)
        func needed(
            intent: Bool = true,
            frontier: TimeInterval?
        ) -> Bool {
            SessionStore.connectedRawCatchUpPublicationYieldIsNeeded(
                bootstrapIntentPending: intent,
                durableFrontierUnix: frontier,
                currentCycleStart: cycleStart
            )
        }

        XCTAssertFalse(needed(frontier: nil))
        XCTAssertFalse(needed(frontier: .nan))
        XCTAssertFalse(needed(frontier: 0))
        XCTAssertFalse(needed(frontier: 9_999.999))
        XCTAssertTrue(needed(frontier: 10_000))
        XCTAssertTrue(needed(frontier: 10_001))
        XCTAssertFalse(needed(intent: false, frontier: 10_001))
    }

    func testFirstUseAfternoonCutoffIncludesPriorNightWithoutExceeding48Hours() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 9,
            hour: 16
        ))!
        let expectedPriorNightFloor = calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 8,
            hour: 12
        ))!

        let cutoff = SessionStore.automaticRecoveredDataProjectionCutoff(
            now: now,
            confirmedSleeps: [],
            calendar: calendar
        )

        XCTAssertEqual(cutoff, expectedPriorNightFloor)
        XCTAssertGreaterThanOrEqual(
            cutoff,
            now.addingTimeInterval(-48 * 60 * 60)
        )
        XCTAssertLessThan(
            cutoff,
            calendar.startOfDay(for: now),
            "first-use afternoon projection must retain the preceding night"
        )
    }

    // MARK: Foreground admission

    func testOrdinaryColdLaunchAndArchiveUpdatesRequireMetadataAdmission() {
        for reason in [
            "deferred_session_load",
            "archive_did_update",
            "archive_did_update_after_history_finalizer",
        ] {
            XCTAssertTrue(
                SessionStore
                    .isMetadataQualifiedAutomaticRecoveredDataProjectionReason(
                        reason: reason,
                        isExactRecoveryPublication: false,
                        backgroundProjectionAllowed: false
                    ),
                "\(reason) must pass cheap metadata before a ticket exists"
            )
        }
    }

    func testExactBackgroundAndExplicitUserWorkBypassAutomaticMetadataLane() {
        XCTAssertFalse(
            SessionStore
                .isMetadataQualifiedAutomaticRecoveredDataProjectionReason(
                    reason: "archive_did_update",
                    isExactRecoveryPublication: true,
                    backgroundProjectionAllowed: false
                ),
            "terminal exact recovery retains its completion-fenced projection"
        )
        XCTAssertFalse(
            SessionStore
                .isMetadataQualifiedAutomaticRecoveredDataProjectionReason(
                    reason: "deferred_session_load",
                    isExactRecoveryPublication: false,
                    backgroundProjectionAllowed: true
                ),
            "a leased background request uses its separate guarded lane"
        )
        XCTAssertFalse(
            SessionStore
                .isMetadataQualifiedAutomaticRecoveredDataProjectionReason(
                    reason: "explicit_user_repair",
                    isExactRecoveryPublication: false,
                    backgroundProjectionAllowed: false
                )
        )
    }

    func testRefusedBGBootstrapCannotReplayAsUnleasedFullProjection() {
        let reason = "bg_projection_current_window_bootstrap_bg_projection"
        XCTAssertFalse(SessionStore.shouldRetainDeferredRecoveredDataRequest(
            reason: reason,
            backgroundProjectionAllowed: true
        ), "a BG bootstrap refusal must retry only from its durable intent")
        XCTAssertFalse(SessionStore
            .isMetadataQualifiedAutomaticRecoveredDataProjectionReason(
                reason: reason,
                isExactRecoveryPublication: false,
                backgroundProjectionAllowed: false
            ), "losing the typed scope would otherwise mint a full ticket")
        XCTAssertTrue(SessionStore
            .isMetadataQualifiedAutomaticRecoveredDataProjectionReason(
                reason: "deferred_session_load_after_onboarding",
                isExactRecoveryPublication: false,
                backgroundProjectionAllowed: false
            ), "onboarding fallback stays on metadata-qualified bounded work")
    }

    func testOnlyNamedOrdinaryReasonsCanReachMetadataPreflight() {
        XCTAssertTrue(
            SessionStore
                .isMetadataQualifiedAutomaticRecoveredDataProjectionReason(
                    reason: "archive_did_update",
                    isExactRecoveryPublication: false,
                    backgroundProjectionAllowed: false
                ),
            "archive updates may proceed only after bounded plan qualification"
        )
        XCTAssertTrue(
            SessionStore
                .isMetadataQualifiedAutomaticRecoveredDataProjectionReason(
                    reason: "deferred_session_load",
                    isExactRecoveryPublication: false,
                    backgroundProjectionAllowed: false
                ),
            "cold load may reuse the compact checkpoint/process cache"
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
                .isMetadataQualifiedAutomaticRecoveredDataProjectionReason(
                    reason: "archive_did_update",
                    isExactRecoveryPublication: false,
                    backgroundProjectionAllowed: false
                ),
            "ordinary archive updates never enter the full background graph"
        )
    }

    func testBoundedAutomaticProjectionPreservesForegroundThermalSafety() {
        XCTAssertTrue(SessionStore.shouldStartBoundedAutomaticRecoveredDataProjection(
            applicationIsActive: true,
            thermalState: .nominal,
            isLowPowerModeEnabled: false
        ))
        XCTAssertFalse(SessionStore.shouldStartBoundedAutomaticRecoveredDataProjection(
            applicationIsActive: false,
            thermalState: .nominal,
            isLowPowerModeEnabled: false
        ))
        XCTAssertFalse(SessionStore.shouldStartBoundedAutomaticRecoveredDataProjection(
            applicationIsActive: true,
            thermalState: .serious,
            isLowPowerModeEnabled: false
        ))
        XCTAssertFalse(SessionStore.shouldStartBoundedAutomaticRecoveredDataProjection(
            applicationIsActive: true,
            thermalState: .nominal,
            isLowPowerModeEnabled: true
        ))
    }

    func testManyRawACKsCoalesceAcrossContinuationGapsAndNeverOverlapTransport() {
        let baseline: TimeInterval = 1_800_000_000
        var offerCount = 0
        // One hundred durability notifications can advance hours while the
        // same exact raw/motion authority remains pending. None may start the
        // expensive retained-window projector between continuation slices.
        for ack in 1...100 {
            if SessionStore.shouldOfferAutomaticRecoveredArchiveProjection(
                trigger: .archiveDidUpdate,
                historyTransportOwnsLink: true,
                observedFrontierUnix: baseline + TimeInterval(ack * 60),
                lastOfferedFrontierUnix: baseline
            ) {
                offerCount += 1
            }
        }
        XCTAssertEqual(offerCount, 0)
        XCTAssertFalse(SessionStore
            .shouldOfferAutomaticRecoveredArchiveProjection(
                trigger: .transportIdle,
                historyTransportOwnsLink: true,
                observedFrontierUnix: baseline + 6_000,
                lastOfferedFrontierUnix: baseline
            ))
        XCTAssertFalse(SessionStore
            .shouldOfferAutomaticRecoveredArchiveProjection(
                trigger: .terminalOrUserRefresh,
                historyTransportOwnsLink: true,
                observedFrontierUnix: baseline + 6_000,
                lastOfferedFrontierUnix: baseline
            ))
    }

    func testArchiveProjectionOffersAtFiveMinuteFrontierOrTrueIdleOrTerminal() {
        let baseline: TimeInterval = 1_800_000_000
        XCTAssertFalse(SessionStore
            .shouldOfferAutomaticRecoveredArchiveProjection(
                trigger: .archiveDidUpdate,
                historyTransportOwnsLink: false,
                observedFrontierUnix: baseline + 299,
                lastOfferedFrontierUnix: baseline
            ))
        XCTAssertTrue(SessionStore
            .shouldOfferAutomaticRecoveredArchiveProjection(
                trigger: .archiveDidUpdate,
                historyTransportOwnsLink: false,
                observedFrontierUnix: baseline + 300,
                lastOfferedFrontierUnix: baseline
            ))
        XCTAssertTrue(SessionStore
            .shouldOfferAutomaticRecoveredArchiveProjection(
                trigger: .transportIdle,
                historyTransportOwnsLink: false,
                observedFrontierUnix: nil,
                lastOfferedFrontierUnix: nil
            ))
        XCTAssertTrue(SessionStore
            .shouldOfferAutomaticRecoveredArchiveProjection(
                trigger: .terminalOrUserRefresh,
                historyTransportOwnsLink: false,
                observedFrontierUnix: nil,
                lastOfferedFrontierUnix: nil
            ))
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
        pathExtension: String = "jsonl",
        hasStableIdentity: Bool = true
    ) -> AtriaHistoricalJSONLRecentScanner.Source {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(pathExtension)
        return .init(
            descriptor: .init(
                url: url,
                size: size,
                modificationTime: 1,
                resourceIdentifier:
                    hasStableIdentity ? UUID().uuidString : nil
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

    private func temporaryProjectionDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtriaBackgroundProjectionTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
            HistoricalArchive.resetRecoveredDataCacheForTesting()
        }
        return directory
    }

    private func runProjectionOffMain<T>(_ body: @escaping () -> T) -> T {
        let completed = expectation(description: "projection completed off main")
        var result: T?
        DispatchQueue.global(qos: .userInitiated).async {
            result = body()
            completed.fulfill()
        }
        // `body` intentionally exercises the production background path. It
        // writes bounded diagnostics through UserDefaults, whose change
        // notification can synchronously rendezvous with the main queue.
        // Blocking main on a DispatchSemaphore deadlocks that legitimate
        // delivery. XCTest's waiter services the run loop while preserving
        // the assertion that the projection itself executes off-main.
        wait(for: [completed], timeout: 30)
        return result!
    }

    private func bootstrapHeartRateRecordLine(unix: UInt32) throws -> Data {
        let record = HistoricalArchive.Record(
            schema: HistoricalArchive.schema,
            capturedAt: Date(timeIntervalSince1970: TimeInterval(unix)),
            source: "0x2f",
            layoutVersion: HistoricalArchive.layoutVersion,
            sequence: 24,
            command: 0x2f,
            unix7: unix,
            subsec11: 0,
            flash13: unix,
            payloadLength: 1,
            whoofHR17: 72,
            whoofRRNum18: 0,
            whoofRR19: [],
            kRR64: [],
            gravityX36: nil,
            gravityY40: nil,
            gravityZ44: nil,
            gravityMagnitude: nil,
            gravityValidated: false,
            candidateRR: [],
            rawPayloadHex: "00",
            clockDeviceRef: unix,
            clockWallRef: unix,
            clockDriftSeconds: 0,
            clockCorrectedUnix7: unix,
            clockCorrectionStatus: "clock_ref_present",
            currentSessionUsable: true,
            metricUsable: true,
            usabilityReason: "test_bootstrap"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(record)
        data.append(0x0A)
        return data
    }

    private func writeOversizeBootstrapFixture(
        to url: URL,
        terminalUnix: UInt32
    ) throws {
        let maximum = Int(
            HistoricalArchive.maximumAutomaticRecoveredDataIncrementalBytes
        )
        let paddingCount = 2_000
        let filler = Data((
            "{\"unix7\":1,\"padding\":\""
                + String(repeating: "a", count: paddingCount)
                + "\"}\n"
        ).utf8)
        var data = Data()
        data.reserveCapacity(maximum + filler.count + 1_024)
        while data.count <= maximum + 1_024 {
            data.append(filler)
        }
        data.append(try bootstrapHeartRateRecordLine(unix: terminalUnix))
        try data.write(to: url, options: .atomic)
    }

    private func descriptor(
        for url: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> AtriaHistoricalJSONLRecentScanner.FileDescriptor {
        let descriptors = AtriaHistoricalJSONLRecentScanner.descriptors(
            for: [url]
        )
        guard let descriptor = descriptors.first else {
            XCTFail("fixture must have a stable filesystem descriptor",
                    file: file,
                    line: line)
            throw ProjectionTestError.missingTicket
        }
        return descriptor
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
        let maximum = HistoricalArchive
            .maximumAutomaticRecoveredDataIncrementalBytes
        XCTAssertTrue(
            HistoricalArchive.automaticRecoveredDataProjectionPlanIsBounded(
                .incremental([
                    incrementalSource(
                        size: maximum / 2 + 1_000,
                        startOffset: 1_000
                    ),
                    incrementalSource(
                        size: maximum / 2 + 2_000,
                        startOffset: 2_000
                    ),
                ]),
                maximumIncrementalBytes: maximum
            )
        )
        XCTAssertFalse(
            HistoricalArchive.automaticRecoveredDataProjectionPlanIsBounded(
                .incremental([
                    incrementalSource(
                        size: maximum + 1_001,
                        startOffset: 1_000
                    ),
                ]),
                maximumIncrementalBytes: maximum
            ),
            "8 MiB boundary + 1 byte belongs to the guarded background lane"
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
        XCTAssertTrue(
            HistoricalArchive.automaticRecoveredDataProjectionPlanIsBounded(
                .rebuild([source]),
                maximumIncrementalBytes: 4_096,
                allowsBoundedRebuild: true
            ),
            "a genuinely cold first install may seed one fully bounded source"
        )
        XCTAssertFalse(
            HistoricalArchive.automaticRecoveredDataProjectionPlanIsBounded(
                .rebuild([
                    incrementalSource(size: 4_097, startOffset: 0),
                ]),
                maximumIncrementalBytes: 4_096,
                allowsBoundedRebuild: true
            ),
            "the cold rebuild authority is still byte-exact and inclusive"
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
        XCTAssertFalse(
            HistoricalArchive.automaticRecoveredDataProjectionPlanIsBounded(
                .incremental([
                    incrementalSource(
                        size: 1_024,
                        startOffset: 0,
                        hasStableIdentity: false
                    ),
                ]),
                maximumIncrementalBytes: 4_096
            ),
            "append-only authority requires stable filesystem identity"
        )
    }

    func testColdScannerAuthorityRestoresReuseAndExactEightMiBAppend() {
        let since = Date(timeIntervalSince1970: 1_800_000_000)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("jsonl")
            .standardizedFileURL
        let processedOffset: UInt64 = 4_096
        let authority = HistoricalArchive
            .AutomaticRecoveredDataCacheAuthority(
                version: HistoricalArchive
                    .AutomaticRecoveredDataCacheAuthority.schema,
                coveredSince: since.timeIntervalSince1970,
                sources: [.init(
                    path: url.path,
                    processedOffset: processedOffset,
                    modificationTime: 10,
                    resourceIdentifier: "stable-source"
                )]
            )
        let unchanged = AtriaHistoricalJSONLRecentScanner.FileDescriptor(
            url: url,
            size: processedOffset,
            modificationTime: 10,
            resourceIdentifier: "stable-source"
        )

        HistoricalArchive.resetRecoveredDataCacheForTesting()
        XCTAssertTrue(HistoricalArchive.restoreAutomaticRecoveredDataCacheAuthority(
            authority,
            since: since,
            descriptors: [unchanged]
        ))
        XCTAssertTrue(HistoricalArchive
            .automaticRecoveredDataProjectionHasBoundedIncrementalPlan(
                since: since,
                descriptors: [unchanged]
            ))

        HistoricalArchive.resetRecoveredDataCacheForTesting()
        let maximum = HistoricalArchive
            .maximumAutomaticRecoveredDataIncrementalBytes
        let appended = AtriaHistoricalJSONLRecentScanner.FileDescriptor(
            url: url,
            size: processedOffset + maximum,
            modificationTime: 11,
            resourceIdentifier: "stable-source"
        )
        XCTAssertTrue(HistoricalArchive.restoreAutomaticRecoveredDataCacheAuthority(
            authority,
            since: since,
            descriptors: [appended]
        ))
        guard case .incremental(let sources) = HistoricalArchive
            .automaticRecoveredDataCacheAuthorityRestorationPlan(
                authority,
                since: since,
                descriptors: [appended]
            ) else {
            HistoricalArchive.resetRecoveredDataCacheForTesting()
            return XCTFail("expected exact append-only tail")
        }
        XCTAssertEqual(sources.map(\.startOffset), [processedOffset])
        XCTAssertEqual(sources.map(\.descriptor.size), [processedOffset + maximum])
        HistoricalArchive.resetRecoveredDataCacheForTesting()
    }

    func testColdScannerAuthorityNeverAdvancesToLaterFingerprintEOF() {
        let since = Date(timeIntervalSince1970: 1_800_000_000)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("jsonl")
            .standardizedFileURL
        let scanEOF: UInt64 = 8_192
        let laterFingerprintEOF: UInt64 = scanEOF + 2_048
        let authority = HistoricalArchive
            .AutomaticRecoveredDataCacheAuthority(
                version: HistoricalArchive
                    .AutomaticRecoveredDataCacheAuthority.schema,
                coveredSince: since.timeIntervalSince1970,
                sources: [.init(
                    path: url.path,
                    processedOffset: scanEOF,
                    modificationTime: 10,
                    resourceIdentifier: "same-inode"
                )]
            )
        let descriptor = AtriaHistoricalJSONLRecentScanner.FileDescriptor(
            url: url,
            size: laterFingerprintEOF,
            modificationTime: 11,
            resourceIdentifier: "same-inode"
        )

        guard case .incremental(let sources) = HistoricalArchive
            .automaticRecoveredDataCacheAuthorityRestorationPlan(
                authority,
                since: since,
                descriptors: [descriptor]
            ) else { return XCTFail("post-scan append must remain readable") }
        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(
            sources[0].startOffset,
            scanEOF,
            "a later source fingerprint may validate growth but cannot skip the row appended after the successful scan"
        )
        XCTAssertEqual(
            sources[0].descriptor.size - sources[0].startOffset,
            2_048
        )
    }

    func testColdCheckpointBaseIsUnionedWithIncrementalSessionAndHeartRateDelta() {
        let baseStart = Date(timeIntervalSince1970: 1_800_000_000)
        let deltaStart = baseStart.addingTimeInterval(600)
        let base = SavedSession(
            id: UUID(),
            start: baseStart,
            end: baseStart.addingTimeInterval(300),
            label: "Recovered wear",
            points: [.init(t: 0, bpm: 60)],
            respiratoryRate: nil,
            rrPoints: []
        )
        let delta = SavedSession(
            id: UUID(),
            start: deltaStart,
            end: deltaStart.addingTimeInterval(300),
            label: "Recovered wear",
            points: [.init(t: 0, bpm: 70)],
            respiratoryRate: nil,
            rrPoints: []
        )
        let sessions = SessionStore.mergedAutomaticallyRecoveredSessions(
            previous: [base],
            incoming: [delta]
        )
        XCTAssertEqual(Set(sessions.map(\.id)), Set([base.id, delta.id]))

        let sharedTimestamp = baseStart.addingTimeInterval(60)
        let heartRate = SessionStore
            .mergedAutomaticallyRecoveredHeartRatePoints(
                previous: [
                    .init(t: baseStart, bpm: 60),
                    .init(t: sharedTimestamp, bpm: 61),
                ],
                incoming: [
                    .init(t: sharedTimestamp, bpm: 71),
                    .init(t: deltaStart, bpm: 72),
                ]
            )
        XCTAssertEqual(heartRate, [
            .init(t: baseStart, bpm: 60),
            .init(t: sharedTimestamp, bpm: 71),
            .init(t: deltaStart, bpm: 72),
        ])
    }

    func testColdScannerAuthorityFailsClosedForOversizeReplacementTruncationAndCompression() {
        let since = Date(timeIntervalSince1970: 1_800_000_000)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("jsonl")
            .standardizedFileURL
        let offset: UInt64 = 4_096
        let authority = HistoricalArchive
            .AutomaticRecoveredDataCacheAuthority(
                version: HistoricalArchive
                    .AutomaticRecoveredDataCacheAuthority.schema,
                coveredSince: since.timeIntervalSince1970,
                sources: [.init(
                    path: url.path,
                    processedOffset: offset,
                    modificationTime: 10,
                    resourceIdentifier: "original"
                )]
            )
        func plan(
            url candidateURL: URL = url,
            size: UInt64,
            modified: TimeInterval,
            identity: String
        ) -> AtriaHistoricalJSONLRecentScanner.Plan? {
            HistoricalArchive
                .automaticRecoveredDataCacheAuthorityRestorationPlan(
                    authority,
                    since: since,
                    descriptors: [.init(
                        url: candidateURL,
                        size: size,
                        modificationTime: modified,
                        resourceIdentifier: identity
                    )]
                )
        }
        let maximum = HistoricalArchive
            .maximumAutomaticRecoveredDataIncrementalBytes
        XCTAssertNil(plan(
            size: offset + maximum + 1,
            modified: 11,
            identity: "original"
        ))
        XCTAssertNil(plan(
            size: offset + 1,
            modified: 11,
            identity: "replacement"
        ))
        XCTAssertNil(plan(
            size: offset - 1,
            modified: 11,
            identity: "original"
        ))
        XCTAssertNil(plan(
            url: url.deletingPathExtension().appendingPathExtension(
                AtriaHistoricalSealedJSONLCompression.artifactExtension
            ),
            size: offset + 1,
            modified: 11,
            identity: "original"
        ))
    }

    func testNoCheckpointOversizeBootstrapResumesAcrossProcessAndPublishesCurrentEvidence()
        throws {
        let directory = temporaryProjectionDirectory()
        let sourceURL = directory.appendingPathComponent("current.jsonl")
        let checkpointURL = directory.appendingPathComponent("bootstrap.plist")
        let terminalUnix: UInt32 = 1_800_000_000
        let since = Date(timeIntervalSince1970: TimeInterval(terminalUnix - 60))
        try writeOversizeBootstrapFixture(
            to: sourceURL,
            terminalUnix: terminalUnix
        )
        let sourceDescriptor = try descriptor(for: sourceURL)
        let maximum = HistoricalArchive
            .maximumAutomaticRecoveredDataIncrementalBytes
        XCTAssertGreaterThan(sourceDescriptor.size, maximum)

        HistoricalArchive.resetRecoveredDataCacheForTesting()
        let first = HistoricalArchive
            .performAutomaticRecoveredDataBootstrapStepForTesting(
                since: since,
                descriptors: { [sourceDescriptor] },
                checkpointURL: checkpointURL,
                maximumBytesPerStep: maximum
            )
        guard case .progressed(let firstRead, let remaining) = first else {
            return XCTFail("first >8 MiB pass must persist and yield: \(first)")
        }
        XCTAssertLessThanOrEqual(UInt64(firstRead), maximum)
        XCTAssertGreaterThan(remaining, 0)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: checkpointURL.path
        ))

        // A new process has no in-memory recovered cache. The durable cursor
        // must resume near the tail, not reread the first 8 MiB.
        HistoricalArchive.resetRecoveredDataCacheForTesting()
        let second = HistoricalArchive
            .performAutomaticRecoveredDataBootstrapStepForTesting(
                since: since,
                descriptors: { [sourceDescriptor] },
                checkpointURL: checkpointURL,
                maximumBytesPerStep: maximum
            )
        guard case .ready(let secondRead) = second else {
            return XCTFail("relaunch must finish the retained tail: \(second)")
        }
        XCTAssertLessThanOrEqual(UInt64(secondRead), maximum)
        XCTAssertLessThan(
            secondRead,
            128 * 1_024,
            "the persisted complete-line cursor must prevent an 8 MiB reread"
        )

        let snapshot = runProjectionOffMain {
            HistoricalArchive
                .makeAutomaticallyAdmittedRecoveredDataSnapshotForTesting(
                    since: since,
                    descriptors: [sourceDescriptor]
                )
        }
        XCTAssertEqual(snapshot?.scan.byteCount, 0)
        XCTAssertEqual(snapshot?.heartRatePoints, [
            .init(
                t: Date(timeIntervalSince1970: TimeInterval(terminalUnix)),
                bpm: 72
            ),
        ])
        XCTAssertEqual(snapshot?.physiologyCompleteness, .complete)
        XCTAssertNotNil(snapshot?.automaticCacheAuthority)
    }

    func testBootstrapWorkerRevalidationRejectsReplacementTruncationAndCompression()
        throws {
        let directory = temporaryProjectionDirectory()
        let sourceURL = directory.appendingPathComponent("current.jsonl")
        try writeOversizeBootstrapFixture(
            to: sourceURL,
            terminalUnix: 1_800_000_000
        )
        let initial = try descriptor(for: sourceURL)
        let since = Date(timeIntervalSince1970: 1_799_999_940)
        let maximum = HistoricalArchive
            .maximumAutomaticRecoveredDataIncrementalBytes

        func run(
            name: String,
            final: AtriaHistoricalJSONLRecentScanner.FileDescriptor
        ) -> HistoricalArchive.AutomaticRecoveredDataBootstrapStepResult {
            HistoricalArchive.resetRecoveredDataCacheForTesting()
            let checkpointURL = directory
                .appendingPathComponent("\(name).plist")
            var offerCount = 0
            return HistoricalArchive
                .performAutomaticRecoveredDataBootstrapStepForTesting(
                    since: since,
                    descriptors: {
                        offerCount += 1
                        return offerCount == 1 ? [initial] : [final]
                    },
                    checkpointURL: checkpointURL,
                    maximumBytesPerStep: maximum
                )
        }

        let replacement = AtriaHistoricalJSONLRecentScanner.FileDescriptor(
            url: initial.url,
            size: initial.size,
            modificationTime: initial.modificationTime + 1,
            resourceIdentifier: "replacement-inode"
        )
        XCTAssertEqual(
            run(name: "replacement", final: replacement),
            .invalidated(reason: "source_replaced")
        )
        let truncation = AtriaHistoricalJSONLRecentScanner.FileDescriptor(
            url: initial.url,
            size: initial.size - 1,
            modificationTime: initial.modificationTime + 1,
            resourceIdentifier: initial.resourceIdentifier
        )
        XCTAssertEqual(
            run(name: "truncation", final: truncation),
            .invalidated(reason: "source_truncated")
        )
        let compressed = AtriaHistoricalJSONLRecentScanner.FileDescriptor(
            url: initial.url.deletingPathExtension().appendingPathExtension(
                AtriaHistoricalSealedJSONLCompression.artifactExtension
            ),
            size: initial.size,
            modificationTime: initial.modificationTime,
            resourceIdentifier: initial.resourceIdentifier
        )
        XCTAssertEqual(
            run(name: "compressed", final: compressed),
            .invalidated(reason: "source_image_unbounded_or_compressed")
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

    func testAutomaticCurrentCycleTicketStartsOnlyBoundedPublicationComponent()
        throws {
        var coordinator = AtriaRecoveredDataRecomputeCoordinator()
        let cutoff = Date(timeIntervalSince1970: 12_345)
        let ticket = try recoveredProjectionTicket(coordinator.request(
            archiveRevision: 1,
            reason: "archive_did_update",
            scope: .automaticCurrentCycle(since: cutoff)
        ))

        XCTAssertEqual(ticket.scope, .automaticCurrentCycle(since: cutoff))
        let effects = coordinator.projectionCompleted(ticket: ticket)
        guard effects.count == 1,
              case .startDerived(let derivedTicket, let components) = effects[0]
        else {
            return XCTFail("expected the bounded derived publication component")
        }
        XCTAssertEqual(derivedTicket, ticket)
        XCTAssertEqual(components, [.currentCycleAndLatestNight])
        XCTAssertTrue(
            components.isDisjoint(
                with: AtriaRecoveredDataRecomputeCoordinator
                    .sessionStoreComponents
            ),
            "automatic publication cannot enter any full/global component"
        )
    }

    func testRecoveredCurrentCheckpointAcceptsOnlyStableOrAppendOnlySources() {
        let jsonlPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("checkpoint.jsonl").path
        let compressedPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("checkpoint")
            .appendingPathExtension(
                AtriaHistoricalSealedJSONLCompression.artifactExtension
            ).path
        func source(
            path: String = jsonlPath,
            size: UInt64,
            modified: Int64,
            identity: String = "same"
        ) -> HistoricalArchive.ConsumerSourceFingerprint.Source {
            .init(
                path: path,
                size: size,
                modificationTimeMilliseconds: modified,
                resourceIdentifier: identity
            )
        }
        func fingerprint(
            _ source: HistoricalArchive.ConsumerSourceFingerprint.Source
        ) -> HistoricalArchive.ConsumerSourceFingerprint {
            .init(catalogGeneration: 1, sources: [source])
        }
        let previous = fingerprint(source(size: 1_000, modified: 10))

        XCTAssertTrue(SessionStore.recoveredCurrentCheckpointSourceIsReusable(
            previous: previous,
            current: fingerprint(source(size: 1_000, modified: 10))
        ))
        XCTAssertTrue(SessionStore.recoveredCurrentCheckpointSourceIsReusable(
            previous: previous,
            current: fingerprint(source(size: 1_100, modified: 11))
        ), "ordinary JSONL growth is append-only compatible")
        XCTAssertFalse(SessionStore.recoveredCurrentCheckpointSourceIsReusable(
            previous: previous,
            current: fingerprint(source(size: 999, modified: 11))
        ), "truncation invalidates the compact checkpoint")
        XCTAssertFalse(SessionStore.recoveredCurrentCheckpointSourceIsReusable(
            previous: previous,
            current: fingerprint(source(
                size: 1_000,
                modified: 10,
                identity: "replacement"
            ))
        ))
        let unidentified = HistoricalArchive.ConsumerSourceFingerprint(
            catalogGeneration: 1,
            sources: [.init(
                path: jsonlPath,
                size: 1_000,
                modificationTimeMilliseconds: 10,
                resourceIdentifier: nil
            )]
        )
        XCTAssertFalse(SessionStore.recoveredCurrentCheckpointSourceIsReusable(
            previous: unidentified,
            current: .init(
                catalogGeneration: 1,
                sources: [.init(
                    path: jsonlPath,
                    size: 1_100,
                    modificationTimeMilliseconds: 11,
                    resourceIdentifier: nil
                )]
            )
        ), "growth without stable filesystem identity is not proven append-only")
        XCTAssertFalse(SessionStore.recoveredCurrentCheckpointSourceIsReusable(
            previous: fingerprint(source(
                path: compressedPath,
                size: 1_000,
                modified: 10
            )),
            current: fingerprint(source(
                path: compressedPath,
                size: 1_100,
                modified: 11
            ))
        ), "compressed growth is never append-only authority")
    }

    func testMetadataAdmissionPrecedesBoundedProjectionAndMotionUsesEventualSafeLane()
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
        let metadataOffer = try XCTUnwrap(request.range(
            of: "scheduleAutomaticRecoveredDataProjectionAdmission("
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
            metadataOffer.lowerBound,
            revisionFence.lowerBound,
            "ordinary freshness must schedule metadata before minting a revision"
        )
        XCTAssertLessThan(
            metadataOffer.lowerBound,
            coordinatorRequest.lowerBound,
            "ordinary freshness must schedule metadata before a ticket exists"
        )
        XCTAssertLessThan(
            coordinatorRequest.lowerBound,
            workoutRehydrationOffer.lowerBound,
            "projection ownership must exist before workout repair is offered"
        )
        let admissionStart = try XCTUnwrap(sessions.range(
            of: "private func scheduleAutomaticRecoveredDataProjectionAdmission("
        ))
        let admissionEnd = try XCTUnwrap(sessions.range(
            of: "nonisolated static func shouldStartAutomaticArchiveProjection(",
            range: admissionStart.upperBound..<sessions.endIndex
        ))
        let admission = String(
            sessions[admissionStart.lowerBound..<admissionEnd.lowerBound]
        )
        let metadataPreflight = try XCTUnwrap(admission.range(
            of: "automaticRecoveredDataProjectionHasBoundedIncrementalPlan("
        ))
        let admittedRequest = try XCTUnwrap(admission.range(
            of: "requestRecoveredDataRecomputation("
        ))
        XCTAssertLessThan(metadataPreflight.lowerBound, admittedRequest.lowerBound)
        XCTAssertTrue(admission.contains(
            "automaticCurrentCycleCutoff: cutoff"
        ))
        XCTAssertTrue(admission.contains(
            "status=reserved_metadata_plan"
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
            "handleAutomaticRecoveredArchiveDidUpdate()"
        ))
        XCTAssertFalse(observer.contains(
            "requestRecoveredDataRecomputation("
        ), "a raw ACK notification must first pass cadence/ownership coalescing")
        XCTAssertTrue(observer.contains(
            "reserveArchiveCompactionForSafeBackground()"
        ))
        XCTAssertFalse(observer.contains(
            "compactHistoricalArchiveIfUseful("
        ), "archive callbacks must only retain a future BGProcessing intent")
        XCTAssertTrue(sessions.contains(
            "scheduleAutomaticRecoveredDataProjectionAdmission("
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
            of: "if !Self.shouldExecuteAutomaticFullBackgroundProjection() {"
        ))
        let throttleBegin = try XCTUnwrap(fullBackground.range(
            of: "AtriaBackgroundProjectionThrottle.shared.begin("
        ))
        let boundedBootstrapRequest = try XCTUnwrap(fullBackground.range(
            of: "bg_projection_current_window_bootstrap_"
        ))
        XCTAssertLessThan(fullBackgroundFence.lowerBound, throttleBegin.lowerBound)
        XCTAssertLessThan(
            fullBackgroundFence.lowerBound,
            boundedBootstrapRequest.lowerBound
        )
        XCTAssertTrue(fullBackground.contains(
            "automaticCurrentCycleCutoff: cutoff"
        ))
        XCTAssertTrue(fullBackground.contains(
            "scope=current_window_bootstrap"
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
        XCTAssertTrue(worker.contains(
            "if automaticCurrentCycleCutoff == nil"
        ))
        XCTAssertTrue(worker.contains("HistoricalArchive.diagnostics()"))
        XCTAssertFalse(worker.contains(
            "automaticRecoveredDataProjectionHasBoundedIncrementalPlan("
        ), "the worker performs authoritative admission, not another metadata offer")
        XCTAssertTrue(worker.contains(
            "makeAutomaticallyAdmittedRecoveredDataSnapshot("
        ))
        XCTAssertTrue(worker.contains(
            "projectionReservedForSafeBackground(ticket: ticket)"
        ))

        let boundedStepStart = try XCTUnwrap(sessions.range(
            of: "private func runRecoveredCurrentCyclePublicationStep("
        ))
        let boundedStepEnd = try XCTUnwrap(sessions.range(
            of: "private func runRecoveredArchiveStatusStep(",
            range: boundedStepStart.upperBound..<sessions.endIndex
        ))
        let boundedStep = String(
            sessions[boundedStepStart.lowerBound..<boundedStepEnd.lowerBound]
        )
        XCTAssertTrue(boundedStep.contains("evaluationLookbackDays: 2"))
        XCTAssertTrue(boundedStep.contains("maximumEvaluationSessions: 192"))
        XCTAssertTrue(boundedStep.contains("autoConfirmLimit: 1"))
        XCTAssertTrue(boundedStep.contains("SleepHistorySnapshot("))
        for forbidden in [
            "HistoricalArchive.diagnostics(",
            "refreshHistorySnapshotCache(",
            "scheduleConfirmedWorkoutArchiveRehydration(",
            "refreshOverviewTrendPointsCache(",
            "refreshTrainingLoadSummaryCache(",
            "refreshTodayHRZoneMinutesCache(",
            "recomputeBehaviorInsights(",
        ] {
            XCTAssertFalse(
                boundedStep.contains(forbidden),
                "bounded current publication must not reach \(forbidden)"
            )
        }

        let app = try String(
            contentsOf: sourcesURL.appendingPathComponent("AtriaApp.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(app.contains(
            "|| SessionStore.automaticRecoveredDataBootstrapIntentIsPending"
        ), "a retained multi-pass bootstrap must keep BGProcessing scheduled")
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

    func testConnectedRawPublicationYieldIsCompactFirstAndCannotEnterFullProjection()
        throws {
        let testsURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        let sourcesURL = testsURL.deletingLastPathComponent()
            .appendingPathComponent("Atria")
        let sessions = try String(
            contentsOf: sourcesURL.appendingPathComponent("Sessions.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(sessions.range(
            of: "func performConnectedRawCatchUpPublicationYield("
        ))
        let end = try XCTUnwrap(sessions.range(
            of: "/// Release the background projection throttle",
            range: start.upperBound..<sessions.endIndex
        ))
        let body = String(sessions[start.lowerBound..<end.lowerBound])
        let compact = try XCTUnwrap(body.range(
            of: "refreshCurrentCycleStrapStepReceipt("
        ))
        let environment = try XCTUnwrap(body.range(
            of: "shouldStartConnectedRawCatchUpPublicationYield("
        ))
        let boundedBootstrap = try XCTUnwrap(body.range(
            of: "requestConnectedRawCatchUpBoundedProjection("
        ))
        XCTAssertLessThan(compact.lowerBound, environment.lowerBound)
        XCTAssertLessThan(environment.lowerBound, boundedBootstrap.lowerBound)
        XCTAssertFalse(body.contains("HistoricalArchive."))
        XCTAssertFalse(body.contains("requestRecoveredDataRecomputation("))
        XCTAssertFalse(body.contains("requestAndAwaitRecoveredDataPublication("))
        XCTAssertFalse(body.contains("compactHistoricalArchiveIfUseful("))

        let helperStart = try XCTUnwrap(sessions.range(
            of: "private func requestConnectedRawCatchUpBoundedProjection("
        ))
        let helperEnd = try XCTUnwrap(sessions.range(
            of: "/// Gives app-facing current-cycle evidence one finite turn",
            range: helperStart.upperBound..<sessions.endIndex
        ))
        let helper = String(
            sessions[helperStart.lowerBound..<helperEnd.lowerBound]
        )
        XCTAssertTrue(helper.contains(
            "reason: \"bg_projection_current_window_bootstrap_\\(reason)\""
        ))
        XCTAssertTrue(helper.contains(
            "backgroundProjectionAllowed: true"
        ))
        XCTAssertTrue(helper.contains(
            "automaticCurrentCycleCutoff: cutoff"
        ))
        XCTAssertFalse(helper.contains("scope: .full"))
        XCTAssertFalse(helper.contains("HistoricalArchive."))

        let app = try String(
            contentsOf: sourcesURL.appendingPathComponent("AtriaApp.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(app.contains(
            "ble.onConnectedRawCatchUpPublicationYield ="
        ))
        XCTAssertTrue(app.contains(
            "store.performConnectedRawCatchUpPublicationYield("
        ))
        XCTAssertTrue(app.contains(
            "ble.connectedRawCatchUpPublicationYieldIsNeeded ="
        ))
        XCTAssertTrue(app.contains(
            "store?.connectedRawCatchUpPublicationYieldIsNeeded() ?? false"
        ))
        XCTAssertTrue(app.contains(
            ".releaseConnectedRawCatchUpPublicationYieldForLifecycle("
        ))
        XCTAssertTrue(app.contains(
            ".offerConnectedRawCatchUpPublicationYieldIfNeeded("
        ))
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

    func testCompletingOnboardingReplaysRetainedRecoveredProjectionAfterProfileSave()
        throws {
        let testsURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        let sessionsURL = testsURL.deletingLastPathComponent()
            .appendingPathComponent("Atria/Sessions.swift")
        let source = try String(contentsOf: sessionsURL, encoding: .utf8)
        let start = try XCTUnwrap(source.range(
            of: "func completeOnboarding(with profile: AthleteProfile)"
        ))
        let end = try XCTUnwrap(source.range(
            of: "func completeOnboardingFromLaunchIfRequested(",
            range: start.upperBound..<source.endIndex
        ))
        let body = String(source[start.lowerBound..<end.lowerBound])
        let save = try XCTUnwrap(body.range(of: "self.profile.save()"))
        let resume = try XCTUnwrap(body.range(
            of: "resumeDeferredRecoveredDataRecomputation("
        ))
        XCTAssertLessThan(save.lowerBound, resume.lowerBound)
        XCTAssertTrue(body.contains("reason: \"onboarding_completed\""))
        XCTAssertTrue(body.contains(
            "Self.automaticRecoveredDataBootstrapIntentIsPending"
        ))
        XCTAssertTrue(body.contains(
            "reason: \"deferred_session_load_after_onboarding\""
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
