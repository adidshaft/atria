import XCTest
@testable import Atria

/// 2026-09-02: one learning-progress look across the app. The track is the
/// engine's real minimum, the fill is the user's real count, and no surface
/// keeps its own copy of the capsule pair.
final class AtriaLearningProgressTrackTests: XCTestCase {
    private static let appDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Atria")

    private func source(_ file: String) throws -> String {
        try String(contentsOf: Self.appDirectory.appendingPathComponent(file), encoding: .utf8)
    }

    func testThreeLearningStatesShareOneTrack() throws {
        let shared = try source("AtriaSharedUIComponents.swift")
        XCTAssertTrue(shared.contains("struct AtriaLearningProgressTrack: View"))
        XCTAssertTrue(shared.contains(".accessibilityLabel(caption)"),
                      "VoiceOver reads the count, not a bar")

        let journal = try source("AtriaJournalTab.swift")
        XCTAssertTrue(journal.contains("AtriaLearningProgressTrack(current: answeredDayCount,"))
        let behavior = try source("AtriaBehaviorImpactChart.swift")
        XCTAssertTrue(behavior.contains("AtriaLearningProgressTrack(current: model.loggedNights,"))
        let health = try source("AtriaHealthScreen.swift")
        XCTAssertTrue(health.contains("target: AtriaSleepConsistency.minimumQualifiedNights,"),
                      "the schedule track quotes the engine's real minimum")
        XCTAssertTrue(health.contains("current: consistency.qualifiedNightCount,"))

        for (name, text) in [("journal", journal), ("behavior", behavior), ("health", health)] {
            XCTAssertFalse(text.contains("Metrics.electricGreen.opacity(0.75)"),
                           "\(name) must not keep a private copy of the track fill")
        }
    }

    func testScheduleLearningStateSaysLearningAndKeepsTheSentenceForVoiceOver() throws {
        let health = try source("AtriaHealthScreen.swift")
        // Anchor on the qualified-count line, which is unique to this card; the
        // learning word is the else-branch of the same header trailing slot.
        let anchor = try XCTUnwrap(health.range(of: "Text(\"\\(consistency.qualifiedNightCount) qualified nights\")"))
        let window = String(health[anchor.lowerBound...].prefix(600))
        XCTAssertTrue(window.contains("Text(\"Learning\")"),
                      "the canonical not-ready word sits where the score would be")
        XCTAssertTrue(health.contains(": \"Sleep schedule, \\(consistency.footnote)\")"),
                      "the full learning sentence stays in the accessibility label")
        XCTAssertFalse(health.contains("Text(consistency.footnote)"),
                       "the visible learning state is a track, not the sentence")
    }
}
