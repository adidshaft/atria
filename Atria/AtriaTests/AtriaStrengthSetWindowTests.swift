import XCTest
@testable import Atria

final class AtriaStrengthSetWindowTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)

    override func tearDown() {
        AtriaStrengthSetWindow.live.cancel()
        super.tearDown()
    }

    func testStartIngestStopBindsOnlyInWindowSamplesFromIdle() throws {
        let start = origin
        let stop = start.addingTimeInterval(10)
        let incoming = [
            LoggedSetIMUSample(t: start.addingTimeInterval(-1), ax: 9, ay: 9, az: 9),
            LoggedSetIMUSample(t: start, ax: 1, ay: 2, az: 3),
            LoggedSetIMUSample(t: start.addingTimeInterval(4.5), ax: 4, ay: 5, az: 6),
            LoggedSetIMUSample(t: stop, ax: 7, ay: 8, az: 9),
            LoggedSetIMUSample(t: stop.addingTimeInterval(1), ax: 11, ay: 12, az: 13)
        ]
        let expected = incoming.filter { $0.t >= start && $0.t <= stop }

        let window = AtriaStrengthSetWindow()
        XCTAssertFalse(window.isOpen)

        window.start(at: start, draft: Self.draft)
        XCTAssertTrue(window.isOpen)
        window.ingest(incoming)

        let logged = try XCTUnwrap(window.stop(at: stop, labels: Self.labels))
        XCTAssertFalse(window.isOpen)

        let startedAt = try XCTUnwrap(logged.startedAt)
        let endedAt = try XCTUnwrap(logged.endedAt)
        XCTAssertLessThan(startedAt, endedAt)
        XCTAssertEqual(startedAt, start)
        XCTAssertEqual(endedAt, stop)
        XCTAssertEqual(logged.t, stop)
        XCTAssertEqual(endedAt.timeIntervalSince(startedAt),
                       stop.timeIntervalSince(start),
                       accuracy: 0.000_000_1)
        XCTAssertEqual(logged.imuSamples, expected)
        XCTAssertFalse(logged.imuSamples?.contains(where: { $0.t < start || $0.t > stop }) ?? false)
        XCTAssertEqual(logged.exercise, "Barbell row")
        XCTAssertEqual(logged.reps, 10)
    }

    func testStartStopWithZeroIMULogsEmptySeriesAndDoesNotFabricateSamples() throws {
        let start = origin
        let stop = start.addingTimeInterval(8)
        let window = AtriaStrengthSetWindow()
        window.start(at: start, draft: Self.draft)
        let logged = try XCTUnwrap(window.stop(at: stop, labels: Self.labels))

        XCTAssertEqual(logged.startedAt, start)
        XCTAssertEqual(logged.endedAt, stop)
        XCTAssertEqual(logged.t, stop)
        XCTAssertEqual(logged.imuSamples, [])
        XCTAssertEqual(logged.imuSamples?.count, 0)
    }

    func testIngestBeforeStartAndAfterStopIsIgnored() throws {
        let start = origin
        let stop = start.addingTimeInterval(5)
        let before = LoggedSetIMUSample(t: start.addingTimeInterval(-2), ax: 1, ay: 0, az: 0)
        let during = LoggedSetIMUSample(t: start.addingTimeInterval(1), ax: 2, ay: 0, az: 0)
        let after = LoggedSetIMUSample(t: stop.addingTimeInterval(2), ax: 3, ay: 0, az: 0)

        let window = AtriaStrengthSetWindow()
        window.ingest([before])
        window.start(at: start, draft: Self.draft)
        window.ingest([during])
        let logged = try XCTUnwrap(window.stop(at: stop, labels: Self.labels))
        window.ingest([after])

        XCTAssertEqual(logged.imuSamples, [during])
        XCTAssertNil(window.stop(at: stop.addingTimeInterval(10), labels: Self.labels))
    }

    func testStopWithoutOpenWindowReturnsNil() {
        let window = AtriaStrengthSetWindow()
        XCTAssertNil(window.stop(at: origin.addingTimeInterval(1), labels: Self.labels))
    }

    func testStopAtOrBeforeStartReturnsNil() throws {
        let window = AtriaStrengthSetWindow()
        window.start(at: origin, draft: Self.draft)
        XCTAssertNil(window.stop(at: origin, labels: Self.labels))
        XCTAssertTrue(window.isOpen)
        let logged = try XCTUnwrap(window.stop(at: origin.addingTimeInterval(0.5), labels: Self.labels))
        XCTAssertLessThan(try XCTUnwrap(logged.startedAt), try XCTUnwrap(logged.endedAt))
    }

    func testR10ConversionThenWindowBindUsesTheInputSeries() throws {
        let receivedAt = origin.addingTimeInterval(100)
        let acceleration = (0..<AtriaR10MotionDecoder.sampleCount).map { index in
            AtriaR10MotionFrame.Vector3(x: Double(index), y: 0.25, z: -0.5)
        }
        let frame = AtriaR10MotionFrame(deviceTimestamp: 42,
                                        heartRate: 88,
                                        acceleration: acceleration,
                                        rotationRate: acceleration.map { _ in
                                            AtriaR10MotionFrame.Vector3(x: 0, y: 0, z: 0)
                                        })
        let incoming = AtriaStrengthSetWindow.samples(fromR10: frame, receivedAt: receivedAt)
        XCTAssertEqual(incoming.count, acceleration.count)
        XCTAssertEqual(incoming.map(\.ax), acceleration.map(\.x))
        XCTAssertEqual(incoming.map(\.ay), acceleration.map(\.y))
        XCTAssertEqual(incoming.map(\.az), acceleration.map(\.z))
        XCTAssertEqual(incoming.last?.t, receivedAt)

        let start = receivedAt.addingTimeInterval(-0.5)
        let stop = receivedAt
        let expected = incoming.filter { $0.t >= start && $0.t <= stop }

        let window = AtriaStrengthSetWindow()
        window.start(at: start, draft: Self.draft)
        window.ingest(incoming)
        let logged = try XCTUnwrap(window.stop(at: stop, labels: Self.labels))
        XCTAssertEqual(logged.imuSamples, expected)
        XCTAssertFalse(expected.isEmpty)
    }

    func testDecodedIMUConversionKeepsDecoderAxesAndReceiptTime() throws {
        let decoded = try XCTUnwrap(AtriaIMUDecoder.decode(payload: AtriaIMUDecoder.syntheticShakePayload()))
        let receivedAt = origin.addingTimeInterval(3)
        let incoming = AtriaStrengthSetWindow.samples(fromDecoded: decoded, receivedAt: receivedAt)
        XCTAssertEqual(incoming.map(\.ax), decoded.samples.map(\.xG))
        XCTAssertEqual(incoming.map(\.ay), decoded.samples.map(\.yG))
        XCTAssertEqual(incoming.map(\.az), decoded.samples.map(\.zG))
        XCTAssertTrue(incoming.allSatisfy { $0.t == receivedAt })

        let window = AtriaStrengthSetWindow()
        window.start(at: origin, draft: Self.draft)
        window.ingest(incoming)
        let outside = origin.addingTimeInterval(1)
        let missed = try XCTUnwrap(window.stop(at: outside, labels: Self.labels))
        XCTAssertEqual(missed.imuSamples, [])

        let window2 = AtriaStrengthSetWindow()
        window2.start(at: origin, draft: Self.draft)
        window2.ingest(incoming)
        let logged = try XCTUnwrap(window2.stop(at: origin.addingTimeInterval(5), labels: Self.labels))
        XCTAssertEqual(logged.imuSamples, incoming)
    }

    func testWindowedSetJSONRoundTripEqualsOriginalBoundSeries() throws {
        let start = origin
        let stop = start.addingTimeInterval(6)
        let incoming = [
            LoggedSetIMUSample(t: start.addingTimeInterval(-0.2), ax: 0, ay: 0, az: 1),
            LoggedSetIMUSample(t: start.addingTimeInterval(1), ax: 0.1, ay: 0.2, az: 0.9),
            LoggedSetIMUSample(t: start.addingTimeInterval(2.5), ax: -0.4, ay: 0.3, az: 0.8)
        ]
        let window = AtriaStrengthSetWindow()
        window.start(at: start, draft: Self.draft)
        window.ingest(incoming)
        let logged = try XCTUnwrap(window.stop(at: stop, labels: Self.labels))
        let expected = incoming.filter { $0.t >= start && $0.t <= stop }

        let restored = try JSONDecoder().decode(LoggedSet.self, from: JSONEncoder().encode(logged))
        XCTAssertEqual(restored, logged)
        XCTAssertEqual(restored.imuSamples, expected)
        XCTAssertEqual(restored.startedAt, start)
        XCTAssertEqual(restored.endedAt, stop)
        XCTAssertEqual(restored.t, stop)
    }

    func testLegacyLoggedSetJSONWithOnlyTStillDecodes() throws {
        let t = origin.addingTimeInterval(90)
        let id = UUID(uuidString: "AA120000-0000-4000-8000-000000000001") ?? UUID()
        let payload = LegacyLoggedSetPayload(id: id,
                                             exercise: "Bench press",
                                             weightKg: 80,
                                             reps: 6,
                                             rpe: 8.5,
                                             t: t,
                                             effectiveLoadKg: 80)
        let restored = try JSONDecoder().decode(LoggedSet.self, from: JSONEncoder().encode(payload))
        XCTAssertEqual(restored.id, id)
        XCTAssertEqual(restored.exercise, "Bench press")
        XCTAssertEqual(restored.t, t)
        XCTAssertEqual(restored.weightKg, 80)
        XCTAssertEqual(restored.reps, 6)
        XCTAssertNil(restored.startedAt)
        XCTAssertNil(restored.endedAt)
        XCTAssertNil(restored.imuSamples)
    }

    @MainActor
    func testConfirmedWorkoutPersistsStartEndAndBoundIMU() async throws {
        let store = SessionStore()
        let marker = "set-window-" + UUID().uuidString
        let workoutStart = Date(timeIntervalSince1970: 2_140_000_000 + Double.random(in: 0..<100_000))
        let setStart = workoutStart.addingTimeInterval(8 * 60)
        let setStop = setStart.addingTimeInterval(12)
        let incoming = [
            LoggedSetIMUSample(t: setStart.addingTimeInterval(-1), ax: 3, ay: 0, az: 0),
            LoggedSetIMUSample(t: setStart.addingTimeInterval(2), ax: 0.2, ay: -0.1, az: 0.95),
            LoggedSetIMUSample(t: setStop.addingTimeInterval(3), ax: 8, ay: 8, az: 8)
        ]
        let window = AtriaStrengthSetWindow()
        window.start(at: setStart, draft: Self.draft)
        window.ingest(incoming)
        let set = try XCTUnwrap(window.stop(at: setStop, labels: Self.labels))
        let expectedIMU = incoming.filter { $0.t >= setStart && $0.t <= setStop }

        let confirmed = await store.confirmWorkoutWindowForUI(
            start: workoutStart,
            end: workoutStart.addingTimeInterval(30 * 60),
            rest: 60,
            maxHR: 190,
            source: marker,
            preserveUserDeclaredActivityWithoutHeartRate: true,
            activityType: "Strength",
            strengthSets: [set],
            reviewSource: marker
        )
        let workout = try XCTUnwrap(confirmed)
        defer { Task { @MainActor in _ = await store.deleteConfirmedWorkout(id: workout.id) } }

        XCTAssertEqual(workout.strengthSets, [set])
        XCTAssertEqual(workout.strengthSets?.first?.startedAt, setStart)
        XCTAssertEqual(workout.strengthSets?.first?.endedAt, setStop)
        XCTAssertEqual(workout.strengthSets?.first?.imuSamples, expectedIMU)

        let decoded = try JSONDecoder().decode(UserConfirmedWorkout.self,
                                               from: JSONEncoder().encode(workout))
        XCTAssertEqual(decoded.strengthSets, [set])
        XCTAssertEqual(decoded.strengthSets?.first?.imuSamples, expectedIMU)
    }

    func testOpeningLabelsWhileSetIsOpenKeepsPendingDraftNotLastLoggedSet() throws {
        let last = LoggedSet(exercise: "Barbell row",
                             weightKg: 70,
                             reps: 10,
                             rpe: nil,
                             t: origin)
        let pending = AtriaStrengthSetWindow.Draft(exercise: "Barbell row",
                                                   weightKg: 75,
                                                   reps: 8,
                                                   rpe: 7)
        let window = AtriaStrengthSetWindow()
        window.start(at: origin, draft: pending)
        XCTAssertTrue(window.isOpen)

        let opened = AtriaStrengthSetWindow.draftForOpeningLabels(
            setWindowIsOpen: window.isOpen,
            current: pending,
            lastLoggedForExercise: last
        )
        XCTAssertEqual(opened, pending)
        XCTAssertEqual(opened.weightKg, pending.weightKg)
        XCTAssertEqual(opened.reps, pending.reps)
        XCTAssertEqual(opened.rpe, pending.rpe)
        XCTAssertNotEqual(opened.weightKg, last.weightKg)
        XCTAssertNotEqual(opened.reps, last.reps)
        window.updateDraft(opened)

        let logged = try XCTUnwrap(window.stop(
            at: origin.addingTimeInterval(6),
            labels: AtriaStrengthSetWindow.Labels(exercise: opened.exercise,
                                                  weightKg: opened.weightKg,
                                                  reps: opened.reps,
                                                  rpe: opened.rpe,
                                                  effectiveLoadKg: opened.weightKg)
        ))
        XCTAssertEqual(logged.weightKg, pending.weightKg)
        XCTAssertEqual(logged.reps, pending.reps)
        XCTAssertEqual(logged.rpe, pending.rpe)
        XCTAssertEqual(window.draft, nil)
    }

    func testOpeningLabelsWhileIdlePrimesWeightAndRepsFromLastLoggedSet() {
        let last = LoggedSet(exercise: "Barbell row",
                             weightKg: 70,
                             reps: 10,
                             rpe: 9,
                             t: origin)
        let pending = AtriaStrengthSetWindow.Draft(exercise: "Barbell row",
                                                   weightKg: 75,
                                                   reps: 8,
                                                   rpe: 7)
        let opened = AtriaStrengthSetWindow.draftForOpeningLabels(
            setWindowIsOpen: false,
            current: pending,
            lastLoggedForExercise: last
        )
        XCTAssertEqual(opened.weightKg, last.weightKg)
        XCTAssertEqual(opened.reps, last.reps)
        XCTAssertEqual(opened.rpe, pending.rpe)
        XCTAssertNotEqual(opened, pending)
    }

    func testLiveWorkoutSurfaceContainsStartSetAndStopAndLogSet() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Atria/AtriaLiveWorkoutView.swift"),
            encoding: .utf8)
        XCTAssertTrue(source.contains("Start Set"))
        XCTAssertTrue(source.contains("Stop & log set"))
        XCTAssertTrue(source.contains("AtriaStrengthSetWindow.live.start"))
        XCTAssertTrue(source.contains("AtriaStrengthSetWindow.live.stop"))
        XCTAssertTrue(source.contains("Label(setWindowIsOpen ? \"Stop & log set\" : \"Start Set\""))
        XCTAssertTrue(source.contains("openSetLabelsSheet()"))
        XCTAssertTrue(source.contains("AtriaStrengthSetWindow.draftForOpeningLabels"))
        let labelsStart = try XCTUnwrap(source.range(of: "private func openSetLabelsSheet()"))
        let labelsEnd = try XCTUnwrap(source.range(of: "private func applyOpeningLabelsDraft",
                                                   range: labelsStart.upperBound..<source.endIndex))
        let openLabels = String(source[labelsStart.lowerBound..<labelsEnd.lowerBound])
        XCTAssertTrue(openLabels.contains("setWindowIsOpen: setWindowIsOpen"))
        XCTAssertFalse(openLabels.contains("primeLoggerFromLastSet()"),
                       "opening labels while a set is open must not prime from the last logged set")
    }

    func testBLEFeedsExistingDecodersIntoTheOpenSetWindow() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Atria/AtriaBLEManager.swift"),
            encoding: .utf8)
        XCTAssertTrue(source.contains("AtriaStrengthSetWindow.ingestLiveR10(frame: r10Frame, receivedAt: receivedAt)"))
        XCTAssertTrue(source.contains("AtriaStrengthSetWindow.ingestLiveDecoded(decoded, receivedAt: Date())"))
        XCTAssertTrue(source.contains("AtriaR10MotionDecoder.decode(frame: completeFrame)"))
        XCTAssertTrue(source.contains("AtriaIMUDecoder.decode(payload: payload)"))
    }

    // Objective 3: the live BLE tap (ingestLiveR10) must feed the SHARED live
    // window only while a set is open. If R10 frames flow but imuSamples stays
    // empty, this proves the bug is upstream (no frames) rather than in the tap
    // or window: with a set open, an in-window frame binds; frames before Start
    // and after Stop never bind.
    func testLiveStaticTapBindsOnlyInWindowFramesWhileOpen() throws {
        let start = origin
        let stop = start.addingTimeInterval(3)

        // Before Start: the tap is a no-op (guard live.isOpen).
        XCTAssertFalse(AtriaStrengthSetWindow.live.isOpen)
        AtriaStrengthSetWindow.ingestLiveR10(frame: Self.r10Frame(value: 1),
                                             receivedAt: start.addingTimeInterval(-1))

        AtriaStrengthSetWindow.live.start(at: start, draft: Self.draft)
        let inFrame = Self.r10Frame(value: 2)
        let inReceivedAt = start.addingTimeInterval(1.5) // whole frame inside [start, stop]
        AtriaStrengthSetWindow.ingestLiveR10(frame: inFrame, receivedAt: inReceivedAt)

        let logged = try XCTUnwrap(AtriaStrengthSetWindow.live.stop(at: stop, labels: Self.labels))
        // After Stop: another frame must not bind to the just-closed window.
        AtriaStrengthSetWindow.ingestLiveR10(frame: Self.r10Frame(value: 9),
                                             receivedAt: stop.addingTimeInterval(1))

        let expected = AtriaStrengthSetWindow.samples(fromR10: inFrame, receivedAt: inReceivedAt)
        XCTAssertFalse(expected.isEmpty)
        XCTAssertEqual(logged.imuSamples, expected)
        XCTAssertFalse(logged.imuSamples?.contains(where: { $0.t < start || $0.t > stop }) ?? true)
    }

    private static func r10Frame(value: Double) -> AtriaR10MotionFrame {
        let acceleration = (0..<AtriaR10MotionDecoder.sampleCount).map { _ in
            AtriaR10MotionFrame.Vector3(x: value, y: 0.25, z: -0.5)
        }
        return AtriaR10MotionFrame(deviceTimestamp: 0,
                                   heartRate: 80,
                                   acceleration: acceleration,
                                   rotationRate: acceleration.map { _ in
                                       AtriaR10MotionFrame.Vector3(x: 0, y: 0, z: 0)
                                   })
    }

    private static let draft = AtriaStrengthSetWindow.Draft(exercise: "Barbell row",
                                                            weightKg: 70,
                                                            reps: 10,
                                                            rpe: 8)
    private static let labels = AtriaStrengthSetWindow.Labels(exercise: "Barbell row",
                                                              weightKg: 70,
                                                              reps: 10,
                                                              rpe: 8,
                                                              effectiveLoadKg: 70)

    private struct LegacyLoggedSetPayload: Encodable {
        var id: UUID
        var exercise: String
        var weightKg: Double?
        var reps: Int?
        var rpe: Double?
        var t: Date
        var effectiveLoadKg: Double?
    }
}
