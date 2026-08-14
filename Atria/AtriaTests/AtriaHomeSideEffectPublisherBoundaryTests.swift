import XCTest

final class AtriaHomeSideEffectPublisherBoundaryTests: XCTestCase {
    func testHighFrequencySideEffectsUseSemanticPublishers() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let source = try String(contentsOf: testsDirectory.deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaHomeView.swift"), encoding: .utf8)

        XCTAssertFalse(source.contains("private var liveSideEffectUpdates"))
        for publisher in ["liveActivityUpdates", "hapticUpdates", "liveWidgetUpdates", "workoutDetectionUpdates"] {
            XCTAssertTrue(source.contains("private var \(publisher): AnyPublisher<Void, Never>"))
            XCTAssertTrue(source.contains(".onReceive(\(publisher))"))
        }
        // 2026-08-14 pin migration: the App Review restructure moved the
        // ownership guards into named handlers. The invariants are unchanged:
        // detection stays silent during an explicit live workout, and
        // Live Activity updates flow only while one exists.
        XCTAssertTrue(source.contains(".onReceive(workoutDetectionUpdates) { _ in\n            handleWorkoutDetectionUpdate()"))
        XCTAssertTrue(source.contains(".onReceive(liveActivityUpdates) { _ in\n            handleLiveActivityUpdate()"))
        let detectionHandler = try XCTUnwrap(source.range(of: "private func handleWorkoutDetectionUpdate()"))
        XCTAssertTrue(String(source[detectionHandler.lowerBound...].prefix(200))
            .contains("guard workoutSession == nil else { return }"),
                      "detection must fail closed during an explicit live workout")
        let liveActivityHandler = try XCTUnwrap(source.range(of: "private func handleLiveActivityUpdate()"))
        XCTAssertTrue(String(source[liveActivityHandler.lowerBound...].prefix(200))
            .contains("guard workoutSession != nil else { return }"),
                      "Live Activity updates require an owning workout session")
    }

    func testWidgetAndDetectionPublishersExcludeMediaAndGuidanceTimer() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let source = try String(contentsOf: testsDirectory.deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaHomeView.swift"), encoding: .utf8)
        let widgetStart = try XCTUnwrap(source.range(of: "private var liveWidgetUpdates"))
        let detectionStart = try XCTUnwrap(source.range(of: "private var workoutDetectionUpdates",
                                                        range: widgetStart.upperBound..<source.endIndex))
        let batteryStart = try XCTUnwrap(source.range(of: "private var batteryWidgetUpdates",
                                                      range: detectionStart.upperBound..<source.endIndex))
        let widget = String(source[widgetStart.lowerBound..<detectionStart.lowerBound])
        let detection = String(source[detectionStart.lowerBound..<batteryStart.lowerBound])

        for section in [widget, detection] {
            XCTAssertFalse(section.contains("mediaController.$state"))
            XCTAssertFalse(section.contains("strainTargetGuidanceTimer"))
            XCTAssertFalse(section.contains("collectionLiveStore.$state"))
        }
        XCTAssertTrue(widget.contains("pulseLiveStore.$state"))
    }

    func testLiveWorkoutDetectionIsNotDisabledAwayFromOverview() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let source = try String(contentsOf: testsDirectory.deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaHomeView.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private func updateWorkoutDetectionPrompt"))
        let end = try XCTUnwrap(source.range(of: "private func setWorkoutDetectionPromptIfChanged",
                                              range: start.upperBound..<source.endIndex))
        let implementation = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertFalse(implementation.contains("selectedTab == .overview"),
                       "A live strap effort must keep being evaluated while the wearer uses Activity, History, or another in-app tab; only its banner presentation is overview-scoped.")
        XCTAssertTrue(implementation.contains("guard scenePhase == .active else { return }"),
                      "This remains foreground-only: background execution cannot be represented as continuous automatic detection.")
        XCTAssertTrue(implementation.contains("guard workoutSession == nil else"),
                      "An explicit live workout must remain the sole owner of its session.")
    }
}
