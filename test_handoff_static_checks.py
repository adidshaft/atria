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
        ]:
            assert_contains(self, text, needle)

        assert_not_contains(self, text, ".fill(baseFill)\n            .glassEffect")
        assert_not_contains(self, text, "Tab(\"Today\"")
        assert_not_contains(self, text, "Tab(\"Vitals\"")
        assert_not_contains(self, text, "Tab(\"Data\"")

    def test_top_left_status_restores_original_chip_and_labels(self):
        home = source(ROOT / "WhoopApp" / "WhoopApp" / "AtriaHomeView.swift")

        for needle in [
            "ToolbarItem(placement: .topBarLeading)",
            "AtriaLiquidStatusPillBackground(tint: statusTint)",
            ".onTapGesture",
            "ble.startScan(reason: \"home_status_chip\")",
            "case .connected: return \"Live\"",
            "case .connecting: return \"Connecting\"",
            "case .scanning: return \"Searching\"",
            "case .poweredOff: return \"Bluetooth off\"",
            "case .disconnected: return \"Disconnected\"",
            "case .connected: return .green",
            "case .connecting: return .yellow",
            "case .scanning: return .cyan",
            "case .poweredOff: return .red",
            "case .disconnected: return .blue",
            "HStack(spacing: 7)",
            ".buttonBorderShape(.circle)",
        ]:
            assert_contains(self, home, needle)

        for forbidden in [
            "ble.startScan(reason: \"home_status_button\")",
            ".glassEffect(.regular.tint(statusTint.opacity(0.24)).interactive(), in: .capsule)",
            "case .connected: return \"Live/Connected\"",
            "case .connecting, .scanning: return \"Connecting...\"",
            "case .poweredOff, .disconnected: return \"Not Connected\"",
        ]:
            assert_not_contains(self, home, forbidden)

    def test_settings_appearance_switcher_is_bordered_native_glass(self):
        settings = source(ROOT / "WhoopApp" / "WhoopApp" / "AtriaSettingsView.swift")
        home = source(ROOT / "WhoopApp" / "WhoopApp" / "AtriaHomeView.swift")

        for needle in [
            "@AppStorage(\"atriaAppearanceMode\") private var appearanceMode = \"system\"",
            "appearanceButton(\"System\", mode: \"system\", icon: \"circle.lefthalf.filled\")",
            "appearanceButton(\"Light\", mode: \"light\", icon: \"sun.max.fill\")",
            "appearanceButton(\"Dark\", mode: \"dark\", icon: \"moon.fill\")",
            "HStack(spacing: 8)",
            ".glassEffect(.regular.tint(Color(red: 0.541, green: 0.22, blue: 0.961).opacity(0.12)), in: .rect(cornerRadius: 5))",
            ".stroke(Color(red: 0.541, green: 0.22, blue: 0.961), lineWidth: 1)",
            ".buttonStyle(.glass)",
            ".buttonBorderShape(.capsule)",
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

    def test_offline_historical_sync_is_bounded_standard_hr_exception(self):
        ble = source(ROOT / "WhoopApp" / "WhoopApp" / "WhoopBLEManager.swift")
        app = source(ROOT / "WhoopApp" / "WhoopApp" / "WhoopAppApp.swift")

        for needle in [
            "enum OfflineSyncDefaults",
            "defaults.set(true, forKey: OfflineSyncDefaults.enabled)",
            "private func migrateOfflineSyncDefaultIfNeeded(arguments: [String])",
            "stored_session_backfill_default",
            "applyEarlyHistoricalLaunchConfiguration(arguments: arguments)",
            "private func applyEarlyHistoricalLaunchConfiguration(arguments: [String])",
            "WHOOPDBG realtimeConfig history_only_probe=1 phase=early",
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
            "WHOOPDBG offline_sync status=armed",
            "live_realtime=skipped metrics_fail_closed=1",
            "deferred_live_link",
            "detail=live_link_connected action=keep_ble_stream",
            "detail=live_link_connected_late action=keep_ble_stream",
            "static let rangeLossBackfillPending",
            "private func markRangeLossBackfillRequired(reason: String)",
            "private func preserveLongWearRangeLossRecovery(reason: String)",
            "private func scheduleRangeLossBackfillIfNeeded(reason: String)",
            "WHOOPDBG offline_sync status=pending_range_loss_backfill",
            "WHOOPDBG offline_sync status=requesting_range_loss_backfill",
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
        decoder = source(ROOT / "WhoopApp" / "WhoopApp" / "AtriaIMUDecoder.swift")
        steps = source(ROOT / "WhoopApp" / "WhoopApp" / "AtriaStrapStepResearch.swift")
        sleep = source(ROOT / "WhoopApp" / "WhoopApp" / "AtriaSleepWakeResearch.swift")
        ble = source(ROOT / "WhoopApp" / "WhoopApp" / "WhoopBLEManager.swift")
        sessions = source(ROOT / "WhoopApp" / "WhoopApp" / "Sessions.swift")

        for needle in [
            "static func syntheticRestPayload",
            "static func syntheticShakePayload",
            "static func selfTestPassed() -> Bool",
            "abs(rest.meanMagnitudeG - 1.0) <= 0.05",
            "abs(shake.meanMagnitudeG - 2.0) <= 0.10",
            "gravityValidated ? \"gravity_validated\" : \"research_unvalidated\"",
        ]:
            assert_contains(self, decoder, needle)

        shared = source(ROOT / "WhoopApp" / "WhoopApp" / "AtriaSharedUIComponents.swift")
        collection = source(ROOT / "WhoopApp" / "WhoopApp" / "AtriaVitalsCollectionSections.swift")
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
        ]:
            assert_contains(self, collection, needle)

        for needle in [
            "AtriaIMUDecoder.decode(payload: payload)",
            "recordIMUFeatures(decoded)",
            "WHOOPDBG imu_candidate validated=%d validation_state=%@",
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
        probe = source(ROOT / "WhoopApp" / "WhoopApp" / "AtriaResearchProbe.swift")
        ble = source(ROOT / "WhoopApp" / "WhoopApp" / "WhoopBLEManager.swift")
        healthkit = source(ROOT / "WhoopApp" / "WhoopApp" / "HealthKitExporter.swift")
        harness = source(ROOT / "live_device_debug.sh")
        analyzer = source(ROOT / "tools" / "analyze_sensor_research_probe.py")

        for needle in [
            "enum AtriaResearchProbe",
            "case metadata = \"0x31\"",
            "case historical = \"0x2f\"",
            "case diagnostic = \"61080007\"",
            "enum ModelGeneration",
            "case whoopMG",
            "redactIdentifierLikeTokens",
            "(90...100).contains(value)",
            "(2_500...4_200).contains(value)",
            "oxygenOffsetSummary",
            "temperatureOffsetSummary",
            "modelGeneration(in: payload)",
        ]:
            assert_contains(self, probe, needle)

        for needle in [
            "case whoop4",
            "case .whoop4: return \"WHOOP 4.0\"",
            "case .whoop4Class: return \"WHOOP strap\"",
            "guard supportsSpO2Probe || supportsSkinTempProbe else { return }",
            "AtriaResearchProbe.analyze(payload: payload, source: source)",
            "applyModelMetadataIfExplicit(summary)",
            "sensorResearchProbeFrames: researchProbeFrameCount > 0 ? researchProbeFrameCount : nil",
            "spo2ResearchCandidateFrames: researchProbeOxygenCandidateFrames > 0 ? researchProbeOxygenCandidateFrames : nil",
            "skinTempResearchCandidateFrames: researchProbeTemperatureCandidateFrames > 0 ? researchProbeTemperatureCandidateFrames : nil",
            "WHOOPDBG model_gate status=metadata_explicit model=%@ evidence=%@ source=%@",
            "WHOOPDBG sensor_research_probe source=%@ status=research_unvalidated",
            "model_generation=%@ model_evidence=%@",
            "metric_promotions=0 healthkit_write=0 raw_storage=0",
            "recordResearchProbeCandidate(payload: payload, source: .metadata)",
            "recordResearchProbeCandidate(payload: payload, source: .historical)",
            "recordResearchProbeCandidate(payload: [UInt8](data), source: .diagnostic)",
        ]:
            assert_contains(self, ble, needle)

        home = source(ROOT / "WhoopApp" / "WhoopApp" / "AtriaHomeView.swift")
        settings = source(ROOT / "WhoopApp" / "WhoopApp" / "AtriaSettingsView.swift")
        assert_contains(self, home, "strapModel: ble.whoopModelLabel")
        assert_not_contains(self, home, "strapModel: ble.status == .connected ? ble.whoopModelLabel : \"\"")
        assert_contains(self, settings, "LabeledContent(\"Model\")")
        assert_contains(self, settings, "Text(strapModel.isEmpty ? \"WHOOP strap\" : strapModel)")

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
            "WHOOPDBG sensor_research_probe ",
            "WHOOPDBG model_gate ",
            "tokens.get(\"spo2_candidate_frames\", \"\")",
            "tokens.get(\"model_evidence\", \"\")",
            "metadata_0x31_body_hashes[hashlib.sha256(payload).hexdigest()[:16]] += 1",
        ]:
            assert_contains(self, harness, needle)

        for needle in [
            "WHOOPDBG sensor_research_probe ",
            "WHOOPDBG frame ch=([0-9A-Fa-f-]+) len=(\\d+) hex=([0-9A-Fa-f]+)",
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
        sessions = source(ROOT / "WhoopApp" / "WhoopApp" / "Sessions.swift")
        collection = source(ROOT / "WhoopApp" / "WhoopApp" / "AtriaVitalsCollectionSections.swift")
        healthkit = source(ROOT / "WhoopApp" / "WhoopApp" / "HealthKitExporter.swift")

        for needle in [
            "struct ResearchManeuverMarker: Codable, Identifiable, Equatable",
            "case breathHold",
            "case heatExposure",
            "case coldExposure",
            "case walkTest",
            "static let key = \"atria.researchManeuverMarkers.v1\"",
            "var researchManeuverMarkers: [ResearchManeuverMarker]",
            "func markResearchManeuver(_ kind: ResearchManeuverMarker.Kind",
            "WHOOPDBG research_maneuver_marker status=marked",
            "local_only=1 research_only=1 metric_promotions=0 healthkit_write=0 raw_storage=0",
        ]:
            assert_contains(self, sessions, needle)

        for needle in [
            "researchManeuverCard",
            "AtriaResearchManeuverMarkerCard(markers: store.researchManeuverMarkers",
            "sessions: store.sessions",
            "private struct AtriaResearchManeuverMarkerCard: View, Equatable",
            "private struct ResearchManeuverProbeCorrelationSummary: Equatable",
            "AtriaPanelSectionHeader(title: \"Probe markers\", subtitle: \"\")",
            "ForEach(ResearchManeuverMarker.Kind.allCases)",
            ".buttonStyle(.glass)",
            "AtriaMetricTile(label: \"Probe match\"",
            "state: markers.isEmpty ? .learning : .research",
            "state: correlationSummary.matchedMarkers > 0 ? .research : .learning",
            "static let correlationWindow: TimeInterval = 15 * 60",
            "guard (session.sensorResearchProbeFrames ?? 0) > 0 else { return false }",
            "marker.timestamp >= lower && marker.timestamp <= upper",
            "oxygenCandidateFrames",
            "temperatureCandidateFrames",
            "Research only; timestamps stay on device for probe correlation.",
        ]:
            assert_contains(self, collection, needle)

        for forbidden in [
            "markResearchManeuver",
            "ResearchManeuverMarker",
            "researchManeuverMarkers",
        ]:
            assert_not_contains(self, healthkit, forbidden)

    def test_bp_ecg_are_fail_closed_on_whoop4(self):
        settings = source(ROOT / "WhoopApp" / "WhoopApp" / "AtriaSettingsView.swift")
        healthkit = source(ROOT / "WhoopApp" / "WhoopApp" / "HealthKitExporter.swift")
        ble = source(ROOT / "WhoopApp" / "WhoopApp" / "WhoopBLEManager.swift")

        for needle in [
            "private var sensorAvailabilitySection: some View",
            "ECG unavailable",
            "WHOOP 4.0 has no electrodes.",
            "Blood pressure unavailable",
            "Requires a cuff-calibrated device.",
            "Blood oxygen research",
            "Sleep-only probe; no Health export.",
            "Skin temperature research",
            "Baseline-only probe; no absolute degrees C or Health export.",
            "Atria shows only hardware-backed readings.",
        ]:
            assert_contains(self, settings, needle)

        for needle in [
            "var supportsECG: Bool { self == .whoopMG }",
            "var supportsBloodPressure: Bool { self == .whoopMG }",
            "var readTypes: Set<HKObjectType> = [heartRateType, stepCountType, bloodPressureSystolicType, bloodPressureDiastolicType]",
            "private func auditCuffBloodPressureReadAvailability(reason: String)",
            "auditBloodPressureComponentReadAvailability(type: bloodPressureSystolicType",
            "auditBloodPressureComponentReadAvailability(type: bloodPressureDiastolicType",
            "HKSampleQuery(sampleType: type",
            "WHOOPDBG healthkit_cuff_bp_read status=%@",
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

    def test_production_capture_defaults_enable_protected_long_wear(self):
        text = source(ROOT / "WhoopApp" / "WhoopApp" / "WhoopBLEManager.swift")

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
        text = source(ROOT / "WhoopApp" / "WhoopApp" / "WhoopBLEManager.swift")

        for needle in [
            "private var pendingScanReason: String?",
            "pendingScanReason = reason",
            "let reason = pendingScanReason ?? \"central_powered_on\"",
            "WHOOPDBG ble_restore status=reuse_restored reason=fresh_scan_deferred",
            "WHOOPDBG ble_restore status=reuse_restored reason=standard_hr_only",
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
        text = source(ROOT / "WhoopApp" / "WhoopApp" / "WhoopBLEManager.swift")

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
        text = source(ROOT / "WhoopApp" / "WhoopApp" / "WhoopBLEManager.swift")

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
            "WHOOPDBG ble_link status=disconnected reason=user_disconnect action=stay_disconnected",
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
        text = source(ROOT / "WhoopApp" / "WhoopApp" / "WhoopBLEManager.swift")

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
        text = source(ROOT / "WhoopApp" / "WhoopApp" / "WhoopBLEManager.swift")

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

    def test_healthkit_step_count_is_read_only(self):
        text = source(ROOT / "WhoopApp" / "WhoopApp" / "HealthKitExporter.swift")

        for needle in [
            "private var stepCountType",
            ".stepCount",
            "var readTypes: Set<HKObjectType> = [heartRateType, stepCountType, bloodPressureSystolicType, bloodPressureDiastolicType]",
            "private func auditAppleStepCountReadAvailability(reason: String)",
            "HKStatisticsQuery(quantityType: stepCountType",
            "options: .cumulativeSum",
            "WHOOPDBG healthkit_step_read status=%@",
            "source=healthkit_read write_steps=0",
            "auditAppleStepCountReadAvailability(reason: \"authorization_cached\")",
            "auditAppleStepCountReadAvailability(reason: \"authorization_granted\")",
            "auditAppleStepCountReadAvailability(reason: \"up_to_date\")",
        ]:
            assert_contains(self, text, needle)

        assert_not_contains(self, text, "HKQuantitySample(type: stepCountType")

    def test_healthkit_sleeping_wrist_temperature_is_read_only(self):
        text = source(ROOT / "WhoopApp" / "WhoopApp" / "HealthKitExporter.swift")
        app_text = all_swift_source()

        for needle in [
            "private var sleepingWristTemperatureType: HKQuantityType?",
            ".appleSleepingWristTemperature",
            "readTypes.insert(sleepingWristTemperatureType)",
            "private func auditSleepingWristTemperatureReadAvailability(reason: String)",
            "HKSampleQuery(sampleType: sleepingWristTemperatureType",
            "HKSampleSortIdentifierEndDate",
            "WHOOPDBG healthkit_sleeping_wrist_temp_read status=%@",
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
        sessions = source(ROOT / "WhoopApp" / "WhoopApp" / "Sessions.swift")
        ble = source(ROOT / "WhoopApp" / "WhoopApp" / "WhoopBLEManager.swift")
        healthkit = source(ROOT / "WhoopApp" / "WhoopApp" / "HealthKitExporter.swift")

        for needle in [
            "var activeCalories: Double? = nil",
            "var caloriesConfidence: String? = nil",
        ]:
            assert_contains(self, sessions, needle)

        shared = source(ROOT / "WhoopApp" / "WhoopApp" / "AtriaSharedUIComponents.swift")
        overview = source(ROOT / "WhoopApp" / "WhoopApp" / "AtriaOverviewSections.swift")
        for needle in [
            "case estimate",
            "return \"Estimate\"",
            "return \"function\"",
        ]:
            assert_contains(self, shared, needle)
        assert_contains(self, overview, "state: live.liveActiveCalories == nil ? .learning : .estimate")
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
        sessions = source(ROOT / "WhoopApp" / "WhoopApp" / "Sessions.swift")
        healthkit = source(ROOT / "WhoopApp" / "WhoopApp" / "HealthKitExporter.swift")
        vitals = source(ROOT / "WhoopApp" / "WhoopApp" / "AtriaVitalsCollectionSections.swift")

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
        ]:
            assert_contains(self, body, needle)
        self.assertGreater(body.find("let rawEstimate = 15.3"), body.find("guard profile.maxHRSource == .measured else"))

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
        ]:
            assert_contains(self, vitals, needle)
        assert_not_contains(self, vitals, "AtriaInlineQuickStat(label: \"VO2max\"")

    def test_validate_later_recovery_displays_personal_baseline_before_validation(self):
        text = source(ROOT / "WhoopApp" / "WhoopApp" / "Metrics.swift")
        widget = source(ROOT / "WhoopApp" / "WhoopApp" / "WidgetSnapshot.swift")
        intents = source(ROOT / "WhoopApp" / "WhoopApp" / "AtriaAppIntents.swift")
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
            "MPNowPlayingInfoCenter.default().nowPlayingInfo",
            "MPMusicPlayerController.systemMusicPlayer",
            "CXCallObserver",
            "import ActivityKit",
            "ControlWidget",
            "AppIntent",
        ]
        for needle in required:
            assert_contains(self, text, needle)

    def test_haptic_alerts_are_phone_side_only(self):
        haptics = source(ROOT / "WhoopApp" / "WhoopApp" / "AtriaHapticAlerts.swift")

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
        text = source(ROOT / "WhoopApp" / "WhoopApp" / "AtriaAICoach.swift")

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

        card = source(ROOT / "WhoopApp" / "WhoopApp" / "AtriaAICoachCard.swift")
        assert_contains(self, card, "does not send metrics until a reviewed")
        assert_contains(self, card, "Enable local mode for an offline summary")
        assert_contains(self, card, ".privacySensitive()")
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
        entitlements = source(ROOT / "WhoopApp" / "WhoopApp" / "AtriaEntitlements.swift")

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
        developer_mode = source(ROOT / "WhoopApp" / "WhoopApp" / "AtriaDeveloperMode.swift")
        home = source(ROOT / "WhoopApp" / "WhoopApp" / "AtriaHomeView.swift")
        collection = source(ROOT / "WhoopApp" / "WhoopApp" / "AtriaVitalsCollectionSections.swift")
        content = source(ROOT / "WhoopApp" / "WhoopApp" / "ContentView.swift")
        sessions = source(ROOT / "WhoopApp" / "WhoopApp" / "Sessions.swift")

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
            "if developerModeEnabled {\n                            rrReferenceCard",
            "if developerModeEnabled {\n                            rrReferenceCard\n                            hrReferenceCard\n                            imuAuditCard",
            "if developerModeEnabled {\n                    AtriaCollectionToggleCard",
            "title: \"Standard HR radio\"",
            "subtitle: \"Advanced compatibility mode for heart-rate-only collection.\"",
            "private struct AtriaCollectionIMUAuditCard: View, Equatable",
            "AtriaPanelSectionHeader(title: \"IMU audit\", subtitle: \"\")",
            "Research only; compare with phone motion before steps or sleep.",
            "AtriaMetricTile(label: \"Strap steps\"",
            "AtriaMetricTile(label: \"Sleep/wake\"",
            "AtriaMetricTile(label: \"Probes\"",
            "agreementText",
            "probeDetail",
            "IMUAuditSummary(sessions: sessions)",
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

        assert_contains(self, content, "let debugCompletesOnboarding = AtriaDeveloperMode.isEnabled")
        assert_contains(self, content, "&& ProcessInfo.processInfo.arguments.contains(\"--whoop-complete-onboarding\")")
        assert_contains(self, sessions, "func completeOnboardingFromLaunchIfRequested")
        assert_contains(self, sessions, "guard AtriaDeveloperMode.isEnabled else { return }\n        guard arguments.contains(\"--whoop-complete-onboarding\") else { return }")

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

    def test_media_refresh_loop_is_scene_and_connection_scoped(self):
        media = source(ROOT / "WhoopApp" / "WhoopApp" / "AtriaMediaControls.swift")
        home = source(ROOT / "WhoopApp" / "WhoopApp" / "AtriaHomeView.swift")

        for needle in [
            "private var isRefreshLoopActive = false",
            "func setRefreshLoopActive(_ active: Bool)",
            "guard isRefreshLoopActive else { return }",
            "guard let self, self.isRefreshLoopActive else { return }",
        ]:
            assert_contains(self, media, needle)

        assert_not_contains(self, media, "startRefreshLoop()\n    }")
        for needle in [
            "private func updateMediaRefreshLoop()",
            "let isActive = scenePhase == .active",
            "let isConnected = model.coreLiveStore.state.status == .connected",
            "mediaController.setRefreshLoopActive(isActive && isConnected)",
            ".onChange(of: scenePhase)",
            "mediaController.setRefreshLoopActive(false)",
        ]:
            assert_contains(self, home, needle)

    def test_deferred_home_diagnostics_do_not_overlap(self):
        home = source(ROOT / "WhoopApp" / "WhoopApp" / "AtriaHomeView.swift")

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
        home = source(ROOT / "WhoopApp" / "WhoopApp" / "AtriaHomeView.swift")
        overview = source(ROOT / "WhoopApp" / "WhoopApp" / "AtriaOverviewSections.swift")
        sessions = source(ROOT / "WhoopApp" / "WhoopApp" / "Sessions.swift")
        intents = source(ROOT / "WhoopApp" / "WhoopApp" / "AtriaAppIntents.swift")
        ble = source(ROOT / "WhoopApp" / "WhoopApp" / "WhoopBLEManager.swift")

        assert_contains(self, content, "Not counted as workout until activity evidence is stronger.")
        assert_contains(self, content, "Current segment is HR-only; saved HRV window stays ready.")
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
        assert_contains(self, notifications, "title: \"Atria notification test\"")
        assert_contains(self, notifications, "body: \"Local notification delivery is working.\"")
        assert_not_contains(self, notifications, "static let active = [recovery, strain, battery, diagnostic]")
        assert_not_contains(self, notifications, "title: \"Atria diagnostic\"")

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
        parse_args = script.find("while [[ $# -gt 0 ]]; do")
        validate_device = script.find("Set ATRIA_DEVICE_ID or pass --device")
        self.assertGreaterEqual(parse_args, 0)
        self.assertGreater(validate_device, parse_args)

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

    def test_phone_motion_remains_adjunct_to_whoop_primary_data(self):
        sessions = source(ROOT / "WhoopApp" / "WhoopApp" / "Sessions.swift")
        ble = source(ROOT / "WhoopApp" / "WhoopApp" / "WhoopBLEManager.swift")
        pull = source(ROOT / "pull_atria_state.sh")

        for needle in [
            "WHOOP HR/RR remains primary, phone motion is adjunct only",
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

        assert_contains(self, pull, "whoop_primary_data_source=saved_sessions_hr_rr")
        assert_not_contains(self, sessions, "phone motion is primary")
        assert_not_contains(self, sessions, "phoneMotionValidated: true")
        assert_not_contains(self, sessions, "phoneStepValidated: true")


if __name__ == "__main__":
    unittest.main()
