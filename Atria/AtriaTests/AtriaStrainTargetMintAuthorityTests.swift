import XCTest
@testable import Atria

/// W1-C (STRENGTHEN_FIVE_PLAN 2026-08-20): strain-target mint authority.
/// One honesty standard for the one durable strain-target write — the Home
/// hero snapshot and the notification scheduler derive mint authority from
/// the same shared gate; nil attribution preserves, never erases (the repo's
/// recovery-state defect class); a learning-load mint upgrades exactly once;
/// a stale blob is relocated to the audit slot, never silently deleted and
/// never returned.
final class AtriaStrainTargetMintAuthorityTests: XCTestCase {

    private func isolatedDefaults() throws -> (UserDefaults, String) {
        let name = "AtriaStrainTargetMintAuthorityTests.\(UUID().uuidString)"
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
                          confidence: Metrics.RecoveryEstimate.Confidence) -> Metrics.RecoveryEstimate {
        Metrics.RecoveryEstimate(percent: percent,
                                 confidence: confidence,
                                 usesHRV: true,
                                 detail: "fixture",
                                 contributors: [])
    }

    // MARK: - Fix 1: scheduler nil attribution preserves, never erases

    func testSchedulerShapedNilRecoveryPreservesStoredSnapshot() throws {
        let (defaults, name) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let calendar = gmtCalendar

        let minted = try XCTUnwrap(AtriaDailyStrainTargetStore.resolve(
            recovery: 64,
            load: .learning,
            recoveryIsAttributedToCurrentDay: true,
            loadIsPrepared: true,
            mutationAuthority: .canonical,
            cycleStart: wake,
            now: wake.addingTimeInterval(60),
            calendar: calendar,
            defaults: defaults
        ))

        // The scheduler's shape when attribution resolves to nil: authority is
        // .preserveExisting (never the delete branch). The stored target must
        // survive and still be readable.
        let preserved = AtriaDailyStrainTargetStore.resolve(
            recovery: nil,
            load: .learning,
            recoveryIsAttributedToCurrentDay: false,
            loadIsPrepared: false,
            mutationAuthority: .preserveExisting,
            cycleStart: wake,
            now: wake.addingTimeInterval(300),
            calendar: calendar,
            defaults: defaults
        )
        XCTAssertEqual(preserved, minted,
                       "nil attribution must read the same-cycle target, not erase it")
        XCTAssertEqual(AtriaDailyStrainTargetStore.loadSnapshot(defaults: defaults), minted,
                       "the durable snapshot must survive a nil-attribution scheduler pass")
    }

    // MARK: - Fix 1: unverified tiers cannot mint via either writer shape

