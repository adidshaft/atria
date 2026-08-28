import XCTest

final class AtriaOverviewOnboardingDensityTests: XCTestCase {
    private func source(_ relativePath: String) throws -> String {
        let testsURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let appURL = testsURL.deletingLastPathComponent().appendingPathComponent("Atria")
        return try String(contentsOf: appURL.appendingPathComponent(relativePath), encoding: .utf8)
    }

    func testStrapOnboardingIsImageLedWithDetailCollapsedButHonest() throws {
        // 2026-07-31 redesign (user: onboarding should be minimal + image-first
        // like the reference screens, "not just texts"). The strap page now leads
        // with the visual StrapSetupShowcase; the old compact setupStepTile strip
        // and the always-on pairing/data wall-of-text were removed. Details collapse
        // behind ONE tap -- but the honest pairing + data-handling copy must remain
        // present (now inside the DisclosureGroup), never dropped.
        let source = try source("AtriaOnboardingFlow.swift")
        let start = try XCTUnwrap(source.range(of: "private var strapPage"))
        let end = try XCTUnwrap(source.range(of: "private var youPage", range: start.upperBound..<source.endIndex))
        let page = String(source[start.lowerBound..<end.lowerBound])

        // Image-led, minimal: showcase leads; no tile strip, no always-visible wall.
        XCTAssertTrue(page.contains("StrapSetupShowcase()"))
        XCTAssertFalse(page.contains("LazyVGrid(columns: [GridItem(.adaptive(minimum: 92)"))
        XCTAssertEqual(page.components(separatedBy: "setupStepTile(").count - 1, 0)
        XCTAssertTrue(page.contains("DisclosureGroup"))
        // Honesty preserved: pairing truth + data-handling detail still present.
        XCTAssertTrue(page.contains("side light pulses blue"))
        XCTAssertTrue(page.contains("The strap stops its blue light when pairing finishes"))
        XCTAssertTrue(page.contains("Atria does not force the light off"))
        XCTAssertTrue(page.contains("FreshStartPolicy.summary"))
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
        XCTAssertTrue(bootstrap.contains("verified replay pages are acknowledged only after they are saved on this iPhone"))
        XCTAssertTrue(bootstrap.contains("It never disconnects live tracking or discards unseen strap data to force a fresh start."))
        XCTAssertTrue(bootstrap.contains("Atria does not send a physical-erase command"),
                      "onboarding must not promise an unverified destructive erase")
    }

