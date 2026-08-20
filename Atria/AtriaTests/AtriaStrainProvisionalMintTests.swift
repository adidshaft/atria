import XCTest
@testable import Atria

/// W3-B (STRENGTHEN_FIVE_PLAN 2026-08-20): strain provisional mint +
/// prior-cycle disclosure.
///
/// Fix 2: a stable daily target is reachable from a NUMERIC AUTHORITATIVE
/// `.unverified` recovery — never from the pending sleep-review presentation
/// preview — via `MutationAuthority.provisionalMint`, which may only FILL an
/// empty cycle slot. The minting tier is recorded as provenance on the
/// schema-2 `AtriaFrozenDailyStrainTarget` (the on-device v1 blob still
/// decodes), surfaces can label the target "provisional" through the existing
/// targetSummary/sourceLabel plumbing, and a canonical settle with the same
/// percent re-mints exactly once with disclosed upgraded provenance.
///
/// Fix 5: during the post-wake window where the cycle has flipped but no
/// target exists yet (the shifted sleeper's daily ~19:15 wake), the PRIOR
/// cycle's real frozen target appears only as a dated disclosure in the
/// guidance sentence; `target` stays nil so the zone chip stays absent.
final class AtriaStrainProvisionalMintTests: XCTestCase {

    private func isolatedDefaults() throws -> (UserDefaults, String) {
        let name = "AtriaStrainProvisionalMintTests.\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: name)), name)
    }

    private var gmtCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    /// Post-2026-08-06 anchor (2027-01-15T08:00:00Z) per the repo's fixture
    /// time-base rule.
    private let wake = Date(timeIntervalSince1970: 1_800_000_000)

    private func estimate(percent: Int?,
                          confidence: Metrics.RecoveryEstimate.Confidence,
                          detail: String = "fixture") -> Metrics.RecoveryEstimate {
        Metrics.RecoveryEstimate(percent: percent,
                                 confidence: confidence,
                                 usesHRV: false,
                                 detail: detail,
                                 contributors: [])
    }

    private var preparedHighLoad: TrainingLoadSummary {
        TrainingLoadSummary(acuteLoad: 14,
                            chronicLoad: 10,
                            ratio: 1.4,
                            monotony: 1.1,
                            confidence: "local",
                            readiness: "strained",
                            acwrSignal: "bad",
                            monotonySignal: "good",
                            targetBand: nil,
                            detail: "fixture")
    }

    // MARK: - Fix 2: mint from unverified numeric authoritative recovery records the tier

    func testUnverifiedNumericAuthoritativeRecoveryMintsProvisionallyAndRecordsTier() throws {
        let (defaults, name) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        // Home-shaped derivation: the gate passes an authoritative unverified
        // estimate through as (percent, tier)...
        let authorized = try XCTUnwrap(AtriaHomeModel.recoveryAuthorizedForStrainTarget(
            estimate(percent: 50, confidence: .unverified)
        ))
        XCTAssertEqual(authorized.percent, 50)
        XCTAssertEqual(authorized.tier, .unverified)
        // ...and the shared standard grants provisional (fill-only) authority.
        XCTAssertEqual(AtriaDailyStrainTargetStore.mintAuthority(recoveryConfidence: authorized.tier),
                       .provisionalMint)

        let minted = try XCTUnwrap(AtriaDailyStrainTargetStore.resolve(
            recovery: authorized.percent,
            recoveryConfidence: authorized.tier,
            load: .learning,
            recoveryIsAttributedToCurrentDay: true,
            loadIsPrepared: true,
            mutationAuthority: AtriaDailyStrainTargetStore.mintAuthority(recoveryConfidence: authorized.tier),
            cycleStart: wake,
            now: wake.addingTimeInterval(60),
            calendar: gmtCalendar,
            defaults: defaults
        ))
        XCTAssertEqual(minted.target, 13, accuracy: 0.0001)
        XCTAssertEqual(minted.recoveryConfidence, "unverified",
                       "the minting tier is the provenance")
        XCTAssertTrue(minted.isProvisional)
        XCTAssertEqual(minted.schemaVersion, 2)

        let stored = try XCTUnwrap(AtriaDailyStrainTargetStore.loadSnapshot(defaults: defaults))
        XCTAssertEqual(stored, minted, "the provisional mint is durable")
        XCTAssertEqual(stored.recoveryConfidence, "unverified")
    }

