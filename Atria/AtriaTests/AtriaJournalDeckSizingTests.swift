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

    func testCheckInCardShowsTheSpokenPromptNotJustTheNoun() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let source = try String(
            contentsOf: testsDirectory
                .deletingLastPathComponent()
                .appendingPathComponent("Atria/AtriaJournalTab.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "private func questionCard(for tag: BehaviorJournalEntry.Tag)"))
        let end = try XCTUnwrap(source.range(of: "private static let scaleEmoji",
                                             range: start.upperBound..<source.endIndex))
        let card = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(card.contains("Text(tag.prompt)"))
        XCTAssertTrue(card.contains("Text(tag.label)"))
        XCTAssertTrue(card.contains("Label(\"Yes\", systemImage: \"checkmark\")"))
        XCTAssertTrue(card.contains("Label(\"No\", systemImage: \"xmark\")"))
        XCTAssertFalse(card.contains(".lineLimit(1)"))
        XCTAssertTrue(source.contains("Choose what you track"))
        XCTAssertTrue(source.contains("AtriaTrackedBehaviorsSettingsView()"))
        XCTAssertEqual(BehaviorJournalEntry.Tag.sleep.prompt,
                       "Did you get to bed on time last night?")
        XCTAssertEqual(BehaviorJournalEntry.Tag.alcohol.prompt,
                       "Any alcohol yesterday?")
        XCTAssertEqual(BehaviorJournalEntry.Tag.caffeine.prompt,
                       "Coffee, tea, or caffeine after mid-afternoon?")
    }
}
