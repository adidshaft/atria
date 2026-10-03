import XCTest
@testable import Atria

/// 2026-09-02: the Activity timeline header printed "-- bpm" (or the stress
/// equivalent) above a canvas that already said why the trace was empty.
/// A placeholder value only ever accompanies an empty trace, so the header
/// now omits it and keeps only the window label. A real reading is primary
/// text (owner 2026-10-03: colour for data marks, not numbers).
final class AtriaActivityTimelineHeaderTests: XCTestCase {
    func testHeaderOmitsPlaceholderValuesAndShowsRealReadingsNeutral() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaActivityMonitor.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("if !timelineSignalValueText.hasPrefix(\"--\") {\n                    Text(timelineSignalValueText)"))
        XCTAssertTrue(source.contains("Text(timelineSignalValueText)\n                        .font(.subheadline.weight(.black).monospacedDigit())\n                        .foregroundStyle(.primary)"))
        XCTAssertFalse(source.contains("timelineSignalValueText.hasPrefix(\"--\")\n                                     ? Color.secondary"),
                       "no secondary-tinted placeholder remains; the value is simply absent")
        // The placeholder still exists as the value's own fallback, so an
        // accessibility reader or a future surface can rely on it.
        XCTAssertTrue(source.contains("?? \"-- bpm\""))
    }
}
