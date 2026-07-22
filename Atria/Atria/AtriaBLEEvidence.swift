import Foundation

/// Stateless, read-only diagnostic projections owned by `AtriaBLEManager`.
/// Injected overloads make outputs deterministic in tests without touching
/// the live app's defaults; no builder mutates BLE or persistence state.
extension AtriaBLEManager {
    static func linkEvidence() -> String {
        linkEvidence(defaults: .standard)
    }

    static func linkEvidence(defaults: UserDefaults) -> String {
        let status = evidenceToken(defaults.string(forKey: LinkDefaults.lastStatus) ?? "none")
        let reason = evidenceToken(defaults.string(forKey: LinkDefaults.lastReason) ?? "none")
        let error = evidenceToken(defaults.string(forKey: LinkDefaults.lastError) ?? "none")
        let save = evidenceToken(defaults.string(forKey: LinkDefaults.lastAutoSaveStatus) ?? "none")
        let coexistenceRisk = evidenceToken(defaults.string(forKey: LinkDefaults.officialAppCoexistenceRisk) ?? OfficialAppCoexistenceRisk.advisory.rawValue)
        let coexistenceReason = evidenceToken(defaults.string(forKey: LinkDefaults.officialAppCoexistenceReason) ?? "onboarding_advisory")
        return "ble_link_attempts=\(defaults.integer(forKey: LinkDefaults.attempts)); ble_link_disconnects=\(defaults.integer(forKey: LinkDefaults.disconnects)); ble_link_successes=\(defaults.integer(forKey: LinkDefaults.successes)); ble_link_failures=\(defaults.integer(forKey: LinkDefaults.failures)); ble_link_last_status=\(status); ble_link_last_reason=\(reason); ble_link_last_error=\(error); ble_link_last_autosave=\(save); ble_link_last_autosave_samples=\(defaults.integer(forKey: LinkDefaults.lastAutoSaveSamples)); ble_link_last_autosave_duration_s=\(defaults.integer(forKey: LinkDefaults.lastAutoSaveDuration)); official_app_coexistence_risk=\(coexistenceRisk); official_app_coexistence_reason=\(coexistenceReason)"
    }

    static func sampleGapEvidence() -> String {
        sampleGapEvidence(defaults: .standard)
    }

    static func sampleGapEvidence(defaults: UserDefaults) -> String {
        let status = evidenceToken(defaults.string(forKey: SampleDefaults.lastStatus) ?? "none")
        let reason = evidenceToken(defaults.string(forKey: SampleDefaults.lastReason) ?? "none")
        return String(format: "hr_raw_2a37=%d; hr_accepted=%d; hr_zero=%d; hr_artifact_held=%d; hr_artifact_dropped=%d; hr_raw_gaps=%d; hr_accepted_gaps=%d; hr_max_raw_gap_s=%.1f; hr_max_accepted_gap_s=%.1f; hr_sample_last_status=%@; hr_sample_last_reason=%@",
                      defaults.integer(forKey: SampleDefaults.rawNotifications),
                      defaults.integer(forKey: SampleDefaults.acceptedSamples),
                      defaults.integer(forKey: SampleDefaults.zeroSamples),
                      defaults.integer(forKey: SampleDefaults.heldArtifacts),
                      defaults.integer(forKey: SampleDefaults.droppedArtifacts),
                      defaults.integer(forKey: SampleDefaults.rawGaps),
                      defaults.integer(forKey: SampleDefaults.acceptedGaps),
                      defaults.double(forKey: SampleDefaults.maxRawGap),
                      defaults.double(forKey: SampleDefaults.maxAcceptedGap),
                      status,
                      reason)
    }

    static func radioEvidence() -> String {
        radioEvidence(defaults: .standard, now: Date())
    }

    static func radioEvidence(defaults: UserDefaults, now: Date) -> String {
        let persistedStandardOnly = defaults.bool(forKey: RadioDefaults.standardHROnly)
        let mode = evidenceToken(defaults.string(forKey: RadioDefaults.mode) ?? (persistedStandardOnly ? "standard_hr_only" : "full_protocol"))
        let reason = evidenceToken(defaults.string(forKey: RadioDefaults.lastReason) ?? "none")
        let passiveStatus = evidenceToken(defaults.string(forKey: RadioDefaults.passiveR10Status) ?? "not_subscribed")
        let passiveLastAt = defaults.object(forKey: RadioDefaults.passiveR10LastValidAt) as? Double
        let passiveAge = passiveLastAt.map { max(0, now.timeIntervalSince1970 - $0) } ?? -1
        return String(format: "radio_mode=%@; radio_standard_hr_only=%d; radio_custom_notify_skipped=%d; radio_custom_notify_enabled=%d; radio_tx_skipped=%d; radio_realtime_start_skipped=%d; radio_passive_r10_status=%@; radio_passive_r10_valid_frames=%d; radio_passive_r10_last_age_s=%.1f; radio_last_reason=%@",
                      mode,
                      persistedStandardOnly ? 1 : 0,
                      defaults.integer(forKey: RadioDefaults.customNotifySkipped),
                      defaults.integer(forKey: RadioDefaults.customNotifyEnabled),
                      defaults.integer(forKey: RadioDefaults.txSkipped),
                      defaults.integer(forKey: RadioDefaults.realtimeStartSkipped),
                      passiveStatus,
                      defaults.integer(forKey: RadioDefaults.passiveR10ValidFrames),
                      passiveAge,
                      reason)
    }

