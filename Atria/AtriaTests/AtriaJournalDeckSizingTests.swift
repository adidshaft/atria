import SwiftUI
import XCTest
@testable import Atria

final class AtriaJournalDeckSizingTests: XCTestCase {
    // 2026-07-17: pins migrated 250 -> 460 to follow the deliberate
    // "large, focal swipe cards" decision in AtriaJournalDeckSizing
    // (commit 824a411e, dated comment in source). The structural
    // invariants (fixed+clipped standard, unclipped accessibility
    // growth) are unchanged; only the height literal moved.
    func testStandardDynamicTypeKeepsExistingFixedCardHeightAndClipping() {
        for size in [DynamicTypeSize.small, .large, .xxxLarge] {
            let sizing = AtriaJournalDeckSizing(dynamicTypeSize: size)

            XCTAssertEqual(sizing.minimumHeight, AtriaJournalDeckSizing.standardHeight)
            XCTAssertEqual(sizing.maximumHeight, AtriaJournalDeckSizing.standardHeight)
            XCTAssertEqual(AtriaJournalDeckSizing.standardHeight, 460)
            XCTAssertTrue(sizing.clipsContent)
        }
    }

    func testAccessibilityDynamicTypeAllowsUnclippedVerticalGrowth() {
        for size in [DynamicTypeSize.accessibility1, .accessibility3, .accessibility5] {
            let sizing = AtriaJournalDeckSizing(dynamicTypeSize: size)

            XCTAssertEqual(sizing.minimumHeight, AtriaJournalDeckSizing.standardHeight)
            XCTAssertNil(sizing.maximumHeight)
            XCTAssertFalse(sizing.clipsContent)
        }
    }

    func testJournalDeckReadsNativeDynamicTypeEnvironment() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaJournalTab.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("@Environment(\\.dynamicTypeSize) private var dynamicTypeSize"))
        XCTAssertTrue(source.contains("AtriaJournalDeckSizing(dynamicTypeSize: dynamicTypeSize)"))
        XCTAssertFalse(source.contains(".frame(height: Self.cardHeight)"))
    }
}
