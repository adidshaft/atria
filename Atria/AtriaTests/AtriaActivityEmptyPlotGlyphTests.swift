import XCTest
@testable import Atria

/// 2026-09-02: the Activity timeline's empty message sat alone in a
/// plot-sized blank. A dimmed signal glyph now rides above it, naming the
/// missing trace at a glance; the plot keeps its height so day navigation
/// does not jump.
final class AtriaActivityEmptyPlotGlyphTests: XCTestCase {
    func testEmptyOverlayShowsTheSignalGlyphAboveTheMessage() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaActivityMonitor.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "// Empty-plot glyph (2026-09-02)"))
        let window = String(source[start.lowerBound...].prefix(900))
        XCTAssertTrue(window.contains("Image(systemName: selectedSignal == .heartRate ? \"waveform.path.ecg\" : \"waveform.path\")"))
        XCTAssertTrue(window.contains(".foregroundStyle(.tertiary)"), "the glyph is dimmer than the message")
        XCTAssertTrue(window.contains("Text(emptyMessage)"))
        XCTAssertTrue(window.contains(".position(x: frame.midX, y: frame.midY + 8)"), "still centred in the plot frame")
    }
}
