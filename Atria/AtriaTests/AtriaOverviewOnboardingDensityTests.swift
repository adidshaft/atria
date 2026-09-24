import XCTest
@testable import Atria

final class AtriaOverviewOnboardingDensityTests: XCTestCase {
    private func source(_ relativePath: String) throws -> String {
        let testsURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let appURL = testsURL.deletingLastPathComponent().appendingPathComponent("Atria")
        return try String(contentsOf: appURL.appendingPathComponent(relativePath), encoding: .utf8)
    }

    func testStrapOnboardingIsImageLedWithDetailCollapsedButHonest() throws {
        // 2026-09-24 setup rework: the strap page is a live checklist
        // (StrapSetupPanel). The image-led showcase and the honest pairing and
        // data-handling copy moved behind ONE "How to pair" tap — present,
        // never dropped.
        let source = try source("AtriaOnboardingFlow.swift")
        let start = try XCTUnwrap(source.range(of: "private struct StrapSetupPanel"))
        let panel = String(source[start.lowerBound...])

        XCTAssertTrue(panel.contains("StrapSetupShowcase()"))
        XCTAssertTrue(panel.contains("DisclosureGroup"))
        XCTAssertFalse(panel.contains("LazyVGrid(columns: [GridItem(.adaptive(minimum: 92)"))
        XCTAssertEqual(panel.components(separatedBy: "setupStepTile(").count - 1, 0)
        XCTAssertTrue(panel.contains("AtriaStrapSetup.Problem.pairingMode"))
        XCTAssertTrue(AtriaStrapSetup.Problem.pairingMode.contains("side light pulses blue"))
        XCTAssertTrue(panel.contains("FreshStartPolicy.summary"))
        XCTAssertTrue(panel.contains("FreshStartPolicy.interruptionDisclosure"))
        XCTAssertFalse(panel.contains("StrapChargeIllustration"))
    }

    func testConnectActionCannotAdvanceBeforeDurableHistoryBootstrap() throws {
        // 2026-09-24: the strap step advances only on a verified setup (the
        // read-only secure check confirmed) or a completion already bound to
        // this strap; the last page routes back instead of completing.
        let source = try source("AtriaOnboardingFlow.swift")
        let bootstrap = try self.source("AtriaOnboardingHistoryBootstrap.swift")
        let actionStart = try XCTUnwrap(source.range(of: "private func primaryAction()"))
        let actionEnd = try XCTUnwrap(source.range(of: "private func recordVerifiedStrap()",
                                                  range: actionStart.upperBound..<source.endIndex))
        let action = String(source[actionStart.lowerBound..<actionEnd.lowerBound])

        XCTAssertTrue(action.contains("if strapSetup.verdict.isReady || historyBootstrap.isSetupComplete"))
        XCTAssertTrue(action.contains("if historyBootstrap.isSetupComplete { move(to: .you) }"))
        XCTAssertTrue(action.contains("case .retry: strapSetup.retry()"))
        XCTAssertTrue(action.contains("onComplete(draft)"))
        XCTAssertTrue(action.contains("move(to: .strap)"),
                      "an incomplete setup on the last page must route back instead of completing")

        XCTAssertTrue(bootstrap.contains("!AtriaStrapSetup.Tracker.verifies(ble.strapSetupSignals.secureCheck)"),
                      "connected alone must not complete setup; the protected channel must be proven")
        XCTAssertTrue(bootstrap.contains("func completeVerifiedSetup(peripheralIdentifier: String)"))
        XCTAssertTrue(bootstrap.contains("durableTransportAuthorityAndLiveRestored"))
        XCTAssertTrue(bootstrap.contains("recoveredDataPublished"))
        XCTAssertTrue(bootstrap.contains("currentPeripheralIdentifier == requestedPeripheralIdentifier"),
                      "completion must be bound to the exact strap that was imported")
        XCTAssertTrue(bootstrap.contains("Verified replay pages are acknowledged only after they are saved on this iPhone"))
        XCTAssertTrue(bootstrap.contains("It never disconnects live tracking or discards unseen strap data to force a fresh start."))
        XCTAssertTrue(bootstrap.contains("Atria does not send a physical-erase command"),
                      "onboarding must not promise an unverified destructive erase")
    }

