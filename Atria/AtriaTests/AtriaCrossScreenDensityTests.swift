import XCTest

final class AtriaCrossScreenDensityTests: XCTestCase {
    private func source(_ relativePath: String) throws -> String {
        let testsURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let appURL = testsURL.deletingLastPathComponent().appendingPathComponent("Atria")
        return try String(contentsOf: appURL.appendingPathComponent(relativePath), encoding: .utf8)
    }

    func testTodayCardsKeepRationaleAccessibleWithoutRepeatingItVisually() throws {
        let source = try source("AtriaTodayScreen.swift")
        let planStart = try XCTUnwrap(source.range(of: "private struct AtriaTodayPlanCard"))
        let planEnd = try XCTUnwrap(source.range(of: "private struct AtriaStrainTargetCard", range: planStart.upperBound..<source.endIndex))
        let plan = String(source[planStart.lowerBound..<planEnd.lowerBound])

        XCTAssertFalse(plan.contains("Text(detail)"))
        XCTAssertTrue(plan.contains(".accessibilityLabel(\"Today's Plan. \\(title). \\(detail). \\(target).\")"))

        let weeklyStart = try XCTUnwrap(source.range(of: "private struct AtriaTodayWeeklyPlanTargetRow"))
        let weeklyEnd = try XCTUnwrap(source.range(of: "private struct AtriaTodayGlanceTile", range: weeklyStart.upperBound..<source.endIndex))
        let weekly = String(source[weeklyStart.lowerBound..<weeklyEnd.lowerBound])
        XCTAssertFalse(weekly.contains("Text(target.detail)"))
        XCTAssertTrue(weekly.contains("target.detail"), "VoiceOver should retain the target rationale")
    }

    func testJournalEmptyStatesDoNotStackInstructionParagraphs() throws {
        let source = try source("AtriaJournalTab.swift")

        XCTAssertFalse(source.contains("Unlocks after roughly 2–3 weeks of detailed answers."))
        XCTAssertTrue(source.contains("Text(\"About 2–3 weeks of answers\")"))
        XCTAssertFalse(source.contains("Text(\"Skipped questions stay unanswered.\")"))
        XCTAssertTrue(source.contains(".accessibilityLabel(\"Check-in done. Skipped questions stay unanswered.\")"))
        XCTAssertFalse(source.contains("Log today to start your pattern — the full 90-day view builds as history grows."))
        XCTAssertTrue(source.contains("The full 90-day pattern appears as logging history grows."))
    }

    func testWorkoutTargetControlsUseSaveSemanticsAndCompactGuidance() throws {
        let source = try source("AtriaLiveWorkoutView.swift")

        XCTAssertTrue(source.contains("Button(\"Close\") { showSetLogger = false }"))
        XCTAssertTrue(source.contains("Button(\"Save\") { commitAndDismiss() }"))
        XCTAssertFalse(source.contains("Follows Atria's live strain guidance."))
        XCTAssertFalse(source.contains("Pick a zone to hold. Atria maps it to a strain band."))
        XCTAssertFalse(source.contains("Set a direct strain number to aim for."))
        XCTAssertTrue(source.contains("Atria is learning your live strain guidance target."))
    }

    func testSettingsDetailsUseNativeDisclosureAndAccessibleHints() throws {
        let source = try source("AtriaSettingsView.swift")
        let helperStart = try XCTUnwrap(source.range(of: "private func settingsInfoRow"))
        let helperEnd = try XCTUnwrap(source.range(of: "private var appVersion", range: helperStart.upperBound..<source.endIndex))
        let helper = String(source[helperStart.lowerBound..<helperEnd.lowerBound])

        XCTAssertTrue(helper.contains("DisclosureGroup"))
        XCTAssertTrue(helper.contains(".accessibilityHint(detail)"))
        XCTAssertFalse(helper.contains("VStack(alignment: .leading"))
        XCTAssertFalse(source.contains("Text(\"Read-only context from your food app:"))
        XCTAssertFalse(source.contains("Text(\"Pulls data your strap stored while disconnected"))
    }

