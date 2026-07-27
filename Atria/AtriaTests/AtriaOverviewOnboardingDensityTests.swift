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
        XCTAssertTrue(page.contains("Tap until blue"))
        XCTAssertTrue(page.contains("side light pulses blue"))
        XCTAssertTrue(page.contains("The strap stops its blue light when pairing finishes"))
        XCTAssertTrue(page.contains("Atria does not force the light off"))
        XCTAssertFalse(page.contains("StrapChargeIllustration"))
    }

    func testConnectActionCannotAdvanceBeforeDurableHistoryBootstrap() throws {
        let source = try source("AtriaOnboardingFlow.swift")
        let bootstrap = try self.source("AtriaOnboardingHistoryBootstrap.swift")
        let actionStart = try XCTUnwrap(source.range(of: "PrimaryActionButton(ble: ble,"))
        let actionEnd = try XCTUnwrap(source.range(of: ".padding(.horizontal, 20)",
                                                  range: actionStart.upperBound..<source.endIndex))
        let action = String(source[actionStart.lowerBound..<actionEnd.lowerBound])

        XCTAssertTrue(action.contains("if step == .strap, !onboardingStrapIsReady"))
        XCTAssertTrue(action.contains("ble.startScan(reason: \"onboarding_primary_connect\")"))
        XCTAssertTrue(action.contains("if onboardingStrapIsReady {"))
        XCTAssertTrue(action.contains("onComplete(draft)"))
        XCTAssertTrue(action.contains("move(to: .strap)"),
                      "Swiping past strap setup must route back instead of completing")

        XCTAssertTrue(source.contains("historyBootstrap.isCompleteForCurrentStrap"),
                      "Live HR alone must not bypass durable import and publication")
        XCTAssertTrue(source.contains("AtriaOnboardingHistoryBootstrapPolicy.FreshStartPolicy.summary"))
        XCTAssertTrue(source.contains("AtriaOnboardingHistoryBootstrapPolicy.FreshStartPolicy.disclosure"))
        XCTAssertTrue(source.contains("AtriaOnboardingHistoryBootstrapPolicy.FreshStartPolicy.interruptionDisclosure"))
        XCTAssertTrue(bootstrap.contains("durableTransportAuthorityAndLiveRestored"))
        XCTAssertTrue(bootstrap.contains("recoveredDataPublished"))
        XCTAssertTrue(bootstrap.contains("currentPeripheralIdentifier == requestedPeripheralIdentifier"),
                      "completion must be bound to the exact strap that was imported")
        XCTAssertTrue(bootstrap.contains("saved on this iPhone before their verified replay pages are acknowledged"))
        XCTAssertTrue(bootstrap.contains("It never discards unseen strap data to force a fresh start."))
        XCTAssertTrue(bootstrap.contains("Atria does not send a physical-erase command"),
                      "onboarding must not promise an unverified destructive erase")
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

        // 2026-07-17: the companions ForEach pin was retired — commit 824a411e
        // refactored companion rows into scrub-context text, so neither the
        // domain-identity loop nor the offset anti-pattern exists for them.
        // The remaining loops must still use domain identity, never offsets.
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
        let flow = try source("AtriaOnboardingFlow.swift")
        let stepStart = try XCTUnwrap(flow.range(of: "private enum Step: Int, CaseIterable"))
        let stepEnd = try XCTUnwrap(flow.range(of: "private struct PrimaryActionButton",
                                               range: stepStart.upperBound..<flow.endIndex))
        let steps = String(flow[stepStart.lowerBound..<stepEnd.lowerBound])

        XCTAssertTrue(stages.contains("case flow"))
        XCTAssertTrue(stages.contains("case sharingChoice(AthleteProfile)"))
        XCTAssertFalse(stages.contains("case nickname"))
        XCTAssertFalse(stages.contains("case ringPicker"))
        XCTAssertFalse(stages.contains("case womensHealth"))
        XCTAssertEqual(steps.components(separatedBy: "\n        case ").count - 1, 5)
        XCTAssertTrue(steps.contains("case whatThisIs"))
        XCTAssertTrue(steps.contains("case strap"))
        XCTAssertTrue(steps.contains("case you"))
        XCTAssertTrue(steps.contains("case behaviors"))
        XCTAssertTrue(steps.contains("case expectations"))
        XCTAssertTrue(content.contains("onboardingStage = .sharingChoice("))
        XCTAssertFalse(content.contains("onboardingStage = .nickname(profile)"))
    }
}
