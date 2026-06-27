#!/usr/bin/env python3
import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent
APP_ROOTS = [ROOT / "Atria" / "Atria", ROOT / "Atria" / "AtriaWidget"]


def swift_files():
    for root in APP_ROOTS:
        yield from root.rglob("*.swift")


def source(path):
    return path.read_text(encoding="utf-8")


def all_swift_source():
    return "\n".join(source(path) for path in swift_files())


def swift_braced_blocks(text, patterns):
    blocks = []
    matches = []
    for pattern in patterns:
        matches.extend(re.finditer(pattern, text))
    for match in sorted(matches, key=lambda item: item.start()):
        index = match.start()
        brace = text.find("{", index)
        if brace == -1:
            continue
        depth = 0
        for pos in range(brace, len(text)):
            char = text[pos]
            if char == "{":
                depth += 1
            elif char == "}":
                depth -= 1
                if depth == 0:
                    blocks.append((index, text[index:pos + 1]))
                    break
    return blocks


def swift_var_body_blocks(text):
    return swift_braced_blocks(text, [r"\bvar\s+body\s*:\s*some\s+View\b"])


def swift_some_view_blocks(text):
    return swift_braced_blocks(text, [
        r"\bvar\s+\w+\s*:\s*some\s+View\b",
        r"\bfunc\s+\w+\s*\([^)]*\)\s*->\s*some\s+View\b",
    ])


def assert_contains(testcase, haystack, needle):
    testcase.assertTrue(needle in haystack, f"missing required source token: {needle}")


def assert_not_contains(testcase, haystack, needle):
    testcase.assertFalse(needle in haystack, f"forbidden source token present: {needle}")