    func testSettingsAlertCardsRemoveVisibleExplanationsAndAdaptTheirGrid() throws {
        let alerts = try source("AtriaHapticAlerts.swift")
        let settings = try source("AtriaSettingsView.swift")

        XCTAssertFalse(alerts.contains("Text(\"Incoming calls, zones, targets, and low strap battery.\")"))
        XCTAssertFalse(alerts.contains("Text(\"Choose the coaching nudges Atria can send on this phone. Nothing leaves your device.\")"))
        XCTAssertTrue(alerts.contains(".accessibilityLabel(\"Phone haptics. Incoming calls, zones, targets, and low strap battery.\")"))
        XCTAssertTrue(alerts.contains(".accessibilityLabel(\"Notifications. Choose coaching nudges Atria can send on this phone. Nothing leaves your device.\")"))
        XCTAssertTrue(alerts.contains("AtriaAlertSettingsGrid.columns(for: dynamicTypeSize)"))

        XCTAssertFalse(settings.contains("Text(\"Phone-side alerts and on-device notifications only. Nothing leaves your phone.\")"))
        XCTAssertFalse(settings.contains("Text(\"Atria reconnects the strap when the radio mode changes.\")"))
        XCTAssertFalse(settings.contains("Text(\"Uses live strap HR and a little extra battery.\")"))
        XCTAssertTrue(settings.contains(".accessibilityHint(\"Changing mode reconnects the strap.\")"))
        XCTAssertTrue(settings.contains(".accessibilityHint(\"Uses live strap heart rate and slightly more battery.\")"))
    }

    func testActivityUsesOneCompactDayToolbarAndCompactTimeAxis() throws {
        let source = try source("AtriaActivityMonitor.swift")
        let toolbarStart = try XCTUnwrap(source.range(of: "private var activityToolbar"))
        let toolbarEnd = try XCTUnwrap(source.range(of: "private var activityLoadingState", range: toolbarStart.upperBound..<source.endIndex))
        let toolbar = String(source[toolbarStart.lowerBound..<toolbarEnd.lowerBound])
        let timelineStart = try XCTUnwrap(source.range(of: "private var dayTimelineCard"))
        let timelineEnd = try XCTUnwrap(source.range(of: "private var addActivityMenu", range: timelineStart.upperBound..<source.endIndex))
        let timeline = String(source[timelineStart.lowerBound..<timelineEnd.lowerBound])

        XCTAssertTrue(toolbar.contains("addActivityMenu"))
        XCTAssertEqual(source.components(separatedBy: "addActivityMenu").count - 1, 2,
                       "Activity should declare one Add menu and render it only in the day toolbar")
        XCTAssertTrue(toolbar.contains("frame(width: 44, height: 44)"))
        XCTAssertFalse(source.contains("private var activityHeader"))
        XCTAssertTrue(timeline.contains("AxisMarks(values: axisTicks.map(\\.date))"))
        XCTAssertTrue(timeline.contains("font(.system(size: 9"))
        XCTAssertTrue(timeline.contains(".accessibilityLabel(\"Activity timeline\")"))
        XCTAssertTrue(timeline.contains(".symbolSize(360)"))
        XCTAssertTrue(timeline.contains(".frame(height: 44)"),
                      "An empty activity axis should reserve one compact, predictable row")
        XCTAssertFalse(timeline.contains("Previous day"), "Day controls belong in the single toolbar, not another stacked row")
        XCTAssertFalse(source.contains("detection.kind == .workout ? \"figure.run\""))
        XCTAssertFalse(source.contains("$0.kind == .workout ? \"figure.run\""))
        XCTAssertTrue(source.contains("detection.kind == .workout ? \"figure.mixed.cardio\""),
                      "unclassified detections must use a neutral activity icon")
        XCTAssertTrue(source.contains("let compactAssignments = AtriaActivityTimelineLanePacker.assignments"))
        XCTAssertTrue(source.contains("lane: \"timeline-\\(compactAssignments[$0.id] ?? 0)\""),
                      "Non-overlapping sleep, workout, and review spans should reuse compact lanes")
    }

