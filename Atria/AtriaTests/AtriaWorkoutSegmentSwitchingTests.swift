import XCTest
@testable import Atria

/// In-workout activity switching (2026-08-30): timestamped, user-declared
/// segments on the pending intent and the confirmed record; dominant-segment
/// scalar at finalize; derived (never stored) per-segment attribution; and
/// the logger-availability + switcher-affordance product rules.
@MainActor
final class AtriaWorkoutSegmentSwitchingTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 2_000_000_000)

    private func makeIntent(segments: [WorkoutSegment]? = nil) -> AtriaPendingWorkoutIntent {
        AtriaPendingWorkoutIntent(startedAt: start,
                                  endedAt: nil,
                                  activityType: AtriaWorkoutActivityType.walking.rawValue,
                                  strengthSets: [],
                                  excludedIntervals: [],
                                  startingStepCount: 0,
                                  startingDayStrain: 0,
                                  segments: segments)
    }

    // MARK: - Switch recording

    func testFirstSwitchSeedsOriginalTypeAtSessionStartThenAppends() {
        var session = AtriaWorkoutSession(start: start, activityType: .walking)
        XCTAssertNil(session.segments, "No switch yet: the timeline must stay nil")

        let firstSwitch = start.addingTimeInterval(600)
        session.recordActivitySwitch(to: .strength, at: firstSwitch)

        XCTAssertEqual(session.activityType, .strength)
        XCTAssertEqual(session.segments, [
            WorkoutSegment(activityType: AtriaWorkoutActivityType.walking.rawValue,
                           startedAt: start),
            WorkoutSegment(activityType: AtriaWorkoutActivityType.strength.rawValue,
                           startedAt: firstSwitch),
        ], "First switch seeds the ORIGINAL type at session start, then appends the new type")

        let secondSwitch = start.addingTimeInterval(1_500)
        session.recordActivitySwitch(to: .cycling, at: secondSwitch)
        XCTAssertEqual(session.segments?.count, 3)
        XCTAssertEqual(session.segments?.last,
                       WorkoutSegment(activityType: AtriaWorkoutActivityType.cycling.rawValue,
                                      startedAt: secondSwitch))
    }

    func testSameTypeSwitchIsANoOp() {
        var session = AtriaWorkoutSession(start: start, activityType: .walking)
        session.recordActivitySwitch(to: .walking, at: start.addingTimeInterval(60))
        XCTAssertNil(session.segments, "Re-selecting the current type must not mint segments")
        XCTAssertEqual(session.activityType, .walking)
    }

    func testSwitchTimestampBeforeSessionStartIsClampedToStart() {
        var session = AtriaWorkoutSession(start: start, activityType: .walking)
        session.recordActivitySwitch(to: .strength, at: start.addingTimeInterval(-30))
        XCTAssertEqual(session.segments?.last?.startedAt, start,
                       "A skewed clock cannot declare a switch before the session existed")
    }

    // MARK: - Regression pin: no switch == byte-identical persisted intent

    func testNoSwitchEncodesWithoutSegmentsKeyAndLegacyPayloadDecodesClean() throws {
        let data = try JSONEncoder().encode(makeIntent())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["segments"],
                     "Nil segments must omit the key: a never-switched intent's payload is byte-identical to pre-segment builds")

        // A legacy payload (no segments key) must decode with nil segments.
        struct LegacyIntent: Encodable {
            let startedAt: Date
            let endedAt: Date?
            let activityType: String
            let strengthSets: [LoggedSet]
            let excludedIntervals: [ExcludedInterval]
        }
        let legacy = LegacyIntent(startedAt: start,
                                  endedAt: nil,
                                  activityType: AtriaWorkoutActivityType.walking.rawValue,
                                  strengthSets: [],
                                  excludedIntervals: [])
        let decoded = try JSONDecoder().decode(AtriaPendingWorkoutIntent.self,
                                               from: JSONEncoder().encode(legacy))
        XCTAssertNil(decoded.segments)
        XCTAssertEqual(decoded.resolvedActivityType, .walking)
    }

    func testSegmentsSurviveIntentRoundTrip() throws {
        let segments = [
            WorkoutSegment(activityType: AtriaWorkoutActivityType.walking.rawValue,
                           startedAt: start),
            WorkoutSegment(activityType: AtriaWorkoutActivityType.strength.rawValue,
                           startedAt: start.addingTimeInterval(700)),
        ]
        let intent = makeIntent(segments: segments)
        let decoded = try JSONDecoder().decode(AtriaPendingWorkoutIntent.self,
                                               from: JSONEncoder().encode(intent))
        XCTAssertEqual(decoded, intent)
        XCTAssertEqual(decoded.segments, segments)
    }

    func testConfirmedWorkoutSegmentsRoundTripAndOmitKeyWhenNil() throws {
        let workout = UserConfirmedWorkout(id: "seg-roundtrip",
                                           createdAt: start,
                                           start: start,
                                           end: start.addingTimeInterval(3600),
                                           label: "Live workout",
                                           source: "live_workout_window",
                                           confidence: "live_window_user_confirmed",
                                           sessions: 1,
                                           samples: 100,
                                           avgHR: 120,
                                           peakHR: 160,
                                           p95HR: 150,
                                           p99HR: 158,
                                           thresholdHR: 100,
                                           streamCoveragePercent: 95,
                                           observedDuration: 3500,
                                           reason: "test")
        // Nil segments: the persisted record must not gain a key (byte pin).
        let plainObject = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(workout)) as? [String: Any])
        XCTAssertNil(plainObject["segments"])

        var switched = workout
        switched.segments = [
            WorkoutSegment(activityType: AtriaWorkoutActivityType.walking.rawValue,
                           startedAt: start),
            WorkoutSegment(activityType: AtriaWorkoutActivityType.strength.rawValue,
                           startedAt: start.addingTimeInterval(1200)),
        ]
        let decoded = try JSONDecoder().decode(UserConfirmedWorkout.self,
                                               from: JSONEncoder().encode(switched))
        XCTAssertEqual(decoded.segments, switched.segments)

        // Legacy record (key removed) decodes clean with nil segments.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(switched)) as? [String: Any])
        object.removeValue(forKey: "segments")
        let legacyDecoded = try JSONDecoder().decode(
            UserConfirmedWorkout.self,
            from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(legacyDecoded.segments)
    }

    // MARK: - Dominant-segment scalar

    func testDominantSegmentIsLongestByMovingDuration() {
        let segments = [
            WorkoutSegment(activityType: AtriaWorkoutActivityType.walking.rawValue,
                           startedAt: start),
            WorkoutSegment(activityType: AtriaWorkoutActivityType.strength.rawValue,
                           startedAt: start.addingTimeInterval(600)),
        ]
        // Walking 10 min, strength 50 min -> strength dominates.
        XCTAssertEqual(WorkoutSegment.dominantActivityType(
            segments: segments,
            sessionStart: start,
            sessionEnd: start.addingTimeInterval(3600),
            excludedIntervals: []
        ), AtriaWorkoutActivityType.strength.rawValue)
    }

    func testDominantSegmentUsesMovingNotWallDuration() {
        let segments = [
            WorkoutSegment(activityType: AtriaWorkoutActivityType.strength.rawValue,
                           startedAt: start),
            WorkoutSegment(activityType: AtriaWorkoutActivityType.walking.rawValue,
                           startedAt: start.addingTimeInterval(1200)),
        ]
        // Strength 20 min wall but 15 min paused (5 moving); walking 10 min
        // moving -> walking dominates on MOVING duration.
        let pause = ExcludedInterval(start: start.addingTimeInterval(60),
                                     end: start.addingTimeInterval(960))
        XCTAssertEqual(WorkoutSegment.dominantActivityType(
            segments: segments,
            sessionStart: start,
            sessionEnd: start.addingTimeInterval(1800),
            excludedIntervals: [pause]
        ), AtriaWorkoutActivityType.walking.rawValue)
    }

    func testDominantSegmentTieGoesToLastSegment() {
        let segments = [
            WorkoutSegment(activityType: AtriaWorkoutActivityType.walking.rawValue,
                           startedAt: start),
            WorkoutSegment(activityType: AtriaWorkoutActivityType.strength.rawValue,
                           startedAt: start.addingTimeInterval(900)),
        ]
        // Exactly 15 min each -> the LAST segment wins the tie.
        XCTAssertEqual(WorkoutSegment.dominantActivityType(
            segments: segments,
            sessionStart: start,
            sessionEnd: start.addingTimeInterval(1800),
            excludedIntervals: []
        ), AtriaWorkoutActivityType.strength.rawValue)
    }

    func testDominantSegmentIsNilWithoutTimeline() {
        XCTAssertNil(WorkoutSegment.dominantActivityType(
            segments: nil,
            sessionStart: start,
            sessionEnd: start.addingTimeInterval(1800),
            excludedIntervals: []
        ), "No timeline: the scalar stays exactly what the session says today")
    }

    // MARK: - Derived per-segment attribution

    func testPerSegmentAttributionRespectsBoundsExclusionsAndZones() {
        let sessionEnd = start.addingTimeInterval(3600)
        let switchAt = start.addingTimeInterval(1800)
        let segments = [
            WorkoutSegment(activityType: AtriaWorkoutActivityType.walking.rawValue,
                           startedAt: start.addingTimeInterval(-120)), // clamps to start
            WorkoutSegment(activityType: AtriaWorkoutActivityType.strength.rawValue,
                           startedAt: switchAt),
        ]
        // 10 s cadence; walking phase at 100 bpm, strength phase at 150 bpm.
        var samples: [HRSample] = []
        var t: TimeInterval = 0
        while t <= 3600 {
            samples.append(HRSample(t: start.addingTimeInterval(t),
                                    bpm: t < 1800 ? 100 : 150))
            t += 10
        }
        // Pause 30..40 min: excluded samples must not contribute anywhere.
        let pause = ExcludedInterval(start: start.addingTimeInterval(1800),
                                     end: start.addingTimeInterval(2400))
        let slices = AtriaWorkoutSegmentAttribution.derive(
            segments: segments,
            sessionStart: start,
            sessionEnd: sessionEnd,
            samples: samples,
            excludedIntervals: [pause],
            maxHR: 200,
            restingHR: 60
        )
        XCTAssertEqual(slices.count, 2)

        XCTAssertEqual(slices[0].start, start, "Pre-session switch timestamp clamps to the session start")
        XCTAssertEqual(slices[0].end, switchAt)
        XCTAssertEqual(slices[0].movingDuration, 1800, accuracy: 0.001)
        XCTAssertEqual(slices[0].meanHR, 100)
        XCTAssertNotNil(slices[0].zoneSeconds, "Real dense samples must yield derived zone time")

        XCTAssertEqual(slices[1].start, switchAt)
        XCTAssertEqual(slices[1].end, sessionEnd)
        XCTAssertEqual(slices[1].movingDuration, 1200, accuracy: 0.001,
                       "The 10-minute pause must be removed from the strength slice")
        XCTAssertEqual(slices[1].meanHR, 150,
                       "Excluded samples must not pull the strength mean")
        // Zone check: at maxHR 200 / rest 60, 150 bpm sits in one HRR zone
        // bucket; all attributed seconds land there, none in walking's bucket.
        let strengthZones = slices[1].zoneSeconds ?? [:]
        XCTAssertGreaterThan(strengthZones.values.reduce(0, +), 0)
        XCTAssertNil(strengthZones["rest"],
                     "150 bpm slices must not attribute rest-zone time")
    }

    func testAttributionIsEmptyWithoutSwitchTimeline() {
        let workout = UserConfirmedWorkout(id: "seg-none",
                                           createdAt: start,
                                           start: start,
                                           end: start.addingTimeInterval(600),
                                           label: "Walk",
                                           source: "live_workout_window",
                                           confidence: "user_confirmed_no_hr",
                                           sessions: 0,
                                           samples: 0,
                                           avgHR: 0,
                                           peakHR: 0,
                                           p95HR: 0,
                                           p99HR: 0,
                                           thresholdHR: 100,
                                           streamCoveragePercent: 0,
                                           observedDuration: 0,
                                           reason: "test")
        XCTAssertEqual(AtriaWorkoutSegmentAttribution.derive(workout: workout,
                                                             sessions: [],
                                                             fallbackRestingHR: 60,
                                                             fallbackMaxHR: 190),
                       [],
                       "Single-type workouts derive nothing and render nothing new")
    }

    // MARK: - Logger availability

    func testSetLoggerAvailabilityRules() {
        let strengthSet = LoggedSet(exercise: "Barbell bench press",
                                    weightKg: 60,
                                    reps: 8,
                                    rpe: nil,
                                    t: start)
        // Current type supports exercise selection.
        XCTAssertTrue(AtriaLiveWorkoutView.showsSetLoggingControls(
            activityType: .strength, loggedSets: [], segments: nil))
        // Plain walk: no logger.
        XCTAssertFalse(AtriaLiveWorkoutView.showsSetLoggingControls(
            activityType: .walking, loggedSets: [], segments: nil))
        // A set already logged this session keeps the logger available.
        XCTAssertTrue(AtriaLiveWorkoutView.showsSetLoggingControls(
            activityType: .walking, loggedSets: [strengthSet], segments: nil))
        // A past strength segment keeps the logger available after switching.
        XCTAssertTrue(AtriaLiveWorkoutView.showsSetLoggingControls(
            activityType: .walking,
            loggedSets: [],
            segments: [
                WorkoutSegment(activityType: AtriaWorkoutActivityType.strength.rawValue,
                               startedAt: start),
                WorkoutSegment(activityType: AtriaWorkoutActivityType.walking.rawValue,
                               startedAt: start.addingTimeInterval(600)),
            ]))
        // Segments of non-exercise types add nothing.
        XCTAssertFalse(AtriaLiveWorkoutView.showsSetLoggingControls(
            activityType: .walking,
            loggedSets: [],
            segments: [
                WorkoutSegment(activityType: AtriaWorkoutActivityType.running.rawValue,
                               startedAt: start),
                WorkoutSegment(activityType: AtriaWorkoutActivityType.walking.rawValue,
                               startedAt: start.addingTimeInterval(600)),
            ]))
    }

    // MARK: - Persisted save path

    func testMetadataOnlySaveCarriesSegmentsOntoConfirmedRecord() async throws {
        let store = SessionStore()
        let marker = "segments-save-\(UUID().uuidString)"
        // Unique window per run: the confirmed-workout id derives from the
        // exact bounds, and a leftover record from an earlier run would take
        // the merge branch instead of the fresh-save branch under test.
        let saveStart = Date(timeIntervalSince1970: 2_050_100_000
                             + Double(Int.random(in: 0..<3_000_000)))
        let saveEnd = saveStart.addingTimeInterval(30 * 60)
        let segments = [
            WorkoutSegment(activityType: AtriaWorkoutActivityType.walking.rawValue,
                           startedAt: saveStart),
            WorkoutSegment(activityType: AtriaWorkoutActivityType.strength.rawValue,
                           startedAt: saveStart.addingTimeInterval(10 * 60)),
        ]
        let saved = await store.confirmWorkoutWindowForUIAsync(
            start: saveStart,
            end: saveEnd,
            rest: 60,
            maxHR: 190,
            source: marker,
            preserveUserDeclaredActivityWithoutHeartRate: true,
            activityType: AtriaWorkoutActivityType.strength.rawValue,
            reviewSource: marker,
            segments: segments
        )
        let confirmed = try XCTUnwrap(saved)
        defer {
            let id = confirmed.id
            Task { @MainActor in _ = await store.deleteConfirmedWorkout(id: id) }
        }
        XCTAssertEqual(confirmed.segments, segments,
                       "The declared switch timeline must land on the confirmed record at finalize")
        XCTAssertEqual(confirmed.activityType,
                       AtriaWorkoutActivityType.strength.rawValue)
    }

    // MARK: - Switcher affordance source pins

    func testSwitcherAffordanceAndCopyArePinned() throws {
        let liveViewURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // AtriaTests
            .deletingLastPathComponent()   // Atria (project dir)
            .appendingPathComponent("Atria/AtriaLiveWorkoutView.swift")
        let source = try String(contentsOf: liveViewURL, encoding: .utf8)
        XCTAssertTrue(source.contains("Switch activity — keeps recording"),
                      "The switcher menu must state that switching keeps recording")
        XCTAssertTrue(source.contains("Section(\"Switch activity — keeps recording\")"),
                      "The copy belongs to the switch section header")
        // The affordance is a visibly-chromed 44pt control, not bare text.
        let headerRange = try XCTUnwrap(source.range(of: "private var header: some View"))
        let headerSlice = source[headerRange.lowerBound...].prefix(3200)
        XCTAssertTrue(headerSlice.contains(".buttonStyle(.glass)"),
                      "Switcher label carries visible glass chrome")
        XCTAssertTrue(headerSlice.contains(".frame(minHeight: 44)"),
                      "Switcher stays a 44pt target")
        XCTAssertTrue(headerSlice.contains("chevron.up.chevron.down"),
                      "Switcher keeps the disclosure chevron")

        let homeURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaHomeView.swift")
        let home = try String(contentsOf: homeURL, encoding: .utf8)
        XCTAssertTrue(home.contains("session.recordActivitySwitch(to: newType, at: Date())"),
                      "The binding setter must commit switches through the session's timeline recorder")
        XCTAssertTrue(home.contains("segments: finalIntent.segments"),
                      "Finalize must carry the timeline onto the confirmed save path")
    }
}
