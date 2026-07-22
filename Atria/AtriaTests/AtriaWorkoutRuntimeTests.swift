import XCTest
@testable import Atria

final class AtriaWorkoutRuntimeTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "AtriaWorkoutRuntimeTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults?.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = ""
        super.tearDown()
    }

    func testCompletedStepSelectionPrefersValidatedStrap() {
        let strap = AtriaCompletedWorkoutStepEvidence(
            count: 612,
            isEstimated: false,
            capturedAt: Date(timeIntervalSince1970: 100)
        )
        let phone = AtriaCompletedWorkoutStepEvidence(
            count: 1_010,
            isEstimated: true,
            capturedAt: Date(timeIntervalSince1970: 101)
        )

        XCTAssertEqual(AtriaCompletedWorkoutStepEvidence.select(strap: strap, phone: phone),
                       strap)
    }

    func testCompletedStepSelectionUsesLargerPreliminarySubtotal() {
        let capturedAt = Date(timeIntervalSince1970: 100)
        let sparseStrap = AtriaCompletedWorkoutStepEvidence(
            count: 612,
            isEstimated: true,
            capturedAt: capturedAt
        )
        let carriedPhone = AtriaCompletedWorkoutStepEvidence(
            count: 1_010,
            isEstimated: true,
            capturedAt: capturedAt
        )
        XCTAssertEqual(
            AtriaCompletedWorkoutStepEvidence.select(strap: sparseStrap, phone: carriedPhone),
            carriedPhone
        )

        let benchPhone = AtriaCompletedWorkoutStepEvidence(
            count: 0,
            isEstimated: true,
            capturedAt: capturedAt
        )
        XCTAssertEqual(
            AtriaCompletedWorkoutStepEvidence.select(strap: sparseStrap, phone: benchPhone),
            sparseStrap
        )
    }

    func testHeadlessPausePersistsCanonicalPauseAndStepAnchor() throws {
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let original = makeIntent(startedAt: start)
        let paused = try XCTUnwrap(AtriaWorkoutCommandTransaction.applying(
            .pause,
            to: original,
            at: start.addingTimeInterval(90),
            currentStepCount: 1_234,
            hasCurrentStepEvidence: true
        ))

        XCTAssertTrue(paused.save(defaults: defaults))
        let restored = try XCTUnwrap(AtriaPendingWorkoutIntent.load(defaults: defaults))
        XCTAssertEqual(restored.pauseStartedAt, start.addingTimeInterval(90))
        XCTAssertEqual(restored.pauseStartedStepCount, 1_234)
        XCTAssertNil(restored.endedAt)
    }

    func testHeadlessResumePersistsExcludedWindowAndPausedSteps() throws {
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        var paused = makeIntent(startedAt: start)
        paused.pauseStartedAt = start.addingTimeInterval(40)
        paused.pauseStartedStepCount = 500
        paused.pausedStepCount = 7
        let resumedAt = start.addingTimeInterval(100)

        let resumed = try XCTUnwrap(AtriaWorkoutCommandTransaction.applying(
            .resume,
            to: paused,
            at: resumedAt,
            currentStepCount: 527,
            hasCurrentStepEvidence: true
        ))
        XCTAssertTrue(resumed.save(defaults: defaults))

        let restored = try XCTUnwrap(AtriaPendingWorkoutIntent.load(defaults: defaults))
        XCTAssertNil(restored.pauseStartedAt)
        XCTAssertNil(restored.pauseStartedStepCount)
        XCTAssertEqual(restored.pausedStepCount, 34)
        XCTAssertEqual(restored.excludedIntervals, [
            ExcludedInterval(start: start.addingTimeInterval(40), end: resumedAt)
        ])
    }

    func testHeadlessEndPersistsTerminalIntentAndClosesOpenPauseWithoutLosingSteps() throws {
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        var paused = makeIntent(startedAt: start)
        paused.pauseStartedAt = start.addingTimeInterval(20)
        paused.pauseStartedStepCount = 140
        paused.pausedStepCount = 8
        let endedAt = start.addingTimeInterval(80)
        let capturedAt = endedAt.addingTimeInterval(-1)

        let ended = try XCTUnwrap(AtriaWorkoutCommandTransaction.applying(
            .end,
            to: paused,
            at: endedAt,
            currentStepCount: 147,
            hasCurrentStepEvidence: true,
            currentStepsAreEstimated: false,
            currentStepsCapturedAt: capturedAt
        ))
        XCTAssertTrue(ended.save(defaults: defaults))

        let restored = try XCTUnwrap(AtriaPendingWorkoutIntent.load(defaults: defaults))
        XCTAssertEqual(restored.endedAt, endedAt)
        XCTAssertEqual(restored.pauseStartedAt, start.addingTimeInterval(20))
        XCTAssertNil(restored.pauseStartedStepCount)
        XCTAssertEqual(restored.pausedStepCount, 15)
        XCTAssertEqual(restored.completedStepCount, 32)
        XCTAssertEqual(restored.completedStepsAreEstimated, false)
        XCTAssertEqual(restored.completedStepsCapturedAt, capturedAt)
        XCTAssertEqual(restored.finalizedExcludedIntervals(), [
            ExcludedInterval(start: start.addingTimeInterval(20), end: endedAt)
        ])
    }

    func testHeadlessEndDoesNotInventStepsWithoutMotionEvidence() throws {
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let ended = try XCTUnwrap(AtriaWorkoutCommandTransaction.applying(
            .end,
            to: makeIntent(startedAt: start),
            at: start.addingTimeInterval(80),
            currentStepCount: 147
        ))

        XCTAssertNil(ended.completedStepCount)
        XCTAssertNil(ended.completedStepsAreEstimated)
        XCTAssertNil(ended.completedStepsCapturedAt)
    }

    func testWorkoutCalculationContextFreezesAndPersistsStartProfile() throws {
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let startProfile = AthleteProfile(age: 30,
                                          measuredMaxHR: 190,
                                          maxHRSource: .measured,
                                          biologicalSex: .male,
                                          weightKg: 75,
                                          heightCm: 178,
                                          updated: start,
                                          hasCompletedOnboarding: true)
        let context = AtriaWorkoutCalculationContext(restingHeartRate: 58,
                                                     profile: startProfile)
        var intent = makeIntent(startedAt: start)
        intent.calculationContext = context

        let data = try JSONEncoder().encode(intent)
        let restored = try JSONDecoder().decode(AtriaPendingWorkoutIntent.self,
                                                from: data)
        XCTAssertEqual(restored.calculationContext, context)
        XCTAssertEqual(restored.calculationContext?.restingHeartRate, 58)
        XCTAssertEqual(restored.calculationContext?.maximumHeartRate, 190)
        XCTAssertEqual(restored.calculationContext?.profile.weightKg, 75)

        let editedProfile = AthleteProfile(age: 31,
                                           measuredMaxHR: 177,
                                           maxHRSource: .measured,
                                           biologicalSex: .female,
                                           weightKg: 82,
                                           heightCm: 178,
                                           updated: start.addingTimeInterval(60),
                                           hasCompletedOnboarding: true)
        XCTAssertNotEqual(editedProfile, restored.calculationContext?.profile)
        XCTAssertEqual(restored.calculationContext?.maximumHeartRate, 190,
                       "mid-workout profile edits cannot change the frozen calculation epoch")
    }

    func testLockScreenUsesMergedAllDayCoordinateAcrossPauseResumeAndEnd() throws {
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let pauseAt = start.addingTimeInterval(60)
        let pauseCoordinate = try XCTUnwrap(AtriaWorkoutStepCoordinate.make(
            savedPrefixHydrated: true,
            savedToday: 1_000,
            savedActiveSession: 500,
            savedActiveSessionTotal: 500,
            liveActiveSession: 550,
            hasLiveStepEvidence: true,
            isValidated: true,
            capturedAt: pauseAt,
            isConnected: true,
            reconnectPending: false,
            rangeLossBackfillPending: false,
            now: pauseAt
        ))
        XCTAssertEqual(pauseCoordinate.cumulativeCount, 1_050)

        var intent = AtriaPendingWorkoutIntent(
            startedAt: start,
            endedAt: nil,
            activityType: AtriaWorkoutActivityType.walking.rawValue,
            strengthSets: [],
            excludedIntervals: [],
            startingStepCount: 1_000,
            startingDayStrain: 1.2
        )
        intent = try XCTUnwrap(AtriaWorkoutCommandTransaction.applying(
            .pause,
            to: intent,
            at: pauseAt,
            currentStepCount: pauseCoordinate.cumulativeCount,
            hasCurrentStepEvidence: pauseCoordinate.isLiveForCompletion
        ))
        XCTAssertEqual(intent.pauseStartedStepCount, 1_050)

        let resumeAt = pauseAt.addingTimeInterval(30)
        let resumeCoordinate = try XCTUnwrap(AtriaWorkoutStepCoordinate.make(
            savedPrefixHydrated: true,
            savedToday: 1_050,
            savedActiveSession: 550,
            savedActiveSessionTotal: 550,
            liveActiveSession: 575,
            hasLiveStepEvidence: true,
            isValidated: true,
            capturedAt: resumeAt,
            isConnected: true,
            reconnectPending: false,
            rangeLossBackfillPending: false,
            now: resumeAt
        ))
        intent = try XCTUnwrap(AtriaWorkoutCommandTransaction.applying(
            .resume,
            to: intent,
            at: resumeAt,
            currentStepCount: resumeCoordinate.cumulativeCount,
            hasCurrentStepEvidence: resumeCoordinate.isLiveForCompletion
        ))
        XCTAssertEqual(intent.pausedStepCount, 25)

        let endAt = resumeAt.addingTimeInterval(60)
        let endCoordinate = try XCTUnwrap(AtriaWorkoutStepCoordinate.make(
            savedPrefixHydrated: true,
            savedToday: 1_075,
            savedActiveSession: 575,
            savedActiveSessionTotal: 575,
            liveActiveSession: 625,
            hasLiveStepEvidence: true,
            isValidated: true,
            capturedAt: endAt.addingTimeInterval(-1),
            isConnected: true,
            reconnectPending: false,
            rangeLossBackfillPending: false,
            now: endAt
        ))
        let ended = try XCTUnwrap(AtriaWorkoutCommandTransaction.applying(
            .end,
            to: intent,
            at: endAt,
            currentStepCount: endCoordinate.cumulativeCount,
            hasCurrentStepEvidence: endCoordinate.isLiveForCompletion,
            currentStepsAreEstimated: endCoordinate.isEstimated,
            currentStepsCapturedAt: endCoordinate.capturedAt
        ))
        XCTAssertEqual(ended.completedStepCount, 100)
        XCTAssertEqual(ended.completedStepsAreEstimated, false)
    }

    func testLockScreenStepCoordinateFailsClosedUntilSavedPrefixHydrates() {
        XCTAssertNil(AtriaWorkoutStepCoordinate.make(
            savedPrefixHydrated: false,
            savedToday: 1_000,
            savedActiveSession: 500,
            savedActiveSessionTotal: 500,
            liveActiveSession: 50,
            hasLiveStepEvidence: true,
            isValidated: true,
            capturedAt: Date(),
            isConnected: true,
            reconnectPending: false,
            rangeLossBackfillPending: false,
            now: Date()
        ))
    }

    func testHeadlessEndOmitsStaleOrBackfillPendingStepTotals() throws {
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let endAt = start.addingTimeInterval(120)
        for coordinate in [
            AtriaWorkoutStepCoordinate.make(
                savedPrefixHydrated: true,
                savedToday: 100,
                savedActiveSession: 0,
                savedActiveSessionTotal: 0,
                liveActiveSession: 80,
                hasLiveStepEvidence: true,
                isValidated: true,
                capturedAt: endAt.addingTimeInterval(-3),
                isConnected: true,
                reconnectPending: false,
                rangeLossBackfillPending: false,
                now: endAt
            ),
            AtriaWorkoutStepCoordinate.make(
                savedPrefixHydrated: true,
                savedToday: 100,
                savedActiveSession: 0,
                savedActiveSessionTotal: 0,
                liveActiveSession: 80,
                hasLiveStepEvidence: true,
                isValidated: true,
                capturedAt: endAt,
                isConnected: true,
                reconnectPending: false,
                rangeLossBackfillPending: true,
                now: endAt
            ),
        ] {
            let coordinate = try XCTUnwrap(coordinate)
            XCTAssertFalse(coordinate.isLiveForCompletion)
            var intent = makeIntent(startedAt: start)
            intent.completedStepCount = 999
            intent.completedStepsAreEstimated = false
            intent.completedStepsCapturedAt = endAt.addingTimeInterval(-1)
            let ended = try XCTUnwrap(AtriaWorkoutCommandTransaction.applying(
                .end,
                to: intent,
                at: endAt,
                currentStepCount: coordinate.cumulativeCount,
                hasCurrentStepEvidence: coordinate.isLiveForCompletion,
                currentStepsAreEstimated: coordinate.isEstimated,
                currentStepsCapturedAt: coordinate.capturedAt
            ))
            XCTAssertNil(ended.completedStepCount)
            XCTAssertNil(ended.completedStepsAreEstimated)
            XCTAssertNil(ended.completedStepsCapturedAt)
        }
    }

    func testActionTimeStepCoordinateRejectsNextSecondFrame() throws {
        let actionAt = Date(timeIntervalSince1970: 2_000_000_000)
        let exact = try XCTUnwrap(AtriaWorkoutStepCoordinate.make(
            savedPrefixHydrated: true,
            savedToday: 100,
            savedActiveSession: 0,
            savedActiveSessionTotal: 0,
            liveActiveSession: 12,
            hasLiveStepEvidence: true,
            isValidated: true,
            capturedAt: actionAt,
            isConnected: true,
            reconnectPending: false,
            rangeLossBackfillPending: false,
            now: actionAt
        ))
        XCTAssertTrue(exact.isLiveForCompletion)

        let nextFrame = try XCTUnwrap(AtriaWorkoutStepCoordinate.make(
            savedPrefixHydrated: true,
            savedToday: 100,
            savedActiveSession: 0,
            savedActiveSessionTotal: 0,
            liveActiveSession: 13,
            hasLiveStepEvidence: true,
            isValidated: true,
            capturedAt: actionAt.addingTimeInterval(1),
            isConnected: true,
            reconnectPending: false,
            rangeLossBackfillPending: false,
            now: actionAt
        ))
        XCTAssertFalse(nextFrame.isLiveForCompletion,
                       "A frame one second after the tap belongs to the next action interval")
    }

    func testHUDToleranceDoesNotAuthorizeStaleActionBoundary() throws {
        let actionAt = Date(timeIntervalSince1970: 2_000_000_000)
        let capturedAt = actionAt.addingTimeInterval(-10)
        let hud = AtriaLiveWorkoutStepProjection.make(
            totalCount: 212,
            startingCount: 100,
            hasStepEvidence: true,
            isValidated: true,
            capturedAt: capturedAt,
            isReconnecting: false,
            now: actionAt
        )
        XCTAssertEqual(hud.availability, .live,
                       "the workout HUD keeps its existing 15-second continuity tolerance")

        let action = try XCTUnwrap(AtriaWorkoutStepCoordinate.make(
            savedPrefixHydrated: true,
            savedToday: 100,
            savedActiveSession: 0,
            savedActiveSessionTotal: 0,
            liveActiveSession: 112,
            hasLiveStepEvidence: true,
            isValidated: true,
            capturedAt: capturedAt,
            isConnected: true,
            reconnectPending: false,
            rangeLossBackfillPending: false,
            now: actionAt
        ))
        XCTAssertFalse(action.isLiveForCompletion,
                       "last-known HUD context must not become completion evidence")
    }

    func testForegroundCompletionUsesActionBoundaryFreshnessNotHUDTolerance() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let home = try String(contentsOf: root
            .appendingPathComponent("Atria/AtriaHomeView.swift"), encoding: .utf8)
        let start = try XCTUnwrap(home.range(of: "private func completedWorkoutStepEvidence"))
        let end = try XCTUnwrap(home.range(of: "private func publishLiveWidgetSnapshotIfNeeded",
                                           range: start.upperBound..<home.endIndex))
        let body = String(home[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(body.contains("sourceVersion: session.stepSourceVersion"))
        XCTAssertTrue(body.contains("now: now"))
        XCTAssertTrue(body.contains("coordinate.isLiveForCompletion"))
        XCTAssertFalse(body.contains("AtriaLiveWorkoutStepProjection.make"),
                       "the 15-second HUD tolerance cannot authorize foreground End")
    }

    func testDelayedPauseResumeReplayPreservesTimeButFailsStepAccountingClosed() throws {
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let pauseAt = start.addingTimeInterval(60)
        let replayedAt = pauseAt.addingTimeInterval(90)
        let delayedCoordinate = try XCTUnwrap(AtriaWorkoutStepCoordinate.make(
            savedPrefixHydrated: true,
            savedToday: 1_400,
            savedActiveSession: 400,
            savedActiveSessionTotal: 400,
            liveActiveSession: 500,
            hasLiveStepEvidence: true,
            isValidated: true,
            capturedAt: replayedAt,
            isConnected: true,
            reconnectPending: false,
            rangeLossBackfillPending: false,
            now: pauseAt
        ))
        XCTAssertFalse(delayedCoordinate.isLiveForCompletion,
                       "a current coordinate cannot be attached to an older tap")

        var intent = try XCTUnwrap(AtriaWorkoutCommandTransaction.applying(
            .pause,
            to: makeIntent(startedAt: start),
            at: pauseAt,
            currentStepCount: delayedCoordinate.cumulativeCount,
            hasCurrentStepEvidence: delayedCoordinate.isLiveForCompletion
        ))
        XCTAssertEqual(intent.pauseStartedAt, pauseAt)
        XCTAssertNil(intent.pauseStartedStepCount)
        XCTAssertFalse(intent.stepAccountingIsComplete)

        let resumeAt = start.addingTimeInterval(180)
        intent = try XCTUnwrap(AtriaWorkoutCommandTransaction.applying(
            .resume,
            to: intent,
            at: resumeAt,
            currentStepCount: 1_550,
            hasCurrentStepEvidence: false
        ))
        XCTAssertEqual(intent.excludedIntervals, [
            ExcludedInterval(start: pauseAt, end: resumeAt)
        ])
        XCTAssertEqual(intent.pausedStepCount, 0)
        XCTAssertFalse(intent.stepAccountingIsComplete)

        let ended = try XCTUnwrap(AtriaWorkoutCommandTransaction.applying(
            .end,
            to: intent,
            at: start.addingTimeInterval(240),
            currentStepCount: 1_600,
            hasCurrentStepEvidence: true,
            currentStepsAreEstimated: false,
            currentStepsCapturedAt: start.addingTimeInterval(239)
        ))
        XCTAssertNil(ended.completedStepCount,
                     "a later fresh total cannot repair an unknown pause boundary")
    }

    func testForegroundStartUsesBoundedHydrationBeforeReadingMergedStepAnchor() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let home = try String(contentsOf: root
            .appendingPathComponent("Atria/AtriaHomeView.swift"), encoding: .utf8)
        let start = try XCTUnwrap(home.range(of: "private func makeWorkoutSession("))
        let end = try XCTUnwrap(home.range(of: "private func beginWorkoutSession(",
                                           range: start.upperBound..<home.endIndex))
        let body = String(home[start.lowerBound..<end.lowerBound])
        let authorityStart = try XCTUnwrap(home.range(of: "private func workoutStepLedgerIsReadyForStart("))
        let authorityEnd = try XCTUnwrap(home.range(of: "private func makeWorkoutSession(",
                                                     range: authorityStart.upperBound..<home.endIndex))
        let authority = String(home[authorityStart.lowerBound..<authorityEnd.lowerBound])
        XCTAssertTrue(authority.contains("await store.waitForDeferredSessionLoadIfNeeded(timeoutSeconds: timeoutSeconds)"))
        XCTAssertTrue(authority.contains("timeoutSeconds: TimeInterval = 1"),
                      "A cold ledger must fail fast instead of holding Start behind the old eight-second wait")
        let guardLoaded = try XCTUnwrap(body.range(of: "guard await workoutStepLedgerIsReadyForStart()"))
        let clock = try XCTUnwrap(body.range(of: "let start = Date()"))
        let sourceFreeze = try XCTUnwrap(body.range(of: "AtriaWorkoutStepSourceVersion.frozen"))
        let coordinate = try XCTUnwrap(body.range(of: "sourceVersion: stepSourceVersion"))
        let anchor = try XCTUnwrap(body.range(of: "startingStepCount: stepCoordinate.cumulativeCount"))
        XCTAssertLessThan(guardLoaded.lowerBound, clock.lowerBound)
        XCTAssertLessThan(clock.lowerBound, sourceFreeze.lowerBound)
        XCTAssertLessThan(sourceFreeze.lowerBound, coordinate.lowerBound)
        XCTAssertLessThan(clock.lowerBound, coordinate.lowerBound)
        XCTAssertLessThan(coordinate.lowerBound, anchor.lowerBound)
        XCTAssertFalse(body.contains("model.coreLiveStore.state.strapStepResearchCount"))
    }

    func testForegroundColdStartStepAnchorFailsClosedUntilSavedSessionsHydrate() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        XCTAssertNil(AtriaWorkoutStepCoordinate.make(
            savedPrefixHydrated: false,
            savedToday: 1_200,
            savedActiveSession: 300,
            savedActiveSessionTotal: 300,
            liveActiveSession: 380,
            hasLiveStepEvidence: true,
            isValidated: true,
            capturedAt: now,
            isConnected: true,
            reconnectPending: false,
            rangeLossBackfillPending: false,
            now: now
        ))

        let hydrated = try XCTUnwrap(AtriaWorkoutStepCoordinate.make(
            savedPrefixHydrated: true,
            savedToday: 1_200,
            savedActiveSession: 300,
            savedActiveSessionTotal: 300,
            liveActiveSession: 380,
            hasLiveStepEvidence: true,
            isValidated: true,
            capturedAt: now,
            isConnected: true,
            reconnectPending: false,
            rangeLossBackfillPending: false,
            now: now
        ))
        XCTAssertEqual(hydrated.cumulativeCount, 1_280,
                       "foreground Start must anchor to the hydrated all-day coordinate")
    }

    func testLiveActivityIntentIsSharedAcrossAppAndWidgetAndAwaitsCanonicalState() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let shared = try String(contentsOf: root
            .appendingPathComponent("AtriaShared/AtriaLiveWorkoutControlIntent.swift"), encoding: .utf8)
        let project = try String(contentsOf: root
            .appendingPathComponent("Atria.xcodeproj/project.pbxproj"), encoding: .utf8)
        let app = try String(contentsOf: root
            .appendingPathComponent("Atria/AtriaApp.swift"), encoding: .utf8)

        XCTAssertFalse(shared.contains("openAppWhenRun = true"))
        XCTAssertTrue(shared.contains("@Dependency(default: AtriaLiveWorkoutCommandHandler.unavailable)"))
        XCTAssertTrue(shared.contains("guard let canonicalState = await commandHandler.apply"))
        XCTAssertEqual(project.components(separatedBy:
            "AtriaLiveWorkoutControlIntent.swift in Atria Sources").count - 1, 2)
        XCTAssertEqual(project.components(separatedBy:
            "AtriaLiveWorkoutControlIntent.swift in Widget Sources").count - 1, 2)
        XCTAssertTrue(app.contains("AppDependencyManager.shared.add"))
    }

    func testPendingActionQueueLoadRunsOffMainThread() async {
        let executedOnMainThread = await AtriaWorkoutRuntime.performPendingActionLoad {
            pthread_main_np() != 0
        }

        XCTAssertFalse(executedOnMainThread,
                       "App-group directory scans and JSON reads must never block a scene activation on MainActor")
    }

    func testSceneActivationSchedulesCoalescedReplayInsteadOfSynchronousDirectoryScan() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let app = try String(contentsOf: root
            .appendingPathComponent("Atria/AtriaApp.swift"), encoding: .utf8)
        let home = try String(contentsOf: root
            .appendingPathComponent("Atria/AtriaHomeView.swift"), encoding: .utf8)
        let runtime = try String(contentsOf: root
            .appendingPathComponent("Atria/AtriaWorkoutRuntime.swift"), encoding: .utf8)

        XCTAssertFalse(app.contains("workoutRuntime.replayPendingActions()"))
        XCTAssertTrue(app.contains("workoutRuntime.schedulePendingActionReplay()"))
        XCTAssertFalse(home.contains("consumePendingLiveWorkoutActionIfNeeded"),
                       "Home must not reintroduce a main-actor command-directory scan")
        XCTAssertFalse(home.contains("AtriaLiveWorkoutActionStore.consumeAll"),
                       "The app-lifetime runtime is the only queue-consumption owner")
        XCTAssertTrue(runtime.contains("guard pendingActionReplayTask == nil else { return }"))
        XCTAssertTrue(runtime.contains("Task.detached(priority: .userInitiated"))
    }

    func testHomeAppearanceYieldsBeforeRestorationAndPublisherSetup() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let home = try String(contentsOf: root
            .appendingPathComponent("Atria/AtriaHomeView.swift"), encoding: .utf8)
        let appearStart = try XCTUnwrap(home.range(of: ".onAppear {"))
        let appearEnd = try XCTUnwrap(home.range(of: ".onChange(of: selectedTab)",
                                               range: appearStart.upperBound..<home.endIndex))
        let appearBody = String(home[appearStart.lowerBound..<appearEnd.lowerBound])
        let yieldOffset = try XCTUnwrap(appearBody.range(of: "await Task.yield()"))
        let workOffset = try XCTUnwrap(appearBody.range(of: "handleHomeAppear()"))

        XCTAssertLessThan(yieldOffset.lowerBound, workOffset.lowerBound)
    }

    func testRootRuntimeOwnsTerminalWorkoutRecoveryAfterEverySceneReplay() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let runtime = try String(contentsOf: root
            .appendingPathComponent("Atria/AtriaWorkoutRuntime.swift"), encoding: .utf8)

        let replaySchedule = try XCTUnwrap(runtime.range(of: "func schedulePendingActionReplay()"))
        let replayEnd = try XCTUnwrap(runtime.range(of: "/// App-lifetime completion owner",
                                                   range: replaySchedule.upperBound..<runtime.endIndex))
        let replayBody = String(runtime[replaySchedule.lowerBound..<replayEnd.lowerBound])
        XCTAssertTrue(replayBody.contains("self.scheduleTerminalWorkoutRecovery()"),
                      "A launch with an already-ended intent must recover even when no new command is queued")
        XCTAssertTrue(runtime.contains("while !Task.isCancelled"),
                      "Terminal recovery must outlive Home's short presentation retry window")
        XCTAssertTrue(runtime.contains("pending_live_workout_root_recovery"))
    }

    func testRootRecoveryRetainsIntentUntilWorkoutRouteAndSessionWritesAreDurable() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let runtime = try String(contentsOf: root
            .appendingPathComponent("Atria/AtriaWorkoutRuntime.swift"), encoding: .utf8)
        let recoveryStart = try XCTUnwrap(runtime.range(of:
            "private func recoverTerminalWorkoutIntentIfNeeded() async -> Bool"))
        let recoveryEnd = try XCTUnwrap(runtime.range(of: "/// Root-launch replay",
                                                     range: recoveryStart.upperBound..<runtime.endIndex))
        let recovery = String(runtime[recoveryStart.lowerBound..<recoveryEnd.lowerBound])

        let confirm = try XCTUnwrap(recovery.range(of: "confirmWorkoutWindowForUIAsync"))
        let routeSave = try XCTUnwrap(recovery.range(of: "await AtriaWorkoutRouteStore.saveAsync"))
        let flush = try XCTUnwrap(recovery.range(of: "flushScheduledPersistenceAsync"))
        let clear = try XCTUnwrap(recovery.range(of: "clearIfUnchanged"))
        let discard = try XCTUnwrap(recovery.range(of: "discardDurableCheckpoint"))
        XCTAssertLessThan(confirm.lowerBound, routeSave.lowerBound)
        XCTAssertLessThan(routeSave.lowerBound, flush.lowerBound)
        XCTAssertLessThan(flush.lowerBound, clear.lowerBound)
        XCTAssertLessThan(clear.lowerBound, discard.lowerBound)
        XCTAssertTrue(recovery.contains("guard AtriaPendingWorkoutIntent.load() == intent"),
                      "A concurrent/new workout must never be cleared by an older recovery task")
        XCTAssertTrue(recovery.contains("return false\n        }\n        let persisted = await withCheckedContinuation"),
                      "A route write failure must retain the terminal intent for retry")
        XCTAssertTrue(recovery.contains("guard persisted else { return false }"),
                      "a failed session-file write must retain the terminal intent and route checkpoint")
    }

    func testCanonicalPersistenceFailureReleasesEntireOrderedCommandTail() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let runtime = try String(
            contentsOf: testsDirectory.deletingLastPathComponent()
                .appendingPathComponent("Atria/AtriaWorkoutRuntime.swift"),
            encoding: .utf8
        )
        let failure = try XCTUnwrap(runtime.range(of: "guard await intent.replacePersisted(expected: original) else"))
        let tail = String(runtime[failure.lowerBound...])
        let releaseLoop = try XCTUnwrap(tail.range(of: "for pending in commands[commandIndex...]"))
        let stop = try XCTUnwrap(tail.range(of: "break"))
        let sideEffects = try XCTUnwrap(tail.range(of: "applyDurableSideEffects"))
        XCTAssertLessThan(releaseLoop.lowerBound, stop.lowerBound)
        XCTAssertLessThan(stop.lowerBound, sideEffects.lowerBound)
        XCTAssertTrue(tail.contains("AtriaLiveWorkoutActionStore.release(pending)"))
    }

    private func makeIntent(startedAt: Date) -> AtriaPendingWorkoutIntent {
        AtriaPendingWorkoutIntent(startedAt: startedAt,
                                  endedAt: nil,
                                  activityType: AtriaWorkoutActivityType.walking.rawValue,
                                  strengthSets: [],
                                  excludedIntervals: [],
                                  lowerTargetZone: 2,
                                  upperTargetZone: 3,
                                  startingStepCount: 100,
                                  startingDayStrain: 1.2)
    }
}