    // MARK: - Fix 2: the pending-review preview never reaches the minter

    func testPendingReviewPreviewMarkerIsStrippedWhateverItsTier() throws {
        let previewDetail = "Today · pending sleep review · limited confidence · fixture"
        XCTAssertNil(AtriaHomeModel.recoveryAuthorizedForStrainTarget(
            estimate(percent: 55, confidence: .unverified, detail: previewDetail)
        ), "the preview is display evidence only — numeric percent notwithstanding")
        // Even an (impossible today) canonical-tier preview stays stripped:
        // the authority marker outranks the tier.
        XCTAssertNil(AtriaHomeModel.recoveryAuthorizedForStrainTarget(
            estimate(percent: 55, confidence: .personalBaseline, detail: previewDetail)
        ))
        // Authoritative estimates pass with their tier.
        XCTAssertEqual(AtriaHomeModel.recoveryAuthorizedForStrainTarget(
            estimate(percent: 55, confidence: .unverified)
        )?.tier, .unverified)
        XCTAssertEqual(AtriaHomeModel.recoveryAuthorizedForStrainTarget(
            estimate(percent: 60, confidence: .personalBaseline)
        )?.tier, .personalBaseline)
        // Learning and percent-nil estimates never pass.
        XCTAssertNil(AtriaHomeModel.recoveryAuthorizedForStrainTarget(
            estimate(percent: 55, confidence: .learning)
        ))
        XCTAssertNil(AtriaHomeModel.recoveryAuthorizedForStrainTarget(
            estimate(percent: nil, confidence: .unverified)
        ))
    }