    func testOnboardingConnectionCardKeepsGuidanceForVoiceOverWithoutVisibleParagraph() throws {
        let source = try source("ContentView.swift")
        let start = try XCTUnwrap(source.range(of: "struct OnboardingConnectionStatusView"))
        let end = try XCTUnwrap(source.range(of: "extension View", range: start.upperBound..<source.endIndex))
        let card = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertFalse(card.contains("Text(subtitle)"))
        XCTAssertTrue(card.contains(".accessibilityLabel(\"\\(title). \\(subtitle)\")"))
        XCTAssertTrue(card.contains(".padding(.vertical, 12)"))
    }

    func testLiveWorkoutKeepsPrimaryActionsSideBySideWithoutInstructionCopy() throws {
        let source = try source("AtriaLiveWorkoutView.swift")
        let start = try XCTUnwrap(source.range(of: "private var workoutActionsCard"))
        let end = try XCTUnwrap(source.range(of: "private func loggedSetRow", range: start.upperBound..<source.endIndex))
        let actions = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(actions.contains("HStack(spacing: 10)"))
        XCTAssertTrue(actions.contains("Label(\"Log set\""))
        XCTAssertTrue(actions.contains("isPaused ? \"Resume\" : \"Pause\""))
        XCTAssertFalse(actions.contains("Log your workout"))
        XCTAssertFalse(actions.contains("Pause your workout"))
    }

    func testActiveBreathworkUsesOneRemainingTimeAndCompactAnimatedOrb() throws {
        let source = try source("AtriaBreathworkSession.swift")
        let headerStart = try XCTUnwrap(source.range(of: "private var header"))
        let headerEnd = try XCTUnwrap(source.range(of: "private var setupView", range: headerStart.upperBound..<source.endIndex))
        let header = String(source[headerStart.lowerBound..<headerEnd.lowerBound])
        let activeStart = try XCTUnwrap(source.range(of: "private func activeSession"))
        let activeEnd = try XCTUnwrap(source.range(of: "private func animatedBreathCircle", range: activeStart.upperBound..<source.endIndex))
        let active = String(source[activeStart.lowerBound..<activeEnd.lowerBound])
        let orbStart = try XCTUnwrap(source.range(of: "private func animatedBreathCircle"))
        let orbEnd = try XCTUnwrap(source.range(of: "private func resultView", range: orbStart.upperBound..<source.endIndex))
        let orb = String(source[orbStart.lowerBound..<orbEnd.lowerBound])

        XCTAssertTrue(header.contains("TimelineView(.periodic(from: .now, by: 1))"))
        XCTAssertTrue(header.contains("Text(\"Relax · \\(timeText(remaining))\")"))
        XCTAssertFalse(active.contains(".font(.system(size: 42"), "Remaining time should not consume a second hero row")
        XCTAssertTrue(active.contains("Label(currentHeartRate > 0"))
        XCTAssertTrue(orb.contains("TimelineView(.periodic(from: .now, by: 1))"),
                      "Breathwork copy should update no faster than once per second")
        XCTAssertFalse(orb.contains("TimelineView(.animation"),
                       "The radial-gradient and native-glass orb must not rebuild at display-link cadence")
        XCTAssertTrue(orb.contains("await runBreathOrbAnimation(startedAt: startedAt)"))
        XCTAssertTrue(orb.contains("withAnimation(animation)"),
                      "Orb motion should interpolate compositor-friendly scale and opacity endpoints")
        XCTAssertTrue(orb.contains("Task.sleep(for: .seconds"),
                      "Phase state should change only at the 45/10/45 boundaries")
        XCTAssertTrue(orb.contains(".frame(width: 260, height: 260)"))
        XCTAssertTrue(orb.contains("reduceMotion ? 1"))
        XCTAssertTrue(orb.contains(".accessibilityLabel("))
    }