class HandoffStaticChecks(unittest.TestCase):
    def test_ios_26_ui_has_no_legacy_availability_or_material_fallbacks(self):
        text = all_swift_source()

        forbidden = [
            "#available",
            "ultraThinMaterial",
            "thinMaterial",
            "regularMaterial",
            "thickMaterial",
            ".blur(",
            "LegacyContentView",
            "DashboardSection",
            "AtriaGlassToolbar",
            "RecoveryRing",
            "StrainGauge",
            "atriaGlassPanel",
            "atriaQuietPanel",
        ]
        for needle in forbidden:
            assert_not_contains(self, text, needle)

        assert_not_contains(self, text, "ViewThatFits")

        for needle in [
            "TabView(selection:",
            ".tabItem { Label(HomeTab.overview.title, systemImage: HomeTab.overview.systemImage) }",
            ".tabItem { Label(HomeTab.vitals.title, systemImage: HomeTab.vitals.systemImage) }",
            ".tabItem { Label(HomeTab.collection.title, systemImage: HomeTab.collection.systemImage) }",
            ".tabBarMinimizeBehavior(.onScrollDown)",
            ".tabViewBottomAccessory",
            ".scrollEdgeEffectStyle(.soft, for: .top)",
            "enum AtriaDesignTokens",
            "func atriaCard(",
            "func atriaRaisedCard(",
            "struct AtriaSegmentButtonStyle: ButtonStyle",
            "struct AtriaCardActionButtonStyle: ButtonStyle",
            "var tint: Color = .blue",
            "func atriaGlassSelectable(selected: Bool, tint: Color = .blue) -> some View",
            "self.buttonStyle(AtriaSegmentButtonStyle(selected: selected, tint: tint))",
            "func atriaCardAction(prominent: Bool = true, tint: Color = .blue) -> some View",
            "self.buttonStyle(AtriaCardActionButtonStyle(prominent: prominent, tint: tint))",
        ]:
            assert_contains(self, text, needle)

        content = source(ROOT / "Atria" / "Atria" / "ContentView.swift")
        overview = source(ROOT / "Atria" / "Atria" / "AtriaOverviewSections.swift")
        vitals = source(ROOT / "Atria" / "Atria" / "AtriaVitalsCollectionSections.swift")
        settings = source(ROOT / "Atria" / "Atria" / "AtriaSettingsView.swift")
        assert_not_contains(self, content, "self.buttonStyle(.glassProminent).tint(tint)")
        assert_not_contains(self, content, "self.buttonStyle(.glass)\n        }")
        for scroll_surface in [overview, vitals, settings]:
            assert_not_contains(self, scroll_surface, "GlassEffectContainer")
        assert_not_contains(self, text, ".fill(baseFill)\n            .glassEffect")
        assert_not_contains(self, text, "Tab(\"Today\"")
        assert_not_contains(self, text, "Tab(\"Vitals\"")
        assert_not_contains(self, text, "Tab(\"Data\"")

    def test_project_declares_complete_ipad_orientations_without_forcing_iphone_fullscreen(self):
        project = source(ROOT / "Atria" / "Atria.xcodeproj" / "project.pbxproj")

        iphone_orientations = (
            'INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone = '
            '"UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight";'
        )
        ipad_orientations = (
            'INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad = '
            '"UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight";'
        )
        self.assertEqual(project.count(iphone_orientations), 2)
        self.assertEqual(project.count(ipad_orientations), 2)
        assert_not_contains(self, project, "INFOPLIST_KEY_UIRequiresFullScreen")

    def test_top_left_status_restores_original_chip_and_labels(self):
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")

        for needle in [
            "private struct AtriaHomeTopChrome: View",
            "AtriaHomeTopChrome(statusStore: model.statusStore",
            ".toolbar(.hidden, for: .navigationBar)",
            "private static func liveHeartRate(ble: AtriaBLEManager) -> Int",
            "Date().timeIntervalSince(latest.t) <= 75",
            ".onTapGesture",
            "ble.startScan(reason: \"home_status_chip\")",
            "var hasPulseSignal: Bool { heartRate > 0 || hasContact }",
            "var sensorHasContact: Bool",
            "sensorHasContact: ble.hasContact",
            "var needsContactCoach: Bool { !hasPulseSignal && !sensorHasContact }",
            "var contactText: String { hasPulseSignal ? \"Live\" : \"No signal\" }",
            "hasContact: ble.hasContact || reconciledHeartRate > 0",
            "return hasPulseSignal ? \"Live\" : \"No signal\"",
            "case .connecting: return \"Connecting\"",
            "case .scanning: return \"Searching\"",
            "case .poweredOff: return \"Bluetooth off\"",
            "? \"Reconnecting…\"",
            ": \"Disconnected\"",
            "case .connected: return hasPulseSignal ? .green : .orange",
            "case .connecting: return .yellow",
            "case .scanning: return .cyan",
            "case .poweredOff: return .red",
            "case .disconnected: return .blue",
            "HStack(spacing: 5)",
            "private struct AtriaToolbarIcon: View, Equatable",
            "private static let visualSize: CGFloat = 34",
            "private static let hitSize: CGFloat = 44",
            "AtriaToolbarIcon(symbol: \"figure.run\")",
            "AtriaToolbarIcon(symbol: \"questionmark.circle\")",
            "AtriaToolbarIcon(symbol: \"clock.arrow.circlepath\")",
            "AtriaToolbarIcon(symbol: \"gearshape\")",
            ".frame(width: Self.visualSize, height: Self.visualSize)",
            ".frame(width: Self.hitSize, height: Self.hitSize)",
            ".contentShape(Rectangle())",
            "HStack(spacing: 0)",
            ".fill(colorScheme == .dark ? Color.white.opacity(0.08) : Color.white.opacity(0.84))",
            "self.publishHeroPulse()\n                if self.prefersPulseSparklineUpdates",
            "Capsule()\n                .fill(tint.opacity(colorScheme == .light ? 0.28 : 0.22))",
            ".frame(minWidth: 132, minHeight: 44)",
        ]:
            assert_contains(self, home, needle)

        for forbidden in [
            "ToolbarItem(placement: .topBarLeading)",
            "ToolbarItem(placement: .topBarTrailing)",
            "ble.startScan(reason: \"home_status_button\")",
            "case .connected: return \"Live/Connected\"",
            "case .connecting, .scanning: return \"Connecting...\"",
            "case .poweredOff, .disconnected: return \"Not Connected\"",
            ".buttonStyle(.glass)\n            .buttonBorderShape(.circle)",
            ".glassEffect(.regular.tint(tint.opacity(0.55)).interactive(), in: .capsule)",
            ".glassEffect(.regular.interactive(), in: .circle)",
            ".atriaChromeCapsule(tint: .white)\n            .fixedSize()",
            "private struct AtriaLiquidStatusPillBackground",
            "private var baseFill: AnyShapeStyle",
            "private var liquidWash: LinearGradient",
            "case .connected where !pulse.hasContact:",
            "guard let self, self.prefersPulseSparklineUpdates else { return }\n                self.publishPulseLive()",
        ]:
            assert_not_contains(self, home, forbidden)

        shared_ui = source(ROOT / "Atria" / "Atria" / "AtriaSharedUIComponents.swift")
        assert_contains(self, shared_ui, "case .noContact:\n            return \"No signal\"")
        assert_not_contains(self, shared_ui, "return \"No contact\"")

    def test_state_pull_detects_official_whoop_widget_name(self):
        pull_script = source(ROOT / "pull_atria_state.sh")

        for needle in [
            "WhoopWidgetExtension",
            "whoop_widget_pattern=",
            "official_whoop_widget_process=1",
            "official_whoop_coexistence_risk=1",
            "copy_first_from_container",
            "Documents/atria-historical/historical-archive.jsonl",
            "Documents/whoop-historical/historical-archive.jsonl",
            "offline_sync_namespace=",
            "pref(prefs, 'offlineSync.lastStatus'",
            "link_namespace=",
        ]:
            assert_contains(self, pull_script, needle)

    def test_heart_rate_timeline_has_axes_and_fullscreen_explorer(self):
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")
        vitals = source(ROOT / "Atria" / "Atria" / "AtriaVitalsCollectionSections.swift")
        shared = source(ROOT / "Atria" / "Atria" / "AtriaSharedUIComponents.swift")
        hero = source(ROOT / "Atria" / "Atria" / "AtriaHeroConnectionSections.swift")

        for needle in [
            "struct HeartRateChartPoint: Identifiable, Equatable",
            "chartPoints: compactHeartChartPoints(Array(ble.session.suffix(900)))",
            "private static func compactHeartChartPoints(_ samples: [HRSample], targetCount: Int = 120)",
            "private struct AtriaHeartRateTimelineCard: View, Equatable",
            "Text(\"Heart-rate timeline\")",
            "Text(\"Tap to inspect\")",
            "Label(\"Time\", systemImage: \"clock\")",
            "Label(\"BPM\", systemImage: \"heart\")",
            "private struct AtriaHeartRateExplorer: View",
            "@Environment(\\.colorScheme) private var colorScheme",
            "@Environment(\\.accessibilityReduceTransparency) private var reduceTransparency",
            "Tap or drag on the graph to inspect any sample.",
            "AtriaBackdropLayer(isDark: colorScheme == .dark,",
            "reduceTransparency: reduceTransparency",
            "private struct AtriaHeartRateAxisChart: View, Equatable",
            ".chartXAxis",
            ".chartYAxis",
            ".chartXSelection(value: $selectedTime)",
            "Slider(value: $zoom, in: 1...6, step: 1)",
            ".fullScreenCover(isPresented: $showHeartRateExplorer)",
            "live.hasPulseSignal",
        ]:
            assert_contains(self, home + vitals, needle)

        assert_contains(self, shared, "case conflict")
        assert_contains(self, shared, 'return "App conflict"')
        assert_contains(self, vitals, "officialAppCoexistenceRisk == .suspected ? .conflict : .local")
        assert_contains(self, hero, "let hasPulseSignal: Bool")
        assert_contains(self, hero, "let needsContactCoach: Bool")
        assert_contains(self, hero, 'AtriaHeroStatusTile(title: needsContactCoach ? "Fit check needed" : "Connected, no pulse"')
        assert_contains(self, hero, "Strap is connected; tighten fit or wet the sensor for a stable reading.")
        assert_contains(self, hero, "Waiting for the next live heart-rate sample.")
        assert_contains(self, hero, "needsContactCoach: pulseStore.state.needsContactCoach")
        assert_contains(self, home, "struct HeroPulseState: Equatable")
        assert_contains(self, home, "var hasPulseSignal: Bool { heartRate > 0 || hasContact }")
        assert_contains(self, home, "return HeroPulseState(heartRate: reconciledHeartRate,")
        assert_not_contains(self, vitals, "isConnected && live.hasPulseSignal")

    def test_settings_appearance_switcher_uses_shared_scroll_safe_chrome(self):
        settings = source(ROOT / "Atria" / "Atria" / "AtriaSettingsView.swift")
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")

        for needle in [
            "@AppStorage(\"atriaAppearanceMode\") private var appearanceMode = \"system\"",
            "appearanceButton(\"System\", mode: \"system\", icon: \"circle.lefthalf.filled\")",
            "appearanceButton(\"Light\", mode: \"light\", icon: \"sun.max.fill\")",
            "appearanceButton(\"Dark\", mode: \"dark\", icon: \"moon.fill\")",
            "HStack(spacing: 8)",
            ".atriaInsetCard(tint: .purple)",
            ".buttonStyle(AtriaSegmentButtonStyle(selected: isAppearanceModeSelected(mode), tint: .purple))",
            ".atriaCardAction(prominent: false, tint: .secondary)",
            "private func isAppearanceModeSelected(_ mode: String) -> Bool",
        ]:
            assert_contains(self, settings, needle)

        for needle in [
            "@AppStorage(\"atriaAppearanceMode\") private var appearanceMode = \"system\"",
            "@State private var showSettings = false",
            "arguments.contains(\"--atria-open-settings\")",
            "requestedScreen = \"settings\"",
            "didApplyDebugUIScreenLaunchArgument = true",
            "case \"settings\":\n            selectedTab = .overview",
            "for delay in [100, 450, 900]",
            "showSettings = false\n                    await Task.yield()\n                    showSettings = true",
            ".preferredColorScheme(preferredColorScheme)",
            "case \"light\": return .light",
            "case \"dark\": return .dark",
            "default: return nil",
        ]:
            assert_contains(self, home, needle)

    def test_handoff_21_customizable_layout_is_persisted_and_reorderable(self):
        overview = source(ROOT / "Atria" / "Atria" / "AtriaOverviewSections.swift")
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")
        settings = source(ROOT / "Atria" / "Atria" / "AtriaSettingsView.swift")
        vitals = source(ROOT / "Atria" / "Atria" / "AtriaVitalsCollectionSections.swift")

        for needle in [
            "static let orderStorageKey = \"atria.overview.glanceOrderCSV\"",
            "static var defaultGlanceOrder: [AtriaTodayMetric]",
            "static func visibleOrdered(orderCSV: String, hiddenCSV: String) -> [AtriaTodayMetric]",
            "static func moving(_ dragged: AtriaTodayMetric, before target: AtriaTodayMetric, in csv: String) -> String",
            "fileprivate struct AtriaGlanceGridSize: Equatable",
            "static let compact = AtriaGlanceGridSize(rows: 1, columns: 1)",
            "static let wide = AtriaGlanceGridSize(rows: 1, columns: 2)",
            "var isWide: Bool { columns == 2 }",
            "var isValidGlanceShape: Bool",
            "rows == 1 && (columns == 1 || columns == 2)",
            "fileprivate var glanceGridSize: AtriaGlanceGridSize",
            "case .sleepHistory, .trend, .insights:\n            return .wide",
            "var glanceColumnSpan: Int { glanceGridSize.columns }",
            "fileprivate var isWideGlanceCard: Bool { glanceGridSize.isWide }",
            "private static let glanceGridSpacing: CGFloat = 10",
            "private static let glanceGridColumnCount = 2",
            "private static let glanceRowHeight = AtriaGlanceMetricCard.cardHeight",
            "VStack(spacing: Self.glanceGridSpacing)",
            ".frame(maxWidth: .infinity)",
            "ForEach(glanceRows, id: \\.glanceRowID)",
            "HStack(spacing: Self.glanceGridSpacing)",
            "minHeight: Self.glanceRowHeight",
            "maxHeight: Self.glanceRowHeight",
            "private func glanceRowContent(_ row: [AtriaTodayMetric]) -> some View",
            ".layoutPriority(metric.isWideGlanceCard ? 2 : 1)",
            "GeometryReader { proxy in",
            "private func glanceCardCell(_ metric: AtriaTodayMetric, width: CGFloat) -> some View",
            "private func glanceCardWidth(for metric: AtriaTodayMetric, containerWidth: CGFloat) -> CGFloat",
            "let columnWidth = (containerWidth - Self.glanceGridSpacing) / CGFloat(Self.glanceGridColumnCount)",
            "glanceCardCell(metric,\n                                   width: glanceCardWidth(for: metric, containerWidth: proxy.size.width))",
            "private struct AtriaGlanceMetricCard: View, Equatable",
            "static let cardHeight: CGFloat = 154",
            "private static let headerHeight: CGFloat = 44",
            "private static let valueHeight: CGFloat = 38",
            "private struct AtriaGlanceMetricMarker: View, Equatable",
            "private static let size: CGFloat = 44",
            "private static let iconCircleSize: CGFloat = 30",
            "private static let iconSize: CGFloat = 15",
            "private static let footerHeight: CGFloat = 34",
            "private static let ringLineWidth: CGFloat = 3.5",
            "static var placeholder: some View",
            "private var hasProgressSignal: Bool",
            "title == \"Recovery\" || title == \"Strain\"",
            "private var clampedRingFraction: Double?",
            "AtriaGlanceMetricMarker(systemImage: systemImage,",
            "precondition(metric.glanceGridSize.isValidGlanceShape, \"Today glance cards must be 1x1 or 1x2.\")",
            "precondition(rowFitsGlanceGrid(row), \"Today glance row exceeds the fixed two-column grid.\")",
            "private func rowFitsGlanceGrid(_ row: [AtriaTodayMetric]) -> Bool",
            "if row.count == 1, row.first?.isWideGlanceCard == false",
            "AtriaGlanceMetricCard.placeholder",
            "if metric.isWideGlanceCard",
            ".frame(maxWidth: .infinity, minHeight: Self.cardHeight, maxHeight: Self.cardHeight, alignment: .leading)",
            ".frame(width: Self.size, height: Self.size)",
            "private var ringEnd: Double",
            "progressFraction == nil ? 1 : clampedProgress",
            "private var ringOpacity: Double",
            "progressFraction == nil ? 0.38 : 1",
            "private var markerRing: some View",
            "StrokeStyle(lineWidth: Self.ringLineWidth, lineCap: .round)",
            "case .recovery: return \"gauge.with.dots.needle.67percent\"",
            "case .strain: return \"figure.run\"",
            "case .workout: return \"stopwatch.fill\"",
            "case .backfill: return \"arrow.triangle.2.circlepath\"",
            "case .hrv: return \"waveform.path.ecg\"",
            "case .sleep: return \"bed.double.fill\"",
            "case .sleepHistory: return \"moon.zzz.fill\"",
            "case .sleepEfficiency: return \"percent\"",
            "case .rhr: return \"heart.fill\"",
            "case .respiratoryRate: return \"lungs\"",
            "case .steps: return \"shoeprints.fill\"",
            "case .strapSteps: return \"figure.walk.motion\"",
            "case .calories: return \"flame.fill\"",
            "case .vo2max: return \"lungs.fill\"",
            "case .bloodOxygen: return \"drop.degreesign\"",
            "case .bodyTemp: return \"thermometer.variable\"",
            "case .insights: return \"sparkles\"",
            "[.recovery, .strain, .workout, .backfill, .hrv, .sleep, .sleepHistory, .sleepEfficiency, .rhr, .respiratoryRate, .steps, .strapSteps, .calories, .vo2max, .bloodOxygen, .bodyTemp, .trend, .insights]",
            "let profileMetricsStore: AtriaHomeModel.ProfileMetricsStore",
            "@ObservedObject var profileMetricsStore: AtriaHomeModel.ProfileMetricsStore",
            "vo2MaxEstimate: profileMetricsStore.state.vo2MaxEstimate",
            "let vo2MaxEstimate: VO2MaxEstimateSummary",
            "&& lhs.hero.recoveryEstimate.confidence == rhs.hero.recoveryEstimate.confidence",
            "&& lhs.hero.recoveryEstimate.detail == rhs.hero.recoveryEstimate.detail",
            "&& lhs.hero.strain == rhs.hero.strain",
            "&& lhs.vo2MaxEstimate == rhs.vo2MaxEstimate",
            "detail: recoveryDetailText",
            "private var recoveryDetailText: String",
            "case .validated:\n            return \"Validated\"",
            "case .personalBaseline:\n            return \"Personal baseline\"",
            "if hero.recoveryEstimate.detail.localizedCaseInsensitiveContains(\"HRV baseline\")",
            "return \"Building baseline\"",
            "&& lhs.live.status == rhs.live.status",
            "&& lhs.live.sessionSampleCount == rhs.live.sessionSampleCount",
            "&& lhs.live.liveActiveCalories == rhs.live.liveActiveCalories",
            "AtriaGlanceMetricCard(title: \"VO2max\"",
            "value: vo2MaxEstimate.value.map { String(format: \"%.1f\", $0) } ?? \"--\"",
            "VO2max building from resting baseline and measured HR max",
            "sensorSummary: store.imuAuditSummary",
            "let sensorSummary: IMUAuditSummary",
            "&& lhs.sensorSummary == rhs.sensorSummary",
            "onOpenVitals: onOpenVitals",
            "let onOpenVitals: () -> Void",
            "sleepHistory: store.sleepHistorySnapshot",
            "let sleepHistory: SleepHistorySnapshot",
            "&& lhs.sleepHistory == rhs.sleepHistory",
            "private func openTrendsSegment()",
            "onOpenInsights: openTrendsSegment",
            "let onOpenInsights: () -> Void",
            "historicalArchiveStatus: store.historicalArchiveStatus",
            "let historicalArchiveStatus: SessionStore.HistoricalArchiveStatus",
            "&& lhs.historicalArchiveStatus == rhs.historicalArchiveStatus",
            "onOpenCollection: onOpenCollection",
            "let onOpenCollection: () -> Void",
            "Button(action: onOpenCollection)",
            "AtriaGlanceMetricCard(title: \"Backfill\"",
            "value: historicalArchiveStatus.valueText",
            "detail: historicalArchiveStatus.detailText",
            ".accessibilityLabel(\"Open Data. Backfill \\(historicalArchiveStatus.valueText). \\(historicalArchiveStatus.userFootnoteText)\")",
            "private var backfillTint: Color",
            "historicalArchiveStatus.metricReady",
            "historicalArchiveStatus.hasArchiveRows",
            "historicalArchiveStatus.userFootnoteText",
            "AtriaGlanceMetricCard(title: \"Sleep eff\"",
            "value: sleepHistory.latest?.sleepEfficiencyText ?? \"--\"",
            "Duration-based",
            "Sleep efficiency is building from saved sleep duration",
            "private var sleepHistoryCard: some View",
            "Button(action: onOpenVitals)",
            "AtriaGlanceMetricCard(title: \"Sleep history\"",
            "value: sleepHistory.nights.isEmpty ? \"--\" : sleepHistory.averageDurationText",
            "detail: sleepHistory.nights.isEmpty ? \"Wear strap overnight or nap\" : sleepHistory.evidenceCountText",
            "Open Vitals. Sleep history is building. Wear the strap overnight or during a nap.",
            "sleepHistory.averageFootnoteText",
            "private var sleepHistorySparklineValues: [Int]",
            "for night in sleepHistory.nights.reversed()",
            "values.append(Int((night.durationHours * 10).rounded()))",
            "AtriaGlanceMetricCard(title: \"Resp rate\"",
            "value: sleepHistory.latest?.respiratoryRateText ?? \"--\"",
            "Sleep research",
            "Sleep-only",
            "AtriaGlanceMetricCard(title: \"Strap steps\"",
            "value: sensorSummary.strapStepText",
            "detail: sensorSummary.strapStepCount > 0 ? sensorSummary.agreementText : \"Research\"",
            "Strap step research is waiting for validated motion evidence",
            "AtriaGlanceMetricCard(title: \"Blood oxygen\"",
            "value: sensorSummary.spo2CandidateFrames > 0 ? \"\\(sensorSummary.spo2CandidateFrames)\" : \"--\"",
            "not an SpO2 reading",
            "does not show an SpO2 percentage",
            "AtriaGlanceMetricCard(title: \"Body temp\"",
            "value: sensorSummary.skinTempCandidateFrames > 0 ? \"\\(sensorSummary.skinTempCandidateFrames)\" : \"--\"",
            "research frames",
            "not a temperature reading",
            "insights: store.behaviorInsights",
            "taggedDays: store.behaviorJournalEntries.count",
            "let insights: [AtriaInsight]",
            "let taggedDays: Int",
            "let onShiftMetric: (AtriaTodayMetric, Int) -> Void",
            "let onStartWorkout: () -> Void",
            "&& lhs.insights == rhs.insights",
            "AtriaGlanceMetricCard(title: \"Workout\"",
            "value: live.status == .connected ? \"Start\" : \"Connect\"",
            "detail: live.sessionSampleCount > 0 ? \"\\(live.sessionSampleCount) readings\" : \"Live mode\"",
            ".accessibilityLabel(live.status == .connected",
            "private var insightsCard: some View",
            "Button(action: onOpenInsights)",
            "AtriaGlanceMetricCard(title: \"Insights\"",
            "detail: topInsight?.tagLabel ?? (taggedDays > 0 ? \"Learning patterns\" : \"Tag today\")",
            "Open Trends. Insights building from \\(taggedDays) tagged days",
            ".draggable(metric.rawValue)",
            ".dropDestination(for: String.self)",
            "onMoveMetric(dragged, metric)",
            "let upLabel = Text(\"Move \\(metric.label) up\")",
            "let downLabel = Text(\"Move \\(metric.label) down\")",
            ".accessibilityAction(named: upLabel)",
            ".accessibilityAction(named: downLabel)",
            "onShiftMetric(metric, -1)",
            "onShiftMetric(metric, 1)",
            "private func shiftMetric(_ metric: AtriaTodayMetric, direction: Int)",
            ".sensoryFeedback(.selection, trigger: orderCSV)",
        ]:
            assert_contains(self, overview, needle)

        assert_contains(self, home, "profileMetricsStore: model.profileMetricsStore")
        assert_contains(self, home, "onStartWorkout: {\n                                        workoutSession = AtriaWorkoutSession(start: Date())\n                                    }")

        assert_not_contains(self, overview, "LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 10)]")
        assert_not_contains(self, overview, "row.map(\\.glanceColumnSpan).reduce")
        assert_not_contains(self, overview, "figure.run.circle.fill")
        assert_not_contains(self, overview, "heart.text.square.fill")
        assert_not_contains(self, overview, "flame.circle.fill")

        for needle in [
            "@AppStorage(AtriaTodayMetric.orderStorageKey) private var todayOrderCSV = \"\"",
            "ForEach(AtriaTodayMetric.ordered(from: todayOrderCSV))",
            "private func canHideTodayMetric(_ metric: AtriaTodayMetric,",
            "AtriaTodayMetric.defaultGlanceOrder.filter { !activeHidden.contains($0.rawValue) }.count > 1",
            ".disabled(todayBinding(metric).wrappedValue && !canHideTodayMetric(metric))",
            "private func resetTodayLayout()",
            "todayOrderCSV = AtriaTodayMetric.defaultGlanceOrder.map(\\.rawValue).joined(separator: \",\")",
            "todayHiddenCSV = \"\"",
            "Label(\"Reset Today layout\", systemImage: \"arrow.counterclockwise\")",
            "AtriaTodayMetric.moving(metric, direction: -1, in: todayOrderCSV)",
            "AtriaTodayMetric.moving(metric, direction: 1, in: todayOrderCSV)",
            "Choose and reorder the cards shown at a glance.",
        ]:
            assert_contains(self, settings, needle)
        assert_not_contains(self, overview, "AtriaInsightsCardHost(store: store)")

        for needle in [
            "@AppStorage(AtriaVitalsSection.orderStorageKey) private var sectionOrderCSV = \"\"",
            "enum AtriaVitalsSection: String, CaseIterable, Identifiable",
            "static let orderStorageKey = \"atria.vitals.sectionOrderCSV\"",
            "var label: String",
            "case .recoveryStrain: return \"Recovery and strain\"",
            ".draggable(section.rawValue)",
            "AtriaVitalsSection.moving(dragged, before: section, in: sectionOrderCSV)",
            ".accessibilityAction(named: Text(\"Move \\(section.label) up\"))",
            ".accessibilityAction(named: Text(\"Move \\(section.label) down\"))",
            "private func moveSection(_ section: AtriaVitalsSection, direction: Int)",
            "private var hasCustomVitalsLayout: Bool",
            "AtriaVitalsSection.ordered(from: sectionOrderCSV) != Array(AtriaVitalsSection.allCases)",
            "private func resetVitalsLayout()",
            "sectionOrderCSV = AtriaVitalsSection.allCases.map(\\.rawValue).joined(separator: \",\")",
            "Label(\"Reset Vitals layout\", systemImage: \"arrow.counterclockwise\")",
            ".sensoryFeedback(.selection, trigger: sectionOrderCSV)",
            "static func moving(_ section: AtriaVitalsSection, direction: Int, in csv: String) -> String",
            "func enumeratedColumn(_ column: Int) -> [AtriaVitalsSection]",
        ]:
            assert_contains(self, vitals, needle)

    def test_handoff_21_connection_diagnosis_is_actionable_inline(self):
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")

        for needle in [
            "private struct AtriaConnectionDiagnosis: Equatable",
            "private static let lowBatteryThreshold = 20",
            "private static let connectionDiagnosisPersistenceDelay: TimeInterval = 15",
            "private static let connectionDiagnosisTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()",
            "@State private var connectionDiagnosisCandidate: AtriaConnectionDiagnosis?",
            "@State private var connectionDiagnosisCandidateSince: Date?",
            "@State private var visibleConnectionDiagnosis: AtriaConnectionDiagnosis?",
            ".onReceive(model.coreLiveStore.$state.map { _ in () })",
            ".onReceive(model.pulseLiveStore.$state.map { _ in () })",
            ".onReceive(Self.connectionDiagnosisTimer)",
            "private func updateConnectionDiagnosisVisibility(reason: String, now: Date = Date())",
            "AtriaConnectionDiagnosis.derive(live: model.coreLiveStore.state",
            "AtriaConnectionDiagnosisBanner(diagnosis: diagnosis)",
            "guard elapsed >= Self.connectionDiagnosisPersistenceDelay else",
            "visibleConnectionDiagnosis = nil",
            "var showsImmediately: Bool",
            "title == \"Bluetooth is off\"",
            "title == \"Bluetooth permission needed\"",
            "title == \"Strap battery low\"",
            "live.batteryLevel <= Self.lowBatteryThreshold",
            "var bluetoothPermissionDenied: Bool",
            "var officialAppCoexistenceRisk: AtriaBLEManager.OfficialAppCoexistenceRisk",
            "var needsRRContactCoach: Bool { rrContinuityState == \"poor_contact\" }",
            "ble.$bluetoothPermissionDenied.removeDuplicates()",
            "ble.$officialAppCoexistenceRisk.removeDuplicates()",
            "live.bluetoothPermissionDenied",
            "officialAppCoexistenceRisk: ble.officialAppCoexistenceRisk",
            "case .connected where pulse.needsContactCoach:",
            "pulse.hasPulseSignal ? \"Fit check needed\" : \"Connected, no pulse\"",
            "case .connected where live.needsRRContactCoach:",
            "Beat-to-beat signal weak",
            "Tighten the strap fit or wet the sensor for HRV and Recovery.",
            "case .connected where officialAppRiskActive && live.officialAppCoexistenceRisk == .suspected:",
            "WHOOP may interrupt",
            "Close or uninstall WHOOP if readings fragment.",
            "case .connected where officialAppRiskActive:",
            "WHOOP coexistence watch",
            "Atria is streaming; close WHOOP if drops return.",
            "let officialAppRiskActive = officialAppInstalled && live.officialAppCoexistenceRisk != .cleared",
            "let stalePairingSuspected = !officialAppInstalled && live.officialAppCoexistenceRisk == .suspected",
            "case .scanning, .connecting:\n            if officialAppRiskActive",
            "Keep the strap nearby and close WHOOP if it keeps reclaiming it.",
            "Connection keeps dropping",
            "Stale Bluetooth pairing",
            "Forget the strap in Bluetooth, then reconnect.",
            "Turn on Bluetooth in Settings.",
            "Allow Bluetooth for Atria in Settings.",
            "Tighten the strap fit or wet the sensor.",
            "Bring your strap closer and keep it on your wrist.",
            "Charge your strap before a workout or overnight wear.",
            "Close or uninstall WHOOP if it keeps reclaiming the strap.",
            "forget it in Bluetooth and reconnect",
        ]:
            assert_contains(self, home, needle)

        ble = source(ROOT / "Atria" / "Atria" / "AtriaBLEManager.swift")
        for needle in [
            "@Published private(set) var bluetoothPermissionDenied = false",
            "case .unauthorized:",
            "assignIfChanged(\\.bluetoothPermissionDenied, true)",
            "recomputeConnectionStatus(reason: \"central_unauthorized\")",
        ]:
            assert_contains(self, ble, needle)

        assert_not_contains(self, home, "showConnectionDiagnosisModal")

    def test_handoff_21_battery_saver_radio_mode_is_user_visible(self):
        settings = source(ROOT / "Atria" / "Atria" / "AtriaSettingsView.swift")
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")
        ble = source(ROOT / "Atria" / "Atria" / "AtriaBLEManager.swift")

        for needle in [
            "let batterySaverEnabled: Bool",
            "let onUpdateBatterySaver: (Bool) -> Void",
            "@State private var batterySaver: Bool",
            "radioModeSection",
            "Toggle(isOn: $batterySaver)",
            "Label(\"Battery saver\", systemImage: \"battery.75percent\")",
            "title: batterySaver ? \"Heart-rate only\" : \"Full sensor mode\"",
            "HRV, Recovery and sleep detail wait for validated beat-to-beat windows.",
            "Keeps richer strap streams available for beat-to-beat, HRV, Recovery and sleep research.",
            "Atria reconnects the strap when the radio mode changes.",
            ".onChange(of: batterySaver) { _, value in onUpdateBatterySaver(value) }",
        ]:
            assert_contains(self, settings, needle)

        for needle in [
            "batterySaverEnabled: ble.standardHROnlyEnabled",
            "onUpdateBatterySaver: { ble.setStandardHROnlyEnabled($0) }",
        ]:
            assert_contains(self, home, needle)

        for needle in [
            "func setStandardHROnlyEnabled(_ enabled: Bool)",
            "applyStandardHROnly(enabled: enabled, persist: true, reconnect: true, reason: \"user_toggle\")",
        ]:
            assert_contains(self, ble, needle)

    def test_handoff_21_historical_backfill_status_is_visible_and_fail_closed(self):
        archive = source(ROOT / "Atria" / "Atria" / "HistoricalArchive.swift")
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")
        collection = source(ROOT / "Atria" / "Atria" / "AtriaVitalsCollectionSections.swift")

        for needle in [
            "static let didUpdateNotification = Notification.Name(\"AtriaHistoricalArchiveDidUpdate\")",
            "NotificationCenter.default.post(name: didUpdateNotification, object: nil)",
        ]:
            assert_contains(self, archive, needle)

        for needle in [
            "struct HistoricalArchiveStatus: Equatable",
            "@Published private(set) var historicalArchiveStatus = HistoricalArchiveStatus.empty",
            "func refreshHistoricalArchiveStatus(reason: String = \"manual\")",
            "private var historicalArchiveStatusObserver: NSObjectProtocol?",
            "private var pendingHistoricalArchiveStatusRefresh: Task<Void, Never>?",
            "NotificationCenter.default.addObserver(forName: HistoricalArchive.didUpdateNotification",
            "scheduleHistoricalArchiveStatusRefresh(reason: \"archive_did_update\")",
            "pendingHistoricalArchiveStatusRefresh?.cancel()",
            "try? await Task.sleep(nanoseconds: 500_000_000)",
            "refreshHistoricalArchiveStatus(reason: reason)",
            "NotificationCenter.default.removeObserver(historicalArchiveStatusObserver)",
            "DispatchQueue.global(qos: .utility).async",
            "HistoricalArchive.diagnostics()",
            "return \"\\(rows) saved · reference gated\"",
            "var userFootnoteText: String",
            "return \"\\(rows) saved locally; external beat-to-beat reference gates HRV, Recovery and Sleep metrics.\"",
            "return \"\\(metricUsableRows)/\\(rows) rows metric-ready.\"",
            "var metricReady: Bool",
            "metricUsableRows > 0 && currentSessionUsableRows > 0",
            "refreshHistoricalArchiveStatus(reason: \"session_store_init\")",
        ]:
            assert_contains(self, sessions, needle)

        for needle in [
            "AtriaCollectionStatusCardHost(coreLiveStore: coreLiveStore,",
            "store: store)",
            "officialAppInstalled: officialAppInstalled",
            "let officialAppInstalled: Bool",
            "@ObservedObject var store: SessionStore",
            "store.refreshHistoricalArchiveStatus(reason: \"data_status_appear\")",
            "AtriaMetricTile(label: \"Backfill\"",
            "value: store.historicalArchiveStatus.valueText",
            "state: store.historicalArchiveStatus.metricReady ? .validated : (store.historicalArchiveStatus.hasArchiveRows ? .local : .learning)",
            "footnote: store.historicalArchiveStatus.userFootnoteText",
            "AtriaMetricTile(label: \"App\"",
            "value: coexistenceValue",
            "state: coexistenceState",
            "tint: coexistenceTint",
            "footnote: coexistenceFootnote",
            "AtriaCollectionCoexistenceWarning(risk: collectionLiveStore.state.officialAppCoexistenceRisk,",
            "officialAppInstalled: officialAppInstalled)",
            "return officialAppInstalled ? \"App conflict\" : \"Connection keeps dropping\"",
            "case .suspected where officialAppInstalled:",
            "return \"Remove the official strap app, then reconnect.\"",
            "return \"Forget the strap in Bluetooth, then reconnect.\"",
            "private var coexistenceValue: String",
            "case .advisory:\n            return \"Monitor\"",
            "case .suspected:\n            return \"Conflict\"",
            "private var coexistenceState: AtriaMetricState",
            "case .advisory:\n            return .local",
            "return .conflict",
            "private var coexistenceFootnote: String",
            "return \"Close the official app if drops return.\"",
            "return \"Uninstall or disable the official app before relying on Atria.\"",
        ]:
            assert_contains(self, collection, needle)

    def test_handoff_21_uniform_cards_avoid_clipping_and_nested_raised_chrome(self):
        overview = source(ROOT / "Atria" / "Atria" / "AtriaOverviewSections.swift")
        vitals = source(ROOT / "Atria" / "Atria" / "AtriaVitalsCollectionSections.swift")
        shared_ui = source(ROOT / "Atria" / "Atria" / "AtriaSharedUIComponents.swift")
        connection = source(ROOT / "Atria" / "Atria" / "AtriaHeroConnectionSections.swift")
        content = source(ROOT / "Atria" / "Atria" / "ContentView.swift")
        live_workout = source(ROOT / "Atria" / "Atria" / "AtriaLiveWorkoutView.swift")
        haptics = source(ROOT / "Atria" / "Atria" / "AtriaHapticAlerts.swift")
        settings = source(ROOT / "Atria" / "Atria" / "AtriaSettingsView.swift")

        for needle in [
            "struct AtriaOverviewCollectionSection: View, Equatable",
            "Label(\"Data\", systemImage: \"arrow.right.circle.fill\")",
            ".frame(minWidth: 88)",
            "AtriaInlineQuickStat(label: \"HRV window\", value: stats.rrPackageText)",
            ".frame(maxWidth: .infinity, alignment: .leading)",
            ".lineLimit(3)",
            ".lineLimit(2)",
        ]:
            assert_contains(self, overview, needle)

        assert_not_contains(self, overview, ".frame(maxWidth: 118)")

        for needle in [
            "private struct AtriaCollectionCoexistenceWarning: View, Equatable",
            ".atriaInsetCard(tint: tint)",
            "AtriaPanelSectionHeader(title: \"Beat-to-beat reference\", subtitle: \"\")",
            "leadingTitle: \"Beat-to-beat window\"",
            "Text(\"Export beats\").frame(maxWidth: .infinity)",
            "Text(\"Import beats\").frame(maxWidth: .infinity)",
            "AtriaPanelSectionHeader(title: \"Heart-rate check\", subtitle: \"\")",
            "leadingTitle: \"Heart-rate status\"",
            "leadingDetail: \"comparison workout\"",
            "Text(\"Export heart rate\").frame(maxWidth: .infinity)",
            "Text(\"Import heart rate\").frame(maxWidth: .infinity)",
            "private struct AtriaCollectionProfilePicker: View, Equatable",
            ".atriaInsetCard(tint: .purple)",
            "private struct AtriaRecoveryStrainCard: View, Equatable",
            "private struct AtriaProfileCard: View, Equatable",
            "private struct AtriaCollectionResearchSignalsCard: View, Equatable",
            "private struct AtriaCollectionIMUAuditCard: View, Equatable",
            "private struct AtriaResearchManeuverMarkerCard: View, Equatable",
            ".atriaCard(emphasis: .soft)",
        ]:
            assert_contains(self, vitals, needle)
        assert_not_contains(self, vitals, ".atriaRaisedCard(")
        assert_not_contains(self, vitals, "AtriaPanelSectionHeader(title: \"RR reference\"")
        assert_not_contains(self, vitals, "leadingTitle: \"RR window\"")
        assert_not_contains(self, vitals, "Text(\"Export RR\")")
        assert_not_contains(self, vitals, "Text(\"Import RR\")")
        assert_not_contains(self, vitals, "AtriaPanelSectionHeader(title: \"HR reference\"")
        assert_not_contains(self, vitals, "leadingTitle: \"HR status\"")
        assert_not_contains(self, vitals, "leadingDetail: \"external workout check\"")
        assert_not_contains(self, vitals, "Text(\"Export HR\")")
        assert_not_contains(self, vitals, "Text(\"Import HR\")")

        for needle in [
            "struct AtriaHapticAlertSettingsCard: View, Equatable",
            ".atriaInsetCard(tint: .purple)",
        ]:
            assert_contains(self, haptics, needle)
        assert_not_contains(self, haptics, ".atriaRaisedCard(")

        for needle in [
            "AtriaHapticAlertSettingsCard(settings: haptics) { next in",
            "haptics = next",
            "Text(\"Phone-side alerts only.\")",
        ]:
            assert_contains(self, settings, needle)
        for forbidden in [
            "Toggle(\"Heart-rate zone alerts\", isOn: $haptics.heartRateZones)",
            "Toggle(\"Strain target reached\", isOn: $haptics.strainTarget)",
            "Toggle(\"Recovery is ready\", isOn: $haptics.recoveryReady)",
            "Toggle(\"Incoming calls\", isOn: $haptics.incomingCalls)",
            "Toggle(\"Low strap battery\", isOn: $haptics.lowBattery)",
        ]:
            assert_not_contains(self, settings, forbidden)

        for needle in [
            "Text(\"I’ll handle it\")\n                        .frame(maxWidth: .infinity)",
            ".atriaCardAction(tint: .orange)",
            "Text(primaryButtonTitle)\n                                    .frame(maxWidth: .infinity)",
            ".atriaCardAction(tint: .blue)",
            "Text(\"Retry scan now\")\n                                    .frame(maxWidth: .infinity)",
            ".atriaCardAction(prominent: false, tint: .gray)",
        ]:
            assert_contains(self, connection, needle)
        assert_not_contains(self, connection, ".buttonStyle(.glass")
        assert_not_contains(self, connection, ".buttonStyle(.glassProminent")

        for needle in [
            "struct AtriaMetricTile: View, Equatable",
            "static let gridSpacing: CGFloat = 12",
            "static let gridMinimumWidth: CGFloat = 142",
            "static let gridColumns = [GridItem(.adaptive(minimum: gridMinimumWidth), spacing: gridSpacing)]",
            "private static let compactHeight: CGFloat = 122",
            "private static let sparklineHeight: CGFloat = 132",
            "private static let footerHeight: CGFloat = 34",
            "private var accessibilityText: String",
            "parts.append(state.accessibilityLabel)",
            "parts.append(footnote)",
            ".accessibilityLabel(accessibilityText)",
            "private var tileHeight: CGFloat",
            "private var footer: some View",
            "maxHeight: tileHeight",
            ".frame(height: Self.footerHeight)",
            ".frame(height: Self.footerHeight, alignment: .topLeading)",
            "Color.clear",
            ".lineLimit(2)",
            ".fixedSize(horizontal: false, vertical: true)",
            ".frame(maxWidth: .infinity, minHeight: 30)",
            ".atriaCardAction(prominent: false, tint: .secondary)",
            ".accessibilityLabel(\"Decrease \\(title)\")",
            ".accessibilityLabel(\"Increase \\(title)\")",
        ]:
            assert_contains(self, shared_ui, needle)
        assert_not_contains(self, shared_ui, "minHeight: sparklineValues == nil ? 100 : 130")
        assert_not_contains(self, shared_ui, ".buttonStyle(.glass")
        assert_contains(self, vitals, "private static let statColumns = AtriaMetricTile.gridColumns")
        assert_contains(self, vitals, "LazyVGrid(columns: Self.statColumns, spacing: AtriaMetricTile.gridSpacing)")
        assert_not_contains(self, vitals, "private static let statColumns = [GridItem(.adaptive(minimum:")

        assert_contains(self, content, "Text(primaryButtonTitle)\n                            .frame(maxWidth: .infinity)")
        assert_contains(self, content, ".atriaCardAction(tint: .blue)")
        assert_contains(self, live_workout, ".atriaCardAction(tint: .red)")

    def test_live_workout_end_checkpoints_and_confirms_honestly(self):
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")
        ble = source(ROOT / "Atria" / "Atria" / "AtriaBLEManager.swift")
        live_workout = source(ROOT / "Atria" / "Atria" / "AtriaLiveWorkoutView.swift")

        for needle in [
            "private struct AtriaWorkoutEndNotice: Identifiable, Equatable",
            "@State private var workoutEndNotice: AtriaWorkoutEndNotice?",
            "onStop: { endWorkoutSession(startedAt: session.start) }",
            ".alert(item: $workoutEndNotice)",
            "private func endWorkoutSession(startedAt: Date)",
            "ble.checkpointCurrentSession(label: label, reason: \"live_workout_end\")",
            "store.confirmBestWorkoutCandidateForUI(rest: rest,",
            "source: \"live_workout_end\"",
            "store.exportToHealthKit()",
            "Workout evidence saved",
            "needs at least 10 minutes of strong heart-rate evidence",
            "ATRIADBG live_workout_end",
        ]:
            assert_contains(self, home, needle)

        for needle in [
            "func checkpointCurrentSession(label: String, reason: String) -> Bool",
            "snapshotSession(label: label)",
            "onSessionCheckpoint?(saved) == true",
            "persistActiveSessionJournalIfNeeded(reason: \"live_workout_end_checkpoint\", force: true)",
            "source=live_workout_end mode=upsert reset_live_session=0",
        ]:
            assert_contains(self, ble, needle)

        assert_contains(self, live_workout, "Label(\"End workout\", systemImage: \"stop.fill\")")
        assert_not_contains(self, home, "onStop: { workoutSession = nil }")

    def test_live_workout_auto_detect_prompt_is_inline_and_conservative(self):
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")

        for needle in [
            "private static let workoutPromptCooldown: TimeInterval = 45 * 60",
            "private static let workoutPromptMinimumSamples = 180",
            "private static let workoutPromptMinimumTRIMP = 1.2",
            "private static let workoutPromptMinimumBPMOverRest = 25",
            "fileprivate struct AtriaWorkoutDetectionPrompt: Equatable",
            "@State private var workoutDetectionPrompt: AtriaWorkoutDetectionPrompt?",
            "@State private var workoutPromptDismissedUntil: Date?",
            "AtriaWorkoutDetectionBanner(prompt: prompt)",
            "workoutPromptDismissedUntil = Date().addingTimeInterval(Self.workoutPromptCooldown)",
            "workoutSession = AtriaWorkoutSession(start: Date())",
            "updateWorkoutDetectionPrompt()",
            "private func updateWorkoutDetectionPrompt(now: Date = Date())",
            "guard selectedTab == .overview else { return }",
            "guard workoutSession == nil else {",
            "guard model.coreLiveStore.state.status == .connected else {",
            "workoutPromptDismissedUntil > now",
            "samples >= Self.workoutPromptMinimumSamples",
            "liveTRIMP >= Self.workoutPromptMinimumTRIMP",
            "heartRate >= rest + Self.workoutPromptMinimumBPMOverRest",
            "private struct AtriaWorkoutDetectionBanner: View, Equatable",
            "Text(\"Looks like a workout\")",
            "Text(\"Start workout\")",
            "Text(\"Dismiss\")",
        ]:
            assert_contains(self, home, needle)

        assert_not_contains(self, home, ".alert(item: $workoutDetectionPrompt)")

    def test_session_detail_downsamples_once_for_render_perf(self):
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")

        for needle in [
            "struct SessionDetail: View",
            "private let displayedPoints: [SavedSession.Point]",
            "init(session: SavedSession)",
            "self.displayedPoints = Self.downsampledPoints(session.points)",
            "private static func downsampledPoints",
            "Chart(Array(displayedPoints.enumerated()), id: \\.offset)",
        ]:
            assert_contains(self, sessions, needle)

        assert_not_contains(
            self,
            sessions,
            "private var displayedPoints: [SavedSession.Point] {\n        downsampledPoints(session.points)",
        )

    def test_swiftui_render_blocks_do_not_run_session_derivations(self):
        forbidden = [
            ".sorted(",
            ".reduce(",
            ".compactMap(",
            "dailyRollups(",
            "detectedActivity(",
        ]
        checked = 0
        for rel in [
            ROOT / "Atria" / "Atria" / "ContentView.swift",
            ROOT / "Atria" / "Atria" / "AtriaHomeView.swift",
            ROOT / "Atria" / "Atria" / "AtriaHeroConnectionSections.swift",
            ROOT / "Atria" / "Atria" / "AtriaOverviewSections.swift",
            ROOT / "Atria" / "Atria" / "AtriaVitalsCollectionSections.swift",
            ROOT / "Atria" / "Atria" / "AtriaTrendChart.swift",
            ROOT / "Atria" / "Atria" / "AtriaLiveWorkoutView.swift",
            ROOT / "Atria" / "Atria" / "AtriaSettingsView.swift",
            ROOT / "Atria" / "Atria" / "AtriaAICoachCard.swift",
        ]:
            for start, body in swift_some_view_blocks(source(rel)):
                checked += 1
                for needle in forbidden:
                    self.assertNotIn(needle, body, f"{rel}:{start} keeps {needle} in a some View render block")
        self.assertGreater(checked, 90)

        checks = source(ROOT / "test_handoff_static_checks.py")
        assert_contains(self, checks, "def swift_some_view_blocks(text):")

        content = source(ROOT / "Atria" / "Atria" / "ContentView.swift")
        for removed_legacy_token in [
            "private struct DailyEvidenceCard",
            "private struct CollectionReliabilityCard",
            "ATRIADBG daily_evidence_ui",
            "ATRIADBG collection_reliability_ui",
            "detectedActivity(",
        ]:
            assert_not_contains(self, content, removed_legacy_token)

    def test_history_snapshot_is_cached_off_navigation_path(self):
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")

        for needle in [
            "@Published private(set) var historySnapshot = HistorySnapshot.empty",
            "@Published private(set) var sleepHistorySnapshot = SleepHistorySnapshot.empty",
            "private var historySnapshotRevision = 0",
            "private func refreshHistorySnapshotCache(deferred: Bool = true)",
            "historySnapshot = HistorySnapshot.sessionsOnly(sessions)",
            "await Task.yield()",
            "try? await Task.sleep(nanoseconds: 120_000_000)",
            "private func publishFullHistorySnapshotIfCurrent(revision: Int)",
            "historySnapshot = HistorySnapshot(sessions: sessions,",
            "sleepHistorySnapshot = SleepHistorySnapshot(rollups: rollups,",
            "private var snapshot: HistorySnapshot {\n        store.historySnapshot\n    }",
            "struct HistorySnapshot",
            "struct SleepHistorySnapshot: Equatable",
            "static let empty = HistorySnapshot(sessions: [], detections: [], trends: [], rollups: [])",
            "static func sessionsOnly(_ sessions: [SavedSession]) -> HistorySnapshot",
        ]:
            assert_contains(self, sessions, needle)

        history_view_start = sessions.index("struct HistoryView: View")
        history_view_end = sessions.index("struct HistorySnapshot")
        history_view_source = sessions[history_view_start:history_view_end]
        for forbidden in [
            "@State private var snapshot",
            "HistorySnapshot(store: store)",
            "refreshSnapshot()",
            "detectedActivities(rest:",
            "trendSummaries(rest:",
            "dailyRollups(rest:",
        ]:
            assert_not_contains(self, history_view_source, forbidden)

        history_snapshot_start = sessions.index("struct HistorySnapshot")
        history_snapshot_end = sessions.index("private struct HistoryQuickStat")
        history_snapshot_source = sessions[history_snapshot_start:history_snapshot_end]
        for forbidden in [
            "init(store: SessionStore)",
            "detectedActivities(rest:",
            "trendSummaries(rest:",
            "dailyRollups(rest:",
        ]:
            assert_not_contains(self, history_snapshot_source, forbidden)

    def test_sleep_history_snapshot_is_cached_and_shown_in_vitals(self):
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")
        vitals = source(ROOT / "Atria" / "Atria" / "AtriaVitalsCollectionSections.swift")

        for needle in [
            "struct SleepHistorySnapshot: Equatable",
            "struct Night: Identifiable, Equatable",
            "@Published private(set) var sleepHistorySnapshot = SleepHistorySnapshot.empty",
            "let rollups = dailyRollups(rest: rest, maxHR: maxHR)",
            "sleepHistorySnapshot = SleepHistorySnapshot(rollups: rollups,",
            "confirmedSleeps: cachedConfirmedSleeps",
            "let sleepDuration: TimeInterval?",
            "let sleepSpan: TimeInterval?",
            "let sleepSource: String?",
            "let sleepEfficiency: Double?",
            "var sleepEfficiencyText: String",
            "var isNapEvidence: Bool",
            'source == "nap_candidate"',
            'var evidenceLabel: String',
            'isNapEvidence ? "Nap" : "Sleep"',
            'var evidenceOnlyFootnote: String',
            'isNapEvidence ? "Nap-only estimate" : "Sleep-only estimate"',
            'var confirmationText: String',
            'return isNapEvidence ? "Nap candidate" : "Sleep candidate"',
            "var evidenceCountText: String",
            "let napCount = nights.filter(\\.isNapEvidence).count",
            'return "\\(nights.count) records"',
            'return nights.count == 1 ? "1 night" : "\\(nights.count) nights"',
            "var averageFootnoteText: String",
            '"Average across \\(evidenceCountText)"',
            "var emptyEvidenceLabel: String",
            '"Recent records"',
            "var emptyEvidenceValue: String",
            'return "Confirmed sleep or nap saved locally."',
            "var emptyEvidenceFootnote: String",
            "sleepEfficiency: Self.efficiency(duration: sleep.duration, span: sleep.span)",
            "sleepSource: aggregateSleep?.kind",
            'source: rollup.sleepReady > 0 ? "validated_sleep_window" : (rollup.sleepSource ?? "sleep_candidate")',
            "if let existing = nightsByDay[day], existing.confirmed {",
            "nightsByDay[day] = Self.mergingConfirmedNight(existing, with: rollup)",
            "private static func mergingConfirmedNight(_ night: Night, with rollup: DailyRollup) -> Night",
            "restingHR: night.restingHR ?? rollup.restingHR",
            "hrv: night.hrv ?? rollup.avgHRV",
            "respiratoryRate: night.respiratoryRate ?? rollup.avgRespiratoryRate",
            "private static func efficiency(duration: TimeInterval, span: TimeInterval?) -> Double?",
            "static let minimumFragmentDuration: TimeInterval = 5 * 60",
            "static let napMinimumDuration: TimeInterval = 20 * 60",
            "static let napMaximumSpan: TimeInterval = 3 * 60 * 60",
            'let kind: String',
            "session.duration >= AggregateSleepCandidate.minimumFragmentDuration",
            "let daytimeNapWindow = !overnight && startHour >= 11 && endHour <= 20",
            "session.duration >= AggregateSleepCandidate.napMinimumDuration",
            "session.avg <= rest + 12",
            "session.peak <= rest + 35",
            "let strictDurationReady = totalDuration >= AggregateSleepCandidate.strictMinimumDuration",
            "let fragmentedFallbackReady = cluster.count > 1",
            "let napCandidateReady = clusterStartHour >= 11",
            "guard strictDurationReady || fragmentedFallbackReady || napCandidateReady else { return nil }",
            'reason = "HR-only daytime nap candidate; user confirmation required; \\(motionReason)"',
            'let kind = napCandidateReady ? "nap_candidate" : "overnight_sleep"',
            'if candidate.kind == "nap_candidate" { return "hr_only_nap" }',
            'let sleepSource = best.kind == "nap_candidate"',
            '? "nap_candidate"',
            "AtriaVitalsRecoveryStrainCardHost(heroStore: heroStore,\n                                          store: store)",
            "AtriaRecoveryStrainCard(hero: heroStore.state,\n                                sleepHistory: store.sleepHistorySnapshot)",
            "private struct AtriaSleepHistoryCard: View, Equatable",
            "AtriaSleepHistoryCard(snapshot: sleepHistory)",
            "Chart(chartNights)",
            "Wear the strap overnight or during a nap.",
            "Sleep or nap evidence saved; confirm it when ready.",
            'AtriaMetricTile(label: snapshot.latest?.evidenceLabel ?? "Latest"',
            'night.isNapEvidence ? "moon.zzz.fill" : "bed.double.fill"',
            "\\(night.confirmationText) · \\(night.durationText)",
            "footnote: snapshot.averageFootnoteText",
            "private var emptyEvidenceState: AtriaMetricState",
            "if snapshot.candidateCount > 0 { return .research }",
            "private var latestEvidenceFootnote: String",
            "\"\\(latest.confidenceText) · \\(latest.confirmationText)\"",
            "\"\\(latest.confidenceText) · \\(latest.confirmationText.lowercased())\"",
            "AtriaMetricTile(label: snapshot.emptyEvidenceLabel",
            "value: snapshot.emptyEvidenceValue",
            "state: emptyEvidenceState",
            "footnote: snapshot.emptyEvidenceFootnote",
            "AtriaMetricTile(label: \"Efficiency\"",
            "value: snapshot.latest?.sleepEfficiencyText ?? \"--\"",
            "state: snapshot.latest?.sleepEfficiency == nil ? .learning : .research",
            "footnote: \"Duration-based estimate\"",
            'AtriaMetricTile(label: "\\(snapshot.latest?.evidenceLabel ?? "Sleep") RHR"',
            'AtriaMetricTile(label: "\\(snapshot.latest?.evidenceLabel ?? "Sleep") HRV"',
            "value: snapshot.latest?.hrvText ?? \"--\"",
            "state: snapshot.latest?.hrv == nil ? .learning : .research",
            'footnote: snapshot.latest?.evidenceOnlyFootnote ?? "Sleep-only estimate"',
            'AtriaMetricTile(label: "\\(snapshot.latest?.evidenceLabel ?? "Sleep") resp"',
            "value: snapshot.latest?.respiratoryRateText ?? \"--\"",
            "state: snapshot.latest?.respiratoryRate == nil ? .learning : .research",
            'footnote: snapshot.latest?.evidenceOnlyFootnote ?? "Sleep-only estimate"',
            "Eff \\(night.sleepEfficiencyText)",
            "HRV \\(night.hrvText)",
            "Resp \\(night.respiratoryRateText)",
        ]:
            assert_contains(self, sessions + vitals, needle)

        assert_contains(self, vitals, "case pulse, hrv, recoveryStrain, profile")
        assert_not_contains(self, vitals, "case pulse, hrv, recoveryStrain, sleep")
        assert_not_contains(self, sessions, "guard session.duration >= 20 * 60, !session.points.isEmpty else { return false }")

        sleep_card_start = vitals.index("private struct AtriaSleepHistoryCard")
        sleep_card_end = vitals.index("private struct AtriaSleepNightRow")
        sleep_card_source = vitals[sleep_card_start:sleep_card_end]
        for forbidden in [
            "dailyRollups(",
            "detectedActivity(",
            "aggregateSleepCandidates(",
        ]:
            assert_not_contains(self, sleep_card_source, forbidden)

    def test_morning_journal_uses_cached_sleep_and_explicit_confirm(self):
        overview = source(ROOT / "Atria" / "Atria" / "AtriaOverviewSections.swift")

        for needle in [
            "AtriaOverviewMorningJournalHost(heroStore: heroStore,",
            "struct AtriaOverviewMorningJournalHost: View",
            "AtriaOverviewMorningJournalCard(hero: heroStore.state,",
            "sleepHistory: store.sleepHistorySnapshot",
            "todayEntry: store.behaviorJournalEntry()",
            "taggedDays: store.behaviorJournalEntries.count",
            "store.toggleBehaviorTag(tag)",
            "store.confirmBestSleepCandidateForUI(rest: store.baseline.restingInt ?? 60,",
            'source: "morning_journal"',
            "struct AtriaOverviewMorningJournalCard: View, Equatable",
            'AtriaPanelSectionHeader(title: "Morning journal", subtitle: "")',
            'AtriaMetricTile(label: latestNight?.evidenceLabel ?? "Sleep"',
            'AtriaMetricTile(label: latestNight.map { "\\($0.evidenceLabel) eff" } ?? "Sleep eff"',
            "value: latestNight?.sleepEfficiencyText ?? \"--\"",
            "state: latestNight?.sleepEfficiency == nil ? .learning : .research",
            "AtriaMetricTile(label: \"HRV\"",
            "footnote: hero.hrvDetail",
            "parts.append(\"Eff \\(latestNight.sleepEfficiencyText)\")",
            "parts.append(\"HRV \\(latestNight.hrvText)\")",
            "parts.append(\"Resp \\(latestNight.respiratoryRateText)\")",
            "parts.append(latestNight.confirmationText)",
            "return parts.joined(separator: \" · \")",
            "footnote: \"Duration-based estimate\"",
            'Label(latestNight?.isNapEvidence == true ? "Confirm nap" : "Confirm sleep",',
            '"Tags stay on device and power local insights."',
        ]:
            assert_contains(self, overview, needle)

        morning_start = overview.index("struct AtriaOverviewMorningJournalCard")
        morning_end = overview.index("struct AtriaInsightsCardHost")
        morning_source = overview[morning_start:morning_end]
        for forbidden in [
            "dailyRollups(",
            "detectedActivity(",
            "aggregateSleepCandidates(",
        ]:
            assert_not_contains(self, morning_source, forbidden)

    def test_overview_trend_chart_points_are_cached_off_render_path(self):
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")
        trend_chart = source(ROOT / "Atria" / "Atria" / "AtriaTrendChart.swift")
        overview = source(ROOT / "Atria" / "Atria" / "AtriaOverviewSections.swift")

        for needle in [
            "@Published private(set) var overviewTrendPoints: [AtriaTrendPoint] = []",
            "private var overviewTrendPointsRevision = 0",
            "private func refreshOverviewTrendPointsCache(deferred: Bool = true)",
            "DispatchQueue.global(qos: .utility).async",
            "Self.makeOverviewTrendPoints(sessions: source, rest: rest, maxHR: maxHR)",
            "private nonisolated static func makeOverviewTrendPoints(sessions: [SavedSession]",
            "Metrics.strain(fromTRIMP: session.trimp(rest: rest, max: maxHR))",
        ]:
            assert_contains(self, sessions, needle)

        for needle in [
            "AtriaTrendChartCard(points: store.overviewTrendPoints,",
            "baselineRestingHR: store.baseline.restingInt",
        ]:
            assert_contains(self, trend_chart, needle)

        for forbidden in [
            "private var trendPoints",
            "store.sessions.filter",
            "meaningful.sorted",
            "Metrics.strain(fromTRIMP:",
            "session.trimp(rest:",
            "let maxHR",
        ]:
            assert_not_contains(self, trend_chart, forbidden)

        assert_contains(self, overview, "AtriaOverviewTrendChartHost(store: store)")
        assert_contains(self, overview, "store.overviewTrendPoints.count >= 2")
        assert_not_contains(self, overview, "AtriaOverviewTrendChartHost(store: store, maxHR:")
        assert_not_contains(self, overview, "store.sessions.filter { $0.points.count >= 8 }.count >= 2")

    def test_behavior_insights_compute_from_snapshots_off_actor_path(self):
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")

        for needle in [
            "let sourceSessions = cachedCanonicalSessions",
            "let journalEntries = cachedBehaviorJournalEntries",
            "Self.makeBehaviorCorrelationSummaries(sessions: sourceSessions,",
            "let insights = Self.deriveInsights(from: summaries)",
            "nonisolated static func deriveInsights(from summaries: [BehaviorCorrelationSummary])",
            "private nonisolated static func makeBehaviorCorrelationSummaries(sessions: [SavedSession]",
            "journalEntries: [BehaviorJournalEntry]",
            "Self.makeBehaviorCorrelationSummaries(sessions: canonicalSessions(),",
            "private nonisolated static func averageDoubleSnapshot(_ values: [Double]) -> Double?",
        ]:
            assert_contains(self, sessions, needle)

        recompute_start = sessions.index("func recomputeBehaviorInsights()")
        recompute_end = sessions.index("/// Turn per-tag correlation deltas")
        recompute_source = sessions[recompute_start:recompute_end]
        for forbidden in [
            "self.behaviorCorrelationSummaries(rest:",
            "dailyRollups(rest:",
            "detectedActivities(rest:",
        ]:
            assert_not_contains(self, recompute_source, forbidden)

    def test_connected_pulse_display_name_is_precomputed_for_hr_tick_perf(self):
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")
        hero = source(ROOT / "Atria" / "Atria" / "AtriaHeroConnectionSections.swift")

        for needle in [
            "var displayDeviceName: String",
            "displayDeviceName: AtriaDeviceDisplayName.shortName(for: deviceName)",
        ]:
            assert_contains(self, home, needle)

        for needle in [
            "enum AtriaDeviceDisplayName",
            "static func shortName(for deviceName: String) -> String",
            "displayDeviceName: liveStore.state.displayDeviceName",
            "AtriaConnectedPulseStatusCard(displayDeviceName: displayDeviceName",
            "let displayDeviceName: String",
            "Live heart rate \\(heartRateText) beats per minute from \\(displayDeviceName)",
        ]:
            assert_contains(self, hero, needle)

        assert_not_contains(self, hero, "private var displayDeviceName: String")

    def test_standard_hr_only_mode_blocks_strap_writes(self):
        text = source(ROOT / "Atria" / "Atria" / "AtriaBLEManager.swift")
        match = re.search(r"private func sendCommand\(_ cmd: UInt8, _ data: \[UInt8\], mode: CommandWriteMode\) \{(?P<body>.*?)\n    \}", text, re.S)
        self.assertIsNotNone(match)
        body = match.group("body")

        guard_index = body.find("guard !standardHROnlyMode || historyOnlyProbeEnabled else")
        first_write_index = body.find("writeValue(")
        self.assertGreaterEqual(guard_index, 0)
        self.assertGreater(first_write_index, guard_index)
        assert_contains(self, body, "standard_hr_only_no_strap_writes")
        assert_contains(self, body, "standard_hr_only_write_blocked")
        self.assertEqual(text.count("writeValue("), body.count("writeValue("))
        self.assertEqual(body.count("writeValue("), 2)

    def test_offline_historical_sync_is_bounded_standard_hr_exception(self):
        ble = source(ROOT / "Atria" / "Atria" / "AtriaBLEManager.swift")
        app = source(ROOT / "Atria" / "Atria" / "AtriaApp.swift")

        for needle in [
            "enum OfflineSyncDefaults",
            "defaults.set(true, forKey: OfflineSyncDefaults.enabled)",
            "private func migrateOfflineSyncDefaultIfNeeded(arguments: [String])",
            "stored_session_backfill_default",
            "applyEarlyHistoricalLaunchConfiguration(arguments: arguments)",
            "private func applyEarlyHistoricalLaunchConfiguration(arguments: [String])",
            "ATRIADBG realtimeConfig history_only_probe=1 phase=early",
            "@discardableResult",
            "func requestOfflineHistoricalSyncIfNeeded(reason: String, force: Bool = false)",
            "private func startOfflineHistoricalSync(reason: String, force: Bool)",
            "historyOnlyProbeEnabled = true",
            "historyOnlyProbeMode = true",
            "historyClockSyncEnabled = true",
            "historicalAckDisabled = false",
            "historyAckMode = \"enddata\"",
            "probeCommandMode = .withResponse",
            "[Cmd.abortHistoricalTransmits, 0x00]",
            "[Cmd.enterHighFreqSync, 0x00]",
            "[Cmd.sendHistoricalData, 0x00]",
            "historySkipDataRangeRequest = true",
            "ATRIADBG offline_sync status=armed",
            "live_realtime=skipped metrics_fail_closed=1",
            "deferred_live_link",
            "detail=live_link_connected action=keep_ble_stream",
            "detail=live_link_connected_late action=keep_ble_stream",
            "static let rangeLossBackfillPending",
            "private func markRangeLossBackfillRequired(reason: String)",
            "private func preserveLongWearRangeLossRecovery(reason: String)",
            "private func scheduleRangeLossBackfillIfNeeded(reason: String)",
            "ATRIADBG offline_sync status=pending_range_loss_backfill",
            "ATRIADBG offline_sync status=requesting_range_loss_backfill",
            "action=defer_if_live_link_connected",
            "requestOfflineHistoricalSyncIfNeeded(reason: backfillReason, force: false)",
            "static func offlineSyncEvidence() -> String",
            "offline_range_loss_backfill_pending",
            "private func finishOfflineHistoricalSync(reason: String)",
            "applyStandardHROnly(enabled: true, persist: true, reconnect: true, reason: \"offline_sync_complete\")",
            "central.cancelPeripheralConnection(peripheral)",
        ]:
            assert_contains(self, ble, needle)

        init_body = re.search(r"override init\(\) \{(?P<body>.*?)\n    \}", ble, re.S)
        self.assertIsNotNone(init_body)
        body = init_body.group("body")
        early_config = body.find("applyEarlyHistoricalLaunchConfiguration(arguments: arguments)")
        central_create = body.find("central = CBCentralManager")
        self.assertGreaterEqual(early_config, 0)
        self.assertGreater(central_create, early_config)

        for needle in [
            "let syncStarted = ble.requestOfflineHistoricalSyncIfNeeded(reason: reason)",
            "if syncStarted",
            "try? await Task.sleep(for: .seconds(185))",
            "case .background:",
            "ble.handleSceneBackgroundTransition(reason: \"scene_background\",",
            "rest: store.baseline.restingInt ?? 60",
            "maxHR: store.profile.maxHR",
            "case .inactive:",
            "ble.flushLifecycleRealtimeState(reason: \"scene_inactive_checkpoint\")",
            "handleBackgroundTask",
            "performSceneBackgroundMaintenance",
        ]:
            assert_contains(self, app, needle)

        inactive_case = re.search(
            r"case \.inactive:(?P<body>.*?)case \.active:",
            app,
            re.S,
        )
        self.assertIsNotNone(inactive_case)
        self.assertNotIn("handleUnattendedMode", inactive_case.group("body"))

        scene_background = re.search(
            r"private func performSceneBackgroundMaintenance\(reason: String\) \{(?P<body>.*?)\n    \}",
            app,
            re.S,
        )
        self.assertIsNotNone(scene_background)
        self.assertNotIn("requestOfflineHistoricalSyncIfNeeded", scene_background.group("body"))
        assert_contains(self, scene_background.group("body"), "ble.flushLifecycleRealtimeState(reason: reason)")
        unattended_mode = re.search(
            r"func handleUnattendedMode\(rest: Int, maxHR: Int, reason: String\) \{(?P<body>.*?)\n    \}",
            ble,
            re.S,
        )
        self.assertIsNotNone(unattended_mode)
        self.assertNotIn("requestOfflineHistoricalSyncIfNeeded", unattended_mode.group("body"))

        scene_background_transition = re.search(
            r"func handleSceneBackgroundTransition\(reason: String, rest: Int, maxHR: Int\) \{(?P<body>.*?)\n    \}",
            ble,
            re.S,
        )
        self.assertIsNotNone(scene_background_transition)
        transition_body = scene_background_transition.group("body")
        assert_contains(self, transition_body, "flushLifecycleRealtimeState(reason: reason)")
        assert_contains(self, transition_body, "if longWearModeEnabled")
        assert_contains(self, transition_body, "startLongWearMode(rest: rest, maxHR: maxHR, reason: reason)")

        assert_contains(self, transition_body, "reassertHeartRateNotificationsIfConnected(reason: reason)")
        self.assertNotIn("cancelPeripheralConnection", transition_body)

        request_sync = re.search(
            r"func requestOfflineHistoricalSyncIfNeeded\(reason: String, force: Bool = false\) -> Bool \{(?P<body>.*?)\n    \}",
            ble,
            re.S,
        )
        self.assertIsNotNone(request_sync)
        request_body = request_sync.group("body")
        live_defer_index = request_body.find("longWearModeEnabled, let peripheral, peripheral.state == .connected")
        start_index = request_body.find("startOfflineHistoricalSync(reason: reason, force: force)")
        self.assertGreaterEqual(live_defer_index, 0)
        self.assertGreater(start_index, live_defer_index)
        assert_contains(self, request_body, "return false")

        start_sync = re.search(
            r"private func startOfflineHistoricalSync\(reason: String, force: Bool\) \{(?P<body>.*?)\n    \}",
            ble,
            re.S,
        )
        self.assertIsNotNone(start_sync)
        start_body = start_sync.group("body")
        late_defer_index = start_body.find("force || !longWearModeEnabled || peripheral.state != .connected")
        cancel_index = start_body.find("central.cancelPeripheralConnection(peripheral)")
        self.assertGreaterEqual(late_defer_index, 0)
        self.assertGreater(cancel_index, late_defer_index)

        assert_contains(self, ble, "currentSessionUsable: false")
        assert_contains(self, ble, "metricUsable: false")
        assert_contains(self, ble, "usabilityReason: \"provisional_historical_layout_old_or_unvalidated\"")

    def test_advanced_metrics_imu_decoder_is_research_gated(self):
        decoder = source(ROOT / "Atria" / "Atria" / "AtriaIMUDecoder.swift")
        steps = source(ROOT / "Atria" / "Atria" / "AtriaStrapStepResearch.swift")
        sleep = source(ROOT / "Atria" / "Atria" / "AtriaSleepWakeResearch.swift")
        ble = source(ROOT / "Atria" / "Atria" / "AtriaBLEManager.swift")
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")

        for needle in [
            "static func syntheticRestPayload",
            "static func syntheticShakePayload",
            "static func selfTestPassed() -> Bool",
            "abs(rest.meanMagnitudeG - 1.0) <= 0.05",
            "abs(shake.meanMagnitudeG - 2.0) <= 0.10",
            "gravityValidated ? \"gravity_validated\" : \"research_unvalidated\"",
        ]:
            assert_contains(self, decoder, needle)

        shared = source(ROOT / "Atria" / "Atria" / "AtriaSharedUIComponents.swift")
        collection = source(ROOT / "Atria" / "Atria" / "AtriaVitalsCollectionSections.swift")
        for needle in [
            "case research",
            "return \"Research\"",
            "return \"waveform.badge.magnifyingglass\"",
        ]:
            assert_contains(self, shared, needle)
        for needle in [
            "state: summary.frameCount > 0 ? .research : .learning",
            "state: summary.sampleRateHz == nil ? .learning : .research",
            "state: summary.layoutText == \"--\" ? .learning : .research",
            "state: summary.strapStepCount > 0 ? .research : .learning",
            "state: summary.sleepWakeText == \"--\" ? .learning : .research",
            "state: summary.probeFrameCount > 0 ? .research : .learning",
            "unit: summary.spo2CandidateFrames > 0 ? \"frames\" : nil",
            "unit: summary.skinTempCandidateFrames > 0 ? \"frames\" : nil",
            "footnote: \"Early signal; not a SpO2 value.\"",
            "footnote: \"Early signal; not body temperature.\"",
            "footnote: \"Sleep-only estimate; needs comparison data.\"",
            "Early sensor rows show evidence counts, not measurements.",
        ]:
            assert_contains(self, collection, needle)

        for needle in [
            "AtriaIMUDecoder.decode(payload: payload)",
            "recordIMUFeatures(decoded)",
            "ATRIADBG imu_candidate validated=%d validation_state=%@",
            "sample_rate_hz=%@",
            "metric_promotions=0 i16=%@",
            "imuSampleRateHzSum += Double(decoded.samples.count) / delta",
            "imuInferredScale = decoded.scale",
            "imuInferredEndian = decoded.endian.rawValue",
            "AtriaStrapStepResearch.estimate(samples: decoded.samples",
            "strap_steps_research=%d phone_step_agreement=%@",
            "AtriaSleepWakeResearch.classify(duration:",
            "imuValidationState = imuGravityValidatedFrameCount > 0 ? \"gravity_validated_research\" : \"research_unvalidated\"",
        ]:
            assert_contains(self, ble, needle)

        for needle in [
            "enum AtriaStrapStepResearch",
            "guard current >= 1.12",
            "refractorySamples",
            "static func agreement(strapSteps: Int, phoneSteps: Int?) -> Double?",
            "state: \"research_unvalidated\"",
        ]:
            assert_contains(self, steps, needle)

        for needle in [
            "enum AtriaSleepWakeResearch",
            "state: \"sleep_research\"",
            "state: \"wake_research\"",
            "confidence: \"research\"",
            "low_motion_low_hr",
        ]:
            assert_contains(self, sleep, needle)

        for needle in [
            "var imuSampleCount: Int? = nil",
            "var imuFrameCount: Int? = nil",
            "var imuSampleRateHz: Double? = nil",
            "var imuScale: Double? = nil",
            "var imuEndian: String? = nil",
            "var imuStillnessRatio: Double? = nil",
            "var imuMovementIntensity: Double? = nil",
            "var imuActivityBursts: Int? = nil",
            "var imuValidationState: String? = nil",
            "var strapStepResearchCount: Int? = nil",
            "var strapStepResearchAgreement: Double? = nil",
            "var strapStepResearchState: String? = nil",
            "var sleepWakeResearchState: String? = nil",
            "var sleepWakeResearchConfidence: String? = nil",
            "var sleepWakeResearchReason: String? = nil",
            "var sensorResearchProbeFrames: Int? = nil",
            "var spo2ResearchCandidateFrames: Int? = nil",
            "var skinTempResearchCandidateFrames: Int? = nil",
            "var activeCalories: Double? = nil",
            "var caloriesConfidence: String? = nil",
        ]:
            assert_contains(self, sessions, needle)

    def test_advanced_metrics_temp_spo2_probe_is_research_only(self):
        probe = source(ROOT / "Atria" / "Atria" / "AtriaResearchProbe.swift")
        ble = source(ROOT / "Atria" / "Atria" / "AtriaBLEManager.swift")
        healthkit = source(ROOT / "Atria" / "Atria" / "HealthKitExporter.swift")
        harness = source(ROOT / "live_device_debug.sh")
        analyzer = source(ROOT / "tools" / "analyze_sensor_research_probe.py")

        for needle in [
            "enum AtriaResearchProbe",
            "case metadata = \"0x31\"",
            "case historical = \"0x2f\"",
            "case diagnostic = \"61080007\"",
            "enum ModelGeneration",
            "case strapMG",
            "redactIdentifierLikeTokens",
            "(90...100).contains(value)",
            "(2_500...4_200).contains(value)",
            "oxygenOffsetSummary",
            "temperatureOffsetSummary",
            "modelGeneration(in: payload)",
        ]:
            assert_contains(self, probe, needle)

        for needle in [
            "case strap4",
            "case .strap4: return \"Strap 4.0\"",
            "case .strap4Class: return \"Strap\"",
            "guard supportsSpO2Probe || supportsSkinTempProbe else { return }",
            "AtriaResearchProbe.analyze(payload: payload, source: source)",
            "applyModelMetadataIfExplicit(summary)",
            "sensorResearchProbeFrames: researchProbeFrameCount > 0 ? researchProbeFrameCount : nil",
            "spo2ResearchCandidateFrames: researchProbeOxygenCandidateFrames > 0 ? researchProbeOxygenCandidateFrames : nil",
            "skinTempResearchCandidateFrames: researchProbeTemperatureCandidateFrames > 0 ? researchProbeTemperatureCandidateFrames : nil",
            "ATRIADBG model_gate status=metadata_explicit model=%@ evidence=%@ source=%@",
            "ATRIADBG sensor_research_probe source=%@ status=research_unvalidated",
            "model_generation=%@ model_evidence=%@",
            "metric_promotions=0 healthkit_write=0 raw_storage=0",
            "recordResearchProbeCandidate(payload: payload, source: .metadata)",
            "recordResearchProbeCandidate(payload: payload, source: .historical)",
            "recordResearchProbeCandidate(payload: [UInt8](data), source: .diagnostic)",
        ]:
            assert_contains(self, ble, needle)

        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")
        settings = source(ROOT / "Atria" / "Atria" / "AtriaSettingsView.swift")
        assert_contains(self, home, "strapModel: ble.strapModelLabel")
        assert_not_contains(self, home, "strapModel: ble.status == .connected ? ble.strapModelLabel : \"\"")
        assert_contains(self, settings, "LabeledContent(\"Model\")")
        assert_contains(self, settings, "Text(strapModel.isEmpty ? \"Strap\" : strapModel)")

        text = all_swift_source()
        assert_not_contains(self, text, ".oxygenSaturation")
        assert_not_contains(self, text, "HKQuantitySample(type: oxygen")

        for needle in [
            "\"sensor_research_probe_rows\": 0",
            "\"model_gate_assume_4_class_rows\": 0",
            "\"model_gate_metadata_explicit_rows\": 0",
            "\"metadata_0x31_frames\": 0",
            "\"metadata_0x31_lengths\": \"\"",
            "\"metadata_0x31_body_hashes\": \"\"",
            "ATRIADBG sensor_research_probe ",
            "ATRIADBG model_gate ",
            "tokens.get(\"spo2_candidate_frames\", \"\")",
            "tokens.get(\"model_evidence\", \"\")",
            "metadata_0x31_body_hashes[hashlib.sha256(payload).hexdigest()[:16]] += 1",
        ]:
            assert_contains(self, harness, needle)

        for needle in [
            "ATRIADBG sensor_research_probe ",
            "ATRIADBG frame ch=([0-9A-Fa-f-]+) len=(\\d+) hex=([0-9A-Fa-f]+)",
            "frame_61080005_types",
            "metadata_0x31_frames",
            "metadata_0x31_lengths",
            "metadata_0x31_body_hashes",
            "metadata_0x31_printable",
            "metadata_explicit_model_tokens",
            "hashlib.sha256(body).hexdigest()[:16]",
            "redact_identifier_like_tokens",
            "probe_sources",
            "model_generations",
            "spo2_top_offsets",
            "skin_temp_top_offsets",
            "metric_promotions",
            "healthkit_writes",
            "raw_storage",
            "research_only",
        ]:
            assert_contains(self, analyzer, needle)

    def test_self_induced_probe_markers_are_local_research_only(self):
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")
        collection = source(ROOT / "Atria" / "Atria" / "AtriaVitalsCollectionSections.swift")
        healthkit = source(ROOT / "Atria" / "Atria" / "HealthKitExporter.swift")

        for needle in [
            "struct ResearchManeuverMarker: Codable, Identifiable, Equatable",
            "case breathHold",
            "case heatExposure",
            "case coldExposure",
            "case walkTest",
            "static let key = \"atria.researchManeuverMarkers.v1\"",
            "var researchManeuverMarkers: [ResearchManeuverMarker]",
            "struct ResearchManeuverProbeCorrelationSummary: Equatable",
            "@Published private(set) var researchManeuverProbeCorrelationSummary",
            "private func recomputeCollectionResearchSummaries()",
            "researchManeuverProbeCorrelationSummary = ResearchManeuverProbeCorrelationSummary(markers: cachedResearchManeuverMarkers",
            "func markResearchManeuver(_ kind: ResearchManeuverMarker.Kind",
            "ATRIADBG research_maneuver_marker status=marked",
            "local_only=1 research_only=1 metric_promotions=0 healthkit_write=0 raw_storage=0",
            "static let correlationWindow: TimeInterval = 15 * 60",
            "guard (session.sensorResearchProbeFrames ?? 0) > 0 else { return false }",
            "marker.timestamp >= lower && marker.timestamp <= upper",
            "oxygenCandidateFrames",
            "temperatureCandidateFrames",
        ]:
            assert_contains(self, sessions, needle)

        for needle in [
            "researchManeuverCard",
            "AtriaResearchManeuverMarkerCard(markers: store.researchManeuverMarkers",
            "correlationSummary: store.researchManeuverProbeCorrelationSummary",
            "private struct AtriaResearchManeuverMarkerCard: View, Equatable",
            "AtriaPanelSectionHeader(title: \"Probe markers\", subtitle: \"\")",
            "ForEach(ResearchManeuverMarker.Kind.allCases)",
            ".atriaCardAction(prominent: false, tint: .teal)",
            "AtriaMetricTile(label: \"Probe match\"",
            "state: markers.isEmpty ? .learning : .research",
            "state: correlationSummary.matchedMarkers > 0 ? .research : .learning",
            "Markers stay on device and help compare probe timing.",
        ]:
            assert_contains(self, collection, needle)

        assert_not_contains(
            self,
            collection,
            "private var correlationSummary: ResearchManeuverProbeCorrelationSummary",
        )
        assert_not_contains(self, collection, "private struct ResearchManeuverProbeCorrelationSummary: Equatable")
        assert_not_contains(self, collection, "ResearchManeuverProbeCorrelationSummary(markers: store.researchManeuverMarkers")

        for forbidden in [
            "markResearchManeuver",
            "ResearchManeuverMarker",
            "researchManeuverMarkers",
        ]:
            assert_not_contains(self, healthkit, forbidden)

    def test_bp_ecg_are_fail_closed_on_strap4(self):
        settings = source(ROOT / "Atria" / "Atria" / "AtriaSettingsView.swift")
        healthkit = source(ROOT / "Atria" / "Atria" / "HealthKitExporter.swift")
        ble = source(ROOT / "Atria" / "Atria" / "AtriaBLEManager.swift")

        for needle in [
            "private var sensorAvailabilitySection: some View",
            "ECG unavailable",
            "WHOOP 4.0 has no electrodes.",
            "Blood pressure unavailable",
            "Requires a cuff-calibrated device.",
            "Blood oxygen research",
            "Sleep-only probe; no Health export.",
            "Body temperature research",
            "Skin-temp deviation only; no absolute degrees C or Health export.",
            "Atria shows only hardware-backed readings.",
        ]:
            assert_contains(self, settings, needle)

        for needle in [
            "var supportsECG: Bool { self == .strapMG }",
            "var supportsBloodPressure: Bool { self == .strapMG }",
            "var readTypes: Set<HKObjectType> = [heartRateType, stepCountType, bloodPressureSystolicType, bloodPressureDiastolicType]",
            "private func auditCuffBloodPressureReadAvailability(reason: String)",
            "auditBloodPressureComponentReadAvailability(type: bloodPressureSystolicType",
            "auditBloodPressureComponentReadAvailability(type: bloodPressureDiastolicType",
            "HKSampleQuery(sampleType: type",
            "ATRIADBG healthkit_cuff_bp_read status=%@",
            "source=healthkit_read write_bp=0 strap_bp=0 cuff_only=1",
            "auditCuffBloodPressureReadAvailability(reason: \"authorization_cached\")",
            "auditCuffBloodPressureReadAvailability(reason: \"authorization_granted\")",
            "auditCuffBloodPressureReadAvailability(reason: \"up_to_date\")",
        ]:
            assert_contains(self, ble + healthkit, needle)

        for forbidden in [
            "HKQuantitySample(type: bloodPressureSystolicType",
            "HKQuantitySample(type: bloodPressureDiastolicType",
            "AFib",
            "atrial fibrillation",
        ]:
            assert_not_contains(self, all_swift_source(), forbidden)

    def test_production_capture_defaults_land_on_balanced_profile(self):
        text = source(ROOT / "Atria" / "Atria" / "AtriaBLEManager.swift")

        for needle in [
            "case balanced",
            "case .balanced: return \"Balanced\"",
            "return .balanced",
            "defaults.removeObject(forKey: CollectionProfileDefaults.profile)",
            "collectionProfile = .balanced",
            "defaults.set(CollectionProfile.balanced.rawValue, forKey: CollectionProfileDefaults.profile)",
            "collectionProfile = CollectionProfile.load(defaults: defaults)",
        ]:
            assert_contains(self, text, needle)

    def test_production_capture_defaults_enable_protected_long_wear(self):
        text = source(ROOT / "Atria" / "Atria" / "AtriaBLEManager.swift")

        for needle in [
            "static let protectedLongWearMigrated",
            "defaults.set(true, forKey: CaptureDefaults.protectedLongWearMigrated)",
            "defaults.set(true, forKey: LongWearDefaults.enabled)",
            "defaults.set(true, forKey: RadioDefaults.standardHROnly)",
            "longWearModeEnabled = true",
            "standardHROnlyMode = true",
            "standardHROnlyEnabled = true",
            "recordRadioMode(\"standard_hr_only\", reason: \"protected_default\")",
            "mode=protected_long_wear_default",
            "long_wear_default=1",
            "standard_hr_only_default=1",
            "offline_sync_default=1",
            "protected_background_collection_default",
        ]:
            assert_contains(self, text, needle)

    def test_harness_classifies_untrusted_developer_profile_launch(self):
        text = source(ROOT / "live_device_debug.sh")

        for needle in [
            "launch_output_lines = []",
            "launch_output_lines.append(line)",
            "\"invalid code signature\" in launch_output",
            "\"profile has not been explicitly trusted\" in launch_output",
            "\"BSErrorCodeDescription = RequestDenied\" in launch_output",
            "HARNESS_ERROR=developer_profile_not_trusted",
            "HARNESS_NEXT_ACTION=trust_developer_profile_in_ios_settings_then_retry",
        ]:
            assert_contains(self, text, needle)

    def test_state_restoration_reuses_restored_peripheral(self):
        text = source(ROOT / "Atria" / "Atria" / "AtriaBLEManager.swift")

        for needle in [
            "private var pendingScanReason: String?",
            "pendingScanReason = reason",
            "let reason = pendingScanReason ?? \"central_powered_on\"",
            "ATRIADBG ble_restore status=reuse_restored reason=fresh_scan_deferred",
            "ATRIADBG ble_restore status=reuse_restored reason=standard_hr_only",
            "recordLinkObservedConnected(reason: \"state_restore_connected\"",
            "central.connect(restoredPeripheral, options: nil)",
        ]:
            assert_contains(self, text, needle)

        restore_method = re.search(
            r"nonisolated func centralManager\(_ central: CBCentralManager, willRestoreState dict: \[String: Any\]\) \{(?P<body>.*?)\n    \}",
            text,
            re.S,
        )
        self.assertIsNotNone(restore_method)
        body = restore_method.group("body")
        self.assertNotIn("cancelPeripheralConnection", body)
        self.assertNotIn("full_protocol_fresh_scan", body)

    def test_long_wear_keepalive_survives_app_switch(self):
        text = source(ROOT / "Atria" / "Atria" / "AtriaBLEManager.swift")

        for needle in [
            "enum KeepaliveDefaults",
            "private func ensureForegroundKeepaliveWatchdog(reason: String)",
            "ensureForegroundKeepaliveWatchdog(reason: \"scene_active\")",
            "ensureForegroundKeepaliveWatchdog(reason: reason)",
            "foreground_keepalive armed=1",
            "foreground_keepalive status=silent",
            "let initialSilenceTimeout: TimeInterval = 8",
            "let initialReconnectWindow: TimeInterval = 20",
        ]:
            assert_contains(self, text, needle)

        handle_unattended = re.search(
            r"func handleUnattendedMode\(rest: Int, maxHR: Int, reason: String\) \{(?P<body>.*?)\n    \}",
            text,
            re.S,
        )
        self.assertIsNotNone(handle_unattended)
        unattended_body = handle_unattended.group("body")
        assert_contains(self, unattended_body, "ensureForegroundKeepaliveWatchdog(reason: reason)")
        self.assertNotIn("stopForegroundKeepaliveWatchdog(reason: reason)\n        guard longWearModeEnabled", unattended_body)

        keepalive = re.search(
            r"private func startForegroundKeepaliveWatchdog\(reason: String\) \{(?P<body>.*?)\n    \}",
            text,
            re.S,
        )
        self.assertIsNotNone(keepalive)
        keepalive_body = keepalive.group("body")
        self.assertNotIn("guard foregroundInteractiveMode, longWearModeEnabled", keepalive_body)
        assert_contains(self, keepalive_body, "guard longWearModeEnabled else { continue }")
        assert_contains(self, keepalive_body, "let hasSeenPacket = lastRawHRNotificationAt != nil")
        assert_contains(self, keepalive_body, "let effectiveSilenceTimeout = hasSeenPacket ? silenceTimeout : initialSilenceTimeout")
        assert_contains(self, keepalive_body, "let reconnectWindow = hasSeenPacket ? silenceTimeout : initialReconnectWindow")

    def test_long_wear_disconnect_preserves_session_continuity(self):
        text = source(ROOT / "Atria" / "Atria" / "AtriaBLEManager.swift")

        for needle in [
            "private var userRequestedDisconnect = false",
            "userRequestedDisconnect = true",
            "let wasUserRequestedDisconnect = userRequestedDisconnect",
            "let shouldPreserveLongWearSession = longWearModeEnabled && !wasUserRequestedDisconnect",
            "persistActiveSessionJournalIfNeeded(reason: \"\\(reason)_continuity_checkpoint\", force: true)",
            "markRangeLossBackfillRequired(reason: \"long_wear_range_loss\")",
            "autoSaveStatus = session.isEmpty ? \"skipped_continuity_empty\" : \"checkpointed_continuity\"",
            "scheduleRangeLossBackfillIfNeeded(reason: \"did_connect\")",
            "scheduleRangeLossBackfillIfNeeded(reason: \"state_restore_connected\")",
            "preserveLongWearRangeLossRecovery(reason: \"foreground_keepalive\")",
            "preserveLongWearRangeLossRecovery(reason: \"no_data_watchdog\")",
            "preserveLongWearRangeLossRecovery(reason: \"accepted_hr_watchdog\")",
            "preserveLongWearRangeLossRecovery(reason: \"central_powered_off\")",
            "ATRIADBG ble_link status=disconnected reason=user_disconnect action=stay_disconnected",
        ]:
            assert_contains(self, text, needle)

        disconnect_handler = re.search(
            r"nonisolated func centralManager\(_ central: CBCentralManager,\s+didDisconnectPeripheral peripheral: CBPeripheral, error: Error\?\) \{(?P<body>.*?)\n    \}",
            text,
            re.S,
        )
        self.assertIsNotNone(disconnect_handler)
        body = disconnect_handler.group("body")
        preserve_index = body.find("if shouldPreserveLongWearSession")
        finish_index = body.find("finishSession(label:")
        reconnect_index = body.find("recordLinkAttempt(reason: \"did_disconnect_reconnect\"")
        self.assertGreaterEqual(preserve_index, 0)
        self.assertGreater(finish_index, preserve_index)
        self.assertGreater(reconnect_index, finish_index)

    def test_long_wear_auto_save_keeps_live_session_open(self):
        text = source(ROOT / "Atria" / "Atria" / "AtriaBLEManager.swift")

        auto_save = re.search(
            r"private func runLongWearSupervisorAutoSave\(index: Int, label: String, rest: Int, maxHR: Int\) -> Bool \{(?P<body>.*?)\n    \}",
            text,
            re.S,
        )
        self.assertIsNotNone(auto_save)
        body = auto_save.group("body")
        assert_not_contains(self, body, "finishSession(label: label)")
        assert_contains(self, body, "let saved = snapshot")
        assert_contains(self, body, "workout_auto_save_snapshot_supervisor")
        assert_contains(self, body, "mode=snapshot_keep_live")
        assert_contains(self, body, "return false")

    def test_live_sample_counters_flush_on_healthy_stream(self):
        text = source(ROOT / "Atria" / "Atria" / "AtriaBLEManager.swift")

        raw = re.search(
            r"private func recordRawHRNotification\(hr: Int, at sampleTime: Date\) \{(?P<body>.*?)\n    \}",
            text,
            re.S,
        )
        self.assertIsNotNone(raw)
        raw_body = raw.group("body")
        self.assertGreater(raw_body.find("sampleDiagnostics.rawNotifications += 1"), -1)
        self.assertGreater(raw_body.rfind("scheduleSampleDiagnosticsFlush()"), raw_body.find("lastRawHRNotificationAt = sampleTime"))

        accepted = re.search(
            r"private func recordAcceptedHRSample\(rate: Int, at sampleTime: Date\) \{(?P<body>.*?)\n    \}",
            text,
            re.S,
        )
        self.assertIsNotNone(accepted)
        accepted_body = accepted.group("body")
        self.assertGreater(accepted_body.find("sampleDiagnostics.acceptedSamples += 1"), -1)
        self.assertGreater(accepted_body.rfind("scheduleSampleDiagnosticsFlush()"), accepted_body.find("sampleDiagnostics.lastReason == \"accepted_gap\""))

        lifecycle = re.search(
            r"func flushLifecycleRealtimeState\(reason: String\) \{(?P<body>.*?)\n    \}",
            text,
            re.S,
        )
        self.assertIsNotNone(lifecycle)
        lifecycle_body = lifecycle.group("body")
        assert_contains(self, lifecycle_body, "flushSampleDiagnostics()")
        assert_contains(self, lifecycle_body, "flushActiveSessionJournal(reason: reason)")

    def test_healthkit_hrv_export_uses_validated_sdnn_only(self):
        text = source(ROOT / "Atria" / "Atria" / "HealthKitExporter.swift")

        for needle in [
            "private var hrvType",
            ".heartRateVariabilitySDNN",
            "if let sdnn = session.referenceValidatedSDNN, sdnn > 0",
        ]:
            assert_contains(self, text, needle)
        for needle in ["referenceValidatedRMSSD", "rmssdExported"]:
            assert_not_contains(self, text, needle)

    def test_healthkit_rhr_and_respiratory_rate_export_use_correct_types(self):
        text = source(ROOT / "Atria" / "Atria" / "HealthKitExporter.swift")

        for needle in [
            "private var restingHeartRateType",
            ".restingHeartRate",
            "private var respiratoryRateType",
            ".respiratoryRate",
            "session.restingStable > 0",
            "HKQuantitySample(type: restingHeartRateType",
            "let respiratoryRate = session.respiratoryRate",
            "HKQuantitySample(type: respiratoryRateType",
            "HKUnit.count().unitDivided(by: .minute())",
        ]:
            assert_contains(self, text, needle)

    def test_healthkit_step_count_is_read_only(self):
        text = source(ROOT / "Atria" / "Atria" / "HealthKitExporter.swift")

        for needle in [
            "private var stepCountType",
            ".stepCount",
            "var readTypes: Set<HKObjectType> = [heartRateType, stepCountType, bloodPressureSystolicType, bloodPressureDiastolicType]",
            "private func auditAppleStepCountReadAvailability(reason: String)",
            "HKStatisticsQuery(quantityType: stepCountType",
            "options: .cumulativeSum",
            "ATRIADBG healthkit_step_read status=%@",
            "source=healthkit_read write_steps=0",
            "auditAppleStepCountReadAvailability(reason: \"authorization_cached\")",
            "auditAppleStepCountReadAvailability(reason: \"authorization_granted\")",
            "auditAppleStepCountReadAvailability(reason: \"up_to_date\")",
        ]:
            assert_contains(self, text, needle)

        assert_not_contains(self, text, "HKQuantitySample(type: stepCountType")

    def test_healthkit_sleeping_wrist_temperature_is_read_only(self):
        text = source(ROOT / "Atria" / "Atria" / "HealthKitExporter.swift")
        app_text = all_swift_source()

        for needle in [
            "private var sleepingWristTemperatureType: HKQuantityType?",
            ".appleSleepingWristTemperature",
            "readTypes.insert(sleepingWristTemperatureType)",
            "private func auditSleepingWristTemperatureReadAvailability(reason: String)",
            "HKSampleQuery(sampleType: sleepingWristTemperatureType",
            "HKSampleSortIdentifierEndDate",
            "ATRIADBG healthkit_sleeping_wrist_temp_read status=%@",
            "source=healthkit_read write_temperature=0 baseline_only=1",
            "auditSleepingWristTemperatureReadAvailability(reason: \"authorization_cached\")",
            "auditSleepingWristTemperatureReadAvailability(reason: \"authorization_granted\")",
            "auditSleepingWristTemperatureReadAvailability(reason: \"up_to_date\")",
        ]:
            assert_contains(self, text, needle)

        for forbidden in [
            "HKQuantitySample(type: sleepingWristTemperatureType",
            "HKQuantitySample(type: bodyTemperature",
            ".bodyTemperature",
        ]:
            assert_not_contains(self, app_text, forbidden)

    def test_active_calories_are_persisted_as_estimates(self):
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")
        ble = source(ROOT / "Atria" / "Atria" / "AtriaBLEManager.swift")
        healthkit = source(ROOT / "Atria" / "Atria" / "HealthKitExporter.swift")

        for needle in [
            "var activeCalories: Double? = nil",
            "var caloriesConfidence: String? = nil",
        ]:
            assert_contains(self, sessions, needle)

        shared = source(ROOT / "Atria" / "Atria" / "AtriaSharedUIComponents.swift")
        overview = source(ROOT / "Atria" / "Atria" / "AtriaOverviewSections.swift")
        for needle in [
            "case estimate",
            "return \"Estimate\"",
            "return \"function\"",
        ]:
            assert_contains(self, shared, needle)
        assert_contains(self, overview, "detail: live.liveActiveCalories == nil ? \"Needs profile\" : \"Estimate\"")
        assert_not_contains(self, overview, "state: live.liveActiveCalories == nil ? .learning : .local")

        for needle in [
            "let activeCalories = Metrics.activeCalories(session",
            "let caloriesConfidence: String? = session.count > 1 ? (profile.hasEnergyProfile ? \"estimate\" : \"needs_profile\") : nil",
            "activeCalories: activeCalories",
            "caloriesConfidence: caloriesConfidence",
        ]:
            assert_contains(self, ble, needle)

        for needle in [
            "if session.caloriesConfidence == \"estimate\"",
            "let activeCalories = session.activeCalories",
            "return activeCalories",
            "if session.workoutReadiness(rest: rest, maxHR: maxHR).ready,\n               profile.hasEnergyProfile,\n               snapshot?.activeEnergyExported != true",
            "if snapshot?.activeEnergyExported != true,\n           session.workoutReadiness(rest: rest, maxHR: maxHR).ready,\n           let profile",
            "\"atria_metric_confidence\": \"estimate\"",
            "\"atria_metric_source\": \"keytel_2005_hr_energy\"",
        ]:
            assert_contains(self, healthkit, needle)

    def test_vo2max_fails_closed_until_confident(self):
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")
        healthkit = source(ROOT / "Atria" / "Atria" / "HealthKitExporter.swift")
        vitals = source(ROOT / "Atria" / "Atria" / "AtriaVitalsCollectionSections.swift")

        match = re.search(r"func vo2MaxEstimateSummary\(rest: Int, maxHR: Int\) -> VO2MaxEstimateSummary \{(?P<body>.*?)\n    \}", sessions, re.S)
        self.assertIsNotNone(match)
        body = match.group("body")
        for needle in [
            "guard rest > 0, maxHR > rest else",
            "guard restingSamples >= 7 else",
            "guard profile.maxHRSource == .measured else",
            "VO2MaxEstimateSummary(value: nil",
            "let rawEstimate = 15.3 * Double(maxHR) / Double(rest)",
            "let confidence = \"rough estimate\"",
            "let trend = vo2MaxTrendText(currentEstimate: boundedEstimate, maxHR: maxHR)",
            "trendText: trend.text",
            "trendDetail: trend.detail",
        ]:
            assert_contains(self, body, needle)
        self.assertGreater(body.find("let rawEstimate = 15.3"), body.find("guard profile.maxHRSource == .measured else"))
        assert_contains(self, sessions, "private func vo2MaxTrendText(currentEstimate: Double, maxHR: Int) -> (text: String, detail: String)")
        assert_contains(self, sessions, "let rests = restingTrend14.filter { $0 > 0 }")
        assert_contains(self, sessions, "guard rests.count >= 2, let oldestRest = rests.first else")
        assert_contains(self, sessions, "let previousEstimate = min(max(15.3 * Double(maxHR) / Double(oldestRest), 20), 80)")

        for needle in [
            "profile.maxHRSource == .measured",
            "restingBaselineSamples >= 7",
            "if !vo2MaxPlanned,\n               profile.maxHRSource == .measured,\n               restingBaselineSamples >= 7,\n               snapshot?.vo2MaxExported != true",
            "if snapshot?.vo2MaxExported != true,\n           let profile,\n           profile.maxHRSource == .measured,\n           restingBaselineSamples >= 7,\n           rest > 0,\n           maxHR > rest",
            "\"atria_metric_confidence\": \"rough_estimate\"",
            "\"atria_metric_source\": \"uth_sorensen_resting_hr\"",
        ]:
            assert_contains(self, healthkit, needle)

        for needle in [
            "AtriaMetricTile(label: \"VO2max\"",
            "state: vo2MaxEstimate.value == nil ? .learning : .estimate",
            "footnote: vo2MaxEstimate.confidence",
            "AtriaMetricTile(label: \"VO2 trend\"",
            "value: vo2MaxEstimate.trendText",
            "footnote: vo2MaxEstimate.trendDetail",
        ]:
            assert_contains(self, vitals, needle)
        assert_not_contains(self, vitals, "AtriaInlineQuickStat(label: \"VO2max\"")

    def test_validate_later_recovery_displays_personal_baseline_before_validation(self):
        text = source(ROOT / "Atria" / "Atria" / "Metrics.swift")
        overview = source(ROOT / "Atria" / "Atria" / "AtriaOverviewSections.swift")
        vitals = source(ROOT / "Atria" / "Atria" / "AtriaVitalsCollectionSections.swift")
        widget = source(ROOT / "Atria" / "Atria" / "WidgetSnapshot.swift")
        intents = source(ROOT / "Atria" / "Atria" / "AtriaAppIntents.swift")
        docs = "\n".join(source(path) for path in (ROOT / "docs").rglob("*.md"))

        for needle in [
            "case personalBaseline = \"personal baseline\"",
            "external reference validation upgrades the confidence tier",
            "but does not block in-app display",
            "hrvReferenceValidated ? .validated : .personalBaseline",
        ]:
            assert_contains(self, text, needle)

        for needle in [
            "let fallbackHRV = validatedHRV ?? store.latestLocalRMSSD",
            "fallbackRMSSD: fallbackHRV",
            "hrvReferenceValidated: validatedHRV != nil",
            "hrvState = recovery.confidence == .validated ? \"validated\" : \"personal_baseline\"",
        ]:
            assert_contains(self, widget, needle)

        for needle in [
            "private var recoveryState: AtriaMetricState",
            "case .personalBaseline:\n            return .personalBaseline",
            "case .unverified:\n            return .research",
            "state: recoveryState",
            "footnote: hero.recoveryEstimate.confidence.rawValue",
            "footnote: hero.hrvDetail",
        ]:
            assert_contains(self, overview + vitals, needle)

        assert_not_contains(self, overview + vitals, "state: hero.recoveryEstimate.percent == nil ? .learning : .validated")

        assert_contains(self, intents, "Read the latest local recovery, strain, and HRV snapshot.")
        assert_contains(self, intents, "snapshot.hrvRMSSD.map")

        for forbidden in [
            "all HRV metrics in\n  **learning** until an external RR/IBI reference passes",
            "blocked from display until an external RR reference passes",
            "show nothing until validated",
        ]:
            assert_not_contains(self, docs, forbidden)

    def test_local_native_feature_seams_are_present(self):
        text = all_swift_source()

        required = [
            "protocol AtriaCoachProvider",
            "AtriaLocalCoachProvider",
            "AtriaCloudCoachProvider",
            "enum AtriaCoachKeychain",
            "CXCallObserver",
            "import ActivityKit",
            "ControlWidget",
            "AppIntent",
        ]
        for needle in required:
            assert_contains(self, text, needle)

        # Atria must NEVER touch the user's music/audio (no AVAudioSession grab, no
        # system-music-player control). The media-control feature was removed on
        # purpose; these tokens must stay absent everywhere.
        for forbidden in [
            "MPMusicPlayerController.systemMusicPlayer",
            "beginGeneratingPlaybackNotifications",
            "AVAudioSession.sharedInstance().setActive(true",
        ]:
            assert_not_contains(self, text, forbidden)

    def test_haptic_alerts_are_phone_side_only(self):
        haptics = source(ROOT / "Atria" / "Atria" / "AtriaHapticAlerts.swift")

        for needle in [
            "import CallKit",
            "UINotificationFeedbackGenerator()",
            "UIImpactFeedbackGenerator",
            "Text(\"Phone haptics\")",
            "phone_side=1 strap_write=0",
        ]:
            assert_contains(self, haptics, needle)

        for forbidden in [
            "sendCommand(",
            "writeValue(",
            "CoreBluetooth",
            "CBPeripheral",
            "strap_side=1",
            "strap_write=1",
        ]:
            assert_not_contains(self, haptics, forbidden)

    def test_ai_coach_local_mode_is_explicitly_offline(self):
        text = source(ROOT / "Atria" / "Atria" / "AtriaAICoach.swift")

        for needle in [
            "enum AtriaCoachNetworkPolicy",
            "case offlineOnly",
            "case cloudDisabled",
            "let networkPolicy: AtriaCoachNetworkPolicy = .offlineOnly",
            "let networkPolicy: AtriaCoachNetworkPolicy = .cloudDisabled",
            "kSecAttrAccessibleWhenUnlockedThisDeviceOnly",
            "No data leaves this iPhone.",
            "Network requests stay disabled until a reviewed provider client is added.",
            "provider client pending",
        ]:
            assert_contains(self, text, needle)

        card = source(ROOT / "Atria" / "Atria" / "AtriaAICoachCard.swift")
        assert_contains(self, card, "does not send metrics until a reviewed")
        assert_contains(self, card, "Enable local mode for an offline summary")
        assert_contains(self, card, ".privacySensitive()")
        assert_contains(self, card, ".atriaCardAction(tint: .indigo)")
        assert_contains(self, card, ".atriaCardAction(prominent: false, tint: .gray)")
        assert_not_contains(self, card, ".buttonStyle(.glass")
        assert_not_contains(self, card, ".buttonStyle(.glassProminent")
        assert_not_contains(self, card, "sends selected local metrics")
        assert_not_contains(self, card, ".textContentType(.password)")

        for forbidden in [
            "import Network",
            "localModelEnabled",
            "URLSession",
            "URLRequest",
            ".resume()",
            "http://",
            "https://",
        ]:
            assert_not_contains(self, text, forbidden)

    def test_monetization_seam_exists_without_paywall_or_storekit(self):
        app_text = all_swift_source()
        entitlements = source(ROOT / "Atria" / "Atria" / "AtriaEntitlements.swift")

        for needle in [
            "struct AtriaEntitlements",
            "enum Feature",
            "enum Tier",
            "case paidApp",
            "case premium",
            "var tier: Tier = .paidApp",
            "var premiumOverrides: Set<Feature> = []",
            "EnvironmentValues",
            "atriaEntitlements",
        ]:
            assert_contains(self, entitlements, needle)

        for feature in [
            ".localMetrics",
            ".healthKitExport",
            ".backgroundCollection",
            ".liveActivity",
            ".mediaControls",
            ".hapticAlerts",
            ".aiCoachLocal",
            ".aiCoachCloud",
        ]:
            assert_contains(self, entitlements, feature)

        assert_contains(self, entitlements, "return true")
        assert_not_contains(self, entitlements, "return tier == .premium")
        assert_not_contains(self, entitlements, "premiumOverrides.contains")

        for forbidden in [
            "import StoreKit",
            "Product.products",
            "SubscriptionStoreView",
            "StoreView",
            "Purchase",
        ]:
            assert_not_contains(self, app_text, forbidden)

    def test_local_first_core_has_no_network_or_browser_clients(self):
        app_text = all_swift_source()

        for forbidden in [
            "URLSession",
            "URLRequest",
            "NSURLConnection",
            "import Network",
            "NWConnection",
            "http://",
            "https://",
            "WKWebView",
            "SFSafariViewController",
            "ASWebAuthenticationSession",
        ]:
            assert_not_contains(self, app_text, forbidden)

    def test_developer_only_surfaces_are_hidden_by_default(self):
        developer_mode = source(ROOT / "Atria" / "Atria" / "AtriaDeveloperMode.swift")
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")
        collection = source(ROOT / "Atria" / "Atria" / "AtriaVitalsCollectionSections.swift")
        content = source(ROOT / "Atria" / "Atria" / "ContentView.swift")
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")

        for needle in [
            "enum AtriaDeveloperMode",
            "defaultsKey = \"atria.developerMode.enabled\"",
            "launchArgument = \"--atria-developer-mode\"",
            "let enabledByLaunchArgument = ProcessInfo.processInfo.arguments.contains(launchArgument)",
            "UserDefaults.standard.removeObject(forKey: defaultsKey)",
            "return enabledByLaunchArgument",
        ]:
            assert_contains(self, developer_mode, needle)

        for needle in [
            "@State private var developerModeEnabled = AtriaDeveloperMode.isEnabled",
            "developerModeEnabled: developerModeEnabled",
        ]:
            assert_contains(self, home, needle)

        for needle in [
            "let developerModeEnabled: Bool",
            "captureCard\n                        researchSignalsCard\n                        if developerModeEnabled",
            "captureCard\n                    researchSignalsCard\n                    if developerModeEnabled",
            "if developerModeEnabled {\n                            rrReferenceCard",
            "if developerModeEnabled {\n                            rrReferenceCard\n                            hrReferenceCard\n                            imuAuditCard",
            "if developerModeEnabled {\n                    AtriaCollectionToggleCard",
            "title: \"Standard HR radio\"",
            "subtitle: \"Advanced compatibility mode for heart-rate-only collection.\"",
            "private var researchSignalsCard: some View",
            "AtriaCollectionResearchSignalsCard(summary: store.imuAuditSummary,",
            "sleepHistory: store.sleepHistorySnapshot",
            "private struct AtriaCollectionResearchSignalsCard: View, Equatable",
            "AtriaPanelSectionHeader(title: \"Sensor signals\", subtitle: \"\")",
            "AtriaMetricTile(label: \"Blood oxygen\"",
            "AtriaMetricTile(label: \"Body temp\"",
            "AtriaMetricTile(label: \"Resp rate\"",
            "AtriaMetricTile(label: \"Strap steps\"",
            "Early signal; not a SpO2 value.",
            "Early signal; not body temperature.",
            "Sleep-only estimate; needs comparison data.",
            "Early sensor rows show evidence counts, not measurements. Atria will not show SpO2 or body-temperature values until the sensor layout is proven against comparison data.",
            "private struct AtriaCollectionIMUAuditCard: View, Equatable",
            "AtriaPanelSectionHeader(title: \"IMU audit\", subtitle: \"\")",
            "Early motion signals stay separate until they match phone motion reliably.",
            ".lineLimit(2)",
            "AtriaMetricTile(label: \"Strap steps\"",
            "AtriaMetricTile(label: \"Sleep/wake\"",
            "AtriaMetricTile(label: \"Probes\"",
            "agreementText",
            "probeDetail",
            "AtriaCollectionIMUAuditCard(summary: store.imuAuditSummary)",
        ]:
            assert_contains(self, collection, needle)

        for needle in [
            "struct IMUAuditSummary: Equatable",
            "var respiratoryRateText: String",
            "@Published private(set) var imuAuditSummary",
            "private func recomputeCollectionResearchSummaries()",
            "imuAuditSummary = IMUAuditSummary(sessions: sessions)",
        ]:
            assert_contains(self, sessions, needle)

        assert_not_contains(
            self,
            collection,
            "private var summary: IMUAuditSummary",
        )
        assert_not_contains(self, collection, "private struct IMUAuditSummary: Equatable")
        assert_not_contains(self, collection, "IMUAuditSummary(sessions: store.sessions)")

        research_card = collection[
            collection.index("private struct AtriaCollectionResearchSignalsCard"):
            collection.index("private struct AtriaCollectionIMUAuditCard")
        ]
        for forbidden in [
            "dailyRollups(",
            "detectedActivity(",
            "aggregateSleepCandidates(",
            "IMUAuditSummary(sessions:",
            "SleepHistorySnapshot(rollups:",
        ]:
            assert_not_contains(self, research_card, forbidden)

        for forbidden in [
            "title: \"Low radio HR\"",
            "Developer option for standard heart-rate-only collection.",
            "subtitle: \"Native RR window and reference flow\"",
            "AtriaInlineQuickStat(label: \"Reference\"",
            "AtriaInlineQuickStat(label: \"RR package\"",
        ]:
            assert_not_contains(self, collection, forbidden)

        assert_contains(self, content, "let debugCompletesOnboarding = AtriaDeveloperMode.isEnabled")
        assert_contains(self, content, "&& ProcessInfo.processInfo.arguments.contains(\"--atria-complete-onboarding\")")
        assert_contains(self, sessions, "func completeOnboardingFromLaunchIfRequested")
        assert_contains(self, sessions, "guard AtriaDeveloperMode.isEnabled else { return }\n        guard arguments.contains(\"--atria-complete-onboarding\") else { return }")

    def test_live_activity_uses_end_user_reading_language(self):
        app_attributes = source(ROOT / "Atria" / "Atria" / "AtriaLiveActivityAttributes.swift")
        widget_attributes = source(ROOT / "Atria" / "AtriaWidget" / "AtriaLiveActivityAttributes.swift")
        coordinator = source(ROOT / "Atria" / "Atria" / "AtriaLiveActivityCoordinator.swift")
        widget = source(ROOT / "Atria" / "AtriaWidget" / "AtriaWidget.swift")
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")

        for text in [app_attributes, widget_attributes, coordinator]:
            assert_contains(self, text, "readingCount")
            assert_not_contains(self, text, "sampleCount")

        assert_contains(self, home, "readingCount: model.coreLiveStore.state.sessionSampleCount")
        assert_contains(self, widget, "context.state.readingCount")
        assert_contains(self, widget, "readings ·")
        assert_not_contains(self, widget, "samples ·")

    def test_standby_overlay_is_charging_landscape_and_metric_rich(self):
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")

        for needle in [
            "private func shouldShowStandBy(isLandscape: Bool) -> Bool",
            "guard isLandscape else { return false }",
            "guard model.coreLiveStore.state.status == .connected else { return false }",
            "guard batteryState == .charging || batteryState == .full else { return false }",
            "AtriaStandByOverlay(coreLiveStore: model.coreLiveStore,",
            "private struct AtriaStandByOverlay: View",
            "AtriaStandByMetric(title: \"Calories\"",
            "value: coreLiveStore.state.liveActiveCaloriesText",
            "detail: coreLiveStore.state.liveActiveCalories == nil ? \"Profile needed\" : \"Active estimate\"",
            "AtriaStandByMetric(title: \"Battery\"",
        ]:
            assert_contains(self, home, needle)

    def test_widget_snapshot_refreshes_from_live_bpm_on_safe_cadence(self):
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")
        widget_snapshot = source(ROOT / "Atria" / "Atria" / "WidgetSnapshot.swift")

        for needle in [
            "private static let liveWidgetSnapshotMinimumInterval: TimeInterval = 60",
            "@State private var lastLiveWidgetSnapshotAt: Date?",
            "publishLiveWidgetSnapshotIfNeeded()",
            "private func publishLiveWidgetSnapshotIfNeeded(now: Date = Date())",
            "guard scenePhase == .active else { return }",
            "guard model.pulseLiveStore.state.heartRate > 0 else { return }",
            "now.timeIntervalSince(lastLiveWidgetSnapshotAt) < Self.liveWidgetSnapshotMinimumInterval",
            "WidgetSnapshotPublisher.publish(store: store, ble: ble, reason: \"live_throttled\")",
        ]:
            assert_contains(self, home, needle)

        for needle in [
            "heartRate: ble.heartRate > 0 ? ble.heartRate : nil",
            "WidgetCenter.shared.reloadAllTimelines()",
        ]:
            assert_contains(self, widget_snapshot, needle)

    def test_widgets_deep_link_to_matching_tabs(self):
        plist = source(ROOT / "Atria" / "Info.plist")
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")
        widget = source(ROOT / "Atria" / "AtriaWidget" / "AtriaWidget.swift")

        for needle in [
            "<key>CFBundleURLTypes</key>",
            "<string>com.adidshaft.atria</string>",
            "<string>atria</string>",
        ]:
            assert_contains(self, plist, needle)

        for needle in [
            "var deepLinkPath: String",
            "static func deepLinkDestination(for url: URL) -> HomeTab?",
            "guard url.scheme?.lowercased() == \"atria\" else { return nil }",
            "case \"data\", \"collection\": return .collection",
            ".onOpenURL(perform: handleDeepLink)",
            "private func handleDeepLink(_ url: URL)",
            "selectedTab = tab",
            "model.loadDeferredDiagnosticsIfNeeded(reason: \"deeplink_\\(tab.deepLinkPath)\")",
            "ATRIADBG deeplink status=handled",
        ]:
            assert_contains(self, home, needle)

        for needle in [
            "private let atriaOverviewURL = URL(string: \"atria://tab/overview\")!",
            "private let atriaVitalsURL = URL(string: \"atria://tab/vitals\")!",
            ".widgetURL(atriaOverviewURL)",
            "var deepLinkURL: URL",
            "case .steps, .strain:",
            "return atriaOverviewURL",
            "case .hrv, .bpm:",
            "return atriaVitalsURL",
            ".widgetURL(metric.deepLinkURL)",
        ]:
            assert_contains(self, widget, needle)

    def test_home_screen_widgets_use_richer_small_and_medium_layouts(self):
        widget = source(ROOT / "Atria" / "AtriaWidget" / "AtriaWidget.swift")

        for needle in [
            "private var systemSmallWidget: some View",
            "private var systemMediumWidget: some View",
            "private var widgetHeader: some View",
            "private func compactMetric(_ title: String, value: String, icon: String, tint: Color) -> some View",
            "private func widgetMetricTile(_ title: String, value: String, icon: String, tint: Color) -> some View",
            "private struct AtriaWidgetRecoveryGauge: View",
            "AtriaWidgetRecoveryGauge(percent: entry.snapshot?.recoveryPercent)",
            ".frame(width: 72, height: 72)",
            ".frame(width: 92, height: 92)",
            "widgetMetricTile(\"Strain\"",
            "widgetMetricTile(\"BPM\"",
            "widgetMetricTile(\"HRV\"",
            "widgetMetricTile(\"Steps\"",
            ".accessibilityLabel(percent.map { \"Recovery \\($0) percent\" } ?? \"Recovery learning\")",
        ]:
            assert_contains(self, widget, needle)

        assert_not_contains(self, widget, "// Recovery + Strain are the headline pair.")

    def test_live_activity_updates_are_throttled_off_the_sample_hot_path(self):
        coordinator = source(ROOT / "Atria" / "Atria" / "AtriaLiveActivityCoordinator.swift")

        for needle in [
            "private var lastActivitySnapshot: Snapshot?",
            "private var lastActivityUpdateAt: Date?",
            "private var pendingActivityUpdateTask: Task<Void, Never>?",
            "private let minimumActivityUpdateInterval: TimeInterval = 15",
            "enqueueActivityUpdate(snapshot, now: now)",
            "shouldSendActivityUpdateImmediately",
            "nextActivityUpdateDelay",
            "pendingActivityUpdateTask?.cancel()",
        ]:
            assert_contains(self, coordinator, needle)

    def test_media_controller_is_inert_no_music_interference(self):
        # The media-control feature was removed so Atria never interferes with the
        # user's music (AirPods/speaker) or drains battery polling now-playing.
        # AtriaMediaController must be a no-op shell: no MediaPlayer import, no
        # system music player, no playback notifications, no polling loop.
        media = source(ROOT / "Atria" / "Atria" / "AtriaMediaControls.swift")

        for needle in [
            "final class AtriaMediaController",
            "var hasNowPlayingInfo = false",
            "func setRefreshLoopActive(_ active: Bool) {}",
        ]:
            assert_contains(self, media, needle)

        for forbidden in [
            "import MediaPlayer",
            "MPMusicPlayerController",
            "beginGeneratingPlaybackNotifications",
            "player.play()",
            "player.pause()",
            "skipToNextItem",
            "Task.sleep(nanoseconds: 10_000_000_000)",
        ]:
            assert_not_contains(self, media, forbidden)

    def test_deferred_home_diagnostics_do_not_overlap(self):
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")

        for needle in [
            "private var diagnosticsWorkInFlight = false",
            "guard !diagnosticsWorkInFlight else",
            "reason=refresh_in_flight",
            "diagnosticsWorkInFlight = true",
            "diagnosticsWorkInFlight = false",
            "Self.makeDeferredDetails(ble: self.ble, store: self.store)",
        ]:
            assert_contains(self, home, needle)

    def test_backdrop_respects_reduce_transparency(self):
        shell = source(ROOT / "Atria" / "Atria" / "AtriaHomeShellSupport.swift")
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")
        guide = source(ROOT / "Atria" / "Atria" / "AtriaHeroConnectionSections.swift")

        for needle in [
            "let reduceTransparency: Bool",
            "if reduceTransparency",
            "private var reducedTransparencyFill: Color",
        ]:
            assert_contains(self, shell, needle)

        assert_contains(self, home, "@Environment(\\.accessibilityReduceTransparency) private var reduceTransparency")
        assert_contains(self, home, "AtriaBackdropLayer(isDark: isDark, reduceTransparency: reduceTransparency)")
        assert_contains(self, guide, "@Environment(\\.accessibilityReduceTransparency) private var reduceTransparency")
        assert_contains(self, guide, "AtriaBackdropLayer(isDark: true, reduceTransparency: reduceTransparency)")

    def test_user_flow_animations_respect_reduce_motion(self):
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")
        overview = source(ROOT / "Atria" / "Atria" / "AtriaOverviewSections.swift")
        collection = source(ROOT / "Atria" / "Atria" / "AtriaVitalsCollectionSections.swift")
        content = source(ROOT / "Atria" / "Atria" / "ContentView.swift")
        heart_rate = source(ROOT / "Atria" / "Atria" / "HeartRate.swift")

        for text in [home, overview, collection, content, heart_rate]:
            assert_contains(self, text, "accessibilityReduceMotion")

        assert_contains(self, home, "private func performMotionAwareUpdate")
        assert_contains(self, home, "if reduceMotion")
        assert_contains(self, heart_rate, ".animation(reduceMotion ? nil")

    def test_section_render_paths_do_not_recompute_session_metrics(self):
        forbidden_calls = [
            ".sorted(",
            ".reduce(",
            ".compactMap(",
            "detectedActivity(",
            "dailyRollups(",
            "aggregateWorkoutCandidates(",
            "aggregateSleepCandidates(",
            "canonicalSessions(",
        ]

        for path in [
            ROOT / "Atria" / "Atria" / "AtriaOverviewSections.swift",
            ROOT / "Atria" / "Atria" / "AtriaVitalsCollectionSections.swift",
        ]:
            text = source(path)
            for start, block in swift_some_view_blocks(text):
                line = text.count("\n", 0, start) + 1
                for forbidden in forbidden_calls:
                    self.assertNotIn(
                        forbidden,
                        block,
                        f"{path.name}:{line} recomputes session metrics in a render path via {forbidden}",
                    )

    def test_end_user_copy_avoids_lab_only_language(self):
        content = source(ROOT / "Atria" / "Atria" / "ContentView.swift")
        hero = source(ROOT / "Atria" / "Atria" / "AtriaHeroConnectionSections.swift")
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")
        overview = source(ROOT / "Atria" / "Atria" / "AtriaOverviewSections.swift")
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")
        intents = source(ROOT / "Atria" / "Atria" / "AtriaAppIntents.swift")
        ble = source(ROOT / "Atria" / "Atria" / "AtriaBLEManager.swift")

        assert_contains(self, content, "The official strap app can reclaim the strap and fragment readings.")
        assert_contains(self, content, "Switch apps freely; don’t force quit.")
        assert_contains(self, hero, "Saved metrics and backup remain on device while Atria waits for the strap again.")
        assert_contains(self, hero, "Connection state: \\(context.userStatusLabel)")
        assert_contains(self, overview, "Saved metrics and backup remain available while the strap reconnects.")
        assert_contains(self, overview, "Saved insights prepare after the live connection settles.")
        assert_contains(self, overview, "AtriaLoadingPanel(title: \"Preparing saved insights\"")
        assert_contains(self, overview, "AtriaLoadingPanel(title: \"Preparing trends\"")
        assert_contains(self, overview, "AtriaInlineQuickStat(label: \"Personal baseline\"")
        assert_contains(self, overview, "AtriaInlineQuickStat(label: \"Baseline\"")
        assert_not_contains(self, overview, "AtriaInlineQuickStat(label: \"Validation\"")
        assert_contains(self, overview, "AtriaInlineQuickStat(label: \"HRV window\"")
        assert_contains(self, hero, "return \"Beat-to-beat window\"")
        assert_contains(self, home, "Checked HRV is ready.")
        assert_contains(self, home, "Beat-to-beat data is ready as personal-baseline HRV.")
        assert_contains(self, home, "Saved beat-to-beat data is ready while the strap reconnects.")
        assert_contains(self, home, "Beat-to-beat reference validated")
        assert_contains(self, home, "Heart-rate check passed")
        assert_contains(self, home, "Heart-rate check still pending")
        assert_contains(self, overview + hero + home, "Beat-to-beat")
        assert_contains(self, home, "baselineMaturityText(sampleCount:")
        assert_contains(self, home, "sleepValue: \"Preparing\"")
        assert_contains(self, home, "loggingText: \"settling\"")
        assert_contains(self, home, "Saved trends are preparing.")
        assert_contains(self, ble, "@Published var captureSummary = \"No backup yet\"")
        assert_contains(self, ble, "Personal baseline ready")
        assert_contains(self, ble, "Recording a clean heart-rate window")
        assert_contains(self, sessions, "Rest candidates are recovery context only; they do not count as sleep.")

        for text in [content, hero, home, overview, sessions, ble]:
            for forbidden in [
                "Not counted as workout until HR/reference evidence is stronger.",
                "saved RR package stays ready.",
                "external RR reference gates HRV, Recovery and Sleep metrics.",
                "\"RR window\"",
                "Reference-checked HRV is ready.",
                "The live RR window is ready as personal-baseline HRV.",
                "A clean RR window is ready as personal-baseline HRV.",
                "Atria keeps the live RR window light while the connection settles.",
                "Saved RR is ready while the strap reconnects.",
                "Saved references and backup remain available while the strap reconnects.",
                "Saved references and backup remain on device while Atria waits for the strap again.",
                "Rest candidates are diagnostic only; they do not count as sleep.",
                "Latest status:",
                "Loading saved insights",
                "Saved insights will finish loading",
                "Warming up trends",
                "Saved trends are loading.",
                "loggingText: \"warming up\"",
                "Validation-ready",
                "Not validation-ready",
                "No HR file selected",
                "HR reference validated",
                "HR reference still pending",
                "HR import failed",
            ]:
                assert_not_contains(self, text, forbidden)
        assert_not_contains(self, overview, "AtriaInlineQuickStat(label: \"Reference\"")
        assert_not_contains(self, overview, "AtriaInlineQuickStat(label: \"RR package\"")
        assert_contains(self, intents, "subtitle: \"Start live backup\"")
        assert_contains(self, intents, "subtitle: \"Arm overnight backup\"")
        assert_contains(self, intents, "shortTitle: \"Start backup\"")
        assert_contains(self, intents, "shortTitle: \"Stop backup\"")
        assert_not_contains(self, intents, "low-radio")

    def test_user_path_debug_logs_are_gated(self):
        for rel in [
            ROOT / "Atria" / "Atria" / "ContentView.swift",
            ROOT / "Atria" / "Atria" / "WidgetSnapshot.swift",
            ROOT / "Atria" / "Atria" / "AtriaHomeView.swift",
            ROOT / "Atria" / "Atria" / "AtriaOverviewSections.swift",
            ROOT / "Atria" / "Atria" / "AtriaVitalsCollectionSections.swift",
            ROOT / "Atria" / "Atria" / "HealthKitExporter.swift",
        ]:
            text = source(rel)
            assert_not_contains(self, text, "NSLog(\"ATRIADBG")

        assert_not_contains(self, all_swift_source(), "NSLog(\"ATRIADBG")
        debug_logging = source(ROOT / "Atria" / "Atria" / "AtriaDebugLogging.swift")
        assert_contains(self, debug_logging, "guard AtriaDebugLogging.isEnabled else { return }")
        assert_contains(self, debug_logging, "NSLogv(String(describing: format), pointer)")

    def test_diagnostic_notifications_are_not_production_active(self):
        notifications = source(ROOT / "Atria" / "Atria" / "LocalNotificationScheduler.swift")

        assert_contains(self, notifications, "private static let actionableBatteryThreshold = 20")
        assert_contains(self, notifications, "private static let actionableDiagnosisCooldown: TimeInterval = 6 * 60 * 60")
        assert_contains(self, notifications, "private static let actionableDiagnosisLastScheduledPrefix")
        assert_contains(self, notifications, "static let active = [recovery, strain, battery, bluetoothOff]")
        assert_contains(self, notifications, "static let diagnosticOnly = [diagnostic]")
        assert_contains(self, notifications, "static let removable = active + diagnosticOnly + legacy")
        assert_contains(self, notifications, "static func scheduleActionableConnectionDiagnosis(title: String,")
        assert_contains(self, notifications, "private static func actionableConnectionDiagnosisDecision(title: String,")
        assert_contains(self, notifications, "if pending.contains(where: { $0.identifier == decision.identifier })")
        assert_contains(self, notifications, "reason=pending_request")
        assert_contains(self, notifications, "reason=cooldown")
        assert_contains(self, notifications, "case \"Strap battery low\":")
        assert_contains(self, notifications, "case \"Bluetooth is off\", \"Bluetooth permission needed\":")
        assert_contains(self, notifications, "includeMetricDecisions: debugMetricRequest")
        assert_contains(self, notifications, "includeActionableConnectionDecisions: productionCadence || debugMetricRequest")
        assert_contains(self, notifications, "actionable_connection_decisions=%d")
        assert_contains(self, notifications, "monitor_actionable_connection_triggers")
        assert_contains(self, notifications, "private static func makeMetricDecisions(store: SessionStore,")
        assert_contains(self, notifications, "private static func makeActionableConnectionDecisions(ble: AtriaBLEManager) -> [NotificationDecision]")
        assert_contains(self, notifications, 'static let bluetoothOff = "atria.bluetooth.off"')
        assert_contains(self, notifications, 'kind: "bluetooth_off"')
        assert_contains(self, notifications, 'title: ble.bluetoothPermissionDenied ? "Bluetooth permission needed" : "Bluetooth is off"')
        assert_contains(self, notifications, 'body: ble.bluetoothPermissionDenied')
        assert_contains(self, notifications, 'Allow Bluetooth for Atria in Settings.')
        assert_contains(self, notifications, 'Turn on Bluetooth in Settings so Atria can read your strap.')
        assert_contains(self, notifications, "threshold=%d")
        assert_contains(self, notifications, "battery.level <= Self.actionableBatteryThreshold")
        assert_contains(self, notifications, 'body: "Charge your strap before a workout or overnight wear. Battery is \\(battery.level)%."')
        assert_contains(self, notifications, 'bluetooth_off=%d')
        assert_contains(self, notifications, "title: \"Atria notification test\"")
        assert_contains(self, notifications, "body: \"Local notification delivery is working.\"")
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")
        assert_contains(self, home, "LocalNotificationScheduler.scheduleActionableConnectionDiagnosis(title: next.title,")
        assert_contains(self, home, "if visibleConnectionDiagnosis != next")
        assert_not_contains(self, notifications, "static let active = [recovery, strain, battery, diagnostic]")
        assert_not_contains(self, notifications, "static let active = [recovery, strain, battery, bluetoothOff, diagnostic]")
        assert_not_contains(self, notifications, "includeMetricDecisions: productionCadence || debugMetricRequest")
        assert_not_contains(self, notifications, "monitor_confidence_gated_metric_triggers")
        assert_not_contains(self, notifications, "title: \"Atria diagnostic\"")

    def test_background_task_plumbing_is_present(self):
        app = source(ROOT / "Atria" / "Atria" / "AtriaApp.swift")
        plist = source(ROOT / "Atria" / "Info.plist")

        for needle in [
            "import BackgroundTasks",
            "BGTaskScheduler.shared.register",
            "BGAppRefreshTaskRequest",
            "BGProcessingTaskRequest",
            "requiresNetworkConnectivity = false",
            "UIApplication.shared.beginBackgroundTask",
            "ble.flushActiveSessionJournal(reason: reason)",
            "store.performBackgroundMaintenance(reason: reason)",
        ]:
            assert_contains(self, app, needle)

        for needle in [
            "BGTaskSchedulerPermittedIdentifiers",
            "com.adidshaft.atria.refresh",
            "com.adidshaft.atria.processing",
            "UIBackgroundModes",
            "bluetooth-central",
            "processing",
        ]:
            assert_contains(self, plist, needle)

    def test_non_disruptive_pull_handles_segmented_active_journal(self):
        script = source(ROOT / "pull_atria_state.sh")

        for needle in [
            "Documents/atria-active-session.segments",
            "active_journal_segments_status=ok",
            "def reconstructed_segmented_journal(evidence):",
            "active_journal_reconstructed_from_segments=1",
            "active_journal_final_status=ok",
            "active_journal_final_status=missing",
            "active_journal_continuity_status=",
            "active_journal_interruption_class=live_stream_interrupted_saved_sessions_present",
            "file_durability_status=saved_sessions_present",
            "file_durability_status=saved_sessions_preserved",
            "live_stream_consistency_status=interrupted_not_file_loss",
            "whoop_primary_data_source=saved_sessions_hr_rr",
        ]:
            assert_contains(self, script, needle)

        assert_not_contains(self, script, "active_journal_final_status=missing\\n' | tee -a \"$summary\"")
        parse_args = script.find("while [[ $# -gt 0 ]]; do")
        validate_device = script.find("Set ATRIA_DEVICE_ID or pass --device")
        self.assertGreaterEqual(parse_args, 0)
        self.assertGreater(validate_device, parse_args)

    def test_unsavable_active_journals_are_cleared_during_recovery(self):
        text = source(ROOT / "Atria" / "Atria" / "AtriaBLEManager.swift")

        for needle in [
            "private func clearUnsavableActiveJournalIfNeeded(reason: String) -> Bool",
            "session.count < 2",
            "status: \"cleared_unsavable\"",
            "action=drop_unsavable_stale_segment",
            "clearUnsavableActiveJournalIfNeeded(reason: \"no_data_watchdog_unsavable\")",
            "clearUnsavableActiveJournalIfNeeded(reason: \"hr_continuity_watchdog_unsavable\")",
            "clearUnsavableActiveJournalIfNeeded(reason: \"accepted_hr_watchdog_unsavable\")",
            "clearUnsavableActiveJournalIfNeeded(reason: \"disconnect_unsavable\")",
            "autoSaveStatus = \"cleared_unsavable\"",
        ]:
            assert_contains(self, text, needle)

    def test_phone_motion_remains_adjunct_to_whoop_primary_data(self):
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")
        ble = source(ROOT / "Atria" / "Atria" / "AtriaBLEManager.swift")
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")
        overview = source(ROOT / "Atria" / "Atria" / "AtriaOverviewSections.swift")
        pull = source(ROOT / "pull_atria_state.sh")

        for needle in [
            "Strap HR/RR remains primary, phone motion is adjunct only",
            "var phoneMotionValidatedValue: Bool { phoneMotionValidated == true }",
            "var phoneStepValidatedValue: Bool { phoneStepValidated == true }",
        ]:
            assert_contains(self, sessions, needle)

        for needle in [
            "phone_motion_validated=0 wrist_motion_validated=0",
            "source=phone_coremotion_audit_only",
            "action=activity_adjunct_only",
            "phoneStepValidated: phoneSteps.validated",
            "private func phoneMotionAuditSummary() -> (source: String, validated: Bool",
            "return (\"phone_coremotion_audit_only\", false",
            "private func phoneStepEvidenceSummary() -> (source: String, validated: Bool",
            "return (\"phone_coremotion_pedometer\", false",
        ]:
            assert_contains(self, ble, needle)

        for needle in [
            "var phoneMotionDetailText: String",
            "if let meters = phoneDistanceTodayMeters, meters >= 100",
            "parts.append(String(format: \"%.1f km\", meters / 1_000))",
            "if let floors = phoneFloorsToday, floors > 0",
        ]:
            assert_contains(self, home, needle)

        for needle in [
            "&& lhs.live.phoneMotionDetailText == rhs.live.phoneMotionDetailText",
            "detail: live.phoneMotionDetailText",
            "Steps counted by iPhone motion \\(live.phoneStepsText), \\(live.phoneMotionDetailText)",
        ]:
            assert_contains(self, overview, needle)

        assert_contains(self, pull, "whoop_primary_data_source=saved_sessions_hr_rr")
        assert_not_contains(self, sessions, "phone motion is primary")
        assert_not_contains(self, sessions, "phoneMotionValidated: true")
        assert_not_contains(self, sessions, "phoneStepValidated: true")


if __name__ == "__main__":
    unittest.main()
