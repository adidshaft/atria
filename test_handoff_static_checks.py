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
            "enum AtriaDesignTokens",
            "func atriaCard(",
            "func atriaRaisedCard(",
        ]:
            assert_contains(self, text, needle)

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

        for needle in [
            "case personalBaseline = \"personal baseline\"",
            "external reference validation upgrades the confidence tier",
            "but does not block in-app display",
            "hrvReferenceValidated ? .validated : .personalBaseline",
        ]:
            assert_contains(self, text, needle)

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


if __name__ == "__main__":
    unittest.main()