    func testBreathworkPresentationsObserveLivePulseThroughNarrowHosts() throws {
        let todaySource = try source("AtriaTodayScreen.swift")
        let todayHostStart = try XCTUnwrap(todaySource.range(of: "private struct AtriaTodayBreathworkSessionHost"))
        let todayHostEnd = try XCTUnwrap(todaySource.range(of: "private struct AtriaTodaySleepNeedKey",
                                                           range: todayHostStart.upperBound..<todaySource.endIndex))
        let todayHost = String(todaySource[todayHostStart.lowerBound..<todayHostEnd.lowerBound])

        XCTAssertTrue(todaySource.contains("AtriaTodayBreathworkSessionHost(pulseStore: pulseStore"))
        XCTAssertTrue(todayHost.contains("@ObservedObject var pulseStore: AtriaHomeModel.HeroPulseStore"))
        XCTAssertTrue(todayHost.contains("currentHeartRate: pulseStore.state.heartRate"))
        XCTAssertTrue(todayHost.contains("currentRRSamples: pulseStore.state.recentRRSamples"))

        let healthSource = try source("AtriaHealthScreen.swift")
        let healthHostStart = try XCTUnwrap(healthSource.range(of: "private struct AtriaHealthBreathworkSessionHost"))
        let healthHostEnd = try XCTUnwrap(healthSource.range(of: "private struct AtriaHealthStressSection",
                                                             range: healthHostStart.upperBound..<healthSource.endIndex))
        let healthHost = String(healthSource[healthHostStart.lowerBound..<healthHostEnd.lowerBound])

        XCTAssertTrue(healthSource.contains("AtriaHealthBreathworkSessionHost(pulseStore: pulseStore"))
        XCTAssertTrue(healthHost.contains("@ObservedObject var pulseStore: AtriaHomeModel.PulseLiveStore"))
        XCTAssertTrue(healthHost.contains("currentHeartRate: pulseStore.state.heartRate"))
        XCTAssertTrue(healthHost.contains("currentRRSamples: pulseStore.state.recentRRSamples"))
    }

