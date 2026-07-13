import XCTest
@testable import Atria

@MainActor
final class AtriaStepCalibrationPlanTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "AtriaStepCalibrationPlanTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testStageContractMatchesFitterSequence() {
        XCTAssertEqual(AtriaStepCalibrationPlanStore.stages.map(\.label), [
            "Rest before", "Slow 100", "Normal 100", "Brisk 100", "Normal 200", "Rest after",
        ])
        XCTAssertEqual(AtriaStepCalibrationPlanStore.stages.map(\.kind), [
            .rest, .walk, .walk, .walk, .walk, .rest,
        ])
        XCTAssertEqual(AtriaStepCalibrationPlanStore.stages.map(\.expectedSteps), [0, 100, 100, 100, 200, 0])
    }

    func testMachineTimestampsAndAdvancesEveryStage() throws {
        var milliseconds: Int64 = 1_720_000_000_000
        let store = makeStore(milliseconds: { milliseconds })

        for (index, stage) in AtriaStepCalibrationPlanStore.stages.enumerated() {
            XCTAssertEqual(store.currentStage, stage)
            XCTAssertTrue(store.startCurrentStage())
            let startMS = try XCTUnwrap(store.state.activeStageStartMS)
            milliseconds += max(stage.minimumDurationMS, Int64(10_000 + index))
            XCTAssertTrue(store.stopCurrentStage(validatedQuality: readyQuality(
                startMS: startMS,
                endMS: milliseconds
            )))
            let window = try XCTUnwrap(store.state.windows.last)
            XCTAssertEqual(window.label, stage.label)
            XCTAssertEqual(window.kind, stage.kind)
            XCTAssertEqual(window.expectedSteps, stage.expectedSteps)
            XCTAssertEqual(window.endMS, milliseconds)
            milliseconds += 1_000
        }

        XCTAssertTrue(store.isComplete)
        XCTAssertNil(store.currentStage)
        XCTAssertEqual(store.manifest.windows.count, 6)
    }

    func testRestStagesRejectStopBeforeSixtySeconds() {
        var milliseconds: Int64 = 1_720_000_000_000
        let store = makeStore(milliseconds: { milliseconds })
        XCTAssertTrue(store.startCurrentStage())

        milliseconds += 59_999
        XCTAssertFalse(store.canStopCurrentStage())
        XCTAssertFalse(store.stopCurrentStage(validatedQuality: readyQuality(
            startMS: 1_720_000_000_000,
            endMS: milliseconds
        )))
        XCTAssertTrue(store.isRunning)

        milliseconds += 1
        XCTAssertTrue(store.canStopCurrentStage())
        XCTAssertTrue(store.stopCurrentStage(validatedQuality: readyQuality(
            startMS: 1_720_000_000_000,
            endMS: milliseconds
        )))
        XCTAssertEqual(store.state.windows.first?.endMS, milliseconds)
    }

    func testActiveStageSurvivesStoreRecreationAndCanStop() throws {
        var milliseconds: Int64 = 1_720_000_000_000
        var store: AtriaStepCalibrationPlanStore? = makeStore(milliseconds: { milliseconds })
        XCTAssertTrue(store?.startCurrentStage() == true)
        let startMS = try XCTUnwrap(store?.state.activeStageStartMS)

        store = nil
        milliseconds += 60_000
        let resumed = makeStore(milliseconds: { milliseconds })
        XCTAssertTrue(resumed.isRunning)
        XCTAssertEqual(resumed.state.activeStageStartMS, startMS)
        XCTAssertEqual(resumed.currentStage?.label, "Rest before")
        XCTAssertTrue(resumed.stopCurrentStage(validatedQuality: readyQuality(
            startMS: startMS,
            endMS: milliseconds
        )))
        XCTAssertEqual(resumed.currentStage?.label, "Slow 100")
    }

    func testFailedCaptureCannotAdvanceAndRetryKeepsEarlierStages() {
        var milliseconds: Int64 = 1_720_000_000_000
        let store = makeStore(milliseconds: { milliseconds })
        XCTAssertTrue(store.startCurrentStage())
        milliseconds += 60_000
        let failed = AtriaStrapCalibrationArchive.CaptureQuality(
            decodedFrames: 20,
            durationMS: 60_000,
            coveragePercent: 33.3,
            continuityBreaks: 8,
            maximumUncoveredGapMS: 12_000,
            alignedStartMS: 1_720_000_000_000,
            alignedEndMSExclusive: milliseconds
        )

        XCTAssertFalse(store.stopCurrentStage(validatedQuality: failed))
        XCTAssertEqual(store.completedStageCount, 0)
        XCTAssertTrue(store.isRunning)

        store.discardCurrentStage()
        XCTAssertFalse(store.isRunning)
        XCTAssertEqual(store.currentStage?.label, "Rest before")
        XCTAssertTrue(store.startCurrentStage())
    }

    func testRestartClearsDurableState() {
        var milliseconds: Int64 = 1_720_000_000_000
        let store = makeStore(milliseconds: { milliseconds })
        XCTAssertTrue(store.startCurrentStage())
        let startMS = try! XCTUnwrap(store.state.activeStageStartMS)
        milliseconds += 60_000
        XCTAssertTrue(store.stopCurrentStage(validatedQuality: readyQuality(
            startMS: startMS,
            endMS: milliseconds
        )))

        store.restart()

        XCTAssertEqual(store.completedStageCount, 0)
        XCTAssertFalse(store.isRunning)
        XCTAssertNil(defaults.data(forKey: AtriaStepCalibrationPlanStore.defaultsKey))
    }

    func testExportUsesExactFitterJSONKeys() throws {
        var milliseconds: Int64 = 1_720_000_000_000
        let store = makeStore(milliseconds: { milliseconds })
        for stage in AtriaStepCalibrationPlanStore.stages {
            XCTAssertTrue(store.startCurrentStage())
            let startMS = try XCTUnwrap(store.state.activeStageStartMS)
            milliseconds += max(stage.minimumDurationMS, 5_000)
            XCTAssertTrue(store.stopCurrentStage(validatedQuality: readyQuality(
                startMS: startMS,
                endMS: milliseconds
            )))
            milliseconds += 1_000
        }

        let url = try store.writeManifest()
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try Data(contentsOf: url)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(root.keys), ["windows"])
        let windows = try XCTUnwrap(root["windows"] as? [[String: Any]])
        XCTAssertEqual(windows.count, 6)
        XCTAssertEqual(Set(windows[0].keys), ["label", "kind", "start_ms", "end_ms", "expected_steps"])

        let decoded = try JSONDecoder().decode(FitterManifest.self, from: data)
        XCTAssertEqual(decoded.windows.map(\.expectedSteps), [0, 100, 100, 100, 200, 0])
        XCTAssertEqual(decoded.windows.map(\.kind), ["rest", "walk", "walk", "walk", "walk", "rest"])
    }

    func testMalformedPersistedSequenceFailsClosed() throws {
        let malformed = AtriaStepCalibrationPlanStore.PersistedState(
            sessionStartedMS: 1,
            activeStageIndex: nil,
            activeStageStartMS: nil,
            windows: [
                AtriaStepCalibrationManifest.Window(
                    label: "Wrong stage",
                    kind: .walk,
                    startMS: 10,
                    endMS: 20,
                    expectedSteps: 999
                ),
            ]
        )
        defaults.set(try JSONEncoder().encode(malformed), forKey: AtriaStepCalibrationPlanStore.defaultsKey)

        let store = makeStore(milliseconds: { 1_720_000_000_000 })

        XCTAssertEqual(store.completedStageCount, 0)
        XCTAssertNil(defaults.data(forKey: AtriaStepCalibrationPlanStore.defaultsKey))
    }

    func testResearchUIWaitsForFreshMotionBeforeTimestamping() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceRoot = testsDirectory.deletingLastPathComponent().appendingPathComponent("Atria")
        let planSource = try String(
            contentsOf: sourceRoot.appendingPathComponent("AtriaStepCalibrationPlan.swift"),
            encoding: .utf8
        )
        let bleSource = try String(
            contentsOf: sourceRoot.appendingPathComponent("AtriaBLEManager.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(planSource.contains("ble.stepCalibrationMotionStreamReady"))
        XCTAssertTrue(planSource.contains("Waiting for fresh motion"))
        XCTAssertTrue(bleSource.contains("markStepCalibrationMotionStreamReady(receivedAt:"))
        XCTAssertTrue(bleSource.contains("finishStepCalibrationCapture"))

        let armStart = try XCTUnwrap(bleSource.range(of: "func armStepCalibrationCapture("))
        let finishStart = try XCTUnwrap(bleSource.range(
            of: "func finishStepCalibrationCapture(",
            range: armStart.upperBound..<bleSource.endIndex
        ))
        let armBody = String(bleSource[armStart.lowerBound..<finishStart.lowerBound])
        for forbidden in [
            "applyStandardHROnly(",
            "reconnect: true",
            "rediscoverFullProtocolServicesIfConnected",
            "setNotifyValue(",
            "requestStrapStatusRead(",
            "startOfflineHistoricalSync(",
            "writeValue(",
        ] {
            XCTAssertFalse(armBody.contains(forbidden), forbidden)
        }
        XCTAssertTrue(armBody.contains("stepCalibrationCaptureArmedAt = now"))
        XCTAssertTrue(armBody.contains("stepCalibrationMotionStreamReady = false"))
        XCTAssertTrue(armBody.contains("transport=existing_protected_r10"))

        let finishEnd = try XCTUnwrap(bleSource.range(
            of: "func setLongWearModeEnabled(",
            range: finishStart.upperBound..<bleSource.endIndex
        ))
        let finishBody = String(bleSource[finishStart.lowerBound..<finishEnd.lowerBound])
        XCTAssertFalse(finishBody.contains("applyStandardHROnly("))
        XCTAssertFalse(finishBody.contains("reconnect: true"))
        XCTAssertTrue(finishBody.contains("AtriaStrapCalibrationArchive.shared.flush()"))
    }

    func testCalibrationToolsUseDeviceTimeAndPreserveContinuousDetectorState() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for name in ["replay_step_calibration.swift", "fit_step_calibration.swift"] {
            let source = try String(
                contentsOf: projectRoot.appendingPathComponent("tools/\(name)"),
                encoding: .utf8
            )
            XCTAssertTrue(source.contains("Int64(decoded.deviceTimestamp) * 1_000"), name)
            XCTAssertTrue(source.contains("sampleAtMS >="), name)
            XCTAssertFalse(source.contains("minuteSamples"), name)
            XCTAssertFalse(source.contains("rawStepCountByProductionMinute"), name)
        }
    }

    private func makeStore(milliseconds: @escaping () -> Int64) -> AtriaStepCalibrationPlanStore {
        AtriaStepCalibrationPlanStore(
            defaults: defaults,
            now: { Date(timeIntervalSince1970: Double(milliseconds()) / 1_000) }
        )
    }

    private func readyQuality(startMS: Int64,
                              endMS: Int64) -> AtriaStrapCalibrationArchive.CaptureQuality {
        AtriaStrapCalibrationArchive.CaptureQuality(
            decodedFrames: max(1, Int((endMS - startMS) / 1_000)),
            durationMS: endMS - startMS,
            coveragePercent: 100,
            continuityBreaks: 0,
            maximumUncoveredGapMS: 0,
            alignedStartMS: startMS,
            alignedEndMSExclusive: endMS
        )
    }
}

private struct FitterManifest: Decodable {
    struct Window: Decodable {
        let label: String
        let kind: String
        let startMS: Int64
        let endMS: Int64
        let expectedSteps: Int

        enum CodingKeys: String, CodingKey {
            case label
            case kind
            case startMS = "start_ms"
            case endMS = "end_ms"
            case expectedSteps = "expected_steps"
        }
    }

    let windows: [Window]
}
