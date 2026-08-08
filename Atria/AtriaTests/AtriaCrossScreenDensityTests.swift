import XCTest

final class AtriaCrossScreenDensityTests: XCTestCase {
    private func source(_ relativePath: String) throws -> String {
        let testsURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let appURL = testsURL.deletingLastPathComponent().appendingPathComponent("Atria")
        return try String(contentsOf: appURL.appendingPathComponent(relativePath), encoding: .utf8)
    }

    func testPrimaryDailyTabUsesTodayLanguageAndKeepsLegacyDeepLinks() throws {
        let source = try source("AtriaHomeView.swift")
        let tabStart = try XCTUnwrap(source.range(of: "private enum HomeTab"))
        let tabEnd = try XCTUnwrap(source.range(of: "fileprivate enum WorkoutReviewHoldState",
                                                range: tabStart.upperBound..<source.endIndex))
        let tabs = String(source[tabStart.lowerBound..<tabEnd.lowerBound])

        XCTAssertTrue(tabs.contains("case .overview: return \"Today\""))
        XCTAssertTrue(tabs.contains("case \"overview\", \"today\": return .overview"),
                      "Renaming the visible tab must not break existing overview links")
    }

    func testTrendAdviceRequiresQualifiedCurrentAndPriorSamplesForEveryInput() throws {
        let source = try source("AtriaTrendChart.swift")

        XCTAssertTrue(source.contains("periodReadout.hasCompleteComparison("))
        XCTAssertTrue(source.contains("minimumSamples: range.confidenceTargetPoints"))
        XCTAssertTrue(source.contains("$0.currentCount >= required"))
        XCTAssertTrue(source.contains("$0.previousCount >= required"))
        XCTAssertTrue(source.contains("currentCount: currentHRV.count"))
        XCTAssertTrue(source.contains("previousCount: priorStrain.count"))
    }

