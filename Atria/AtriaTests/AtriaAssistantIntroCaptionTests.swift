import XCTest
@testable import Atria

/// 2026-09-02: the assistant's on-device promise was only a VoiceOver hint.
/// It is now a visible caption under "Ask Atria", combined into one
/// accessibility element so it is neither hidden from sighted readers nor
/// read twice.
final class AtriaAssistantIntroCaptionTests: XCTestCase {
    func testOnDevicePromiseIsVisibleAndSaidOnce() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaAssistantScreen.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("Text(\"Quick answers come from your data on this phone, not generated text.\")"))
        XCTAssertFalse(source.contains(".accessibilityHint(\"Quick answers use on-device data"),
                       "the visible caption replaces the hidden hint; combined element reads it once")
        XCTAssertTrue(source.contains("Image(systemName: \"lock.shield.fill\")"))
    }
}