    /// Source pin: the Home gate's marker must keep matching the stamp the
    /// presentation authority writes in Sessions.swift
    /// (`pendingSleepRecoveryEstimate`). Editing either string requires
    /// consciously revisiting the W3-B preview boundary.
    func testPreviewMarkerPinsTheSessionsPresentationStamp() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sessionsSource = try String(
            contentsOf: sourceRoot.appendingPathComponent("Atria/Sessions.swift"),
            encoding: .utf8
        )
        let stamp = "Today · pending sleep review · limited confidence ·"
        XCTAssertTrue(sessionsSource.contains(stamp),
                      "the presentation authority must keep stamping the preview detail")
        XCTAssertTrue(stamp.contains(AtriaHomeModel.pendingSleepReviewPreviewDetailMarker),
                      "Home's marker must be a substring of the Sessions stamp")
    }

    // MARK: - Fix 2: provisional authority may only FILL an empty slot

    func testProvisionalMintNeverReplacesDeletesOrOverwritesExistingState() throws {
        let (defaults, name) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let calendar = gmtCalendar

        let canonical = try XCTUnwrap(AtriaDailyStrainTargetStore.resolve(
            recovery: 70,
            recoveryConfidence: .personalBaseline,
            load: .learning,
            recoveryIsAttributedToCurrentDay: true,
            loadIsPrepared: true,
            mutationAuthority: .canonical,
            cycleStart: wake,
            now: wake.addingTimeInterval(60),
            calendar: calendar,
            defaults: defaults
        ))
        let canonicalBytes = try XCTUnwrap(defaults.data(
            forKey: AtriaDailyStrainTargetStore.storageKey
        ))

        // A provisional caller with a DIFFERENT percent may not replace the
        // canonical same-cycle target.
        let provisionalRead = AtriaDailyStrainTargetStore.resolve(
            recovery: 40,
            recoveryConfidence: .unverified,
            load: .learning,
            recoveryIsAttributedToCurrentDay: true,
            loadIsPrepared: true,
            mutationAuthority: .provisionalMint,
            cycleStart: wake,
            now: wake.addingTimeInterval(120),
            calendar: calendar,
            defaults: defaults
        )
        XCTAssertEqual(provisionalRead, canonical,
                       "weaker evidence must not replace stronger state")
        XCTAssertEqual(defaults.data(forKey: AtriaDailyStrainTargetStore.storageKey),
                       canonicalBytes,
                       "the durable blob must be byte-identical after a provisional pass")

        // Nil attribution under provisional authority preserves, never deletes
        // (the repo's recovery-state defect class).
        XCTAssertEqual(AtriaDailyStrainTargetStore.resolve(
            recovery: 40,
            recoveryConfidence: .unverified,
            load: .learning,
            recoveryIsAttributedToCurrentDay: false,
            loadIsPrepared: true,
            mutationAuthority: .provisionalMint,
            cycleStart: wake,
            now: wake.addingTimeInterval(180),
            calendar: calendar,
            defaults: defaults
        ), canonical)
        XCTAssertEqual(defaults.data(forKey: AtriaDailyStrainTargetStore.storageKey),
                       canonicalBytes)

        // At the NEXT wake cycle the slot is empty for that cycle, so the
        // provisional mint fills it — this is exactly what makes a stable
        // daily target reachable again on limited-evidence days.
        let nextWake = wake.addingTimeInterval(24 * 3_600)
        let nextMint = try XCTUnwrap(AtriaDailyStrainTargetStore.resolve(
            recovery: 40,
            recoveryConfidence: .unverified,
            load: .learning,
            recoveryIsAttributedToCurrentDay: true,
            loadIsPrepared: true,
            mutationAuthority: .provisionalMint,
            cycleStart: nextWake,
            now: nextWake.addingTimeInterval(60),
            calendar: calendar,
            defaults: defaults
        ))
        XCTAssertEqual(nextMint.day, nextWake)
        XCTAssertTrue(nextMint.isProvisional)
    }

    func testProvisionalMintWithoutAttributionOrRecoveryWritesNothing() throws {
        let (defaults, name) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertNil(AtriaDailyStrainTargetStore.resolve(
            recovery: 40,
            recoveryConfidence: .unverified,
            load: .learning,
            recoveryIsAttributedToCurrentDay: false,
            loadIsPrepared: true,
            mutationAuthority: .provisionalMint,
            cycleStart: wake,
            now: wake.addingTimeInterval(60),
            calendar: gmtCalendar,
            defaults: defaults
        ))
        XCTAssertNil(AtriaDailyStrainTargetStore.resolve(
            recovery: nil,
            recoveryConfidence: .unverified,
            load: .learning,
            recoveryIsAttributedToCurrentDay: true,
            loadIsPrepared: true,
            mutationAuthority: .provisionalMint,
            cycleStart: wake,
            now: wake.addingTimeInterval(60),
            calendar: gmtCalendar,
            defaults: defaults
        ))
        XCTAssertNil(defaults.data(forKey: AtriaDailyStrainTargetStore.storageKey))
    }

    // MARK: - Fix 2: tier upgrade re-mints exactly once

    func testTierUpgradeWithSamePercentRemintsExactlyOnceDisclosed() throws {
        let (defaults, name) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let calendar = gmtCalendar

        let provisional = try XCTUnwrap(AtriaDailyStrainTargetStore.resolve(
            recovery: 50,
            recoveryConfidence: .unverified,
            load: .learning,
            recoveryIsAttributedToCurrentDay: true,
            loadIsPrepared: true,
            mutationAuthority: .provisionalMint,
            cycleStart: wake,
            now: wake.addingTimeInterval(60),
            calendar: calendar,
            defaults: defaults
        ))
        XCTAssertEqual(provisional.target, 13, accuracy: 0.0001)
        XCTAssertEqual(provisional.recoveryConfidence, "unverified")
        XCTAssertEqual(provisional.loadProvenance, "load_learning_at_mint")

        // Canonical settle, same percent, prepared load: single re-mint. The
        // provisional tier AND the learning-load history stay legible inside
        // the new provenance strings — provenance relocates, never disappears.
        let upgraded = try XCTUnwrap(AtriaDailyStrainTargetStore.resolve(
            recovery: 50,
            recoveryConfidence: .personalBaseline,
            load: preparedHighLoad,
            recoveryIsAttributedToCurrentDay: true,
            loadIsPrepared: true,
            mutationAuthority: .canonical,
            cycleStart: wake,
            now: wake.addingTimeInterval(3_600),
            calendar: calendar,
            defaults: defaults
        ))
        XCTAssertEqual(upgraded.target, 11, accuracy: 0.0001,
                       "the disclosed one-time move: load leg re-derived at settle")
        XCTAssertEqual(upgraded.loadAdjustment, -2, accuracy: 0.0001)
        XCTAssertEqual(upgraded.loadProvenance, "load_high_upgraded_from_learning")
        XCTAssertEqual(upgraded.recoveryConfidence, "personal baseline_upgraded_from_unverified")
        XCTAssertFalse(upgraded.isProvisional)
        XCTAssertEqual(upgraded.recovery, provisional.recovery)
        XCTAssertEqual(upgraded.day, provisional.day)

        // Third resolve is a no-op — the upgrade fires at most once per cycle.
        let third = try XCTUnwrap(AtriaDailyStrainTargetStore.resolve(
            recovery: 50,
            recoveryConfidence: .personalBaseline,
            load: preparedHighLoad,
            recoveryIsAttributedToCurrentDay: true,
            loadIsPrepared: true,
            mutationAuthority: .canonical,
            cycleStart: wake,
            now: wake.addingTimeInterval(7_200),
            calendar: calendar,
            defaults: defaults
        ))
        XCTAssertEqual(third, upgraded)
        XCTAssertEqual(third.createdAt, upgraded.createdAt,
                       "a no-op resolve must not rewrite the snapshot")

        // A later provisional pass reads the upgraded target untouched.
        XCTAssertEqual(AtriaDailyStrainTargetStore.resolve(
            recovery: 50,
            recoveryConfidence: .unverified,
            load: preparedHighLoad,
            recoveryIsAttributedToCurrentDay: true,
            loadIsPrepared: true,
            mutationAuthority: .provisionalMint,
            cycleStart: wake,
            now: wake.addingTimeInterval(7_260),
            calendar: calendar,
            defaults: defaults
        ), upgraded)
    }

    func testTierUpgradeWithUnpreparedLoadKeepsTheValueAndLoadLeg() throws {
        let (defaults, name) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let calendar = gmtCalendar

        let provisional = try XCTUnwrap(AtriaDailyStrainTargetStore.resolve(
            recovery: 50,
            recoveryConfidence: .unverified,
            load: .learning,
            recoveryIsAttributedToCurrentDay: true,
            loadIsPrepared: true,
            mutationAuthority: .provisionalMint,
            cycleStart: wake,
            now: wake.addingTimeInterval(60),
            calendar: calendar,
            defaults: defaults
        ))

        let upgraded = try XCTUnwrap(AtriaDailyStrainTargetStore.resolve(
            recovery: 50,
            recoveryConfidence: .personalBaseline,
            load: .learning,
            recoveryIsAttributedToCurrentDay: true,
            loadIsPrepared: true,
            mutationAuthority: .canonical,
            cycleStart: wake,
            now: wake.addingTimeInterval(3_600),
            calendar: calendar,
            defaults: defaults
        ))
        XCTAssertEqual(upgraded.target, provisional.target, accuracy: 0.0001,
                       "a tier upgrade alone must not move the value")
        XCTAssertEqual(upgraded.loadAdjustment, provisional.loadAdjustment, accuracy: 0.0001)
        XCTAssertEqual(upgraded.loadProvenance, "load_learning_at_mint",
                       "the learning-load leg survives for the one-shot W1-C upgrade")
        XCTAssertEqual(upgraded.recoveryConfidence, "personal baseline_upgraded_from_unverified")

        // The W1-C load upgrade still fires exactly once afterwards.
        let loadUpgraded = try XCTUnwrap(AtriaDailyStrainTargetStore.resolve(
            recovery: 50,
            recoveryConfidence: .personalBaseline,
            load: preparedHighLoad,
            recoveryIsAttributedToCurrentDay: true,
            loadIsPrepared: true,
            mutationAuthority: .canonical,
            cycleStart: wake,
            now: wake.addingTimeInterval(7_200),
            calendar: calendar,
            defaults: defaults
        ))
        XCTAssertEqual(loadUpgraded.loadProvenance, "load_high_upgraded_from_learning")
        XCTAssertEqual(loadUpgraded.recoveryConfidence,
                       "personal baseline_upgraded_from_unverified",
                       "tier provenance survives the load upgrade")
    }

    // MARK: - Fix 2: personalBaseline behavior byte-identical to today

    func testPersonalBaselineMintBehaviorIsUnchanged() throws {
        let (defaults, name) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let calendar = gmtCalendar

        let minted = try XCTUnwrap(AtriaDailyStrainTargetStore.resolve(
            recovery: 50,
            recoveryConfidence: .personalBaseline,
            load: .learning,
            recoveryIsAttributedToCurrentDay: true,
            loadIsPrepared: true,
            mutationAuthority: .canonical,
            cycleStart: wake,
            now: wake.addingTimeInterval(60),
            calendar: calendar,
            defaults: defaults
        ))
        XCTAssertEqual(minted.target, 13, accuracy: 0.0001)
        XCTAssertEqual(minted.loadAdjustment, 0, accuracy: 0.0001)
        XCTAssertEqual(minted.loadProvenance, "load_learning_at_mint")
        XCTAssertEqual(minted.recoveryConfidence, "personal baseline")
        XCTAssertFalse(minted.isProvisional)

        // Same-cycle same-percent canonical resolve is still a no-op...
        let again = AtriaDailyStrainTargetStore.resolve(
            recovery: 50,
            recoveryConfidence: .personalBaseline,
            load: .learning,
            recoveryIsAttributedToCurrentDay: true,
            loadIsPrepared: true,
            mutationAuthority: .canonical,
            cycleStart: wake,
            now: wake.addingTimeInterval(120),
            calendar: calendar,
            defaults: defaults
        )
        XCTAssertEqual(again, minted)
        XCTAssertEqual(again?.createdAt, minted.createdAt)

        // ...and `.validated` is not a tier upgrade over an already-canonical
        // blob — `.validated` stays reserved for the held-out outcome study.
        let validatedPass = AtriaDailyStrainTargetStore.resolve(
            recovery: 50,
            recoveryConfidence: .validated,
            load: .learning,
            recoveryIsAttributedToCurrentDay: true,
            loadIsPrepared: true,
            mutationAuthority: .canonical,
            cycleStart: wake,
            now: wake.addingTimeInterval(180),
            calendar: calendar,
            defaults: defaults
        )
        XCTAssertEqual(validatedPass, minted,
                       "canonical state stands; no churn from tier relabeling")
    }

    // MARK: - Fix 2: schema 2 decodes the on-device v1 blob

    func testSchemaVersion2DecoderAcceptsOnDeviceV1Blob() throws {
        // The on-device blob shape from the July-22 mint: day/recovery/target
        // only (no schemaVersion, no load leg, no tier).
        struct DeviceV1Blob: Codable {
            let day: Date
            let recovery: Int
            let target: Double
        }
        let deviceBlob = DeviceV1Blob(day: wake, recovery: 50, target: 13)
        let decoded = try JSONDecoder().decode(AtriaFrozenDailyStrainTarget.self,
                                               from: JSONEncoder().encode(deviceBlob))
        XCTAssertEqual(decoded.target, 13, accuracy: 0.0001)
        XCTAssertEqual(decoded.recoveryConfidence,
                       AtriaFrozenDailyStrainTarget.legacyRecoveryConfidence)
        XCTAssertFalse(decoded.isProvisional,
                       "an unknown legacy tier is never labeled provisional")

        // A W1-C-era schemaVersion-1 blob (all fields except the tier) also
        // decodes with the defaulted tier.
        struct W1CBlob: Codable {
            let schemaVersion: Int
            let day: Date
            let timeZoneIdentifier: String
            let recovery: Int
            let target: Double
            let loadAdjustment: Double
            let loadProvenance: String
            let createdAt: Date
        }
        let w1c = W1CBlob(schemaVersion: 1,
                          day: wake,
                          timeZoneIdentifier: "GMT",
                          recovery: 64,
                          target: 15,
                          loadAdjustment: 0,
                          loadProvenance: "load_aligned",
                          createdAt: wake.addingTimeInterval(60))
        let decodedW1C = try JSONDecoder().decode(AtriaFrozenDailyStrainTarget.self,
                                                  from: JSONEncoder().encode(w1c))
        XCTAssertEqual(decodedW1C.schemaVersion, 1)
        XCTAssertEqual(decodedW1C.loadProvenance, "load_aligned")
        XCTAssertEqual(decodedW1C.recoveryConfidence,
                       AtriaFrozenDailyStrainTarget.legacyRecoveryConfidence)

        // Round trip: a fresh mint encodes schema 2 with its tier and decodes
        // to an equal value.
        let (defaults, name) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let minted = try XCTUnwrap(AtriaDailyStrainTargetStore.resolve(
            recovery: 50,
            recoveryConfidence: .unverified,
            load: .learning,
            recoveryIsAttributedToCurrentDay: true,
            loadIsPrepared: true,
            mutationAuthority: .provisionalMint,
            cycleStart: wake,
            now: wake.addingTimeInterval(60),
            calendar: gmtCalendar,
            defaults: defaults
        ))
        let bytes = try XCTUnwrap(defaults.data(forKey: AtriaDailyStrainTargetStore.storageKey))
        let roundTripped = try JSONDecoder().decode(AtriaFrozenDailyStrainTarget.self, from: bytes)
        XCTAssertEqual(roundTripped, minted)
        XCTAssertEqual(roundTripped.schemaVersion, 2)
        XCTAssertEqual(roundTripped.recoveryConfidence, "unverified")
    }

    // MARK: - Fix 2: provisional labeling through the existing zone plumbing

    func testStrainZoneProvisionalRelabelsSourceLineOnly() throws {
        let plain = try XCTUnwrap(Metrics.strainZone(strain: 12, target: 10))
        XCTAssertEqual(plain.sourceLabel, "Recovery-scaled target",
                       "default call sites are unchanged")

        let provisional = try XCTUnwrap(Metrics.strainZone(strain: 12,
                                                           target: 10,
                                                           provisional: true))
        XCTAssertEqual(provisional.sourceLabel,
                       AtriaMetricZone.provisionalStrainTargetSourceHead)
        XCTAssertEqual(provisional.level, plain.level,
                       "labels only — the zone level is untouched")
        XCTAssertEqual(provisional.current, plain.current)
        XCTAssertEqual(provisional.recommendation, plain.recommendation)
        XCTAssertTrue(provisional.targetSummary.contains("Green within"),
                      "the band text tail survives the relabel")

        // Fail-closed absence is untouched: no target, no chip — provisional
        // labeling cannot resurrect it.
        XCTAssertNil(Metrics.strainZone(strain: 12, target: nil, provisional: true))
    }

    // MARK: - Fix 5: shifted-sleeper prior-cycle dated disclosure

    func testShiftedSleeperCycleFlipShowsDatedPriorTargetAndNoZoneChip() throws {
        let (defaults, name) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Kolkata"))

        // The user's daily reality: wake confirms at ~19:15 IST. Prior cycle
        // 2026-08-18 19:15, current cycle 2026-08-19 19:15 (post-2026-08-06
        // fixture time base).
        let priorWake = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 18, hour: 19, minute: 15
        )))
        let currentWake = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 19, hour: 19, minute: 15
        )))

        let priorTarget = try XCTUnwrap(AtriaDailyStrainTargetStore.resolve(
            recovery: 64,
            recoveryConfidence: .personalBaseline,
            load: .learning,
            recoveryIsAttributedToCurrentDay: true,
            loadIsPrepared: true,
            mutationAuthority: .canonical,
            cycleStart: priorWake,
            now: priorWake.addingTimeInterval(60),
            calendar: calendar,
            defaults: defaults
        ))

        // The cycle has flipped; recovery is unverified and not yet numeric,
        // so nothing may mint and the resolve read returns no target.
        let now = currentWake.addingTimeInterval(5 * 60)
        let recovery = estimate(percent: nil, confidence: .unverified)
        XCTAssertNil(AtriaHomeModel.recoveryAuthorizedForStrainTarget(recovery))
        XCTAssertNil(AtriaDailyStrainTargetStore.resolve(
            recovery: nil,
            load: .learning,
            recoveryIsAttributedToCurrentDay: false,
            loadIsPrepared: true,
            mutationAuthority: .preserveExisting,
            cycleStart: currentWake,
            now: now,
            calendar: calendar,
            defaults: defaults
        ), "the prior cycle's target is never the new cycle's answer")

        // The prior blob is still live (within one cycle) and reads as the
        // dated disclosure source — read-only.
        let bytesBefore = defaults.data(forKey: AtriaDailyStrainTargetStore.storageKey)
        let prior = try XCTUnwrap(AtriaDailyStrainTargetStore.priorCycleSnapshot(
            cycleStart: currentWake,
            now: now,
            calendar: calendar,
            defaults: defaults
        ))
        XCTAssertEqual(prior, priorTarget)
        XCTAssertEqual(defaults.data(forKey: AtriaDailyStrainTargetStore.storageKey),
                       bytesBefore,
                       "the disclosure read never mutates storage")

        // Guidance carries the REAL prior target with its REAL date; the
        // primary target stays nil.
        let kernel = Coach.guide(recovery: recovery, strain: 2.4)
        XCTAssertNil(kernel.target)
        let disclosed = AtriaHomeModel.guidanceDisclosingPriorCycleStrainTarget(
            kernel,
            priorCycleTarget: prior
        )
        let dateText = prior.day.formatted(.dateTime.month(.abbreviated).day())
        XCTAssertTrue(disclosed.detail.contains("Prior cycle (\(dateText))"),
                      "the disclosure must be dated: \(disclosed.detail)")
        XCTAssertTrue(disclosed.detail.contains(String(format: "%.1f", prior.target)),
                      "the disclosure must carry the real prior value")
        XCTAssertNil(disclosed.target, "no fabricated primary target")
        XCTAssertTrue(disclosed.reason.hasSuffix("_prior_cycle_target_disclosed"))

        // Zone chip stays absent: `TargetZones.strain` fail-closed on nil.
        XCTAssertNil(Metrics.strainZone(strain: 2.4, target: disclosed.target))
    }

    func testPriorCycleDisclosureFailsClosedOutsideItsWindow() throws {
        let (defaults, name) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let calendar = gmtCalendar

        _ = try XCTUnwrap(AtriaDailyStrainTargetStore.resolve(
            recovery: 64,
            recoveryConfidence: .personalBaseline,
            load: .learning,
            recoveryIsAttributedToCurrentDay: true,
            loadIsPrepared: true,
            mutationAuthority: .canonical,
            cycleStart: wake,
            now: wake.addingTimeInterval(60),
            calendar: calendar,
            defaults: defaults
        ))

        // Same cycle: the blob is the live target, not a prior disclosure.
        XCTAssertNil(AtriaDailyStrainTargetStore.priorCycleSnapshot(
            cycleStart: wake,
            now: wake.addingTimeInterval(3_600),
            calendar: calendar,
            defaults: defaults
        ))
        // More than one full cycle stale: mint-outage evidence (the July-22
        // shape) is for the audit slot, never a coaching display.
        XCTAssertNil(AtriaDailyStrainTargetStore.priorCycleSnapshot(
            cycleStart: wake.addingTimeInterval(20 * 24 * 3_600),
            now: wake.addingTimeInterval(20 * 24 * 3_600 + 60),
            calendar: calendar,
            defaults: defaults
        ))
        // Immediately previous cycle: disclosed.
        XCTAssertNotNil(AtriaDailyStrainTargetStore.priorCycleSnapshot(
            cycleStart: wake.addingTimeInterval(24 * 3_600),
            now: wake.addingTimeInterval(24 * 3_600 + 60),
            calendar: calendar,
            defaults: defaults
        ))

        // The guidance amendment is inert whenever a live target exists.
        let ready = Coach.guide(recovery: 64, strain: 6, frozenTarget: 15)
        XCTAssertEqual(AtriaHomeModel.guidanceDisclosingPriorCycleStrainTarget(
            ready,
            priorCycleTarget: AtriaDailyStrainTargetStore.loadSnapshot(defaults: defaults)
        ), ready, "a present target must never be mixed with a prior disclosure")
    }
}