    func testTodayDailyBriefKeepsGuidanceVisibleAndCheckInActionable() throws {
        let source = try source("AtriaTodayScreen.swift")
        let planStart = try XCTUnwrap(source.range(of: "private struct AtriaTodayPlanCard"))
        let planEnd = try XCTUnwrap(source.range(of: "private struct AtriaStrainTargetCard", range: planStart.upperBound..<source.endIndex))
        let plan = String(source[planStart.lowerBound..<planEnd.lowerBound])

        XCTAssertTrue(plan.contains("Label(\"Daily brief\""))
        XCTAssertTrue(plan.contains("Text(detail)"))
        XCTAssertTrue(plan.contains(".buttonStyle(.glass)"))
        XCTAssertTrue(plan.contains("minHeight: 44"))
        XCTAssertTrue(plan.contains("checkIn.actionLabel"))

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
        XCTAssertTrue(source.contains("Text(allQuestionsAnswered ? \"Check-in done\" : \"Check-in paused\")"))
        XCTAssertTrue(source.contains("Text(allQuestionsAnswered ? \"Review answers\" : \"Answer skipped questions\")"))
        XCTAssertTrue(source.contains(".buttonStyle(.glass)"))
        XCTAssertFalse(source.contains("Log today to start your pattern — the full 90-day view builds as history grows."))
        // 2026-08-04: the "full 90-day pattern appears..." empty-state line was
        // retired with the 7x13 heat-strip redesign (ed4cdac8) — sparse days
        // read directly from the calendar cells now. Pin the surviving 90-day
        // honesty copy instead.
        XCTAssertFalse(source.contains("The full 90-day pattern appears as logging history grows."))
        XCTAssertTrue(source.contains("90-day association from logged dates; not a prediction."))
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

    // 2026-08-04: RETIRED — `AtriaVitalsEducationSheet` was removed by
    // b1509b30 (metric info buttons wired to the spec-§20 About sheets). The
    // successor content contracts live in AtriaAboutMetricSheetTests; this
    // density pin had been failing on a nonexistent anchor since then.
    func testVitalsEducationLeadsWithActionsInsteadOfThreeParagraphCards() throws {
        let source = try source("AtriaVitalsCollectionSections.swift")
        XCTAssertFalse(source.contains("struct AtriaVitalsEducationSheet"),
                       "education sheet was replaced by AtriaAboutMetricSheet (b1509b30); if it returns, restore the retired density pins from git history")
    }

    func testDeveloperReferenceChecksUseFlatReadableLiquidGlassHierarchy() throws {
        let source = try source("AtriaVitalsCollectionSections.swift")
        let rrStart = try XCTUnwrap(source.range(of: "private struct AtriaCollectionRRReferenceCardHost"))
        let hrStart = try XCTUnwrap(source.range(of: "private struct AtriaCollectionHRReferenceCardHost",
                                                 range: rrStart.upperBound..<source.endIndex))
        let actionStart = try XCTUnwrap(source.range(of: "private struct AtriaCollectionReferenceActionLabel",
                                                     range: hrStart.upperBound..<source.endIndex))
        let sensorCopyStart = try XCTUnwrap(source.range(of: "enum AtriaExperimentalSensorCopy",
                                                         range: actionStart.upperBound..<source.endIndex))
        let summaryStart = try XCTUnwrap(source.range(of: "private struct AtriaCollectionReferenceSummaryCard"))
        let summaryEnd = try XCTUnwrap(source.range(of: "private struct AtriaCollectionToggleCard",
                                                    range: summaryStart.upperBound..<source.endIndex))

        let rr = String(source[rrStart.lowerBound..<hrStart.lowerBound])
        let hr = String(source[hrStart.lowerBound..<actionStart.lowerBound])
        let action = String(source[actionStart.lowerBound..<sensorCopyStart.lowerBound])
        let summary = String(source[summaryStart.lowerBound..<summaryEnd.lowerBound])

        for card in [rr, hr] {
            XCTAssertTrue(card.contains("@Environment(\\.dynamicTypeSize) private var dynamicTypeSize"))
            XCTAssertTrue(card.contains("if dynamicTypeSize.isAccessibilitySize"),
                          "Reference controls should stack before Dynamic Type compresses their labels")
            XCTAssertTrue(card.contains(".buttonStyle(.glass)"))
            XCTAssertTrue(card.contains(".buttonBorderShape(.roundedRectangle(radius: 14))"))
            XCTAssertTrue(card.contains(".fixedSize(horizontal: false, vertical: true)"))
            XCTAssertFalse(card.contains(".minimumScaleFactor("),
                           "Developer action titles must never shrink to fit")
            XCTAssertFalse(card.contains(".atriaCardAction("),
                           "Reference cards should use one consistent native glass action treatment")
        }

        XCTAssertTrue(action.contains(".frame(width: 18)"),
                      "Every developer action should reserve the same icon slot")
        XCTAssertTrue(action.contains(".frame(maxWidth: .infinity, minHeight: 44)"))
        XCTAssertTrue(action.contains(".lineLimit(2)"))
        XCTAssertTrue(action.contains(".layoutPriority(1)"))

        XCTAssertTrue(summary.contains("Divider()"))
        XCTAssertTrue(summary.contains(".accessibilityElement(children: .combine)"))
        XCTAssertFalse(summary.contains("LazyVGrid"),
                       "Status belongs in plain rows, not nested adaptive tiles")
        XCTAssertFalse(summary.contains("AtriaMetricTile("),
                       "The quiet outer card should not contain another card-like metric surface")
        XCTAssertFalse(summary.contains("prefix(4)"),
                       "Developer status detail must remain complete rather than being word-truncated")
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
        XCTAssertTrue(timeline.contains("AtriaTextSelector(items: TimelineSignal.allCases"))
        XCTAssertTrue(timeline.contains("heartRateTimelineChart"))
        XCTAssertTrue(timeline.contains("stressTimelineChart"))
        XCTAssertTrue(timeline.contains("LineMark(x: .value(\"Time\", point.t)"))
        XCTAssertTrue(timeline.contains("timelinePlotOverlay"),
                      "The single activity-marker lane should share the monitor plot")
        XCTAssertTrue(timeline.contains("font(.system(size: 9"))
        XCTAssertTrue(timeline.contains(".accessibilityLabel(\"Heart rate and activity timeline\")"))
        XCTAssertTrue(timeline.contains(".accessibilityLabel(\"Stress and activity timeline\")"))
        XCTAssertTrue(timeline.contains(".frame(height: 154)"),
                      "Both honest empty states and measured traces keep a stable plot height")
        XCTAssertFalse(timeline.contains(".chartScrollableAxes"),
                       "The compact monitor should show one complete daily context before inspection")
        XCTAssertFalse(timeline.contains("Previous day"), "Day controls belong in the single toolbar, not another stacked row")
        XCTAssertFalse(source.contains("detection.kind == .workout ? \"figure.run\""))
        XCTAssertFalse(source.contains("$0.kind == .workout ? \"figure.run\""))
        XCTAssertTrue(source.contains("icon: kind == .workout ? \"figure.mixed.cardio\" : \"waveform.path.ecg\""),
                      "unclassified detections must use a neutral activity icon")
        XCTAssertTrue(source.contains("if let suggestedActivityType"),
                      "a specific icon may appear only when classifier evidence supplies a type hint")
        XCTAssertTrue(source.contains("AtriaActivityTimelineMarkerProjection.nonOverlappingSlices"))
        XCTAssertTrue(source.contains("lane: \"activity\""),
                      "Sleep, workout, and review markers must share one non-overlapping lane")
    }

    func testOnboardingConnectionCardKeepsGuidanceVisibleAndAvailableToVoiceOver() throws {
        let source = try source("ContentView.swift")
        let start = try XCTUnwrap(source.range(of: "struct OnboardingConnectionStatusView"))
        let end = try XCTUnwrap(source.range(of: "extension View", range: start.upperBound..<source.endIndex))
        let card = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(card.contains("Text(subtitle)"))
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
        XCTAssertTrue(todaySource.contains("accessibilityLabel(isEditingGlance ? \"Finish editing At a glance\" : \"Edit At a glance\")"))
        XCTAssertTrue(todaySource.contains("accessibilityHint(\"Lets you drag cards to reorder and remove cards.\")"),
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

    func testDashboardHasOnlyOneLazyVerticalContentOwner() throws {
        let home = try source("AtriaHomeView.swift")
        let navigationStart = try XCTUnwrap(
            home.range(of: "private func tabNavigation<Content: View>")
        )
        let navigationEnd = try XCTUnwrap(
            home.range(
                of: "private var scrollBottomClearance",
                range: navigationStart.upperBound..<home.endIndex
            )
        )
        let navigation = String(
            home[navigationStart.lowerBound..<navigationEnd.lowerBound]
        )
        let today = try source("AtriaTodayScreen.swift")

        XCTAssertTrue(navigation.contains("VStack(spacing: 18)"))
        XCTAssertFalse(
            navigation.contains("LazyVStack(spacing: 18)"),
            "The scroll shell must not wrap screen-owned lazy content in a second LazyVStack; nested lazy layout made below-fold Strap steps unreachable on a physical iPhone."
        )
        XCTAssertTrue(
            today.contains("VStack(spacing: 16)"),
            "Today's bounded section list must publish its full content height so the physical scroll reaches Strap steps."
        )
        XCTAssertFalse(
            today.contains("LazyVStack(spacing: 16)"),
            "A lazy Today root can truncate the device scroll surface before below-fold cards."
        )
    }

    func testCompactRingUsesRequestedEmojiAndNumberVocabulary() throws {
        let ring = try source("AtriaTriRing.swift")

        for emoji in ["🌙", "❤️", "🔥", "📈", "💓"] {
            XCTAssertTrue(ring.contains("return \"\(emoji)\""))
        }
    }

    /// 2026-08-08 field report: "Sleep and strain rings are grey in 3 ring view
    /// and does not show at all in concentric rings." Both layouts must render
    /// an awaiting-data metric as a clearly present, dashed ring — one state,
    /// one story, and never a fabricated arc.
    func testAwaitingDataRingIsVisiblyPresentInBothLayouts() throws {
        let concentric = try source("AtriaTriRing.swift")
        XCTAssertTrue(concentric.contains("if metric.fill == nil {"),
                      "the concentric hero must special-case an unavailable metric")
        XCTAssertTrue(concentric.contains("dash: [2, lineWidth * 1.4]"),
                      "an unavailable concentric ring reads as dashed-awaiting, not absent")
        XCTAssertFalse(concentric.contains("metric.tint.opacity(0.20), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))\n\n            if metric.fill != nil"),
                       "the near-invisible ghost track must not be the unavailable state")

        let separate = try source("AtriaMetricRing.swift")
        XCTAssertTrue(separate.contains("if fraction == nil {"),
                      "the separate layout must special-case an unavailable metric")
        XCTAssertTrue(separate.contains("dash: [2, lineWidth * 1.4]"),
                      "both layouts share the awaiting-data treatment")
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
        let advancedStart = try XCTUnwrap(source.range(of: "private struct AtriaAdvancedTargetsSettingsView"))
        let advanced = String(source[advancedStart.lowerBound...])
        let headerStart = try XCTUnwrap(advanced.range(of: "private func targetGroupHeader"))
        let menuStart = try XCTUnwrap(advanced.range(of: "private func targetGroupResetMenu",
                                                     range: headerStart.upperBound..<advanced.endIndex))
        let header = String(advanced[headerStart.lowerBound..<menuStart.lowerBound])
        XCTAssertFalse(header.contains("Menu {"),
                       "DisclosureGroup labels must remain noninteractive content")
        XCTAssertEqual(advanced.components(separatedBy: ".overlay(alignment: .topTrailing)").count - 1,
                       9,
                       "Every advanced target group should expose one sibling reset menu")
        XCTAssertEqual(advanced.components(separatedBy: ".padding(.trailing, 48)").count - 1,
                       9,
                       "Disclosure indicators must reserve space beside the reset hit target")
        XCTAssertTrue(advanced.contains(".frame(width: 44, height: 44)"),
                      "The sibling reset menu needs a native accessible hit target")
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
        XCTAssertTrue(menu.contains(".frame(width: 44, height: 44)"),
                      "Compact glass visuals still need native 44-point hit targets")
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

    func testRingTargetsStayConfiguredAcrossTodayOverviewAndShare() throws {
        let today = try source("AtriaTodayScreen.swift")
        for key in [
            "atria.target.recovery.greenLower",
            "atria.target.recovery.yellowLower",
            "atria.target.strain.greenBand",
            "atria.target.strain.yellowBand",
        ] {
            XCTAssertTrue(today.contains(key))
        }
        XCTAssertTrue(today.contains("tint: ringRecoveryZone?.tint ?? .secondary"))
        XCTAssertTrue(today.contains("stateTint: incomplete || pending ? nil : ringStrainZone(target: target)?.tint"))
        XCTAssertFalse(today.contains("AtriaTriRing.zoneTint(.recovery"))
        XCTAssertFalse(today.contains("AtriaTriRing.zoneTint(.strain"))

        let overview = try source("AtriaOverviewSections.swift")
        XCTAssertTrue(overview.contains("switch recoveryZone?.level"))
        XCTAssertTrue(overview.contains("let unqualified = pending || strainIsPartial"))
        XCTAssertTrue(overview.contains("stateTint: unqualified ? nil : qualifiedStrainZone?.tint"),
                      "pending or partial strain must not receive a confident target-zone tint")
        XCTAssertFalse(overview.contains("hero.guidance.target ?? 21"))

        let home = try source("AtriaHomeView.swift")
        XCTAssertFalse(home.contains("switch recoveryPercent ?? 50"))
        XCTAssertTrue(home.contains("AtriaRingMetricProjection.strainFill(strain: hero.strain"))

        let share = try source("AtriaShareCard.swift")
        XCTAssertTrue(share.contains("let stateTintHex: String?"))
        XCTAssertTrue(share.contains("let targetFraction: Double?"))
        XCTAssertTrue(share.contains("if let targetFraction = ring.targetFraction"))
    }

    func testShareExportRunsOnlyFromAnActionAndRejectsStaleResults() throws {
        let share = try source("AtriaShareCard.swift")

        XCTAssertFalse(share.contains(".task(id: renderKey)"),
                       "A live preview change must not schedule a full-size export")
        XCTAssertFalse(share.contains("Task.sleep(for: .milliseconds(120))"),
                       "Debouncing eager export still performs avoidable work")
        XCTAssertEqual(share.components(separatedBy: ".sheet(item: $sharePayload)").count - 1, 3)
        XCTAssertTrue(share.contains("private func prepareShare()"))
        XCTAssertTrue(share.contains("private func prepareShare(_ kind: ExportKind)"))
        XCTAssertTrue(share.contains("private func prepareWeeklyShare()"))
        XCTAssertTrue(share.contains("renderKey == requestedRenderKey"),
                      "An export must match the exact preview generation requested by the user")
        XCTAssertTrue(share.contains("exportTask?.cancel()"))
        XCTAssertTrue(share.contains("private struct AtriaSystemShareSheet"))
        XCTAssertTrue(share.contains("ProgressView()"),
                      "Share needs an honest preparing state while the image is rendered")
        XCTAssertFalse(share.contains("@State private var shareURL"),
                       "A previously rendered URL must not survive later style/photo changes")
        XCTAssertEqual(share.components(separatedBy:
            "photoBackground == nil ? \"canvas\" : UUID().uuidString").count - 1,
                       2,
                       "Daily and workout photo exports need unique files so canceled writes cannot overwrite a newer share")
        XCTAssertTrue(share.contains("static func dailyCacheKey(snapshot:"))
        XCTAssertTrue(share.contains("static func weeklyCacheKey(snapshot:"))
        XCTAssertTrue(share.contains("return \"daily-\\(stableDigest(content))\""))
        XCTAssertTrue(share.contains("return \"weekly-\\(stableDigest(content))\""))
        XCTAssertTrue(share.contains("private struct SendableCGImage: @unchecked Sendable"))
        XCTAssertTrue(share.contains("nonisolated private static func encodePNGForExport"))
        XCTAssertTrue(share.contains("Task.detached(priority: .utility)"))
        XCTAssertTrue(share.contains("renderedImageURL: imageURL"),
                      "Portable workout recap should preserve and reuse the exact rendered preview")
        let portableStart = try XCTUnwrap(share.range(of: "static func renderPortableWorkoutURL"))
        let portableEnd = try XCTUnwrap(share.range(of: "static func portableWorkoutHTML",
                                                    range: portableStart.upperBound..<share.endIndex))
        let portableRenderer = String(share[portableStart.lowerBound..<portableEnd.lowerBound])
        XCTAssertFalse(portableRenderer.contains("renderPNGDataForExport"),
                       "Portable recap must embed the already-rendered preview instead of rendering twice")
        XCTAssertTrue(share.contains("removeRenderedImageAfterEmbedding: requestedPhotoBackground != nil"))
        XCTAssertTrue(share.contains("cameraPreparationTask?.cancel()"))
        XCTAssertTrue(share.contains("AtriaSharePhotoPreparation.acceptsResult("),
                      "A late camera result must match both its generation and render key")
        XCTAssertTrue(share.contains("completionWithItemsHandler"))
        XCTAssertTrue(share.contains("releaseTemporaryExport(at: payload.url)"))
        XCTAssertTrue(share.contains(".completeFileProtection"))
        XCTAssertTrue(share.contains("FileProtectionType.completeUnlessOpen"))
        XCTAssertTrue(share.contains("private static let cacheCapacity = 24"))
        XCTAssertTrue(share.contains("while cacheRecency.count > cacheCapacity"))
        XCTAssertTrue(share.contains("await removeExportFile(evictedURL)"))
        XCTAssertTrue(share.contains("withTaskCancellationHandler"))
        XCTAssertTrue(share.contains("route-absent"))
        XCTAssertTrue(share.contains("route-present"))
    }

    func testSyncNoticeUsesNativeGlassPagingWithCompactHeight() throws {
        let home = try source("AtriaHomeView.swift")
        let start = try XCTUnwrap(home.range(
            of: "private struct AtriaHomeRecoveryStatusHost: View {"
        ))
        let end = try XCTUnwrap(home.range(
            of: "static func rotationIndex(", range: start.upperBound..<home.endIndex
        ))
        let host = String(home[start.lowerBound..<end.lowerBound])

        // Native Liquid Glass surface with a horizontally paged card for each
        // currently relevant notice.
        XCTAssertTrue(host.contains("GlassEffectContainer(spacing: 10)"))
        XCTAssertTrue(host.contains("ScrollView(.horizontal, showsIndicators: false)"))
        XCTAssertTrue(host.contains(".scrollTargetBehavior(.paging)"))
        XCTAssertTrue(host.contains(".glassEffect(.regular, in: .rect(cornerRadius: 18))"))
        XCTAssertTrue(host.contains(".frame(height: 40)"))
        XCTAssertTrue(host.contains(".foregroundStyle(.primary)"))

        // The negative bottom padding existed only to close the void the
        // floating card opened above the greeting; edge-to-edge ends flush.
        XCTAssertFalse(host.contains(".padding(.bottom, -12)"))
    }

    func testCustomizeCommitsOnceWithSaveAndDoesNotInventUnavailableVitals() throws {
        let source = try source("AtriaCustomizeSheet.swift")

        XCTAssertTrue(source.contains("Button(\"Save\")"))
        XCTAssertFalse(source.contains("Button(\"Done\")"))
        XCTAssertTrue(source.contains("case .bloodOxygen, .bodyTemp: return \"--\""))
        XCTAssertFalse(source.contains("case .bloodOxygen: return \"98%\""))
        XCTAssertFalse(source.contains("case .bodyTemp: return \"+0.1\""))
    }

    func testTodayDistinguishesSettledMorningHRVFromLivePersonalHRV() throws {
        let source = try source("AtriaTodayScreen.swift")
        let start = try XCTUnwrap(source.range(of: "case .hrv:"))
        let end = try XCTUnwrap(
            source.range(of: "case .stress:", range: start.upperBound..<source.endIndex)
        )
        let hrvCard = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(hrvCard.contains("title: \"Morning HRV\""))
        XCTAssertTrue(hrvCard.contains("value: displaySettledHRV.value"))
        XCTAssertTrue(hrvCard.contains("detail: legendDetail(displaySettledHRV.detail)"))
    }
}
