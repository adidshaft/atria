import XCTest
@testable import Atria

/// 2026-09-02: the one big number a card leads with was 30pt on the overview
/// night card and 34pt on the Activity night card for the same duration.
/// One card-hero token (largeTitle rounded bold, scales with type) carries
/// every card hero.
///
/// 2026-09-03: the live pulse reading joined them. It had been carved out to
/// keep a hand-set 38pt, but a hand-set size does not scale with Dynamic
/// Type, so at large text sizes the one number the monitor exists to show was
/// the one that would not grow. No hand-set hero sizes remain.
final class AtriaCardHeroValueTokenTests: XCTestCase {
    private static let appDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Atria")

    private func source(_ file: String) throws -> String {
        try String(contentsOf: Self.appDirectory.appendingPathComponent(file), encoding: .utf8)
    }

    func testCardHeroValueIsATextStyleSoItScales() throws {
        let tokens = try source("AtriaDesignTokens.swift")
        XCTAssertTrue(tokens.contains("static let cardHeroValue = Font.system(.largeTitle, design: .rounded, weight: .bold)"))
    }

    func testSummaryHeroesShareTheTokenAndLiveReadingsKeepTheirs() throws {
        let expected: [(String, Int)] = [
            ("AtriaOverviewSections.swift", 3), ("AtriaActivityMonitor.swift", 1),
            ("AtriaHomeView.swift", 1), ("AtriaVitalsCollectionSections.swift", 2), ("Sessions.swift", 1)
        ]
        for (file, count) in expected {
            let text = try source(file)
            XCTAssertEqual(text.components(separatedBy: "AtriaDesignTokens.Typography.cardHeroValue").count - 1, count, file)
            XCTAssertFalse(text.contains("size: 30, weight: .bold, design: .rounded"), file)
            XCTAssertFalse(text.contains("size: 34, weight: .bold, design: .rounded"), file)
        }
        let vitals = try source("AtriaVitalsCollectionSections.swift")
        XCTAssertFalse(vitals.contains("size: 38, weight: .bold, design: .rounded"),
                       "the live bpm reading scales with Dynamic Type like every other hero")
    }
}
