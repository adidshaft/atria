#!/usr/bin/env python3
import math
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


def today_metric_defaults():
    overview = source(ROOT / "Atria" / "Atria" / "AtriaOverviewSections.swift")
    hidden_match = re.search(
        r"let metrics: \[AtriaTodayMetric\] = \[(?P<body>[^\]]+)\]",
        overview,
    )
    order_match = re.search(
        r"static var defaultGlanceOrder: \[AtriaTodayMetric\] \{\n        \[(?P<body>[^\]]+)\]",
        overview,
    )
    if not hidden_match or not order_match:
        raise AssertionError("Could not parse AtriaTodayMetric defaults")

    def parse_cases(body):
        return re.findall(r"\.([A-Za-z0-9_]+)", body)

    return parse_cases(hidden_match.group("body")), parse_cases(order_match.group("body"))


TODAY_NO_HIDDEN_SENTINEL = "__atria_all_today_cards_visible__"


def today_hidden_from_csv(csv):
    default_hidden, _ = today_metric_defaults()
    trimmed = csv.strip()
    if not trimmed:
        return set(default_hidden)
    if trimmed == TODAY_NO_HIDDEN_SENTINEL:
        return set()
    return {part for part in trimmed.split(",") if part}


def today_hidden_storage_value(hidden):
    return TODAY_NO_HIDDEN_SENTINEL if not hidden else ",".join(sorted(hidden))


def today_ordered(csv):
    _, default_order = today_metric_defaults()
    decoded = [part for part in csv.split(",") if part in default_order]
    result = []
    seen = set()
    for metric in decoded + default_order:
        if metric in default_order and metric not in seen:
            result.append(metric)
            seen.add(metric)
    return result


def today_visible_ordered(order_csv, hidden_csv):
    hidden = today_hidden_from_csv(hidden_csv)
    return [metric for metric in today_ordered(order_csv) if metric not in hidden]


def today_hidden_ordered(order_csv, hidden_csv):
    hidden = today_hidden_from_csv(hidden_csv)
    return [metric for metric in today_ordered(order_csv) if metric in hidden]


def today_moving_before(dragged, target, csv):
    ordered = today_ordered(csv)
    if dragged == target:
        return ",".join(ordered)
    order = [metric for metric in ordered if metric != dragged]
    try:
        index = order.index(target)
    except ValueError:
        index = len(order)
    order.insert(index, dragged)
    return ",".join(order)


def today_moving_direction(metric, direction, csv):
    order = today_ordered(csv)
    if metric not in order:
        return ",".join(order)
    index = order.index(metric)
    next_index = max(0, min(len(order) - 1, index + direction))
    if next_index != index:
        order[index], order[next_index] = order[next_index], order[index]
    return ",".join(order)


