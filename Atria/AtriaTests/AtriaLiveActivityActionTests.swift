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
        XCTAssertTrue(controls.contains("Resumes workout time and route tracking"))
        XCTAssertTrue(controls.contains("Pauses workout time and route tracking"))
        XCTAssertTrue(controls.contains("Ends the active workout"))
    }

    func testLiveActivityMetricsStaySingleLineWithThreeDigitHeartRate() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let source = try String(contentsOf: testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("AtriaWidget/AtriaWidget.swift"), encoding: .utf8)

        let islandStart = try XCTUnwrap(source.range(of: "struct AtriaLiveActivityWidget: Widget"))
        let lockScreenStart = try XCTUnwrap(source.range(of: "private struct AtriaLiveActivityLockScreenView"))
        let compactHeartStart = try XCTUnwrap(source.range(of: "private struct AtriaDynamicIslandCompactHeartRate"))
        let compactHeartEnd = try XCTUnwrap(source.range(of: "private struct AtriaDynamicIslandActivityGlyph",
                                                        range: compactHeartStart.upperBound..<source.endIndex))
        let island = String(source[islandStart.lowerBound..<lockScreenStart.lowerBound])
        let compactHeart = String(source[compactHeartStart.lowerBound..<compactHeartEnd.lowerBound])
        let lockScreen = String(source[lockScreenStart.lowerBound...])

        XCTAssertTrue(island.contains("Text(signalFresh ? \"\\(context.state.heartRate) bpm\" : \"-- bpm\")"))
        XCTAssertTrue(island.contains(".lineLimit(1)"))
        XCTAssertTrue(island.contains(".minimumScaleFactor(0.62)"))
        XCTAssertTrue(island.contains(".allowsTightening(true)"))
        XCTAssertTrue(island.contains(".layoutPriority(2)"))
        XCTAssertTrue(island.contains("AtriaDynamicIslandCompactHeartRate(heartRate: context.state.heartRate"))
        XCTAssertTrue(compactHeart.contains("Text(isLive ? \"\\(heartRate)\" : \"--\")"),
                      "the compact island must show the live numeric HR without an overflowing suffix")
        XCTAssertTrue(compactHeart.contains(".lineLimit(1)"))
        XCTAssertTrue(compactHeart.contains(".minimumScaleFactor(0.55)"))
        XCTAssertTrue(compactHeart.contains("Heart rate \\(heartRate) beats per minute"))

        XCTAssertTrue(lockScreen.contains(".font(.system(size: 34, weight: .black, design: .rounded))"))
        XCTAssertTrue(lockScreen.contains(".minimumScaleFactor(0.58)"))
        XCTAssertTrue(lockScreen.contains(".layoutPriority(3)"))
        XCTAssertTrue(lockScreen.contains("Text(\"BPM\")"))
        XCTAssertTrue(lockScreen.contains(".fixedSize()"),
                      "the BPM suffix must stay separate so a three-digit reading cannot wrap it")
        XCTAssertTrue(lockScreen.contains(".lineLimit(1)"))
        XCTAssertTrue(lockScreen.contains(".minimumScaleFactor(0.68)"),
                      "the HR-zone, step, calorie, and strain row must shrink rather than wrap")
    }

    func testLiveActivityExposesTruthfulBatteryAndSensorStatus() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let source = try String(contentsOf: testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("AtriaWidget/AtriaWidget.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains(".labelStyle(.titleAndIcon)"),
                      "the Lock Screen must show the strap percentage instead of hiding the title")
        XCTAssertTrue(source.contains("\"\\(state.batteryLevel)% · Charging\""))
        XCTAssertTrue(source.contains("\"\\(state.batteryLevel)% · Low\""))
        XCTAssertTrue(source.contains("state.batteryLevel <= 20 ? .red : .secondary"))
        XCTAssertTrue(source.contains(".accessibilityLabel(\"Sensor status \\(sensorStatus)\")"),
                      "VoiceOver must read the actual syncing/stale status")
        XCTAssertFalse(source.contains(".accessibilityLabel(\"Sensor status\")"))
        XCTAssertTrue(source.contains(".accessibilityLabel(\"\\(context.state.activityName ?? \"Workout\") workout\")"),
                      "compact and minimal island presentations need a meaningful activity label")
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

    func testActionFileQueueClaimsSortsAndAcknowledgesEveryTap() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let start = now.addingTimeInterval(-1_200)
        let queue = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtriaLiveActionQueueTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: queue,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: queue) }

        let pause = AtriaPendingLiveWorkoutAction(action: .pause,
                                                  workoutStartedAt: start,
                                                  issuedAt: now.addingTimeInterval(-4))
        let resume = AtriaPendingLiveWorkoutAction(action: .resume,
                                                   workoutStartedAt: start,
                                                   issuedAt: now.addingTimeInterval(-3))
        let end = AtriaPendingLiveWorkoutAction(action: .end,
                                                workoutStartedAt: start,
                                                issuedAt: now.addingTimeInterval(-2))
        // Unique files model three extension processes racing to append. File
        // enumeration order must not determine application order.
        try writeAction(end, to: queue, name: "pending-c.json")
        try writeAction(pause, to: queue, name: "pending-a.json")
        try writeAction(resume, to: queue, name: "pending-b.json")

        let consumed = AtriaLiveWorkoutActionStore.consumeAll(
            now: now,
            defaults: nil,
            queueDirectoryURL: queue
        )

        XCTAssertEqual(consumed, [pause, resume, end])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: queue.path).count, 3,
                       "claims must survive until the workout owner applies them")
        consumed.forEach {
            AtriaLiveWorkoutActionStore.acknowledge($0, queueDirectoryURL: queue)
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: queue.path).isEmpty,
                      "claimed command files should be acknowledged exactly once")
        XCTAssertTrue(AtriaLiveWorkoutActionStore.consumeAll(
            now: now,
            defaults: nil,
            queueDirectoryURL: queue
        ).isEmpty)
    }

    func testActionFileQueueDropsMalformedStaleAndFutureCommands() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let queue = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtriaLiveActionValidationTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: queue,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: queue) }

        let stale = AtriaPendingLiveWorkoutAction(action: .pause,
                                                  workoutStartedAt: now.addingTimeInterval(-800),
                                                  issuedAt: now.addingTimeInterval(-301))
        let future = AtriaPendingLiveWorkoutAction(action: .end,
                                                   workoutStartedAt: now,
                                                   issuedAt: now.addingTimeInterval(6))
        try writeAction(stale, to: queue, name: "pending-stale.json")
        try writeAction(future, to: queue, name: "pending-future.json")
        try Data("not-json".utf8).write(to: queue.appendingPathComponent("pending-bad.json"))

        XCTAssertTrue(AtriaLiveWorkoutActionStore.consumeAll(
            now: now,
            defaults: nil,
            queueDirectoryURL: queue
        ).isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: queue.path).isEmpty,
                      "invalid commands must be acknowledged rather than replayed")
    }

    func testActionFileQueueRecoversOnlyExpiredClaims() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let start = now.addingTimeInterval(-100)
        let queue = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtriaLiveActionClaimTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: queue,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: queue) }

        let expired = AtriaPendingLiveWorkoutAction(action: .pause,
                                                    workoutStartedAt: start,
                                                    issuedAt: now.addingTimeInterval(-4))
        let active = AtriaPendingLiveWorkoutAction(action: .resume,
                                                   workoutStartedAt: start,
                                                   issuedAt: now.addingTimeInterval(-3))
        let expiredURL = try writeAction(expired, to: queue, name: "claimed-old.json")
        let activeURL = try writeAction(active, to: queue, name: "claimed-active.json")
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-31)],
                                              ofItemAtPath: expiredURL.path)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-5)],
                                              ofItemAtPath: activeURL.path)

        XCTAssertEqual(AtriaLiveWorkoutActionStore.consumeAll(
            now: now,
            defaults: nil,
            queueDirectoryURL: queue
        ), [expired])
        XCTAssertTrue(FileManager.default.fileExists(atPath: activeURL.path),
                      "a live consumer's claim must not be stolen")
    }

    func testActionFileQueueReleaseMakesSessionRestorationRetryImmediate() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let queue = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtriaLiveActionReleaseTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: queue,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: queue) }
        let pause = AtriaPendingLiveWorkoutAction(action: .pause,
                                                  workoutStartedAt: now.addingTimeInterval(-60),
                                                  issuedAt: now.addingTimeInterval(-1))
        try writeAction(pause, to: queue, name: "pending-pause.json")

        let firstClaim = try XCTUnwrap(AtriaLiveWorkoutActionStore.consumeAll(
            now: now,
            defaults: nil,
            queueDirectoryURL: queue
        ).first)
        AtriaLiveWorkoutActionStore.release(firstClaim, queueDirectoryURL: queue)
        let retry = AtriaLiveWorkoutActionStore.consumeAll(
            now: now,
            defaults: nil,
            queueDirectoryURL: queue
        )

        XCTAssertEqual(retry, [pause])
        retry.forEach {
            AtriaLiveWorkoutActionStore.acknowledge($0, queueDirectoryURL: queue)
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: queue.path).isEmpty)
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

    @discardableResult
    private func writeAction(_ action: AtriaPendingLiveWorkoutAction,
                             to directory: URL,
                             name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try JSONEncoder().encode(action).write(to: url, options: .atomic)
        return url
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

    func testPendingWorkoutDefersTransientIdleActivityReconciliation() {
        XCTAssertTrue(AtriaLiveActivityCoordinator.shouldDeferExistingActivityReconciliation(
            snapshotIsRecording: false,
            pendingWorkoutIsActive: true
        ))
        XCTAssertFalse(AtriaLiveActivityCoordinator.shouldDeferExistingActivityReconciliation(
            snapshotIsRecording: true,
            pendingWorkoutIsActive: true
        ))
        XCTAssertFalse(AtriaLiveActivityCoordinator.shouldDeferExistingActivityReconciliation(
            snapshotIsRecording: false,
            pendingWorkoutIsActive: false
        ))
    }

    func testSlowActivityKitWriterKeepsOnlyNewestSuccessorAndBackgroundProtection() {
        let first = liveSnapshot(elapsed: 100, heartRate: 120)
        var newer = first
        newer.heartRate = 126
        newer.elapsedDuration = 104
        var newest = newer
        newest.heartRate = 131
        newest.heartRateZoneIndex = 4
        newest.heartRateZoneName = "Anaerobic"

        let queued = AtriaLiveActivityCoordinator.coalescedActivityUpdate(
            existing: nil,
            incoming: newer,
            protectsBackgroundWrite: true
        )
        let replaced = AtriaLiveActivityCoordinator.coalescedActivityUpdate(
            existing: queued,
            incoming: newest,
            protectsBackgroundWrite: false
        )

        XCTAssertEqual(replaced.snapshot, newest)
        XCTAssertTrue(replaced.protectsBackgroundWrite,
                      "replacing a queued metric pulse must retain the background-boundary assertion")
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

        var moreCalories = baseline
        moreCalories.activeEnergyKilocalories = 81
        XCTAssertFalse(AtriaLiveActivityCoordinator.shouldSendActivityUpdateImmediately(
            previous: baseline,
            current: moreCalories,
            elapsedSinceLastWrite: 4.9
        ))
        XCTAssertTrue(AtriaLiveActivityCoordinator.shouldSendActivityUpdateImmediately(
            previous: baseline,
            current: moreCalories,
            elapsedSinceLastWrite: 5
        ))

        var caloriesUnavailable = baseline
        caloriesUnavailable.activeEnergyKilocalories = nil
        XCTAssertTrue(AtriaLiveActivityCoordinator.shouldSendActivityUpdateImmediately(
            previous: baseline,
            current: caloriesUnavailable,
            elapsedSinceLastWrite: 0.1
        ), "calorie availability must update immediately rather than leave a prior estimate visible")

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

    func testPauseResumeAndSourceRecoveryTransitionsBypassCadence() {
        let running = liveSnapshot(elapsed: 100, heartRate: 122)
        var paused = running
        paused.isPaused = true
        XCTAssertTrue(AtriaLiveActivityCoordinator.shouldSendActivityUpdateImmediately(
            previous: running,
            current: paused,
            elapsedSinceLastWrite: 0.1
        ))

        var resumed = paused
        resumed.isPaused = false
        XCTAssertTrue(AtriaLiveActivityCoordinator.shouldSendActivityUpdateImmediately(
            previous: paused,
            current: resumed,
            elapsedSinceLastWrite: 0.1
        ))

        var stale = resumed
        stale.heartRateAvailability = .stale
        stale.stepsAvailability = .stale
        XCTAssertTrue(AtriaLiveActivityCoordinator.shouldSendActivityUpdateImmediately(
            previous: resumed,
            current: stale,
            elapsedSinceLastWrite: 0.1
        ))

        var recovered = stale
        recovered.heartRateAvailability = .live
        recovered.stepsAvailability = .live
        recovered.heartRateCapturedAt = recovered.heartRateCapturedAt?.addingTimeInterval(1)
        recovered.stepsCapturedAt = recovered.stepsCapturedAt?.addingTimeInterval(1)
        XCTAssertTrue(AtriaLiveActivityCoordinator.shouldSendActivityUpdateImmediately(
            previous: stale,
            current: recovered,
            elapsedSinceLastWrite: 0.1
        ))
    }

    func testExactDailyStepGoalCrossingPublishesImmediatelyButEstimateDoesNotClaimIt() {
        var below = liveSnapshot(elapsed: 100, heartRate: 122)
        below.dailySteps = 7_999
        below.dailyStepsAreEstimated = false
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

    func testActivityStaleDeadlineRedrawsAtFirstIndependentSensorExpiry() {
        let fallback = Date(timeIntervalSince1970: 2_000_000_000)
        let oldHeartRate = fallback.addingTimeInterval(-70)
        let reconnectedMotion = fallback.addingTimeInterval(-2)

        XCTAssertEqual(AtriaLiveActivityCoordinator.sensorStaleDate(
            heartRateCapturedAt: oldHeartRate,
            stepsCapturedAt: reconnectedMotion,
            fallback: fallback
        ), reconnectedMotion.addingTimeInterval(15))
        XCTAssertEqual(AtriaLiveActivityCoordinator.sensorStaleDate(
            heartRateCapturedAt: fallback,
            stepsCapturedAt: reconnectedMotion,
            fallback: fallback
        ), reconnectedMotion.addingTimeInterval(15))
        XCTAssertEqual(AtriaLiveActivityCoordinator.sensorStaleDate(
            heartRateCapturedAt: nil,
            stepsCapturedAt: nil,
            fallback: fallback
        ), fallback.addingTimeInterval(90))
    }

    func testExpiredOrUnavailableSourceCannotKeepFreshWorkoutContentGloballyStale() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let freshHeartRate = now.addingTimeInterval(-2)
        let expiredMotion = now.addingTimeInterval(-20)

        XCTAssertEqual(AtriaLiveActivityCoordinator.sensorStaleDate(
            heartRateCapturedAt: freshHeartRate,
            stepsCapturedAt: expiredMotion,
            fallback: now,
            heartRateAvailability: .live,
            stepsAvailability: .stale,
            sensorHasContact: true
        ), freshHeartRate.addingTimeInterval(90),
        "stale steps stay labelled stale, but must not mark current HR and workout metrics globally stale")

        XCTAssertEqual(AtriaLiveActivityCoordinator.sensorStaleDate(
            heartRateCapturedAt: freshHeartRate,
            stepsCapturedAt: now,
            fallback: now,
            heartRateAvailability: .reconnecting,
            stepsAvailability: .unavailable,
            sensorHasContact: false
        ), now,
        "without a live source, ActivityKit should consider the content stale immediately")
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

    func testCanonicalTerminalTransitionUpdatesThenDismissesLiveActivityPromptly() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let appDirectory = testsDirectory.deletingLastPathComponent().appendingPathComponent("Atria")
        let home = try String(contentsOf: appDirectory.appendingPathComponent("AtriaHomeView.swift"),
                              encoding: .utf8)
        let syncStart = try XCTUnwrap(home.range(of: "private func synchronizeWorkoutUIWithCanonicalIntent"))
        let syncEnd = try XCTUnwrap(home.range(of: "private func restoreOrFinalizePendingWorkoutIntent",
                                              range: syncStart.upperBound..<home.endIndex))
        let terminalSync = String(home[syncStart.lowerBound..<syncEnd.lowerBound])
        XCTAssertTrue(terminalSync.contains("updateLiveActivity(forceActivityWrite: true)"))

        let coordinator = try String(contentsOf: appDirectory
            .appendingPathComponent("AtriaLiveActivityCoordinator.swift"), encoding: .utf8)
        let endStart = try XCTUnwrap(coordinator.range(of: "private func endActivity(with snapshot"))
        let endFinish = try XCTUnwrap(coordinator.range(of: "private func contentState",
                                                       range: endStart.upperBound..<coordinator.endIndex))
        let terminal = String(coordinator[endStart.lowerBound..<endFinish.lowerBound])
        let update = try XCTUnwrap(terminal.range(of: "await activity.update(terminalContent)"))
        let end = try XCTUnwrap(terminal.range(of: "await activity.end(terminalContent"))
        XCTAssertLessThan(update.lowerBound, end.lowerBound)
        XCTAssertTrue(terminal.contains("contentState(from: snapshot, isEnding: true)"))
        XCTAssertTrue(terminal.contains("addingTimeInterval(2)"))
        XCTAssertTrue(coordinator.contains("beginBackgroundTask(\n                withName: \"Atria live workout terminal\""))
    }

    func testForegroundResumeRefreshesWorkoutMetricsAfterFirstFrame() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let home = try String(contentsOf: testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaHomeView.swift"), encoding: .utf8)
        let activeStart = try XCTUnwrap(home.range(
            of: "foregroundResumeTask = Task { @MainActor in"
        ))
        let activeEnd = try XCTUnwrap(home.range(
            of: "foregroundResumeTask = nil",
            range: activeStart.upperBound..<home.endIndex
        ))
        let resume = String(home[activeStart.lowerBound..<activeEnd.lowerBound])

        let firstFrameYield = try XCTUnwrap(resume.range(of: "await Task.yield()"))
        let liveRefresh = try XCTUnwrap(resume.range(
            of: "updateLiveActivity(forceActivityWrite: true)"
        ))
        let sleepSettlement = try XCTUnwrap(resume.range(
            of: "store.autoConfirmSleepOnForegroundIfUseful"
        ))
        XCTAssertLessThan(firstFrameYield.lowerBound, liveRefresh.lowerBound)
        XCTAssertLessThan(liveRefresh.lowerBound, sleepSettlement.lowerBound)
    }

    func testLockScreenActionPreservesIndependentSensorFreshness() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let source = try String(contentsOf: testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("AtriaShared/AtriaLiveWorkoutControlIntent.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("state.heartRateCapturedAt?.addingTimeInterval(90)"))
        XCTAssertTrue(source.contains("state.stepsCapturedAt?.addingTimeInterval(15)"))
        XCTAssertTrue(source.contains("state.batteryCapturedAt?.addingTimeInterval(10 * 60)"))
        XCTAssertTrue(source.contains("expiry > canonicalState.appliedAt"),
                      "an already-expired source must not keep a fresh source globally stale")
        XCTAssertTrue(source.contains("let staleDate = sourceExpiries.min()"),
                      "a Lock Screen command should advance to the next live source expiry")
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

    func testLiveActivityPayloadExcludesUnrenderedNowPlayingStateAndStaysBounded() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let projectDirectory = testsDirectory.deletingLastPathComponent()
        let schema = try String(contentsOf: projectDirectory
            .appendingPathComponent("Atria/AtriaLiveActivityAttributes.swift"), encoding: .utf8)
        let home = try String(contentsOf: projectDirectory
            .appendingPathComponent("Atria/AtriaHomeView.swift"), encoding: .utf8)

        for unrenderedField in ["mediaTitle", "mediaArtist", "mediaIsPlaying", "mediaHasNowPlayingInfo"] {
            XCTAssertFalse(schema.contains(unrenderedField))
        }
        let publisherStart = try XCTUnwrap(home.range(of: "private var liveActivityUpdates"))
        let publisherEnd = try XCTUnwrap(home.range(of: "private var hapticUpdates",
                                                    range: publisherStart.upperBound..<home.endIndex))
        XCTAssertFalse(home[publisherStart.lowerBound..<publisherEnd.lowerBound]
            .contains("mediaController.$state"),
            "Now Playing changes must not force an ActivityKit write for UI that never renders media")

        let state = AtriaLiveActivityAttributes.ContentState(
            heartRate: 188,
            strain: 20.9,
            batteryLevel: 100,
            batteryChargeStatus: "notCharging",
            batteryChargeText: "Not charging",
            batteryCapturedAt: Date(timeIntervalSince1970: 2_000_000_000),
            batteryChargeCapturedAt: nil,
            batteryAvailability: .live,
            readingCount: .max,
            updatedAt: Date(timeIntervalSince1970: 2_000_000_000),
            heartRateCapturedAt: Date(timeIntervalSince1970: 2_000_000_000),
            sensorHasContact: true,
            heartRateAvailability: .live,
            activityName: String(repeating: "W", count: 64),
            activitySystemImage: "figure.run",
            heartRateZoneIndex: 5,
            heartRateZoneName: String(repeating: "Z", count: 64),
            steps: .max,
            stepsAreEstimated: false,
            stepsCapturedAt: Date(timeIntervalSince1970: 2_000_000_000),
            stepsAvailability: .live,
            dailySteps: .max,
            dailyStepsAreEstimated: false,
            dailyStepGoal: .max,
            workoutStrain: 20.9,
            targetWorkoutStrain: 21,
            activeEnergyKilocalories: 99_999,
            targetLowerHeartRateZone: 1,
            targetUpperHeartRateZone: 5,
            isPaused: false,
            isEnding: false,
            timerAnchor: Date(timeIntervalSince1970: 2_000_000_000),
            elapsedDuration: 86_400
        )
        let encoded = try JSONEncoder().encode(state)
        XCTAssertLessThan(encoded.count, 4_096,
                          "ActivityKit rejects dynamic content whose encoded state exceeds 4 KB")

        var legacyObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded)
            as? [String: Any])
        legacyObject["mediaTitle"] = "Previously playing"
        legacyObject["mediaArtist"] = "Legacy artist"
        legacyObject["mediaIsPlaying"] = true
        legacyObject["mediaHasNowPlayingInfo"] = true
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        XCTAssertEqual(try JSONDecoder().decode(AtriaLiveActivityAttributes.ContentState.self,
                                                from: legacyData),
                       state,
                       "Removing unrendered keys must continue decoding an in-flight activity from the previous build")
    }

    func testWidgetFailsClosedAndDistinguishesLiveReconnectStaleUnavailable() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let widgetSourceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("AtriaWidget/AtriaWidget.swift")
        let source = try String(contentsOf: widgetSourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("state.sensorHasContact != false"))
        XCTAssertTrue(source.contains("now.timeIntervalSince(capturedAt) <= atriaHeartRateFreshness"))
        XCTAssertFalse(source.contains("state.heartRateCapturedAt ?? state.updatedAt"),
                       "unrelated activity updates must not make a legacy HR reading fresh")
        XCTAssertTrue(source.contains("guard let capturedAt = state.heartRateCapturedAt"),
                      "HR without its independent source timestamp must fail closed")
        XCTAssertTrue(source.contains("case .reconnecting: return \"Reconnecting\""))
        XCTAssertTrue(source.contains("case .stale: return \"HR stale\""))
        XCTAssertTrue(source.contains("case .unavailable: return \"Unavailable\""))
        XCTAssertTrue(source.contains("state.stepsAreEstimated ?? false"))
        XCTAssertTrue(source.contains("let capturedAt = state.stepsCapturedAt"))
        XCTAssertTrue(source.contains("now.timeIntervalSince(capturedAt) <= atriaStepFreshness"))
        XCTAssertTrue(source.contains("labelText: \"Steps reconnecting\""))
        XCTAssertTrue(source.contains("labelText: \"Steps stale\""))
        XCTAssertTrue(source.contains("labelText: \"Steps unavailable\""))
        XCTAssertTrue(source.contains("strap-derived workout steps"))
        XCTAssertTrue(source.contains("liveActivityStrainProgressText(for: context.state)"))
        XCTAssertTrue(source.contains("String(format: \"%.1f / %.1f\", strain, target)"))
        XCTAssertTrue(source.contains("String(format: \"Goal ✓ · %.1f\", strain)"))
        XCTAssertTrue(source.contains("let strain = state.workoutStrain else { return nil }"),
                      "workout goals must use the canonical workout-only strain projection")
        XCTAssertTrue(source.contains("guard state.workoutStrainAvailability == .live"),
                      "stale or disconnected strain must fail closed instead of retaining a numeric goal")
        XCTAssertTrue(source.contains("let capturedAt = state.batteryCapturedAt"),
                      "Lock Screen battery must have its own level-bearing evidence clock")
        XCTAssertTrue(source.contains("let capturedAt = state.batteryChargeCapturedAt"),
                      "the charging bolt must expire independently from the percentage")
        XCTAssertTrue(source.contains("age > atriaBatteryFreshness"))
        XCTAssertFalse(source.contains("state.batteryCapturedAt ?? state.updatedAt"),
                       "timer and HR writes must not renew battery evidence")
        XCTAssertTrue(source.contains("ProgressView(value: liveActivityStrainProgressFraction(for: context.state))"))
        XCTAssertTrue(source.contains("liveActivityDailyStepGoalPresentation(for: context.state)"))
        XCTAssertTrue(source.contains("state.dailyStepsAreEstimated ?? false"))
        XCTAssertTrue(source.contains("reached && !estimated"),
                      "preliminary steps must never claim an exact goal completion")
        XCTAssertTrue(source.contains("liveActivitySensorStatusText"))
        XCTAssertTrue(source.contains("return statuses.isEmpty ? nil"),
                      "healthy live sources must not waste Lock Screen space on a redundant status row")
        XCTAssertTrue(source.contains("\\(label) last \\(atriaCaptureTimeText($0))"),
                      "stale sensor values must reveal their actual capture time")
        XCTAssertTrue(source.contains("|| dailyStepGoal?.fraction != nil"),
                      "the goal progress row renders only with a live fraction; stale/unavailable honesty is carried by the presentation function and sensor status row")
        XCTAssertTrue(source.contains("text: \"Step goal stale\""),
                      "stale daily-goal evidence must keep its fail-closed presentation branch")
        XCTAssertTrue(source.contains("text: \"Step goal --\""),
                      "missing daily-goal evidence must keep its fail-closed presentation branch")
        XCTAssertTrue(source.contains("Label(dailyStepGoal.text, systemImage: \"target\")"))
        XCTAssertTrue(source.contains("liveActivityCaloriesText(for: context.state)"))
        XCTAssertTrue(source.contains("Approximately \\(Int(calories.rounded())) active calories"))
        XCTAssertTrue(source.contains("guard let calories = state.activeEnergyKilocalories"))
        XCTAssertTrue(source.contains("calories.isFinite"))
        XCTAssertTrue(source.contains("calories >= 0 else { return \"-- kcal\" }"),
                      "invalid or missing energy evidence must never be rendered as a fabricated calorie value")
        XCTAssertTrue(source.contains(".disabled(state.isEnding ?? false)"),
                      "controls must lock after End is accepted to prevent duplicate commands")

        let home = try String(contentsOf: testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaHomeView.swift"), encoding: .utf8)
        XCTAssertTrue(home.contains("steps: metricProjection.steps.count"))
        XCTAssertTrue(home.contains("activeEnergyKilocalories: metricProjection.loadIsComplete"))
        XCTAssertTrue(home.contains("? metricProjection.activeCalories : nil"),
                      "incomplete rolled or retroactively paused load must not publish precise calories")
        XCTAssertTrue(home.contains("stepsCapturedAt: metricProjection.steps.capturedAt"),
                      "A stale transition must retain its real source time for the Lock Screen's last-seen label")
        XCTAssertFalse(home.contains("stepsCapturedAt: metricProjection.steps.liveCapturedAt"))
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
        XCTAssertTrue(widgetSource.contains("accessibilityLabel(\"Target heart rate \\(target)\")"),
                      "the target zone must stay an accessible element wherever the layout renders it")
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
            batteryCapturedAt: Date(timeIntervalSince1970: 2_000_000_000),
            batteryChargeCapturedAt: nil,
            batteryAvailability: .live,
            batteryChargeStatus: .levelOnly,
            readingCount: 100,
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
            activeEnergyKilocalories: 80,
            isPaused: false,
            elapsedDuration: elapsed
        )
    }

    func testWorkoutStrainClockParticipatesInLiveActivityStaleness() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        XCTAssertEqual(AtriaLiveActivityCoordinator.sensorStaleDate(
            heartRateCapturedAt: nil,
            stepsCapturedAt: nil,
            strainCapturedAt: now,
            fallback: now,
            heartRateFreshnessWindow: 90,
            strainAvailability: .live
        ), now.addingTimeInterval(90))
        XCTAssertEqual(AtriaLiveActivityCoordinator.sensorStaleDate(
            heartRateCapturedAt: nil,
            stepsCapturedAt: nil,
            strainCapturedAt: now,
            fallback: now,
            strainAvailability: .stale
        ), now)
    }

    func testBatteryClockParticipatesInLiveActivityStalenessWithoutRenewingHR() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        XCTAssertEqual(AtriaLiveActivityCoordinator.sensorStaleDate(
            heartRateCapturedAt: nil,
            stepsCapturedAt: nil,
            batteryCapturedAt: now,
            fallback: now,
            batteryFreshnessWindow: 600,
            batteryAvailability: .live
        ), now.addingTimeInterval(600))
        XCTAssertEqual(AtriaLiveActivityCoordinator.sensorStaleDate(
            heartRateCapturedAt: nil,
            stepsCapturedAt: nil,
            batteryCapturedAt: now,
            fallback: now,
            batteryAvailability: .stale
        ), now)
    }

    func testLegacyLiveActivityStateDecodesWithoutBatteryFreshness() throws {
        let encoded = try JSONEncoder().encode(AtriaLiveActivityAttributes.ContentState(
            heartRate: 80, strain: 3.2, batteryLevel: 50,
            batteryChargeStatus: "levelOnly", batteryChargeText: "Unavailable",
            batteryCapturedAt: Date(), batteryChargeCapturedAt: Date(), batteryAvailability: .live,
            readingCount: 10, updatedAt: Date()
        ))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "batteryCapturedAt")
        object.removeValue(forKey: "batteryChargeCapturedAt")
        object.removeValue(forKey: "batteryAvailability")
        let decoded = try JSONDecoder().decode(
            AtriaLiveActivityAttributes.ContentState.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertNil(decoded.batteryCapturedAt)
        XCTAssertNil(decoded.batteryChargeCapturedAt)
        XCTAssertNil(decoded.batteryAvailability)
    }

    func testLegacyLiveActivityStateDecodesWithoutStrainFreshness() throws {
        let legacy = try JSONEncoder().encode(AtriaLiveActivityAttributes.ContentState(
            heartRate: 80, strain: 3.2, batteryLevel: 50,
            batteryChargeStatus: "levelOnly", batteryChargeText: "Unavailable",
            readingCount: 10, updatedAt: Date()
        ))
        var object = try JSONSerialization.jsonObject(with: legacy) as! [String: Any]
        object.removeValue(forKey: "workoutStrainCapturedAt")
        object.removeValue(forKey: "workoutStrainAvailability")
        let decoded = try JSONDecoder().decode(
            AtriaLiveActivityAttributes.ContentState.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertNil(decoded.workoutStrainCapturedAt)
        XCTAssertNil(decoded.workoutStrainAvailability)
    }
}
