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

    func testHeadlessPausePersistsCanonicalPauseAndStepAnchor() throws {
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let original = makeIntent(startedAt: start)
        let paused = try XCTUnwrap(AtriaWorkoutCommandTransaction.applying(
            .pause,
            to: original,
            at: start.addingTimeInterval(90),
            currentStepCount: 1_234
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
            currentStepCount: 527
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

    func testLiveActivityIntentIsSharedAcrossAppAndWidgetAndAwaitsCanonicalState() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let shared = try String(contentsOf: root
            .appendingPathComponent("AtriaShared/AtriaLiveWorkoutControlIntent.swift"))
        let project = try String(contentsOf: root
            .appendingPathComponent("Atria.xcodeproj/project.pbxproj"))
        let app = try String(contentsOf: root
            .appendingPathComponent("Atria/AtriaApp.swift"))

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
            Thread.isMainThread
        }

        XCTAssertFalse(executedOnMainThread,
                       "App-group directory scans and JSON reads must never block a scene activation on MainActor")
    }

    func testSceneActivationSchedulesCoalescedReplayInsteadOfSynchronousDirectoryScan() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let app = try String(contentsOf: root
            .appendingPathComponent("Atria/AtriaApp.swift"))
        let home = try String(contentsOf: root
            .appendingPathComponent("Atria/AtriaHomeView.swift"))
        let runtime = try String(contentsOf: root
            .appendingPathComponent("Atria/AtriaWorkoutRuntime.swift"))

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
            .appendingPathComponent("Atria/AtriaHomeView.swift"))
        let appearStart = try XCTUnwrap(home.range(of: ".onAppear {"))
        let appearEnd = try XCTUnwrap(home.range(of: ".onChange(of: selectedTab)",
                                               range: appearStart.upperBound..<home.endIndex))
        let appearBody = String(home[appearStart.lowerBound..<appearEnd.lowerBound])
        let yieldOffset = try XCTUnwrap(appearBody.range(of: "await Task.yield()"))
        let workOffset = try XCTUnwrap(appearBody.range(of: "handleHomeAppear()"))

        XCTAssertLessThan(yieldOffset.lowerBound, workOffset.lowerBound)
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
