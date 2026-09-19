import XCTest
@testable import Atria

/// 2026-09-02 XXXL screenshot: the Customize sheet's miniature layout
/// preview, scaled to 60% in a fixed frame, overflowed itself once the
/// legend stacked at large type. The miniature is illustrative ("Example
/// data") and keeps a standard text size at every setting.
final class AtriaCustomizePreviewTypeTests: XCTestCase {
    func testMiniatureKeepsAStandardTextSize() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaCustomizeSheet.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private struct AtriaCustomizePreview: View {"))
        let window = String(source[start.lowerBound...].prefix(1_200))
        XCTAssertTrue(window.contains("previewContent.dynamicTypeSize(.large)"))
        XCTAssertTrue(window.contains("private var previewContent: some View {"))
    }
}
