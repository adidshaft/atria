import XCTest
@testable import Atria

/// W4.5: "What's my recovery", "Start walk", "Log tag".
final class AtriaW45IntentsTests: XCTestCase {
    func testEveryVoiceTagMapsToARealPublicJournalTag() {
        for tag in AtriaIntentTag.allCases {
            XCTAssertEqual(BehaviorJournalEntry.Tag(rawValue: tag.rawValue), tag.journalTag, tag.rawValue)
            XCTAssertFalse(tag.journalTag.isPrivate, "intimacy tags are never spoken")
        }
    }

    func testLogTagCommandRoundTripsThroughTheCommandStore() throws {
        let data = try JSONEncoder().encode(AtriaIntentCommand.logTag("sauna"))
        XCTAssertEqual(try JSONDecoder().decode(AtriaIntentCommand.self, from: data), .logTag("sauna"))
    }

    func testStartWalkUsesTheWorkoutDeepLinkThatResolvesToWalking() {
        let url = AtriaStartWalkIntent.deepLink
        XCTAssertEqual(url.scheme, "atria")
        let type = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "type" }?.value
        XCTAssertEqual(AtriaWorkoutActivityType.deepLinkType(type), .walking)
    }

    func testShortcutsExposeTheThreeRequestedActionsAndHomeAppliesTagsAddOnly() throws {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let intents = try String(contentsOf: tests.appendingPathComponent("Atria/AtriaAppIntents.swift"), encoding: .utf8)
        XCTAssertTrue(intents.contains("\"What's my recovery in \\(.applicationName)\""))
        XCTAssertTrue(intents.contains("intent: AtriaStartWalkIntent()"))
        XCTAssertTrue(intents.contains("intent: AtriaLogTagIntent()"))
        let home = try String(contentsOf: tests.appendingPathComponent("Atria/AtriaHomeView.swift"), encoding: .utf8)
        XCTAssertTrue(home.contains("!store.behaviorJournalEntry(for: Date()).tags.contains(tag)"))
    }
}
