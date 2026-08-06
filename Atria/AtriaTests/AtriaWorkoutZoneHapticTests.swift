import XCTest
@testable import Atria

final class AtriaWorkoutZoneHapticTests: XCTestCase {
    func testBoundaryTransitionsProduceRequestedPulseCounts() {
        var detector = AtriaWorkoutZoneHapticTransition()

        XCTAssertNil(detector.accept(bpm: 110, lowerBPM: 120, upperBPM: 150))
        XCTAssertEqual(detector.accept(bpm: 120, lowerBPM: 120, upperBPM: 150), 1)
        XCTAssertNil(detector.accept(bpm: 149, lowerBPM: 120, upperBPM: 150))
        XCTAssertEqual(detector.accept(bpm: 153, lowerBPM: 120, upperBPM: 150), 3)
        XCTAssertEqual(detector.accept(bpm: 150, lowerBPM: 120, upperBPM: 150), 2)
        XCTAssertEqual(detector.accept(bpm: 117, lowerBPM: 120, upperBPM: 150), 1)
    }

    func testHysteresisPreventsBoundaryChatter() {
        var detector = AtriaWorkoutZoneHapticTransition()
        XCTAssertNil(detector.accept(bpm: 130, lowerBPM: 120, upperBPM: 150))
        XCTAssertNil(detector.accept(bpm: 151, lowerBPM: 120, upperBPM: 150))
        XCTAssertNil(detector.accept(bpm: 119, lowerBPM: 120, upperBPM: 150))
        XCTAssertEqual(detector.accept(bpm: 117, lowerBPM: 120, upperBPM: 150), 1)
    }

    func testLifecycleContinuesAcrossPresentationChangesWithoutDuplicatePulses() {
        let startedAt = Date(timeIntervalSince1970: 100)
        var lifecycle = AtriaWorkoutZoneHapticLifecycle()
        lifecycle.configure(workoutStartedAt: startedAt,
                            lowerTargetZone: HRZone.fatBurn.rawValue,
                            upperTargetZone: HRZone.aerobic.rawValue,
                            maxHR: 200,
                            isPaused: false)

        // Initial accepted sample establishes a silent baseline below Z2.
        XCTAssertNil(lifecycle.accept(bpm: 110))
        XCTAssertEqual(lifecycle.accept(bpm: 120), 1)

        // A minimize/reopen synchronization repeats the exact configuration.
        // Detector state must survive, so the same BPM cannot fire again.
        lifecycle.configure(workoutStartedAt: startedAt,
                            lowerTargetZone: HRZone.fatBurn.rawValue,
                            upperTargetZone: HRZone.aerobic.rawValue,
                            maxHR: 200,
                            isPaused: false)
        XCTAssertNil(lifecycle.accept(bpm: 120))
        XCTAssertEqual(lifecycle.accept(bpm: 162), 3)
        XCTAssertNil(lifecycle.accept(bpm: 162))
    }

    func testLifecyclePauseAndRestoreEstablishSilentBaselines() {
        let startedAt = Date(timeIntervalSince1970: 200)
        var lifecycle = AtriaWorkoutZoneHapticLifecycle()
        lifecycle.configure(workoutStartedAt: startedAt,
                            lowerTargetZone: HRZone.fatBurn.rawValue,
                            upperTargetZone: HRZone.aerobic.rawValue,
                            maxHR: 200,
                            isPaused: false)
        XCTAssertNil(lifecycle.accept(bpm: 130))

        lifecycle.configure(workoutStartedAt: startedAt,
                            lowerTargetZone: HRZone.fatBurn.rawValue,
                            upperTargetZone: HRZone.aerobic.rawValue,
                            maxHR: 200,
                            isPaused: true)
        XCTAssertNil(lifecycle.accept(bpm: 170))

        lifecycle.configure(workoutStartedAt: startedAt,
                            lowerTargetZone: HRZone.fatBurn.rawValue,
                            upperTargetZone: HRZone.aerobic.rawValue,
                            maxHR: 200,
                            isPaused: false)
        XCTAssertNil(lifecycle.accept(bpm: 170), "resume must not vibrate from a stale pre-pause band")
        XCTAssertEqual(lifecycle.accept(bpm: 150), 2)

        // App/process restoration installs the same persisted targets into a
        // fresh lifecycle. Its first sample is likewise silent.
        var restored = AtriaWorkoutZoneHapticLifecycle()
        restored.configure(workoutStartedAt: startedAt,
                           lowerTargetZone: HRZone.fatBurn.rawValue,
                           upperTargetZone: HRZone.aerobic.rawValue,
                           maxHR: 200,
                           isPaused: false)
        XCTAssertNil(restored.accept(bpm: 170))
    }