class HandoffStaticChecks(unittest.TestCase):
    def test_today_metric_persistence_model_handles_restore_reorder_and_bad_storage(self):
        default_hidden, default_order = today_metric_defaults()
        self.assertEqual(default_hidden, ["respiratoryRate", "strapSteps", "bloodOxygen", "bodyTemp"])
        self.assertEqual(default_order[0:4], ["recovery", "strain", "workout", "backfill"])
        self.assertEqual(default_order[-2:], ["trend", "insights"])
        self.assertEqual(len(default_order), len(set(default_order)))

        self.assertEqual(today_hidden_from_csv(""), set(default_hidden))
        self.assertEqual(today_hidden_from_csv(TODAY_NO_HIDDEN_SENTINEL), set())
        self.assertEqual(today_hidden_storage_value(set()), TODAY_NO_HIDDEN_SENTINEL)
        self.assertEqual(today_hidden_storage_value({"steps", "hrv"}), "hrv,steps")

        malformed = "steps,steps,notAMetric,hrv,recovery"
        ordered = today_ordered(malformed)
        self.assertEqual(ordered[0:3], ["steps", "hrv", "recovery"])
        self.assertEqual(len(ordered), len(default_order))
        self.assertEqual(set(ordered), set(default_order))

        hidden_csv = "hrv,steps,bodyTemp"
        self.assertNotIn("hrv", today_visible_ordered(malformed, hidden_csv))
        self.assertEqual(today_hidden_ordered(malformed, hidden_csv), ["steps", "hrv", "bodyTemp"])

        moved_hidden = today_moving_before("bodyTemp", "recovery", ",".join(default_order))
        self.assertEqual(today_hidden_ordered(moved_hidden, ""), ["bodyTemp", "respiratoryRate", "strapSteps", "bloodOxygen"])
        self.assertEqual(today_visible_ordered(moved_hidden, TODAY_NO_HIDDEN_SENTINEL)[0], "bodyTemp")

        self.assertEqual(today_ordered(today_moving_direction("recovery", -1, ",".join(default_order)))[0], "recovery")
        self.assertEqual(today_ordered(today_moving_direction("strain", -1, ",".join(default_order)))[0:2], ["strain", "recovery"])
        self.assertEqual(today_ordered(today_moving_direction("insights", 1, ",".join(default_order)))[-1], "insights")

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
            "struct AtriaGlassIconButtonStyle: ButtonStyle",
            "func atriaGlassIconAction(tint: Color = .blue, size: CGFloat = 38) -> some View",
            "self.buttonStyle(AtriaGlassIconButtonStyle(tint: tint, size: size))",
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
        shared_chrome = source(ROOT / "Atria" / "Atria" / "AtriaSharedChrome.swift")
        icon_style = re.search(
            r"struct AtriaGlassIconButtonStyle: ButtonStyle \{(?P<body>.*?)\n\}",
            shared_chrome,
            re.S,
        )
        self.assertIsNotNone(icon_style)
        self.assertNotIn(".glassEffect(", icon_style.group("body"))
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
            "coreLiveStore: model.coreLiveStore",
            ".toolbar(.hidden, for: .navigationBar)",
            "private static func liveHeartRate(ble: AtriaBLEManager) -> Int",
            "Date().timeIntervalSince(latest.t) <= 180",
            "ble.status == .connected,\n           let windowRate = ble.liveHeartWindow.sparkline.last(where: { $0 > 0 })",
            "ble.status == .connected,\n           let average = ble.liveHeartWindow.average",
            ".onTapGesture",
            "ble.startScan(reason: \"home_status_chip\")",
            "var bluetoothPermissionDenied: Bool",
            "bluetoothPermissionDenied: ble.bluetoothPermissionDenied",
            "private var bluetoothPermissionDenied: Bool { statusStore.state.bluetoothPermissionDenied }",
            "ble.$bluetoothPermissionDenied\n            .removeDuplicates()",
            "var hasPulseSignal: Bool { heartRate > 0 || hasContact }",
            "var sensorHasContact: Bool",
            "sensorHasContact: ble.hasContact",
            "var needsContactCoach: Bool { !hasPulseSignal && !sensorHasContact }",
            "var contactText: String { hasPulseSignal ? \"Live\" : \"No signal\" }",
            "hasContact: ble.hasContact || reconciledHeartRate > 0",
            "ble.$sessionSampleCount.removeDuplicates().map { _ in () }.eraseToAnyPublisher()",
            "private var displayStatus: AtriaBLEManager.Status",
            "guard hasPulseSignal else { return status }",
            "case .poweredOff:\n            return status",
            "case .connected, .connecting, .scanning, .disconnected:\n            return .connected",
            "if displayStatus != .connected { onTapWhenNotConnected() }",
            "return hasPulseSignal ? \"Live\" : \"No signal\"",
            "case .connecting: return \"Connecting\"",
            "case .scanning: return \"Searching\"",
            "case .poweredOff: return bluetoothPermissionDenied ? \"Permission\" : \"Bluetooth off\"",
            "case .poweredOff: return bluetoothPermissionDenied ? \"hand.raised.fill\" : \"bolt.slash.fill\"",
            "? \"Reconnecting…\"",
            ": \"Disconnected\"",
            "case .connected: return hasPulseSignal ? .green : .orange",
            "case .connecting: return .yellow",
            "case .scanning: return .cyan",
            "case .poweredOff: return .red",
            "case .disconnected: return .blue",
            "HStack(spacing: 5)",
            "private struct AtriaToolbarIcon: View, Equatable",
            "private struct AtriaHeaderActionButtonStyle: ButtonStyle",
            "private static let size: CGFloat = AtriaHeaderControlMetrics.height",
            "func makeBody(configuration: Configuration) -> some View",
            "AtriaGlassIconButtonStyle(tint: .secondary, size: Self.size)",
            "private struct AtriaHeaderBatteryIndicator: View",
            "@ObservedObject var liveStore: AtriaHomeModel.CoreLiveStore",
            "Image(systemName: liveStore.state.batterySymbol)",
            ".frame(width: AtriaHeaderControlMetrics.height,\n                   height: AtriaHeaderControlMetrics.height)",
            "accessibilityLabel(\"Strap battery \\(liveStore.state.batteryText), \\(liveStore.state.batteryChargeText).\")",
            "AtriaToolbarIcon(symbol: \"figure.run\")",
            "AtriaToolbarIcon(symbol: \"questionmark.circle\")",
            "AtriaToolbarIcon(symbol: \"clock.arrow.circlepath\")",
            "AtriaToolbarIcon(symbol: \"gearshape\")",
            ".buttonStyle(AtriaHeaderActionButtonStyle())",
            "HStack(spacing: AtriaHeaderControlMetrics.iconSpacing)",
            ".frame(height: AtriaHeaderControlMetrics.height, alignment: .center)",
            "private enum AtriaHeaderControlMetrics",
            "static let height: CGFloat = 44",
            "static let statusMinWidth: CGFloat = 152",
            "static let iconSpacing: CGFloat = 6",
            "minHeight: AtriaHeaderControlMetrics.height",
            "maxHeight: AtriaHeaderControlMetrics.height",
            "self.publishHeroPulse()\n                if self.prefersPulseSparklineUpdates",
            ".atriaChromeCapsule(tint: tint)",
            ".frame(minWidth: AtriaHeaderControlMetrics.statusMinWidth,\n               minHeight: AtriaHeaderControlMetrics.height,\n               maxHeight: AtriaHeaderControlMetrics.height)",
            "Heart rate is live; stress appears once HRV-grade beat-to-beat windows are ready.",
            "HRV-grade beat-to-beat data is ready as personal-baseline HRV.",
            "private static func hrvSettlingText(quality: String, liveHeartRate: Int) -> String",
            "guard liveHeartRate > 0 else { return quality }",
            "normalized.contains(\"stable contact\")",
            "normalized.contains(\"poor contact\")",
            "normalized.contains(\"poor_contact\")",
            "return \"HRV settling\"",
            "hrvSettlingText(quality: ble.hrvQuality,",
            "liveHeartRate: liveHeartRate(ble: ble))",
        ]:
            assert_contains(self, home, needle)

        for forbidden in [
            "ToolbarItem(placement: .topBarLeading)",
            "ToolbarItem(placement: .topBarTrailing)",
            "ble.startScan(reason: \"home_status_button\")",
            "case .connected: return \"Live/Connected\"",
            "case .connecting, .scanning: return \"Connecting...\"",
            "case .poweredOff, .disconnected: return \"Not Connected\"",
            ".atriaChromeCapsule(tint: .white)\n            .fixedSize()",
            "HStack(spacing: 0) {\n                if showWorkout",
            ".contentShape(Rectangle())",
            ".buttonStyle(.plain)\n                    .accessibilityLabel(\"Start workout\")",
            ".buttonStyle(.plain)\n                    .accessibilityLabel(\"Connection help\")",
            ".buttonStyle(.plain)\n                .accessibilityLabel(\"History\")",
            ".buttonStyle(.plain)\n                .accessibilityLabel(\"Settings\")",
            ".glassEffect(.regular.interactive(), in: .circle)",
            ".glassEffect(.regular.tint(tint.opacity",
            "private struct AtriaLiquidStatusPillBackground",
            "private var baseFill: AnyShapeStyle",
            "private var liquidWash: LinearGradient",
            ".fill(colorScheme == .dark ? Color.white.opacity(0.08) : Color.white.opacity(0.84))",
            "Capsule()\n                .fill(tint.opacity(colorScheme == .light ? 0.34 : 0.24))",
            ".shadow(color:",
            "case .connected where !pulse.hasContact:",
            "guard let self, self.prefersPulseSparklineUpdates else { return }\n                self.publishPulseLive()",
            "clean beat-to-beat",
            "Clean beat-to-beat",
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
            "private struct AtriaHeartRateChartSeries: Equatable",
            "let visiblePoints: [AtriaHomeModel.HeartRateChartPoint]",
            "let yDomain: ClosedRange<Int>",
            "static func make(points: [AtriaHomeModel.HeartRateChartPoint], zoom: Double) -> AtriaHeartRateChartSeries",
            "static func yDomain(for points: [AtriaHomeModel.HeartRateChartPoint]) -> ClosedRange<Int>",
            "func nearestPoint(to selectedTime: Date?) -> AtriaHomeModel.HeartRateChartPoint?",
            "@State private var series: AtriaHeartRateChartSeries",
            "_series = State(initialValue: AtriaHeartRateChartSeries.make(points: points, zoom: 1))",
            "AtriaHeartRateAxisChart(points: series.visiblePoints,",
            "yDomain: series.yDomain,",
            "series = AtriaHeartRateChartSeries.make(points: points, zoom: newValue)",
            "series = AtriaHeartRateChartSeries.make(points: newValue, zoom: zoom)",
            "private struct AtriaHeartRateAxisChart: View, Equatable",
            "let yDomain: ClosedRange<Int>",
            "lhs.points == rhs.points && lhs.yDomain == rhs.yDomain",
            "AreaMark(x: .value(\"Time\", point.t),\n                     yStart: .value(\"Visible floor\", yDomain.lowerBound),\n                     yEnd: .value(\"BPM\", point.bpm))",
            ".chartXAxis",
            ".chartYAxis",
            ".chartXSelection(value: $selectedTime)",
            ".contentShape(Rectangle())",
            ".compositingGroup()",
            ".clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))",
            ".clipped()",
            ".background(Color(.systemBackground).opacity(0.18), in: RoundedRectangle(cornerRadius: 12, style: .continuous))",
            ".mask(RoundedRectangle(cornerRadius: 12, style: .continuous))",
            ".clipShape(RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.inset, style: .continuous))",
            "Slider(value: $zoom, in: 1...6, step: 1)",
            "Label(\"Done\", systemImage: \"xmark\")",
            ".atriaCardAction(prominent: false, tint: .secondary)",
            ".fullScreenCover(isPresented: $showHeartRateExplorer)",
            "live.hasPulseSignal",
        ]:
            assert_contains(self, home + vitals, needle)
        assert_not_contains(self, vitals, "Button(\"Done\", action: onDismiss)")
        assert_not_contains(self, vitals, ".buttonStyle(.borderedProminent)")

        assert_contains(self, shared, "case conflict")
        assert_contains(self, shared, 'return "App conflict"')
        assert_contains(self, vitals, "officialAppCoexistenceRisk == .suspected ? .conflict : .local")
        assert_contains(self, hero, "let hasPulseSignal: Bool")
        assert_contains(self, hero, "let needsContactCoach: Bool")
        assert_contains(self, hero, 'AtriaHeroStatusTile(title: needsContactCoach ? "Fit check needed" : "Waiting for pulse"')
        assert_contains(self, hero, "Strap is connected; adjust fit so Atria can read pulse.")
        assert_contains(self, hero, "Waiting for the next live heart-rate sample.")
        assert_contains(self, hero, "needsContactCoach: pulseStore.state.needsContactCoach")
        assert_contains(self, home, "struct HeroPulseState: Equatable")
        assert_contains(self, home, "var hasPulseSignal: Bool { heartRate > 0 || hasContact }")
        assert_contains(self, home, "return HeroPulseState(heartRate: reconciledHeartRate,")
        assert_contains(self, home, "let windowRate = ble.liveHeartWindow.sparkline.last(where: { $0 > 0 })")
        assert_contains(self, home, "return windowRate")
        assert_contains(self, home, "ble.$sessionSampleCount.removeDuplicates().map { _ in () }.eraseToAnyPublisher()")
        assert_contains(self, source(ROOT / "Atria" / "Atria" / "AtriaBLEManager.swift"), "@Published private(set) var sessionSampleCount = 0")
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
            "static let noHiddenMetricsSentinel = \"__atria_all_today_cards_visible__\"",
            "static var defaultHiddenMetrics: Set<String>",
            "let metrics: [AtriaTodayMetric] = [.respiratoryRate, .strapSteps, .bloodOxygen, .bodyTemp]",
            "return Set(metrics.map(\\.rawValue))",
            "if trimmed.isEmpty { return defaultHiddenMetrics }",
            "if trimmed == noHiddenMetricsSentinel { return [] }",
            "static func hiddenStorageValue(for hidden: Set<String>) -> String",
            "hidden.isEmpty ? noHiddenMetricsSentinel : hidden.sorted().joined(separator: \",\")",
            "static var defaultGlanceOrder: [AtriaTodayMetric]",
            "static func visibleOrdered(orderCSV: String, hiddenCSV: String) -> [AtriaTodayMetric]",
            "static func hiddenOrdered(orderCSV: String, hiddenCSV: String) -> [AtriaTodayMetric]",
            "static func moving(_ dragged: AtriaTodayMetric, before target: AtriaTodayMetric, in csv: String) -> String",
            "fileprivate struct AtriaGlanceGridSize: Equatable",
            "static let compact = AtriaGlanceGridSize(rows: 1, columns: 1)",
            "static let wide = AtriaGlanceGridSize(rows: 1, columns: 2)",
            "var isWide: Bool { columns == 2 }",
            "var isValidGlanceShape: Bool",
            "rows == 1 && (columns == 1 || columns == 2)",
            "var storageValue: String",
            "static func storageSize(from raw: String) -> AtriaGlanceGridSize?",
            "fileprivate var defaultGlanceGridSize: AtriaGlanceGridSize",
            "case .sleepHistory, .trend, .insights:\n            return .wide",
            "static let sizeStorageKey = \"atria.overview.glanceSizeCSV\"",
            "static func sizeOverrides(from csv: String) -> [String: AtriaGlanceGridSize]",
            "static func sizeStorageValue(updating metric: AtriaTodayMetric,",
            "func glanceColumnSpan(sizeOverridesCSV: String) -> Int",
            "fileprivate func isWideGlanceCard(sizeOverridesCSV: String) -> Bool",
            "@AppStorage(AtriaTodayMetric.sizeStorageKey) private var sizeCSV: String = \"\"",
            "private func toggleMetricSize(_ metric: AtriaTodayMetric)",
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
            ".layoutPriority(metric.isWideGlanceCard(sizeOverridesCSV: sizeOverridesCSV) ? 2 : 1)",
            "GeometryReader { proxy in",
            "private func glanceCardCell(_ metric: AtriaTodayMetric, width: CGFloat) -> some View",
            "private func glanceCardWidth(for metric: AtriaTodayMetric, containerWidth: CGFloat) -> CGFloat",
            "let columnWidth = (containerWidth - Self.glanceGridSpacing) / CGFloat(Self.glanceGridColumnCount)",
            "glanceCardCell(metric,\n                                   width: glanceCardWidth(for: metric, containerWidth: proxy.size.width))",
            "private struct AtriaGlanceMetricCard: View, Equatable",
            "static let cardHeight: CGFloat = 152",
            "private static let headerHeight: CGFloat = 42",
            "private static let valueHeight: CGFloat = 38",
            "private struct AtriaGlanceMetricMarker: View, Equatable",
            "private static let size: CGFloat = 38",
            "private static let iconCircleSize: CGFloat = 26",
            "private static let iconSize: CGFloat = 14",
            "private static let footerHeight: CGFloat = 30",
            "private static let ringLineWidth: CGFloat = 3",
            "static var placeholder: some View",
            "private var hasProgressSignal: Bool",
            "title == \"Recovery\" || title == \"Strain\"",
            "private var clampedRingFraction: Double?",
            "AtriaGlanceMetricMarker(systemImage: systemImage,",
            "guard metric.glanceGridSize(sizeOverridesCSV: sizeOverridesCSV).isValidGlanceShape else { continue }",
            "return rows.filter(rowFitsGlanceGrid)",
            "private func rowFitsGlanceGrid(_ row: [AtriaTodayMetric]) -> Bool",
            "if row.count == 1, row.first?.isWideGlanceCard(sizeOverridesCSV: sizeOverridesCSV) == false",
            "AtriaGlanceMetricCard.placeholder",
            "if metric.isWideGlanceCard(sizeOverridesCSV: sizeOverridesCSV)",
            ".frame(maxWidth: .infinity, minHeight: Self.cardHeight, maxHeight: Self.cardHeight, alignment: .leading)",
            ".frame(width: Self.size, height: Self.size)",
            "private var ringEnd: Double",
            "progressFraction == nil ? 1 : clampedProgress",
            "private var markerRing: some View",
            "if progressFraction == nil",
            "Color.secondary.opacity(0.34)",
            "dash: [2.4, 6.2]",
            "StrokeStyle(lineWidth: Self.ringLineWidth, lineCap: .round)",
            "case .recovery: return \"gauge.with.dots.needle.67percent\"",
            "case .strain: return \"figure.run\"",
            "case .workout: return \"stopwatch.fill\"",
            "case .backfill: return \"arrow.triangle.2.circlepath\"",
            "case .hapticAlerts: return \"iphone.radiowaves.left.and.right\"",
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
            "case .bioAge: return \"figure.stand.line.dotted.figure.stand\"",
            "case .bloodOxygen: return \"drop.degreesign\"",
            "case .bodyTemp: return \"thermometer.variable\"",
            "case .insights: return \"sparkles\"",
            "case .hapticAlerts: return \"Alerts\"",
            "[.recovery, .strain, .workout, .backfill, .hapticAlerts, .hrv, .sleep, .sleepHistory, .sleepEfficiency, .rhr, .respiratoryRate, .steps, .strapSteps, .calories, .vo2max, .bioAge, .bloodOxygen, .bodyTemp, .trend, .insights]",
            "let profileMetricsStore: AtriaHomeModel.ProfileMetricsStore",
            "let hapticSettings: AtriaHapticAlertSettings",
            "@ObservedObject var profileMetricsStore: AtriaHomeModel.ProfileMetricsStore",
            "hapticSettings: hapticSettings",
            "vo2MaxEstimate: profileMetricsStore.state.vo2MaxEstimate",
            "biologicalAgeSummary: profileMetricsStore.state.biologicalAgeSummary",
            "let vo2MaxEstimate: VO2MaxEstimateSummary",
            "let biologicalAgeSummary: BiologicalAgeSummary",
            "&& lhs.hero.recoveryEstimate.confidence == rhs.hero.recoveryEstimate.confidence",
            "&& lhs.hero.recoveryEstimate.detail == rhs.hero.recoveryEstimate.detail",
            "&& lhs.hero.strain == rhs.hero.strain",
            "&& lhs.vo2MaxEstimate == rhs.vo2MaxEstimate",
            "&& lhs.biologicalAgeSummary == rhs.biologicalAgeSummary",
            "detail: recoveryDetailText",
            "private var recoveryDetailText: String",
            "case .validated:\n            return \"Validated\"",
            "case .personalBaseline:\n            return \"Personal baseline\"",
            "if hero.recoveryEstimate.detail.localizedCaseInsensitiveContains(\"HRV baseline\")",
            "return \"Building baseline\"",
            "detail: hrvDetailText",
            "private var hrvDetailText: String",
            "if detail.contains(\"validated\") { return \"Validated\" }",
            "if detail.contains(\"personal baseline\") || detail.contains(\"% kept\") { return \"Personal baseline\" }",
            "&& lhs.live.status == rhs.live.status",
            "&& lhs.live.sessionSampleCount == rhs.live.sessionSampleCount",
            "&& lhs.live.liveActiveCalories == rhs.live.liveActiveCalories",
            "&& lhs.hapticSettings == rhs.hapticSettings",
            "case .hapticAlerts:",
            "AtriaGlanceMetricCard(title: \"Alerts\"",
            "value: hapticSettings.glanceValueText",
            "detail: hapticSettings.glanceDetailText",
            "Phone haptic alerts \\(hapticSettings.glanceValueText)",
            "AtriaGlanceMetricCard(title: \"VO2max\"",
            "value: vo2MaxEstimate.value.map { String(format: \"%.1f\", $0) } ?? \"--\"",
            "detail: vo2MaxEstimate.value == nil ? \"Building\" : vo2MaxDetailText",
            "private var vo2MaxDetailText: String",
            "let confidence = vo2MaxEstimate.confidence.capitalized",
            "guard vo2MaxEstimate.trendText != \"Learning\" else { return confidence }",
            "return \"\\(confidence) · \\(vo2MaxEstimate.trendText)\"",
            "trend \\(vo2MaxEstimate.trendText), \\(vo2MaxEstimate.trendDetail)",
            "VO2max building from resting baseline and measured HR max",
            "case .bioAge:",
            "AtriaGlanceMetricCard(title: \"Body age\"",
            "value: biologicalAgeSummary.valueText",
            "Building your body-age baseline",
            "Biological age estimate",
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
            "private static let dragPayloadPrefix = \"atria.today.metric:\"",
            "fileprivate var dragPayload: String",
            "Self.dragPayloadPrefix + rawValue",
            "static func draggedMetric(from payload: String) -> AtriaTodayMetric?",
            "guard payload.hasPrefix(dragPayloadPrefix) else { return nil }",
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
            "AtriaSleepHistoryGlanceCard(snapshot: sleepHistory,\n                                            sleepGoalHours: sleepGoalHours)",
            "private struct AtriaSleepHistoryGlanceCard: View, Equatable",
            "Text(\"Sleep history\")",
            "return \"\\(latest.evidenceLabel) · debt \\(snapshot.sleepDebtText(goalHours: sleepGoalHours))\"",
            "if let latest, !latest.displayStageSegments.isEmpty",
            "AtriaSleepMiniHypnogram(segments: latest.displayStageSegments,",
            "private struct AtriaSleepMiniHypnogram: View, Equatable",
            "Canvas { context, size in",
            "width: min(width, max(0, size.width - x))",
            "AtriaSleepStageGlyph.color(for: segment.stage)",
            "Awake \\(latest.stageText(.awake))",
            "Open Vitals. Sleep history is building. Wear the strap overnight or during a nap.",
            "sleepHistory.averageFootnoteText",
            "snapshot.sleepConsistencyText",
            "snapshot.sleepDebtText(goalHours: sleepGoalHours)",
            "AtriaGlanceMetricCard(title: \"Resp rate\"",
            "value: sleepHistory.latest?.respiratoryRateText ?? \"--\"",
            "Sleep research",
            "detail: sleepHistory.latest?.respiratoryRate == nil ? \"Sleep research\" : \"Research\"",
            "Respiratory rate research sleep-only estimate",
            "AtriaGlanceMetricCard(title: \"Strap steps\"",
            "value: sensorSummary.strapStepText",
            "detail: sensorSummary.strapStepCount > 0 ? sensorSummary.agreementText : \"Research\"",
            "tint: strapStepsZone?.tint ?? (sensorSummary.strapStepCount > 0 ? .green : .orange)",
            "zone: strapStepsZone",
            "private var strapStepsZone: AtriaMetricZone?",
            "Metrics.stepsZone(sensorSummary.strapStepCount, goal: stepsGoal)",
            "title: \"Strap step research goal\"",
            "Strap-step agreement: \\(sensorSummary.agreementText)",
            "Strap steps remain research-tier until motion agreement is validated.",
            "Research strap-step estimate. \\(AtriaMetricZone.nonMedicalDisclaimer)",
            "Strap step research is waiting for validated motion evidence",
            "case .steps, .strapSteps:",
            "Adjust the daily step goal used by strap-step research while validation remains separate.",
            "AtriaGlanceMetricCard(title: \"Blood oxygen\"",
            "value: sensorSummary.spo2CandidateFrames > 0 ? \"Research\" : \"--\"",
            "detail: sensorSummary.spo2CandidateFrames > 0 ? \"\\(sensorSummary.spo2CandidateFrames) candidate frames\" : \"Sleep research\"",
            "not an SpO2 reading",
            "does not show an SpO2 percentage",
            "AtriaGlanceMetricCard(title: \"Body temp\"",
            "value: sensorSummary.skinTemperatureDeviation.isReady ? sensorSummary.skinTemperatureDeviation.valueText : \"--\"",
            "detail: sensorSummary.skinTemperatureDeviation.detailText",
            "relative deviation",
            "delta C from baseline",
            "does not show an absolute temperature",
            "insights: store.behaviorInsights",
            "taggedDays: store.behaviorJournalEntries.count",
            "let insights: [AtriaInsight]",
            "let taggedDays: Int",
            "AtriaPanelSectionHeader(title: \"Insights\", subtitle: \"What moves your HRV\")",
            "Atria learns what moves your HRV.",
            "let hiddenMetrics: [AtriaTodayMetric]",
            "let onShiftMetric: (AtriaTodayMetric, Int) -> Void",
            "let onHideMetric: (AtriaTodayMetric) -> Void",
            "let onShowMetric: (AtriaTodayMetric) -> Void",
            "let sizeOverridesCSV: String",
            "let onToggleMetricSize: (AtriaTodayMetric) -> Void",
            "@State private var isEditingGlance = false",
            "if isEditingGlance {\n                Button {",
            ".transition(.scale.combined(with: .opacity))",
            "withAnimation(.snappy(duration: 0.2)) {\n                                    isEditingGlance = false",
            ".accessibilityLabel(\"Finish editing widgets\")",
            "let onResetMetrics: () -> Void",
            "let onStartWorkout: () -> Void",
            "&& lhs.insights == rhs.insights",
            "&& lhs.hiddenMetrics == rhs.hiddenMetrics",
            "&& lhs.sizeOverridesCSV == rhs.sizeOverridesCSV",
            "AtriaGlanceMetricCard(title: \"Workout\"",
            "value: live.status == .connected ? \"Start\" : \"Connect\"",
            "detail: live.sessionSampleCount > 0 ? \"\\(live.sessionSampleCount) readings\" : \"Live mode\"",
            ".accessibilityLabel(live.status == .connected",
            "private var insightsCard: some View",
            "Button(action: onOpenInsights)",
            "AtriaGlanceMetricCard(title: \"Insights\"",
            "detail: topInsight?.tagLabel ?? (taggedDays > 0 ? \"Learning patterns\" : \"Tag today\")",
            "Open Trends. Insights building from \\(taggedDays) tagged days",
            ".draggable(metric.dragPayload)",
            ".dropDestination(for: String.self)",
            "AtriaTodayMetric.draggedMetric(from: raw)",
            "onMoveMetric(dragged, metric)",
            "let upLabel = Text(\"Move \\(metric.label) up\")",
            "let downLabel = Text(\"Move \\(metric.label) down\")",
            ".accessibilityAction(named: upLabel)",
            ".accessibilityAction(named: downLabel)",
            "onShiftMetric(metric, -1)",
            "onShiftMetric(metric, 1)",
            ".accessibilityAction(named: Text(\"Edit \\(metric.label) widget\"))",
            "if isEditingGlance && metric.supportsGlanceTargetEditing",
            ".contentShape(RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.inset,",
            ".accessibilityHidden(true)",
            ".accessibilityAction(named: Text(\"Edit \\(metric.label) target\"))",
            ".accessibilityAction(named: Text(metric.isWideGlanceCard(sizeOverridesCSV: sizeOverridesCSV)",
            "? \"Make \\(metric.label) compact\"",
            ": \"Make \\(metric.label) wide\"",
            ".accessibilityAction(named: Text(\"Remove \\(metric.label) widget\"))",
            ".accessibilityHint(\"Long press to edit, then tap to edit targets, drag to reorder, or use actions to resize and remove.\")",
            "private func hideMetric(_ metric: AtriaTodayMetric)",
            "private func showMetric(_ metric: AtriaTodayMetric)",
            "private func resetMetrics()",
            "hiddenCSV = AtriaTodayMetric.hiddenStorageValue(for: hidden)",
            "private var addWidgetMenu: some View",
            "Section(\"Add widget\")",
            "Image(systemName: \"plus\")",
            "glanceEditControls(for: metric)",
            "private func glanceEditControls(for metric: AtriaTodayMetric) -> some View",
            "@State private var targetEditorMetric: AtriaTodayMetric?",
            "if metric.supportsGlanceTargetEditing",
            "case .recovery, .strain, .hrv, .sleep, .sleepHistory, .sleepEfficiency, .rhr, .respiratoryRate, .steps, .strapSteps",
            "targetEditorMetric = metric",
            "Image(systemName: \"slider.horizontal.3\")",
            ".accessibilityLabel(\"Edit \\(metric.label) target\")",
            "AtriaGlanceTargetEditorSheet(metric: metric)",
            "case .sleep, .sleepHistory:",
            "Adjust the sleep goal used by sleep history, debt, and consistency.",
            "Image(systemName: \"xmark\")",
            "Image(systemName: metric.isWideGlanceCard(sizeOverridesCSV: sizeOverridesCSV)",
            "? \"rectangle.compress.horizontal\"",
            ": \"rectangle.expand.horizontal\"",
            "onToggleMetricSize(metric)",
            ".atriaGlassIconAction(tint: .secondary, size: 38)",
            ".atriaGlassIconAction(tint: .secondary, size: 30)",
            ".atriaGlassIconAction(tint: .red, size: 30)",
            ".accessibilityLabel(\"Add Today widget\")",
            ".accessibilityHint(hiddenMetrics.isEmpty",
            "\"Opens the list of hidden Today widgets.\"",
            "Menu {",
            "Button(role: .destructive)",
            ".clipShape(RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.inset, style: .continuous))",
            "private func shiftMetric(_ metric: AtriaTodayMetric, direction: Int)",
            ".sensoryFeedback(.selection, trigger: orderCSV)",
            ".sensoryFeedback(.selection, trigger: sizeCSV)",
        ]:
            assert_contains(self, overview, needle)

        assert_contains(self, home, "profileMetricsStore: model.profileMetricsStore")
        assert_contains(self, home, "onStartWorkout: {\n                                        workoutSession = AtriaWorkoutSession(start: Date())\n                                    }")

        assert_not_contains(self, overview, "LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 10)]")
        assert_not_contains(self, overview, "row.map(\\.glanceColumnSpan).reduce")
        assert_not_contains(self, overview, "precondition(metric.glanceGridSize.isValidGlanceShape")
        assert_not_contains(self, overview, "precondition(rowFitsGlanceGrid(row)")
        assert_not_contains(self, overview, "private var customizeMenu: some View")
        assert_not_contains(self, overview, "Label(isEditingGlance ? \"Done editing\" : \"Edit widgets\", systemImage: \"square.grid.2x2\")")
        assert_not_contains(self, overview, "Section(\"Hide widget\")")
        assert_not_contains(self, overview, ".background(Color(.systemBackground).opacity(0.82), in: Capsule(style: .continuous))")
        assert_not_contains(self, overview, "Label(\"Reset widgets\", systemImage: \"arrow.counterclockwise\")")
        assert_not_contains(self, overview, "figure.run.circle.fill")
        assert_not_contains(self, overview, "heart.text.square.fill")
        assert_not_contains(self, overview, "flame.circle.fill")
        assert_not_contains(self, overview, "detail: hrvLearningState == .learning ? \"Building\" : \"Baseline\"")
        assert_not_contains(self, overview, "private var hrvLearningState: AtriaMetricState")
        assert_not_contains(self, overview, "Label(\"Remove \\(metric.label)\", systemImage: \"minus.circle\")")
        assert_not_contains(self, overview, ".accessibilityLabel(\"Widget options for \\(metric.label)\")")
        assert_not_contains(self, overview, ".background(Color(.systemBackground).opacity(0.82), in: Circle())")
        assert_not_contains(self, overview, ".buttonStyle(.glass)")
        assert_not_contains(self, overview, ".buttonBorderShape(.circle)")
        assert_not_contains(self, overview, "degrees Celsius from baseline")

        for needle in [
            "@AppStorage(AtriaTodayMetric.orderStorageKey) private var todayOrderCSV = \"\"",
            "@AppStorage(AtriaTodayMetric.sizeStorageKey) private var todaySizeCSV = \"\"",
            "ForEach(AtriaTodayMetric.ordered(from: todayOrderCSV))",
            "private func canHideTodayMetric(_ metric: AtriaTodayMetric,",
            "AtriaTodayMetric.defaultGlanceOrder.filter { !activeHidden.contains($0.rawValue) }.count > 1",
            ".disabled(todayBinding(metric).wrappedValue && !canHideTodayMetric(metric))",
            "private func resetTodayLayout()",
            "todayOrderCSV = AtriaTodayMetric.defaultGlanceOrder.map(\\.rawValue).joined(separator: \",\")",
            "todayHiddenCSV = \"\"",
            "todaySizeCSV = \"\"",
            "todayHiddenCSV = AtriaTodayMetric.hiddenStorageValue(for: hidden)",
            "Label(\"Reset Today layout\", systemImage: \"arrow.counterclockwise\")",
            "AtriaTodayMetric.moving(metric, direction: -1, in: todayOrderCSV)",
            "AtriaTodayMetric.moving(metric, direction: 1, in: todayOrderCSV)",
            "Choose, reorder, and reset the cards shown at a glance.",
        ]:
            assert_contains(self, settings, needle)
        assert_not_contains(self, overview, "AtriaInsightsCardHost(store: store)")

        for needle in [
            "@AppStorage(AtriaVitalsSection.orderStorageKey) private var sectionOrderCSV = \"\"",
            "enum AtriaVitalsSection: String, CaseIterable, Identifiable",
            "static let orderStorageKey = \"atria.vitals.sectionOrderCSV\"",
            "private static let dragPayloadPrefix = \"atria.vitals.section:\"",
            "fileprivate var dragPayload: String",
            "static func draggedSection(from payload: String) -> AtriaVitalsSection?",
            "var label: String",
            "case .recoveryStrain: return \"Recovery and strain\"",
            ".draggable(section.dragPayload)",
            "AtriaVitalsSection.draggedSection(from: raw)",
            "AtriaVitalsSection.moving(dragged, before: section, in: sectionOrderCSV)",
            ".accessibilityAction(named: Text(\"Move \\(section.label) up\"))",
            ".accessibilityAction(named: Text(\"Move \\(section.label) down\"))",
            ".accessibilityHint(\"Drag to reorder this Vitals section, or use actions to move it.\")",
            "private func moveSection(_ section: AtriaVitalsSection, direction: Int)",
            "private var hasCustomVitalsLayout: Bool",
            "AtriaVitalsSection.ordered(from: sectionOrderCSV) != Array(AtriaVitalsSection.allCases)",
            "private func resetVitalsLayout()",
            "sectionOrderCSV = AtriaVitalsSection.allCases.map(\\.rawValue).joined(separator: \",\")",
            "Label(\"Reset Vitals layout\", systemImage: \"arrow.counterclockwise\")",
            ".accessibilityHint(\"Restores Pulse, HRV, Recovery and strain, and Profile to the default order.\")",
            ".sensoryFeedback(.selection, trigger: sectionOrderCSV)",
            "static func moving(_ section: AtriaVitalsSection, direction: Int, in csv: String) -> String",
            "func enumeratedColumn(_ column: Int) -> [AtriaVitalsSection]",
        ]:
            assert_contains(self, vitals, needle)

        assert_not_contains(self, overview, ".draggable(metric.rawValue)")
        assert_not_contains(self, overview, "let dragged = AtriaTodayMetric(rawValue: raw)")
        assert_not_contains(self, vitals, ".draggable(section.rawValue)")
        assert_not_contains(self, vitals, "let dragged = AtriaVitalsSection(rawValue: raw)")

    def test_handoff_21_connection_diagnosis_is_actionable_inline(self):
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")

        for needle in [
            "private struct AtriaConnectionDiagnosis: Equatable",
            "private static let lowBatteryThreshold = 20",
            "private static let pendingKnownReconnectActionAge: TimeInterval = 15",
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
            "private struct AtriaConnectionDiagnosisBanner: View, Equatable",
            ".atriaCardAction(prominent: false, tint: diagnosis.tint)",
            ".atriaInsetCard(tint: diagnosis.tint)",
            "guard elapsed >= Self.connectionDiagnosisPersistenceDelay else",
            "visibleConnectionDiagnosis = nil",
            "var showsImmediately: Bool",
            "title == \"Bluetooth is off\"",
            "title == \"Bluetooth permission needed\"",
            "title == \"Strap battery low\"",
            "var sendsLocalNotification: Bool",
            "next.sendsLocalNotification && visibleConnectionDiagnosis != next",
            "live.batteryLevel <= Self.lowBatteryThreshold",
            "live.batteryRecentlyDropping",
            "var bluetoothPermissionDenied: Bool",
            "bluetoothPermissionDenied: ble.bluetoothPermissionDenied",
            "private var bluetoothPermissionDenied: Bool { statusStore.state.bluetoothPermissionDenied }",
            "var officialAppCoexistenceRisk: AtriaBLEManager.OfficialAppCoexistenceRisk",
            "var batteryRecentlyDropping: Bool",
            "var lastScanRequestedAt: Date?",
            "var lastScanMatchAt: Date?",
            "var pendingKnownReconnectStartedAt: Date?",
            "var pendingKnownReconnectReason: String",
            "func pendingKnownReconnectAge(now: Date = Date()) -> TimeInterval?",
            "var needsRRQualityCoach: Bool { rrContinuityState == \"poor_contact\" }",
            "ble.$bluetoothPermissionDenied.removeDuplicates()",
            "ble.$batteryRecentlyDropping.removeDuplicates()",
            "ble.$officialAppCoexistenceRisk.removeDuplicates()",
            "ble.$lastScanRequestedAt.removeDuplicates()",
            "ble.$lastScanMatchAt.removeDuplicates()",
            "ble.$pendingKnownReconnectStartedAt.removeDuplicates()",
            "ble.$pendingKnownReconnectReason.removeDuplicates()",
            "live.bluetoothPermissionDenied",
            "batteryRecentlyDropping: ble.batteryRecentlyDropping",
            "officialAppCoexistenceRisk: ble.officialAppCoexistenceRisk",
            "lastScanRequestedAt: ble.lastScanRequestedAt",
            "lastScanMatchAt: ble.lastScanMatchAt",
            "pendingKnownReconnectStartedAt: ble.pendingKnownReconnectStartedAt",
            "pendingKnownReconnectReason: ble.pendingKnownReconnectReason",
            "case .connected where pulse.needsContactCoach:",
            "return AtriaConnectionDiagnosis(title: \"Fit check needed\"",
            "case .connected where live.needsRRQualityCoach && !pulse.hasPulseSignal:",
            "Beat-to-beat waiting",
            "Atria needs pulse before it can build HRV and Recovery.",
            "case .connected where live.needsRRQualityCoach && pulse.hasPulseSignal:",
            "HRV settling",
            "Heart rate is live. Keep wearing normally while HRV settles.",
            "case .connected where officialAppRiskActive && live.officialAppCoexistenceRisk == .suspected:",
            "WHOOP may interrupt",
            "Close or uninstall WHOOP if readings fragment.",
            "case .connected where officialAppRiskActive:",
            "WHOOP coexistence watch",
            "Atria is streaming; close WHOOP if drops return.",
            "let officialAppRiskActive = officialAppInstalled && live.officialAppCoexistenceRisk != .cleared",
            "let stalePairingSuspected = !officialAppInstalled && live.officialAppCoexistenceRisk == .suspected",
            "let pendingKnownReconnectAge = live.pendingKnownReconnectAge() ?? 0",
            "let pendingKnownReconnectActive = pendingKnownReconnectAge >= Self.pendingKnownReconnectActionAge",
            "case .scanning, .connecting:\n            if officialAppRiskActive",
            "Keep the strap nearby and close WHOOP if it keeps reclaiming it.",
            "Strap out of range",
            "Atria is still reconnecting to your saved strap. Bring it closer or keep wearing it.",
            "Atria is still waiting for your saved strap. Bring it closer or keep wearing it.",
            "Connection keeps dropping",
            "Stale Bluetooth pairing",
            "Forget the strap in Bluetooth, then reconnect.",
            "Turn on Bluetooth in Settings.",
            "Allow Bluetooth for Atria in Settings.",
            "Tighten the strap fit so Atria can read pulse.",
            "Bring your strap closer and keep it on your wrist.",
            "Charge your strap before a workout or overnight wear.",
            "Close or uninstall WHOOP if it keeps reclaiming the strap.",
            "forget it in Bluetooth and reconnect",
        ]:
            assert_contains(self, home, needle)
        assert_not_contains(self, home, "Connected, no pulse")
        diagnosis_banner = re.search(
            r"private struct AtriaConnectionDiagnosisBanner: View, Equatable \{(?P<body>.*?)\n\}",
            home,
            re.S,
        )
        self.assertIsNotNone(diagnosis_banner)
        self.assertNotIn(".buttonStyle(.glass", diagnosis_banner.group("body"))
        self.assertNotIn(".glassEffect(", diagnosis_banner.group("body"))

        diagnosis = re.search(
            r"static func derive\(live: AtriaHomeModel\.CoreLiveState,\n                       pulse: AtriaHomeModel\.PulseLiveState,\n                       officialAppInstalled: Bool\) -> AtriaConnectionDiagnosis\? \{(?P<body>.*?)\n    \}",
            home,
            re.S,
        )
        self.assertIsNotNone(diagnosis)
        diagnosis_body = diagnosis.group("body")
        powered_off_index = diagnosis_body.find("case .poweredOff:")
        low_battery_index = diagnosis_body.find("case _ where live.batteryLevel >= 0")
        contact_index = diagnosis_body.find("case .connected where pulse.needsContactCoach:")
        hrv_settling_index = diagnosis_body.find("case .connected where live.needsRRQualityCoach && pulse.hasPulseSignal:")
        self.assertGreaterEqual(powered_off_index, 0)
        self.assertGreaterEqual(contact_index, 0)
        self.assertGreaterEqual(hrv_settling_index, 0)
        self.assertGreater(low_battery_index, powered_off_index)
        self.assertGreater(low_battery_index, contact_index)
        self.assertGreater(low_battery_index, hrv_settling_index)

        ble = source(ROOT / "Atria" / "Atria" / "AtriaBLEManager.swift")
        for needle in [
            "@Published private(set) var bluetoothPermissionDenied = false",
            "@Published private(set) var batteryRecentlyDropping: Bool = false",
            "case .unauthorized:",
            "assignIfChanged(\\.bluetoothPermissionDenied, true)",
            "recomputeConnectionStatus(reason: \"central_unauthorized\")",
            "static let dropAt = \"atria.battery.dropAt\"",
            "static let dropDelta = \"atria.battery.dropDelta\"",
            "static func cachedBatteryDrop(maxAge: TimeInterval = 6 * 60 * 60) -> (recent: Bool, delta: Int, age: TimeInterval)",
            "battery_drop_recent=\\(drop.recent ? 1 : 0)",
            "assignIfChanged(\\.batteryRecentlyDropping, true)",
            "clearBatteryDropMarker()",
        ]:
            assert_contains(self, ble, needle)

        assert_not_contains(self, home, "showConnectionDiagnosisModal")
        assert_not_contains(self, home, "needsRRContactCoach")
        assert_not_contains(self, home, "Beat-to-beat signal weak")
        assert_not_contains(self, home, "Tighten the strap fit or wet the sensor")

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

    def test_strap_battery_charge_status_is_visible_and_honest(self):
        ble = source(ROOT / "Atria" / "Atria" / "AtriaBLEManager.swift")
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")
        live_activity = source(ROOT / "Atria" / "Atria" / "AtriaLiveActivityAttributes.swift")
        live_activity_widget_attrs = source(ROOT / "Atria" / "AtriaWidget" / "AtriaLiveActivityAttributes.swift")
        live_activity_coordinator = source(ROOT / "Atria" / "Atria" / "AtriaLiveActivityCoordinator.swift")
        overview = source(ROOT / "Atria" / "Atria" / "AtriaOverviewSections.swift")
        data = source(ROOT / "Atria" / "Atria" / "AtriaVitalsCollectionSections.swift")
        widget_snapshot = source(ROOT / "Atria" / "Atria" / "WidgetSnapshot.swift")
        widget = source(ROOT / "Atria" / "AtriaWidget" / "AtriaWidget.swift")

        for needle in [
            "enum BatteryChargeStatus: String, Equatable",
            "case levelOnly",
            "case charging",
            "case notCharging",
            "case full",
            "@Published var batteryChargeStatus: BatteryChargeStatus = .levelOnly",
            "static let chargeStatus = \"atria.battery.chargeStatus\"",
            "static let chargeAt = \"atria.battery.chargeAt\"",
            "static let batteryLevelStatus = CBUUID(string: \"2A1B\")",
            "return [UUIDs.batteryLevel, UUIDs.batteryLevelStatus]",
            "case UUIDs.heartRateMeasure, UUIDs.batteryLevel, UUIDs.batteryLevelStatus:",
            "peripheral.readValue(for: ch)",
            "if uuid == UUIDs.batteryLevelStatus",
            "parseBatteryChargeStatus(_ data: Data) -> BatteryChargeStatus?",
            "batteryPowerStateByte(fromBatteryLevelStatus: bytes)",
            "if bytes.count >= 3 { return bytes[2] }",
            "if bytes.count == 2, flags & 0x01 == 0 { return bytes[1] }",
            "let chargeState = (powerState >> 6) & 0x03",
            "if chargeState == 0x03 { return .charging }",
            "if chargeState == 0x02 { return .notCharging }",
            "wiredExternalPower == 0x03 || wirelessExternalPower == 0x03",
            "source=2A1B",
            "hydrateCachedBatteryStateIfFresh()",
            "private func hydrateCachedBatteryStateIfFresh(maxAge: TimeInterval = 86_400)",
            "batteryChargeStatus = cached.chargeStatus",
            "static func cachedBattery(maxAge: TimeInterval = 86_400) -> (level: Int, source: String, age: TimeInterval, chargeStatus: BatteryChargeStatus, chargeAge: TimeInterval, usable: Bool)",
            "BatteryChargeStatus(rawValue: rawCharge) ?? .levelOnly",
            "battery_charge_status=\\(battery.chargeStatus.rawValue)",
            "battery_charge_age_s=\\(chargeAgeText)",
            "let cachedBattery = Self.cachedBattery(maxAge: 10 * 60)",
            "cachedBattery.chargeStatus != .levelOnly",
            "assignIfChanged(\\.batteryChargeStatus, .levelOnly)",
            "delta > 0 && delta <= 5",
            "assignIfChanged(\\.batteryChargeStatus, .charging)",
            "assignIfChanged(\\.batteryChargeStatus, .notCharging)",
            "assignIfChanged(\\.batteryChargeStatus, .full)",
            "persistBatteryLevel(batteryLevel, source: \"live_2A19\", chargeStatus: batteryChargeStatus)",
            "persistBatteryChargeStatus(status, source: \"live_2A1B\")",
            "private func persistBatteryChargeStatus(_ status: BatteryChargeStatus, source: String)",
        ]:
            assert_contains(self, ble, needle)

        for needle in [
            "var batteryChargeStatus: AtriaBLEManager.BatteryChargeStatus",
            "var batteryChargeText: String",
            "var batteryChargeCompactText: String",
            "var batteryStatusSummaryText: String",
            "var batteryDetailText: String",
            "case .levelOnly: return \"State pending\"",
            "Battery level is live; waiting for charger-state signal",
            "return \"\\(batteryText) · \\(batteryChargeCompactText)\"",
            "ble.$batteryChargeStatus.removeDuplicates()",
            "batteryChargeStatus: ble.batteryChargeStatus",
            "Text(isInline ? liveStore.state.batteryChargeCompactText : liveStore.state.batteryChargeText)",
            "accessibilityLabel(\"Strap battery \\(liveStore.state.batteryText), \\(liveStore.state.batteryChargeText).\")",
            "value: coreLiveStore.state.batteryStatusSummaryText",
            "detail: coreLiveStore.state.batteryDetailText",
        ]:
            assert_contains(self, home, needle)

        for path in [live_activity, live_activity_widget_attrs]:
            for needle in [
                "var batteryChargeStatus: String",
                "var batteryChargeText: String",
            ]:
                assert_contains(self, path, needle)

        for needle in [
            "var batteryChargeStatus: AtriaBLEManager.BatteryChargeStatus",
            "batteryChargeStatus: snapshot.batteryChargeStatus.rawValue",
            "batteryChargeText: snapshot.batteryChargeStatus.label",
            "|| snapshot.batteryChargeStatus != lastActivitySnapshot.batteryChargeStatus",
            "batteryChargeStatus: model.coreLiveStore.state.batteryChargeStatus",
        ]:
            assert_contains(self, live_activity_coordinator + home, needle)

        for needle in [
            "value: live.batteryStatusSummaryText",
            "AtriaInlineQuickStat(label: \"Charge\"",
            "value: live.batteryChargeText",
            "detail: live.batteryChargeStatus == .levelOnly",
            "? \"Battery level is live; charger state pending\"",
            ": \"Current strap status\"",
            "footnote: coreLiveStore.state.batteryDetailText",
            "tint: coreLiveStore.state.batteryChargeStatus == .charging ? .green : .blue",
        ]:
            assert_contains(self, overview + data, needle)

        for needle in [
            "let batteryLevel: Int?",
            "let batteryChargeStatus: String?",
            "let batteryChargeText: String?",
            "batteryLevel: ble.batteryLevel >= 0 ? ble.batteryLevel : nil",
            "batteryChargeStatus: ble.batteryChargeStatus.rawValue",
            "batteryChargeText: ble.batteryChargeStatus.label",
            "battery=%@ charge=%@",
            "formatInt(snapshot.batteryLevel)",
        ]:
            assert_contains(self, widget_snapshot, needle)

        for needle in [
            "let batteryLevel: Int?",
            "let batteryChargeStatus: String?",
            "let batteryChargeText: String?",
            "if let battery = batteryHeaderText",
            "Label(battery, systemImage: batterySymbol)",
            "if snapshot.batteryChargeStatus == \"charging\" { return \"battery.100percent.bolt\" }",
            "case \"charging\", \"full\": return .green",
            "liveActivityBatteryText(for: context.state)",
            "liveActivityBatterySymbol(for: context.state)",
            "liveActivityBatteryTint(for: context.state)",
            "private func liveActivityBatteryText(for state: AtriaLiveActivityAttributes.ContentState) -> String",
            "return state.batteryChargeText.isEmpty ? \"\\(state.batteryLevel)%\" : \"\\(state.batteryLevel)% · \\(state.batteryChargeText)\"",
        ]:
            assert_contains(self, widget, needle)

    def test_handoff_21_historical_backfill_status_is_visible_and_fail_closed(self):
        archive = source(ROOT / "Atria" / "Atria" / "HistoricalArchive.swift")
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")
        collection = source(ROOT / "Atria" / "Atria" / "AtriaVitalsCollectionSections.swift")

        for needle in [
            "static let didUpdateNotification = Notification.Name(\"AtriaHistoricalArchiveDidUpdate\")",
            "static let relativePath = \"Documents/atria-historical/historical-archive.jsonl\"",
            "appendingPathComponent(\"atria-historical\", isDirectory: true)",
            "appendingPathComponent(\"whoop-historical\", isDirectory: true)",
            "if FileManager.default.fileExists(atPath: fileURL.path)",
            "return legacyFileURL",
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
            "return \"Gated\"",
            "return \"\\(rows) saved · metric gated\"",
            "var userFootnoteText: String",
            "return \"Backfill archived locally; HRV, Recovery and Sleep stay gated until historical RR is validated.\"",
            "return \"\\(metricUsableRows)/\\(rows) rows metric-ready.\"",
            "var metricGateText: String",
            "if metricReady { return \"Metric-ready\" }",
            "if hasArchiveRows { return \"Metric gated\" }",
            "metric_ready=%d fail_closed=%d status=%@ gate=%@ detail=%@",
            "status.hasArchiveRows && !status.metricReady ? 1 : 0",
            "status.metricGateText",
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
            "state: backfillState",
            "private var backfillState: AtriaMetricState",
            "if !store.historicalArchiveStatus.parseOK { return .conflict }",
            "if store.historicalArchiveStatus.metricReady { return .validated }",
            "if store.historicalArchiveStatus.hasArchiveRows { return .local }",
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
            "recoveryStrainVisuals",
            "AtriaMetricRing(label: \"Recovery\"",
            "AtriaMetricRing(label: \"Strain\"",
            "fraction: recoveryFraction",
            "fraction: strainFraction",
            "hero.loadSignalSummaryText",
            "private var recoveryFraction: Double?",
            "Double($0) / 100",
            "private var strainFraction: Double?",
            "hero.strain / 21",
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
        assert_contains(self, live_workout, "value: liveStore.state.liveActiveCaloriesText")
        assert_not_contains(self, live_workout, "liveStore.state.liveActiveCalories.map { \"\\($0)\" }")

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

    def test_confirmed_workouts_persist_rich_metrics_and_active_energy(self):
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")
        healthkit = source(ROOT / "Atria" / "Atria" / "HealthKitExporter.swift")

        for needle in [
            "var strain: Double? = nil",
            "var activeEnergyKilocalories: Double? = nil",
            "var activeEnergyConfidence: String? = nil",
            "var zoneSeconds: [String: TimeInterval]? = nil",
            "let enriched = confirmedWorkoutMetrics(start: bestStart,",
            "strain: enriched.strain",
            "activeEnergyKilocalories: enriched.activeEnergyKilocalories",
            "activeEnergyConfidence: enriched.activeEnergyConfidence",
            "zoneSeconds: enriched.zoneSeconds",
            "private func confirmedWorkoutMetrics(start: Date,",
            "Metrics.activeCalories(samples, rest: rest, profile: profile)",
            "Metrics.strain(fromTRIMP: trimp)",
            "AtriaAnalytics.Strain.maxHeartRateZoneSeconds(samples.map",
            "zoneSummary.isEmpty ? nil : zoneSummary.storage",
            "active_energy_kcal=%.0f",
            "zone_rest_s=%.0f",
        ]:
            assert_contains(self, sessions, needle)

        for needle in [
            "snapshot?.activeEnergyExported != true",
            "(workout.activeEnergyKilocalories ?? 0) > 0",
            "samples.append(contentsOf: confirmedWorkouts.compactMap { workout in",
            "return confirmedWorkoutActiveEnergySample(for: workout)",
            "metadata[\"atria_workout_strain\"] = strain",
            "metadata[\"atria_workout_active_energy_kcal\"] = activeEnergy",
            "metadata[\"atria_workout_active_energy_confidence\"] = workout.activeEnergyConfidence ?? \"estimate\"",
            "metadata[\"atria_workout_zone_\\(zone)_seconds\"] = seconds",
            "private func confirmedWorkoutActiveEnergySample(for workout: UserConfirmedWorkout) -> HKQuantitySample?",
            "HKQuantity(unit: .kilocalorie(), doubleValue: kilocalories)",
            "\"atria_metric_source\": \"keytel_hr_energy_estimate\"",
        ]:
            assert_contains(self, healthkit, needle)

    def test_session_detail_downsamples_once_for_render_perf(self):
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")
        insights = source(ROOT / "Atria" / "Atria" / "Insights.swift")

        for needle in [
            "struct SessionDetail: View",
            "private let displayedPoints: [SavedSession.Point]",
            "private let summary: SessionDetailSummary",
            "init(session: SavedSession)",
            "self.displayedPoints = Self.downsampledPoints(session.points)",
            "self.summary = SessionDetailSummary(session: session, maxHR: AthleteProfile.load().maxHR)",
            "private static func downsampledPoints",
            "Chart(Array(displayedPoints.enumerated()), id: \\.offset)",
            "private struct SessionDetailSummary",
            "let zoneRows: [TimeInZoneRow]",
            "let zoneTotal: Double",
            "TimeInZoneView(rows: summary.zoneRows, total: summary.zoneTotal)",
        ]:
            assert_contains(self, sessions, needle)

        for forbidden in [
            "private var displayedPoints: [SavedSession.Point] {\n        downsampledPoints(session.points)",
            "private var maxHR: Int { AthleteProfile.load().maxHR }",
            "Metrics.strain(fromTRIMP: session.trimp(rest: session.restingStable, max: maxHR))",
            "TimeInZoneView(session: session, maxHR: maxHR)",
        ]:
            assert_not_contains(self, sessions, forbidden)

        for needle in [
            "struct TimeInZoneRow: Identifiable",
            "let rows: [TimeInZoneRow]",
            "let total: Double",
            "ForEach(rows) { row in",
        ]:
            assert_contains(self, insights, needle)

        time_in_zone = re.search(
            r"struct TimeInZoneView: View \{(?P<body>.*?)\n\}",
            insights,
            re.S,
        )
        self.assertIsNotNone(time_in_zone)
        time_in_zone_body = time_in_zone.group("body")
        for forbidden in [
            "let session: SavedSession",
            "let maxHR: Int",
            "session.timeInZone",
            ".sorted",
            ".reduce",
        ]:
            assert_not_contains(self, time_in_zone_body, forbidden)

    def test_swiftui_render_blocks_do_not_run_session_derivations(self):
        forbidden = [
            ".sorted(",
            ".reduce(",
            ".compactMap(",
            "dailyRollups(",
            "detectedActivity(",
            "aggregateSleepCandidates(",
            "aggregateSleepDiagnostics(",
            "aggregateWorkoutCandidates(",
            "canonicalSessions(",
            "replaySavedWorkoutReadiness(",
            "makeHistorySnapshots(",
            "makeDeferredDetails(",
            "makeBehaviorCorrelationSummaries(",
            "behaviorCorrelationSummaries(",
            "logDeepDailyRollupDiagnostics(",
            "session.trimp(",
            "timeInZone(",
            "AthleteProfile.load()",
        ]
        checked = 0
        for rel in (ROOT / "Atria" / "Atria").rglob("*.swift"):
            for start, body in swift_some_view_blocks(source(rel)):
                checked += 1
                for needle in forbidden:
                    self.assertNotIn(needle, body, f"{rel}:{start} keeps {needle} in a some View render block")
        self.assertGreater(checked, 160)

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
            "let sourceSessions = sessions",
            "historySnapshot = HistorySnapshot.sessionsOnly(sourceSessions, maxHR: maxHR)",
            "DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.12)",
            "let snapshots = Self.makeHistorySnapshots(sessions: sourceSessions,",
            "private func publishFullHistorySnapshotIfCurrent(revision: Int,\n                                                     history: HistorySnapshot,\n                                                     sleep: SleepHistorySnapshot)",
            "historySnapshot = history",
            "sleepHistorySnapshot = sleep",
            "private nonisolated static func makeHistorySnapshots(sessions: [SavedSession],",
            "private nonisolated static func makeHistoryDailyRollups(sessions: [SavedSession],",
            "private nonisolated static func makeHistoryTrendSummaries(sessions: [SavedSession],",
            "anomalySource: \"bounded_history_rollups\"",
            "private var snapshot: HistorySnapshot {\n        store.historySnapshot\n    }",
            "struct HistorySnapshot",
            "let sessionRows: [HistorySessionRowSnapshot]",
            "let restingTrendPoints: [RestingTrendPoint]",
            "private static func makeRestingTrendPoints(_ sessions: [SavedSession]) -> [RestingTrendPoint]",
            "struct HistorySessionRowSnapshot: Identifiable",
            "struct SleepHistorySnapshot: Equatable",
            "static let empty = HistorySnapshot(sessions: [], detections: [], trends: [], rollups: [], maxHR: 200)",
            "static func sessionsOnly(_ sessions: [SavedSession], maxHR: Int) -> HistorySnapshot",
            "includeDerivedSessionRows: false",
            "HistorySessionRowSnapshot(session: $0,",
            "includeDerivedMetrics: includeDerivedSessionRows",
            "? Self.makeRestingTrendPoints(sessions)",
            ": []",
        ]:
            assert_contains(self, sessions, needle)

        refresh_start = sessions.index("private func refreshHistorySnapshotCache")
        refresh_end = sessions.index("private func refreshOverviewTrendPointsCache")
        refresh_source = sessions[refresh_start:refresh_end]
        for forbidden in [
            "dailyRollups(rest:",
            "detectedActivities(rest:",
            "trendSummaries(rest:",
            "await Task.yield()",
            "Task.sleep(nanoseconds: 120_000_000)",
        ]:
            assert_not_contains(self, refresh_source, forbidden)

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
            "ForEach(snapshot.sessions) { session in",
            "historySessionRow(session)",
            "session.avg",
            "session.peak",
            "session.resting",
            "session.points.count",
            "session.trimp(",
            "RestingTrendChart(sessions: snapshot.sessions,",
        ]:
            assert_not_contains(self, history_view_source, forbidden)

        insights = source(ROOT / "Atria" / "Atria" / "Insights.swift")
        chart = re.search(
            r"struct RestingTrendChart: View \{(?P<body>.*?)\n\}",
            insights,
            re.S,
        )
        self.assertIsNotNone(chart)
        chart_body = chart.group("body")
        for needle in [
            "let points: [RestingTrendPoint]",
            "ForEach(points) { point in",
            "point.resting",
        ]:
            assert_contains(self, chart_body, needle)
        for forbidden in [
            "let sessions: [SavedSession]",
            "sessions.sorted",
            "restingStable",
        ]:
            assert_not_contains(self, chart_body, forbidden)

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

    def test_launch_trend_diagnostics_use_snapshot_builder(self):
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")
        app = source(ROOT / "Atria" / "Atria" / "AtriaApp.swift")

        for needle in [
            "func logTrendSummariesFromLaunchIfRequested(arguments: [String] = ProcessInfo.processInfo.arguments)",
            'arguments.contains("--atria-log-trends")',
            'arguments.contains("--atria-log-trend-summaries")',
            "let sourceSessions = sessions",
            "DispatchQueue.global(qos: .utility).async",
            "let snapshots = Self.makeHistorySnapshots(sessions: sourceSessions,",
            "Self.logTrendSummaries(summaries: snapshots.history.trends,",
            "private nonisolated static func logTrendSummaries(summaries: [TrendSummary],",
            "private nonisolated static func trendAnomalyFlagsSnapshot(_ anomalies: [String]) -> String",
            "private nonisolated static func formatIntSnapshot(_ value: Int?) -> String",
            "private nonisolated static func formatDoubleSnapshot(_ value: Double?) -> String",
        ]:
            assert_contains(self, sessions, needle)

        logger = re.search(
            r"func logTrendSummariesFromLaunchIfRequested\(arguments: \[String\] = ProcessInfo\.processInfo\.arguments\) \{(?P<body>.*?)\n    \}",
            sessions,
            re.S,
        )
        self.assertIsNotNone(logger)
        body = logger.group("body")
        for needle in [
            'arguments.contains("--atria-log-trends")',
            'arguments.contains("--atria-log-trend-summaries")',
        ]:
            assert_contains(self, body, needle)
        for forbidden in [
            "trendSummaries(rest:",
            "dailyRollups(rest:",
            "detectedActivities(rest:",
        ]:
            assert_not_contains(self, body, forbidden)

        assert_contains(self, app, 'arguments.contains("--atria-log-trend-summaries")')
        assert_contains(self, app, "store.logTrendSummariesFromLaunchIfRequested(arguments: arguments)")

    def test_sleep_history_snapshot_is_cached_and_shown_in_vitals(self):
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")
        vitals = source(ROOT / "Atria" / "Atria" / "AtriaVitalsCollectionSections.swift")
        manual_sheet = source(ROOT / "Atria" / "Atria" / "AtriaManualSleepSheet.swift")
        sleep_research = source(ROOT / "Atria" / "Atria" / "AtriaSleepWakeResearch.swift")
        analytics = source(ROOT / "Atria" / "Atria" / "AtriaAnalytics.swift")

        for needle in [
            "struct SleepHistorySnapshot: Equatable",
            "struct Night: Identifiable, Equatable",
            "@Published private(set) var sleepHistorySnapshot = SleepHistorySnapshot.empty",
            "let start: Date?",
            "let end: Date?",
            "let sleep = SleepHistorySnapshot(rollups: rollups,",
            "confirmedSleeps: confirmedSleeps",
            "sleepHistorySnapshot = sleep",
            "let sleepDuration: TimeInterval?",
            "let sleepSpan: TimeInterval?",
            "let sleepStart: Date?",
            "let sleepEnd: Date?",
            "let sleepSource: String?",
            "let sleepEfficiency: Double?",
            "var sleepEfficiencyText: String",
            "var isNapEvidence: Bool",
            "if Self.explicitNapSources.contains(source) { return true }",
            "if Self.explicitSleepSources.contains(source) { return false }",
            "return !confirmed && duration <= AggregateSleepCandidate.napMaximumSpan",
            "private static let explicitNapSources: Set<String>",
            "\"manual_nap\"",
            "\"nap_candidate\"",
            "\"hr_only_nap\"",
            "private static let explicitSleepSources: Set<String>",
            "\"manual_sleep\"",
            "\"validated_sleep_window\"",
            "\"overnight_sleep\"",
            "\"sleep_candidate\"",
            "\"single_session_sleep_candidate\"",
            "\"incomplete_fragmented_sleep\"",
            'var evidenceLabel: String',
            'isNapEvidence ? "Nap" : "Sleep"',
            'var evidenceOnlyFootnote: String',
            'isNapEvidence ? "Nap-only estimate" : "Sleep-only estimate"',
            'var confirmationText: String',
            'return isNapEvidence ? "Nap candidate" : "Sleep candidate"',
            "let averageDurationText: String",
            "let evidenceCountText: String",
            "let averageFootnoteText: String",
            "let sleepConsistencyText: String",
            "let sleepConsistencyFootnote: String",
            "let sleepConsistencyPercent: Int?",
            "let recentSleepAverageDurationHours: Double?",
            "let recentSleepRecordCount: Int",
            "private static func makeEvidenceCountText(_ nights: [Night]) -> String",
            "let napCount = nights.filter(\\.isNapEvidence).count",
            'return "\\(nights.count) records"',
            'return nights.count == 1 ? "1 night" : "\\(nights.count) nights"',
            'self.averageFootnoteText = "Average across \\(self.evidenceCountText)"',
            "private static func makeSleepConsistency(_ nights: [Night]) -> (percent: Int?, text: String, footnote: String)",
            "private static func makeRecentSleepDebtBasis(_ nights: [Night]) -> (averageHours: Double?, recordCount: Int)",
            "self.recentSleepAverageDurationHours = debtBasis.averageHours",
            "self.recentSleepRecordCount = debtBasis.recordCount",
            "var emptyEvidenceLabel: String",
            '"Recent records"',
            "var emptyEvidenceValue: String",
            'return "Confirmed sleep or nap saved locally."',
            "var emptyEvidenceFootnote: String",
            "sleepEfficiency: Self.efficiency(duration: sleep.duration, span: sleep.span)",
            "start: sleep.start",
            "end: sleep.end",
            "let sleepStart = aggregateSleep?.start ?? sleepDetections.map(\\.start).min()",
            "let sleepEnd = aggregateSleep?.end ?? sleepDetections.map(\\.end).max()",
            "let sleepStart = sleepDetections.map(\\.start).min()",
            "let sleepEnd = sleepDetections.map(\\.end).max()",
            "sleepStart: sleepStart",
            "sleepEnd: sleepEnd",
            "start: rollup.sleepStart",
            "end: rollup.sleepEnd",
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
            "private struct IncompleteSleepFallback",
            "incompleteSleepFallback(in: recent,",
            'blocker: "sleep_fragmented_below_minimum"',
            'fallbackSource: "incomplete_fragmented_sleep"',
            "Fragmented overnight HR persisted below the sleep minimum",
            "AtriaVitalsRecoveryStrainCardHost(heroStore: heroStore,\n                                          store: store)",
            "AtriaRecoveryStrainCard(hero: heroStore.state,\n                                sleepHistory: store.sleepHistorySnapshot,",
            "onAddManualSleep: addManualSleep)",
            "private func addManualSleep(start: Date, end: Date, isNap: Bool)",
            "store.addManualSleep(start: start,",
            "enum SleepStageKind: String, Codable, CaseIterable, Identifiable",
            "case awake",
            "case light",
            "case sws",
            "case deep",
            "enum SleepStageEvidence: String, Codable, Equatable",
            "case manualEstimate",
            "case sensorResearch",
            "case validated",
            "case .none: return \"Stages not ready\"",
            "case .manualEstimate: return \"Manual estimate\"",
            "case .sensorResearch: return \"Research stages\"",
            "struct HeartSample: Equatable",
            "private struct EpochFeature: Equatable",
            "static func stageSegments(samples: [HeartSample],",
            "let epoch: TimeInterval = 30",
            "private static func epochFeatures(samples: [HeartSample],",
            "let shortSmoothHR = gaussianSmoothedHR(samples: samples, center: center, sigma: 120)",
            "let longSmoothHR = gaussianSmoothedHR(samples: samples, center: center, sigma: 600)",
            "differenceOfGaussians: shortSmoothHR - longSmoothHR",
            "localVariability: variability",
            "motionStillnessPrior: motionStillnessPrior",
            "private static func stage(feature: EpochFeature,",
            "feature.differenceOfGaussians",
            "feature.localVariability",
            "feature.motionStillnessPrior",
            "private static func gaussianSmoothedHR(samples: [HeartSample],",
            "private static func standardDeviation(_ values: [Double]) -> Double",
            "private static func merge(_ staged:",
            "struct SleepStageSegment: Codable, Identifiable, Equatable",
            "func addManualSleep(start: Date,",
            "source: String = \"manual_ui\") -> UserConfirmedSleep?",
            "let sleepSource = isNap ? \"manual_nap\" : \"manual_sleep\"",
            "confidence: \"manual_user_entered\"",
            "stageSegments: Self.defaultManualSleepStages(start: start,",
            "let stageSegments = sleepStageResearchSegments(start: best.start,",
            "stageSegments: stageSegments.isEmpty ? nil : stageSegments",
            "stage_research_segments=%d",
            "private func sleepStageResearchSegments(start: Date,",
            "AtriaSleepWakeResearch.HeartSample(t: t, bpm: point.bpm)",
            "AtriaSleepWakeResearch.stageSegments(samples: samples,",
            "let displayStageSegments: [SleepStageSegment]",
            "let stageEvidence: SleepStageEvidence",
            "let stageDurationsByStage: [SleepStageKind: TimeInterval]",
            "Self.stageEvidence(source: source,",
            "self.displayStageSegments = evidence == .none ? [] : stageSegments",
            "private static func stageEvidence(source: String,",
            "if source == \"validated_sleep_stages\"",
            "return .sensorResearch",
            "stageDurationsByStage[stage] ?? 0",
            "private static func stageDurations(from segments: [SleepStageSegment]) -> [SleepStageKind: TimeInterval]",
            "private struct AtriaSleepHistoryCard: View, Equatable",
            "AtriaSleepHistoryCard(snapshot: sleepHistory,",
            "let onAddManualSleep: (Date, Date, Bool) -> Void",
            "@State private var showManualSleepSheet = false",
            "Image(systemName: \"plus\")",
            ".atriaCardAction(prominent: false, tint: .cyan)",
            ".accessibilityLabel(\"Add sleep manually\")",
            "AtriaManualSleepSheet { start, end, isNap in",
            "@State private var typeWasManuallyEdited = false",
            "private var inferredIsNap: Bool",
            "AtriaAnalytics.ManualSleep.inferredIsNap(start: start,",
            "private var typeBinding: Binding<Bool>",
            "typeWasManuallyEdited = true",
            "private var typeSuggestionText: String",
            "\"Suggested by the window: \\(suggested). Your manual choice is kept.\"",
            "\"Atria suggested \\(suggested) from duration and time of day.\"",
            "Text(\"Sleep\").tag(false)",
            "Text(\"Nap\").tag(true)",
            "Picker(\"Type\", selection: typeBinding)",
            ".onAppear(perform: applyInferredTypeIfNeeded)",
            ".onChange(of: start) { _, _ in applyInferredTypeIfNeeded() }",
            ".onChange(of: end) { _, _ in applyInferredTypeIfNeeded() }",
            "private func applyInferredTypeIfNeeded()",
            "guard !typeWasManuallyEdited else { return }",
            "DatePicker(\"Start\"",
            "DatePicker(\"End\"",
            "private var canSave: Bool",
            "duration >= AggregateSleepCandidate.napMinimumDuration",
            "duration <= AggregateSleepCandidate.napMaximumSpan",
            "duration >= AggregateSleepCandidate.strictMinimumDuration",
            "Section(\"Duration\")",
            "LabeledContent(\"Window\")",
            "Text(validationText)",
            "\"Naps need at least 20 minutes.\"",
            "\"Longer than 3 hours should be saved as sleep.\"",
            "\"Sleep needs at least 3 hours.\"",
            ".disabled(!canSave)",
            "ForEach(SleepStageKind.allCases)",
            "AtriaSleepStageSummary(night: latest)",
            "AtriaMetricTile(label: \"Consistency\"",
            "value: snapshot.sleepConsistencyText",
            "private static func sleepDurationConsistencyPercent(_ nights: [Night]) -> Int?",
            "private static func sleepScheduleConsistencyPercent(_ nights: [Night]) -> Int?",
            "compactMap(Self.sleepMidpointTimeOfDaySeconds)",
            "private static func circularMeanAbsoluteDeviationHours(_ seconds: [TimeInterval]) -> Double",
            "Double(durationScore) * 0.55 + Double($0) * 0.45",
            '"sleep timing and duration"',
            "AtriaMetricTile(label: \"Debt\"",
            "value: snapshot.sleepDebtText(goalHours: sleepGoalHours)",
            "footnote: snapshot.sleepDebtFootnote(goalHours: sleepGoalHours)",
            "guard let averageHours = recentSleepAverageDurationHours, recentSleepRecordCount > 0 else { return nil }",
            "!latest.displayStageSegments.isEmpty",
            "private var heatStripNights: [SleepHistorySnapshot.Night]",
            "Array(snapshot.nights.prefix(84).reversed())",
            "AtriaSleepYearHeatStrip(nights: heatStripNights,",
            "private struct AtriaSleepYearHeatStrip: View, Equatable",
            "Canvas { context, size in",
            "drawCells(in: &context, size: size)",
            "let rows = 7",
            "Int(ceil(Double(nights.count) / Double(rows)))",
            "Sleep heat strip",
            "private struct AtriaSleepStageSummary: View, Equatable",
            "Text(night.stageEvidence.label)",
            "AtriaSleepStageHypnogram(segments: night.displayStageSegments,",
            "private struct AtriaSleepStageHypnogram: View, Equatable",
            "Canvas { context, size in",
            "drawGuides(in: &context, size: size)",
            "drawSegments(in: &context, size: size)",
            "private func stageY(_ stage: SleepStageKind, height: CGFloat) -> CGFloat",
            "width: min(width, max(0, size.width - x))",
            "Awake \\(night.stageText(.awake))",
            "Light \\(night.stageText(.light))",
            "SWS \\(night.stageText(.sws))",
            "Deep \\(night.stageText(.deep))",
            ".accessibilityLabel(\"\\(night.evidenceLabel) \\(night.stageEvidence.label). Awake \\(night.stageText(.awake)), Light \\(night.stageText(.light)), SWS \\(night.stageText(.sws)), Deep \\(night.stageText(.deep)).\")",
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
            "enum ManualSleep",
            "static func inferredIsNap(start: Date,",
            "currentSelection: Bool,",
            "calendar: Calendar = .current",
            "duration >= AggregateSleepCandidate.strictMinimumDuration",
            "let daytimeWindow = startHour >= 11 && endHour <= 20",
            "return daytimeWindow || duration < AggregateSleepCandidate.strictMinimumDuration",
        ]:
            assert_contains(self, sessions + vitals + manual_sheet + sleep_research + analytics, needle)

        overview = source(ROOT / "Atria" / "Atria" / "AtriaOverviewSections.swift")
        for needle in [
            "onAddManualSleep: addManualSleep",
            "source: \"manual_today_glance\"",
            "rest: store.baseline.restingInt ?? 60",
            "AtriaManualSleepSheet { start, end, isNap in",
            "showManualSleepSheet = false",
            "Image(systemName: \"moon.zzz.badge.plus\")",
            ".accessibilityLabel(\"Add sleep manually\")",
            "Text(latest?.stageEvidence.label ?? \"Stages not ready\")",
            "guard !latest.displayStageSegments.isEmpty else",
            "Consistency \\(snapshot.sleepConsistencyText)",
            "Debt \\(snapshot.sleepDebtText(goalHours: sleepGoalHours))",
            "Sleep debt \\(snapshot.sleepDebtText(goalHours: sleepGoalHours))",
        ]:
            assert_contains(self, overview, needle)

        assert_contains(self, vitals, "case pulse, hrv, recoveryStrain, profile")
        assert_not_contains(self, vitals, "case pulse, hrv, recoveryStrain, sleep")
        assert_not_contains(self, sessions, "estimatedStageSegments")
        assert_not_contains(self, sessions, "let resolvedSegments = stageSegments.isEmpty")
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

    def test_launch_activity_diagnostics_use_snapshot_builder(self):
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")

        logger = re.search(
            r"func logActivityDetectionsFromLaunchIfRequested\(arguments: \[String\] = ProcessInfo\.processInfo\.arguments\) \{(?P<body>.*?)\n    \}",
            sessions,
            re.S,
        )
        self.assertIsNotNone(logger)
        body = logger.group("body")
        for needle in [
            "let sourceSessions = sessions",
            "let confirmedWorkouts = cachedConfirmedWorkouts",
            "let confirmedSleeps = cachedConfirmedSleeps",
            "let baselineSnapshot = baseline",
            "DispatchQueue.global(qos: .utility).async",
            "let snapshots = Self.makeHistorySnapshots(sessions: sourceSessions,",
            "Self.logActivityDetections(detections: snapshots.history.detections,",
        ]:
            assert_contains(self, body, needle)
        for forbidden in [
            "detectedActivities(rest:",
            "aggregateWorkoutCandidates(",
            "dailyRollups(",
            "aggregateSleepCandidates(",
        ]:
            assert_not_contains(self, body, forbidden)

        for needle in [
            "private nonisolated static func logActivityDetections(detections: [ActivityDetection],",
            "private nonisolated static func kindRankSnapshot(_ kind: ActivityDetection.Kind) -> Int",
            "private nonisolated static func confidenceRankSnapshot(_ confidence: ActivityDetection.Confidence) -> Int",
        ]:
            assert_contains(self, sessions, needle)

    def test_launch_daily_rollup_diagnostics_use_snapshot_builder_by_default(self):
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")

        logger = re.search(
            r"func logDailyRollupsFromLaunchIfRequested\(arguments: \[String\] = ProcessInfo\.processInfo\.arguments\) \{(?P<body>.*?)\n    \}",
            sessions,
            re.S,
        )
        self.assertIsNotNone(logger)
        body = logger.group("body")
        for needle in [
            "let deepDiagnosticsRequested = arguments.contains(\"--atria-log-daily-rollups-deep\")",
            "guard arguments.contains(\"--atria-log-daily-rollups\") || deepDiagnosticsRequested else { return }",
            "let sourceSessions = sessions",
            "let confirmedWorkouts = cachedConfirmedWorkouts",
            "let confirmedSleeps = cachedConfirmedSleeps",
            "let baselineSnapshot = baseline",
            "guard deepDiagnosticsRequested else {",
            "DispatchQueue.global(qos: .utility).async",
            "let snapshots = Self.makeHistorySnapshots(sessions: sourceSessions,",
            "Self.logDailyRollups(rollups: snapshots.history.rollups,",
            "return",
            "logDeepDailyRollupDiagnostics(formatter: formatter, rest: rest)",
        ]:
            assert_contains(self, body, needle)

        fast_path = body.split("guard deepDiagnosticsRequested else {", 1)[1].split("\n        let rollups = dailyRollups", 1)[0]
        for forbidden in [
            "dailyRollups(rest:",
            "aggregateWorkoutCandidates(",
            "aggregateSleepDiagnostics(",
            "aggregateSleepCandidates(",
            "workoutReadiness(",
        ]:
            assert_not_contains(self, fast_path, forbidden)

        for needle in [
            "private nonisolated static func logDailyRollups(rollups: [DailyRollup],",
            "private func logDeepDailyRollupDiagnostics(formatter: DateFormatter, rest: Int)",
            "aggregateWorkoutCandidates(rest:",
            "aggregateSleepDiagnostics(rest:",
            "aggregateSleepCandidates(rest:",
        ]:
            assert_contains(self, sessions, needle)

        app = source(ROOT / "Atria" / "Atria" / "AtriaApp.swift")
        assert_contains(self, app, 'arguments.contains("--atria-log-daily-rollups-deep")')

    def test_launch_validation_flags_are_wired_to_deferred_diagnostics(self):
        app = source(ROOT / "Atria" / "Atria" / "AtriaApp.swift")
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")

        for needle in [
            'arguments.contains("--atria-verify-sleep")',
            'arguments.contains("--atria-schedule-sleep-validation")',
            'arguments.contains("--atria-verify-workout-label")',
            'arguments.contains("--atria-schedule-workout-validation")',
            "store.scheduleSleepValidationFromLaunchIfRequested(arguments: arguments)",
            "store.scheduleWorkoutValidationFromLaunchIfRequested(arguments: arguments)",
        ]:
            assert_contains(self, app, needle)

        sleep_scheduler = re.search(
            r"func scheduleSleepValidationFromLaunchIfRequested\(arguments: \[String\] = ProcessInfo\.processInfo\.arguments\) \{(?P<body>.*?)\n    \}",
            sessions,
            re.S,
        )
        self.assertIsNotNone(sleep_scheduler)
        sleep_body = sleep_scheduler.group("body")
        for needle in [
            'arguments.contains("--atria-verify-sleep") || arguments.contains("--atria-schedule-sleep-validation")',
            'value(after: "--atria-verify-sleep-label", in: arguments)',
            'doubleValue(after: "--atria-verify-sleep-after"',
        ]:
            assert_contains(self, sleep_body, needle)

        workout_scheduler = re.search(
            r"func scheduleWorkoutValidationFromLaunchIfRequested\(arguments: \[String\] = ProcessInfo\.processInfo\.arguments\) \{(?P<body>.*?)\n    \}",
            sessions,
            re.S,
        )
        self.assertIsNotNone(workout_scheduler)
        workout_body = workout_scheduler.group("body")
        for needle in [
            'arguments.contains("--atria-schedule-workout-validation")',
            'value(after: "--atria-verify-workout-label", in: arguments) != nil',
            'value(after: "--atria-verify-workout-label", in: arguments)',
            'doubleValue(after: "--atria-verify-workout-after"',
        ]:
            assert_contains(self, workout_body, needle)

    def test_launch_session_backup_flags_are_wired_to_store_guards(self):
        app = source(ROOT / "Atria" / "Atria" / "AtriaApp.swift")
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")

        for needle in [
            'store.restoreLatestSessionBackupFromLaunchIfRequested()',
            'arguments.contains("--atria-write-session-backup")',
            'arguments.contains("--atria-verify-session-backup")',
            "store.writeSessionBackupFromLaunchIfRequested(arguments: arguments)",
            "store.verifyLatestSessionBackupFromLaunchIfRequested(arguments: arguments)",
        ]:
            assert_contains(self, app, needle)

        write_backup = re.search(
            r"func writeSessionBackupFromLaunchIfRequested\(arguments: \[String\] = ProcessInfo\.processInfo\.arguments\) \{(?P<body>.*?)\n    \}",
            sessions,
            re.S,
        )
        self.assertIsNotNone(write_backup)
        for needle in [
            'arguments.contains("--atria-backup-sessions")',
            'arguments.contains("--atria-write-session-backup")',
            'writeSessionBackup(label: "debug")',
        ]:
            assert_contains(self, write_backup.group("body"), needle)

        verify_backup = re.search(
            r"func verifyLatestSessionBackupFromLaunchIfRequested\(arguments: \[String\] = ProcessInfo\.processInfo\.arguments\) \{(?P<body>.*?)\n    \}",
            sessions,
            re.S,
        )
        self.assertIsNotNone(verify_backup)
        for needle in [
            'arguments.contains("--atria-verify-backup")',
            'arguments.contains("--atria-verify-session-backup")',
            "verifyLatestSessionBackup()",
        ]:
            assert_contains(self, verify_backup.group("body"), needle)

        restore_backup = re.search(
            r"func restoreLatestSessionBackupFromLaunchIfRequested\(arguments: \[String\] = ProcessInfo\.processInfo\.arguments\) \{(?P<body>.*?)\n    \}",
            sessions,
            re.S,
        )
        self.assertIsNotNone(restore_backup)
        assert_contains(self, restore_backup.group("body"), 'arguments.contains("--atria-restore-backup")')

    def test_sleep_validation_reuses_aggregate_candidates(self):
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")

        logger = re.search(
            r"private func logSleepValidation\(label: String\?\) \{(?P<body>.*?)\n    \}",
            sessions,
            re.S,
        )
        self.assertIsNotNone(logger)
        body = logger.group("body")
        assert_contains(self, body, "let aggregateSleepCandidatesForValidation = label == nil ? aggregateSleepCandidates(rest: rest, calendar: calendar) : []")
        assert_contains(self, body, "let aggregate = aggregateSleepCandidatesForValidation.first")
        assert_contains(self, body, "aggregateSleepCandidatesForValidation.count")
        self.assertEqual(body.count("aggregateSleepCandidates(rest: rest, calendar: calendar)"), 1)

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
            "state: hrvState",
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
        analytics = source(ROOT / "Atria" / "Atria" / "AtriaAnalytics.swift")
        metrics = source(ROOT / "Atria" / "Atria" / "Metrics.swift")
        trend_chart = source(ROOT / "Atria" / "Atria" / "AtriaTrendChart.swift")
        overview = source(ROOT / "Atria" / "Atria" / "AtriaOverviewSections.swift")
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")

        for needle in [
            "@Published private(set) var overviewTrendPoints: [AtriaTrendPoint] = []",
            "@Published private(set) var trainingLoadSummarySnapshot = TrainingLoadSummary.learning",
            "let monotony: Double?",
            "let readiness: String",
            "let acwrSignal: String",
            "let monotonySignal: String",
            "var acwrSignalText: String",
            "var monotonySignalText: String",
            "var signalSummaryText: String",
            "private var overviewTrendPointsRevision = 0",
            "private var trainingLoadSummaryRevision = 0",
            "private func refreshOverviewTrendPointsCache(deferred: Bool = true)",
            "private func refreshTrainingLoadSummaryCache(deferred: Bool = true)",
            "DispatchQueue.global(qos: .utility).async",
            "Self.makeOverviewTrendPoints(sessions: source, rest: rest, maxHR: maxHR)",
            "Self.makeTrainingLoadSummary(sessions: source,",
            "private nonisolated static func makeOverviewTrendPoints(sessions: [SavedSession]",
            "private nonisolated static func makeTrainingLoadSummary(sessions: [SavedSession]",
            "AtriaAnalytics.TrainingLoad.summary(sessions: sessions,",
            "trainingLoadSummarySnapshot",
            "func trainingLoadSummary(rest: Int, maxHR: Int) -> TrainingLoadSummary {\n        trainingLoadSummarySnapshot\n    }",
        ]:
            assert_contains(self, sessions, needle)

        for needle in [
            "enum AtriaAnalytics",
            "enum Daily",
            "struct PhoneMotionSample: Equatable",
            "struct PhoneMotionSummary: Equatable",
            "static func stepsDaily(_ samples: [PhoneMotionSample]) -> PhoneMotionSummary",
            "struct HeartRateEnergySample: Equatable",
            "static func dayCalories(_ samples: [HeartRateEnergySample],",
            "private static func energyKcalPerMinute(heartRate: Int, profile: AthleteProfile) -> Double",
            "enum Strain",
            "enum TrainingLoad",
            "static func trimp(_ series: [(t: Double, bpm: Int)],",
            "sex: AthleteProfile.BiologicalSex",
            "static func banisterCoefficient(for sex: AthleteProfile.BiologicalSex) -> Double",
            "case .female: return 1.67",
            "case .male, .unspecified: return 1.92",
            "static func edwardsLoad(_ series: [(t: Double, bpm: Int)], rest: Int, max: Int) -> Double",
            "static func edwardsWeight(forHRReserve reserve: Double) -> Int",
            "struct MaxHeartRateZoneSeconds: Equatable",
            "static func maxHeartRateZoneSeconds(_ series: [(t: Double, bpm: Int)],",
            "static func maxHeartRateZoneRawValue(for bpm: Int, maxHR: Int) -> Int",
            "case 0.90...: return 5",
            "case 0.80..<0.90: return 4",
            "case 0.70..<0.80: return 3",
            "case 0.60..<0.70: return 2",
            "case 0.50..<0.60: return 1",
            "static func score(fromEdwardsLoad load: Double) -> Double",
            "static func summary(sessions: [SavedSession],",
            "static func summary(dailyStrains: [Double]) -> TrainingLoadSummary",
            ".map { Strain.score(fromTRIMP: $0.value) }",
            "let monotony = trainingMonotony(acuteRollups)",
            "static func trainingMonotony(_ dailyStrains: [Double]) -> Double?",
            "static func acwrReadinessSignal(ratio: Double?, enoughChronic: Bool) -> String",
            "static func monotonyReadinessSignal(monotony: Double?, enoughAcute: Bool) -> String",
            "static func trainingReadiness(acwrSignal: String,",
            "return \"rundown\"",
            "return \"strained\"",
            "return \"primed\"",
            "return \"balanced\"",
        ]:
            assert_contains(self, analytics, needle)

        for needle in [
            "typealias StrainZoneSummary = AtriaAnalytics.Strain.ZoneSummary",
            "typealias PhoneMotionSample = AtriaAnalytics.Daily.PhoneMotionSample",
            "typealias PhoneMotionSummary = AtriaAnalytics.Daily.PhoneMotionSummary",
            "typealias HeartRateEnergySample = AtriaAnalytics.Daily.HeartRateEnergySample",
            "AtriaAnalytics.Daily.stepsDaily(samples)",
            "AtriaAnalytics.Daily.dayCalories(samples, rest: rest, profile: profile)",
            "AtriaAnalytics.Strain.trimp(series, rest: rest, max: max)",
            "AtriaAnalytics.Strain.trimp(series, rest: rest, max: max, sex: sex)",
            "AtriaAnalytics.Strain.edwardsLoad(series, rest: rest, max: max)",
            "AtriaAnalytics.Strain.activeCalories(samples, rest: rest, profile: profile)",
            "typealias MaxHeartRateZoneSeconds = AtriaAnalytics.Strain.MaxHeartRateZoneSeconds",
            "AtriaAnalytics.Strain.maxHeartRateZoneSeconds(series, maxHR: maxHR, maxGap: maxGap)",
            "AtriaAnalytics.Strain.zoneSummary(series, rest: rest, max: max)",
            "AtriaAnalytics.Strain.score(fromTRIMP: trimp)",
            "AtriaAnalytics.Strain.score(fromEdwardsLoad: load)",
        ]:
            assert_contains(self, metrics, needle)

        for needle in [
            "AtriaTrendChartCard(points: store.overviewTrendPoints,",
            "baselineRestingHR: store.baseline.restingInt",
            "let phoneMotion = Metrics.stepsDaily(overlapping.map",
            "let phoneMotion = Metrics.stepsDaily(ordered.map",
            "phoneStepSource: phoneMotion.hasStepEvidence ? \"phone_coremotion_pedometer\" : \"unavailable\"",
            "phoneStepCount: phoneMotion.steps",
            "phoneStepDistanceMeters: phoneMotion.distanceMeters",
            "phoneStepFloorsAscended: phoneMotion.floorsAscended",
            "phoneStepFloorsDescended: phoneMotion.floorsDescended",
            "Metrics.dayCalories(samples.map",
            "Metrics.HeartRateEnergySample(t: $0.t, bpm: $0.bpm)",
            "activeCalories += Metrics.dayCalories([",
        ]:
            assert_contains(self, trend_chart + sessions + home, needle)

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

        vitals = source(ROOT / "Atria" / "Atria" / "AtriaVitalsCollectionSections.swift")
        assert_contains(self, home, "let load = store.trainingLoadSummarySnapshot")
        assert_contains(self, home, "let loadReadinessText: String")
        assert_contains(self, home, "let loadACWRSignalText: String")
        assert_contains(self, home, "let loadMonotonySignalText: String")
        assert_contains(self, home, "let loadSignalSummaryText: String")
        assert_contains(self, home, "loadReadinessText: load.readinessText")
        assert_contains(self, home, "loadACWRSignalText: load.acwrSignalText")
        assert_contains(self, home, "loadMonotonySignalText: load.monotonySignalText")
        assert_contains(self, home, "loadSignalSummaryText: load.signalSummaryText")
        assert_not_contains(self, home, "store.trainingLoadSummary(rest:")
        for needle in [
            "readiness: hero.loadReadinessText",
            "acwrSignal: hero.loadACWRSignalText",
            "monotonySignal: hero.loadMonotonySignalText",
            "signalSummary: hero.loadSignalSummaryText",
            "private struct AtriaTrainingSignalChip: View, Equatable",
            "AtriaTrainingSignalChip(title: \"ACWR\", value: ratio, signal: acwrSignal)",
            "AtriaTrainingSignalChip(title: \"Monotony\", value: monotonySignal, signal: monotonySignal)",
            "Text(\"Target \\(target)\")",
        ]:
            assert_contains(self, vitals, needle)

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
            "Recovery correlations stay fail-closed until they can use real",
            "strain-derived recovery proxies would",
            "return InsightDayMetrics(recovery: nil, hrv: hrv)",
            "let taggedRecovery = averageDoubleSnapshot(tagged.compactMap(\\.recovery))",
            "let untaggedRecovery = averageDoubleSnapshot(untagged.compactMap(\\.recovery))",
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

        insight_source_start = sessions.index("private nonisolated static func makeBehaviorCorrelationSummaries")
        insight_source_end = sessions.index("private nonisolated static func averageDoubleSnapshot")
        insight_source = sessions[insight_source_start:insight_source_end]
        for forbidden in [
            "100 - Metrics.strain(fromTRIMP:",
            "let recovery = max(0, 100",
            "tagged.map(\\.recovery)",
            "untagged.map(\\.recovery)",
        ]:
            assert_not_contains(self, insight_source, forbidden)

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
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")

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
            "offlineSyncLiveAcceptedHRProtectionWindow",
            "private func shouldProtectLiveStreamForOfflineSync(now: Date = Date()) -> Bool",
            "detail=live_hr_recent action=keep_ble_stream",
            "detail=live_hr_recent_late action=keep_ble_stream",
            "static let rangeLossBackfillPending",
            "private func markRangeLossBackfillRequired(reason: String)",
            "private func preserveLongWearRangeLossRecovery(reason: String)",
            "private func scheduleRangeLossBackfillIfNeeded(reason: String)",
            "private func scheduleRangeLossBackfillRetry(reason: String)",
            "rangeLossBackfillRetryInterval",
            "offline_sync_stale_peripheral",
            "ATRIADBG offline_sync status=pending_range_loss_backfill",
            "ATRIADBG offline_sync status=requesting_range_loss_backfill",
            "protectedLiveStream ? \"defer_live_stream\" : \"sync_when_available\"",
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
        live_defer_index = request_body.find("shouldProtectLiveStreamForOfflineSync(now: now)")
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
        late_defer_index = start_body.find("force || !shouldProtectLiveStreamForOfflineSync(now: Date())")
        cancel_index = start_body.find("central.cancelPeripheralConnection(peripheral)")
        stale_index = start_body.find("recomputeConnectionStatus(reason: \"offline_sync_stale_peripheral\")")
        self.assertGreaterEqual(late_defer_index, 0)
        self.assertGreater(cancel_index, late_defer_index)
        self.assertGreater(stale_index, cancel_index)

        protect_helper = re.search(
            r"private func shouldProtectLiveStreamForOfflineSync\(now: Date = Date\(\)\) -> Bool \{(?P<body>.*?)\n    \}",
            ble,
            re.S,
        )
        self.assertIsNotNone(protect_helper)
        protect_body = protect_helper.group("body")
        for needle in [
            "guard longWearModeEnabled else { return false }",
            "guard let peripheral, peripheral.state == .connected else { return false }",
            "guard hasContact else { return false }",
            "guard session.count >= autoSaveMinSamples else { return false }",
            "guard let lastAcceptedHRAt else { return false }",
            "<= offlineSyncLiveAcceptedHRProtectionWindow",
        ]:
            assert_contains(self, protect_body, needle)

        for needle in [
            "AtriaMissedDataBanner(protectsLiveStream: missedDataBackfillIsDeferredForLiveStream)",
            "private var missedDataBackfillIsDeferredForLiveStream: Bool",
            "case .connected:\n            return model.coreLiveStore.state.sessionSampleCount > 0",
            "Text(protectsLiveStream ? \"Missed data queued\" : \"New data on your strap\")",
            "Live HR stays protected. Sync when you can pause the stream.",
            "guard !missedDataBackfillIsDeferredForLiveStream else",
            "missedDataBannerDismissedUntil = Date().addingTimeInterval(15 * 60)",
            "Text(protectsLiveStream ? \"Queued\" : \"Sync\")",
            ".frame(minWidth: protectsLiveStream ? 76 : 48)",
            ".atriaCardAction(tint: .cyan)",
            ".atriaCardAction(prominent: false, tint: .secondary)",
            ".atriaInsetCard(tint: .cyan)",
            "requestOfflineHistoricalSyncIfNeeded(reason: \"home_missed_data_banner\",\n                                                                 force: true)",
        ]:
            assert_contains(self, home, needle)

        missed_banner = re.search(
            r"private struct AtriaMissedDataBanner: View, Equatable \{(?P<body>.*?)\n\}",
            home,
            re.S,
        )
        self.assertIsNotNone(missed_banner)
        self.assertNotIn(".buttonStyle(.glass", missed_banner.group("body"))
        self.assertNotIn(".glassEffect(", missed_banner.group("body"))

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
            "value: summary.spo2CandidateFrames > 0 ? \"Research\" : \"--\"",
            "value: summary.skinTemperatureDeviation.valueText",
            "unit: summary.skinTemperatureDeviation.isReady ? \"delta C\" : nil",
            "state: summary.skinTemperatureDeviation.isReady ? .research : .learning",
            "@State private var showResearchInfo = false",
            ".accessibilityLabel(\"Sensor research info\")",
            "AtriaResearchSignalInfoSheet(spo2CandidateFrames: summary.spo2CandidateFrames,",
            "private struct AtriaResearchSignalInfoSheet: View",
            "Atria does not show an SpO2 percentage until this protocol is validated.",
            "never absolute body temperature",
            "Atria does not write SpO2 or body-temperature values to HealthKit.",
            "footnote: summary.spo2CandidateFrames > 0 ? \"\\(summary.spo2CandidateFrames) candidate frames; not a SpO2 value.\" : \"Early signal; not a SpO2 value.\"",
            "footnote: summary.skinTemperatureDeviation.footnoteText",
            "footnote: \"Sleep-only estimate; needs comparison data.\"",
            "skin temperature only as a sleep-baseline deviation",
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
            "var skinTempResearchCandidateValueSum: Int? = nil",
            "var skinTempResearchCandidateValueCount: Int? = nil",
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
            "skinTempResearchCandidateValueSum: researchProbeTemperatureCandidateValueCount > 0 ? researchProbeTemperatureCandidateValueSum : nil",
            "skinTempResearchCandidateValueCount: researchProbeTemperatureCandidateValueCount > 0 ? researchProbeTemperatureCandidateValueCount : nil",
            "researchProbeTemperatureCandidateValueSum += summary.temperatureWordCandidates.reduce(0) { $0 + $1.value }",
            "researchProbeTemperatureCandidateValueCount += summary.temperatureWordCandidates.count",
            "ATRIADBG model_gate status=metadata_explicit model=%@ evidence=%@ source=%@",
            "ATRIADBG sensor_research_probe source=%@ status=research_unvalidated",
            "model_generation=%@ model_evidence=%@",
            "metric_promotions=0 healthkit_write=0 raw_storage=0",
        ]:
            assert_contains(self, ble, needle)

        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")
        for needle in [
            "struct SkinTemperatureDeviationSummary: Equatable",
            "let latestDeltaCelsius: Double?",
            "var valueText: String",
            "return String(format: \"%+.1f\", latestDeltaCelsius)",
            "vs sleep baseline",
            "relative baseline building, no absolute temperature",
            "Relative sleep-only deviation from \\(baselineSessions) prior local sessions; no absolute temperature.",
            "let skinTemperatureDeviation: SkinTemperatureDeviationSummary",
            "skinTemperatureDeviation = Self.makeSkinTemperatureDeviationSummary(sessions: sessions,",
            "private static func makeSkinTemperatureDeviationSummary(sessions: [SavedSession],",
            ".filter { $0.sleepWakeResearchState == \"sleep_research\" }",
            "Double(sum) / Double(count) / 100.0",
            "guard baseline.count >= 3 else",
            "latest.meanCelsius - baselineMean",
        ]:
            assert_contains(self, sessions, needle)

        for needle in [
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
            "private static let relativeMarkerFormatter: RelativeDateTimeFormatter",
            "formatter.unitsStyle = .short",
            "AtriaPanelSectionHeader(title: \"Probe markers\", subtitle: \"\")",
            "ForEach(ResearchManeuverMarker.Kind.allCases)",
            ".atriaCardAction(prominent: false, tint: .teal)",
            "AtriaMetricTile(label: \"Probe match\"",
            "state: markers.isEmpty ? .learning : .research",
            "state: correlationSummary.matchedMarkers > 0 ? .research : .learning",
            "Markers stay on device and help compare probe timing.",
            "Self.relativeMarkerFormatter.localizedString(for: marker.timestamp, relativeTo: Date())",
        ]:
            assert_contains(self, collection, needle)

        assert_not_contains(self, collection, "RelativeDateTimeFormatter().localizedString")
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
            "ECG not supported",
            "WHOOP 4.0 has no electrodes, so Atria does not fake an ECG.",
            "Blood pressure not supported",
            "WHOOP 4.0 is not cuff-calibrated, so Atria does not estimate BP.",
            "Blood oxygen research",
            "Sleep-only evidence; no SpO2 percentage or Health export yet.",
            "Body temperature research",
            "Skin-temp deviation only; no absolute body temperature or Health export.",
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

    def test_live_device_harness_supports_release_build_configuration(self):
        text = source(ROOT / "live_device_debug.sh")

        for needle in [
            "build_configuration=${ATRIA_BUILD_CONFIGURATION:-Debug}",
            "--configuration Debug|Release",
            "--release            Shorthand for --configuration Release.",
            "build_configuration=${2:?--configuration requires a value}",
            "build_configuration=Release",
            "case \"$build_configuration\" in",
            "Debug|Release) ;;",
            "app_path=\"${derived_data}/Build/Products/${build_configuration}-iphoneos/Atria.app\"",
            "-configuration \"$build_configuration\"",
        ]:
            assert_contains(self, text, needle)

        assert_not_contains(self, text, "Build/Products/Debug-iphoneos/Atria.app\"")
        assert_not_contains(self, text, "-configuration Debug \\")
        self.assertGreaterEqual(text.count("-configuration \"$build_configuration\""), 3)

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
            "@Published private(set) var lastScanRequestedAt: Date?",
            "@Published private(set) var lastScanMatchAt: Date?",
            "@Published private(set) var pendingKnownReconnectStartedAt: Date?",
            "@Published private(set) var pendingKnownReconnectReason = \"\"",
            "private func markPendingKnownReconnect(reason: String)",
            "private func clearPendingKnownReconnect(reason: String)",
            "markPendingKnownReconnect(reason: reason)",
            "clearPendingKnownReconnect(reason: \"did_connect\")",
            "clearPendingKnownReconnect(reason: \"forget\")",
            "self.lastScanMatchAt = Date()",
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

    def test_healthkit_sleep_stage_export_requires_validated_stage_source(self):
        text = source(ROOT / "Atria" / "Atria" / "HealthKitExporter.swift")

        for needle in [
            "\"atria_sleep_stage_evidence\": sleep.source == \"validated_sleep_stages\" ? \"validated\" : \"non_validated\"",
            "guard sleep.source == \"validated_sleep_stages\"",
            "value: HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue",
            "stageMetadata[\"atria_sleep_stage\"] = segment.stage.rawValue",
            "value: healthKitSleepValue(for: segment.stage)",
        ]:
            assert_contains(self, text, needle)

    def test_healthkit_rhr_and_respiratory_rate_export_use_correct_types(self):
        text = source(ROOT / "Atria" / "Atria" / "HealthKitExporter.swift")
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")

        for needle in [
            "private var restingHeartRateType",
            ".restingHeartRate",
            "private var respiratoryRateType",
            ".respiratoryRate",
            "session.restingStable > 0",
            "HKQuantitySample(type: restingHeartRateType",
            "func sleepRespiratoryRate(rest: Int, maxHR: Int, calendar: Calendar = .current) -> Double?",
            "sleepWakeResearchState == \"sleep_research\"",
            "detectedActivity(rest: rest, maxHR: maxHR, calendar: calendar)?.kind == .sleepCandidate",
            "let respiratoryRate = session.sleepRespiratoryRate(rest: rest, maxHR: maxHR)",
            "HKQuantitySample(type: respiratoryRateType",
            "HKUnit.count().unitDivided(by: .minute())",
        ]:
            assert_contains(self, text + sessions, needle)
        assert_not_contains(self, text, "let respiratoryRate = session.respiratoryRate")
        assert_not_contains(self, text, "respiratoryRateExported: (session.respiratoryRate ?? 0) > 0")
        assert_not_contains(self, sessions, "let respiratoryRates = recent.compactMap(\\.respiratoryRate)")
        assert_not_contains(self, sessions, "let respiratoryRates = daySessions.compactMap(\\.respiratoryRate)")

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
        analytics = source(ROOT / "Atria" / "Atria" / "AtriaAnalytics.swift")
        healthkit = source(ROOT / "Atria" / "Atria" / "HealthKitExporter.swift")
        vitals = source(ROOT / "Atria" / "Atria" / "AtriaVitalsCollectionSections.swift")

        match = re.search(r"func vo2MaxEstimateSummary\(rest: Int, maxHR: Int\) -> VO2MaxEstimateSummary \{(?P<body>.*?)\n    \}", sessions, re.S)
        self.assertIsNotNone(match)
        body = match.group("body")
        for needle in [
            "AtriaAnalytics.VO2Max.summary(rest: rest,",
            "maxHR: maxHR,",
            "restingSamples: baseline.restingSampleCount,",
            "maxHRMeasured: profile.maxHRSource == .measured,",
            "restingTrend: restingTrend14)",
        ]:
            assert_contains(self, body, needle)
        assert_contains(self, sessions, "let trendDelta: Double?")
        for needle in [
            "enum VO2Max",
            "guard rest > 0, maxHR > rest else",
            "guard restingSamples >= 7 else",
            "guard maxHRMeasured else",
            "VO2MaxEstimateSummary(value: nil",
            "let rawEstimate = 15.3 * Double(maxHR) / Double(rest)",
            "let confidence = \"rough estimate\"",
            "let trend = trendText(currentEstimate: boundedEstimate,",
            "trendText: trend.text",
            "trendDetail: trend.detail",
            "trendDelta: trend.delta",
            "static func trendText(currentEstimate: Double,",
            "let rests = restingTrend.filter { $0 > 0 }",
            "guard rests.count >= 2, let oldestRest = rests.first else",
            "let previousEstimate = boundedEstimate(rest: oldestRest, maxHR: maxHR)",
            "return (String(format: \"%+.1f\", delta), \"vs \\(rests.count)-point RHR trend.\", delta)",
        ]:
            assert_contains(self, analytics, needle)
        self.assertGreater(analytics.find("let rawEstimate = 15.3"), analytics.find("guard maxHRMeasured else"))

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

    def test_biological_age_is_local_estimate_and_fail_closed(self):
        insights = source(ROOT / "Atria" / "Atria" / "Insights.swift")
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")
        analytics = source(ROOT / "Atria" / "Atria" / "AtriaAnalytics.swift")
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")
        hero = source(ROOT / "Atria" / "Atria" / "AtriaHeroConnectionSections.swift")
        overview = source(ROOT / "Atria" / "Atria" / "AtriaOverviewSections.swift")
        vitals = source(ROOT / "Atria" / "Atria" / "AtriaVitalsCollectionSections.swift")

        for needle in [
            "static let trustedMinimumSamples = 14",
            "static let staleAfter: TimeInterval = 21 * 24 * 60 * 60",
            "func isStale(now: Date = Date()) -> Bool",
            "func hasTrustedRestingBaseline(now: Date = Date()) -> Bool",
            "restingSampleCount >= Self.trustedMinimumSamples && !isStale(now: now)",
            "func hasTrustedHRVBaseline(now: Date = Date()) -> Bool",
            "hrvSampleCount >= Self.trustedMinimumSamples && !isStale(now: now)",
        ]:
            assert_contains(self, insights, needle)

        for needle in [
            "struct BiologicalAgeSummary: Equatable",
            "let biologicalAge: Int?",
            "let ageDelta: Int?",
            "let agingPaceText: String",
            "let agingPaceDetail: String",
            "let factors: [BioAgeFactor]",
            "enum Direction: String, Equatable",
            "let direction: Direction",
            "static let footnoteText = \"Estimated from your fitness, heart-rate, HRV and sleep data -- an estimate, not a medical assessment.\"",
            "Building your body-age baseline",
            "func biologicalAgeSummary(vo2MaxEstimate: VO2MaxEstimateSummary) -> BiologicalAgeSummary",
            "guard let vo2Max = vo2MaxEstimate.value else",
            "baseline.hasTrustedRestingBaseline()",
            "14 fresh RHR baseline nights",
            "baseline.hasTrustedHRVBaseline()",
            "14 fresh HRV baseline nights",
            "let sleepNights = sleepHistorySnapshot.nights\n            .filter { !$0.isNapEvidence }\n            .prefix(14)",
            "guard sleepNights.count >= 3 else",
            "3 sleep night records",
            "guard profile.heightCm > 0, profile.weightKg > 0 else",
            "trainingLoadSummarySnapshot.confidence == \"local\"",
            "14 activity load days",
            "VO2max",
            "Resting HR",
            "HRV",
            "Sleep",
            "Activity",
            "BMI",
            "AtriaAnalytics.BiologicalAge.summary(chronologicalAge: chronologicalAge,",
        ]:
            assert_contains(self, sessions, needle)
        assert_not_contains(self, sessions, "3 sleep or nap records")
        assert_not_contains(self, sessions, "trainingLoadSummarySnapshot.confidence != \"learning\"")
        assert_not_contains(self, sessions, "activity load baseline")
        assert_not_contains(self, sessions, "guard let restingHR = baseline.restingInt, baseline.restingSampleCount >= 7 else")
        assert_not_contains(self, sessions, "guard let hrv = baseline.hrvInt, baseline.hrvSampleCount >= 7 else")

        for needle in [
            "enum BiologicalAge",
            "static func summary(chronologicalAge: Int, factors: [BioAgeFactor]) -> BiologicalAgeSummary",
            "min(max(unclamped, chronologicalAge - 20), chronologicalAge + 20)",
            "static func agingPace(biologicalAge: Int,",
            "weekly trend unlocks after more local estimates",
            "static func factor(id: String,",
            "direction: delta == 0 ? .neutral : (delta < 0 ? .younger : .older)",
            "ACSM/Cooper VO2max percentile tables",
            "static func vo2AgeEquivalent(_ vo2: Double, sex: AthleteProfile.BiologicalSex) -> Int",
            "private static let maleVO2AgeReference: [(age: Int, value: Double)]",
            "private static let femaleVO2AgeReference: [(age: Int, value: Double)]",
            "private static let restingHRAgeReference: [(age: Int, value: Double)]",
            "private static let rmssdAgeReference: [(age: Int, value: Double)]",
            "private static func interpolatedAgeEquivalent(for value: Double,",
            "higherIsYounger: Bool",
            "static func rhrAgeEquivalent(_ restingHR: Int) -> Int",
            "static func hrvAgeEquivalent(_ rmssd: Int) -> Int",
            "static func sleepAgeEquivalent(durationHours: Double,",
            "consistencyPercent: Int?",
            "static func activityAgeEquivalent(_ chronicLoad: Double,",
            "static func bmiAgeEquivalent(_ bmi: Double,",
        ]:
            assert_contains(self, analytics, needle)

        for needle in [
            "let biologicalAgeSummary: BiologicalAgeSummary",
            "biologicalAgeSummary: store.biologicalAgeSummary(vo2MaxEstimate: vo2)",
            "biologicalAgeSummary: profileMetricsStore.state.biologicalAgeSummary",
            "store.$sleepHistorySnapshot.map { _ in () }.eraseToAnyPublisher()",
            "store.$trainingLoadSummarySnapshot.map { _ in () }.eraseToAnyPublisher()",
            "profileMetricsStore: model.profileMetricsStore",
        ]:
            assert_contains(self, home + overview, needle)
        for needle in [
            r"\(hero.baselineSamples)/\(PersonalBaseline.trustedMinimumSamples)",
            r"\(stats.baselineSamples)/\(PersonalBaseline.trustedMinimumSamples)",
            r"\(store.baseline.hrvSampleCount)/\(PersonalBaseline.trustedMinimumSamples)",
            "sampleCount >= PersonalBaseline.trustedMinimumSamples",
            "Trusted personal baseline is ready.",
            "Wear overnight to build a trusted recovery baseline.",
        ]:
            assert_contains(self, home + hero + overview + sessions, needle)
        for forbidden in [
            r"\(hero.baselineSamples)/7",
            r"\(stats.baselineSamples)/7",
            r"\(store.baseline.hrvSampleCount)/7",
            "Personal baseline is ready.",
        ]:
            assert_not_contains(self, home + hero + overview + sessions, forbidden)

        for needle in [
            "case .bioAge: return \"Body age\"",
            "case .bioAge: return \"figure.stand.line.dotted.figure.stand\"",
            "case .bioAge:",
            "AtriaGlanceMetricCard(title: \"Body age\"",
            "biologicalAgeSummary.isReady ? biologicalAgeSummary.detailText : \"Building baseline\"",
            "Building your body-age baseline",
        ]:
            assert_contains(self, overview, needle)

        for needle in [
            "let biologicalAgeSummary: BiologicalAgeSummary",
            "AtriaMetricTile(label: \"Body age\"",
            "AtriaMetricTile(label: \"Aging pace\"",
            "biologicalAgeSummary.agingPaceText",
            "biologicalAgeSummary.agingPaceDetail",
            "state: biologicalAgeSummary.isReady ? .estimate : .learning",
            "AtriaPanelSectionHeader(title: \"Biological Age\", subtitle: biologicalAgeSummary.narrative)",
            "ForEach(biologicalAgeSummary.factors)",
            "Text(biologicalAgeSummary.footnote)",
            "let profileMetricsStore: AtriaHomeModel.ProfileMetricsStore",
            "struct AtriaCollectionBiologicalAgeCard: View, Equatable",
            "AtriaCollectionBiologicalAgeCard(summary: profileMetricsStore.state.biologicalAgeSummary,",
            "AtriaPanelSectionHeader(title: \"Biological Age\", subtitle: summary.narrative)",
            "AtriaMetricTile(label: \"Pace\"",
            "value: summary.agingPaceText",
            "footnote: summary.agingPaceDetail",
            "ForEach(summary.factors)",
            "Text(summary.footnote)",
        ]:
            assert_contains(self, vitals, needle)

        assert_not_contains(self, sessions + overview + vitals, "longevity")
        assert_not_contains(self, sessions + overview + vitals, "lifespan")
        assert_not_contains(self, sessions + overview + vitals, "disease risk")

    def test_validate_later_recovery_displays_personal_baseline_before_validation(self):
        metrics = source(ROOT / "Atria" / "Atria" / "Metrics.swift")
        analytics = source(ROOT / "Atria" / "Atria" / "AtriaAnalytics.swift")
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")
        text = metrics + analytics
        overview = source(ROOT / "Atria" / "Atria" / "AtriaOverviewSections.swift")
        vitals = source(ROOT / "Atria" / "Atria" / "AtriaVitalsCollectionSections.swift")
        widget = source(ROOT / "Atria" / "Atria" / "WidgetSnapshot.swift")
        intents = source(ROOT / "Atria" / "Atria" / "AtriaAppIntents.swift")
        docs = "\n".join(source(path) for path in (ROOT / "docs").rglob("*.md"))

        for needle in [
            "case personalBaseline = \"personal baseline\"",
            "Recovery v2: logistic personal z-score model.",
            "baseline.hasTrustedRestingBaseline()",
            "baseline.hasTrustedHRVBaseline()",
            "PersonalBaseline.trustedMinimumSamples",
            "sleepEfficiency: Double? = nil",
            "sleepDurationHours: Double? = nil",
            "respiratoryRate: Double? = nil",
            "respiratoryBaseline: (mean: Double, sd: Double, count: Int)? = nil",
            "guard let sleepZ = sleepRecoveryZ(efficiency: sleepEfficiency,",
            "detail: \"learning: need saved sleep\"",
            "let respirationZ = respiratoryRecoveryZ(rate: respiratoryRate,",
            "0.60 * hrvZ - 0.20 * restingZ + 0.15 * sleepZ + 0.05 * respirationZ",
            "let percent = logisticRecoveryPercent(z: blendedZ)",
            "private static func logisticRecoveryPercent(z: Double) -> Int",
            "100.0 / (1.0 + exp(-k * (z - z0)))",
            "private static func respiratoryRecoveryZ(rate: Double?,",
            "baseline.count >= PersonalBaseline.trustedMinimumSamples",
            "-zScore(rate, mean: baseline.mean, sd: baseline.sd)",
            "? \"Resp neutral\"",
            "String(format: \"Resp z %.1f\", respirationZ)",
            "Sleep z %.1f · %@",
            "private static func sleepRecoveryZ(efficiency: Double?, durationHours: Double?) -> Double?",
            "hrvReferenceValidated ? .validated : .personalBaseline",
            "enum RespRateRsa",
            "static func estimate(samples: [(t: Date, ms: Double)],",
            "lookback: TimeInterval = 90",
            "static func estimate(resampledRR: [Double], sampleRate: Double = 4.0) -> Double?",
            "for breathsPerMinute in stride(from: 6.0, through: 30.0, by: 0.5)",
            "bestPower / max(bandPower, bestPower) >= 0.18",
        ]:
            assert_contains(self, text, needle)
        assert_contains(self, analytics, "enum Recovery")
        assert_contains(self, analytics, "static func restingOnly(restingNow: Int, baseline: Int) -> Int")
        assert_contains(self, analytics, "static func estimate(hrvNow: Int, hrvBaseline: Int, restingNow: Int, restingBaseline: Int) -> Int")
        assert_contains(self, analytics, "static func estimate(hrvSnapshot: HRVSnapshot?,")
        assert_contains(self, metrics, "typealias RecoveryEstimate = AtriaAnalytics.Recovery.Estimate")
        assert_contains(self, metrics, "AtriaAnalytics.Recovery.restingOnly(restingNow: restingNow, baseline: baseline)")
        assert_contains(self, metrics, "AtriaAnalytics.Recovery.estimate(hrvNow: hrvNow,")
        assert_contains(self, metrics, "AtriaAnalytics.Recovery.estimate(hrvSnapshot: hrvSnapshot,")
        assert_contains(self, metrics, "respiratoryRate: respiratoryRate")
        assert_contains(self, metrics, "respiratoryBaseline: respiratoryBaseline")
        assert_contains(self, sessions, "var respiratoryBaselineStats: (mean: Double, sd: Double, count: Int)?")
        assert_contains(self, sessions, "values.count >= PersonalBaseline.trustedMinimumSamples")
        assert_contains(self, sessions, "let clippedNights = Array(sorted.prefix(PersonalBaseline.trustedMinimumSamples + 1))")
        assert_contains(self, sessions, "self.nights = clippedNights")
        assert_contains(self, sessions, "let respiratoryBaselineMean: Double?")
        assert_contains(self, sessions, "let respiratoryBaselineCount: Int")
        assert_contains(self, sessions, "let respiratoryRate = AtriaAnalytics.RespRateRsa.estimate(samples: sorted, now: windowEnd)")
        assert_contains(self, sessions, "respiratoryRate: respiratoryRate")
        hrv_source = source(ROOT / "Atria" / "Atria" / "HRV.swift")
        assert_contains(self, hrv_source, "AtriaAnalytics.RespRateRsa.estimate(samples: kept.map { (t: $0.t, ms: $0.ms) }, now: now)")
        assert_not_contains(self, sessions, "respiratoryRate: nil)\n    }\n\n    private func replayReason")
        assert_not_contains(self, metrics, "let hrvScore = 66.0 * Double(hrvNow) / Double(hrvBaseline)")
        assert_not_contains(self, metrics, "let restingPenalty = restingNow > 0 && restingBaseline > 0")
        assert_not_contains(self, analytics, "hrvStats.count >= 7")
        assert_not_contains(self, analytics, "learning HRV baseline \\(baseline.hrvSampleCount)/7")
        assert_not_contains(self, analytics, "50 + blendedZ * 16")
        assert_not_contains(self, analytics, "0.60 * hrvZ - 0.25 * restingZ + 0.15 * sleepZ")

        for needle in [
            "let fallbackHRV = validatedHRV ?? store.latestLocalRMSSD",
            "let latestSleep = store.sleepHistorySnapshot.latest",
            "fallbackRMSSD: fallbackHRV",
            "hrvReferenceValidated: validatedHRV != nil",
            "sleepEfficiency: latestSleep?.sleepEfficiency",
            "sleepDurationHours: latestSleep?.durationHours",
            "hrvState = recovery.confidence == .validated ? \"validated\" : \"personal_baseline\"",
        ]:
            assert_contains(self, widget, needle)

        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")
        notifications = source(ROOT / "Atria" / "Atria" / "LocalNotificationScheduler.swift")
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")
        assert_contains(self, home, "sleepEfficiency: latestSleep?.sleepEfficiency")
        assert_contains(self, home, "sleepDurationHours: latestSleep?.durationHours")
        assert_contains(self, notifications, "sleepEfficiency: latestSleep?.sleepEfficiency")
        assert_contains(self, notifications, "sleepDurationHours: latestSleep?.durationHours")
        assert_contains(self, sessions, "private nonisolated static func sleepEfficiency(duration: TimeInterval?, span: TimeInterval?) -> Double?")
        assert_contains(self, sessions, "sleepEfficiency: Self.sleepEfficiency(duration: sleepRollup?.sleepDuration,")
        assert_contains(self, sessions, "sleepDurationHours: sleepRollup?.sleepDuration.map { $0 / 3_600 }")

        for needle in [
            "private var recoveryState: AtriaMetricState",
            "case .personalBaseline:\n            return .personalBaseline",
            "case .unverified:\n            return .research",
            "state: recoveryState",
            "footnote: hero.recoveryEstimate.confidence.rawValue",
            "private var hrvState: AtriaMetricState",
            "if detail.contains(\"validated\") { return .validated }",
            "if detail.contains(\"personal baseline\") || detail.contains(\"% kept\") { return .personalBaseline }",
            "footnote: hero.hrvDetail",
        ]:
            assert_contains(self, overview + vitals, needle)

        assert_not_contains(self, overview + vitals, "state: hero.recoveryEstimate.percent == nil ? .learning : .validated")
        assert_not_contains(self, vitals, "hero.hrvDetail.localizedCaseInsensitiveContains(\"validated\") ? .validated : .learning")
        assert_not_contains(self, overview, "hero.hrvDetail.localizedCaseInsensitiveContains(\"validated\") ? .validated : .learning")

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
            "var enabledCount: Int",
            "var glanceValueText: String",
            "var glanceDetailText: String",
            "if heartRateZones { return \"Zones on\" }",
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
            "captureCard\n                        researchSignalsCard\n                        biologicalAgeCard\n                        if developerModeEnabled",
            "captureCard\n                    researchSignalsCard\n                    biologicalAgeCard\n                    if developerModeEnabled",
            "if developerModeEnabled {\n                            rrReferenceCard",
            "if developerModeEnabled {\n                            rrReferenceCard\n                            hrReferenceCard\n                            imuAuditCard",
            "if developerModeEnabled {\n                    AtriaCollectionToggleCard",
            "title: \"Battery saver\"",
            "Heart-rate only. HR stays live; HRV, Recovery and sleep detail wait for validated beat-to-beat windows.",
            "Full sensor mode. Beat-to-beat, HRV, Recovery and sleep research stay available.",
            "private var researchSignalsCard: some View",
            "AtriaCollectionResearchSignalsCard(summary: store.imuAuditSummary,",
            "sleepHistory: store.sleepHistorySnapshot",
            "private struct AtriaCollectionResearchSignalsCard: View, Equatable",
            "AtriaPanelSectionHeader(title: \"Sensor signals\", subtitle: \"\")",
            "Image(systemName: \"info.circle\")",
            "showResearchInfo = true",
            "Sensor research info",
            "AtriaResearchSignalInfoSheet(spo2CandidateFrames: summary.spo2CandidateFrames,",
            "AtriaMetricTile(label: \"Blood oxygen\"",
            "value: summary.spo2CandidateFrames > 0 ? \"Research\" : \"--\"",
            "AtriaMetricTile(label: \"Body temp\"",
            "value: summary.skinTemperatureDeviation.valueText",
            "unit: summary.skinTemperatureDeviation.isReady ? \"delta C\" : nil",
            "footnote: summary.skinTemperatureDeviation.footnoteText",
            "AtriaMetricTile(label: \"Resp rate\"",
            "AtriaMetricTile(label: \"Strap steps\"",
            "\\(summary.spo2CandidateFrames) candidate frames; not a SpO2 value.",
            "Sleep-only estimate; needs comparison data.",
            "Atria shows skin temperature only as a sleep-baseline deviation, never as an absolute body-temperature value.",
            "private struct AtriaResearchSignalInfoSheet: View",
            "No candidate frames yet. Atria does not estimate or display an SpO2 percentage from unvalidated bytes.",
            "private struct AtriaCollectionIMUAuditCard: View, Equatable",
            "AtriaPanelSectionHeader(title: \"IMU audit\", subtitle: \"\")",
            "Early motion signals stay separate until they match phone motion reliably.",
            ".lineLimit(2)",
            "AtriaMetricTile(label: \"Sleep/wake\"",
            "AtriaMetricTile(label: \"Probes\"",
            "agreementText",
            "probeDetail",
            "AtriaCollectionIMUAuditCard(summary: store.imuAuditSummary)",
        ]:
            assert_contains(self, collection, needle)
        assert_not_contains(self, collection, "title: \"Standard HR radio\"")
        assert_not_contains(self, collection, "Advanced compatibility mode for heart-rate-only collection.")

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
        imu_audit_card = collection[
            collection.index("private struct AtriaCollectionIMUAuditCard"):
            collection.index("private struct AtriaResearchManeuverMarkerCard")
        ]
        for forbidden in [
            "dailyRollups(",
            "detectedActivity(",
            "aggregateSleepCandidates(",
            "IMUAuditSummary(sessions:",
            "SleepHistorySnapshot(rollups:",
        ]:
            assert_not_contains(self, research_card, forbidden)
        assert_contains(self, research_card, "AtriaMetricTile(label: \"Strap steps\"")
        assert_not_contains(self, imu_audit_card, "AtriaMetricTile(label: \"Strap steps\"")

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
        for needle in [
            "if step == .coexistence && officialAppMayBeInstalled {\n                            recheckOfficialApp()",
            "case .coexistence: return officialAppMayBeInstalled ? \"Recheck official app\" : \"Continue\"",
            "Clear this before relying on Atria for overnight or workout metrics.",
            "Close it, log out, disable Bluetooth access, and remove widgets.",
        ]:
            assert_contains(self, content, needle)

        assert_not_contains(self, content, "I’ll do this — continue")

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
            "private static let liveWidgetSnapshotMinimumInterval: TimeInterval = 45",
            "private static let liveWidgetSnapshotMeaningfulChangeInterval: TimeInterval = 15",
            "private static let liveWidgetSnapshotMeaningfulBPMDelta = 4",
            "@State private var lastLiveWidgetSnapshotAt: Date?",
            "@State private var lastLiveWidgetSnapshotHeartRate: Int?",
            "publishLiveWidgetSnapshotIfNeeded()",
            "private func publishLiveWidgetSnapshotIfNeeded(now: Date = Date())",
            "guard scenePhase == .active else { return }",
            "let heartRate = model.pulseLiveStore.state.heartRate",
            "guard heartRate > 0 else { return }",
            "let meaningfulDelta = lastLiveWidgetSnapshotHeartRate.map {",
            "abs(heartRate - $0) >= Self.liveWidgetSnapshotMeaningfulBPMDelta",
            "let cadenceReady = elapsed.map { $0 >= Self.liveWidgetSnapshotMinimumInterval } ?? true",
            "let changeReady = meaningfulDelta",
            "elapsed.map { $0 >= Self.liveWidgetSnapshotMeaningfulChangeInterval } ?? true",
            "guard cadenceReady || changeReady else",
            "lastLiveWidgetSnapshotHeartRate = heartRate",
            "reason: cadenceReady ? \"live_throttled\" : \"live_bpm_delta\"",
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
            "deepLinkURL: AtriaWidgetMetric.strain.deepLinkURL",
            "deepLinkURL: AtriaWidgetMetric.bpm.deepLinkURL",
            "private func widgetMetricLink(_ metric: AtriaWidgetMetric, tint: Color) -> some View",
            "Link(destination: metric.deepLinkURL)",
        ]:
            assert_contains(self, widget, needle)

    def test_home_screen_widgets_use_richer_small_and_medium_layouts(self):
        widget = source(ROOT / "Atria" / "AtriaWidget" / "AtriaWidget.swift")

        for needle in [
            "private var systemSmallWidget: some View",
            "private var systemMediumWidget: some View",
            "case .systemLarge:\n                systemLargeWidget",
            "private var systemLargeWidget: some View",
            "private var widgetHeader: some View",
            "private func compactMetric(_ title: String,",
            "private func widgetMetricTile(_ title: String, value: String, icon: String, tint: Color) -> some View",
            "private func widgetMetricLink(_ metric: AtriaWidgetMetric, tint: Color) -> some View",
            "private struct AtriaWidgetRecoveryGauge: View",
            "AtriaWidgetRecoveryGauge(percent: entry.snapshot?.recoveryPercent)",
            ".frame(width: 72, height: 72)",
            ".frame(width: 92, height: 92)",
            ".frame(width: 118, height: 118)",
            "private var largeBatteryText: String",
            "controlButtons",
            "private var largeFooterText: String",
            "widgetMetricLink(.strain, tint: .orange)",
            "widgetMetricLink(.bpm, tint: .red)",
            "widgetMetricLink(.hrv, tint: .pink)",
            "widgetMetricLink(.steps, tint: .blue)",
            ".supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryCircular, .accessoryRectangular, .accessoryInline])",
            ".accessibilityLabel(percent.map { \"Recovery \\($0) percent\" } ?? \"Recovery learning\")",
        ]:
            assert_contains(self, widget, needle)

        assert_not_contains(self, widget, "// Recovery + Strain are the headline pair.")

    def test_single_metric_widgets_support_home_screen_small_layouts(self):
        widget = source(ROOT / "Atria" / "AtriaWidget" / "AtriaWidget.swift")

        for needle in [
            "// MARK: - Single-metric widgets (Home Screen + Lock Screen)",
            "case .systemSmall:\n                systemSmallMetric",
            "private var systemSmallMetric: some View",
            "var tint: Color",
            "var unit: String",
            "Text(metric.unit.uppercased())",
            "Text(metricFooterText)",
            "private var metricFooterText: String",
            ".accessibilityLabel(\"\\(metric.title) \\(value), \\(metricFooterText)\")",
            ".description(\"Today's steps on your Home Screen or Lock Screen.\")",
            ".description(\"Today's strain on your Home Screen or Lock Screen.\")",
            ".description(\"Latest HRV on your Home Screen or Lock Screen.\")",
            ".description(\"Latest heart rate on your Home Screen or Lock Screen.\")",
            ".supportedFamilies([.systemSmall, .accessoryCircular, .accessoryInline, .accessoryRectangular])",
        ]:
            assert_contains(self, widget, needle)

        self.assertGreaterEqual(
            widget.count(".supportedFamilies([.systemSmall, .accessoryCircular, .accessoryInline, .accessoryRectangular])"),
            4,
        )

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
        settings = source(ROOT / "Atria" / "Atria" / "AtriaSettingsView.swift")

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

        for forbidden in [
            "shortcutsSection",
            "Strap tap shortcuts",
            "music, calls",
            "are coming once",
        ]:
            assert_not_contains(self, settings, forbidden)

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
            "aggregateSleepDiagnostics(",
            "canonicalSessions(",
            "replaySavedWorkoutReadiness(",
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
        hrv = source(ROOT / "Atria" / "Atria" / "HRV.swift")

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
        assert_contains(self, ble, "Recording a beat-to-beat heart-rate window")
        assert_contains(self, ble, "waiting for beat-to-beat samples")
        assert_contains(self, ble, "collecting beat-to-beat samples")
        assert_contains(self, hrv, "learning: need 240 beat-to-beat samples")
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
                "Recording a clean heart-rate window",
                "waiting for clean RR",
                "collecting clean RR",
                "clean beats",
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
        assert_contains(self, notifications, "static func cancelActionableConnectionDiagnosis(title: String? = nil, reason: String)")
        assert_contains(self, notifications, "private static func actionableConnectionDiagnosisDecision(title: String,")
        assert_contains(self, notifications, "center.removePendingNotificationRequests(withIdentifiers: identifiers)")
        assert_contains(self, notifications, "ATRIADBG notification_cancel kind=actionable_connection")
        assert_contains(self, notifications, "if pending.contains(where: { $0.identifier == decision.identifier })")
        assert_contains(self, notifications, "reason=pending_request")
        assert_contains(self, notifications, "reason=cooldown")
        assert_contains(self, notifications, "case \"Strap battery low\":")
        assert_contains(self, notifications, "case \"Bluetooth is off\":")
        assert_contains(self, notifications, "bluetooth_permission_inline_only")
        assert_contains(self, notifications, "includeMetricDecisions: debugMetricRequest")
        assert_contains(self, notifications, "includeActionableConnectionDecisions: productionCadence || debugMetricRequest")
        assert_contains(self, notifications, "actionable_connection_decisions=%d")
        assert_contains(self, notifications, "monitor_actionable_connection_triggers")
        assert_contains(self, notifications, "private static func makeMetricDecisions(store: SessionStore,")
        assert_contains(self, notifications, "private static func makeActionableConnectionDecisions(ble: AtriaBLEManager) -> [NotificationDecision]")
        assert_contains(self, notifications, 'static let bluetoothOff = "atria.bluetooth.off"')
        assert_contains(self, notifications, 'kind: "bluetooth_off"')
        assert_contains(self, notifications, "if ble.bluetoothPermissionDenied")
        assert_contains(self, notifications, 'title: "Bluetooth is off"')
        assert_contains(self, notifications, 'Turn on Bluetooth in Settings so Atria can read your strap.')
        assert_contains(self, notifications, "if ble.status == .poweredOff")
        assert_contains(self, notifications, "return [bluetoothDecision]")
        assert_contains(self, notifications, "threshold=%d")
        assert_contains(self, notifications, "drop_recent=%d")
        assert_contains(self, notifications, "let effectiveChargeStatus = battery.chargeStatus")
        assert_contains(self, notifications, "let batteryIsCharging = effectiveChargeStatus == .charging || effectiveChargeStatus == .full")
        assert_contains(self, notifications, "charge=%@")
        assert_contains(self, notifications, "effectiveChargeStatus.rawValue")
        assert_contains(self, notifications, "battery.recentDrop ? 1 : 0")
        assert_contains(self, notifications, "battery.level <= Self.actionableBatteryThreshold")
        assert_contains(self, notifications, "battery.level <= Self.actionableBatteryThreshold && battery.recentDrop && !batteryIsCharging")
        assert_contains(self, notifications, "batterySnapshot(liveLevel: ble.batteryLevel, liveChargeStatus: ble.batteryChargeStatus)")
        assert_contains(self, notifications, "cachedBattery(maxAge: 10 * 60)")
        assert_contains(self, notifications, "AtriaBLEManager.cachedBatteryDrop()")
        assert_contains(self, notifications, "live_2A19_cached_charge")
        assert_contains(self, notifications, "battery_\\(battery.level)_drop_source_\\(battery.source)")
        assert_contains(self, notifications, "battery_\\(battery.level)_low_no_recent_drop_source_\\(battery.source)")
        assert_contains(self, notifications, "battery_\\(battery.level)_charging_\\(effectiveChargeStatus.rawValue)_source_\\(battery.source)")
        assert_contains(self, notifications, 'body: "Charge your strap before a workout or overnight wear. Battery is \\(battery.level)%."')
        assert_contains(self, notifications, 'bluetooth_off=%d')
        assert_contains(self, notifications, "title: \"Atria notification test\"")
        assert_contains(self, notifications, "body: \"Local notification delivery is working.\"")
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")
        assert_contains(self, home, "LocalNotificationScheduler.scheduleActionableConnectionDiagnosis(title: next.title,")
        assert_contains(self, home, "if next.sendsLocalNotification && visibleConnectionDiagnosis != next")
        assert_contains(self, home, "LocalNotificationScheduler.cancelActionableConnectionDiagnosis(reason: \"diagnosis_cleared_\\(reason)\")")
        assert_contains(self, home, "LocalNotificationScheduler.cancelActionableConnectionDiagnosis(title: visibleConnectionDiagnosis?.title,")
        assert_contains(self, home, "LocalNotificationScheduler.cancelActionableConnectionDiagnosis(reason: \"diagnosis_non_actionable_\\(reason)\")")

        actionable = re.search(
            r"private static func makeActionableConnectionDecisions\(ble: AtriaBLEManager\) -> \[NotificationDecision\] \{(?P<body>.*?)\n    \}",
            notifications,
            re.S,
        )
        self.assertIsNotNone(actionable)
        actionable_body = actionable.group("body")
        bluetooth_index = actionable_body.find("if ble.status == .poweredOff")
        battery_index = actionable_body.find("let battery = batterySnapshot")
        self.assertGreaterEqual(bluetooth_index, 0)
        self.assertGreater(battery_index, bluetooth_index)
        assert_not_contains(self, notifications, "static let active = [recovery, strain, battery, diagnostic]")
        assert_not_contains(self, notifications, "static let active = [recovery, strain, battery, bluetoothOff, diagnostic]")
        assert_not_contains(self, notifications, "includeMetricDecisions: productionCadence || debugMetricRequest")
        assert_not_contains(self, notifications, "monitor_confidence_gated_metric_triggers")
        assert_not_contains(self, notifications, "title: \"Atria diagnostic\"")
        assert_not_contains(self, notifications, "case \"Bluetooth is off\", \"Bluetooth permission needed\":")
        assert_not_contains(self, notifications, 'title: ble.bluetoothPermissionDenied ? "Bluetooth permission needed" : "Bluetooth is off"')

    def test_background_task_plumbing_is_present(self):
        app = source(ROOT / "Atria" / "Atria" / "AtriaApp.swift")
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")
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

        maintenance = re.search(
            r"func performBackgroundMaintenance\(reason: String\) \{(?P<body>.*?)\n    \}",
            sessions,
            re.S,
        )
        self.assertIsNotNone(maintenance)
        maintenance_body = maintenance.group("body")
        for needle in [
            "flushScheduledPersistence(reason:",
            "writeAutomaticSessionBackup(reason: reason)",
            "HealthKitExporter.diagnostics(for: sessions,",
            "ATRIADBG bg_maintenance status=ok",
        ]:
            assert_contains(self, maintenance_body, needle)
        for forbidden in [
            "dailyRollups(",
            "trendSummaries(",
            "detectedActivities(",
        ]:
            assert_not_contains(self, maintenance_body, forbidden)

        bounded_gate = re.search(
            r"private func logBoundedLargeStoreGateStatus\(mode: String,(?P<body>.*?)\n    \}",
            sessions,
            re.S,
        )
        self.assertIsNotNone(bounded_gate)
        bounded_gate_body = bounded_gate.group("body")
        assert_contains(self, bounded_gate_body, "let boundedTrend90 = trendSummaryFast(rest: rest, maxHR: profile.maxHR, days: 90)")
        for forbidden in [
            "dailyRollups(",
            "detectedActivities(",
            "trendSummaries(",
            "aggregateSleepCandidates(",
        ]:
            assert_not_contains(self, bounded_gate_body, forbidden)

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

    def test_recovery_target_zone_first_slice_is_user_visible(self):
        targets = source(ROOT / "Atria" / "Atria" / "AtriaMetricTargets.swift")
        analytics = source(ROOT / "Atria" / "Atria" / "AtriaAnalytics.swift")
        shared = source(ROOT / "Atria" / "Atria" / "AtriaSharedUIComponents.swift")
        overview = source(ROOT / "Atria" / "Atria" / "AtriaOverviewSections.swift")
        vitals = source(ROOT / "Atria" / "Atria" / "AtriaVitalsCollectionSections.swift")
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")
        settings = source(ROOT / "Atria" / "Atria" / "AtriaSettingsView.swift")

        for needle in [
            "struct AtriaMetricTarget: Equatable, Codable",
            "case higherIsBetter",
            "case researchDefault",
            "case .researchDefault: return \"Research default\"",
            "case .personalBaseline: return \"Personal baseline\"",
            "case .userEdited: return \"User edited\"",
            "case .red: return \"Out of range\"",
            "static let recoveryRecommended",
            "greenLower: 67",
            "yellowLower: 34",
            "let optimalRange: ClosedRange<Double>?",
            "let yellowBuffer: Double?",
            "let redThreshold: Double?",
            "let goal: Double?",
            "optimalRange: 67...100",
            "yellowBuffer: 33",
            "redThreshold: 34",
            "goal: 67",
            "static func zone(for value: Double, target: AtriaMetricTarget) -> AtriaMetricZoneLevel",
            "optimalRange.contains(value)",
            "case .targetBand:",
            "\"\\(source.label) · Green >=",
            "yellow \\(Int(yellowLower.rounded()))-\\(Int(greenLower.rounded()) - 1)%",
            "static func recoveryZone(_ pct: Int?, target: AtriaMetricTarget = .recoveryRecommended) -> AtriaMetricZone?",
            "static func strainZone(strain: Double,",
            "greenBand: Double = 1.5",
            "yellowBand: Double = 3.0",
            "AtriaAnalytics.TargetZones.recovery(pct, target: target)",
            "AtriaAnalytics.TargetZones.strain(strain: strain,",
            "target: target,",
            "greenBand: greenBand,",
            "yellowBand: yellowBand)",
            "static func hrvZone(_ rmssd: Int?,",
            "baselineTrusted: Bool",
            "greenRatio: Double = 0.95",
            "yellowRatio: Double = 0.85",
            "AtriaAnalytics.TargetZones.hrv(rmssd,",
            "baselineTrusted: baselineTrusted",
            "greenRatio: greenRatio,",
            "yellowRatio: yellowRatio)",
            "static func restingHeartRateZone(_ bpm: Int?,",
            "baselineTrusted: Bool",
            "greenDelta: Int = 3",
            "yellowDelta: Int = 7",
            "AtriaAnalytics.TargetZones.restingHeartRate(bpm,",
            "baselineTrusted: baselineTrusted",
            "greenDelta: greenDelta,",
            "yellowDelta: yellowDelta)",
            "static func sleepEfficiencyZone(_ efficiency: Double?,",
            "greenLower: Double = 90",
            "yellowLower: Double = 80",
            "AtriaAnalytics.TargetZones.sleepEfficiency(efficiency,",
            "greenLower: greenLower,",
            "yellowLower: yellowLower)",
            "static func sleepDurationZone(_ hours: Double?, goalHours: Double = 8.0) -> AtriaMetricZone?",
            "AtriaAnalytics.TargetZones.sleepDuration(hours, goalHours: goalHours)",
            "static func stepsZone(_ steps: Int?, goal: Int = 8_000) -> AtriaMetricZone?",
            "AtriaAnalytics.TargetZones.steps(steps, goal: goal)",
            "static func activeCaloriesZone(_ calories: Double?, goal: Int = 500) -> AtriaMetricZone?",
            "AtriaAnalytics.TargetZones.activeCalories(calories, goal: goal)",
            "static func vo2TrendZone(_ summary: VO2MaxEstimateSummary,",
            "greenDelta: Double = 0.2",
            "redDelta: Double = -0.2",
            "AtriaAnalytics.TargetZones.vo2Trend(summary,",
            "redDelta: redDelta)",
            "static func biologicalAgeZone(_ summary: BiologicalAgeSummary,",
            "greenOlderDelta: Int = 0",
            "yellowOlderDelta: Int = 3",
            "AtriaAnalytics.TargetZones.biologicalAge(summary,",
            "greenOlderDelta: greenOlderDelta,",
            "yellowOlderDelta: yellowOlderDelta)",
            "static func respiratoryRateZone(_ breathsPerMinute: Double?,",
            "greenDelta: Double = 1.5",
            "yellowDelta: Double = 3.0",
            "AtriaAnalytics.TargetZones.respiratoryRate(breathsPerMinute,",
            "baselineSamples: baselineSamples,",
            "static func skinTemperatureDeviationZone(_ summary: IMUAuditSummary.SkinTemperatureDeviationSummary,",
            "greenDelta: Double = 0.5",
            "yellowDelta: Double = 1.0",
            "AtriaAnalytics.TargetZones.skinTemperatureDeviation(summary,",
            "exclamationmark.circle",
            "exclamationmark.triangle.fill",
            "General wellness guidance only, not medical advice.",
            "struct AtriaMetricZoneInfoSheet: View",
        ]:
            assert_contains(self, targets, needle)

        wrapper_match = re.search(r"extension Metrics \{(?P<body>.*?)\n\}\n\nstruct AtriaMetricZoneInfoSheet", targets, re.S)
        self.assertIsNotNone(wrapper_match)
        wrapper_body = wrapper_match.group("body")
        for forbidden in [
            "let level: AtriaMetricZoneLevel",
            "let recommendation: String",
            "safeGreen",
            "safeYellow",
            "absDelta",
            "trendDelta",
            "guard summary.isReady",
            "Research sleep-only estimate.",
            "General wellness guidance only, not medical advice.",
            "Below your step goal",
            "Restless night",
            "Trending the wrong way",
            "Green within +/-",
        ]:
            assert_not_contains(self, wrapper_body, forbidden)
        self.assertEqual(wrapper_body.count("AtriaAnalytics.TargetZones."), 12)

        for needle in [
            "enum TargetZones",
            "static func recovery(_ pct: Int?,",
            "target: AtriaMetricTarget = .recoveryRecommended",
            "let level = AtriaMetricZone.zone(for: Double(pct), target: target)",
            "Low recovery -- keep today light, hydrate, and get to bed earlier.",
            "static func strain(strain: Double,",
            "safeGreenBand",
            "safeYellowBand",
            "absDelta <= safeGreenBand",
            "absDelta <= safeYellowBand",
            "Recovery-scaled target · Green within +/-%.1f",
            "Strain is inside today's recovery-scaled target band.",
            "You're past today's suggested strain for your recovery -- ease off to protect tomorrow.",
            "static func hrv(_ rmssd: Int?,",
            "baselineTrusted: Bool",
            "guard baselineTrusted,\n                  baselineSamples >= PersonalBaseline.trustedMinimumSamples",
            "baselineSamples >= PersonalBaseline.trustedMinimumSamples",
            "ratio >= safeGreen",
            "ratio >= safeYellow",
            "\"Personal baseline · Green >= \\(greenValue) ms",
            "HRV below your norm -- usually stress, short sleep, alcohol, or heavy load.",
            "static func restingHeartRate(_ bpm: Int?,",
            "guard baselineTrusted,\n                  baselineSamples >= PersonalBaseline.trustedMinimumSamples",
            "delta <= safeGreenDelta",
            "delta <= safeYellowDelta",
            "\"Personal baseline · Green <= \\(baseline + safeGreenDelta) bpm",
            "Resting HR is up vs your norm",
            "static func sleepEfficiency(_ efficiency: Double?,",
            "safeGreen",
            "safeYellow",
            "\"Editable target · Green >= \\(Int(safeGreen.rounded()))%",
            "Restless night -- cut late caffeine or alcohol",
            "static func sleepDuration(_ hours: Double?, goalHours: Double = 8.0) -> AtriaMetricZone?",
            "ratio >= 1.0",
            "ratio >= 0.85",
            "User goal · Green >= %.1fh",
            "Under your sleep need -- aim for about",
            "static func steps(_ steps: Int?, goal: Int = 8_000) -> AtriaMetricZone?",
            "steps >= safeGoal / 2",
            "\"User goal · Green >= \\(safeGoal), yellow",
            "Below your step goal -- a short walk closes the gap.",
            "static func activeCalories(_ calories: Double?, goal: Int = 500) -> AtriaMetricZone?",
            "\"User goal · Green >= \\(safeGoal) kcal",
            "Estimated from heart rate/profile.",
            "static func vo2Trend(_ summary: VO2MaxEstimateSummary,",
            "let trendDelta = summary.trendDelta",
            "trendDelta >= safeGreenDelta",
            "trendDelta <= safeRedDelta",
            "Estimate trend · Green >= +%.1f",
            "Trending the wrong way -- consistent cardio, Zone 2, intervals, and sleep move this most.",
            "static func biologicalAge(_ summary: BiologicalAgeSummary,",
            "guard summary.isReady, let delta = summary.ageDelta else { return nil }",
            "delta <= safeGreenDelta",
            "delta <= safeYellowDelta",
            "Estimate · Green <= +",
            "static func respiratoryRate(_ breathsPerMinute: Double?,",
            "baselineSamples >= 3",
            "absDelta <= safeGreenDelta",
            "absDelta <= safeYellowDelta",
            "Research baseline · Green within +/-%.1f/min",
            "Research sleep-only estimate.",
            "static func skinTemperatureDeviation(_ summary: IMUAuditSummary.SkinTemperatureDeviationSummary,",
            "Research baseline · Green within +/-%.1f delta C",
            "Research relative sleep-only deviation; not an absolute temperature.",
        ]:
            assert_contains(self, analytics, needle)
        assert_not_contains(self, analytics, "guard baselineSamples >= 7, let rmssd")
        assert_not_contains(self, analytics, "guard baselineSamples >= 7, let bpm")

        for needle in [
            "var zone: AtriaMetricZone? = nil",
            "AtriaMetricZoneInfoButton(zone: zone)",
            "AtriaMetricZoneInfoSheet(zone: zone)",
            "Image(systemName: \"info.circle\")",
            "if let zone, zone.showsWarning",
            "parts.append(zone.level.label)",
            "parts.append(zone.targetSummary)",
            "parts.append(\"Tap info for guidance.\")",
            ".accessibilityHint(\"Opens target guidance and general wellness recommendations.\")",
        ]:
            assert_contains(self, shared + overview + vitals, needle)

        for needle in [
            "@AppStorage(\"atria.target.recovery.greenLower\")",
            "@AppStorage(\"atria.target.recovery.yellowLower\")",
            "@AppStorage(\"atria.target.strain.greenBand\")",
            "@AppStorage(\"atria.target.strain.yellowBand\")",
            "@AppStorage(\"atria.target.steps.goal\")",
            "@AppStorage(\"atria.target.calories.goal\")",
            "@AppStorage(\"atria.target.sleep.goalHours\")",
            "@AppStorage(\"atria.target.sleepEfficiency.greenLower\")",
            "@AppStorage(\"atria.target.sleepEfficiency.yellowLower\")",
            "@AppStorage(\"atria.target.hrv.greenRatio\")",
            "@AppStorage(\"atria.target.hrv.yellowRatio\")",
            "@AppStorage(\"atria.target.rhr.greenDelta\")",
            "@AppStorage(\"atria.target.rhr.yellowDelta\")",
            "@AppStorage(\"atria.target.respiratory.greenDelta\")",
            "@AppStorage(\"atria.target.respiratory.yellowDelta\")",
            "@AppStorage(\"atria.target.skinTemp.greenDelta\")",
            "@AppStorage(\"atria.target.skinTemp.yellowDelta\")",
            "@AppStorage(\"atria.target.bioAge.greenOlderDelta\")",
            "@AppStorage(\"atria.target.bioAge.yellowOlderDelta\")",
            "@AppStorage(\"atria.target.vo2.greenDelta\")",
            "@AppStorage(\"atria.target.vo2.redDelta\")",
            "recoveryTarget: AtriaMetricTarget.recovery",
            "strainGreenBand: strainGreenBand",
            "strainYellowBand: strainYellowBand",
            "hrvBaseline: store.baseline.hrvInt",
            "hrvBaselineSamples: store.baseline.hrvSampleCount",
            "hrvBaselineTrusted: store.baseline.hasTrustedHRVBaseline()",
            "hrvGreenRatio: hrvGreenRatio",
            "hrvYellowRatio: hrvYellowRatio",
            "restingBaseline: store.baseline.restingInt",
            "restingBaselineSamples: store.baseline.restingSampleCount",
            "restingBaselineTrusted: store.baseline.hasTrustedRestingBaseline()",
            "restingGreenDelta: restingGreenDelta",
            "restingYellowDelta: restingYellowDelta",
            "respiratoryGreenDelta: respiratoryGreenDelta",
            "respiratoryYellowDelta: respiratoryYellowDelta",
            "skinTemperatureGreenDelta: skinTemperatureGreenDelta",
            "skinTemperatureYellowDelta: skinTemperatureYellowDelta",
            "biologicalAgeGreenOlderDelta: biologicalAgeGreenOlderDelta",
            "biologicalAgeYellowOlderDelta: biologicalAgeYellowOlderDelta",
            "vo2GreenDelta: vo2GreenDelta",
            "vo2RedDelta: vo2RedDelta",
            "stepsGoal: stepsGoal",
            "caloriesGoal: caloriesGoal",
            "sleepGoalHours: sleepGoalHours",
            "sleepEfficiencyGreenLower: sleepEfficiencyGreenLower",
            "sleepEfficiencyYellowLower: sleepEfficiencyYellowLower",
            "zone: recoveryZone",
            "zone: strainZone",
            "zone: hrvZone",
            "zone: sleepDurationZone",
            "zone: sleepEfficiencyZone",
            "zone: restingHeartRateZone",
            "zone: stepsZone",
            "zone: activeCaloriesZone",
            "zone: vo2TrendZone",
            "zone: biologicalAgeZone",
            "zone: respiratoryRateZone",
            "zone: skinTemperatureDeviationZone",
            "Metrics.recoveryZone(hero.recoveryEstimate.percent, target: recoveryTarget)",
            "Metrics.strainZone(strain: hero.strain,",
            "target: hero.guidance.target",
            "greenBand: strainGreenBand",
            "yellowBand: strainYellowBand",
            "Metrics.hrvZone(parseInt(hero.hrvValue),",
            "baselineTrusted: hrvBaselineTrusted",
            "greenRatio: hrvGreenRatio",
            "yellowRatio: hrvYellowRatio",
            "Metrics.restingHeartRateZone(hero.restingHeartRate,",
            "baselineTrusted: restingBaselineTrusted",
            "greenDelta: restingGreenDelta",
            "yellowDelta: restingYellowDelta",
            "Metrics.sleepDurationZone(sleepHistory.latest?.durationHours, goalHours: sleepGoalHours)",
            "Metrics.sleepEfficiencyZone(sleepHistory.latest?.sleepEfficiency,",
            "greenLower: sleepEfficiencyGreenLower",
            "yellowLower: sleepEfficiencyYellowLower",
            "Metrics.stepsZone(live.phoneStepsToday > 0 ? live.phoneStepsToday : nil,",
            "Metrics.activeCaloriesZone(live.liveActiveCalories,",
            "goal: caloriesGoal",
            "Metrics.vo2TrendZone(vo2MaxEstimate,",
            "greenDelta: vo2GreenDelta",
            "redDelta: vo2RedDelta",
            "Metrics.biologicalAgeZone(biologicalAgeSummary,",
            "greenOlderDelta: biologicalAgeGreenOlderDelta",
            "yellowOlderDelta: biologicalAgeYellowOlderDelta",
            "Metrics.respiratoryRateZone(sleepHistory.latest?.respiratoryRate,",
            "baseline: sleepHistory.respiratoryBaselineMean",
            "baselineSamples: sleepHistory.respiratoryBaselineCount",
            "greenDelta: respiratoryGreenDelta",
            "yellowDelta: respiratoryYellowDelta",
            "Metrics.skinTemperatureDeviationZone(sensorSummary.skinTemperatureDeviation,",
            "greenDelta: skinTemperatureGreenDelta",
            "yellowDelta: skinTemperatureYellowDelta",
        ]:
            assert_contains(self, overview, needle)

        for needle in [
            "recoveryTarget: AtriaMetricTarget.recovery",
            "strainGreenBand: strainGreenBand",
            "strainYellowBand: strainYellowBand",
            "AtriaVitalsPulseCardHost(liveStore: liveStore,",
            "homeStatsStore: homeStatsStore,\n                                 store: store,",
            "@ObservedObject var store: SessionStore",
            "@AppStorage(\"atria.target.rhr.greenDelta\") private var restingGreenDelta: Int = 3",
            "@AppStorage(\"atria.target.rhr.yellowDelta\") private var restingYellowDelta: Int = 7",
            "restingHeartRate: homeStatsStore.state.restingHeartRate",
            "AtriaVitalsHRVCardHost(liveStore: liveStore,",
            "heroStore: heroStore,\n                               store: store)",
            "var hrvSDNN: Double?",
            "var hrvPNN50: Double?",
            "var hrvSDNNText: String",
            "var hrvPNN50Text: String",
            "hrvSDNN: ble.hrvSnapshot?.sdnn",
            "hrvPNN50: ble.hrvSnapshot?.pnn50",
            "@AppStorage(\"atria.target.hrv.greenRatio\") private var hrvGreenRatio: Double = 0.95",
            "@AppStorage(\"atria.target.hrv.yellowRatio\") private var hrvYellowRatio: Double = 0.85",
            "hrvBaseline: store.baseline.hrvInt",
            "hrvBaselineSamples: store.baseline.hrvSampleCount",
            "hrvBaselineTrusted: store.baseline.hasTrustedHRVBaseline()",
            "hrvGreenRatio: hrvGreenRatio",
            "hrvYellowRatio: hrvYellowRatio",
            "restingBaseline: store.baseline.restingInt",
            "restingBaselineSamples: store.baseline.restingSampleCount",
            "restingBaselineTrusted: store.baseline.hasTrustedRestingBaseline()",
            "restingGreenDelta: restingGreenDelta",
            "restingYellowDelta: restingYellowDelta",
            "respiratoryGreenDelta: respiratoryGreenDelta",
            "respiratoryYellowDelta: respiratoryYellowDelta",
            "@AppStorage(\"atria.target.steps.goal\") private var stepsGoal: Int = 8_000",
            "biologicalAgeGreenOlderDelta: biologicalAgeGreenOlderDelta",
            "biologicalAgeYellowOlderDelta: biologicalAgeYellowOlderDelta",
            "sleepGoalHours: sleepGoalHours",
            "sleepEfficiencyGreenLower: sleepEfficiencyGreenLower",
            "sleepEfficiencyYellowLower: sleepEfficiencyYellowLower",
            "zone: recoveryZone",
            "zone: strainZone",
            "zone: restingHeartRateZone",
            "zone: sleepDurationZone",
            "zone: sleepEfficiencyZone",
            "zone: hrvZone",
            "zone: vo2TrendZone",
            "zone: biologicalAgeZone",
            "zone: respiratoryRateZone",
            "zone: strapStepsZone",
            "zone: skinTemperatureDeviationZone",
            "Metrics.restingHeartRateZone(restingHeartRate,",
            "baselineTrusted: restingBaselineTrusted",
            "tint: restingHeartRateZone?.tint ?? .blue",
            "Metrics.hrvZone(Self.parseInt(hero.hrvValue),",
            "baselineTrusted: hrvBaselineTrusted",
            "tint: hrvZone?.tint ?? .pink",
            "AtriaMetricTile(label: \"SDNN\"",
            "value: live.hrvSDNNText",
            "unit: live.hrvSDNN == nil ? nil : \"ms\"",
            "Secondary HRV metric from the same clean RR window.",
            "AtriaMetricTile(label: \"pNN50\"",
            "value: live.hrvPNN50Text",
            "Share of adjacent beat intervals differing by more than 50 ms.",
            "Metrics.recoveryZone(hero.recoveryEstimate.percent, target: recoveryTarget)",
            "Metrics.strainZone(strain: hero.strain,",
            "target: hero.guidance.target",
            "greenBand: strainGreenBand",
            "yellowBand: strainYellowBand",
            "Metrics.restingHeartRateZone(snapshot.latest?.restingHR,",
            "baselineTrusted: restingBaselineTrusted",
            "greenDelta: restingGreenDelta",
            "yellowDelta: restingYellowDelta",
            "Metrics.sleepDurationZone(snapshot.latest?.durationHours, goalHours: sleepGoalHours)",
            "Metrics.sleepEfficiencyZone(snapshot.latest?.sleepEfficiency,",
            "Metrics.hrvZone(snapshot.latest?.hrv,",
            "baselineTrusted: hrvBaselineTrusted",
            "greenRatio: hrvGreenRatio",
            "yellowRatio: hrvYellowRatio",
            "Metrics.vo2TrendZone(vo2MaxEstimate,",
            "greenDelta: vo2GreenDelta",
            "redDelta: vo2RedDelta",
            "Metrics.biologicalAgeZone(biologicalAgeSummary,",
            "greenOlderDelta: biologicalAgeGreenOlderDelta",
            "yellowOlderDelta: biologicalAgeYellowOlderDelta",
            "Metrics.respiratoryRateZone(snapshot.latest?.respiratoryRate,",
            "baseline: snapshot.respiratoryBaselineMean",
            "baselineSamples: snapshot.respiratoryBaselineCount",
            "greenDelta: respiratoryGreenDelta",
            "yellowDelta: respiratoryYellowDelta",
            "Metrics.stepsZone(summary.strapStepCount > 0 ? summary.strapStepCount : nil,",
            "goal: stepsGoal",
            "title: \"Strap step research goal\"",
            "Strap steps remain research-tier until motion agreement is validated.",
            "Research strap-step estimate. \\(AtriaMetricZone.nonMedicalDisclaimer)",
            "Metrics.skinTemperatureDeviationZone(summary.skinTemperatureDeviation,",
            "greenDelta: skinTemperatureGreenDelta",
            "yellowDelta: skinTemperatureYellowDelta",
        ]:
            assert_contains(self, vitals + home, needle)

        for path in [overview, vitals]:
            assert_not_contains(self, path, "let baselineValues = sleepHistory.nights.dropFirst().compactMap(\\.respiratoryRate)")
            assert_not_contains(self, path, "let baselineValues = snapshot.nights.dropFirst().compactMap(\\.respiratoryRate)")

        for needle in [
            "targetsSection",
            "Text(\"Targets & zones\")",
            "Stepper(value: $recoveryGreenLower",
            "Stepper(value: $recoveryYellowLower",
            "Stepper(value: $strainGreenBand",
            "Stepper(value: $strainYellowBand",
            "Stepper(value: $stepsGoal",
            "Stepper(value: $caloriesGoal",
            "Stepper(value: $sleepGoalHours",
            "Stepper(value: $sleepEfficiencyGreenLower",
            "Stepper(value: $sleepEfficiencyYellowLower",
            "Stepper(value: $hrvGreenRatio",
            "Stepper(value: $hrvYellowRatio",
            "Stepper(value: $restingGreenDelta",
            "Stepper(value: $restingYellowDelta",
            "Stepper(value: $respiratoryGreenDelta",
            "Stepper(value: $respiratoryYellowDelta",
            "Stepper(value: $skinTemperatureGreenDelta",
            "Stepper(value: $skinTemperatureYellowDelta",
            "Stepper(value: $biologicalAgeGreenOlderDelta",
            "Stepper(value: $biologicalAgeYellowOlderDelta",
            "Stepper(value: $vo2GreenDelta",
            "Stepper(value: $vo2RedDelta",
            "Reset to recommended",
            "Reset strain band",
            "Reset activity targets",
            "Reset sleep targets",
            "Reset baseline targets",
            "Reset research targets",
            "Reset body-age target",
            "Reset VO2 trend target",
            "recoveryGreenLower = 67",
            "recoveryYellowLower = 34",
            "strainGreenBand = 1.5",
            "strainYellowBand = 3.0",
            "caloriesGoal = 500",
            "sleepGoalHours = 8.0",
            "sleepEfficiencyGreenLower = 90",
            "sleepEfficiencyYellowLower = 80",
            "hrvGreenRatio = 0.95",
            "hrvYellowRatio = 0.85",
            "restingGreenDelta = 3",
            "restingYellowDelta = 7",
            "respiratoryGreenDelta = 1.5",
            "respiratoryYellowDelta = 3.0",
            "skinTemperatureGreenDelta = 0.5",
            "skinTemperatureYellowDelta = 1.0",
            "biologicalAgeGreenOlderDelta = 0",
            "biologicalAgeYellowOlderDelta = 3",
            "vo2GreenDelta = 0.2",
            "vo2RedDelta = -0.2",
            "normalizeRecoveryTargets()",
            "normalizeStrainTargets()",
            "normalizeStepsGoal()",
            "normalizeCaloriesGoal()",
            "normalizeSleepGoal()",
            "normalizeSleepEfficiencyTargets()",
            "normalizeHRVTargets()",
            "normalizeRestingTargets()",
            "normalizeRespiratoryTargets()",
            "normalizeSkinTemperatureTargets()",
            "normalizeBiologicalAgeTargets()",
            "normalizeVO2Targets()",
            r"HRV and resting HR zones personalize from your trusted \(PersonalBaseline.trustedMinimumSamples)-sample baseline before warning.",
            "Guidance is general wellness information, not medical advice.",
        ]:
            assert_contains(self, settings, needle)
        assert_not_contains(self, settings, "7-night baseline")

    def test_pure_analytics_calibration_examples_are_monotonic_and_gated(self):
        analytics = source(ROOT / "Atria" / "Atria" / "AtriaAnalytics.swift")
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")

        for needle in [
            "enum BiologicalAge",
            "static func summary(chronologicalAge: Int, factors: [BioAgeFactor]) -> BiologicalAgeSummary",
            "static func vo2AgeEquivalent(_ vo2: Double, sex: AthleteProfile.BiologicalSex) -> Int",
            "static func rhrAgeEquivalent(_ restingHR: Int) -> Int",
            "static func hrvAgeEquivalent(_ rmssd: Int) -> Int",
            "static func sleepAgeEquivalent(durationHours: Double,",
            "consistencyPercent: Int?",
            "static func activityAgeEquivalent(_ chronicLoad: Double,",
            "static func bmiAgeEquivalent(_ bmi: Double,",
            "static func acwrReadinessSignal(ratio: Double?, enoughChronic: Bool) -> String",
            "static func monotonyReadinessSignal(monotony: Double?, enoughAcute: Bool) -> String",
            "static func trainingReadiness(acwrSignal: String,",
        ]:
            assert_contains(self, analytics, needle)

        for needle in [
            "guard let vo2Max = vo2MaxEstimate.value else",
            "baseline.hasTrustedRestingBaseline()",
            "baseline.hasTrustedHRVBaseline()",
            "guard sleepNights.count >= 3 else",
            "trainingLoadSummarySnapshot.confidence == \"local\"",
        ]:
            assert_contains(self, sessions, needle)

        def interpolated_age(value, reference, higher_is_younger):
            if higher_is_younger:
                if value >= reference[0][1]:
                    return 18
                if value <= reference[-1][1]:
                    return 90
            else:
                if value <= reference[0][1]:
                    return 18
                if value >= reference[-1][1]:
                    return 90
            for index in range(1, len(reference)):
                previous_age, previous_value = reference[index - 1]
                next_age, next_value = reference[index]
                inside = previous_value >= value >= next_value if higher_is_younger else previous_value <= value <= next_value
                if inside:
                    numerator = previous_value - value if higher_is_younger else value - previous_value
                    fraction = numerator / max(abs(previous_value - next_value), 0.01)
                    return min(max(round(previous_age + fraction * (next_age - previous_age)), 18), 90)
            return 90

        def vo2_age(vo2, sex):
            reference = (
                [(20, 44.0), (30, 41.0), (40, 38.0), (50, 35.0), (60, 32.0), (70, 29.0), (80, 26.0), (90, 23.0)]
                if sex == "female"
                else [(20, 52.0), (30, 48.5), (40, 45.0), (50, 41.5), (60, 38.0), (70, 34.5), (80, 31.0), (90, 27.5)]
            )
            return interpolated_age(vo2, reference, True)

        def rhr_age(resting_hr):
            return interpolated_age(resting_hr, [(20, 58), (30, 60), (40, 62), (50, 64), (60, 66), (70, 68), (80, 70), (90, 72)], False)

        def hrv_age(rmssd):
            return interpolated_age(rmssd, [(20, 70), (30, 58), (40, 46), (50, 36), (60, 28), (70, 22), (80, 18), (90, 14)], True)

        def sleep_age(duration_hours, efficiency, chronological_age, consistency_percent=None):
            duration_penalty = abs(duration_hours - 7.5) * 2.0
            efficiency_penalty = max(0, 0.85 - efficiency) * 35
            consistency_penalty = max(0, 80 - consistency_percent) / 8.0 if consistency_percent is not None else 0
            bonus = -4.0 if duration_penalty < 1.0 and efficiency >= 0.88 and (consistency_percent or 80) >= 85 else 0
            return min(max(round(chronological_age + duration_penalty + efficiency_penalty + consistency_penalty + bonus), 18), 90)

        def activity_age(chronic_load, chronological_age):
            delta = min(max((chronic_load - 25) / 3.0, -8), 8)
            return min(max(round(chronological_age - delta), 18), 90)

        def bmi_age(bmi, chronological_age):
            penalty = (18.5 - bmi) * 1.2 if bmi < 18.5 else max(0, bmi - 24.9) * 0.8
            return min(max(round(chronological_age + penalty), 18), 90)

        def biological_age(chronological_age, weighted_factors):
            weighted = sum(age * weight for age, weight in weighted_factors)
            total_weight = sum(weight for _, weight in weighted_factors)
            unclamped = round(weighted / max(total_weight, 0.01))
            return min(max(unclamped, chronological_age - 20), chronological_age + 20)

        self.assertLess(vo2_age(56, "male"), vo2_age(40, "male"))
        self.assertLess(vo2_age(48, "female"), vo2_age(34, "female"))
        self.assertLess(hrv_age(80), hrv_age(30))
        self.assertLess(rhr_age(52), rhr_age(75))
        self.assertLess(sleep_age(7.6, 0.91, 38, 92), sleep_age(5.5, 0.78, 38, 55))
        self.assertLess(activity_age(40, 38), activity_age(8, 38))
        self.assertLess(bmi_age(22.0, 38), bmi_age(32.0, 38))

        strong_factors = [
            (vo2_age(55, "male"), 0.30),
            (rhr_age(55), 0.20),
            (hrv_age(70), 0.20),
            (sleep_age(7.5, 0.90, 38, 92), 0.15),
            (activity_age(36, 38), 0.10),
            (bmi_age(22.0, 38), 0.05),
        ]
        weak_factors = [
            (vo2_age(28, "male"), 0.30),
            (rhr_age(82), 0.20),
            (hrv_age(16), 0.20),
            (sleep_age(5.2, 0.74, 38, 50), 0.15),
            (activity_age(3, 38), 0.10),
            (bmi_age(35.0, 38), 0.05),
        ]
        self.assertLess(biological_age(38, strong_factors), 38)
        self.assertEqual(biological_age(38, weak_factors), 58)

        def acwr_signal(ratio, enough_chronic):
            if not enough_chronic or ratio is None:
                return "learning"
            if ratio >= 1.50 or ratio < 0.60:
                return "bad"
            if ratio > 1.30 or ratio < 0.80:
                return "watch"
            return "good"

        def monotony_signal(monotony, enough_acute):
            if not enough_acute or monotony is None:
                return "learning"
            if monotony >= 2.50:
                return "bad"
            if monotony >= 2.00:
                return "watch"
            return "good"

        def training_readiness(acwr, monotony, ratio):
            if acwr == "learning" and monotony == "learning":
                return "learning"
            if acwr == "bad" or monotony == "bad":
                return "rundown"
            if acwr == "watch" or monotony == "watch":
                return "strained"
            if ratio is not None and ratio < 0.80:
                return "primed"
            return "balanced"

        def inferred_manual_sleep_is_nap(duration_seconds, start_hour, end_hour, current_selection=False):
            if duration_seconds <= 0:
                return current_selection
            if duration_seconds >= 3 * 60 * 60:
                return False
            if duration_seconds < 20 * 60:
                return current_selection
            daytime_window = start_hour >= 11 and end_hour <= 20
            return daytime_window or duration_seconds < 3 * 60 * 60

        def edwards_weight(reserve):
            if reserve >= 0.90:
                return 5
            if reserve >= 0.80:
                return 4
            if reserve >= 0.70:
                return 3
            if reserve >= 0.60:
                return 2
            if reserve >= 0.50:
                return 1
            return 0

        def edwards_load(series, rest, max_hr):
            total = 0
            span = max_hr - rest
            for previous, current in zip(series, series[1:]):
                dt_min = (current[0] - previous[0]) / 60
                reserve = min(max((current[1] - rest) / span, 0), 1)
                total += dt_min * edwards_weight(reserve)
            return total

        def max_hr_zone_raw_value(bpm, max_hr):
            fraction = bpm / max_hr
            if fraction >= 0.90:
                return 5
            if fraction >= 0.80:
                return 4
            if fraction >= 0.70:
                return 3
            if fraction >= 0.60:
                return 2
            if fraction >= 0.50:
                return 1
            return 0

        def max_hr_zone_seconds(series, max_hr, max_gap=5 * 60):
            buckets = [0, 0, 0, 0, 0, 0]
            dropped = 0
            for previous, current in zip(series, series[1:]):
                dt = current[0] - previous[0]
                if dt <= 0:
                    continue
                if dt >= max_gap:
                    dropped += dt
                    continue
                buckets[max_hr_zone_raw_value(current[1], max_hr)] += dt
            return buckets, dropped

        def steps_daily(samples):
            steps = 0
            distance = 0
            floors_up = 0
            floors_down = 0
            has_distance = False
            has_up = False
            has_down = False
            for sample in samples:
                steps += max(0, sample.get("steps", 0))
                meters = sample.get("distance")
                if meters is not None and meters > 0:
                    distance += meters
                    has_distance = True
                up = sample.get("up")
                if up is not None and up > 0:
                    floors_up += up
                    has_up = True
                down = sample.get("down")
                if down is not None and down > 0:
                    floors_down += down
                    has_down = True
            return {
                "steps": steps,
                "distance": distance if has_distance else None,
                "up": floors_up if has_up else None,
                "down": floors_down if has_down else None,
            }

        def day_calories(samples, rest, sex, age, weight):
            def kcal_per_min(hr):
                if sex == "male":
                    return max(0, (-55.0969 + 0.6309 * hr + 0.1988 * weight + 0.2017 * age) / 4.184)
                if sex == "female":
                    return max(0, (-20.4022 + 0.4472 * hr - 0.1263 * weight + 0.0740 * age) / 4.184)
                return 0

            resting = kcal_per_min(rest)
            total = 0
            for previous, current in zip(samples, samples[1:]):
                dt_min = (current[0] - previous[0]) / 60
                if dt_min <= 0 or dt_min >= 5 or current[1] <= 0:
                    continue
                total += max(0, kcal_per_min(current[1]) - resting) * dt_min
            return total

        def resp_rate_rsa(resampled, sample_rate=4.0):
            mean = sum(resampled) / len(resampled)
            centered = [value - mean for value in resampled]
            best_rate = 0
            best_power = 0
            band_power = 0
            for step in range(12, 61):
                bpm = step / 2
                frequency = bpm / 60
                real = 0
                imaginary = 0
                for index, value in enumerate(centered):
                    angle = 2 * math.pi * frequency * index / sample_rate
                    real += value * math.cos(angle)
                    imaginary -= value * math.sin(angle)
                power = real * real + imaginary * imaginary
                band_power += power
                if power > best_power:
                    best_power = power
                    best_rate = bpm
            if best_power <= 0 or best_power / max(band_power, best_power) < 0.18:
                return None
            return best_rate

        self.assertEqual(acwr_signal(None, False), "learning")
        self.assertEqual(acwr_signal(1.55, True), "bad")
        self.assertEqual(acwr_signal(1.31, True), "watch")
        self.assertEqual(acwr_signal(1.00, True), "good")
        self.assertEqual(monotony_signal(2.6, True), "bad")
        self.assertEqual(monotony_signal(2.1, True), "watch")
        self.assertEqual(monotony_signal(1.4, True), "good")
        self.assertEqual(training_readiness("bad", "good", 1.6), "rundown")
        self.assertEqual(training_readiness("watch", "good", 1.35), "strained")
        self.assertEqual(training_readiness("good", "good", 0.75), "primed")
        self.assertEqual(training_readiness("good", "good", 1.0), "balanced")
        self.assertTrue(inferred_manual_sleep_is_nap(45 * 60, 14, 15))
        self.assertFalse(inferred_manual_sleep_is_nap(8 * 60 * 60, 23, 7))
        self.assertTrue(inferred_manual_sleep_is_nap(-60, 14, 15, current_selection=True))
        self.assertEqual([edwards_weight(x) for x in [0.49, 0.50, 0.61, 0.72, 0.83, 0.94]], [0, 1, 2, 3, 4, 5])
        self.assertEqual(edwards_load([(0, 100), (60, 130), (120, 150), (180, 170)], 60, 180), 9)
        self.assertEqual([max_hr_zone_raw_value(bpm, 200) for bpm in [80, 100, 120, 140, 160, 180]], [0, 1, 2, 3, 4, 5])
        self.assertEqual(max_hr_zone_seconds([(0, 90), (60, 110), (120, 130), (180, 150), (240, 170), (300, 190), (900, 190)], 200),
                         ([0, 60, 60, 60, 60, 60], 600))
        self.assertEqual(steps_daily([
            {"steps": 120, "distance": 80, "up": 1, "down": 0},
            {"steps": -20, "distance": None, "up": None, "down": 2},
            {"steps": 380, "distance": 220, "up": 3, "down": -1},
        ]), {"steps": 500, "distance": 300, "up": 4, "down": 2})
        self.assertGreater(day_calories([(0, 60), (60, 130), (120, 150)], 60, "male", 35, 75), 4.0)
        self.assertEqual(day_calories([(0, 60), (600, 150)], 60, "male", 35, 75), 0)
        synthetic_rr = [800 + 45 * math.sin(2 * math.pi * (15 / 60) * index / 4) for index in range(4 * 90)]
        self.assertEqual(resp_rate_rsa(synthetic_rr), 15)


if __name__ == "__main__":
    unittest.main()
