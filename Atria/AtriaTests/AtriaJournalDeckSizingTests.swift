import SwiftUI
import XCTest
@testable import Atria

final class AtriaJournalDeckSizingTests: XCTestCase {
    func testStandardDynamicTypeKeepsExistingFixedCardHeightAndClipping() {
        for size in [DynamicTypeSize.small, .large, .xxxLarge] {
            let sizing = AtriaJournalDeckSizing(dynamicTypeSize: size)

            XCTAssertEqual(sizing.minimumHeight, 250)
            XCTAssertEqual(sizing.maximumHeight, 250)
            XCTAssertTrue(sizing.clipsContent)
        }
    }

    func testAccessibilityDynamicTypeAllowsUnclippedVerticalGrowth() {
        for size in [DynamicTypeSize.accessibility1, .accessibility3, .accessibility5] {
            let sizing = AtriaJournalDeckSizing(dynamicTypeSize: size)

            XCTAssertEqual(sizing.minimumHeight, 250)
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