    func testCompactOnboardingHeadersKeepAccessibleCombinedTitles() throws {
        let source = try source("AtriaOnboardingFlow.swift")

        XCTAssertTrue(source.contains("private func onboardingHeader"))
        XCTAssertTrue(source.contains(".scrollDismissesKeyboard(.interactively)"))
        XCTAssertTrue(source.contains("ToolbarItemGroup(placement: .keyboard)"))
        XCTAssertTrue(source.contains("Button(\"Done\") { dismissKeyboard() }"),
                      "Number pads have no return key; onboarding must offer Done")
        XCTAssertTrue(source.contains(".accessibilityElement(children: .combine)"))
        // 2026-07-31: the strap page went image-led (StrapSetupShowcase), so its
        // "Connect your strap" onboardingHeader was removed; the remaining pages
        // still use the accessible combined-title header.
        XCTAssertTrue(source.contains("onboardingHeader(\"Wear it tonight\""))
    }

    func testExpectationsUseAdaptiveVerticalTimeline() throws {
        // 2026-07-30 redesign: the expectations step is a vertical "what to expect"
        // timeline (expectationStep x3) rather than a 3-across pill grid, so it
        // stacks and adapts to narrow widths / larger text by construction (no
        // fixed horizontal grid to overflow).
        let source = try source("AtriaOnboardingFlow.swift")
        let start = try XCTUnwrap(source.range(of: "private var tonightPage"))
        let end = try XCTUnwrap(source.range(of: "private var progressDots",
                                              range: start.upperBound..<source.endIndex))
        let page = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertEqual(page.components(separatedBy: "expectationStep(").count - 1, 3)
        XCTAssertFalse(page.contains("expectationPill("))
        XCTAssertFalse(page.contains("LazyVGrid(columns: [GridItem(.adaptive(minimum: 92)"),
                       "Vertical timeline must not force a fixed adaptive grid")
    }

    func testOnboardingKeepsSupportingCopyForVoiceOverWithoutRenderingExtraLines() throws {
        let source = try source("AtriaOnboardingFlow.swift")

        XCTAssertFalse(source.contains("Text(\"WHOOP insights without the subscription.\")"))
        XCTAssertTrue(source.contains(".accessibilityHint(\"Sleep, recovery, and strain insights from your strap.\")"))
        // 2026-07-30: expectation flow is a vertical timeline; assert its step copy
        // is present (each step combines its title + detail for VoiceOver) rather
        // than the old Wear/Sleep/Recovery pill titles.
        XCTAssertTrue(source.contains("title: \"Tonight\""))
        XCTAssertTrue(source.contains("title: \"Tomorrow morning\""))
        XCTAssertTrue(source.contains(".accessibilityElement(children: .combine)"))
        XCTAssertFalse(source.contains("detail: \"First sleep\""))
    }

    // 2026-09-24: the nickname page (and its logo tile) folded into About
    // you. The welcome page leads with the lifestyle hero; the guard against
    // generic decoration stays.
    func testWelcomeUsesAtriaLogoInsteadOfGenericSparkles() throws {
        let source = try source("AtriaOnboardingFlow.swift")
        let pageStart = try XCTUnwrap(source.range(of: "private var welcomePage"))
        let pageEnd = try XCTUnwrap(source.range(of: "private var restoreBackupRow",
                                                 range: pageStart.upperBound..<source.endIndex))
        let page = String(source[pageStart.lowerBound..<pageEnd.lowerBound])

        XCTAssertTrue(page.contains("onboardingLifestyleHero"))
        XCTAssertFalse(page.contains("systemImage: \"sparkles\""))
        XCTAssertFalse(source.contains("systemImage: \"sparkles\""))
    }

    func testOnboardingCustomControlsKeepFullTargetsAndReadableBehaviorLabels() throws {
        // 2026-09-24: behaviour chips left onboarding (Journal owns them); the
        // setup checklist rows inherit the full-target rule.
        let source = try source("AtriaOnboardingFlow.swift")
        let showcaseStart = try XCTUnwrap(source.range(of: "private struct StrapSetupShowcase"))
        let parserStart = try XCTUnwrap(source.range(of: "enum AtriaOptionalProfileNumber",
                                                      range: showcaseStart.upperBound..<source.endIndex))
        let showcase = String(source[showcaseStart.lowerBound..<parserStart.lowerBound])
        let listStart = try XCTUnwrap(source.range(of: "private var checklist: some View"))
        let listEnd = try XCTUnwrap(source.range(of: "private func indicator",
                                                 range: listStart.upperBound..<source.endIndex))
        let checklist = String(source[listStart.lowerBound..<listEnd.lowerBound])

        XCTAssertGreaterThanOrEqual(showcase.components(separatedBy: ".frame(width: 44, height: 44)").count - 1, 2,
                                    "The rotate action and each scene selector need full touch targets")
        XCTAssertTrue(checklist.contains(".frame(minHeight: 44)"))
        XCTAssertFalse(checklist.contains(".minimumScaleFactor"),
                       "Step names should wrap instead of shrinking below a readable size")
        XCTAssertTrue(source.contains("if dynamicTypeSize.isAccessibilitySize"))
    }

