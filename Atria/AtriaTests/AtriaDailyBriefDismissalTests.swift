import XCTest
@testable import Atria

/// Once the daily brief is answered, it leaves Today.
///
/// Device request 2026-08-26: "the daily brief section, once completed for the
/// day, should disappear from today". It had been holding a 44pt row plus two
/// text lines to report "Done" — the one state that needs no action — on the
/// screen with the least room to spare.
///
/// Removing it is only safe because the Journal tab is a permanent entry point,
/// so a completed brief stays reachable. That is asserted here too: if the tab
/// ever goes, this card is the fallback and the guard has to come back.
final class AtriaDailyBriefDismissalTests: XCTestCase {

    private func source(_ name: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Atria/\(name)"),
            encoding: .utf8
        )
    }

    private let day = Date(timeIntervalSince1970: 1_756_000_000)

    private func progress(answered: Int, total: Int) -> AtriaJournalCheckInProgress {
        AtriaJournalCheckInProgress(answeredCount: answered, totalCount: total)
    }

    // MARK: - What "complete" means

    func testCompleteOnlyWhenEveryQuestionIsAnswered() {
        XCTAssertTrue(progress(answered: 7, total: 7).isComplete)
        XCTAssertTrue(progress(answered: 9, total: 7).isComplete,
                      "extra answers still count as done")
        XCTAssertFalse(progress(answered: 6, total: 7).isComplete)
        XCTAssertFalse(progress(answered: 0, total: 7).isComplete)
    }

    func testAnEmptyBriefIsNotSilentlyComplete() {
        // totalCount == 0 means there is nothing to answer yet — treating that
        // as "done" would hide a card that was never offered.
        XCTAssertFalse(progress(answered: 0, total: 0).isComplete)
    }

    func testAPartiallyAnsweredBriefStillReportsItsProgress() {
        let partial = progress(answered: 3, total: 7)
        XCTAssertTrue(partial.isStarted)
        XCTAssertEqual(partial.statusLabel, "3 of 7")
        XCTAssertEqual(partial.actionLabel, "Resume check-in",
                       "the count belongs to statusLabel alone")
    }

    // MARK: - The card obeys it

    func testTheTodayCardHidesTheBriefOnceItIsComplete() throws {
        let text = try source("AtriaTodayScreen.swift")
        XCTAssertTrue(text.contains("if !checkIn.isComplete {"),
                      "the Today plan card must drop the brief when it is done")
    }

    func testTheCompletedIconBranchIsGoneRatherThanUnreachable() throws {
        // The button used to swap its glyph to a checkmark for the complete
        // state. That branch can no longer render, and dead conditional UI is
        // how a "fixed" surface quietly comes back.
        let text = try source("AtriaTodayScreen.swift")
        XCTAssertFalse(text.contains(#"checkIn.isComplete ? "checkmark.circle.fill""#),
                       "the complete-state glyph is unreachable and must not linger")
    }

    // MARK: - ...and the answers stay reachable

    func testTheJournalRemainsAPermanentTab() throws {
        let text = try source("AtriaHomeView.swift")
        XCTAssertTrue(text.contains("case journal"),
                      "hiding the Today card is only safe while the Journal "
                          + "tab exists as an entry point")
        XCTAssertTrue(text.contains("Tab(HomeTab.journal.title"),
                      "and while it is actually mounted in the tab bar")
    }
}
