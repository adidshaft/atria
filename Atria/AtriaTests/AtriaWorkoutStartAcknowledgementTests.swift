import XCTest
@testable import Atria

final class AtriaWorkoutStartAcknowledgementTests: XCTestCase {
    func testStartTapShowsNonWorkoutAcknowledgementBeforeDurableStartCompletes() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Atria/AtriaHomeView.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "AtriaWorkoutStartSheet(initial:"))
        let end = try XCTUnwrap(source.range(of: ".presentationDetents([.large])", range: start.upperBound..<source.endIndex))
        let callback = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(callback.contains("isSecuringWorkoutStart = true"))
        XCTAssertTrue(callback.contains("showWorkoutStartSheet = false"))
        XCTAssertTrue(callback.contains("await beginWorkoutSession"))
        XCTAssertTrue(callback.contains("isSecuringWorkoutStart = false"))

        XCTAssertTrue(source.contains("AtriaSecuringWorkoutStartView()"))
        XCTAssertTrue(source.contains("no clock, metrics, or\n    /// motion lease is published until the atomic intent has read back"))
        XCTAssertTrue(source.contains("phase=intent_durable elapsed_ms=%d"))
        XCTAssertTrue(source.contains("phase=ui_session_published elapsed_ms=%d"))
    }
}
