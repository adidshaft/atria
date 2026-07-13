import XCTest
@testable import Atria

@MainActor
final class AtriaLiveActivityActionTests: XCTestCase {
    func testDynamicIslandCompactControlsUseIconsWithExplicitAccessibilityLabels() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let widgetSourceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("AtriaWidget/AtriaWidget.swift")
        let source = try String(contentsOf: widgetSourceURL, encoding: .utf8)
        let controlsStart = try XCTUnwrap(source.range(of: "private struct AtriaLiveActivityControls: View"))
        let controlsEnd = try XCTUnwrap(source.range(of: "struct AtriaStartCaptureControl: ControlWidget",
                                                    range: controlsStart.upperBound..<source.endIndex))
        let controls = String(source[controlsStart.lowerBound..<controlsEnd.lowerBound])

        XCTAssertTrue(controls.contains("if compact"))
        XCTAssertTrue(controls.contains("Image(systemName: (state.isPaused ?? false) ? \"play.fill\" : \"pause.fill\")"))
        XCTAssertTrue(controls.contains("Image(systemName: \"stop.fill\")"))
        XCTAssertTrue(controls.contains(".accessibilityLabel((state.isPaused ?? false) ? \"Resume workout\" : \"Pause workout\")"))
        XCTAssertTrue(controls.contains(".accessibilityLabel(\"End workout\")"))
    }

    func testActionStoreConsumesRecentSessionMatchedCommandQueueOnceInTapOrder() throws {
        let suite = "AtriaLiveActivityActionTests.recent.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let start = now.addingTimeInterval(-1_200)
        let pause = AtriaPendingLiveWorkoutAction(action: .pause,
                                                  workoutStartedAt: start,
                                                  issuedAt: now.addingTimeInterval(-4))
        let end = AtriaPendingLiveWorkoutAction(action: .end,
                                                workoutStartedAt: start,
                                                issuedAt: now.addingTimeInterval(-2))
        // Store them out of order to prove foreground processing follows the
        // extension's durable tap timestamps rather than encoder order.
        defaults.set(try JSONEncoder().encode([end, pause]),
                     forKey: AtriaLiveWorkoutActionStore.key)

        let consumed = AtriaLiveWorkoutActionStore.consumeAll(now: now,
                                                               defaults: defaults)
        XCTAssertEqual(consumed, [pause, end])
        XCTAssertTrue(AtriaLiveWorkoutActionStore.matches(pause,
                                                          workoutStartedAt: start.addingTimeInterval(0.5)))
        XCTAssertFalse(AtriaLiveWorkoutActionStore.matches(pause,
                                                           workoutStartedAt: start.addingTimeInterval(2)))
        XCTAssertTrue(AtriaLiveWorkoutActionStore.consumeAll(now: now, defaults: defaults).isEmpty)
    }

    func testActionStoreStillDecodesLegacySingleCommandAndClampsActionTime() throws {
        let suite = "AtriaLiveActivityActionTests.legacy.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let start = now.addingTimeInterval(-1_200)
        let pending = AtriaPendingLiveWorkoutAction(action: .end,
                                                    workoutStartedAt: start,
                                                    issuedAt: now.addingTimeInterval(-3))
        defaults.set(try JSONEncoder().encode(pending),
                     forKey: AtriaLiveWorkoutActionStore.key)

        XCTAssertEqual(AtriaLiveWorkoutActionStore.consumeAll(now: now, defaults: defaults),
                       [pending])
        XCTAssertEqual(AtriaLiveWorkoutActionStore.actionDate(pending,
                                                               workoutStartedAt: start,
                                                               now: now),
                       pending.issuedAt)

        let beforeStart = AtriaPendingLiveWorkoutAction(action: .pause,
                                                        workoutStartedAt: start,
                                                        issuedAt: start.addingTimeInterval(-30))
        let future = AtriaPendingLiveWorkoutAction(action: .end,
                                                   workoutStartedAt: start,
                                                   issuedAt: now.addingTimeInterval(3))
        XCTAssertEqual(AtriaLiveWorkoutActionStore.actionDate(beforeStart,
                                                               workoutStartedAt: start,
                                                               now: now), start)
        XCTAssertEqual(AtriaLiveWorkoutActionStore.actionDate(future,
                                                               workoutStartedAt: start,
                                                               now: now), now)
    }

    func testActionStoreRejectsAndRemovesStaleCommand() throws {
        let suite = "AtriaLiveActivityActionTests.stale.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let pending = AtriaPendingLiveWorkoutAction(action: .end,
                                                    workoutStartedAt: now.addingTimeInterval(-3_600),
                                                    issuedAt: now.addingTimeInterval(-301))
        defaults.set(try JSONEncoder().encode(pending),
                     forKey: AtriaLiveWorkoutActionStore.key)

        XCTAssertTrue(AtriaLiveWorkoutActionStore.consumeAll(now: now, defaults: defaults).isEmpty)
        XCTAssertNil(defaults.data(forKey: AtriaLiveWorkoutActionStore.key))
    }

    func testElapsedTimerTicksAloneDoNotScheduleActivityKitWrites() {
        let first = liveSnapshot(elapsed: 100, heartRate: 122)
        let timerTick = liveSnapshot(elapsed: 101, heartRate: 122)
        let newHeartRate = liveSnapshot(elapsed: 101, heartRate: 126)

        XCTAssertFalse(AtriaLiveActivityCoordinator.shouldEnqueueActivityUpdate(
            previous: first,
            current: timerTick
        ))
        XCTAssertTrue(AtriaLiveActivityCoordinator.shouldEnqueueActivityUpdate(
            previous: timerTick,
            current: newHeartRate
        ))
    }

    func testExistingLiveActivityIsAdoptedOnlyForTheSameWorkout() {
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        XCTAssertTrue(AtriaLiveActivityCoordinator.activityBelongsToWorkout(
            activityStartedAt: start,
            workoutStartedAt: start.addingTimeInterval(0.5)
        ))
        XCTAssertFalse(AtriaLiveActivityCoordinator.activityBelongsToWorkout(
            activityStartedAt: start,
            workoutStartedAt: start.addingTimeInterval(60)
        ))
    }

    func testSensorFreshnessChangesScheduleLiveActivityUpdate() {
        let live = liveSnapshot(elapsed: 100, heartRate: 122)
        var disconnected = live
        disconnected.sensorHasContact = false
        var newerSample = live
        newerSample.heartRateCapturedAt = live.heartRateCapturedAt?.addingTimeInterval(5)

        XCTAssertTrue(AtriaLiveActivityCoordinator.shouldEnqueueActivityUpdate(
            previous: live,
            current: disconnected
        ))
        XCTAssertTrue(AtriaLiveActivityCoordinator.shouldEnqueueActivityUpdate(
            previous: live,
            current: newerSample
        ))
    }

    func testLiveMetricsUseFiveSecondCadenceButCriticalTransitionsBypassIt() {
        let baseline = liveSnapshot(elapsed: 100, heartRate: 122)

        var oneMoreStep = baseline
        oneMoreStep.steps = 251
        XCTAssertFalse(AtriaLiveActivityCoordinator.shouldSendActivityUpdateImmediately(
            previous: baseline,
            current: oneMoreStep,
            elapsedSinceLastWrite: 4.9
        ))
        XCTAssertTrue(AtriaLiveActivityCoordinator.shouldSendActivityUpdateImmediately(
            previous: baseline,
            current: oneMoreStep,
            elapsedSinceLastWrite: 5
        ))

        var staleSteps = baseline
        staleSteps.steps = nil
        staleSteps.stepsCapturedAt = nil
        XCTAssertTrue(AtriaLiveActivityCoordinator.shouldSendActivityUpdateImmediately(
            previous: baseline,
            current: staleSteps,
            elapsedSinceLastWrite: 0.1
        ), "A frozen step value must clear without waiting for the cadence gate")

        var lostContact = baseline
        lostContact.sensorHasContact = false
        XCTAssertTrue(AtriaLiveActivityCoordinator.shouldSendActivityUpdateImmediately(
            previous: baseline,
            current: lostContact,
            elapsedSinceLastWrite: 0.1
        ))

        var changedZone = baseline
        changedZone.heartRateZoneIndex = 4
        changedZone.heartRateZoneName = "Anaerobic"
        XCTAssertTrue(AtriaLiveActivityCoordinator.shouldSendActivityUpdateImmediately(
            previous: baseline,
            current: changedZone,
            elapsedSinceLastWrite: 0.1
        ))
    }

    func testReachingWorkoutStrainGoalPublishesImmediately() {
        var below = liveSnapshot(elapsed: 100, heartRate: 122)
        below.strain = 4
        below.workoutStrain = 9.9
        below.targetWorkoutStrain = 10
        var reached = below
        reached.workoutStrain = 10

        XCTAssertTrue(AtriaLiveActivityCoordinator.shouldSendActivityUpdateImmediately(
            previous: below,
            current: reached,
            elapsedSinceLastWrite: 0.1
        ))
    }

    func testDailyStrainCannotFalselyCompleteWorkoutGoal() {
        var baseline = liveSnapshot(elapsed: 100, heartRate: 122)
        baseline.strain = 9.9
        baseline.workoutStrain = 8
        baseline.targetWorkoutStrain = 10
        var dailyStrainCrossed = baseline
        dailyStrainCrossed.strain = 10

        XCTAssertFalse(AtriaLiveActivityCoordinator.shouldSendActivityUpdateImmediately(
            previous: baseline,
            current: dailyStrainCrossed,
            elapsedSinceLastWrite: 0.1
        ), "a workout goal must never be marked reached by the unrelated day numerator")
    }

    func testSensorAvailabilityTransitionsBypassFiveSecondCadence() {
        let baseline = liveSnapshot(elapsed: 100, heartRate: 122)
        var reconnecting = baseline
        reconnecting.heartRateAvailability = .reconnecting
        reconnecting.stepsAvailability = .reconnecting

        XCTAssertTrue(AtriaLiveActivityCoordinator.shouldSendActivityUpdateImmediately(
            previous: baseline,
            current: reconnecting,
            elapsedSinceLastWrite: 0.1
        ))
    }

    func testExactDailyStepGoalCrossingPublishesImmediatelyButEstimateDoesNotClaimIt() {
        var below = liveSnapshot(elapsed: 100, heartRate: 122)
        below.dailySteps = 7_999
        below.dailyStepGoal = 8_000
        var reached = below
        reached.dailySteps = 8_000

        XCTAssertTrue(AtriaLiveActivityCoordinator.shouldSendActivityUpdateImmediately(
            previous: below,
            current: reached,
            elapsedSinceLastWrite: 0.1
        ))

        below.dailyStepsAreEstimated = true
        reached.dailyStepsAreEstimated = true
        XCTAssertFalse(AtriaLiveActivityCoordinator.shouldSendActivityUpdateImmediately(
            previous: below,
            current: reached,
            elapsedSinceLastWrite: 0.1
        ), "a preliminary step estimate must not publish a validated goal-reaching transition")
    }

    func testTargetChangeAndGoalCrossingBypassFiveSecondCadence() {
        var baseline = liveSnapshot(elapsed: 100, heartRate: 122)
        baseline.strain = 8
        baseline.targetWorkoutStrain = 10
        var changedTarget = baseline
        changedTarget.targetWorkoutStrain = 8

        XCTAssertTrue(AtriaLiveActivityCoordinator.shouldSendActivityUpdateImmediately(
            previous: baseline,
            current: changedTarget,
            elapsedSinceLastWrite: 0.1
        ))
    }

    func testActivityStaleDeadlineUsesNewestIndependentSensorSource() {
        let fallback = Date(timeIntervalSince1970: 2_000_000_000)
        let oldHeartRate = fallback.addingTimeInterval(-70)
        let reconnectedMotion = fallback.addingTimeInterval(-2)

        XCTAssertEqual(AtriaLiveActivityCoordinator.sensorStaleDate(
            heartRateCapturedAt: oldHeartRate,
            stepsCapturedAt: reconnectedMotion,
            fallback: fallback
        ), reconnectedMotion.addingTimeInterval(90))
        XCTAssertEqual(AtriaLiveActivityCoordinator.sensorStaleDate(
            heartRateCapturedAt: nil,
            stepsCapturedAt: nil,
            fallback: fallback
        ), fallback.addingTimeInterval(90))
    }

    func testBackgroundEdgeForcesLatestLiveActivityWrite() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let home = try String(contentsOf: testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaHomeView.swift"), encoding: .utf8)
        XCTAssertTrue(home.contains("updateLiveActivity(forceActivityWrite: true)"))
        XCTAssertTrue(home.contains("forceActivityWrite: forceActivityWrite"))

        let coordinator = try String(contentsOf: testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaLiveActivityCoordinator.swift"), encoding: .utf8)
        XCTAssertTrue(coordinator.contains("beginBackgroundTask(withName: \"Atria live workout snapshot\")"))
        XCTAssertTrue(coordinator.contains("endBackgroundTask(backgroundTask)"))
    }

    func testAppAndWidgetLiveActivitySchemasStayEncodingCompatible() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let projectDirectory = testsDirectory.deletingLastPathComponent()
        let app = try String(contentsOf: projectDirectory
            .appendingPathComponent("Atria/AtriaLiveActivityAttributes.swift"), encoding: .utf8)
        let widget = try String(contentsOf: projectDirectory
            .appendingPathComponent("AtriaWidget/AtriaLiveActivityAttributes.swift"), encoding: .utf8)

        func normalizedSchema(_ source: String) -> String {
            source.split(whereSeparator: \.isNewline)
                .map { line in line.split(separator: "//", maxSplits: 1).first.map(String.init) ?? "" }
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }

        XCTAssertEqual(normalizedSchema(app), normalizedSchema(widget))
    }

    func testWidgetFailsClosedAndDistinguishesLiveReconnectStaleUnavailable() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let widgetSourceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("AtriaWidget/AtriaWidget.swift")
        let source = try String(contentsOf: widgetSourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("contextIsStale: context.isStale"))
        XCTAssertTrue(source.contains("state.sensorHasContact != false"))
        XCTAssertTrue(source.contains("now.timeIntervalSince(capturedAt) <= 90"))
        XCTAssertTrue(source.contains("case .reconnecting: return \"Reconnecting\""))
        XCTAssertTrue(source.contains("case .stale: return \"HR stale\""))
        XCTAssertTrue(source.contains("case .unavailable: return \"Unavailable\""))
        XCTAssertTrue(source.contains("state.stepsAreEstimated ?? false"))
        XCTAssertTrue(source.contains("let capturedAt = state.stepsCapturedAt"))
        XCTAssertTrue(source.contains("now.timeIntervalSince(capturedAt) <= 90"))
        XCTAssertTrue(source.contains("labelText: \"Steps reconnecting\""))
        XCTAssertTrue(source.contains("labelText: \"Steps stale\""))
        XCTAssertTrue(source.contains("labelText: \"Steps unavailable\""))
        XCTAssertTrue(source.contains("strap-derived workout steps"))
        XCTAssertTrue(source.contains("liveActivityStrainProgressText(for: context.state)"))
        XCTAssertTrue(source.contains("String(format: \"%.1f / %.1f\", strain, target)"))
        XCTAssertTrue(source.contains("String(format: \"Goal ✓ · %.1f\", strain)"))
        XCTAssertTrue(source.contains("let strain = max(0, state.workoutStrain ?? 0)"),
                      "workout goals must use the canonical workout-only strain projection")
        XCTAssertTrue(source.contains("ProgressView(value: liveActivityStrainProgressFraction(for: context.state))"))
        XCTAssertTrue(source.contains("liveActivityDailyStepGoalPresentation(for: context.state)"))
        XCTAssertTrue(source.contains("state.dailyStepsAreEstimated ?? false"))
        XCTAssertTrue(source.contains("reached && !estimated"),
                      "preliminary steps must never claim an exact goal completion")
    }

    func testWorkoutTargetZonesFlowIntoBackwardCompatibleLiveActivityUI() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let projectDirectory = testsDirectory.deletingLastPathComponent()
        let appSchema = try String(contentsOf: projectDirectory
            .appendingPathComponent("Atria/AtriaLiveActivityAttributes.swift"), encoding: .utf8)
        let widgetSource = try String(contentsOf: projectDirectory
            .appendingPathComponent("AtriaWidget/AtriaWidget.swift"), encoding: .utf8)
        let homeSource = try String(contentsOf: projectDirectory
            .appendingPathComponent("Atria/AtriaHomeView.swift"), encoding: .utf8)

        XCTAssertTrue(appSchema.contains("var targetLowerHeartRateZone: Int? = nil"))
        XCTAssertTrue(appSchema.contains("var targetUpperHeartRateZone: Int? = nil"))
        XCTAssertTrue(homeSource.contains("targetLowerHeartRateZone: session?.lowerTargetZone"))
        XCTAssertTrue(homeSource.contains("targetUpperHeartRateZone: session?.upperTargetZone"))
        XCTAssertTrue(widgetSource.contains("return lower == upper ? \"Z\\(lower)\" : \"Z\\(lower)–Z\\(upper)\""))
        XCTAssertTrue(widgetSource.contains("compactLeading:"))
        XCTAssertTrue(widgetSource.contains("Text(target)"))
        XCTAssertTrue(widgetSource.contains("Label(target, systemImage: \"scope\")"))
    }

    private func liveSnapshot(elapsed: TimeInterval,
                              heartRate: Int) -> AtriaLiveActivityCoordinator.Snapshot {
        AtriaLiveActivityCoordinator.Snapshot(
            isRecording: true,
            heartRate: heartRate,
            heartRateCapturedAt: Date(timeIntervalSince1970: 2_000_000_000),
            sensorHasContact: true,
            heartRateAvailability: .live,
            strain: 5.4,
            batteryLevel: 53,
            batteryChargeStatus: .levelOnly,
            readingCount: 100,
            mediaTitle: "",
            mediaArtist: "",
            mediaIsPlaying: false,
            mediaHasNowPlayingInfo: false,
            startedAt: Date(timeIntervalSince1970: 2_000_000_000),
            activityName: "Strength",
            activitySystemImage: "dumbbell.fill",
            heartRateZoneIndex: 3,
            heartRateZoneName: "Aerobic",
            steps: 250,
            stepsAreEstimated: true,
            stepsCapturedAt: Date(timeIntervalSince1970: 2_000_000_000),
            stepsAvailability: .live,
            dailySteps: 4_250,
            dailyStepsAreEstimated: true,
            dailyStepGoal: 8_000,
            workoutStrain: 5.4,
            targetWorkoutStrain: 10,
            isPaused: false,
            elapsedDuration: elapsed
        )
    }
}