    func testUnverifiedTierCannotMintViaEitherWriterShape() throws {
        XCTAssertEqual(AtriaDailyStrainTargetStore.mintAuthority(recoveryConfidence: .learning),
                       .preserveExisting)
        XCTAssertEqual(AtriaDailyStrainTargetStore.mintAuthority(recoveryConfidence: .unverified),
                       .preserveExisting)
        XCTAssertEqual(AtriaDailyStrainTargetStore.mintAuthority(recoveryConfidence: .personalBaseline),
                       .canonical)
        XCTAssertEqual(AtriaDailyStrainTargetStore.mintAuthority(recoveryConfidence: .validated),
                       .canonical)
        XCTAssertEqual(AtriaDailyStrainTargetStore.mintAuthority(recoveryConfidence: nil),
                       .preserveExisting)

        for tier in [Metrics.RecoveryEstimate.Confidence.learning, .unverified] {
            // Scheduler shape: numeric attributed recovery, confidence-gated
            // authority.
            let (schedulerDefaults, schedulerName) = try isolatedDefaults()
            defer { schedulerDefaults.removePersistentDomain(forName: schedulerName) }
            XCTAssertNil(AtriaDailyStrainTargetStore.resolve(
                recovery: 55,
                load: .learning,
                recoveryIsAttributedToCurrentDay: true,
                loadIsPrepared: true,
                mutationAuthority: AtriaDailyStrainTargetStore.mintAuthority(recoveryConfidence: tier),
                cycleStart: wake,
                now: wake.addingTimeInterval(60),
                calendar: gmtCalendar,
                defaults: schedulerDefaults
            ), "\(tier) must not mint via the scheduler shape")
            XCTAssertNil(AtriaDailyStrainTargetStore.loadSnapshot(defaults: schedulerDefaults),
                         "\(tier) must leave no durable snapshot behind")

            // Home shape: the gate strips the percent first, so the recovery
            // argument itself is nil and authority is .preserveExisting.
            let (homeDefaults, homeName) = try isolatedDefaults()
            defer { homeDefaults.removePersistentDomain(forName: homeName) }
            let authorized = AtriaHomeModel.recoveryAuthorizedForStrainTarget(
                estimate(percent: 55, confidence: tier)
            )
            XCTAssertNil(authorized, "\(tier) must not pass Home's gate")
            XCTAssertNil(AtriaDailyStrainTargetStore.resolve(
                recovery: authorized,
                load: .learning,
                recoveryIsAttributedToCurrentDay: false,
                loadIsPrepared: true,
                mutationAuthority: authorized == nil ? .preserveExisting : .canonical,
                cycleStart: wake,
                now: wake.addingTimeInterval(60),
                calendar: gmtCalendar,
                defaults: homeDefaults
            ), "\(tier) must not mint via the Home shape")
            XCTAssertNil(AtriaDailyStrainTargetStore.loadSnapshot(defaults: homeDefaults))
        }
    }

    // MARK: - Fix 1: shared-helper drift pin (Home vs scheduler)

