import XCTest
@testable import Atria

/// 2026-09-02: the learned max-HR suggestion is offered on the Strain detail
/// sheet, beside the zone card it would change, not only deep in Settings.
/// Accepting it goes through one store-owned path that writes the profile the
/// way Settings does and retires the suggestion immediately.
final class AtriaStrainSheetMaxHRSuggestionTests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private func source(_ relative: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent(relative), encoding: .utf8)
    }

    func testStrainSheetOffersTheSuggestionBesideTheZoneCard() throws {
        let overview = try source("Atria/Atria/AtriaOverviewSections.swift")
        XCTAssertTrue(overview.contains("var maxHRSuggestion: AtriaMaxHRSuggestion? = nil"))
        XCTAssertTrue(overview.contains("maxHRSuggestion: AtriaMaxHRSuggestion? = nil,"),
                      "every other caller stays byte-identical through the defaulted parameter")
        XCTAssertTrue(overview.contains("if metric == .strain, !maxHRSuggestionHandled, let suggestion = maxHRSuggestion {"),
                      "the offer is strain-only and disappears once acted on")
        XCTAssertTrue(overview.contains("                strainRecoveryComboCard\n                // Rare, dismissible, and asking for a decision: the learned\n                // max-HR offer stays above the fold when present (2026-09-02).\n                maxHRSuggestionCard\n            } contributors: {"),
                      "the offer sits above the fold beside the combo card, not behind Show details")
        XCTAssertTrue(overview.contains("Label(\"Update to \\(suggestion.observedPeak)\", systemImage: \"checkmark.circle.fill\")"))
        XCTAssertTrue(overview.contains("Text(\"Not now\")"))
    }

    func testTodayHandsTheCachedSuggestionAndStoreOwnedActions() throws {
        let today = try source("Atria/Atria/AtriaTodayScreen.swift")
        XCTAssertTrue(today.contains("?? store.cachedMaxHRSuggestion)"),
                      "presentation reads the cached value; it never forces a session scan")
        XCTAssertTrue(today.contains("onAcceptMaxHRSuggestion: { store.acceptMaxHRSuggestion(observedPeak: $0) }"))
        XCTAssertTrue(today.contains("onDismissMaxHRSuggestion: { store.dismissMaxHRSuggestion(observedPeak: $0) }"))
        XCTAssertTrue(today.contains("arguments.contains(\"--atria-debug-max-hr-suggestion\")"),
                      "the debug seed is a separate flag because the fixture slot opens the sheet")
    }

    func testAcceptWritesTheProfileLikeSettingsAndRetiresTheSuggestion() throws {
        let sessions = try source("Atria/Atria/Sessions.swift")
        guard let start = sessions.range(of: "func acceptMaxHRSuggestion(observedPeak: Int") else {
            return XCTFail("store accept path missing")
        }
        let body = String(sessions[start.lowerBound...].prefix(700))
        XCTAssertTrue(body.contains("$0.measuredMaxHR = observedPeak"))
        XCTAssertTrue(body.contains("$0.maxHRSource = .measured"))
        XCTAssertTrue(body.contains("AtriaMaxHRSuggestionEngine.clearDismissal()"))
        XCTAssertTrue(body.contains("refreshMaxHRSuggestion(reason: \"accept\", now: now, force: true)"))
        let settings = try source("Atria/Atria/AtriaSettingsView.swift")
        XCTAssertTrue(settings.contains("updated.maxHRSource = .measured"),
                      "Settings keeps its own draft-based row; both paths mark the source measured")
    }
}
