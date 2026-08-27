import XCTest
@testable import Atria

/// Tappable cards must acknowledge the press.
///
/// 2026-08-27 design audit: 67 buttons used `.buttonStyle(.plain)` — label
/// rendered untouched, finger given nothing back. The chrome already had the
/// pattern (segment buttons at 0.97, icon buttons at 0.94, both reduce-motion
/// aware); the cards that open sheets were the gap. Applied to the primary
/// tap-a-card surfaces: Today's glance tiles and the Health screen's metric
/// tiles.
final class AtriaPressableCardStyleTests: XCTestCase {

    private func source(_ name: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Atria/\(name)"),
            encoding: .utf8
        )
    }

    func testTheStyleLivesInSharedChromeAndScalesGently() throws {
        let chrome = try source("AtriaSharedChrome.swift")
        XCTAssertTrue(chrome.contains("struct AtriaPressableCardStyle: ButtonStyle"))
        XCTAssertTrue(chrome.contains("configuration.isPressed ? 0.98 : 1"),
                      "a large surface at the icon buttons' 0.94 lurches; "
                          + "cards use the gentler 0.98")
        XCTAssertTrue(chrome.contains("reduceMotion ? nil :"),
                      "pressed animation must honor reduce-motion like the "
                          + "styles beside it")
    }

    func testTheGlanceAndMetricTilesGiveFeedback() throws {
        XCTAssertEqual(
            try source("AtriaTodayScreen.swift")
                .components(separatedBy: "AtriaPressableCardStyle()").count - 1,
            5, "the four glance-tile button variants plus the "
                + "unverified-movement review banner (added 2026-08-28)")
        XCTAssertEqual(
            try source("AtriaHealthScreen.swift")
                .components(separatedBy: "AtriaPressableCardStyle()").count - 1,
            3, "Sufficiency, Efficiency, and the Lab's Fitness Age card")
    }
}