    func testHomeGateAndSharedMintAuthorityCannotDrift() throws {
        // Behavioral equivalence: for every Recovery tier, Home's writer gate
        // authorizes a durable write exactly when the shared helper grants
        // canonical authority.
        let tiers: [Metrics.RecoveryEstimate.Confidence] = [
            .learning, .unverified, .personalBaseline, .validated
        ]
        for tier in tiers {
            let homeAuthorizes = AtriaHomeModel.recoveryAuthorizedForStrainTarget(
                estimate(percent: 60, confidence: tier)
            ) != nil
            let sharedAuthorizes = AtriaDailyStrainTargetStore.mintAuthority(
                recoveryConfidence: tier
            ) == .canonical
            XCTAssertEqual(homeAuthorizes, sharedAuthorizes,
                           "one honesty standard: Home and the shared helper disagree on \(tier)")
        }

        // Source pin: both writers must keep deriving mutation authority from
        // the nil-preserving ternary, and the scheduler from the shared
        // helper. Editing either site requires consciously revisiting W1-C.
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let schedulerSource = try String(
            contentsOf: sourceRoot.appendingPathComponent("Atria/LocalNotificationScheduler.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(schedulerSource.contains("AtriaDailyStrainTargetStore.mintAuthority("),
                      "the scheduler must derive mint authority from the shared helper")
        XCTAssertTrue(schedulerSource.contains("mutationAuthority: attributedRecovery == nil"),
                      "the scheduler must preserve (never erase) on nil attribution")
        XCTAssertTrue(schedulerSource.contains("? .preserveExisting"))

        let homeSource = try String(
            contentsOf: sourceRoot.appendingPathComponent("Atria/AtriaHomeView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(homeSource.contains("recoveryAuthorizedForStrainTarget"),
                      "Home's writer gate must exist")
        XCTAssertTrue(homeSource.contains("estimate.confidence == .personalBaseline"),
                      "Home's gate must keep the canonical-tier standard the shared helper mirrors")
        XCTAssertTrue(homeSource.contains("|| estimate.confidence == .validated"),
                      "Home's gate must keep the canonical-tier standard the shared helper mirrors")
        XCTAssertTrue(homeSource.contains("mutationAuthority: strainTargetRecovery == nil"),
                      "Home must preserve (never erase) when its gate strips authority")
    }

    // MARK: - Fix 3: learning-load mint upgrades exactly once

    func testLearningLoadMintUpgradesExactlyOnce() throws {
        let (defaults, name) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let calendar = gmtCalendar
        let preparedLoad = TrainingLoadSummary(acuteLoad: 14,
                                               chronicLoad: 10,
                                               ratio: 1.4,
                                               monotony: 1.1,
                                               confidence: "local",
                                               readiness: "strained",
                                               acwrSignal: "bad",
                                               monotonySignal: "good",
                                               targetBand: nil,
                                               detail: "fixture")

        let learningMint = try XCTUnwrap(AtriaDailyStrainTargetStore.resolve(
            recovery: 50,
            load: .learning,
            recoveryIsAttributedToCurrentDay: true,
            loadIsPrepared: true,
            mutationAuthority: .canonical,
            cycleStart: wake,
            now: wake.addingTimeInterval(60),
            calendar: calendar,
            defaults: defaults
        ))
        XCTAssertEqual(learningMint.target, 13, accuracy: 0.0001)
        XCTAssertEqual(learningMint.loadProvenance, "load_learning_at_mint")

        // A preserve-authority reader with the prepared load may NOT perform
        // the upgrade — the durable write stays canonical-only.
        let readOnly = AtriaDailyStrainTargetStore.resolve(
            recovery: nil,
            load: preparedLoad,
            recoveryIsAttributedToCurrentDay: false,
            loadIsPrepared: true,
            mutationAuthority: .preserveExisting,
            cycleStart: wake,
            now: wake.addingTimeInterval(120),
            calendar: calendar,
            defaults: defaults
        )
        XCTAssertEqual(readOnly, learningMint,
                       "a preserve-authority caller must not upgrade the mint")
        XCTAssertEqual(AtriaDailyStrainTargetStore.loadSnapshot(defaults: defaults)?.loadProvenance,
                       "load_learning_at_mint")

        // Canonical caller with the prepared load: single re-mint to
        // target - 2, disclosed provenance carrying the learning history.
        let upgraded = try XCTUnwrap(AtriaDailyStrainTargetStore.resolve(
            recovery: 50,
            load: preparedLoad,
            recoveryIsAttributedToCurrentDay: true,
            loadIsPrepared: true,
            mutationAuthority: .canonical,
            cycleStart: wake,
            now: wake.addingTimeInterval(3_600),
            calendar: calendar,
            defaults: defaults
        ))
        XCTAssertEqual(upgraded.target, 11, accuracy: 0.0001)
        XCTAssertEqual(upgraded.loadAdjustment, -2, accuracy: 0.0001)
        XCTAssertEqual(upgraded.loadProvenance, "load_high_upgraded_from_learning")
        XCTAssertEqual(upgraded.recovery, learningMint.recovery)
        XCTAssertEqual(upgraded.day, learningMint.day)

        // Third resolve is a no-op: same snapshot, same createdAt — no churn.
        let third = try XCTUnwrap(AtriaDailyStrainTargetStore.resolve(
            recovery: 50,
            load: preparedLoad,
            recoveryIsAttributedToCurrentDay: true,
            loadIsPrepared: true,
            mutationAuthority: .canonical,
            cycleStart: wake,
            now: wake.addingTimeInterval(7_200),
            calendar: calendar,
            defaults: defaults
        ))
        XCTAssertEqual(third, upgraded, "the upgrade fires at most once per cycle")
        XCTAssertEqual(third.createdAt, upgraded.createdAt,
                       "a no-op resolve must not rewrite the snapshot")
    }

    // MARK: - Fix 4: stale blob relocated, not returned, not silently deleted

    func testStaleBlobIsRelocatedToAuditKeyNotReturnedNotDeleted() throws {
        let (defaults, name) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let calendar = gmtCalendar

        let staleMint = try XCTUnwrap(AtriaDailyStrainTargetStore.resolve(
            recovery: 60,
            load: .learning,
            recoveryIsAttributedToCurrentDay: true,
            loadIsPrepared: true,
            mutationAuthority: .canonical,
            cycleStart: wake,
            now: wake.addingTimeInterval(60),
            calendar: calendar,
            defaults: defaults
        ))
        let staleBytes = try XCTUnwrap(defaults.data(
            forKey: AtriaDailyStrainTargetStore.storageKey
        ))

        // Twenty cycles later (the device's July-22 blob shape), even a
        // read-only resolve relocates the blob to the audit slot.
        let currentWake = wake.addingTimeInterval(20 * 24 * 3_600)
        XCTAssertNil(AtriaDailyStrainTargetStore.resolve(
            recovery: nil,
            load: .learning,
            recoveryIsAttributedToCurrentDay: false,
            loadIsPrepared: false,
            mutationAuthority: .preserveExisting,
            cycleStart: currentWake,
            now: currentWake.addingTimeInterval(60),
            calendar: calendar,
            defaults: defaults
        ), "a stale blob must never be returned")

        XCTAssertNil(defaults.data(forKey: AtriaDailyStrainTargetStore.storageKey),
                     "the live slot must be emptied")
        let auditBytes = try XCTUnwrap(defaults.data(
            forKey: AtriaDailyStrainTargetStore.auditStorageKey
        ), "the blob must be relocated, never silently deleted")
        XCTAssertEqual(auditBytes, staleBytes,
                       "the audit slot must keep the evidence byte-for-byte")
        let audited = try JSONDecoder().decode(AtriaFrozenDailyStrainTarget.self,
                                               from: auditBytes)
        XCTAssertEqual(audited, staleMint)

        // A later canonical mint fills the live slot without touching the
        // audit evidence — no delete-then-mint churn of history.
        let fresh = try XCTUnwrap(AtriaDailyStrainTargetStore.resolve(
            recovery: 70,
            load: .learning,
            recoveryIsAttributedToCurrentDay: true,
            loadIsPrepared: true,
            mutationAuthority: .canonical,
            cycleStart: currentWake,
            now: currentWake.addingTimeInterval(120),
            calendar: calendar,
            defaults: defaults
        ))
        XCTAssertEqual(fresh.day, currentWake)
        XCTAssertEqual(defaults.data(forKey: AtriaDailyStrainTargetStore.auditStorageKey),
                       staleBytes,
                       "a fresh mint must not disturb the relocated evidence")
    }

    func testPreviousCycleBlobIsNotRelocated() throws {
        let (defaults, name) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let calendar = gmtCalendar

        _ = try XCTUnwrap(AtriaDailyStrainTargetStore.resolve(
            recovery: 60,
            load: .learning,
            recoveryIsAttributedToCurrentDay: true,
            loadIsPrepared: true,
            mutationAuthority: .canonical,
            cycleStart: wake,
            now: wake.addingTimeInterval(60),
            calendar: calendar,
            defaults: defaults
        ))

        // Exactly one cycle old: within the one-full-cycle grace, the blob
        // stays in the live slot for the normal mint path to replace — no
        // relocation churn at every ordinary day flip.
        let nextWake = wake.addingTimeInterval(24 * 3_600)
        XCTAssertNil(AtriaDailyStrainTargetStore.resolve(
            recovery: nil,
            load: .learning,
            recoveryIsAttributedToCurrentDay: false,
            loadIsPrepared: false,
            mutationAuthority: .preserveExisting,
            cycleStart: nextWake,
            now: nextWake.addingTimeInterval(60),
            calendar: calendar,
            defaults: defaults
        ), "a previous-cycle target is not the current cycle's answer")
        XCTAssertNotNil(defaults.data(forKey: AtriaDailyStrainTargetStore.storageKey),
                        "the previous cycle's blob stays live for the mint path to replace")
        XCTAssertNil(defaults.data(forKey: AtriaDailyStrainTargetStore.auditStorageKey))
    }
}
