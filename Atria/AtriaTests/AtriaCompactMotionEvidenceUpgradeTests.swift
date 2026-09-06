import XCTest
@testable import Atria

/// 2026-08-29 compact-motion confidence upgrade wires:
/// 1. confirmed-sleep provenance/stage lanes source window-bounded epochs
///    from the compact tick store when sessions carry none,
/// 2. a durable compact generation schedules a throttled upgrade pass,
/// 3. review-/auto-confirmed sources join the motion-arrival upgrade lane
///    (manual_* stays excluded),
/// 4. the hr_only confidence tier follows the motionValidated flag.
/// The graceful-fallback pin: with no (or insufficient) compact rows every
/// path returns nil/unchanged, i.e. the historical hr_only behavior.
final class AtriaCompactMotionEvidenceUpgradeTests: XCTestCase {
    private var directory: URL!
    private var store: AtriaWhoop4MotionTickCompactStore!
    private var strapIdentifier: String!
    /// A fixed "now" one hour after the fixture night ends keeps the recency
    /// fence deterministic.
    private var now: Date!
    private var nightStart: Date!
    private var nightEnd: Date!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AtriaCompactMotionEvidenceUpgradeTests-\(UUID().uuidString)"
            )
        store = AtriaWhoop4MotionTickCompactStore(directoryURL: directory)
        strapIdentifier = UUID().uuidString
        // Whole-second UTC anchor inside a single day bucket, recent enough
        // for the 14-day recency fence, old enough to be a settled night.
        let anchor = Date(
            timeIntervalSince1970:
                (Date().timeIntervalSince1970 / 86_400).rounded(.down)
                    * 86_400 + 2 * 3_600
        )
        nightStart = anchor
        nightEnd = anchor.addingTimeInterval(45 * 60)
        now = nightEnd.addingTimeInterval(3_600)
    }

    override func tearDownWithError() throws {
        store = nil
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    // MARK: - Wire 1: window-bounded compact epochs

    func testCompactWindowMotionEvidenceQualifiesQuietNight() throws {
        try appendQuietNightRows()
        let evidence = try XCTUnwrap(fetchEvidence())
        XCTAssertTrue(evidence.provenance.measurementSufficient)
        XCTAssertTrue(evidence.provenance.lowMotionValidated)
        XCTAssertEqual(
            evidence.provenance.source,
            AtriaRecoveredMotionEpoch.source,
            "compact epochs reuse the settlement lane's projection; no forked source string"
        )
        XCTAssertFalse(evidence.epochs.isEmpty)
    }

    func testAbsentCompactRowsFailClosedToHROnly() throws {
        // No rows at all: the stat precheck must refuse before any decode.
        XCTAssertNil(fetchEvidence())
    }

    func testSparseCompactRowsFailClosedToHROnly() throws {
        // 1 row / 120 s cannot validate 30-second epochs; the provenance
        // sufficiency gate must refuse (never a partial upgrade).
        try appendQuietNightRows(strideSeconds: 120)
        XCTAssertNil(fetchEvidence())
    }

    func testStaleWindowIsNeverRead() throws {
        try appendQuietNightRows()
        let context = SessionStore.ConfirmedSleepCompactMotionContext(
            store: store,
            strapIdentifier: strapIdentifier,
            // A "now" far in the future puts the fixture night outside the
            // recency fence: the store cannot retain it, so don't stat it.
            now: nightEnd.addingTimeInterval(30 * 86_400)
        )
        XCTAssertNil(runOffMain { [nightStart, nightEnd] in
            try SessionStore.compactWindowMotionEvidence(
                start: nightStart!,
                end: nightEnd!,
                compactMotion: context,
                cooperativeDeadline: Self.relaxedDeadline()
            )
        } ?? nil)
    }

    // MARK: - Wire 3+4: end-to-end record upgrade

    func testHROnlyReviewConfirmedNightUpgradesOnMotionArrival() throws {
        try appendQuietNightRows()
        let evidence = try XCTUnwrap(fetchEvidence())
        let sleep = makeConfirmedSleep(
            source: "sleep_window",
            confidence: "user_confirmed_hr_only",
            motionSource: "historical_gravity_recovered_epoch_v1_missing",
            dayPrimaryChoice: true
        )
        let upgraded = try XCTUnwrap(runOffMain { [self] in
            try SessionStore.motionArrivalUpgradedConfirmedSleepIfNeeded(
                sleep,
                sourceSessions: [makeHeartRateSession()],
                drainedHeartSamples: [],
                compactMotionEvidence: evidence,
                reason: "test",
                cooperativeDeadline: Self.relaxedDeadline()
            )
        } ?? nil)
        XCTAssertTrue(upgraded.motionValidated)
        XCTAssertEqual(upgraded.motionSource, AtriaRecoveredMotionEpoch.source)
        XCTAssertEqual(upgraded.confidence, "user_confirmed_motion_validated")
        let stages = try XCTUnwrap(upgraded.stageSegments)
        XCTAssertFalse(stages.isEmpty)
        XCTAssertTrue(
            stages.allSatisfy {
                $0.id.hasPrefix(SleepStageSegment.motionReceiptIDPrefix)
            },
            "validated motion must mint research-motion-v2 receipts, not estimate stages"
        )
        // Metrics-preservation pin: the upgrade may never rewrite engine-
        // settled hours or evidence counters for non-adjusted sources.
        XCTAssertEqual(upgraded.duration, sleep.duration)
        XCTAssertEqual(upgraded.span, sleep.span)
        XCTAssertEqual(upgraded.samples, sleep.samples)
        XCTAssertEqual(upgraded.avgHR, sleep.avgHR)
        XCTAssertEqual(upgraded.source, sleep.source, "source is identity; never rewritten")
        XCTAssertEqual(upgraded.dayPrimaryChoice, sleep.dayPrimaryChoice)
        XCTAssertTrue(
            SessionStore.sleepRecordIsUserAuthored(upgraded),
            "the upgraded confidence keeps its user_confirmed_ authorship prefix"
        )
    }

    func testHROnlyNightWithoutCompactEvidenceStaysByteIdentical() throws {
        let sleep = makeConfirmedSleep(
            source: "sleep_window",
            confidence: "user_confirmed_hr_only",
            motionSource: "historical_gravity_recovered_epoch_v1_missing"
        )
        let result = runOffMain { [self] in
            try SessionStore.motionArrivalUpgradedConfirmedSleepIfNeeded(
                sleep,
                sourceSessions: [makeHeartRateSession()],
                drainedHeartSamples: [],
                compactMotionEvidence: nil,
                reason: "test",
                cooperativeDeadline: Self.relaxedDeadline()
            )
        }
        XCTAssertNil(result ?? nil,
                     "no compact evidence -> nil -> the caller keeps today's hr_only record untouched")
    }

    func testManualSourcesNeverUpgrade() throws {
        try appendQuietNightRows()
        let evidence = try XCTUnwrap(fetchEvidence())
        for source in ["manual_sleep", "manual_nap"] {
            XCTAssertFalse(
                SessionStore.confirmedSleepSourceIsMotionUpgradeEligible(source)
            )
            let sleep = makeConfirmedSleep(
                source: source,
                confidence: "manual_user_entered",
                motionSource: "manual"
            )
            let result = runOffMain { [self] in
                try SessionStore.motionArrivalUpgradedConfirmedSleepIfNeeded(
                    sleep,
                    sourceSessions: [makeHeartRateSession()],
                    drainedHeartSamples: [],
                    compactMotionEvidence: evidence,
                    reason: "test",
                    cooperativeDeadline: Self.relaxedDeadline()
                )
            }
            XCTAssertNil(result ?? nil,
                         "\(source): a hand-typed window never earns sensor stages")
        }
    }

    func testUpgradeEligibilityCoversReviewAndAutoSources() {
        for source in [
            "sleep_window", "overnight_sleep", "aggregate_sleep",
            "nap_candidate", "auto_confirmed_sleep",
            "auto_confirmed_sleep_hr_only", "user_adjusted_sleep",
        ] {
            XCTAssertTrue(
                SessionStore.confirmedSleepSourceIsMotionUpgradeEligible(source),
                source
            )
        }
    }

    // MARK: - Wire 4: confidence string upgrade

    func testUpgradedConfidenceIsMonotonicAndPrefixPreserving() {
        XCTAssertEqual(
            SessionStore.upgradedConfirmedSleepConfidence(
                "user_confirmed_hr_only", motionValidated: true),
            "user_confirmed_motion_validated"
        )
        XCTAssertEqual(
            SessionStore.upgradedConfirmedSleepConfidence(
                "user_adjusted_hr_only", motionValidated: true),
            "user_adjusted_motion_validated"
        )
        // Never a downgrade, never on unvalidated motion, and source-tier
        // strings (auto_confirmed_sleep_hr_only lives in SOURCE, whose
        // confidence is "provisional") stay untouched.
        for unchanged in [
            "user_confirmed_hr_only", "user_adjusted_hr_only",
        ] {
            XCTAssertEqual(
                SessionStore.upgradedConfirmedSleepConfidence(
                    unchanged, motionValidated: false),
                unchanged
            )
        }
        for unchanged in [
            "user_confirmed_motion_validated", "user_adjusted_motion_validated",
            "provisional", "medium", "high", "low", "manual_user_entered",
            "user_confirmed_no_hr",
        ] {
            XCTAssertEqual(
                SessionStore.upgradedConfirmedSleepConfidence(
                    unchanged, motionValidated: true),
                unchanged
            )
        }
    }

    // MARK: - Wire 2: throttle + precheck planner

    func testUpgradePlannerThrottlesAndPrechecks() {
        let planner = SessionStore.compactMotionSleepEvidenceUpgradeCandidateWindows
        let hrOnly = makeConfirmedSleep(
            source: "sleep_window",
            confidence: "user_confirmed_hr_only",
            motionSource: "historical_gravity_recovered_epoch_v1_missing"
        )
        // Eligible: recent hr_only night, idle recompute, no throttle.
        XCTAssertEqual(
            planner(now, nil, false, true, [hrOnly], 30 * 60, 4 * 86_400)?
                .count,
            1
        )
        // Throttle floor: a second durable generation inside 30 minutes must
        // not re-run the rebuild (no storm on repeated notifications).
        XCTAssertNil(planner(
            now, now.addingTimeInterval(-60), false, true, [hrOnly],
            30 * 60, 4 * 86_400
        ))
        XCTAssertNotNil(planner(
            now, now.addingTimeInterval(-31 * 60), false, true, [hrOnly],
            30 * 60, 4 * 86_400
        ))
        // In-flight and active-projection guards.
        XCTAssertNil(planner(now, nil, true, true, [hrOnly], 30 * 60, 4 * 86_400))
        XCTAssertNil(planner(now, nil, false, false, [hrOnly], 30 * 60, 4 * 86_400))
        // Nothing upgradeable: validated + staged, manual, or out of the
        // store's retention window.
        let done = makeConfirmedSleep(
            source: "sleep_window",
            confidence: "user_confirmed_motion_validated",
            motionSource: AtriaRecoveredMotionEpoch.source,
            motionValidated: true,
            stageSegments: [SleepStageSegment(
                id: "research-motion-v2-test-0-light",
                start: hrOnly.start,
                end: hrOnly.end,
                stage: .light
            )]
        )
        XCTAssertNil(planner(now, nil, false, true, [done], 30 * 60, 4 * 86_400))
        let manual = makeConfirmedSleep(
            source: "manual_sleep",
            confidence: "manual_user_entered",
            motionSource: "manual"
        )
        XCTAssertNil(planner(now, nil, false, true, [manual], 30 * 60, 4 * 86_400))
        XCTAssertNil(planner(
            now.addingTimeInterval(10 * 86_400), nil, false, true, [hrOnly],
            30 * 60, 4 * 86_400
        ))
    }

    // MARK: - Monotonicity: the 08-29 device clobber

    /// Device regression 2026-08-29: an upgrade committed by one lane was
    /// replaced minutes later by an hr-estimate image prepared from an older
    /// snapshot (several lanes run the chain concurrently at launch, and the
    /// ordinary rebase applies a prepared delta over CURRENT
    /// unconditionally). The save-level fence must keep the record
    /// motion-validated.
    func testStaleContextlessPassCannotDowngradeMotionValidatedRecord() throws {
        let hrOnlyStageless = makeConfirmedSleep(
            source: "nap_candidate",
            confidence: "user_confirmed_hr_only",
            motionSource: "historical_gravity_recovered_epoch_v1_missing"
        )
        // What a context-less pass (failed compact read) lawfully prepares
        // from that stale base: an allowHROnlyEstimate re-mint.
        let estimateDowngrade = makeConfirmedSleep(
            source: "nap_candidate",
            confidence: "user_confirmed_hr_only",
            motionSource: "historical_gravity_recovered_epoch_v1_missing",
            motionValidated: false,
            stageSegments: [SleepStageSegment(
                id: "research-hr-estimate-v1-test-0-light",
                start: nightStart,
                end: nightEnd,
                stage: .light
            )]
        )
        // What the durable store holds by the time that stale delta lands:
        // the committed motion-validated upgrade.
        let upgraded = makeConfirmedSleep(
            source: "nap_candidate",
            confidence: "user_confirmed_motion_validated",
            motionSource: AtriaRecoveredMotionEpoch.source,
            motionValidated: true,
            stageSegments: [SleepStageSegment(
                id: "research-motion-v2-test-0-light",
                start: nightStart,
                end: nightEnd,
                stage: .light
            )]
        )
        for usesRecoveredRebase in [false, true] {
            let preparation = try XCTUnwrap(SessionStore.prepareConfirmedSleepSave(
                base: [hrOnlyStageless],
                desired: [estimateDowngrade],
                authoritativeCurrent: [upgraded],
                previous: [upgraded],
                dailyMetrics: [],
                baseNeedHours: 8,
                calendar: .current,
                usesRecoveredRebase: usesRecoveredRebase,
                rebuildsBaselineOffMain: false,
                baselineSessions: [],
                previousBaseline: PersonalBaseline(restingHR: nil, hrvEMA: nil),
                profile: AthleteProfile(age: 35,
                                        measuredMaxHR: 185,
                                        maxHRSource: .measured,
                                        biologicalSex: .male,
                                        weightKg: 75,
                                        heightCm: 178,
                                        updated: nil,
                                        hasCompletedOnboarding: true),
                preparationNow: now,
                shouldContinue: { true }
            ))
            let settled = try XCTUnwrap(
                preparation.settledSleeps.first { $0.id == upgraded.id },
                "record must survive the merge (rebase \(usesRecoveredRebase))"
            )
            XCTAssertTrue(settled.motionValidated,
                          "stale pass must not clear the verdict (rebase \(usesRecoveredRebase))")
            XCTAssertEqual(settled.motionSource, AtriaRecoveredMotionEpoch.source)
            XCTAssertEqual(settled.confidence, "user_confirmed_motion_validated")
            XCTAssertTrue(
                (settled.stageSegments ?? []).allSatisfy {
                    $0.id.hasPrefix(SleepStageSegment.motionReceiptIDPrefix)
                },
                "receipt stages must survive (rebase \(usesRecoveredRebase))"
            )
            XCTAssertEqual(settled.stageSegments?.isEmpty, false)
        }
    }

    func testMonotonicFenceAllowsEditsRemintsAndStripState() throws {
        let upgraded = makeConfirmedSleep(
            source: "sleep_window",
            confidence: "user_confirmed_motion_validated",
            motionSource: AtriaRecoveredMotionEpoch.source,
            motionValidated: true,
            stageSegments: [SleepStageSegment(
                id: "research-motion-v2-test-0-light",
                start: nightStart,
                end: nightEnd,
                stage: .light
            )]
        )
        // A window edit is real authority: evidence must re-derive.
        var edited = makeConfirmedSleep(
            source: "sleep_window",
            confidence: "user_confirmed_hr_only",
            motionSource: "user_review",
            motionValidated: false
        )
        edited = UserConfirmedSleep(
            id: upgraded.id,
            createdAt: edited.createdAt,
            start: edited.start.addingTimeInterval(-600),
            end: edited.end,
            source: edited.source,
            confidence: edited.confidence,
            sessions: edited.sessions,
            samples: edited.samples,
            avgHR: edited.avgHR,
            peakHR: edited.peakHR,
            restingHR: edited.restingHR,
            hrv: edited.hrv,
            hrvWindowCount: edited.hrvWindowCount,
            respiratoryRate: edited.respiratoryRate,
            duration: edited.duration,
            span: edited.span,
            reason: edited.reason,
            motionSource: edited.motionSource,
            motionValidated: edited.motionValidated,
            stageSegments: nil,
            eventTimeZoneIdentifier: edited.eventTimeZoneIdentifier
        )
        let editResult = try XCTUnwrap(
            SessionStore.motionEvidenceMonotonicConfirmedSleeps(
                settled: [edited],
                authoritativeCurrent: [upgraded]
            )
        )
        XCTAssertEqual(editResult.first?.motionValidated, false,
                       "a changed window is an edit, never a fenced downgrade")
        // A motion-receipted re-mint (even with an active/awake verdict) is
        // fresh motion authority, not a downgrade.
        let remint = makeConfirmedSleep(
            source: "sleep_window",
            confidence: "user_confirmed_motion_validated",
            motionSource: AtriaRecoveredMotionEpoch.source,
            motionValidated: false,
            stageSegments: [SleepStageSegment(
                id: "research-motion-v2-test-1-awake",
                start: nightStart,
                end: nightEnd,
                stage: .awake
            )]
        )
        let remintResult = try XCTUnwrap(
            SessionStore.motionEvidenceMonotonicConfirmedSleeps(
                settled: [remint],
                authoritativeCurrent: [upgraded]
            )
        )
        XCTAssertEqual(remintResult.first?.motionValidated, false,
                       "a motion-receipted re-verdict passes through")
        // The rebuild's strip-for-remint keeps the verdict; untouched.
        let strip = makeConfirmedSleep(
            source: "sleep_window",
            confidence: "user_confirmed_motion_validated",
            motionSource: AtriaRecoveredMotionEpoch.source,
            motionValidated: true,
            stageSegments: nil
        )
        let stripResult = try XCTUnwrap(
            SessionStore.motionEvidenceMonotonicConfirmedSleeps(
                settled: [strip],
                authoritativeCurrent: [upgraded]
            )
        )
        XCTAssertNil(stripResult.first?.stageSegments,
                     "the intentional strip-for-remint state passes through")
    }

    func testMultipleRecordsUpgradeInOneArrivalPass() throws {
        try appendQuietNightRows()
        // Second qualifying window later the same day, disjoint from the
        // first: 90 minutes starting 2h after the first night ends.
        let secondStart = nightEnd.addingTimeInterval(2 * 3_600)
        let secondEnd = secondStart.addingTimeInterval(90 * 60)
        try appendQuietRows(start: secondStart, end: secondEnd, tickSeed: 40_000)
        let context = SessionStore.ConfirmedSleepCompactMotionContext(
            store: store,
            strapIdentifier: strapIdentifier,
            now: secondEnd.addingTimeInterval(3_600)
        )
        let windows: [(String, Date, Date)] = [
            ("sleep_window", nightStart, nightEnd),
            ("nap_candidate", secondStart, secondEnd),
        ]
        var upgradedCount = 0
        for (source, start, end) in windows {
            let sleep = UserConfirmedSleep(
                id: "multi-\(source)",
                createdAt: end,
                start: start,
                end: end,
                source: source,
                confidence: "user_confirmed_hr_only",
                sessions: 1,
                samples: 1_350,
                avgHR: 59,
                peakHR: 66,
                restingHR: 56,
                hrv: nil,
                hrvWindowCount: nil,
                respiratoryRate: nil,
                duration: end.timeIntervalSince(start),
                span: end.timeIntervalSince(start),
                reason: "test",
                motionSource: "historical_gravity_recovered_epoch_v1_missing",
                motionValidated: false,
                stageSegments: nil,
                eventTimeZoneIdentifier: TimeZone.current.identifier
            )
            let session = SavedSession(
                id: UUID(),
                start: start,
                end: end,
                label: "HR",
                points: stride(
                    from: 0.0,
                    through: end.timeIntervalSince(start),
                    by: 2.0
                ).map { SavedSession.Point(t: $0, bpm: 58 + Int($0 / 600) % 4) }
            )
            let upgraded = runOffMain {
                guard let evidence = try SessionStore.compactWindowMotionEvidence(
                    start: start,
                    end: end,
                    compactMotion: context,
                    cooperativeDeadline: Self.relaxedDeadline()
                ) else { return UserConfirmedSleep?.none }
                return try SessionStore.motionArrivalUpgradedConfirmedSleepIfNeeded(
                    sleep,
                    sourceSessions: [session],
                    drainedHeartSamples: [],
                    compactMotionEvidence: evidence,
                    reason: "test",
                    cooperativeDeadline: Self.relaxedDeadline()
                )
            }
            let record = try XCTUnwrap(upgraded ?? nil, "window \(source) must upgrade")
            XCTAssertTrue(record.motionValidated, source)
            XCTAssertEqual(record.confidence, "user_confirmed_motion_validated", source)
            upgradedCount += 1
        }
        XCTAssertEqual(upgradedCount, 2)
    }

    // MARK: - Fixture helpers

    private static func relaxedDeadline() -> AtriaSleepSettlementDeadline {
        AtriaSleepSettlementDeadline(
            uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
                + 30_000_000_000
        )
    }

    /// The production lanes run these helpers on cooperative utility
    /// threads; `compactWindowMotionEvidence` fails closed on the main
    /// thread, so tests hop off it the same way the callers do.
    private func runOffMain<T>(
        _ work: @escaping @Sendable () throws -> T
    ) -> T? {
        let expectation = expectation(description: "off-main work")
        let box = ResultBox<T>()
        DispatchQueue.global(qos: .utility).async {
            box.value = try? work()
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 60)
        return box.value
    }

    private final class ResultBox<T>: @unchecked Sendable {
        var value: T?
    }

    private func fetchEvidence()
        -> SessionStore.CompactWindowMotionEvidence? {
        let context = SessionStore.ConfirmedSleepCompactMotionContext(
            store: store,
            strapIdentifier: strapIdentifier,
            now: now
        )
        return runOffMain { [nightStart, nightEnd] in
            try SessionStore.compactWindowMotionEvidence(
                start: nightStart!,
                end: nightEnd!,
                compactMotion: context,
                cooperativeDeadline: Self.relaxedDeadline()
            )
        } ?? nil
    }

    /// ~1 Hz constant-gravity rows across the fixture night: every 30-second
    /// projection validates and low-motion-qualifies, mirroring the quiet
    /// nights the device audit measured (validatedFraction 0.96+, mean
    /// intensity ~0.06).
    private func appendQuietNightRows(strideSeconds: Int = 1) throws {
        try appendQuietRows(start: nightStart,
                            end: nightEnd,
                            tickSeed: 0,
                            strideSeconds: strideSeconds)
    }

    private func appendQuietRows(start: Date,
                                 end: Date,
                                 tickSeed: Int,
                                 strideSeconds: Int = 1) throws {
        let base = UInt32(start.timeIntervalSince1970.rounded(.down))
        let total = Int(end.timeIntervalSince(start))
        var tick = tickSeed
        for second in stride(from: 0, through: total, by: strideSeconds) {
            let unix = base + UInt32(second)
            XCTAssertTrue(try store.append(
                record: makeRecord(unix: unix, flash: UInt32(second + 1), tick: tick),
                rawPayload: payloadIdentity(unix: unix, tick: tick),
                strapIdentifier: strapIdentifier
            ))
            tick = (tick + (second % 600 == 0 ? 1 : 0)) % 65_536
        }
        try store.synchronize()
    }

    private func makeHeartRateSession() -> SavedSession {
        SavedSession(
            id: UUID(),
            start: nightStart,
            end: nightEnd,
            label: "Sleep HR",
            points: stride(
                from: 0.0,
                through: nightEnd.timeIntervalSince(nightStart),
                by: 2.0
            ).map { SavedSession.Point(t: $0, bpm: 58 + Int($0 / 600) % 4) }
        )
    }

    private func makeConfirmedSleep(
        source: String,
        confidence: String,
        motionSource: String,
        motionValidated: Bool = false,
        stageSegments: [SleepStageSegment]? = nil,
        dayPrimaryChoice: Bool? = nil
    ) -> UserConfirmedSleep {
        let span = nightEnd.timeIntervalSince(nightStart)
        return UserConfirmedSleep(
            id: "test-\(source)",
            createdAt: nightEnd,
            start: nightStart,
            end: nightEnd,
            source: source,
            confidence: confidence,
            sessions: 1,
            samples: 1_350,
            avgHR: 59,
            peakHR: 66,
            restingHR: 56,
            hrv: nil,
            hrvWindowCount: nil,
            respiratoryRate: nil,
            duration: span,
            span: span,
            reason: "test",
            motionSource: motionSource,
            motionValidated: motionValidated,
            stageSegments: stageSegments,
            eventTimeZoneIdentifier: TimeZone.current.identifier,
            dayPrimaryChoice: dayPrimaryChoice
        )
    }

    private func makeRecord(
        unix: UInt32,
        flash: UInt32,
        tick: Int
    ) -> HistoricalArchive.Record {
        var record = HistoricalArchive.Record(
            schema: HistoricalArchive.schema,
            capturedAt: Date(timeIntervalSince1970: TimeInterval(unix)),
            source: "0x2f",
            layoutVersion: HistoricalArchive.layoutVersion,
            sequence: Int(AtriaWhoop4HistoricalLayout.v24.rawValue),
            command: 0x2f,
            unix7: unix,
            subsec11: 0,
            flash13: flash,
            payloadLength: 92,
            whoofHR17: 58,
            whoofRRNum18: 0,
            whoofRR19: [],
            kRR64: [],
            gravityX36: 0.01,
            gravityY40: 0.02,
            gravityZ44: 0.999,
            unknownMotionScalar32: 0.05,
            gravityMagnitude: 1,
            gravityValidated: true,
            candidateRR: [],
            rawPayloadHex: "",
            clockDeviceRef: unix,
            clockWallRef: unix,
            clockDriftSeconds: 0,
            clockCorrectedUnix7: unix,
            clockCorrectionStatus: "clock_ref_present",
            currentSessionUsable: true,
            metricUsable: true,
            usabilityReason: "test"
        )
        record.motionTickCounter88 = tick
        return record
    }

    private func payloadIdentity(unix: UInt32, tick: Int) -> [UInt8] {
        withUnsafeBytes(of: unix.littleEndian) { unixBytes in
            withUnsafeBytes(of: UInt16(tick).littleEndian) { tickBytes in
                Array(unixBytes) + Array(tickBytes)
            }
        }
    }
}
