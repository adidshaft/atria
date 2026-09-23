import XCTest
@testable import Atria

/// Handoff-11: when the bounded latest-night compact-motion read is
/// incomplete for a review-eligible reason, sufficiently strong resident
/// HR/RR evidence must produce exactly one durable, explicitly HR-only
/// review candidate — and that candidate must be structurally unable to
/// reach canonical sleep, auto-confirmation or Recovery.
final class AtriaDegradedSleepReviewTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName = ""

    override func setUpWithError() throws {
        suiteName = "AtriaDegradedSleepReviewTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = ""
    }

    // MARK: - Checkpoint 2: motion-failure classification

    func testReviewEligibilityClassifiesEveryReadFailureExplicitly() {
        // Missing or cap-bounded reads leave the resident HR/RR evidence
        // intact: motion could not be VERIFIED, which is not "absent".
        for eligible in [
            AtriaWhoop4MotionTickCompactStore.LatestNightReadFailure
                .missingShard,
            .shardCapExceeded,
            .byteCapExceeded,
            .rowCapExceeded,
        ] {
            XCTAssertTrue(
                SessionStore.compactMotionFailurePermitsHRRRReview(eligible),
                "\(eligible.rawValue) must enter the review-only lane"
            )
        }
        // Identity, integrity, thermal and deadline failures impugn the read
        // itself or the system state; the whole settlement stays withheld.
        for vetoed in [
            AtriaWhoop4MotionTickCompactStore.LatestNightReadFailure
                .invalidRequest,
            .thermalCritical,
            .integrityFailure,
            .deadlineExceeded,
            .sourceChanged,
        ] {
            XCTAssertFalse(
                SessionStore.compactMotionFailurePermitsHRRRReview(vetoed),
                "\(vetoed.rawValue) must veto the review-only lane"
            )
        }
    }

    // MARK: - Checkpoints 1+3: three-outcome preparation

    func testMissingShardWithStrongHRRRYieldsReviewOnly() async throws {
        let fixture = try makeDegradedFixture()
        defer { fixture.cleanUp() }
        let result = await prepare(fixture: fixture)
        guard case .reviewOnly(let review) = result else {
            return XCTFail("expected reviewOnly, got \(result)")
        }
        XCTAssertEqual(review.motionBlocker, .missingShard)
        XCTAssertFalse(review.night.confirmed,
                       "a degraded candidate is never born confirmed")
        XCTAssertNotEqual(review.night.motionValidated, true,
                          "motion cannot be claimed validated when unread")
        XCTAssertEqual(
            review.sourceStrapIdentifier.uuidString,
            fixture.strapIdentifier.uppercased()
        )
        XCTAssertGreaterThan(review.heartRateRows, 0)
        XCTAssertTrue(
            review.evidenceFingerprint.hasPrefix("v1|"),
            "fingerprint must carry its schema"
        )
        XCTAssertTrue(
            review.evidenceFingerprint.contains("blk:missing_shard"),
            "fingerprint must name the exact blocker"
        )
    }

    func testIdenticalEvidenceRepreparationKeepsTheSameFingerprint()
        async throws
    {
        let fixture = try makeDegradedFixture()
        defer { fixture.cleanUp() }
        let first = await prepare(fixture: fixture)
        let second = await prepare(fixture: fixture)
        guard case .reviewOnly(let a) = first,
              case .reviewOnly(let b) = second else {
            return XCTFail("both preparations must be reviewOnly")
        }
        XCTAssertEqual(
            a.evidenceFingerprint,
            b.evidenceFingerprint,
            "durable identity must not depend on process-local state"
        )
    }

    func testMissingContextPreservesPreH11Withhold() async throws {
        let fixture = try makeDegradedFixture()
        defer { fixture.cleanUp() }
        let result = await prepare(fixture: fixture, withContext: false)
        guard case .withheld(let failure) = result else {
            return XCTFail("expected withheld, got \(result)")
        }
        XCTAssertEqual(failure, .compactMotion(.missingShard))
    }

    func testIneligibleFailureStaysWithheldEvenWithContext() throws {
        let now = Date()
        let slice = try SessionStore.compactLatestNightSessionSlice(
            from: [denseNight(endingAt: now.addingTimeInterval(-45 * 60))],
            now: now,
            deadlineUptimeNanoseconds:
                DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        ).get()
        for vetoed in [
            AtriaWhoop4MotionTickCompactStore.LatestNightReadFailure
                .integrityFailure,
            .sourceChanged,
            .deadlineExceeded,
        ] {
            let result = SessionStore
                .makeCompactLatestNightDegradedReviewPreparation(
                    motionFailure: vetoed,
                    slice: slice,
                    degradedReviewContext: makeContext(),
                    activeJournalSession: nil,
                    now: now,
                    rest: 60,
                    maxHR: 190,
                    sourceStrapIdentifier: UUID(),
                    cooperativeDeadline: .init(
                        uptimeNanoseconds: .max,
                        monotonicNow: { 0 }
                    )
                )
            guard case .withheld(let failure) = result else {
                return XCTFail("\(vetoed.rawValue) must stay withheld")
            }
            XCTAssertEqual(failure, .compactMotion(vetoed))
        }
    }

    func testWeakEvidenceYieldsTheNamedNotQualifiedTerminal() async throws {
        // A 24-minute low-HR fragment is below the 30-minute HR-only nap
        // review floor and far below the HR-only sleep tiers: eligible
        // failure, consulted evidence, no candidate — and the outcome must
        // say exactly that. (A 30-minute fragment now legitimately surfaces
        // as a review-only HR-only nap since the 2026-08-29 clock-agnostic
        // nap fix, so this terminal is exercised just under that floor.)
        let fixture = try makeDegradedFixture(nightHours: 0.4)
        defer { fixture.cleanUp() }
        let result = await prepare(fixture: fixture)
        guard case .withheld(let failure) = result else {
            return XCTFail("expected withheld, got \(result)")
        }
        XCTAssertEqual(failure, .hrRRReviewNotQualified(.missingShard))
    }

    func testConfirmedNightSuppressesTheDegradedCandidate() async throws {
        let fixture = try makeDegradedFixture()
        defer { fixture.cleanUp() }
        let night = fixture.night
        let confirmed = makeConfirmedSleep(
            start: night.start,
            end: night.end
        )
        let result = await prepare(
            fixture: fixture,
            confirmedSleeps: [confirmed]
        )
        guard case .withheld(let failure) = result else {
            return XCTFail("expected withheld, got \(result)")
        }
        XCTAssertEqual(
            failure,
            .hrRRReviewNotQualified(.missingShard),
            "user-confirmed truth outranks any degraded candidate"
        )
    }

    // MARK: - Checkpoint 4/5: durable persistence, dedupe, precedence

    func testSaveDegradedReviewPersistsProvenanceAndReloads() throws {
        let now = Date()
        let night = makeStoredNight(now: now)
        let outcome = AtriaPendingSleepReviewStore.saveDegradedReview(
            night,
            motionBlocker: "missing_shard",
            evidenceFingerprint: "v1|test|fingerprint",
            sourceStrapIdentifier: "STRAP-A",
            now: now,
            defaults: defaults
        )
        XCTAssertEqual(outcome, .saved)
        let restored = AtriaPendingSleepReviewStore.load(
            now: now.addingTimeInterval(60),
            confirmedSleeps: [],
            dismissedCandidates: [],
            defaults: defaults
        )
        XCTAssertEqual(restored, night)
        let raw = try XCTUnwrap(
            defaults.data(forKey: "atria.sleepReview.pendingReceipt.v1")
        )
        let payload = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: raw) as? [String: Any]
        )
        XCTAssertEqual(payload["motionBlocker"] as? String, "missing_shard")
        XCTAssertEqual(
            payload["evidenceFingerprint"] as? String,
            "v1|test|fingerprint"
        )
        XCTAssertEqual(payload["sourceStrapIdentifier"] as? String, "STRAP-A")
    }

    func testIdenticalFingerprintDeduplicatesWithoutRewriting() throws {
        let now = Date()
        let night = makeStoredNight(now: now)
        XCTAssertEqual(
            AtriaPendingSleepReviewStore.saveDegradedReview(
                night,
                motionBlocker: "missing_shard",
                evidenceFingerprint: "v1|same",
                sourceStrapIdentifier: nil,
                now: now,
                defaults: defaults
            ),
            .saved
        )
        let firstWrite = defaults.data(
            forKey: "atria.sleepReview.pendingReceipt.v1"
        )
        XCTAssertEqual(
            AtriaPendingSleepReviewStore.saveDegradedReview(
                night,
                motionBlocker: "missing_shard",
                evidenceFingerprint: "v1|same",
                sourceStrapIdentifier: nil,
                now: now.addingTimeInterval(600),
                defaults: defaults
            ),
            .deduplicated
        )
        XCTAssertEqual(
            defaults.data(forKey: "atria.sleepReview.pendingReceipt.v1"),
            firstWrite,
            "a dedupe must leave the stored record byte-identical"
        )
    }

    func testDegradedRecordNeverReplacesMotionValidatedRecord() throws {
        let now = Date()
        let validated = makeStoredNight(now: now, motionValidated: true)
        AtriaPendingSleepReviewStore.save(
            validated,
            now: now,
            defaults: defaults
        )
        let degraded = makeStoredNight(now: now, id: "degraded-clone")
        XCTAssertEqual(
            AtriaPendingSleepReviewStore.saveDegradedReview(
                degraded,
                motionBlocker: "byte_cap_exceeded",
                evidenceFingerprint: "v1|weaker",
                sourceStrapIdentifier: nil,
                now: now,
                defaults: defaults
            ),
            .keptMotionValidated
        )
        let restored = AtriaPendingSleepReviewStore.load(
            now: now,
            confirmedSleeps: [],
            dismissedCandidates: [],
            defaults: defaults
        )
        XCTAssertEqual(restored?.id, validated.id,
                       "weaker provenance must not erase stronger")
    }

    func testMotionValidatedUpgradeReplacesDegradedRecord() throws {
        let now = Date()
        let degraded = makeStoredNight(now: now, id: "degraded-first")
        XCTAssertEqual(
            AtriaPendingSleepReviewStore.saveDegradedReview(
                degraded,
                motionBlocker: "missing_shard",
                evidenceFingerprint: "v1|first",
                sourceStrapIdentifier: nil,
                now: now,
                defaults: defaults
            ),
            .saved
        )
        let validated = makeStoredNight(
            now: now,
            id: "validated-later",
            motionValidated: true
        )
        AtriaPendingSleepReviewStore.save(
            validated,
            now: now,
            defaults: defaults
        )
        let restored = AtriaPendingSleepReviewStore.load(
            now: now,
            confirmedSleeps: [],
            dismissedCandidates: [],
            defaults: defaults
        )
        XCTAssertEqual(restored?.id, validated.id,
                       "a later motion-validated candidate enriches in place")
    }

    func testRepairingTheStrapInvalidatesTheStoredReview() throws {
        let now = Date()
        let night = makeStoredNight(now: now)
        XCTAssertEqual(
            AtriaPendingSleepReviewStore.saveDegradedReview(
                night,
                motionBlocker: "missing_shard",
                evidenceFingerprint: "v1|strap",
                sourceStrapIdentifier: "STRAP-A",
                now: now,
                defaults: defaults
            ),
            .saved
        )
        XCTAssertNil(
            AtriaPendingSleepReviewStore.load(
                now: now,
                confirmedSleeps: [],
                dismissedCandidates: [],
                currentStrapIdentifier: "STRAP-B",
                defaults: defaults
            ),
            "a re-paired strap must invalidate the stale claim"
        )
        XCTAssertNotNil(
            AtriaPendingSleepReviewStore.load(
                now: now,
                confirmedSleeps: [],
                dismissedCandidates: [],
                currentStrapIdentifier: "strap-a",
                defaults: defaults
            ),
            "the recording strap still owns its review, case-insensitively"
        )
        XCTAssertNotNil(
            AtriaPendingSleepReviewStore.load(
                now: now,
                confirmedSleeps: [],
                dismissedCandidates: [],
                defaults: defaults
            ),
            "callers without the identity keep the previous behavior"
        )
    }

    func testUserConfirmationStillOutranksTheDegradedRecord() throws {
        let now = Date()
        let night = makeStoredNight(now: now)
        XCTAssertEqual(
            AtriaPendingSleepReviewStore.saveDegradedReview(
                night,
                motionBlocker: "missing_shard",
                evidenceFingerprint: "v1|conf",
                sourceStrapIdentifier: nil,
                now: now,
                defaults: defaults
            ),
            .saved
        )
        let confirmed = makeConfirmedSleep(
            start: night.start,
            end: night.end
        )
        XCTAssertNil(
            AtriaPendingSleepReviewStore.load(
                now: now,
                confirmedSleeps: [confirmed],
                dismissedCandidates: [],
                defaults: defaults
            ),
            "user precedence always wins at load"
        )
    }

    // MARK: - Diagnostic receipt

    func testDiagnosticReceiptRecordsTheLatestAttempt() throws {
        let preparedAt = Date(timeIntervalSince1970: 1_786_600_000)
        SessionStore.recordDegradedSleepReviewDiagnostic(
            preparedAt: preparedAt,
            motionBlocker: "missing_shard",
            reviewEligible: true,
            reviewQualified: true,
            persistence: "saved",
            fingerprint: "v1|receipt",
            source: "unit_test",
            defaults: defaults
        )
        let raw = try XCTUnwrap(defaults.data(
            forKey: "atria.debug.sleepCompactReviewReceipt.v1"
        ))
        let payload = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: raw) as? [String: Any]
        )
        XCTAssertEqual(payload["motionBlocker"] as? String, "missing_shard")
        XCTAssertEqual(payload["reviewEligible"] as? Bool, true)
        XCTAssertEqual(payload["reviewQualified"] as? Bool, true)
        XCTAssertEqual(payload["persistence"] as? String, "saved")
        XCTAssertEqual(payload["fingerprint"] as? String, "v1|receipt")
        XCTAssertEqual(
            payload["preparedAtUnix"] as? TimeInterval,
            1_786_600_000
        )
        XCTAssertEqual(
            payload["canonicalCommitBlocked"] as? Bool,
            true,
            "the receipt must assert the canonical fence"
        )
    }

    // MARK: - Checkpoint 6: structural canonical-commit fence

    func testDegradedLaneSourceContainsNoCanonicalCommitPath() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/Sessions.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        // The degraded builder and the persistence completion are the only
        // code that can act on a review-only value. Neither region may mint,
        // consume or exercise canonical commit machinery, publish to widgets
        // or HealthKit, or raise a sleep-logged notification.
        let regions: [(start: String, end: String)] = [
            ("nonisolated static func makeCompactLatestNightDegradedReviewPreparation(",
             "nonisolated static func foregroundSleepEvaluationSessions("),
            ("private func persistCompactLatestNightDegradedReview(",
             "nonisolated static func recordDegradedSleepReviewDiagnostic("),
        ]
        for region in regions {
            let start = try XCTUnwrap(
                source.range(of: region.start),
                "missing region start \(region.start)"
            )
            let end = try XCTUnwrap(
                source.range(of: region.end,
                             range: start.upperBound..<source.endIndex),
                "missing region end \(region.end)"
            )
            let body = String(source[start.lowerBound..<end.lowerBound])
            for forbidden in [
                "mintLatestNightCommitAuthority",
                "consumeLatestNightCommitAuthority",
                "LatestNightCommitAuthority",
                "autoConfirmStrongSleepCandidates",
                "commitPreparedWakeBoundarySleepIfUseful",
                "saveConfirmedSleeps",
                "confirmSleepCandidate",
                "HealthKit",
                "WidgetCenter",
                "UNUserNotificationCenter",
            ] {
                XCTAssertFalse(
                    body.contains(forbidden),
                    "\(region.start) must not reach \(forbidden)"
                )
            }
        }
        // The review-only carrier itself must stay free of commit machinery:
        // no compact receipt and no commit authority means the canonical
        // commit path cannot even be expressed against it.
        let carrierStart = try XCTUnwrap(source.range(
            of: "struct CompactLatestNightDegradedReviewProposal"
        ))
        let carrierEnd = try XCTUnwrap(source.range(
            of: "enum CompactLatestNightSettlementPreparation",
            range: carrierStart.upperBound..<source.endIndex
        ))
        let carrier = String(
            source[carrierStart.lowerBound..<carrierEnd.lowerBound]
        )
        XCTAssertFalse(carrier.contains("commitAuthority"))
        XCTAssertFalse(carrier.contains("compactReceipt"))
        XCTAssertFalse(carrier.contains("ForegroundSleepSettlementProposal"))
    }

    // MARK: - Fixtures

    private struct DegradedFixture {
        let night: SavedSession
        let now: Date
        let strapIdentifier: String
        let compactStore: AtriaWhoop4MotionTickCompactStore
        let directory: URL

        func cleanUp() {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// A real (empty) compact store on disk: the latest-night read fails with
    /// `.missingShard` exactly as it does on a device whose motion shards
    /// have not arrived — the incident class this handoff exists for.
    private func makeDegradedFixture(
        nightHours: Double = 6
    ) throws -> DegradedFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AtriaDegradedSleepReviewTests-\(UUID().uuidString)"
            )
        let store = AtriaWhoop4MotionTickCompactStore(
            directoryURL: directory
        )
        let now = Date()
        return DegradedFixture(
            night: denseNight(
                endingAt: now.addingTimeInterval(-45 * 60),
                hours: nightHours
            ),
            now: now,
            strapIdentifier: UUID().uuidString,
            compactStore: store,
            directory: directory
        )
    }

    private func prepare(
        fixture: DegradedFixture,
        withContext: Bool = true,
        confirmedSleeps: [UserConfirmedSleep] = []
    ) async -> SessionStore.CompactLatestNightSettlementPreparation {
        let context = withContext
            ? makeContext(confirmedSleeps: confirmedSleeps)
            : nil
        let fingerprint = makeFingerprint()
        let night = fixture.night
        let now = fixture.now
        let strap = fixture.strapIdentifier
        let store = fixture.compactStore
        return await Task.detached(priority: .utility) {
            SessionStore.makeCompactLatestNightSettlementPreparation(
                fingerprint: fingerprint,
                canonicalSessions: [night],
                now: now,
                rest: 60,
                maxHR: 190,
                learnedWindow: nil,
                strapIdentifier: strap,
                thermalState: .nominal,
                compactStore: store,
                degradedReviewContext: context
            )
        }.value
    }

    private func makeContext(
        confirmedSleeps: [UserConfirmedSleep] = []
    ) -> SessionStore.CompactLatestNightReviewContext {
        .init(
            snapshot: .empty,
            confirmedSleeps: confirmedSleeps,
            dismissedCandidates: [],
            calendar: .current
        )
    }

    private func denseNight(
        endingAt end: Date,
        hours: Double = 6
    ) -> SavedSession {
        let duration = hours * 60 * 60
        let start = end.addingTimeInterval(-duration)
        var session = SavedSession(
            id: UUID(),
            start: start,
            end: end,
            label: "Dense HR-only night",
            points: stride(from: 0.0, through: duration, by: 1.0).map {
                .init(t: $0, bpm: 52 + ((Int($0) / 300) % 3))
            }
        )
        // The dense-long HR-only review tier demands ≥0.60 HR AND RR sample
        // coverage with tight accepted-gap ceilings; 1 Hz for both clears it.
        session.rrPoints = stride(from: 0.0, through: duration, by: 1.0).map {
            .init(t: $0, ms: 1_020, source: .standardHeartRateMeasurement2A37)
        }
        return session
    }

    private func makeStoredNight(
        now: Date,
        id: String = "degraded-review-test",
        motionValidated: Bool? = nil
    ) -> SleepHistorySnapshot.Night {
        let end = now.addingTimeInterval(-60 * 60)
        let start = end.addingTimeInterval(-6 * 60 * 60)
        return .init(
            id: id,
            day: end,
            start: start,
            end: end,
            duration: 6 * 60 * 60,
            restingHR: 55,
            hrv: nil,
            hrvWindowCount: 0,
            respiratoryRate: 14.8,
            sleepEfficiency: 0.9,
            confidence: "review_needed",
            source: "aggregate_sleep",
            confirmed: false,
            stageSegments: [],
            motionValidated: motionValidated
        )
    }

    private func makeConfirmedSleep(
        start: Date?,
        end: Date?
    ) -> UserConfirmedSleep {
        let resolvedEnd = end ?? Date()
        let resolvedStart = start
            ?? resolvedEnd.addingTimeInterval(-6 * 60 * 60)
        return UserConfirmedSleep(
            id: "confirmed-degraded-test",
            createdAt: resolvedEnd,
            start: resolvedStart,
            end: resolvedEnd,
            source: "user_confirmed_sleep",
            confidence: "user_confirmed_sleep",
            sessions: 1,
            samples: 300,
            avgHR: 60,
            peakHR: 72,
            restingHR: 55,
            hrv: nil,
            hrvWindowCount: nil,
            respiratoryRate: nil,
            duration: resolvedEnd.timeIntervalSince(resolvedStart),
            span: resolvedEnd.timeIntervalSince(resolvedStart),
            reason: "test",
            motionSource: "strap",
            motionValidated: true,
            stageSegments: nil,
            eventTimeZoneIdentifier: nil
        )
    }

    private func makeFingerprint()
        -> SessionStore.ForegroundSleepSettlementFingerprint {
        .init(
            canonicalSessionsRevision: 1,
            confirmedSleepsRevision: 1,
            restingHR: 60,
            baselineRestingIsTrusted: true,
            baselineRestingIsNearTrusted: true,
            maxHR: 190
        )
    }
}
