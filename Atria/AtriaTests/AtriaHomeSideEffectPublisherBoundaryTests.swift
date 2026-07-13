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
}
