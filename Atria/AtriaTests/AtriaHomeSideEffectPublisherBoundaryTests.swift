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
        XCTAssertTrue(source.contains(".onReceive(workoutDetectionUpdates) { _ in\n            guard workoutSession == nil else { return }"))
        XCTAssertTrue(source.contains(".onReceive(liveActivityUpdates) { _ in\n            guard workoutSession != nil else { return }"))
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