    func testCompactOnboardingHeadersKeepAccessibleCombinedTitles() throws {
        let source = try source("AtriaOnboardingFlow.swift")

        XCTAssertTrue(source.contains("private func onboardingHeader"))
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
        let start = try XCTUnwrap(source.range(of: "private var expectationsPage"))
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

    func testWelcomeUsesAtriaLogoInsteadOfGenericSparkles() throws {
        let source = try source("AtriaOnboardingFlow.swift")
        let pageStart = try XCTUnwrap(source.range(of: "private var nicknamePage"))
        let pageEnd = try XCTUnwrap(source.range(of: "private var ringsPage",
                                                 range: pageStart.upperBound..<source.endIndex))
        let page = String(source[pageStart.lowerBound..<pageEnd.lowerBound])

        XCTAssertTrue(page.contains("onboardingBrandTile"))
        XCTAssertFalse(page.contains("systemImage: \"sparkles\""))
        XCTAssertTrue(source.contains("Image(\"AtriaLogo\")"),
                      "The first onboarding impression should use Atria's real brand mark")
    }

    func testOnboardingCustomControlsKeepFullTargetsAndReadableBehaviorLabels() throws {
        let source = try source("AtriaOnboardingFlow.swift")
        let showcaseStart = try XCTUnwrap(source.range(of: "private struct StrapSetupShowcase"))
        let parserStart = try XCTUnwrap(source.range(of: "enum AtriaOptionalProfileNumber",
                                                      range: showcaseStart.upperBound..<source.endIndex))
        let showcase = String(source[showcaseStart.lowerBound..<parserStart.lowerBound])
        let chipStart = try XCTUnwrap(source.range(of: "private func behaviorChip"))
        let chipEnd = try XCTUnwrap(source.range(of: "private func toggleTrackedBehavior",
                                                 range: chipStart.upperBound..<source.endIndex))
        let chip = String(source[chipStart.lowerBound..<chipEnd.lowerBound])

        XCTAssertGreaterThanOrEqual(showcase.components(separatedBy: ".frame(width: 44, height: 44)").count - 1, 2,
                                    "The rotate action and each scene selector need full touch targets")
        XCTAssertTrue(source.contains("private var behaviorGridColumns: [GridItem]"))
        XCTAssertTrue(source.contains("if dynamicTypeSize.isAccessibilitySize"))
        XCTAssertTrue(chip.contains(".frame(minHeight: 44)"))
        XCTAssertTrue(chip.contains(".lineLimit(2)"))
        XCTAssertFalse(chip.contains(".minimumScaleFactor"),
                       "Behavior names should wrap instead of shrinking below a readable size")
    }

    func testRestoredOnboardingDoesNotClaimReadyBeforeSavedStrapIdentityMatches() throws {
        let flow = try source("AtriaOnboardingFlow.swift")
        let statusStart = try XCTUnwrap(flow.range(of: "private var onboardingHistoryStatus"))
        let pageStart = try XCTUnwrap(flow.range(of: "private var youPage",
                                                 range: statusStart.upperBound..<flow.endIndex))
        let status = String(flow[statusStart.lowerBound..<pageStart.lowerBound])

        XCTAssertTrue(status.contains("if historyBootstrap.isCompleteForCurrentStrap"))
        XCTAssertTrue(status.contains("Saved setup found · reconnect your strap to verify it"))
        XCTAssertTrue(status.contains("Ready · \\(historyBootstrap.snapshot.importedRows) records safely added"))
        XCTAssertTrue(status.contains(": historyBootstrap.snapshot.detail"),
                      "A zero-row completion must retain the bootstrap's truthful live-ready detail")
    }

    func testConnectionPermissionGuidanceIsVisibleAndAdaptsAtAccessibilitySizes() throws {
        let content = try source("ContentView.swift")
        let flow = try source("AtriaOnboardingFlow.swift")
        let start = try XCTUnwrap(content.range(of: "struct OnboardingConnectionStatusView"))
        let end = try XCTUnwrap(content.range(of: "extension View",
                                              range: start.upperBound..<content.endIndex))
        let status = String(content[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(status.contains("Text(subtitle)"),
                      "Bluetooth and pairing guidance must not be VoiceOver-only")
        XCTAssertTrue(status.contains("Bluetooth access needed"))
        XCTAssertTrue(status.contains("Allow Atria to use Bluetooth in Settings"))
        XCTAssertTrue(status.contains("Turn on Bluetooth in Control Center or Settings to connect."))
        XCTAssertTrue(status.contains("ble.bluetoothPermissionDenied"),
                      "Permission denial must not be presented as a powered-off radio")
        XCTAssertTrue(status.contains("if dynamicTypeSize.isAccessibilitySize"))
        XCTAssertTrue(status.contains("VStack(alignment: .leading, spacing: 10)"))
        XCTAssertTrue(flow.contains("if bluetoothRecovery == .permissionDenied { return false }"),
                      "Denied users need an enabled recovery action, not a permanent dead end")
        XCTAssertTrue(flow.contains("onboardingBluetoothRecovery == .permissionDenied"))
        XCTAssertTrue(flow.contains("UIApplication.openSettingsURLString"),
                      "Permission recovery must use the supported per-app Settings URL")
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
        // The flow owns all 8 first-launch pages, including the three
        // personalization pages adopted from the design.
        XCTAssertEqual(steps.components(separatedBy: "\n        case ").count - 1, 8)
        XCTAssertTrue(steps.contains("case whatThisIs"))
        XCTAssertTrue(steps.contains("case strap"))
        XCTAssertTrue(steps.contains("case you"))
        XCTAssertTrue(steps.contains("case behaviors"))
        XCTAssertTrue(steps.contains("case expectations"))
        XCTAssertTrue(steps.contains("case nickname"))
        XCTAssertTrue(steps.contains("case rings"))
        XCTAssertTrue(steps.contains("case cycle"))
        XCTAssertTrue(content.contains("onboardingStage = .sharingChoice("))
        XCTAssertFalse(content.contains("onboardingStage = .nickname(profile)"))
    }
}