    static func protocolEvidence() -> String {
        protocolEvidence(defaults: .standard)
    }

    static func protocolEvidence(defaults: UserDefaults) -> String {
        let lastType = defaults.string(forKey: ProtocolDefaults.lastPacketType) ?? "none"
        let lastKind = evidenceToken(defaults.string(forKey: ProtocolDefaults.lastPacketKind) ?? "none")
        return "protocol_packets=\(defaults.integer(forKey: ProtocolDefaults.packets)); protocol_imu_frames=\(defaults.integer(forKey: ProtocolDefaults.imuFrames)); protocol_diagnostic_frames=\(defaults.integer(forKey: ProtocolDefaults.diagnosticFrames)); protocol_event_frames=\(defaults.integer(forKey: ProtocolDefaults.eventFrames)); protocol_unknown_frames=\(defaults.integer(forKey: ProtocolDefaults.unknownFrames)); protocol_last_type=\(lastType); protocol_last_kind=\(lastKind); protocol_last_len=\(defaults.integer(forKey: ProtocolDefaults.lastPacketLength))"
    }

    static func offlineSyncEvidence() -> String {
        offlineSyncEvidence(defaults: .standard, now: Date())
    }

    static func offlineSyncEvidence(defaults: UserDefaults, now: Date) -> String {
        let status = evidenceToken(defaults.string(forKey: OfflineSyncDefaults.lastStatus) ?? "none")
        let reason = evidenceToken(defaults.string(forKey: OfflineSyncDefaults.lastReason) ?? "none")
        let rangeReason = evidenceToken(defaults.string(forKey: OfflineSyncDefaults.rangeLossBackfillReason) ?? "none")
        let requestedAt = defaults.object(forKey: OfflineSyncDefaults.rangeLossBackfillRequestedAt) as? Double
        let startedAt = defaults.object(forKey: OfflineSyncDefaults.rangeLossBackfillStartedAt) as? Double
        let rawArchivedAt = defaults.object(forKey: OfflineSyncDefaults.rawArchivedGapAt) as? Double
        let requestedAge = requestedAt.map { max(0, now.timeIntervalSince1970 - $0) } ?? -1
        let startedAge = startedAt.map { max(0, now.timeIntervalSince1970 - $0) } ?? -1
        let rawArchivedAge = rawArchivedAt.map { max(0, now.timeIntervalSince1970 - $0) } ?? -1
        let missingWindows = AtriaHistoricalGapLedger.windowsForEvidence(defaults: defaults)
        let oldestCoverage = missingWindows.first.map {
            AtriaHistoricalGapLedger.coveragePercent(for: $0)
        } ?? 0
        return String(format: "offline_sync_enabled=%d; offline_sync_attempts=%d; offline_sync_last_status=%@; offline_sync_last_reason=%@; offline_range_loss_backfill_pending=%d; offline_range_loss_backfill_reason=%@; offline_range_loss_backfill_requested_age_s=%.1f; offline_range_loss_backfill_started_age_s=%.1f; offline_raw_gap_archived=%d; offline_raw_gap_archived_age_s=%.1f; offline_missing_windows=%d; offline_oldest_gap_coverage_percent=%d; offline_metric_layout_verified=%d",
                      defaults.bool(forKey: OfflineSyncDefaults.enabled) ? 1 : 0,
                      defaults.integer(forKey: OfflineSyncDefaults.attempts),
                      status,
                      reason,
                      defaults.bool(forKey: OfflineSyncDefaults.rangeLossBackfillPending) ? 1 : 0,
                      rangeReason,
                      requestedAge,
                      startedAge,
                      defaults.string(forKey: OfflineSyncDefaults.rawArchivedGapFingerprint) == nil ? 0 : 1,
                      rawArchivedAge,
                      missingWindows.count,
                      oldestCoverage,
                      HistoricalArchive.hasValidatedMetricLayout ? 1 : 0)
    }

