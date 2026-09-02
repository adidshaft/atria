import XCTest
@testable import Atria

/// 2026-09-02 Settings audit, second pass: the three backup actions fell
/// back to three capsules of different widths stacked at the left. They
/// now stretch and fall back to a two-column grid; the Strap page's
/// generation caption drops "layout", packet-format jargon.
final class AtriaSettingsBackupLayoutTests: XCTestCase {
    private func source(_ file: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Atria/\(file)"), encoding: .utf8)
    }

    func testBackupActionsStretchAndFallBackToAGrid() throws {
        let settings = try source("AtriaSettingsView.swift")
        let start = try XCTUnwrap(settings.range(of: "@ViewBuilder private var backupActionButtons: some View {"))
        let buttons = String(settings[start.lowerBound...].prefix(2_600))
        XCTAssertEqual(buttons.components(separatedBy: ".frame(maxWidth: .infinity)").count - 1, 3,
                       "all three labels stretch to their column")
        XCTAssertTrue(settings.contains("LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible())],"))
        XCTAssertFalse(settings.contains("VStack(alignment: .leading, spacing: 8) { backupActionButtons }"))
    }

    func testGenerationCaptionNamesTheStrapNotItsLayout() throws {
        let ble = try source("AtriaBLEManager.swift")
        XCTAssertTrue(ble.contains("\"Unknown · heart rate only until the strap is checked\""))
        XCTAssertFalse(ble.contains("until the layout is checked"))
    }
}