    func testRestoredOnboardingDoesNotClaimReadyBeforeSavedStrapIdentityMatches() throws {
        // 2026-09-24: completion is bound to the strap this phone is bonded to
        // (current link, else the saved identity), so a restored backup from
        // another strap never reads as done, and a link blip never bounces a
        // finished user back into setup.
        let bootstrap = try source("AtriaOnboardingHistoryBootstrap.swift")
        let content = try source("ContentView.swift")
        let start = try XCTUnwrap(bootstrap.range(of: "var isSetupComplete: Bool"))
        let body = String(bootstrap[start.lowerBound...].prefix(400))

        XCTAssertTrue(body.contains("snapshot.phase == .complete"))
        XCTAssertTrue(body.contains("ble.currentPeripheralIdentifier ?? ble.savedPeripheralIdentifier"))
        XCTAssertEqual(content.components(separatedBy: "onboardingHistoryBootstrap.isSetupComplete").count - 1, 3)
        XCTAssertFalse(content.contains("isCompleteForCurrentStrap"))
    }

    func testConnectionPermissionGuidanceIsVisibleAndAdaptsAtAccessibilitySizes() throws {
        // 2026-09-24: permission denial is its own coded problem (AT-102) with
        // an always-enabled Open Settings action; powered-off Bluetooth is a
        // different problem that resumes by itself.
        let flow = try source("AtriaOnboardingFlow.swift")
        XCTAssertEqual(AtriaStrapSetup.Problem.bluetoothDenied.action, .openSettings)
        XCTAssertEqual(AtriaStrapSetup.Problem.bluetoothOff.action, .wait)
        XCTAssertNotEqual(AtriaStrapSetup.Problem.bluetoothDenied.title, AtriaStrapSetup.Problem.bluetoothOff.title)
        XCTAssertTrue(AtriaStrapSetup.Problem.bluetoothDenied.steps.joined().contains("Settings"))
        XCTAssertTrue(flow.contains("case .openSettings: return \"Open Settings\""))
        XCTAssertTrue(flow.contains("case .openSettings: openApplicationSettings()"))
        XCTAssertTrue(flow.contains("UIApplication.openSettingsURLString"),
                      "Permission recovery must use the supported per-app Settings URL")
        XCTAssertTrue(flow.contains(".fixedSize(horizontal: false, vertical: true)"),
                      "fix steps wrap at accessibility sizes")
    }

    // 2026-08-28: `testOverviewRemovesDuplicateVisibleConnectionDetailButKeepsVoiceOverHint`
    // and `testCompletedOverviewChecklistRowsDoNotRepeatExplanationsVisually`
    // were deleted with their subjects. Both scanned
    // AtriaDisconnectedOverviewPanel / AtriaLaunchChecklistRow, which lived
    // inside the unreachable Overview tree (root AtriaOverviewLeadingHost, zero
    // construction sites) removed in this commit. They were the classic
    // green-suite-guarding-dead-code trap: passing, and protecting nothing a
    // user could reach.

    /// The readiness HOST this used to bound on was part of the dead Overview
    /// tree deleted 2026-08-28. `AtriaOverviewLiveProjectionState` itself was
    /// deliberately kept — it is pure, and its bucketing carries real unit
    /// coverage — so the state half of this pin survives, re-bounded on the
    /// next surviving declaration.
    func testOverviewGatesHighFrequencyLiveStateCoalescing() throws {
        let source = try source("AtriaOverviewSections.swift")
        let stateStart = try XCTUnwrap(source.range(of: "struct AtriaOverviewLiveProjectionState"))
        let stateEnd = try XCTUnwrap(source.range(of: "struct AtriaWeeklyPlanCard",
                                                  range: stateStart.upperBound..<source.endIndex))
        let state = String(source[stateStart.lowerBound..<stateEnd.lowerBound])

        XCTAssertTrue(state.contains("sessionProgressBucket"))
        XCTAssertTrue(state.contains("liveActiveCaloriesText"))
        XCTAssertTrue(state.contains("strapStepResearchCount"),
                      "Exact strap-step changes must remain immediate")
    }