    static func watchdogRecoveryEvidence() -> String {
        watchdogRecoveryEvidence(defaults: .standard, now: Date())
    }

    static func watchdogRecoveryEvidence(defaults: UserDefaults, now: Date) -> String {
        let status = evidenceToken(defaults.string(forKey: WatchdogRecoveryDefaults.lastStatus) ?? "none")
        let source = evidenceToken(defaults.string(forKey: WatchdogRecoveryDefaults.lastSource) ?? "none")
        let action = evidenceToken(defaults.string(forKey: WatchdogRecoveryDefaults.lastAction) ?? "none")
        let checkpoint = evidenceToken(defaults.string(forKey: WatchdogRecoveryDefaults.lastCheckpoint) ?? "none")
        let at = defaults.object(forKey: WatchdogRecoveryDefaults.lastAt) as? Double
        let age = at.map { max(0, now.timeIntervalSince1970 - $0) } ?? -1
        let rrStatus = evidenceToken(defaults.string(forKey: RRPresenceDefaults.status) ?? "none")
        let rrAction = evidenceToken(defaults.string(forKey: RRPresenceDefaults.action) ?? "none")
        let rrLabel = evidenceToken(defaults.string(forKey: RRPresenceDefaults.label) ?? "none")
        let rrAt = defaults.object(forKey: RRPresenceDefaults.at) as? Double
        let rrAge = rrAt.map { max(0, now.timeIntervalSince1970 - $0) } ?? -1
        let rrContactSupported = defaults.bool(
            forKey: RRPresenceDefaults.lastPacketContactSupported
        )
        let rrContact = rrContactSupported
            ? (defaults.bool(forKey: RRPresenceDefaults.lastPacketContactDetected)
                ? "detected" : "not_detected")
            : "unsupported"
        return String(format: "watchdog_no_data_recoveries=%d; watchdog_hr_continuity_recoveries=%d; watchdog_accepted_hr_recoveries=%d; watchdog_rr_presence_recoveries=%d; watchdog_last_status=%@; watchdog_last_source=%@; watchdog_last_action=%@; watchdog_last_raw_gap_s=%.1f; watchdog_last_accepted_gap_s=%.1f; watchdog_last_samples=%d; watchdog_last_checkpoint=%@; watchdog_last_age_s=%.1f; rr_presence_status=%@; rr_presence_action=%@; rr_presence_rr_gap_s=%.1f; rr_presence_accepted_gap_s=%.1f; rr_presence_timeout_s=%.1f; rr_presence_samples=%d; rr_presence_rr_values=%d; rr_presence_consecutive=%d; rr_presence_age_s=%.1f; rr_presence_label=%@; rr_last_packet_rr_flag=%d; rr_last_packet_contact=%@",
                      defaults.integer(forKey: WatchdogRecoveryDefaults.noDataCount),
                      defaults.integer(forKey: WatchdogRecoveryDefaults.hrContinuityCount),
                      defaults.integer(forKey: WatchdogRecoveryDefaults.acceptedHRCount),
                      defaults.integer(forKey: WatchdogRecoveryDefaults.rrPresenceCount),
                      status,
                      source,
                      action,
                      defaults.double(forKey: WatchdogRecoveryDefaults.lastRawGap),
                      defaults.double(forKey: WatchdogRecoveryDefaults.lastAcceptedGap),
                      defaults.integer(forKey: WatchdogRecoveryDefaults.lastSamples),
                      checkpoint,
                      age,
                      rrStatus,
                      rrAction,
                      defaults.double(forKey: RRPresenceDefaults.rrGap),
                      defaults.double(forKey: RRPresenceDefaults.acceptedGap),
                      defaults.double(forKey: RRPresenceDefaults.timeout),
                      defaults.integer(forKey: RRPresenceDefaults.samples),
                      defaults.integer(forKey: RRPresenceDefaults.rrValues),
                      defaults.integer(forKey: RRPresenceDefaults.consecutive),
                      rrAge,
                      rrLabel,
                      defaults.bool(forKey: RRPresenceDefaults.lastPacketRRFlagPresent) ? 1 : 0,
                      rrContact)
    }

