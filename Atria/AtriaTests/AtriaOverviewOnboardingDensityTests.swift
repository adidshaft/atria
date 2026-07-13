import XCTest

final class AtriaOverviewOnboardingDensityTests: XCTestCase {
    private func source(_ relativePath: String) throws -> String {
        let testsURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let appURL = testsURL.deletingLastPathComponent().appendingPathComponent("Atria")
        return try String(contentsOf: appURL.appendingPathComponent(relativePath), encoding: .utf8)
    }

    func testStrapOnboardingUsesCompactAdaptiveSetupStrip() throws {
        let source = try source("AtriaOnboardingFlow.swift")
        let start = try XCTUnwrap(source.range(of: "private var strapPage"))
        let end = try XCTUnwrap(source.range(of: "private var youPage", range: start.upperBound..<source.endIndex))
        let page = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(page.contains("LazyVGrid(columns: [GridItem(.adaptive(minimum: 92)"))
        XCTAssertEqual(page.components(separatedBy: "setupStepTile(").count - 1, 3)
        XCTAssertFalse(page.contains("StrapChargeIllustration"))
    }

    func testCompactOnboardingHeadersKeepAccessibleCombinedTitles() throws {
        let source = try source("AtriaOnboardingFlow.swift")

        XCTAssertTrue(source.contains("private func onboardingHeader"))
        XCTAssertTrue(source.contains(".accessibilityElement(children: .combine)"))
        XCTAssertTrue(source.contains("onboardingHeader(\"Connect your strap\""))
        XCTAssertTrue(source.contains("onboardingHeader(\"Wear it tonight\""))
    }

    func testOnboardingKeepsSupportingCopyForVoiceOverWithoutRenderingExtraLines() throws {
        let source = try source("AtriaOnboardingFlow.swift")

        XCTAssertFalse(source.contains("Text(\"WHOOP insights without the subscription.\")"))
        XCTAssertTrue(source.contains(".accessibilityHint(\"WHOOP insights without the subscription.\")"))
        XCTAssertTrue(source.contains("title: \"Wear\""))
        XCTAssertTrue(source.contains("title: \"Sleep\""))
        XCTAssertTrue(source.contains("title: \"Recovery\""))
        XCTAssertFalse(source.contains("detail: \"First sleep\""))
        XCTAssertTrue(source.contains(".frame(maxWidth: .infinity, minHeight: 64)"))
    }

    func testOverviewRemovesDuplicateVisibleConnectionDetailButKeepsVoiceOverHint() throws {
        let source = try source("AtriaOverviewSections.swift")
        let start = try XCTUnwrap(source.range(of: "private struct AtriaDisconnectedOverviewPanel"))
        let end = try XCTUnwrap(source.range(of: "private struct AtriaOverviewLeadingHost", range: start.upperBound..<source.endIndex))
        let panel = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertFalse(panel.contains("Text(detail)"))
        XCTAssertTrue(panel.contains("AtriaPanelSectionHeader(title: \"Overview\", subtitle: title)"))
        XCTAssertTrue(panel.contains(".accessibilityHint(detail)"))
    }

    func testCompletedOverviewChecklistRowsDoNotRepeatExplanationsVisually() throws {
        let source = try source("AtriaOverviewSections.swift")
        let start = try XCTUnwrap(source.range(of: "private struct AtriaLaunchChecklistRow"))
        let end = try XCTUnwrap(source.range(of: "struct AtriaOverviewGuidanceSectionHost", range: start.upperBound..<source.endIndex))
        let row = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(row.contains("if !item.isComplete"))
        XCTAssertTrue(row.contains(".accessibilityHint(item.detail)"))
    }

    func testFirstLaunchStopsAtFiveMandatoryPagesWithoutDuplicatePersonalization() throws {
        let content = try source("ContentView.swift")
        let stageStart = try XCTUnwrap(content.range(of: "private enum OnboardingStage"))
        let stageEnd = try XCTUnwrap(content.range(of: "init(ble:", range: stageStart.upperBound..<content.endIndex))
        let stages = String(content[stageStart.lowerBound..<stageEnd.lowerBound])

        XCTAssertTrue(stages.contains("case flow"))
        XCTAssertTrue(stages.contains("case sharingChoice(AthleteProfile)"))
        XCTAssertFalse(stages.contains("case nickname"))
        XCTAssertFalse(stages.contains("case ringPicker"))
        XCTAssertFalse(stages.contains("case womensHealth"))
        XCTAssertTrue(content.contains("onboardingStage = .sharingChoice(profile)"))
        XCTAssertFalse(content.contains("onboardingStage = .nickname(profile)"))
    }
}
