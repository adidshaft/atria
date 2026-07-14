import XCTest
import SwiftUI
@testable import Atria

/// Assistant deterministic answers (2026-07-08): the honesty LAW is that
/// with no recorded data every answer fails closed to a "still learning /
/// not enough data" line and never invents a number.
@MainActor
final class AtriaAssistantAnswerTests: XCTestCase {
    // "Learning" is the sentinel production actually emits (HeroSnapshot
    // .recoveryValue) when there's no score — not "--". Exercising the real
    // value is what caught the recovery guard bug (2026-07-08 self-review).
    private func makeScreen(recoveryText: String = "Learning") -> AtriaAssistantScreen {
        let context = AtriaCoachContext(guidance: Coach.guide(recovery: 0, strain: 0),
                                        strain: 0, recoveryText: recoveryText, hrvText: "--",
                                        stressText: "--", baselineSamples: 0, sessionsCount: 0)
        let store = SessionStore()
        store.debugResetForEmptyAssistantAnswers()
        return AtriaAssistantScreen(
            store: store, context: context, coachPayload: nil,
            aiCoachSettings: AtriaAICoachSettings(), aiCoachHasAPIKey: false)
    }

    func testEmptyStoreFailsClosedNeverFabricates() {
        let screen = makeScreen()
        let expectations: [(id: String, mustMention: String)] = [
            ("recovery", "learning"),
            ("sleep", "confirmed night"),
            ("typical", "building"),
            ("behaviors", "statistical bar"),
            ("week", "Not enough"),
        ]
        for expectation in expectations {
            let result = screen.debugAnswer(promptID: expectation.id)
            XCTAssertTrue(result.answer.localizedCaseInsensitiveContains(expectation.mustMention),
                          "\(expectation.id) answer should fail closed; got: \(result.answer)")
            // No fabricated percentage or ms reading in a fail-closed answer.
            XCTAssertFalse(result.answer.contains("%"),
                           "\(expectation.id) fail-closed answer must not state a percent: \(result.answer)")
        }
    }

    func testEveryAnswerCitesItsProvenance() {
        let screen = makeScreen()
        for prompt in ["recovery", "sleep", "typical", "behaviors", "week"] {
            let result = screen.debugAnswer(promptID: prompt)
            XCTAssertFalse(result.provenance.isEmpty, "\(prompt) must state where its answer came from")
        }
    }

    func testAssistantReadsSessionStoreAtTapTimeWithoutObservingWholeStore() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaAssistantScreen.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("let store: SessionStore"))
        XCTAssertFalse(source.contains("@ObservedObject var store: SessionStore"))
        XCTAssertTrue(source.contains("exchanges.append(answer(for: prompt))"))
    }

    func testAssistantKeepsConfigurationOutOfTheConversation() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let appDirectory = testsDirectory.deletingLastPathComponent().appendingPathComponent("Atria")
        let assistant = try String(contentsOf: appDirectory.appendingPathComponent("AtriaAssistantScreen.swift"),
                                   encoding: .utf8)
        let card = try String(contentsOf: appDirectory.appendingPathComponent("AtriaAICoachCard.swift"),
                              encoding: .utf8)
        let settings = try String(contentsOf: appDirectory.appendingPathComponent("AtriaSettingsView.swift"),
                                  encoding: .utf8)

        XCTAssertFalse(assistant.contains("onSaveAICoachAPIKey"))
        XCTAssertFalse(card.contains("SecureField"))
        XCTAssertFalse(card.contains("Picker(\"Coach mode\""))
        XCTAssertTrue(card.contains("Label(\"Sources\", systemImage: \"checkmark.shield\")"))

        XCTAssertTrue(settings.contains("private var coachSettingsPage"))
        XCTAssertTrue(settings.contains("SecureField(coachHasAPIKey ? \"Replace saved API key\" : \"API key\""))
        XCTAssertTrue(settings.contains("Picker(\"Mode\", selection: coachModeBinding)"))
        XCTAssertTrue(settings.contains("Picker(\"Service\", selection: coachProviderBinding)"))
    }
}