    static func cachedBattery(maxAge: TimeInterval = 86_400,
                              chargeMaxAge: TimeInterval = AtriaBLEManager.activeBatteryChargeEvidenceMaxAge,
                              defaults: UserDefaults = .standard,
                              now: Date = Date(),
                              permitPendingReconnectBaseline: Bool = false,
                              permitActiveNotificationLease: Bool = false) -> (level: Int, source: String, age: TimeInterval, chargeStatus: BatteryChargeStatus, chargeAge: TimeInterval, usable: Bool) {
        let level = defaults.object(forKey: BatteryDefaults.level) as? Int ?? -1
        let at = defaults.object(forKey: BatteryDefaults.at) as? Double
        let requiresFreshConfirmation = defaults.bool(forKey: BatteryDefaults.requiresFreshConfirmation)
        let age = at.map { max(0, now.timeIntervalSince1970 - $0) } ?? -1
        let source = evidenceToken(defaults.string(forKey: BatteryDefaults.source) ?? (level >= 0 ? "cached_2A19" : "none"))
        let rawCharge = defaults.string(forKey: BatteryDefaults.chargeStatus) ?? BatteryChargeStatus.levelOnly.rawValue
        let storedChargeStatus = BatteryChargeStatus(rawValue: rawCharge) ?? .levelOnly
        let chargeSource = defaults.string(forKey: "atria.battery.chargeSource") ?? "none"
        let chargeAt = defaults.object(forKey: BatteryDefaults.chargeAt) as? Double
        let chargeAge = chargeAt.map { max(0, now.timeIntervalSince1970 - $0) } ?? -1
        let chargeSourceIsEligible = storedChargeStatus != .charging
            || batteryChargeSourceCanAuthorizeCharging(chargeSource)
        let chargeFresh = storedChargeStatus == .levelOnly
            || (chargeSourceIsEligible && chargeAge >= 0 && chargeAge <= chargeMaxAge)
        let effectiveChargeStatus = chargeFresh ? storedChargeStatus : .levelOnly
        let sourceIsEligible = batteryCacheSourceIsDisplayEligible(source)
        let activeNotificationLease = permitActiveNotificationLease
            && persistedBatteryNotificationLeaseSupportsDisplay(
                level: level,
                source: source,
                requiresFreshConfirmation: requiresFreshConfirmation,
                notificationLeaseAt: (defaults.object(forKey: BatteryDefaults.notificationLeaseAt) as? Double)
                    .map(Date.init(timeIntervalSince1970:)),
                notificationConfirmedAt: (defaults.object(forKey: BatteryDefaults.notificationConfirmedAt) as? Double)
                    .map(Date.init(timeIntervalSince1970:)),
                now: now
            )
        let rawLevelIsUsable = (11...99).contains(level)
            && age >= 0
            && age <= maxAge
            && sourceIsEligible
            && (!requiresFreshConfirmation || permitPendingReconnectBaseline)
        let usable = rawLevelIsUsable || activeNotificationLease
        return (level, source, age, effectiveChargeStatus, chargeAge, usable)
    }

    static func cachedBatteryDrop(maxAge: TimeInterval = 6 * 60 * 60) -> (recent: Bool, delta: Int, age: TimeInterval) {
        cachedBatteryDrop(maxAge: maxAge, defaults: .standard, now: Date())
    }

    static func cachedBatteryDrop(maxAge: TimeInterval,
                                  defaults: UserDefaults,
                                  now: Date) -> (recent: Bool, delta: Int, age: TimeInterval) {
        let delta = defaults.object(forKey: BatteryDefaults.dropDelta) as? Int ?? 0
        let at = defaults.object(forKey: BatteryDefaults.dropAt) as? Double
        let age = at.map { max(0, now.timeIntervalSince1970 - $0) } ?? -1
        return (delta > 0 && age >= 0 && age <= maxAge, delta, age)
    }

    static func batteryEvidence() -> String {
        batteryEvidence(defaults: .standard, now: Date())
    }

    static func batteryEvidence(defaults: UserDefaults, now: Date) -> String {
        let battery = cachedBattery(defaults: defaults, now: now)
        let drop = cachedBatteryDrop(maxAge: 6 * 60 * 60, defaults: defaults, now: now)
        let ageText = battery.age >= 0 ? String(format: "%.0f", battery.age) : "learning"
        let chargeAgeText = battery.chargeAge >= 0 ? String(format: "%.0f", battery.chargeAge) : "learning"
        let dropAgeText = drop.age >= 0 ? String(format: "%.0f", drop.age) : "learning"
        return "battery_level=\(battery.level); battery_source=\(battery.source); battery_age_s=\(ageText); battery_charge_status=\(battery.chargeStatus.rawValue); battery_charge_age_s=\(chargeAgeText); battery_usable=\(battery.usable ? 1 : 0); battery_drop_recent=\(drop.recent ? 1 : 0); battery_drop_delta=\(drop.delta); battery_drop_age_s=\(dropAgeText)"
    }

    static func activeSessionJournalEvidence(includeAge: Bool = true) -> String {
        ActiveSessionJournal.evidence(includeAge: includeAge)
    }

    static func evidenceToken(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-."))
        return value.unicodeScalars.map { allowed.contains($0) ? String($0) : "_" }.joined()
    }
}