    func testOverviewDynamicRowsUseDomainIdentityInsteadOfMutableOffsets() throws {
        let source = try source("AtriaOverviewSections.swift")

        // The circular strain-band loop was replaced by the compact strain
        // rail. Pin the stable domain identities now used by the remaining
        // enumerated dynamic rows: enum raw values, model IDs, behavior tags,
        // and the checklist string value itself. Mutable offsets must never
        // become SwiftUI identity for these rows.
        XCTAssertTrue(source.contains("id: \\.element.rawValue) { index, zone in"))
        XCTAssertTrue(source.contains("id: \\.element.id) { index, row in"))
        XCTAssertTrue(source.contains("id: \\.element.tag) { index, summary in"))
        // (the checklist ForEach this pinned lived in the deleted Overview tree)
        XCTAssertFalse(source.contains("ForEach(Array(companions.enumerated()), id: \\.offset)"))
        XCTAssertFalse(source.contains("ForEach(Array(bands.enumerated()), id: \\.offset)"))
        XCTAssertFalse(source.contains("ForEach(Array(rows.enumerated()), id: \\.offset)"))
        XCTAssertFalse(source.contains("ForEach(Array(visibleSummaries.enumerated()), id: \\.offset)"))
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

    // 2026-08-01: the first-launch flow deliberately grew from 5 to 8 pages to
    // adopt the design file's in-flow personalization (nickname, rings + center
    // number, cycle opt-in) at the user's explicit onboarding request. The
    // anti-duplication property this test guards is UNCHANGED and still
    // asserted: personalization is owned by the flow alone — ContentView's
    // OnboardingStage stays a two-stage machine (flow + sharingChoice) with no
    // personalization stages, and research consent remains the post-flow
    // sharingChoice step, never duplicated in-flow. Only the page-count
    // expectation was migrated (5 -> 8); trade-off (added first-launch pages)
    // surfaced to the user for veto.
    func testFirstLaunchOnboardingOwnsPersonalizationWithoutDuplicatingContentViewStages() throws {
        let content = try source("ContentView.swift")
        let stageStart = try XCTUnwrap(content.range(of: "private enum OnboardingStage"))
        let stageEnd = try XCTUnwrap(content.range(of: "init(ble:", range: stageStart.upperBound..<content.endIndex))
        let stages = String(content[stageStart.lowerBound..<stageEnd.lowerBound])
        let flow = try source("AtriaOnboardingFlow.swift")
        let stepStart = try XCTUnwrap(flow.range(of: "private enum Step: Int, CaseIterable"))
        let stepEnd = try XCTUnwrap(flow.range(of: "private struct PrimaryActionButton",
                                               range: stepStart.upperBound..<flow.endIndex))
        let steps = String(flow[stepStart.lowerBound..<stepEnd.lowerBound])

        // ContentView stays flow + sharingChoice — personalization is never
        // duplicated as a ContentView stage.
        XCTAssertTrue(stages.contains("case flow"))
        XCTAssertTrue(stages.contains("case sharingChoice(AthleteProfile)"))
        XCTAssertFalse(stages.contains("case nickname"))
        XCTAssertFalse(stages.contains("case ringPicker"))
        XCTAssertFalse(stages.contains("case womensHealth"))
        // 2026-09-24 (owner: "rework the onboarding entirely. make it
        // easier"): the flow is four pages. Nickname folded into About you;
        // rings, tracked behaviours and cycle tracking keep their defaults and
        // stay editable in Customize / Journal / Settings.
        XCTAssertEqual(steps.components(separatedBy: "\n        case ").count - 1, 4)
        XCTAssertTrue(steps.contains("case welcome"))
        XCTAssertTrue(steps.contains("case strap"))
        XCTAssertTrue(steps.contains("case you"))
        XCTAssertTrue(steps.contains("case tonight"))
        XCTAssertTrue(content.contains("onboardingStage = .sharingChoice("))
        XCTAssertFalse(content.contains("onboardingStage = .nickname(profile)"))
    }
}
