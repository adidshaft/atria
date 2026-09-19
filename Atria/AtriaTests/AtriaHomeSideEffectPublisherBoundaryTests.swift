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
        // Detection stays silent during an explicit live workout. Live
        // Activity also carries all-day strap presence, so its handler must
        // keep publishing while Connected with a held beat.
        XCTAssertTrue(source.contains(".onReceive(workoutDetectionUpdates) { _ in\n            handleWorkoutDetectionUpdate()"))
        XCTAssertTrue(source.contains(".onReceive(liveActivityUpdates) { _ in\n            handleLiveActivityUpdate()"))
        let detectionHandler = try XCTUnwrap(source.range(of: "private func handleWorkoutDetectionUpdate()"))
        XCTAssertTrue(String(source[detectionHandler.lowerBound...].prefix(200))
            .contains("guard workoutSession == nil else { return }"),
                      "detection must fail closed during an explicit live workout")
        let liveActivityHandler = try XCTUnwrap(source.range(of: "private func handleLiveActivityUpdate()"))
        let liveActivityBody = String(source[liveActivityHandler.lowerBound...].prefix(420))
        XCTAssertTrue(liveActivityBody.contains("updateLiveActivity()"))
        XCTAssertFalse(liveActivityBody.contains("guard workoutSession != nil else { return }"),
                       "all-day live presence must keep the Lock Screen on the current beat")
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
        XCTAssertTrue(
            implementation.contains("shouldHoldCompletedSustainedReview("),
            "device 2026-09-19 15:37: a qualified 8-min strap bout must stay reviewable after HR returns to rest"
        )
        XCTAssertTrue(
            implementation.contains("lastCompletedSustainedBout("),
            "device 2026-09-19 15:37: journal reconstruction must keep Review this workout after HR lookback slides off"
        )
        XCTAssertTrue(
            implementation.contains("workoutPromptHeartSamples(now: now)"),
            "device 2026-09-19 16:25: 197 install checkpointed the 13:13 journal; reconstruction must read that saved walk"
        )
        XCTAssertTrue(
            implementation.contains("episodeStart") && implementation.contains("episodeEnd"),
            "Review this workout must open the completed bout window, not now"
        )
    }
}