    func testLifecycleNormalizesTargetsAndResetsWhenWorkoutEnds() throws {
        let startedAt = Date(timeIntervalSince1970: 300)
        var lifecycle = AtriaWorkoutZoneHapticLifecycle()
        lifecycle.configure(workoutStartedAt: startedAt,
                            lowerTargetZone: HRZone.anaerobic.rawValue,
                            upperTargetZone: HRZone.fatBurn.rawValue,
                            maxHR: 200,
                            isPaused: false)
        let configuration = try XCTUnwrap(lifecycle.configuration)
        XCTAssertEqual(configuration.lowerZone, .fatBurn)
        XCTAssertEqual(configuration.upperZone, .anaerobic)
        XCTAssertNil(lifecycle.accept(bpm: 110))
        XCTAssertEqual(lifecycle.accept(bpm: 120), 1)

        lifecycle.configure(workoutStartedAt: nil,
                            lowerTargetZone: nil,
                            upperTargetZone: nil,
                            maxHR: 200,
                            isPaused: false)
        XCTAssertNil(lifecycle.configuration)
        XCTAssertNil(lifecycle.accept(bpm: 180))
    }

    func testTargetBoundariesUseHeartRateReserveMatchingTheDisplay() throws {
        // GAP-03: the target haptic must fire at the same HR-reserve (Karvonen)
        // boundaries the live zone bar shows, not percent-of-max. With rest = 50,
        // max = 200 (reserve 150): Z2 fat burn (0.60) starts at 50 + 0.60*150 = 140,
        // and the window's upper edge is one below Z4 anaerobic (0.80):
        // 50 + 0.80*150 = 170, so upper = 169. Percent-of-max would give 120 / 159.
        var lifecycle = AtriaWorkoutZoneHapticLifecycle()
        lifecycle.configure(workoutStartedAt: Date(timeIntervalSince1970: 500),
                            lowerTargetZone: HRZone.fatBurn.rawValue,
                            upperTargetZone: HRZone.aerobic.rawValue,
                            maxHR: 200,
                            restingHR: 50,
                            isPaused: false)
        let configuration = try XCTUnwrap(lifecycle.configuration)
        XCTAssertEqual(configuration.lowerBPM, 140, "lower target must be HR-reserve, not 0.60*max = 120")
        XCTAssertEqual(configuration.upperBPM, 169, "upper target must be HR-reserve, not 0.80*max - 1 = 159")

        // The haptic boundaries must equal the ones the display renders.
        let displayed = try XCTUnwrap(AtriaHRRZoneBoundaries(restingHR: 50, maxHR: 200))
        XCTAssertEqual(configuration.lowerBPM, displayed.lowerBPM(for: .fatBurn))
        XCTAssertEqual(configuration.upperBPM, displayed.lowerBPM(for: .anaerobic) - 1)
    }

    func testTargetBoundariesFallBackToPercentOfMaxWithoutRestingBaseline() throws {
        // With no valid resting baseline the boundaries degrade to percent-of-max
        // so coaching still works; the existing behavior is preserved.
        var lifecycle = AtriaWorkoutZoneHapticLifecycle()
        lifecycle.configure(workoutStartedAt: Date(timeIntervalSince1970: 600),
                            lowerTargetZone: HRZone.fatBurn.rawValue,
                            upperTargetZone: HRZone.aerobic.rawValue,
                            maxHR: 200,
                            restingHR: 0,
                            isPaused: false)
        let configuration = try XCTUnwrap(lifecycle.configuration)
        XCTAssertEqual(configuration.lowerBPM, 120)
        XCTAssertEqual(configuration.upperBPM, 159)
    }

    func testStartConfigurationNormalizesReversedZoneRange() {
        let configuration = AtriaWorkoutStartConfiguration(activityType: .running,
                                                            lowerTargetZone: 4,
                                                            upperTargetZone: 2)
        XCTAssertEqual(configuration.normalizedZoneRange, 2...4)
    }

