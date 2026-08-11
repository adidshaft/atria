import XCTest
import UIKit
@testable import Atria

final class AtriaBackgroundProjectionTests: XCTestCase {

    private final class RevokingCheckpoint: @unchecked Sendable {
        private let lock = NSLock()
        private let acceptedChecks: Int
        private(set) var visits = 0

        init(acceptedChecks: Int) {
            self.acceptedChecks = acceptedChecks
        }

        func shouldContinue() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            visits += 1
            return visits <= acceptedChecks
        }
    }

    private final class ThrottleClock: @unchecked Sendable {
        private let lock = NSLock()
        private var now: TimeInterval
        private(set) var requestedRest: TimeInterval = 0

        init(now: TimeInterval) {
            self.now = now
        }

        func uptime() -> TimeInterval {
            lock.lock()
            defer { lock.unlock() }
            return now
        }

        func advanceWork(by duration: TimeInterval) {
            lock.lock()
            now += duration
            lock.unlock()
        }

        func rest(for duration: TimeInterval) {
            lock.lock()
            requestedRest += duration
            now += duration
            lock.unlock()
        }

        func restDuration() -> TimeInterval {
            lock.lock()
            defer { lock.unlock() }
            return requestedRest
        }
    }

    private final class CacheInstallRaceState: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation = true
        private var installResult: Bool?
        private var readerResult: Bool?

        func shouldContinue() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return continuation
        }

        func revoke() {
            lock.lock()
            continuation = false
            lock.unlock()
        }

        func setInstallResult(_ value: Bool) {
            lock.lock()
            installResult = value
            lock.unlock()
        }

        func setReaderResult(_ value: Bool) {
            lock.lock()
            readerResult = value
            lock.unlock()
        }

        func results() -> (install: Bool?, reader: Bool?) {
            lock.lock()
            defer { lock.unlock() }
            return (installResult, readerResult)
        }
    }

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

    func testAutomaticDecodedBudgetRejectsPhysicalRetainedImageInOOneCounts() {
        let budget = HistoricalArchive.RecoveredDecodedWorkBudget
            .automaticForeground
        XCTAssertFalse(budget.admitsRetainedCounts(
            heartRate: 1_115_317,
            rr: 647_449,
            skin: 1_084_703,
            gravity: 750_000,
            motionIdentities: 750_000
        ))
        XCTAssertTrue(budget.admitsRetainedCounts(
            heartRate: 50_000,
            rr: 50_000,
            skin: 50_000,
            gravity: 50_000,
            motionIdentities: 50_000
        ))
        XCTAssertFalse(budget.admitsRetainedCounts(
            heartRate: 50_001,
            rr: 50_000,
            skin: 50_000,
            gravity: 50_000,
            motionIdentities: 50_000
        ), "the independent aggregate cap must reject before any element walk")
    }

    func testRecoveredDerivedWholeCorpusStagesAbortInsideElementLoops() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let points = (0..<8_192).map {
            SavedSession.Point(t: Double($0), bpm: 60 + ($0 % 4))
        }
        let rr = (0..<8_192).map {
            SavedSession.RRPoint(
                t: Double($0),
                ms: 980 + ($0 % 3) * 20,
                source: .standardHeartRateMeasurement2A37
            )
        }
        let session = SavedSession(
            id: UUID(),
            start: start,
            end: start.addingTimeInterval(Double(points.count)),
            label: "Recovered cancellation corpus",
            points: points,
            rrPoints: rr,
            sleepWakeResearchState: "sleep_research",
            eventTimeZoneIdentifier: "UTC"
        )
        let now = session.end.addingTimeInterval(60)

        let overview = RevokingCheckpoint(acceptedChecks: 4)
        XCTAssertNil(SessionStore.makeOverviewTrendPointsCancellable(
            sessions: [session],
            rest: 55,
            maxHR: 190,
            now: now,
            calendar: .current,
            shouldContinue: overview.shouldContinue
        ))

        let training = RevokingCheckpoint(acceptedChecks: 4)
        XCTAssertNil(SessionStore.makeTrainingLoadSummaryCancellable(
            sessions: [session],
            rest: 55,
            maxHR: 190,
            calendar: .current,
            shouldContinue: training.shouldContinue
        ))

        let zones = RevokingCheckpoint(acceptedChecks: 4)
        XCTAssertNil(SessionStore.makeTodayHRZoneMinutesCancellable(
            sessions: [session],
            rest: 55,
            maxHR: 190,
            now: now,
            cycleStart: start,
            calendar: .current,
            shouldContinue: zones.shouldContinue
        ))

        let respiration = RevokingCheckpoint(acceptedChecks: 4)
        XCTAssertNil(
            SessionStore.makeDailyRespiratoryRatePreparationCancellable(
                sessions: [session],
                rest: 55,
                maxHR: 190,
                calendar: .current,
                shouldContinue: respiration.shouldContinue
            )
        )

        let history = RevokingCheckpoint(acceptedChecks: 4)
        let historySession = SavedSession(
            id: UUID(),
            start: session.start,
            end: session.end,
            label: "Recovered cancellable history corpus",
            points: points,
            rrPoints: rr,
            eventTimeZoneIdentifier: "UTC"
        )
        XCTAssertNil(SessionStore.makeHistoryDetectionsCancellable(
            sessions: [historySession],
            confirmedWorkouts: [],
            rest: 55,
            maxHR: 190,
            calendar: .current,
            shouldContinue: history.shouldContinue
        ))
        XCTAssertLessThanOrEqual(overview.visits, 6)
        XCTAssertLessThanOrEqual(training.visits, 6)
        XCTAssertLessThanOrEqual(zones.visits, 6)
        XCTAssertLessThanOrEqual(respiration.visits, 6)
        XCTAssertLessThanOrEqual(history.visits, 6)
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

    private func bootstrapRRRecordLine(
        counter: UInt32,
        unix: UInt32
    ) throws -> Data {
        func writeUInt16LE(
            _ value: UInt16,
            at offset: Int,
            to bytes: inout [UInt8]
        ) {
            bytes[offset] = UInt8(truncatingIfNeeded: value)
            bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        }
        func writeUInt32LE(
            _ value: UInt32,
            at offset: Int,
            to bytes: inout [UInt8]
        ) {
            bytes[offset] = UInt8(truncatingIfNeeded: value)
            bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
            bytes[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
            bytes[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
        }
        var payload = [UInt8](repeating: 0, count: 80)
        payload[0] = 0x2f
        payload[1] = 24
        writeUInt32LE(counter, at: 3, to: &payload)
        writeUInt32LE(unix, at: 7, to: &payload)
        writeUInt16LE(0, at: 11, to: &payload)
        payload[17] = 72
        payload[18] = 1
        writeUInt16LE(800, at: 19, to: &payload)
        writeUInt32LE(Float(1).bitPattern, at: 44, to: &payload)
        let record = HistoricalArchive.Record(
            schema: HistoricalArchive.schema,
            capturedAt: Date(timeIntervalSince1970: TimeInterval(unix)),
            source: "0x2f",
            layoutVersion: HistoricalArchive.layoutVersion,
            sequence: 24,
            command: 0x2f,
            unix7: unix,
            subsec11: 0,
            flash13: counter,
            payloadLength: payload.count,
            whoofHR17: 72,
            whoofRRNum18: 1,
            whoofRR19: [800],
            kRR64: [],
            gravityX36: 0,
            gravityY40: 0,
            gravityZ44: 1,
            gravityMagnitude: 1,
            gravityValidated: true,
            candidateRR: [],
            rawPayloadHex: payload.map {
                String(format: "%02x", $0)
            }.joined(),
            clockDeviceRef: unix,
            clockWallRef: unix,
            clockDriftSeconds: 0,
            clockCorrectedUnix7: unix,
            clockCorrectionStatus: "clock_ref_present",
            currentSessionUsable: true,
            metricUsable: true,
            usabilityReason: "test_bootstrap_rr"
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

    private func writeBootstrapHeartRateFixture(
        to url: URL,
        firstUnix: UInt32,
        count: Int
    ) throws {
        var data = Data()
        for offset in 0..<count {
            data.append(try bootstrapHeartRateRecordLine(
                unix: firstUnix + UInt32(offset)
            ))
        }
        try data.write(to: url, options: .atomic)
    }

    private func writeBootstrapRRFixture(
        to url: URL,
        firstUnix: UInt32,
        count: Int
    ) throws {
        var data = Data()
        for offset in 0..<count {
            data.append(try bootstrapRRRecordLine(
                counter: UInt32(10_000 + offset),
                unix: firstUnix + UInt32(offset)
            ))
        }
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

    func testAutomaticUncompressedSourceStopsAtCandidateBudgetPlusOne()
        throws {
        HistoricalArchive.resetRecoveredDataCacheForTesting()
        defer { HistoricalArchive.resetRecoveredDataCacheForTesting() }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent(
            "segments/raw-v2/candidates.jsonl"
        )
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var plaintext = Data()
        for offset in 0..<64 {
            plaintext.append(try bootstrapHeartRateRecordLine(
                unix: UInt32(1_800_000_000 + offset)
            ))
        }
        try plaintext.write(to: source)
        let sourceDescriptor = try descriptor(for: source)
        let completion = expectation(description: "automatic decoded cap")
        var result: HistoricalArchive.RecoveredDataSnapshot?
        var maximumCandidateVisits = 0
        var maximumDecodedRecords = 0
        DispatchQueue.global(qos: .utility).async {
            result = HistoricalArchive
                .makeAutomaticallyAdmittedRecoveredDataSnapshotForTesting(
                    since: Date(timeIntervalSince1970: 1_799_999_000),
                    descriptors: [sourceDescriptor],
                    decodedWorkBudget: .init(
                        maximumDecodedRecords: 5,
                        maximumCandidateLines: 5,
                        maximumRetainedChannelElements: 100,
                        maximumRetainedAggregateElements: 500
                    ),
                    onDecodedWorkCount: { candidates, decoded in
                        maximumCandidateVisits = max(
                            maximumCandidateVisits,
                            candidates
                        )
                        maximumDecodedRecords = max(
                            maximumDecodedRecords,
                            decoded
                        )
                    }
                )
            completion.fulfill()
        }
        wait(for: [completion], timeout: 5)
        XCTAssertNil(result)
        XCTAssertEqual(maximumCandidateVisits, 6)
        XCTAssertEqual(maximumDecodedRecords, 5)
    }

    func testFreshMixedChannelScanStopsBeforeAggregateCapAndInstallsNoCache()
        throws {
        HistoricalArchive.resetRecoveredDataCacheForTesting()
        defer { HistoricalArchive.resetRecoveredDataCacheForTesting() }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("mixed.jsonl")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        var data = Data()
        for offset in 0..<16 {
            data.append(try bootstrapHeartRateRecordLine(
                unix: UInt32(1_800_100_000 + offset)
            ))
        }
        try data.write(to: source, options: .atomic)
        let sourceDescriptor = try descriptor(for: source)
        let completion = expectation(description: "fresh aggregate cap")
        var result: HistoricalArchive.RecoveredDataSnapshot?
        var maximumDecodedRecords = 0
        var maximumRetainedAggregate = 0
        DispatchQueue.global(qos: .utility).async {
            result = HistoricalArchive
                .makeAutomaticallyAdmittedRecoveredDataSnapshotForTesting(
                    since: Date(timeIntervalSince1970: 1_800_099_000),
                    descriptors: [sourceDescriptor],
                    decodedWorkBudget: .init(
                        maximumDecodedRecords: 100,
                        maximumCandidateLines: 100,
                        maximumRetainedChannelElements: 100,
                        maximumRetainedAggregateElements: 5
                    ),
                    onDecodedWorkCount: { _, decoded in
                        maximumDecodedRecords = max(
                            maximumDecodedRecords,
                            decoded
                        )
                    },
                    onRetainedAggregateCount: { retained in
                        maximumRetainedAggregate = max(
                            maximumRetainedAggregate,
                            retained
                        )
                    }
                )
            completion.fulfill()
        }
        wait(for: [completion], timeout: 5)

        XCTAssertNil(result)
        XCTAssertLessThanOrEqual(maximumDecodedRecords, 3)
        XCTAssertLessThanOrEqual(maximumRetainedAggregate, 5)
        XCTAssertFalse(HistoricalArchive.recoveredDataCacheIsInstalledForTesting)
    }

    func testBootstrapMixedChannelsRejectAggregateCapPlusOneBeforeCacheInstall() {
        HistoricalArchive.resetRecoveredDataCacheForTesting()
        defer { HistoricalArchive.resetRecoveredDataCacheForTesting() }

        let heartRateCount = 125_000
        let rrCount = 125_001
        XCTAssertLessThanOrEqual(heartRateCount, 200_000)
        XCTAssertLessThanOrEqual(rrCount, 200_000)
        XCTAssertEqual(heartRateCount + rrCount, 250_001)

        XCTAssertFalse(
            HistoricalArchive
                .installAutomaticRecoveredDataBootstrapRetainedCountsForTesting(
                    heartRate: heartRateCount,
                    rr: rrCount,
                    skin: 0,
                    gravity: 0
                )
        )
        XCTAssertFalse(
            HistoricalArchive.recoveredDataCacheIsInstalledForTesting,
            "the independent aggregate gate must reject cap+1 before publication"
        )
    }

    func testRecoveredCacheBudgetCompatibilityIsStrictlyDirectional() {
        XCTAssertTrue(
            HistoricalArchive.recoveredProjectionCacheBudgetIsReusable(
                cached: .automaticForeground,
                requested: .production,
                hasTruncatedChannels: false
            ),
            "a complete stricter bootstrap image may feed its production BG continuation"
        )
        XCTAssertFalse(
            HistoricalArchive.recoveredProjectionCacheBudgetIsReusable(
                cached: .production,
                requested: .automaticForeground,
                hasTruncatedChannels: false
            ),
            "production-sized state may never bypass automatic admission"
        )
        XCTAssertFalse(
            HistoricalArchive.recoveredProjectionCacheBudgetIsReusable(
                cached: .automaticForeground,
                requested: .production,
                hasTruncatedChannels: true
            ),
            "a stricter cache can widen only when it represents a complete image"
        )
    }

    func testProductionCacheCannotBeReusedByAutomaticPlanner() throws {
        HistoricalArchive.resetRecoveredDataCacheForTesting()
        defer { HistoricalArchive.resetRecoveredDataCacheForTesting() }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let source = root.appendingPathComponent("production-cache.jsonl")
        try bootstrapHeartRateRecordLine(unix: 1_800_352_000)
            .write(to: source, options: .atomic)
        let descriptor = try descriptor(for: source)
        let since = Date(timeIntervalSince1970: 1_800_351_000)

        let production = runProjectionOffMain {
            HistoricalArchive.makeProductionRecoveredDataSnapshotForTesting(
                since: since,
                descriptors: [descriptor]
            )
        }
        XCTAssertNotNil(production)
        XCTAssertGreaterThan(production?.scan.byteCount ?? 0, 0)

        let automatic = runProjectionOffMain {
            HistoricalArchive
                .makeAutomaticallyAdmittedRecoveredDataSnapshotForTesting(
                    since: since,
                    descriptors: [descriptor]
                )
        }
        XCTAssertNil(
            automatic,
            "automatic admission must not inherit even a small production-tagged cache"
        )
    }

    func testBootstrapCacheIsNeverObservableBeforeAuthorityCommit() {
        HistoricalArchive.resetRecoveredDataCacheForTesting()
        defer { HistoricalArchive.resetRecoveredDataCacheForTesting() }
        let state = CacheInstallRaceState()
        let provisionalInstalled = DispatchSemaphore(value: 0)
        let releaseInstaller = DispatchSemaphore(value: 0)
        let installerCompleted = DispatchSemaphore(value: 0)
        let readerStarted = DispatchSemaphore(value: 0)
        let readerCompleted = DispatchSemaphore(value: 0)

        DispatchQueue.global(qos: .utility).async {
            let installed = HistoricalArchive
                .installAutomaticRecoveredDataBootstrapRetainedCountsForTesting(
                    heartRate: 1,
                    rr: 0,
                    skin: 0,
                    gravity: 0,
                    shouldContinue: { state.shouldContinue() },
                    onInstalled: {
                        provisionalInstalled.signal()
                        releaseInstaller.wait()
                    }
                )
            state.setInstallResult(installed)
            installerCompleted.signal()
        }
        XCTAssertEqual(
            provisionalInstalled.wait(timeout: .now() + 3),
            .success
        )

        DispatchQueue.global(qos: .utility).async {
            readerStarted.signal()
            state.setReaderResult(
                HistoricalArchive.recoveredDataCacheIsInstalledForTesting
            )
            readerCompleted.signal()
        }
        XCTAssertEqual(readerStarted.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(
            readerCompleted.wait(timeout: .now() + 0.1),
            .timedOut,
            "the provisional cache must remain behind the publication lock"
        )

        state.revoke()
        releaseInstaller.signal()
        XCTAssertEqual(installerCompleted.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(readerCompleted.wait(timeout: .now() + 3), .success)
        let results = state.results()
        XCTAssertEqual(results.install, false)
        XCTAssertEqual(
            results.reader,
            false,
            "the first external reader may observe only the rolled-back image"
        )
    }

    func testRecoveredArchiveSortRevocationInstallsNoSnapshotOrCache() throws {
        HistoricalArchive.resetRecoveredDataCacheForTesting()
        defer { HistoricalArchive.resetRecoveredDataCacheForTesting() }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let source = root.appendingPathComponent("reverse.jsonl")
        var data = Data()
        for offset in (0..<2_000).reversed() {
            data.append(try bootstrapHeartRateRecordLine(
                unix: UInt32(1_800_300_000 + offset)
            ))
        }
        try data.write(to: source, options: .atomic)
        let sourceDescriptor = try descriptor(for: source)
        let completion = expectation(description: "archive sort revoked")
        var sorting = false
        var sortChecks = 0
        var result: HistoricalArchive.RecoveredDataSnapshot?
        DispatchQueue.global(qos: .utility).async {
            result = HistoricalArchive
                .makeAutomaticallyAdmittedRecoveredDataSnapshotForTesting(
                    since: Date(timeIntervalSince1970: 1_800_299_000),
                    descriptors: [sourceDescriptor],
                    decodedWorkBudget: .init(
                        maximumDecodedRecords: 10_000,
                        maximumCandidateLines: 10_000,
                        maximumRetainedChannelElements: 10_000,
                        maximumRetainedAggregateElements: 10_000
                    ),
                    executionShouldContinue: {
                        guard sorting else { return true }
                        sortChecks += 1
                        return sortChecks < 5
                    },
                    onStage: { stage in
                        if stage == "before_recovered_sort" { sorting = true }
                    }
                )
            completion.fulfill()
        }
        wait(for: [completion], timeout: 5)

        XCTAssertNil(result)
        XCTAssertEqual(sortChecks, 5)
        XCTAssertFalse(HistoricalArchive.recoveredDataCacheIsInstalledForTesting)
    }

    func testOrdinaryRecoveredCacheRevocationDuringInstallRollsBackOwnedImage()
        throws {
        HistoricalArchive.resetRecoveredDataCacheForTesting()
        defer { HistoricalArchive.resetRecoveredDataCacheForTesting() }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let source = root.appendingPathComponent("ordinary-install.jsonl")
        try bootstrapHeartRateRecordLine(unix: 1_800_350_000)
            .write(to: source, options: .atomic)
        let sourceDescriptor = try descriptor(for: source)
        var revoked = false

        let snapshot = runProjectionOffMain {
            HistoricalArchive
                .makeAutomaticallyAdmittedRecoveredDataSnapshotForTesting(
                    since: Date(timeIntervalSince1970: 1_800_349_000),
                    descriptors: [sourceDescriptor],
                    executionShouldContinue: { !revoked },
                    onStage: { stage in
                        if stage == "after_recovered_cache_install" {
                            revoked = true
                        }
                    }
                )
        }

        XCTAssertTrue(revoked)
        XCTAssertNil(snapshot)
        XCTAssertFalse(
            HistoricalArchive.recoveredDataCacheIsInstalledForTesting,
            "a revoked install owner must roll back its exact cache generation"
        )
    }

    func testStaleRecoveredCacheRollbackCannotEraseNewerReplacement()
        throws {
        HistoricalArchive.resetRecoveredDataCacheForTesting()
        defer { HistoricalArchive.resetRecoveredDataCacheForTesting() }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let source = root.appendingPathComponent("replacement-owner.jsonl")
        try bootstrapHeartRateRecordLine(unix: 1_800_351_000)
            .write(to: source, options: .atomic)
        let descriptor = try descriptor(for: source)

        let snapshot = runProjectionOffMain {
            HistoricalArchive
                .makeAutomaticallyAdmittedRecoveredDataSnapshotForTesting(
                    since: Date(timeIntervalSince1970: 1_800_350_000),
                    descriptors: [descriptor]
                )
        }
        XCTAssertNotNil(snapshot)
        XCTAssertTrue(HistoricalArchive.recoveredDataCacheIsInstalledForTesting)
        XCTAssertTrue(
            HistoricalArchive
                .staleRecoveredDataCacheRollbackPreservesReplacementForTesting(),
            "an old installer's unwind must not clear a newer generation/tag"
        )
        XCTAssertTrue(HistoricalArchive.recoveredDataCacheIsInstalledForTesting)
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
            HistoricalArchive.makeProductionRecoveredDataSnapshotForTesting(
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

    func testBootstrapRevocationImmediatelyBeforeCacheInstallDefersAndPublishesNoCache()
        throws {
        HistoricalArchive.resetRecoveredDataCacheForTesting()
        defer { HistoricalArchive.resetRecoveredDataCacheForTesting() }
        let directory = temporaryProjectionDirectory()
        let sourceURL = directory.appendingPathComponent("current.jsonl")
        try bootstrapHeartRateRecordLine(unix: 1_800_200_000)
            .write(to: sourceURL, options: .atomic)
        let sourceDescriptor = try descriptor(for: sourceURL)
        let checkpointURL = directory.appendingPathComponent("bootstrap.plist")
        var revoked = false

        let result = HistoricalArchive
            .performAutomaticRecoveredDataBootstrapStepForTesting(
                since: Date(timeIntervalSince1970: 1_800_199_000),
                descriptors: { [sourceDescriptor] },
                checkpointURL: checkpointURL,
                maximumBytesPerStep: HistoricalArchive
                    .maximumAutomaticRecoveredDataIncrementalBytes,
                shouldContinue: { !revoked },
                onStage: { stage in
                    if stage == "before_cache_install" { revoked = true }
                }
            )

        XCTAssertEqual(
            result,
            .deferred(reason: "background_authority_revoked")
        )
        XCTAssertFalse(HistoricalArchive.recoveredDataCacheIsInstalledForTesting)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: checkpointURL.path),
            "durable scan progress may survive even though this stale lease cannot install"
        )
    }

    func testBootstrapRevocationDuringCacheInstallRollsBackOwnedImageAndKeepsCheckpoint()
        throws {
        HistoricalArchive.resetRecoveredDataCacheForTesting()
        defer { HistoricalArchive.resetRecoveredDataCacheForTesting() }
        let directory = temporaryProjectionDirectory()
        let sourceURL = directory.appendingPathComponent("current.jsonl")
        try bootstrapHeartRateRecordLine(unix: 1_800_250_000)
            .write(to: sourceURL, options: .atomic)
        let sourceDescriptor = try descriptor(for: sourceURL)
        let checkpointURL = directory.appendingPathComponent("bootstrap.plist")
        var revoked = false

        let result = HistoricalArchive
            .performAutomaticRecoveredDataBootstrapStepForTesting(
                since: Date(timeIntervalSince1970: 1_800_249_000),
                descriptors: { [sourceDescriptor] },
                checkpointURL: checkpointURL,
                maximumBytesPerStep: HistoricalArchive
                    .maximumAutomaticRecoveredDataIncrementalBytes,
                shouldContinue: { !revoked },
                onStage: { stage in
                    if stage == "after_bootstrap_cache_install" {
                        revoked = true
                    }
                }
            )

        XCTAssertTrue(revoked)
        XCTAssertEqual(
            result,
            .deferred(reason: "background_authority_revoked")
        )
        XCTAssertFalse(
            HistoricalArchive.recoveredDataCacheIsInstalledForTesting,
            "the revoked bootstrap owner must remove its exact cache generation"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: checkpointURL.path),
            "revocation rolls back only reusable cache; durable scan intent survives"
        )
    }

    func testBootstrapCheckpointDecodeAndPruneRevocationRetainDurableProgress()
        throws {
        HistoricalArchive.resetRecoveredDataCacheForTesting()
        defer { HistoricalArchive.resetRecoveredDataCacheForTesting() }
        let directory = temporaryProjectionDirectory()
        let sourceURL = directory.appendingPathComponent("current.jsonl")
        let checkpointURL = directory.appendingPathComponent("bootstrap.plist")
        let firstUnix: UInt32 = 1_800_400_000
        try writeBootstrapRRFixture(
            to: sourceURL,
            firstUnix: firstUnix,
            count: 1_024
        )
        let sourceDescriptor = try descriptor(for: sourceURL)
        let initialSince = Date(
            timeIntervalSince1970: TimeInterval(firstUnix - 1)
        )
        XCTAssertEqual(
            HistoricalArchive
                .performAutomaticRecoveredDataBootstrapStepForTesting(
                    since: initialSince,
                    descriptors: { [sourceDescriptor] },
                    checkpointURL: checkpointURL,
                    maximumBytesPerStep: HistoricalArchive
                        .maximumAutomaticRecoveredDataIncrementalBytes
                ),
            .ready(readBytes: Int(sourceDescriptor.size))
        )
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: checkpointURL.path
        ))

        HistoricalArchive.resetRecoveredDataCacheForTesting()
        var decodeRevoked = false
        var observedDecodeCheckpoint = false
        let decodeResult = HistoricalArchive
            .performAutomaticRecoveredDataBootstrapStepForTesting(
                since: initialSince,
                descriptors: { [sourceDescriptor] },
                checkpointURL: checkpointURL,
                maximumBytesPerStep: HistoricalArchive
                    .maximumAutomaticRecoveredDataIncrementalBytes,
                shouldContinue: { !decodeRevoked },
                onCheckpointProgress: { stage, index in
                    if stage == "checkpoint_decode_heart_rate",
                       index == 256 {
                        observedDecodeCheckpoint = true
                        decodeRevoked = true
                    }
                }
            )
        XCTAssertTrue(observedDecodeCheckpoint)
        XCTAssertEqual(
            decodeResult,
            .deferred(reason: "background_authority_revoked")
        )
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: checkpointURL.path
        ), "decode cancellation must retain the prior atomic checkpoint")
        XCTAssertFalse(HistoricalArchive.recoveredDataCacheIsInstalledForTesting)

        var rrDecodeRevoked = false
        var observedRRDecodeCheckpoint = false
        let rrDecodeResult = HistoricalArchive
            .performAutomaticRecoveredDataBootstrapStepForTesting(
                since: initialSince,
                descriptors: { [sourceDescriptor] },
                checkpointURL: checkpointURL,
                maximumBytesPerStep: HistoricalArchive
                    .maximumAutomaticRecoveredDataIncrementalBytes,
                shouldContinue: { !rrDecodeRevoked },
                onCheckpointProgress: { stage, index in
                    if stage == "checkpoint_decode_rr", index == 256 {
                        observedRRDecodeCheckpoint = true
                        rrDecodeRevoked = true
                    }
                }
            )
        XCTAssertTrue(observedRRDecodeCheckpoint)
        XCTAssertEqual(
            rrDecodeResult,
            .deferred(reason: "background_authority_revoked")
        )
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: checkpointURL.path
        ), "nested RR decode cancellation must retain durable progress")
        XCTAssertFalse(HistoricalArchive.recoveredDataCacheIsInstalledForTesting)

        var pruneRevoked = false
        var observedPruneCheckpoint = false
        let pruneResult = HistoricalArchive
            .performAutomaticRecoveredDataBootstrapStepForTesting(
                since: Date(
                    timeIntervalSince1970: TimeInterval(firstUnix + 512)
                ),
                descriptors: { [sourceDescriptor] },
                checkpointURL: checkpointURL,
                maximumBytesPerStep: HistoricalArchive
                    .maximumAutomaticRecoveredDataIncrementalBytes,
                shouldContinue: { !pruneRevoked },
                onCheckpointProgress: { stage, index in
                    if stage == "checkpoint_prune_heart_rate",
                       index == 256 {
                        observedPruneCheckpoint = true
                        pruneRevoked = true
                    }
                }
            )
        XCTAssertTrue(observedPruneCheckpoint)
        XCTAssertEqual(
            pruneResult,
            .deferred(reason: "background_authority_revoked")
        )
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: checkpointURL.path
        ), "prune cancellation must not replace durable progress")
        XCTAssertFalse(HistoricalArchive.recoveredDataCacheIsInstalledForTesting)
    }

    func testBootstrapCheckpointEncodeAndWriteRevocationInstallNothing()
        throws {
        HistoricalArchive.resetRecoveredDataCacheForTesting()
        defer { HistoricalArchive.resetRecoveredDataCacheForTesting() }
        let directory = temporaryProjectionDirectory()
        let sourceURL = directory.appendingPathComponent("current.jsonl")
        let firstUnix: UInt32 = 1_800_500_000
        try writeBootstrapRRFixture(
            to: sourceURL,
            firstUnix: firstUnix,
            count: 1_024
        )
        let sourceDescriptor = try descriptor(for: sourceURL)
        let since = Date(timeIntervalSince1970: TimeInterval(firstUnix - 1))

        let encodeURL = directory.appendingPathComponent("encode.plist")
        var encodeRevoked = false
        var observedEncodeCheckpoint = false
        let encodeResult = HistoricalArchive
            .performAutomaticRecoveredDataBootstrapStepForTesting(
                since: since,
                descriptors: { [sourceDescriptor] },
                checkpointURL: encodeURL,
                maximumBytesPerStep: HistoricalArchive
                    .maximumAutomaticRecoveredDataIncrementalBytes,
                shouldContinue: { !encodeRevoked },
                onCheckpointProgress: { stage, index in
                    if stage == "checkpoint_encode_heart_rate",
                       index == 256 {
                        observedEncodeCheckpoint = true
                        encodeRevoked = true
                    }
                }
            )
        XCTAssertTrue(observedEncodeCheckpoint)
        XCTAssertEqual(
            encodeResult,
            .deferred(reason: "background_authority_revoked")
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: encodeURL.path))
        XCTAssertFalse(HistoricalArchive.recoveredDataCacheIsInstalledForTesting)

        let rrEncodeURL = directory.appendingPathComponent("rr-encode.plist")
        var rrEncodeRevoked = false
        var observedRREncodeCheckpoint = false
        let rrEncodeResult = HistoricalArchive
            .performAutomaticRecoveredDataBootstrapStepForTesting(
                since: since,
                descriptors: { [sourceDescriptor] },
                checkpointURL: rrEncodeURL,
                maximumBytesPerStep: HistoricalArchive
                    .maximumAutomaticRecoveredDataIncrementalBytes,
                shouldContinue: { !rrEncodeRevoked },
                onCheckpointProgress: { stage, index in
                    if stage == "checkpoint_encode_rr", index == 256 {
                        observedRREncodeCheckpoint = true
                        rrEncodeRevoked = true
                    }
                }
            )
        XCTAssertTrue(observedRREncodeCheckpoint)
        XCTAssertEqual(
            rrEncodeResult,
            .deferred(reason: "background_authority_revoked")
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: rrEncodeURL.path
        ))
        XCTAssertFalse(HistoricalArchive.recoveredDataCacheIsInstalledForTesting)

        let writeURL = directory.appendingPathComponent("write.plist")
        var writeRevoked = false
        var observedWriteCheckpoint = false
        let writeResult = HistoricalArchive
            .performAutomaticRecoveredDataBootstrapStepForTesting(
                since: since,
                descriptors: { [sourceDescriptor] },
                checkpointURL: writeURL,
                maximumBytesPerStep: HistoricalArchive
                    .maximumAutomaticRecoveredDataIncrementalBytes,
                shouldContinue: { !writeRevoked },
                onCheckpointProgress: { stage, index in
                    if stage == "checkpoint_write", index == 0 {
                        observedWriteCheckpoint = true
                        writeRevoked = true
                    }
                }
            )
        XCTAssertTrue(observedWriteCheckpoint)
        XCTAssertEqual(
            writeResult,
            .deferred(reason: "background_authority_revoked")
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: writeURL.path))
        XCTAssertFalse(HistoricalArchive.recoveredDataCacheIsInstalledForTesting)
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
        XCTAssertTrue(worker.contains(
            "guard let diagnostics = HistoricalArchive.diagnostics("
        ))
        XCTAssertTrue(worker.contains(
            "shouldContinue: executionShouldContinue"
        ))
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
            of: "requestBackgroundArchiveProjectionIfSafe(",
            range: hrStart.upperBound..<app.endIndex
        ))
        let projectionOwnerSet = try XCTUnwrap(app.range(
            of: "recoveredProjectionOwner.set(lease)",
            range: backgroundProjection.upperBound..<app.endIndex
        ))
        let backgroundProjectionCall = String(
            app[backgroundProjection.lowerBound..<projectionOwnerSet.lowerBound]
        )
        XCTAssertTrue(backgroundProjectionCall.contains(
            "reason: \"bg_projection\""
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

    func testRecoveredLifecycleRevocationAndBGLeaseRetirementPrecedeRestoreGuard()
        throws {
        let testsURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        let appURL = testsURL.deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaApp.swift")
        let source = try String(contentsOf: appURL, encoding: .utf8)
        let start = try XCTUnwrap(source.range(
            of: ".onChange(of: scenePhase)"
        ))
        let end = try XCTUnwrap(source.range(
            of: ".onChange(of: store.restoreInitializationBlocked)",
            range: start.upperBound..<source.endIndex
        ))
        let body = String(source[start.lowerBound..<end.lowerBound])
        let restoreGuard = try XCTUnwrap(body.range(
            of: "guard !store.restoreInitializationBlocked else { return }"
        ))
        let attendedEnd = try XCTUnwrap(body.range(
            of: "store.endBackgroundArchiveProjectionThrottle()"
        ))
        let suspend = try XCTUnwrap(body.range(
            of: "store.suspendRecoveredDataPublicationLeaseForBackground("
        ))
        let throttleEnd = try XCTUnwrap(body.range(
            of: "AtriaBackgroundProjectionThrottle.shared.end()"
        ))
        let invalidateBG = try XCTUnwrap(body.range(
            of: "invalidateRecoveredDataBackgroundExecutionLeaseForForeground("
        ))
        let resume = try XCTUnwrap(body.range(
            of: "store.resumeRecoveredDataPublicationLeaseForForeground("
        ))

        XCTAssertLessThan(attendedEnd.lowerBound, suspend.lowerBound)
        XCTAssertLessThan(suspend.lowerBound, restoreGuard.lowerBound)
        XCTAssertLessThan(throttleEnd.lowerBound, invalidateBG.lowerBound)
        XCTAssertLessThan(invalidateBG.lowerBound, restoreGuard.lowerBound)
        XCTAssertGreaterThan(resume.lowerBound, restoreGuard.lowerBound)
        XCTAssertEqual(
            body.components(separatedBy:
                "store.suspendRecoveredDataPublicationLeaseForBackground("
            ).count - 1,
            1
        )
        XCTAssertTrue(body.contains(
            "if releasedAttendedProjection {\n"
                + "                            store.endBackgroundArchiveProjectionThrottle()"
        ), "ordinary backgrounding must preserve an independently leased BGProcessing ticket")
    }

    func testRecoveredExecutionDiagnosticIsEdgeOnlyAndPullable() throws {
        var ring: [String: Any]?
        let eventCount = SessionStore.recoveredExecutionDiagnosticCapacity + 4
        for index in 0..<eventCount {
            let event: [String: Any] = [
                "generation": 7,
                "revision": 41,
                "scope": "automatic_current_cycle",
                "cutoff_unix_ms": 1_786_420_800_000,
                "has_cutoff": true,
                "authority": "foreground",
                "authority_kind": "foreground",
                "authority_id": 7,
                "foreground_token_generation": 7,
                "edge": index == 0 ? "admit" : "stage",
                "stage": index == 0 ? "admission" : "projection",
                "outcome": index == 0 ? "started" : "completed",
                "revoke_count": 0,
                "stale_rejection_count": 0,
                "stale": false,
                "published": false,
                "reason": "none",
                "request_reason": "archive_did_update",
                "at_unix_ms": 1_786_420_800_000 + index,
                "event_uptime_ms": 1_000 + index,
            ]
            ring = SessionStore.appendingRecoveredExecutionDiagnosticEvent(
                event,
                to: ring
            )
        }

        let unwrapped = try XCTUnwrap(ring)
        XCTAssertEqual(unwrapped["schema_version"] as? Int, 1)
        XCTAssertEqual(
            unwrapped["capacity"] as? Int,
            SessionStore.recoveredExecutionDiagnosticCapacity
        )
        XCTAssertEqual(unwrapped["next_sequence"] as? Int, eventCount)
        XCTAssertEqual(unwrapped["first_sequence"] as? Int, 4)
        XCTAssertEqual(unwrapped["watermark_sequence"] as? Int, 4)
        XCTAssertEqual(unwrapped["oldest_sequence"] as? Int, 4)
        XCTAssertEqual(unwrapped["latest_sequence"] as? Int, eventCount - 1)
        XCTAssertEqual(unwrapped["dropped_event_count"] as? Int, 4)
        XCTAssertEqual(unwrapped["overflow_count"] as? Int, 4)
        let events = try XCTUnwrap(unwrapped["events"] as? [[String: Any]])
        XCTAssertEqual(events.count,
                       SessionStore.recoveredExecutionDiagnosticCapacity)
        XCTAssertEqual(events.compactMap { $0["sequence"] as? Int },
                       Array(4..<eventCount))
        XCTAssertEqual(events.first?["authority_kind"] as? String,
                       "foreground")
        XCTAssertEqual(events.first?["authority"] as? String,
                       events.first?["authority_kind"] as? String)

        let testsURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        let sessionsURL = testsURL.deletingLastPathComponent()
            .appendingPathComponent("Atria/Sessions.swift")
        let source = try String(contentsOf: sessionsURL, encoding: .utf8)
        let start = try XCTUnwrap(source.range(
            of: "private func recordRecoveredExecutionEdge("
        ))
        let end = try XCTUnwrap(source.range(
            of: "private func recordStaleRecoveredExecutionCompletion(",
            range: start.upperBound..<source.endIndex
        ))
        let diagnostic = String(source[start.lowerBound..<end.lowerBound])
        for field in [
            "\"generation\"", "\"revision\"", "\"scope\"",
            "\"authority\"", "\"authority_kind\"", "\"edge\"",
            "\"stage\"", "\"outcome\"", "\"revoke_count\"",
            "\"stale_rejection_count\"", "\"stale\"",
            "\"published\"", "\"reason\"", "\"at_unix_ms\"",
            "\"event_uptime_ms\"",
        ] {
            XCTAssertTrue(diagnostic.contains(field), "missing \(field)")
        }
        XCTAssertTrue(diagnostic.contains(
            "Self.recoveredExecutionDiagnosticDefaultsKey"
        ))
        XCTAssertEqual(
            diagnostic.components(separatedBy: "defaults.set(").count - 1,
            1,
            "the bounded pullable channel must have one writer"
        )
        XCTAssertFalse(diagnostic.contains("onScanProgress"))
        XCTAssertFalse(diagnostic.contains("for "))
        XCTAssertFalse(diagnostic.contains("while "))
    }

    func testMalformedRecoveredExecutionRingFailsClosedAtMonotonicWatermark()
        throws {
        var first = SessionStore.appendingRecoveredExecutionDiagnosticEvent(
            ["edge": "admit"],
            to: nil
        )
        var events = try XCTUnwrap(first["events"] as? [[String: Any]])
        events[0]["sequence"] = 99
        first["events"] = events

        let recovered = SessionStore
            .appendingRecoveredExecutionDiagnosticEvent(
                ["edge": "terminal"],
                to: first
            )
        XCTAssertEqual(recovered["next_sequence"] as? Int, 2)
        XCTAssertEqual(recovered["first_sequence"] as? Int, 1)
        XCTAssertEqual(recovered["dropped_event_count"] as? Int, 1)
        let suffix = try XCTUnwrap(
            recovered["events"] as? [[String: Any]]
        )
        XCTAssertEqual(suffix.count, 1)
        XCTAssertEqual(suffix.first?["sequence"] as? Int, 1)
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

    func testOldExactCancelCannotCancelReplacementLease() throws {
        let throttle = AtriaBackgroundProjectionThrottle()
        let oldLease = throttle.begin(budgetSeconds: 600)
        throttle.end()
        let replacement = throttle.begin(budgetSeconds: 600)

        XCTAssertFalse(throttle.cancel(lease: oldLease))
        XCTAssertFalse(throttle.end(lease: oldLease))
        XCTAssertTrue(throttle.activeLeaseShouldContinue(
            replacement,
            now: ProcessInfo.processInfo.systemUptime,
            thermalState: .nominal,
            isLowPowerModeEnabled: false
        ))
    }

    func testOldExactEndDuringUnwindCannotRetireReplacementLease() {
        let throttle = AtriaBackgroundProjectionThrottle()
        let oldLease = throttle.begin(budgetSeconds: 600)
        XCTAssertTrue(throttle.end(lease: oldLease))
        let replacement = throttle.begin(budgetSeconds: 600)

        XCTAssertFalse(throttle.end(lease: oldLease))
        XCTAssertTrue(throttle.activeLeaseShouldContinue(
            replacement,
            now: ProcessInfo.processInfo.systemUptime,
            thermalState: .nominal,
            isLowPowerModeEnabled: false
        ))
        XCTAssertTrue(throttle.end(lease: replacement))
        XCTAssertFalse(throttle.isActive)
    }

    func testReplacementDuringDutyPauseRejectsOldLeaseWithoutMutatingNewPass()
        throws {
        let enteredPause = expectation(description: "old lease entered pause")
        let oldFinished = expectation(description: "old lease returned")
        let releasePause = DispatchSemaphore(value: 0)
        let throttle = AtriaBackgroundProjectionThrottle { _ in
            enteredPause.fulfill()
            releasePause.wait()
        }
        throttle.begin(budgetSeconds: 600)
        let oldLease = try XCTUnwrap(throttle.captureActiveLease())
        var oldAborted = false
        DispatchQueue.global(qos: .utility).async {
            oldAborted = throttle.cooperativeCheckpointShouldAbort(
                lease: oldLease,
                processedDelta: 64
            )
            oldFinished.fulfill()
        }
        wait(for: [enteredPause], timeout: 3)

        throttle.end()
        throttle.begin(budgetSeconds: 600)
        let replacement = try XCTUnwrap(throttle.captureActiveLease())
        releasePause.signal()
        wait(for: [oldFinished], timeout: 3)

        XCTAssertTrue(oldAborted)
        XCTAssertTrue(throttle.activeLeaseShouldContinue(
            replacement,
            now: ProcessInfo.processInfo.systemUptime,
            thermalState: .nominal,
            isLowPowerModeEnabled: false
        ))
        XCTAssertFalse(
            leasedCheckpointOffMain(
                throttle,
                lease: replacement,
                processedDelta: 1
            )
        )
    }

    func testExactBackgroundDutyPauseIsAtLeastWorkDurationWithoutCap() {
        XCTAssertEqual(
            AtriaBackgroundProjectionThrottle
                .backgroundProjectionPauseDuration(
                    workDuration: 0.08,
                    processedFrames: 63
                ),
            0
        )
        for workDuration in [0.08, 1.0, 5.0] {
            let rest = AtriaBackgroundProjectionThrottle
                .backgroundProjectionPauseDuration(
                    workDuration: workDuration,
                    processedFrames: 64
                )
            XCTAssertGreaterThanOrEqual(rest, workDuration)
            XCTAssertLessThanOrEqual(
                workDuration / (workDuration + rest),
                0.5
            )
        }
        XCTAssertEqual(
            AtriaBackgroundProjectionThrottle
                .backgroundProjectionPauseDuration(
                    workDuration: 5,
                    processedFrames: 64
                ),
            5,
            "the exact BG lane must not inherit the orphan replay's 100ms cap"
        )
    }

    func testExactBackgroundCheckpointRequestsFiftyPercentDutyOnInjectedClock()
        throws {
        let clock = ThrottleClock(now: 100)
        let throttle = AtriaBackgroundProjectionThrottle(
            sleepFor: { clock.rest(for: $0) },
            uptimeNow: { clock.uptime() }
        )
        let lease = throttle.begin(budgetSeconds: 600)
        let workDuration: TimeInterval = 0.8
        clock.advanceWork(by: workDuration)

        XCTAssertFalse(leasedCheckpointOffMain(
            throttle,
            lease: lease,
            processedDelta: 64
        ))
        let restDuration = clock.restDuration()
        XCTAssertEqual(restDuration, workDuration, accuracy: 0.000_001)
        XCTAssertEqual(
            workDuration / (workDuration + restDuration),
            0.5,
            accuracy: 0.000_001
        )
        XCTAssertTrue(throttle.activeLeaseShouldContinue(
            lease,
            now: clock.uptime(),
            thermalState: .nominal,
            isLowPowerModeEnabled: false
        ))
    }

    func testCancellableMergeSortParticipatesInExactBackgroundDutyCycle()
        throws {
        let pauseLock = NSLock()
        var pauseCount = 0
        let throttle = AtriaBackgroundProjectionThrottle { _ in
            pauseLock.lock()
            pauseCount += 1
            pauseLock.unlock()
        }
        throttle.begin(budgetSeconds: 600)
        let lease = try XCTUnwrap(throttle.captureActiveLease())
        let completion = expectation(description: "duty-cycled sort")
        var sorted: [Int] = []
        var completed = false
        DispatchQueue.global(qos: .utility).async {
            sorted = Array((0..<4_096).reversed())
            completed = AtriaSleepCooperativeAlgorithms.stableSort(
                &sorted,
                shouldContinue: {
                    !throttle.cooperativeCheckpointShouldAbort(
                        lease: lease,
                        processedDelta: 256
                    )
                },
                areInIncreasingOrder: <
            )
            completion.fulfill()
        }
        wait(for: [completion], timeout: 3)

        XCTAssertTrue(completed)
        XCTAssertEqual(sorted, Array(0..<4_096))
        pauseLock.lock()
        let observedPauses = pauseCount
        pauseLock.unlock()
        XCTAssertGreaterThan(observedPauses, 0)
    }

    func testExactLeaseValidityIsNonSleepingAndWorksOnMainActor() throws {
        let throttle = AtriaBackgroundProjectionThrottle()
        let now = ProcessInfo.processInfo.systemUptime
        throttle.begin(budgetSeconds: 600)
        let lease = try XCTUnwrap(throttle.captureActiveLease())
        XCTAssertTrue(throttle.activeLeaseShouldContinue(
            lease,
            now: now,
            thermalState: .nominal,
            isLowPowerModeEnabled: false
        ))
        throttle.cancel()
        XCTAssertFalse(throttle.activeLeaseShouldContinue(
            lease,
            now: now,
            thermalState: .nominal,
            isLowPowerModeEnabled: false
        ))
    }

    func testExactBackgroundLeaseIgnoresForegroundSceneGateButNotEnd()
        throws {
        let previous = AtriaHistoricalProjectionForegroundGate.isBackgrounded
        defer {
            AtriaHistoricalProjectionForegroundGate.isBackgrounded = previous
        }
        let throttle = AtriaBackgroundProjectionThrottle()
        let now = ProcessInfo.processInfo.systemUptime
        throttle.begin(budgetSeconds: 600)
        let lease = try XCTUnwrap(throttle.captureActiveLease())
        AtriaHistoricalProjectionForegroundGate.isBackgrounded = true
        XCTAssertTrue(throttle.activeLeaseShouldContinue(
            lease,
            now: now,
            thermalState: .nominal,
            isLowPowerModeEnabled: false
        ))
        throttle.end()
        XCTAssertFalse(throttle.activeLeaseShouldContinue(
            lease,
            now: now,
            thermalState: .nominal,
            isLowPowerModeEnabled: false
        ))
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
