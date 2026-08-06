import SwiftUI
import XCTest
@testable import Atria

final class AtriaJournalDeckSizingTests: XCTestCase {
    func testJournalDeckUsesComfortableFloorWithoutAClippingCeiling() {
        for size in [DynamicTypeSize.small, .large, .xxxLarge] {
            let sizing = AtriaJournalDeckSizing(dynamicTypeSize: size)

            XCTAssertEqual(sizing.minimumHeight, AtriaJournalDeckSizing.standardHeight)
            XCTAssertEqual(AtriaJournalDeckSizing.standardHeight, 360)
        }
    }

    func testAccessibilityDynamicTypeKeepsTheSameFloorAndAllowsVerticalGrowth() {
        for size in [DynamicTypeSize.accessibility1, .accessibility3, .accessibility5] {
            let sizing = AtriaJournalDeckSizing(dynamicTypeSize: size)

            XCTAssertEqual(sizing.minimumHeight, AtriaJournalDeckSizing.standardHeight)
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
        XCTAssertFalse(source.contains("maxHeight: deckSizing.maximumHeight"))
        XCTAssertFalse(source.contains("content\n                .frame(maxWidth: .infinity,\n                       minHeight: deckSizing.minimumHeight,\n                       maxHeight:"))
    }
}