    func testProtectedTransportAllowsOnlyTheExplicitWorkoutHapticException() {
        XCTAssertFalse(AtriaBLEManager.shouldAllowProtectedTransportCommand(
            command: AtriaBLEManager.Cmd.toggleRealtimeHR,
            standardHROnlyMode: true,
            historyOnlyProbeEnabled: false,
            explicitWorkoutHaptic: false
        ), "ordinary proprietary writes stay blocked on the protected transport")
        XCTAssertTrue(AtriaBLEManager.shouldAllowProtectedTransportCommand(
            command: AtriaBLEManager.Cmd.runHapticsPattern,
            standardHROnlyMode: true,
            historyOnlyProbeEnabled: false,
            explicitWorkoutHaptic: true
        ), "a user-requested zone transition must reach the strap")
        XCTAssertTrue(AtriaBLEManager.shouldAllowProtectedTransportCommand(
            command: AtriaBLEManager.Cmd.toggleRealtimeHR,
            standardHROnlyMode: false,
            historyOnlyProbeEnabled: false,
            explicitWorkoutHaptic: false
        ))
        XCTAssertFalse(AtriaBLEManager.shouldAllowProtectedTransportCommand(
            command: AtriaBLEManager.Cmd.toggleRealtimeHR,
            standardHROnlyMode: true,
            historyOnlyProbeEnabled: false,
            explicitWorkoutHaptic: true
        ), "the exception is command-level, not a generic proprietary-write bypass")
    }

    func testPendingIntentDecodesPayloadWrittenBeforeZoneTargetsExisted() throws {
        let json = #"{"startedAt":0,"activityType":"Walking","strengthSets":[],"excludedIntervals":[],"startingStepCount":0,"startingDayStrain":0}"#.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let intent = try decoder.decode(AtriaPendingWorkoutIntent.self, from: json)
        XCTAssertNil(intent.lowerTargetZone)
        XCTAssertNil(intent.upperTargetZone)
    }

    func testPendingIntentRoundTripsSelectedZoneTargetsForRestoration() throws {
        let suiteName = "AtriaWorkoutZoneHapticTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let intent = AtriaPendingWorkoutIntent(
            startedAt: Date(timeIntervalSince1970: 400),
            endedAt: nil,
            activityType: AtriaWorkoutActivityType.running.rawValue,
            strengthSets: [],
            excludedIntervals: [],
            lowerTargetZone: HRZone.fatBurn.rawValue,
            upperTargetZone: HRZone.anaerobic.rawValue,
            startingStepCount: 500,
            startingDayStrain: 4.2
        )

        XCTAssertTrue(intent.save(defaults: defaults))
        let restored = try XCTUnwrap(AtriaPendingWorkoutIntent.load(defaults: defaults))
        XCTAssertEqual(restored.lowerTargetZone, HRZone.fatBurn.rawValue)
        XCTAssertEqual(restored.upperTargetZone, HRZone.anaerobic.rawValue)
    }

    func testZoneHapticOwnershipIsNotAttachedToVisibleWorkoutView() throws {
        let projectDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appDirectory = projectDirectory.appendingPathComponent("Atria")
        let liveView = try String(contentsOf: appDirectory.appendingPathComponent("AtriaLiveWorkoutView.swift"),
                                  encoding: .utf8)
        let manager = try String(contentsOf: appDirectory.appendingPathComponent("AtriaBLEManager.swift"),
                                 encoding: .utf8)
        let home = try String(contentsOf: appDirectory.appendingPathComponent("AtriaHomeView.swift"),
                              encoding: .utf8)

        XCTAssertFalse(liveView.contains("AtriaWorkoutZoneHapticObserver"))
        XCTAssertFalse(liveView.contains("onZoneHaptic:"))
        XCTAssertTrue(manager.contains("workoutZoneHapticLifecycle.accept(bpm: displayRate)"))
        XCTAssertTrue(manager.contains("explicitWorkoutHaptic: true"))
        XCTAssertTrue(home.contains("onChange(of: workoutZoneHapticConfiguration, initial: true)"))
        XCTAssertTrue(home.contains("lowerTargetZone: workoutSession.lowerTargetZone"))
        XCTAssertTrue(home.contains("upperTargetZone: workoutSession.upperTargetZone"))
    }
}