    func testCustomizeGlanceOrderHasStableDragAndAccessibleMoveActions() throws {
        let customizeSource = try source("AtriaCustomizeSheet.swift")
        let todaySource = try source("AtriaTodayScreen.swift")
        let start = try XCTUnwrap(customizeSource.range(of: "private var metricsSection"))
        let end = try XCTUnwrap(customizeSource.range(of: "private var metricToggleSection",
                                                       range: start.upperBound..<customizeSource.endIndex))
        let section = String(customizeSource[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(section.contains("EditButton()"), "Reorder must have an obvious visible affordance")
        XCTAssertTrue(section.contains(".draggable(metric.dragPayload)"))
        XCTAssertTrue(section.contains("AtriaTodayMetric.draggedMetric(from: payload)"))
        XCTAssertTrue(section.contains("Move \\(metric.label) up"))
        XCTAssertTrue(section.contains("Move \\(metric.label) down"))
        XCTAssertFalse(section.contains("ForEach(Array(selectedMetrics.enumerated())"),
                       "Metric identity must not depend on mutable array offsets")
        XCTAssertTrue(todaySource.contains("private var glanceKicker"))
        XCTAssertTrue(todaySource.contains("accessibilityLabel(\"Reorder At a glance\")"),
                      "The live grid needs a visible compact path into drag-and-drop ordering")
    }

    func testCustomizeCanResetPersistedGlanceOrderToDefaults() throws {
        let source = try source("AtriaCustomizeSheet.swift")
        let start = try XCTUnwrap(source.range(of: "private var resetSection"))
        let end = try XCTUnwrap(source.range(of: "private func metricBinding",
                                              range: start.upperBound..<source.endIndex))
        let reset = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(reset.contains("Label(\"Reset to defaults\""))
        XCTAssertTrue(source.contains(".confirmationDialog(\"Reset Today layout?\""))
        XCTAssertTrue(source.contains("draft = .default"),
                      "Reset must restore the canonical At a glance order, visibility, and sizes")
        XCTAssertTrue(source.contains("onCommit(draft.validated())"),
                      "The reset draft must still use the sheet's single Save commit")
    }

    func testTodayRingCollapsesIntoPinnedIconValueRail() throws {
        let todaySource = try source("AtriaTodayScreen.swift")
        let start = try XCTUnwrap(todaySource.range(of: "private struct AtriaTodayHeroShrink"))
        let end = try XCTUnwrap(todaySource.range(of: "private struct AtriaTodayGlanceItem",
                                                  range: start.upperBound..<todaySource.endIndex))
        let collapse = String(todaySource[start.lowerBound..<end.lowerBound])

        let home = try source("AtriaHomeView.swift")
        XCTAssertTrue(todaySource.contains(".preference(key: AtriaTodayCompactRingPreferenceKey.self"))
        XCTAssertTrue(home.contains(".overlayPreferenceValue(AtriaTodayCompactRingPreferenceKey.self)"))
        XCTAssertTrue(collapse.contains("AtriaTodayCompactRingRail"))
        XCTAssertTrue(home.contains("private struct AtriaDashboardScrollSurface"))
        XCTAssertTrue(home.contains("onScrollGeometryChange(for: Bool.self)"),
                      "Scrolling should invalidate the surface only when the compact-header threshold changes")
        XCTAssertTrue(home.contains("showsCompactHeader"))
        XCTAssertFalse(home.contains("@State private var scrollOffset"),
                       "A continuously changing offset would rebuild the dashboard throughout every swipe")
        XCTAssertFalse(home.contains("let quantized ="))
        XCTAssertTrue(home.contains("viewport-"))
        XCTAssertTrue(collapse.contains("ForEach(slots, id: \\.metric.title)"), "Configured ring metrics need stable identity")
        XCTAssertTrue(collapse.contains("Text(slot.slot.compactEmoji)"))
        XCTAssertTrue(collapse.contains("Text(slot.metric.value)"))
        XCTAssertFalse(collapse.contains("Text(slot.metric.title)"), "Collapsed rail should contain only icons and values")
        XCTAssertTrue(collapse.contains(".glassEffect(.regular"))
    }

    func testCompactRingUsesRequestedEmojiAndNumberVocabulary() throws {
        let ring = try source("AtriaTriRing.swift")

        for emoji in ["🌙", "❤️", "🔥", "📈", "💓"] {
            XCTAssertTrue(ring.contains("return \"\(emoji)\""))
        }
    }

    func testSettingsStartsAsFiveCompactPlainLanguageDestinations() throws {
        let source = try source("AtriaSettingsView.swift")
        let labelsStart = try XCTUnwrap(source.range(of: "private var settingsHub"))
        let labelsEnd = try XCTUnwrap(source.range(of: "private var personalSettingsPage",
                                                   range: labelsStart.upperBound..<source.endIndex))
        let groups = String(source[labelsStart.lowerBound..<labelsEnd.lowerBound])

        for title in ["Personal", "Strap", "Alerts", "Data", "Privacy & About"] {
            XCTAssertTrue(source.contains("\"\(title)\""))
        }
        XCTAssertTrue(groups.contains("ForEach(visibleDestinations)"),
                      "The root hub should reuse one concrete row type to avoid Swift metadata recursion")
        XCTAssertEqual(groups.components(separatedBy: "NavigationLink(value:").count - 1, 1,
                       "Separate generic NavigationLink expressions can overflow the stack during sheet presentation")
        XCTAssertFalse(groups.contains("subtitle:"), "Top-level Settings rows should not stack explanatory subtitles")
        XCTAssertFalse(groups.contains("DisclosureGroup"), "Destinations should not expand into one long settings wall")
        XCTAssertFalse(source.contains("atria.settings.v3.expanded."))
        XCTAssertTrue(source.contains(".frame(minHeight: 44)"))
        XCTAssertTrue(source.contains("Label(\"Advanced targets\", systemImage: \"scope\")"),
                      "Dense target controls belong behind one explicit destination")
        XCTAssertFalse(source.contains("title: \"On this iPhone\""))
        XCTAssertFalse(source.contains("title: \"Background tracking\""))
        XCTAssertFalse(source.contains("storageFootprintBreakdown"))
    }

    func testRingImageUsesCompactLauncherAndTwoCornerActions() throws {
        let today = try source("AtriaTodayScreen.swift")
        let menuStart = try XCTUnwrap(today.range(of: "private var topActionMenu"))
        let menuEnd = try XCTUnwrap(today.range(of: "private var triRingHero",
                                                range: menuStart.upperBound..<today.endIndex))
        let menu = String(today[menuStart.lowerBound..<menuEnd.lowerBound])
        XCTAssertTrue(menu.contains(".frame(width: 32, height: 32)"))
        XCTAssertTrue(menu.contains(".controlSize(.small)"))
        XCTAssertFalse(menu.contains("frame(width: 44, height: 44)"))
        XCTAssertTrue(today.contains(".sheet(item: $ringShareRoute)"))
        XCTAssertTrue(today.contains("AtriaShareSheet(snapshot: route.snapshot)"))

        let share = try source("AtriaShareCard.swift")
        let previewStart = try XCTUnwrap(share.range(of: "struct AtriaShareSheet: View"))
        let previewEnd = try XCTUnwrap(share.range(of: "struct AtriaWorkoutShareSheet: View",
                                                   range: previewStart.upperBound..<share.endIndex))
        let preview = String(share[previewStart.lowerBound..<previewEnd.lowerBound])
        XCTAssertTrue(preview.contains("private var topControls"))
        XCTAssertTrue(preview.contains("GlassEffectContainer(spacing: 12)"))
        XCTAssertTrue(preview.contains("Button { dismiss() } label:"))
        XCTAssertTrue(preview.contains("shareCornerButton(systemImage: \"xmark\")"))
        XCTAssertFalse(preview.contains("saveShareCardToPhotos"))
        XCTAssertTrue(preview.contains("shareCornerButton(systemImage: \"square.and.arrow.up\")"))
        XCTAssertFalse(preview.contains("ToolbarItem"),
                       "Toolbar context plus a custom glass label creates the nested double-circle chrome")
        XCTAssertTrue(preview.contains("AtriaGlassIconButtonStyle(tint: .white, size: 38)"))
        XCTAssertTrue(preview.contains("PhotosPicker(selection: $selectedPhotoItem"))
        XCTAssertTrue(preview.contains("canvasButtonLabel(title: \"Camera\""))
        XCTAssertTrue(preview.contains("ForEach(AtriaShareCanvasStyle.allCases)"))
        XCTAssertTrue(preview.contains("AtriaShareComposerLayout.fittedStorySize(in: size)"),
                      "The preview must fit the complete 9:16 canvas instead of cropping it")
        XCTAssertTrue(preview.contains("controlDock\n                .frame(height: AtriaShareComposerLayout.styleRailHeight)"),
                      "The style rail must be a sibling below the card, not an overlay covering it")
        XCTAssertTrue(share.contains("case .story: return CGSize(width: 1080, height: 1920)"))
    }

    func testShareExportDebouncesStyleChangesAndKeepsEncodingOffMainActor() throws {
        let share = try source("AtriaShareCard.swift")

        XCTAssertEqual(share.components(separatedBy: "Task.sleep(for: .milliseconds(120))").count - 1, 3)
        XCTAssertTrue(share.contains("private struct SendableCGImage: @unchecked Sendable"))
        XCTAssertTrue(share.contains("nonisolated private static func encodePNGForExport"))
        XCTAssertTrue(share.contains("Task.detached(priority: .utility)"))
        XCTAssertTrue(share.contains("renderedImageURL: photoBackground == nil ? renderedURL : nil"),
                      "Portable workout recap should reuse the already-rendered story image")
    }

    func testCustomizeCommitsOnceWithSaveAndDoesNotInventUnavailableVitals() throws {
        let source = try source("AtriaCustomizeSheet.swift")

        XCTAssertTrue(source.contains("Button(\"Save\")"))
        XCTAssertFalse(source.contains("Button(\"Done\")"))
        XCTAssertTrue(source.contains("case .bloodOxygen, .bodyTemp: return \"--\""))
        XCTAssertFalse(source.contains("case .bloodOxygen: return \"98%\""))
        XCTAssertFalse(source.contains("case .bodyTemp: return \"+0.1\""))
    }
}
