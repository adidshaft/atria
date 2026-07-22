import XCTest
@testable import Atria

@MainActor
final class AtriaBLEEvidenceTests: XCTestCase {
    private func isolatedDefaults() throws -> (UserDefaults, String) {
        let suite = "AtriaBLEEvidenceTests.\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: suite)), suite)
    }

    private func assertDefaultsUnchanged(
        _ defaults: UserDefaults,
        before: [String: Any],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            NSDictionary(dictionary: before).isEqual(to: defaults.dictionaryRepresentation()),
            "evidence builders must remain read-only",
            file: file,
            line: line
        )
    }

    func testLinkAndSampleEvidencePreserveExactFieldsAndSanitizeTokens() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(3, forKey: AtriaBLEManager.LinkDefaults.attempts)
        defaults.set(2, forKey: AtriaBLEManager.LinkDefaults.disconnects)
        defaults.set(1, forKey: AtriaBLEManager.LinkDefaults.successes)
        defaults.set(4, forKey: AtriaBLEManager.LinkDefaults.failures)
        defaults.set("link ready", forKey: AtriaBLEManager.LinkDefaults.lastStatus)
        defaults.set("range/loss", forKey: AtriaBLEManager.LinkDefaults.lastReason)
        defaults.set("CBError 6", forKey: AtriaBLEManager.LinkDefaults.lastError)
        defaults.set("saved.ok", forKey: AtriaBLEManager.LinkDefaults.lastAutoSaveStatus)
        defaults.set(89, forKey: AtriaBLEManager.LinkDefaults.lastAutoSaveSamples)
        defaults.set(90, forKey: AtriaBLEManager.LinkDefaults.lastAutoSaveDuration)
        defaults.set("elevated risk", forKey: AtriaBLEManager.LinkDefaults.officialAppCoexistenceRisk)
        defaults.set("official app?", forKey: AtriaBLEManager.LinkDefaults.officialAppCoexistenceReason)

        defaults.set(101, forKey: AtriaBLEManager.SampleDefaults.rawNotifications)
        defaults.set(99, forKey: AtriaBLEManager.SampleDefaults.acceptedSamples)
        defaults.set(1, forKey: AtriaBLEManager.SampleDefaults.zeroSamples)
        defaults.set(2, forKey: AtriaBLEManager.SampleDefaults.heldArtifacts)
        defaults.set(3, forKey: AtriaBLEManager.SampleDefaults.droppedArtifacts)
        defaults.set(4, forKey: AtriaBLEManager.SampleDefaults.rawGaps)
        defaults.set(5, forKey: AtriaBLEManager.SampleDefaults.acceptedGaps)
        defaults.set(6.25, forKey: AtriaBLEManager.SampleDefaults.maxRawGap)
        defaults.set(7.75, forKey: AtriaBLEManager.SampleDefaults.maxAcceptedGap)
        defaults.set("live sample", forKey: AtriaBLEManager.SampleDefaults.lastStatus)
        defaults.set("fresh/2A37", forKey: AtriaBLEManager.SampleDefaults.lastReason)
        let before = defaults.dictionaryRepresentation()

        XCTAssertEqual(
            AtriaBLEManager.linkEvidence(defaults: defaults),
            "ble_link_attempts=3; ble_link_disconnects=2; ble_link_successes=1; ble_link_failures=4; ble_link_last_status=link_ready; ble_link_last_reason=range_loss; ble_link_last_error=CBError_6; ble_link_last_autosave=saved.ok; ble_link_last_autosave_samples=89; ble_link_last_autosave_duration_s=90; official_app_coexistence_risk=elevated_risk; official_app_coexistence_reason=official_app_"
        )
        XCTAssertEqual(
            AtriaBLEManager.sampleGapEvidence(defaults: defaults),
            "hr_raw_2a37=101; hr_accepted=99; hr_zero=1; hr_artifact_held=2; hr_artifact_dropped=3; hr_raw_gaps=4; hr_accepted_gaps=5; hr_max_raw_gap_s=6.2; hr_max_accepted_gap_s=7.8; hr_sample_last_status=live_sample; hr_sample_last_reason=fresh_2A37"
        )
        assertDefaultsUnchanged(defaults, before: before)
    }

    func testRadioAndProtocolEvidencePreserveFallbacksAgesAndPacketFields() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 2_000)

        defaults.set(true, forKey: AtriaBLEManager.RadioDefaults.standardHROnly)
        defaults.set(7, forKey: AtriaBLEManager.RadioDefaults.customNotifySkipped)
        defaults.set(8, forKey: AtriaBLEManager.RadioDefaults.customNotifyEnabled)
        defaults.set(9, forKey: AtriaBLEManager.RadioDefaults.txSkipped)
        defaults.set(10, forKey: AtriaBLEManager.RadioDefaults.realtimeStartSkipped)
        defaults.set("frame/valid", forKey: AtriaBLEManager.RadioDefaults.passiveR10Status)
        defaults.set(11, forKey: AtriaBLEManager.RadioDefaults.passiveR10ValidFrames)
        defaults.set(1_960.0, forKey: AtriaBLEManager.RadioDefaults.passiveR10LastValidAt)
        defaults.set("overnight stable", forKey: AtriaBLEManager.RadioDefaults.lastReason)

        defaults.set(12, forKey: AtriaBLEManager.ProtocolDefaults.packets)
        defaults.set(13, forKey: AtriaBLEManager.ProtocolDefaults.imuFrames)
        defaults.set(14, forKey: AtriaBLEManager.ProtocolDefaults.diagnosticFrames)
        defaults.set(15, forKey: AtriaBLEManager.ProtocolDefaults.eventFrames)
        defaults.set(16, forKey: AtriaBLEManager.ProtocolDefaults.unknownFrames)
        defaults.set("0x2f raw", forKey: AtriaBLEManager.ProtocolDefaults.lastPacketType)
        defaults.set("historical/data", forKey: AtriaBLEManager.ProtocolDefaults.lastPacketKind)
        defaults.set(17, forKey: AtriaBLEManager.ProtocolDefaults.lastPacketLength)
        let before = defaults.dictionaryRepresentation()

        XCTAssertEqual(
            AtriaBLEManager.radioEvidence(defaults: defaults, now: now),
            "radio_mode=standard_hr_only; radio_standard_hr_only=1; radio_custom_notify_skipped=7; radio_custom_notify_enabled=8; radio_tx_skipped=9; radio_realtime_start_skipped=10; radio_passive_r10_status=frame_valid; radio_passive_r10_valid_frames=11; radio_passive_r10_last_age_s=40.0; radio_last_reason=overnight_stable"
        )
        XCTAssertEqual(
            AtriaBLEManager.protocolEvidence(defaults: defaults),
            "protocol_packets=12; protocol_imu_frames=13; protocol_diagnostic_frames=14; protocol_event_frames=15; protocol_unknown_frames=16; protocol_last_type=0x2f raw; protocol_last_kind=historical_data; protocol_last_len=17"
        )
        assertDefaultsUnchanged(defaults, before: before)
    }

    func testOfflineAndWatchdogEvidencePreserveAgesAndFailClosedDefaults() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 2_000)

        defaults.set(true, forKey: AtriaBLEManager.OfflineSyncDefaults.enabled)
        defaults.set(2, forKey: AtriaBLEManager.OfflineSyncDefaults.attempts)
        defaults.set("gap retained", forKey: AtriaBLEManager.OfflineSyncDefaults.lastStatus)
        defaults.set("transaction/unverified", forKey: AtriaBLEManager.OfflineSyncDefaults.lastReason)
        defaults.set(true, forKey: AtriaBLEManager.OfflineSyncDefaults.rangeLossBackfillPending)
        defaults.set("clock proof", forKey: AtriaBLEManager.OfflineSyncDefaults.rangeLossBackfillReason)
        defaults.set(1_900.0, forKey: AtriaBLEManager.OfflineSyncDefaults.rangeLossBackfillRequestedAt)
        defaults.set(1_950.0, forKey: AtriaBLEManager.OfflineSyncDefaults.rangeLossBackfillStartedAt)
        defaults.set("fingerprint", forKey: AtriaBLEManager.OfflineSyncDefaults.rawArchivedGapFingerprint)
        defaults.set(1_980.0, forKey: AtriaBLEManager.OfflineSyncDefaults.rawArchivedGapAt)

        defaults.set(3, forKey: AtriaBLEManager.WatchdogRecoveryDefaults.noDataCount)
        defaults.set(4, forKey: AtriaBLEManager.WatchdogRecoveryDefaults.hrContinuityCount)
        defaults.set(5, forKey: AtriaBLEManager.WatchdogRecoveryDefaults.acceptedHRCount)
        defaults.set(6, forKey: AtriaBLEManager.WatchdogRecoveryDefaults.rrPresenceCount)
        defaults.set("recovered now", forKey: AtriaBLEManager.WatchdogRecoveryDefaults.lastStatus)
        defaults.set("2A37/live", forKey: AtriaBLEManager.WatchdogRecoveryDefaults.lastSource)
        defaults.set("read HR", forKey: AtriaBLEManager.WatchdogRecoveryDefaults.lastAction)
        defaults.set(7.25, forKey: AtriaBLEManager.WatchdogRecoveryDefaults.lastRawGap)
        defaults.set(8.5, forKey: AtriaBLEManager.WatchdogRecoveryDefaults.lastAcceptedGap)
        defaults.set(9, forKey: AtriaBLEManager.WatchdogRecoveryDefaults.lastSamples)
        defaults.set("journal saved", forKey: AtriaBLEManager.WatchdogRecoveryDefaults.lastCheckpoint)
        defaults.set(1_970.0, forKey: AtriaBLEManager.WatchdogRecoveryDefaults.lastAt)
        defaults.set("rr live", forKey: AtriaBLEManager.RRPresenceDefaults.status)
        defaults.set("observe only", forKey: AtriaBLEManager.RRPresenceDefaults.action)
        defaults.set(1.5, forKey: AtriaBLEManager.RRPresenceDefaults.rrGap)
        defaults.set(2.5, forKey: AtriaBLEManager.RRPresenceDefaults.acceptedGap)
        defaults.set(45.0, forKey: AtriaBLEManager.RRPresenceDefaults.timeout)
        defaults.set(10, forKey: AtriaBLEManager.RRPresenceDefaults.samples)
        defaults.set(11, forKey: AtriaBLEManager.RRPresenceDefaults.rrValues)
        defaults.set(12, forKey: AtriaBLEManager.RRPresenceDefaults.consecutive)
        defaults.set("overnight RR", forKey: AtriaBLEManager.RRPresenceDefaults.label)
        defaults.set(false, forKey: AtriaBLEManager.RRPresenceDefaults.lastPacketRRFlagPresent)
        defaults.set(true, forKey: AtriaBLEManager.RRPresenceDefaults.lastPacketContactSupported)
        defaults.set(true, forKey: AtriaBLEManager.RRPresenceDefaults.lastPacketContactDetected)
        defaults.set(1_990.0, forKey: AtriaBLEManager.RRPresenceDefaults.at)
        let before = defaults.dictionaryRepresentation()

        XCTAssertEqual(
            AtriaBLEManager.offlineSyncEvidence(defaults: defaults, now: now),
            "offline_sync_enabled=1; offline_sync_attempts=2; offline_sync_last_status=gap_retained; offline_sync_last_reason=transaction_unverified; offline_range_loss_backfill_pending=1; offline_range_loss_backfill_reason=clock_proof; offline_range_loss_backfill_requested_age_s=100.0; offline_range_loss_backfill_started_age_s=50.0; offline_raw_gap_archived=1; offline_raw_gap_archived_age_s=20.0; offline_missing_windows=0; offline_oldest_gap_coverage_percent=0; offline_metric_layout_verified=1"
        )
        XCTAssertEqual(
            AtriaBLEManager.watchdogRecoveryEvidence(defaults: defaults, now: now),
            "watchdog_no_data_recoveries=3; watchdog_hr_continuity_recoveries=4; watchdog_accepted_hr_recoveries=5; watchdog_rr_presence_recoveries=6; watchdog_last_status=recovered_now; watchdog_last_source=2A37_live; watchdog_last_action=read_HR; watchdog_last_raw_gap_s=7.2; watchdog_last_accepted_gap_s=8.5; watchdog_last_samples=9; watchdog_last_checkpoint=journal_saved; watchdog_last_age_s=30.0; rr_presence_status=rr_live; rr_presence_action=observe_only; rr_presence_rr_gap_s=1.5; rr_presence_accepted_gap_s=2.5; rr_presence_timeout_s=45.0; rr_presence_samples=10; rr_presence_rr_values=11; rr_presence_consecutive=12; rr_presence_age_s=10.0; rr_presence_label=overnight_RR; rr_last_packet_rr_flag=0; rr_last_packet_contact=detected"
        )
        assertDefaultsUnchanged(defaults, before: before)
    }

    func testBatteryAndJournalEvidenceRemainReadOnlyProjections() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 2_000)

        defaults.set(58, forKey: AtriaBLEManager.BatteryDefaults.level)
        defaults.set(1_980.0, forKey: AtriaBLEManager.BatteryDefaults.at)
        defaults.set("live 2A19", forKey: AtriaBLEManager.BatteryDefaults.source)
        defaults.set(AtriaBLEManager.BatteryChargeStatus.notCharging.rawValue,
                     forKey: AtriaBLEManager.BatteryDefaults.chargeStatus)
        defaults.set(1_970.0, forKey: AtriaBLEManager.BatteryDefaults.chargeAt)
        defaults.set(4, forKey: AtriaBLEManager.BatteryDefaults.dropDelta)
        defaults.set(1_990.0, forKey: AtriaBLEManager.BatteryDefaults.dropAt)
        let before = defaults.dictionaryRepresentation()

        let cached = AtriaBLEManager.cachedBattery(defaults: defaults, now: now)
        XCTAssertEqual(cached.level, 58)
        XCTAssertEqual(cached.source, "live_2A19")
        XCTAssertEqual(cached.age, 20)
        XCTAssertEqual(cached.chargeStatus, .notCharging)
        XCTAssertEqual(cached.chargeAge, 30)
        XCTAssertTrue(cached.usable)

        let drop = AtriaBLEManager.cachedBatteryDrop(maxAge: 60, defaults: defaults, now: now)
        XCTAssertTrue(drop.recent)
        XCTAssertEqual(drop.delta, 4)
        XCTAssertEqual(drop.age, 10)
        XCTAssertEqual(
            AtriaBLEManager.batteryEvidence(defaults: defaults, now: now),
            "battery_level=58; battery_source=live_2A19; battery_age_s=20; battery_charge_status=notCharging; battery_charge_age_s=30; battery_usable=1; battery_drop_recent=1; battery_drop_delta=4; battery_drop_age_s=10"
        )
        assertDefaultsUnchanged(defaults, before: before)

        XCTAssertEqual(
            AtriaBLEManager.activeSessionJournalEvidence(includeAge: false),
            ActiveSessionJournal.evidence(includeAge: false)
        )
        XCTAssertEqual(AtriaBLEManager.evidenceToken("live 2A19/ok?"), "live_2A19_ok_")
    }
}
