import XCTest
@testable import Atria

/// 2026-09-02: the Advanced targets footer listed "lnRMSSD", the engine's
/// log-HRV, to the wearer. It now names the metrics as the app shows them.
final class AtriaAdvancedTargetsCopyTests: XCTestCase {
    func testFooterNamesMetricsAsTheAppShowsThem() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaSettingsView.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("Text(\"Uses resting HR, HRV, zone 2+ minutes, and sleep consistency. These bands only tune guidance colors.\")"))
        XCTAssertFalse(source.contains("Text(\"Uses RHR, lnRMSSD"))
    }
}
