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

    func testConnectActionCannotAdvanceBeforeStrapConnection() throws {
        let source = try source("AtriaOnboardingFlow.swift")
        let actionStart = try XCTUnwrap(source.range(of: "PrimaryActionButton(ble: ble, step: step)"))
        let actionEnd = try XCTUnwrap(source.range(of: "}",
                                                  range: actionStart.upperBound..<source.endIndex))
        let action = String(source[actionStart.lowerBound...actionEnd.lowerBound])

        XCTAssertTrue(action.contains("if step == .strap, ble.status != .connected"))
        XCTAssertTrue(action.contains("ble.startScan(reason: \"onboarding_primary_connect\")"))
        XCTAssertFalse(action.contains("move(to:"),
                       "The disconnected Connect branch must stay on the strap step")
    }

    func testCompactOnboardingHeadersKeepAccessibleCombinedTitles() throws {
        let source = try source("AtriaOnboardingFlow.swift")

        XCTAssertTrue(source.contains("private func onboardingHeader"))
        XCTAssertTrue(source.contains(".accessibilityElement(children: .combine)"))
        XCTAssertTrue(source.contains("onboardingHeader(\"Connect your strap\""))
        XCTAssertTrue(source.contains("onboardingHeader(\"Wear it tonight\""))
    }

    func testExpectationTilesWrapInsteadOfForcingThreeAcross() throws {
        let source = try source("AtriaOnboardingFlow.swift")
        let start = try XCTUnwrap(source.range(of: "private var expectationsPage"))
        let end = try XCTUnwrap(source.range(of: "private var progressDots",
                                              range: start.upperBound..<source.endIndex))
        let page = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(page.contains("LazyVGrid(columns: [GridItem(.adaptive(minimum: 92)"))
        XCTAssertFalse(page.contains("HStack(spacing: 8)"),
                       "Expectation tiles must wrap for narrow widths and larger text")
        XCTAssertEqual(page.components(separatedBy: "expectationPill(").count - 1, 3)
    }

    func testOnboardingKeepsSupportingCopyForVoiceOverWithoutRenderingExtraLines() throws {
        let source = try source("AtriaOnboardingFlow.swift")

        XCTAssertFalse(source.contains("Text(\"WHOOP insights without the subscription.\")"))
        XCTAssertTrue(source.contains(".accessibilityHint(\"WHOOP insights without the subscription.\")"))
        XCTAssertTrue(source.contains("title: \"Wear\""))
        XCTAssertTrue(source.contains("title: \"Sleep\""))
        XCTAssertTrue(source.contains("title: \"Recovery\""))
        XCTAssertFalse(source.contains("detail: \"First sleep\""))
        XCTAssertTrue(source.contains(".frame(maxWidth: .infinity, minHeight: 58)"))
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

    func testOverviewGatesHighFrequencyLiveStateBeforeLargeReadinessTree() throws {
        let source = try source("AtriaOverviewSections.swift")
        let stateStart = try XCTUnwrap(source.range(of: "struct AtriaOverviewLiveProjectionState"))
        let hostStart = try XCTUnwrap(source.range(of: "struct AtriaOverviewReadinessSectionHost",
                                                   range: stateStart.upperBound..<source.endIndex))
        let state = String(source[stateStart.lowerBound..<hostStart.lowerBound])
        let hostEnd = try XCTUnwrap(source.range(of: "private func moveMetric",
                                                 range: hostStart.upperBound..<source.endIndex))
        let host = String(source[hostStart.lowerBound..<hostEnd.lowerBound])

        XCTAssertTrue(state.contains(".removeDuplicates()"))
        XCTAssertTrue(state.contains("sessionProgressBucket"))
        XCTAssertTrue(state.contains("liveActiveCaloriesText"))
        XCTAssertTrue(state.contains("strapStepResearchCount"),
                      "Exact strap-step changes must remain immediate")
        XCTAssertTrue(host.contains("let liveStore: AtriaHomeModel.CoreLiveStore"))
        XCTAssertFalse(host.contains("@ObservedObject var liveStore"),
                       "Every accepted strap sample must not invalidate the full readiness host")
        XCTAssertTrue(host.contains("@StateObject private var liveProjectionStore"))
    }

    func testOverviewDynamicRowsUseDomainIdentityInsteadOfMutableOffsets() throws {
        let source = try source("AtriaOverviewSections.swift")

        XCTAssertTrue(source.contains("id: \\.element.title) { index, companion in"))
        XCTAssertTrue(source.contains("id: \\.element.label) { _, band in"))
        XCTAssertTrue(source.contains("id: \\.element) { index, item in"))
        XCTAssertFalse(source.contains("ForEach(Array(companions.enumerated()), id: \\.offset)"))
        XCTAssertFalse(source.contains("ForEach(Array(bands.enumerated()), id: \\.offset)"))
        XCTAssertFalse(source.contains("ForEach(Array(items.enumerated()), id: \\.offset)"))
    }

    func testVitalsAndAdvancedSettingsKeepVisibleExplanationsCompact() throws {
        let vitals = try source("AtriaVitalsCollectionSections.swift")
        let settings = try source("AtriaSettingsView.swift")

        XCTAssertTrue(vitals.contains("Checks periodically by day."))
        XCTAssertFalse(vitals.contains("During the day, Atria checks your heart rate every few minutes instead of continuously."))
        XCTAssertTrue(vitals.contains("Rows show evidence counts until checked."))
        XCTAssertTrue(settings.contains("Tunes sleep-baseline colors and evidence thresholds"))
        XCTAssertFalse(settings.contains("These bands tune sleep-only deviations and candidate-frame evidence."))
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
