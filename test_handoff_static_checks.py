#!/usr/bin/env python3
import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent
APP_ROOTS = [ROOT / "WhoopApp" / "WhoopApp", ROOT / "WhoopApp" / "WhoopWidget"]


def swift_files():
    for root in APP_ROOTS:
        yield from root.rglob("*.swift")


def source(path):
    return path.read_text(encoding="utf-8")


def all_swift_source():
    return "\n".join(source(path) for path in swift_files())


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

        for needle in [
            "TabView(selection:",
            ".tabBarMinimizeBehavior(.onScrollDown)",
            ".tabViewBottomAccessory",
            ".scrollEdgeEffectStyle(.soft, for: .top)",
            "enum AtriaDesignTokens",
            "func atriaCard(",
            "func atriaRaisedCard(",
        ]:
            assert_contains(self, text, needle)

        assert_not_contains(self, text, ".fill(baseFill)\n            .glassEffect")

    def test_standard_hr_only_mode_blocks_strap_writes(self):
        text = source(ROOT / "WhoopApp" / "WhoopApp" / "WhoopBLEManager.swift")
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

    def test_production_capture_defaults_land_on_balanced_profile(self):
        text = source(ROOT / "WhoopApp" / "WhoopApp" / "WhoopBLEManager.swift")

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

    def test_state_restoration_reuses_standard_hr_only_peripheral(self):
        text = source(ROOT / "WhoopApp" / "WhoopApp" / "WhoopBLEManager.swift")

        for needle in [
            "self.forceFreshScanOnRestore && !self.standardHROnlyMode",
            "self.forceFreshScanOnRestore && self.standardHROnlyMode",
            "WHOOPDBG ble_restore status=reuse_restored reason=standard_hr_only",
            "WHOOPDBG ble_restore status=discarded reason=full_protocol_fresh_scan",
            "recordLinkObservedConnected(reason: \"state_restore_connected\"",
            "central.connect(restoredPeripheral, options: nil)",
        ]:
            assert_contains(self, text, needle)

    def test_healthkit_hrv_export_uses_validated_sdnn_only(self):
        text = source(ROOT / "WhoopApp" / "WhoopApp" / "HealthKitExporter.swift")

        for needle in [
            "private var hrvType",
            ".heartRateVariabilitySDNN",
            "if let sdnn = session.referenceValidatedSDNN, sdnn > 0",
        ]:
            assert_contains(self, text, needle)
        for needle in ["referenceValidatedRMSSD", "rmssdExported"]:
            assert_not_contains(self, text, needle)

    def test_healthkit_rhr_and_respiratory_rate_export_use_correct_types(self):
        text = source(ROOT / "WhoopApp" / "WhoopApp" / "HealthKitExporter.swift")

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

    def test_validate_later_recovery_displays_personal_baseline_before_validation(self):
        text = source(ROOT / "WhoopApp" / "WhoopApp" / "Metrics.swift")
        docs = "\n".join(source(path) for path in (ROOT / "docs").rglob("*.md"))

        for needle in [
            "case personalBaseline = \"personal baseline\"",
            "external reference validation upgrades the confidence tier",
            "but does not block in-app display",
            "hrvReferenceValidated ? .validated : .personalBaseline",
        ]:
            assert_contains(self, text, needle)

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
            "MPNowPlayingInfoCenter.default().nowPlayingInfo",
            "MPMusicPlayerController.systemMusicPlayer",
            "CXCallObserver",
            "import ActivityKit",
            "ControlWidget",
            "AppIntent",
        ]
        for needle in required:
            assert_contains(self, text, needle)

    def test_ai_coach_local_mode_is_explicitly_offline(self):
        text = source(ROOT / "WhoopApp" / "WhoopApp" / "AtriaAICoach.swift")

        for needle in [
            "enum AtriaCoachNetworkPolicy",
            "case offlineOnly",
            "case cloudDisabled",
            "let networkPolicy: AtriaCoachNetworkPolicy = .offlineOnly",
            "let networkPolicy: AtriaCoachNetworkPolicy = .cloudDisabled",
            "No data leaves this iPhone.",
            "Network requests stay disabled until a reviewed provider client is added.",
            "provider client pending",
        ]:
            assert_contains(self, text, needle)

        card = source(ROOT / "WhoopApp" / "WhoopApp" / "AtriaAICoachCard.swift")
        assert_contains(self, card, "does not send metrics until a reviewed")
        assert_contains(self, card, "Enable local mode for an offline summary")
        assert_not_contains(self, card, "sends selected local metrics")

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
        entitlements = source(ROOT / "WhoopApp" / "WhoopApp" / "AtriaEntitlements.swift")

        for needle in [
            "struct AtriaEntitlements",
            "enum Feature",
            "enum Tier",
            "case paidApp",
            "case premium",
            "EnvironmentValues",
            "atriaEntitlements",
        ]:
            assert_contains(self, entitlements, needle)

        for forbidden in [
            "import StoreKit",
            "Product.products",
            "SubscriptionStoreView",
            "StoreView",
            "Purchase",
        ]:
            assert_not_contains(self, app_text, forbidden)

    def test_developer_only_surfaces_are_hidden_by_default(self):
        developer_mode = source(ROOT / "WhoopApp" / "WhoopApp" / "AtriaDeveloperMode.swift")
        home = source(ROOT / "WhoopApp" / "WhoopApp" / "AtriaHomeView.swift")
        collection = source(ROOT / "WhoopApp" / "WhoopApp" / "AtriaVitalsCollectionSections.swift")

        for needle in [
            "enum AtriaDeveloperMode",
            "defaultsKey = \"atria.developerMode.enabled\"",
            "launchArgument = \"--atria-developer-mode\"",
            "UserDefaults.standard.bool(forKey: defaultsKey)",
        ]:
            assert_contains(self, developer_mode, needle)

        for needle in [
            "@State private var developerModeEnabled = AtriaDeveloperMode.isEnabled",
            "developerModeEnabled: developerModeEnabled",
        ]:
            assert_contains(self, home, needle)

        for needle in [
            "let developerModeEnabled: Bool",
            "if developerModeEnabled {\n                            rrReferenceCard",
            "if developerModeEnabled {\n                    AtriaCollectionToggleCard",
            "title: \"Standard HR radio\"",
            "subtitle: \"Advanced compatibility mode for heart-rate-only collection.\"",
        ]:
            assert_contains(self, collection, needle)

        for forbidden in [
            "title: \"Low radio HR\"",
            "Developer option for standard heart-rate-only collection.",
            "subtitle: \"Native RR window and reference flow\"",
            "AtriaInlineQuickStat(label: \"Reference\"",
            "AtriaInlineQuickStat(label: \"RR package\"",
        ]:
            assert_not_contains(self, collection, forbidden)

    def test_live_activity_uses_end_user_reading_language(self):
        app_attributes = source(ROOT / "WhoopApp" / "WhoopApp" / "AtriaLiveActivityAttributes.swift")
        widget_attributes = source(ROOT / "WhoopApp" / "WhoopWidget" / "AtriaLiveActivityAttributes.swift")
        coordinator = source(ROOT / "WhoopApp" / "WhoopApp" / "AtriaLiveActivityCoordinator.swift")
        widget = source(ROOT / "WhoopApp" / "WhoopWidget" / "WhoopWidget.swift")
        home = source(ROOT / "WhoopApp" / "WhoopApp" / "AtriaHomeView.swift")

        for text in [app_attributes, widget_attributes, coordinator]:
            assert_contains(self, text, "readingCount")
            assert_not_contains(self, text, "sampleCount")

        assert_contains(self, home, "readingCount: model.coreLiveStore.state.sessionSampleCount")
        assert_contains(self, widget, "context.state.readingCount")
        assert_contains(self, widget, "readings ·")
        assert_not_contains(self, widget, "samples ·")

    def test_live_activity_updates_are_throttled_off_the_sample_hot_path(self):
        coordinator = source(ROOT / "WhoopApp" / "WhoopApp" / "AtriaLiveActivityCoordinator.swift")

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

    def test_backdrop_respects_reduce_transparency(self):
        shell = source(ROOT / "WhoopApp" / "WhoopApp" / "AtriaHomeShellSupport.swift")
        home = source(ROOT / "WhoopApp" / "WhoopApp" / "AtriaHomeView.swift")
        guide = source(ROOT / "WhoopApp" / "WhoopApp" / "AtriaHeroConnectionSections.swift")

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
        home = source(ROOT / "WhoopApp" / "WhoopApp" / "AtriaHomeView.swift")
        overview = source(ROOT / "WhoopApp" / "WhoopApp" / "AtriaOverviewSections.swift")
        collection = source(ROOT / "WhoopApp" / "WhoopApp" / "AtriaVitalsCollectionSections.swift")
        content = source(ROOT / "WhoopApp" / "WhoopApp" / "ContentView.swift")
        heart_rate = source(ROOT / "WhoopApp" / "WhoopApp" / "HeartRate.swift")

        for text in [home, overview, collection, content, heart_rate]:
            assert_contains(self, text, "accessibilityReduceMotion")

        assert_contains(self, home, "private func performMotionAwareUpdate")
        assert_contains(self, home, "if reduceMotion")
        assert_contains(self, heart_rate, ".animation(reduceMotion ? nil")

    def test_end_user_copy_avoids_lab_only_language(self):
        content = source(ROOT / "WhoopApp" / "WhoopApp" / "ContentView.swift")
        hero = source(ROOT / "WhoopApp" / "WhoopApp" / "AtriaHeroConnectionSections.swift")
        overview = source(ROOT / "WhoopApp" / "WhoopApp" / "AtriaOverviewSections.swift")
        sessions = source(ROOT / "WhoopApp" / "WhoopApp" / "Sessions.swift")
        intents = source(ROOT / "WhoopApp" / "WhoopApp" / "AtriaAppIntents.swift")

        assert_contains(self, content, "Not counted as workout until activity evidence is stronger.")
        assert_contains(self, content, "Current segment is HR-only; saved HRV window stays ready.")
        assert_contains(self, hero, "Saved metrics and backup remain on device while Atria waits for the strap again.")
        assert_contains(self, overview, "Saved metrics and backup remain available while the strap reconnects.")
        assert_contains(self, overview, "AtriaInlineQuickStat(label: \"Validation\"")
        assert_contains(self, overview, "AtriaInlineQuickStat(label: \"HRV window\"")
        assert_contains(self, sessions, "Rest candidates are recovery context only; they do not count as sleep.")

        for text in [content, hero, overview, sessions]:
            for forbidden in [
                "Not counted as workout until HR/reference evidence is stronger.",
                "saved RR package stays ready.",
                "Saved references and backup remain available while the strap reconnects.",
                "Saved references and backup remain on device while Atria waits for the strap again.",
                "Rest candidates are diagnostic only; they do not count as sleep.",
            ]:
                assert_not_contains(self, text, forbidden)
        assert_not_contains(self, overview, "AtriaInlineQuickStat(label: \"Reference\"")
        assert_not_contains(self, overview, "AtriaInlineQuickStat(label: \"RR package\"")
        assert_contains(self, intents, "subtitle: \"Start live collection\"")
        assert_contains(self, intents, "subtitle: \"Arm overnight collection\"")
        assert_not_contains(self, intents, "low-radio")

    def test_user_path_debug_logs_are_gated(self):
        for rel in [
            ROOT / "WhoopApp" / "WhoopApp" / "ContentView.swift",
            ROOT / "WhoopApp" / "WhoopApp" / "WidgetSnapshot.swift",
            ROOT / "WhoopApp" / "WhoopApp" / "AtriaHomeView.swift",
            ROOT / "WhoopApp" / "WhoopApp" / "AtriaOverviewSections.swift",
            ROOT / "WhoopApp" / "WhoopApp" / "AtriaVitalsCollectionSections.swift",
            ROOT / "WhoopApp" / "WhoopApp" / "HealthKitExporter.swift",
        ]:
            text = source(rel)
            assert_not_contains(self, text, "NSLog(\"WHOOPDBG")

        assert_not_contains(self, all_swift_source(), "NSLog(\"WHOOPDBG")
        debug_logging = source(ROOT / "WhoopApp" / "WhoopApp" / "WhoopDebugLogging.swift")
        assert_contains(self, debug_logging, "guard WhoopDebugLogging.isEnabled else { return }")
        assert_contains(self, debug_logging, "NSLogv(String(describing: format), pointer)")

    def test_diagnostic_notifications_are_not_production_active(self):
        notifications = source(ROOT / "WhoopApp" / "WhoopApp" / "LocalNotificationScheduler.swift")

        assert_contains(self, notifications, "static let active = [recovery, strain, battery]")
        assert_contains(self, notifications, "static let diagnosticOnly = [diagnostic]")
        assert_contains(self, notifications, "static let removable = active + diagnosticOnly + legacy")
        assert_not_contains(self, notifications, "static let active = [recovery, strain, battery, diagnostic]")

    def test_background_task_plumbing_is_present(self):
        app = source(ROOT / "WhoopApp" / "WhoopApp" / "WhoopAppApp.swift")
        plist = source(ROOT / "WhoopApp" / "Info.plist")

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

    def test_unsavable_active_journals_are_cleared_during_recovery(self):
        text = source(ROOT / "WhoopApp" / "WhoopApp" / "WhoopBLEManager.swift")

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


if __name__ == "__main__":
    unittest.main()
