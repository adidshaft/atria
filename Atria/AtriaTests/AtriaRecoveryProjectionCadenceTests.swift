import XCTest
@testable import Atria

@MainActor
final class AtriaRecoveryProjectionCadenceTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 2_000_000_000)

    func testUnchangedProjectionHitsFourHourCacheWithoutEvaluatingAutoclosure() {
        var cache = SessionStore.RecoveryProjectionCache()
        var evaluations = 0
        let cycle = makeCycle(start: start)
        let fingerprint = SessionStore.RecoveryProjectionFingerprint(fallbackRMSSD: 62,
                                                                      restingHeartRate: 51,
                                                                      sleepID: "night")
        func evaluate(_ percent: Int) -> Metrics.RecoveryEstimate {
            evaluations += 1
            return estimate(percent)
        }

        let first = cache.resolve(frozen: nil,
                                  cycle: cycle,
                                  fingerprint: fingerprint,
                                  now: start,
                                  ttl: SessionStore.provisionalRecoveryProjectionTTL,
                                  provisional: evaluate(64))
        let second = cache.resolve(frozen: nil,
                                   cycle: cycle,
                                   fingerprint: fingerprint,
                                   now: start.addingTimeInterval(3 * 60 * 60),
                                   ttl: SessionStore.provisionalRecoveryProjectionTTL,
                                   provisional: evaluate(12))

        XCTAssertEqual(first.percent, 64)
        XCTAssertEqual(second.percent, 64)
        XCTAssertEqual(evaluations, 1, "a cache hit must not evaluate Recovery v2")
    }

    func testFrozenPhysiologicalDayNeverEvaluatesProvisionalAutoclosure() {
        var cache = SessionStore.RecoveryProjectionCache()
        var evaluations = 0
        let frozen = estimate(81)
        func evaluate() -> Metrics.RecoveryEstimate {
            evaluations += 1
            return estimate(9)
        }

        let projected = cache.resolve(
            frozen: frozen,
            cycle: makeCycle(start: start),
            fingerprint: SessionStore.RecoveryProjectionFingerprint(),
            now: start,
            ttl: SessionStore.provisionalRecoveryProjectionTTL,
            provisional: evaluate()
        )

        XCTAssertEqual(projected, frozen)
        XCTAssertEqual(evaluations, 0, "frozen recovery must short-circuit Recovery v2")
        XCTAssertNil(cache.entry)
    }

    func testScorelessFrozenSummaryDoesNotSuppressMeasuredRecoveryProjection() {
        let scoreless = Metrics.RecoveryEstimate(
            percent: nil,
            confidence: .learning,
            usesHRV: false,
            detail: "legacy summary had no qualified HRV",
            contributors: []
        )
        let measuredSleep = Metrics.recoveryV2(
            hrvSnapshot: nil,
            fallbackRMSSD: nil,
            restingNow: nil,
            baseline: PersonalBaseline(),
            sleepEfficiency: 0.91,
            sleepDurationHours: 7.4
        )

        XCTAssertNil(SessionStore.numericFrozenRecovery(scoreless),
                     "a scoreless legacy summary is not an authoritative score")
        XCTAssertNotNil(measuredSleep.percent,
                        "measured sleep must keep a day-one recovery visible without HRV")
        XCTAssertEqual(measuredSleep.confidence, .unverified)
        XCTAssertFalse(measuredSleep.usesHRV)

        let numeric = estimate(73)
        XCTAssertEqual(SessionStore.numericFrozenRecovery(numeric), numeric,
                       "an actual frozen morning score must remain immutable")
    }

    func testMissingSleepPublishesLimitedEstimateInsteadOfBlankingDayOne() {
        var cache = SessionStore.RecoveryProjectionCache()
        var evaluations = 0
        func evaluate() -> Metrics.RecoveryEstimate {
            evaluations += 1
            return Metrics.RecoveryEstimate(percent: 99,
                                            confidence: .unverified,
                                            usesHRV: false,
                                            detail: "Limited estimate; sleep or HRV is still unavailable.",
                                            contributors: [])
        }
        let cycle = AtriaPhysiologicalCycle(start: start,
                                            boundaryKind: .noSleepFallback,
                                            anchorSleepID: "prior-night",
                                            expectedInterval: 24 * 60 * 60)

        let projected = cache.resolve(
            frozen: nil,
            cycle: cycle,
            fingerprint: SessionStore.RecoveryProjectionFingerprint(),
            now: start,
            ttl: SessionStore.provisionalRecoveryProjectionTTL,
            provisional: evaluate()
        )

        XCTAssertEqual(projected.percent, 99)
        XCTAssertEqual(projected.confidence, .unverified)
        XCTAssertFalse(projected.usesHRV)
        XCTAssertEqual(evaluations, 1)
    }

    func testChangedPhysiologyFingerprintRefreshesImmediately() {
        var cache = SessionStore.RecoveryProjectionCache()
        var evaluations = 0
        let firstFingerprint = SessionStore.RecoveryProjectionFingerprint(fallbackRMSSD: 55)
        let changedFingerprint = SessionStore.RecoveryProjectionFingerprint(fallbackRMSSD: 61)
        func evaluate() -> Metrics.RecoveryEstimate {
            evaluations += 1
            return estimate(40 + evaluations)
        }

        _ = cache.resolve(frozen: nil,
                          cycle: makeCycle(start: start),
                          fingerprint: firstFingerprint,
                          now: start,
                          ttl: SessionStore.provisionalRecoveryProjectionTTL,
                          provisional: evaluate())
        _ = cache.resolve(frozen: nil,
                          cycle: makeCycle(start: start),
                          fingerprint: changedFingerprint,
                          now: start.addingTimeInterval(60),
                          ttl: SessionStore.provisionalRecoveryProjectionTTL,
                          provisional: evaluate())
        _ = cache.resolve(frozen: nil,
                          cycle: makeCycle(start: start),
                          fingerprint: changedFingerprint,
                          now: start.addingTimeInterval(4 * 60 * 60 + 61),
                          ttl: SessionStore.provisionalRecoveryProjectionTTL,
                          provisional: evaluate())
        _ = cache.resolve(frozen: nil,
                          cycle: makeCycle(start: start.addingTimeInterval(24 * 60 * 60)),
                          fingerprint: changedFingerprint,
                          now: start.addingTimeInterval(24 * 60 * 60 + 1),
                          ttl: SessionStore.provisionalRecoveryProjectionTTL,
                          provisional: evaluate())

        XCTAssertEqual(evaluations, 4)
    }

    func testConfirmedSleepRevisionAndNewTrustedHRVRefreshImmediately() {
        var cache = SessionStore.RecoveryProjectionCache()
        var evaluations = 0
        func evaluate() -> Metrics.RecoveryEstimate {
            evaluations += 1
            return estimate(50 + evaluations)
        }
        let cycle = makeCycle(start: start)

        _ = cache.resolve(frozen: nil,
                          cycle: cycle,
                          fingerprint: .init(restingHeartRate: 60, sleepID: "night"),
                          confirmedSleepsRevision: 1,
                          now: start,
                          ttl: SessionStore.provisionalRecoveryProjectionTTL,
                          provisional: evaluate())
        _ = cache.resolve(frozen: nil,
                          cycle: cycle,
                          fingerprint: .init(restingHeartRate: 55, sleepID: "night"),
                          confirmedSleepsRevision: 2,
                          now: start.addingTimeInterval(60),
                          ttl: SessionStore.provisionalRecoveryProjectionTTL,
                          provisional: evaluate())
        _ = cache.resolve(frozen: nil,
                          cycle: cycle,
                          fingerprint: .init(fallbackRMSSD: 48,
                                             restingHeartRate: 55,
                                             sleepID: "night"),
                          confirmedSleepsRevision: 2,
                          now: start.addingTimeInterval(120),
                          ttl: SessionStore.provisionalRecoveryProjectionTTL,
                          provisional: evaluate())

        XCTAssertEqual(evaluations, 3)
    }

    func testRecoveryRHRRejectsTransportSentinelsAndUsesCanonicalDurableFallback() {
        let newestEmpty = SavedSession(
            id: UUID(),
            start: start.addingTimeInterval(600),
            end: start.addingTimeInterval(900),
            label: "empty transport row",
            points: []
        )
        let durable = SavedSession(
            id: UUID(),
            start: start,
            end: start.addingTimeInterval(300),
            label: "canonical wear",
            points: [
                .init(t: 0, bpm: 57),
                .init(t: 60, bpm: 59),
                .init(t: 120, bpm: 61)
            ]
        )

        XCTAssertEqual(SessionStore.recoveryRestingHeartRate(
            sleepRestingHeartRate: nil,
            liveRestingHeartRate: 0,
            canonicalSessions: [newestEmpty, durable]
        ), 57)
        XCTAssertEqual(SessionStore.recoveryRestingHeartRate(
            sleepRestingHeartRate: 49,
            liveRestingHeartRate: 88,
            canonicalSessions: [durable]
        ), 49, "the confirmed overnight RHR must own recovery")
        XCTAssertEqual(SessionStore.recoveryRestingHeartRate(
            sleepRestingHeartRate: nil,
            liveRestingHeartRate: 72,
            canonicalSessions: [durable]
        ), 72, "a plausible current live reading should precede saved fallback")
        XCTAssertNil(SessionStore.recoveryRestingHeartRate(
            sleepRestingHeartRate: nil,
            liveRestingHeartRate: 255,
            canonicalSessions: [newestEmpty]
        ))
    }

    func testRealPendingSleepReviewUnlocksDayOnePresentationRecovery() throws {
        let pending = pendingNight(end: start, duration: 4 * 60 * 60)
        let authoritative = Metrics.RecoveryEstimate(
            percent: nil,
            confidence: .learning,
            usesHRV: false,
            detail: "learning: need saved sleep",
            contributors: []
        )

        let projected = SessionStore.presentationRecoveryEstimate(
            authoritative: authoritative,
            hasConfirmedMainSleep: false,
            hasFrozenRecovery: false,
            pendingSleepReview: pending,
            baseline: PersonalBaseline(),
            respiratoryBaseline: nil,
            now: start.addingTimeInterval(60),
            physiologicalCycle: makeCycle(start: start)
        )

        XCTAssertNotNil(projected.percent)
        XCTAssertEqual(projected.confidence, .unverified)
        XCTAssertFalse(projected.usesHRV,
                       "an unqualified pending HRV integer must not become measured HRV")
        XCTAssertTrue(projected.detail.contains("pending sleep review"))
        XCTAssertNotEqual(projected, authoritative)
    }

    func testPendingSleepReviewNeverReplacesNumericRHROnlyDayOneEstimate() throws {
        let pending = pendingNight(end: start, duration: 4 * 60 * 60)
        let rhrOnlyNoSleep = Metrics.RecoveryEstimate(
            percent: 66,
            confidence: .unverified,
            usesHRV: false,
            // Migrated 2026-07-31 (device review): mirrors the production
            // plain-language limited-evidence detail.
            detail: "Limited confidence · sleep and HRV unavailable · from resting HR only — confirm a sleep to add HRV",
            contributors: [
                .init(kind: .hrv,
                      zScore: 0,
                      weight: 0,
                      detail: "HRV unavailable; excluded",
                      displayValue: "HRV unavailable"),
                .init(kind: .restingHeartRate,
                      zScore: 1.1,
                      weight: 0.2,
                      detail: "RHR 1.1σ",
                      displayValue: "Resting HR 61 bpm"),
                .init(kind: .sleep,
                      zScore: 0,
                      weight: 0,
                      detail: "Sleep unavailable; excluded",
                      displayValue: "Sleep unavailable")
            ]
        )

        let projected = SessionStore.presentationRecoveryEstimate(
            authoritative: rhrOnlyNoSleep,
            hasConfirmedMainSleep: false,
            hasFrozenRecovery: false,
            pendingSleepReview: pending,
            baseline: PersonalBaseline(),
            respiratoryBaseline: nil,
            now: start.addingTimeInterval(60),
            physiologicalCycle: makeCycle(start: start)
        )

        XCTAssertEqual(projected, rhrOnlyNoSleep)
        XCTAssertEqual(projected.percent, 66)
        XCTAssertEqual(projected.confidence, .unverified)
        // Migrated 2026-07-31 (device review): plain-language detail copy.
        XCTAssertTrue(projected.detail.contains("resting HR only"))
    }

    func testPendingReviewCanNeverOverrideConfirmedOrFrozenRecovery() {
        let pending = pendingNight(end: start, duration: 4 * 60 * 60)
        let confirmed = estimate(82)
        let confirmedWins = SessionStore.presentationRecoveryEstimate(
            authoritative: confirmed,
            hasConfirmedMainSleep: true,
            hasFrozenRecovery: false,
            pendingSleepReview: pending,
            baseline: PersonalBaseline(),
            respiratoryBaseline: nil,
            now: start.addingTimeInterval(60),
            physiologicalCycle: makeCycle(start: start)
        )
        let frozen = Metrics.RecoveryEstimate(percent: 48,
                                              confidence: .unverified,
                                              usesHRV: false,
                                              detail: "frozen limited morning",
                                              contributors: [])
        let frozenWins = SessionStore.presentationRecoveryEstimate(
            authoritative: frozen,
            hasConfirmedMainSleep: false,
            hasFrozenRecovery: true,
            pendingSleepReview: pending,
            baseline: PersonalBaseline(),
            respiratoryBaseline: nil,
            now: start.addingTimeInterval(60),
            physiologicalCycle: makeCycle(start: start)
        )

        XCTAssertEqual(confirmedWins, confirmed)
        XCTAssertEqual(frozenWins, frozen,
                       "presentation evidence must not remint a frozen morning")
    }

    func testPendingReviewNeverDowngradesAnyNumericCanonicalAuthority() {
        let pending = pendingNight(end: start, duration: 4 * 60 * 60)
        let authorities = [
            Metrics.RecoveryEstimate(percent: 41,
                                     confidence: .unverified,
                                     usesHRV: false,
                                     detail: "canonical limited evidence",
                                     contributors: []),
            Metrics.RecoveryEstimate(percent: 72,
                                     confidence: .personalBaseline,
                                     usesHRV: true,
                                     detail: "canonical personal baseline",
                                     contributors: []),
            Metrics.RecoveryEstimate(percent: 88,
                                     confidence: .validated,
                                     usesHRV: true,
                                     detail: "canonical validated",
                                     contributors: []),
        ]

        for authoritative in authorities {
            XCTAssertEqual(SessionStore.presentationRecoveryEstimate(
                authoritative: authoritative,
                hasConfirmedMainSleep: false,
                hasFrozenRecovery: false,
                pendingSleepReview: pending,
                baseline: PersonalBaseline(),
                respiratoryBaseline: nil,
                now: start.addingTimeInterval(60),
                physiologicalCycle: makeCycle(start: start)
            ), authoritative)
        }
    }

    func testSixAMRolloverAcceptsCurrentOvernightButRejectsPriorDayCandidate() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let boundary = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2033, month: 6, day: 2, hour: 6
        )))
        let now = boundary.addingTimeInterval(15 * 60)
        let cycle = AtriaPhysiologicalCycle(start: boundary,
                                            boundaryKind: .initialFallback,
                                            anchorSleepID: nil,
                                            expectedInterval: 24 * 60 * 60)
        let learning = Metrics.RecoveryEstimate(percent: nil,
                                                confidence: .learning,
                                                usesHRV: false,
                                                detail: "learning",
                                                contributors: [])
        let overnight = pendingNight(end: boundary.addingTimeInterval(-30 * 60),
                                     duration: 4 * 60 * 60)
        let priorDayMidday = pendingNight(end: boundary.addingTimeInterval(-18 * 60 * 60),
                                         duration: 4 * 60 * 60)

        XCTAssertNotEqual(SessionStore.presentationRecoveryEstimate(
            authoritative: learning,
            hasConfirmedMainSleep: false,
            hasFrozenRecovery: false,
            pendingSleepReview: overnight,
            baseline: PersonalBaseline(),
            respiratoryBaseline: nil,
            now: now,
            physiologicalCycle: cycle,
            calendar: calendar
        ), learning, "an overnight sleep ending just before 06:00 belongs to the new morning")
        XCTAssertEqual(SessionStore.presentationRecoveryEstimate(
            authoritative: learning,
            hasConfirmedMainSleep: false,
            hasFrozenRecovery: false,
            pendingSleepReview: priorDayMidday,
            baseline: PersonalBaseline(),
            respiratoryBaseline: nil,
            now: now,
            physiologicalCycle: cycle,
            calendar: calendar
        ), learning, "a prior-day episode must not leak across the 06:00 rollover")
    }

    func testPendingHRVRequiresThreeQualifiedWindowsLikeCanonicalSleep() throws {
        let now = start.addingTimeInterval(60)
        let cycle = makeCycle(start: start)
        let baseline = trustedBaseline(now: now)

        for count in [1, 2] {
            let estimate = try XCTUnwrap(SessionStore.pendingSleepRecoveryEstimate(
                pendingNight(end: start,
                             duration: 4 * 60 * 60,
                             hrvWindowCount: count),
                baseline: baseline,
                respiratoryBaseline: nil,
                now: now,
                physiologicalCycle: cycle
            ))
            XCTAssertFalse(estimate.usesHRV,
                           "\(count) RR windows must stay below canonical HRV authority")
        }
        let qualified = try XCTUnwrap(SessionStore.pendingSleepRecoveryEstimate(
            pendingNight(end: start,
                         duration: 4 * 60 * 60,
                         hrvWindowCount: 3),
            baseline: baseline,
            respiratoryBaseline: nil,
            now: now,
            physiologicalCycle: cycle
        ))
        XCTAssertTrue(qualified.usesHRV)
    }

    func testProductionRollupPreservesLegacyUnknownAndActualOneTwoThreeHRVWindowGate() throws {
        let now = start.addingTimeInterval(60)
        let baseline = trustedBaseline(now: now)
        for count in 0...3 {
            let rollup = DailyRollup(
                day: Calendar.current.startOfDay(for: start),
                sessions: 1,
                activityCandidates: 0,
                workouts: 0,
                confirmedWorkouts: 0,
                restCandidates: 0,
                sleepReady: 0,
                sleepCandidates: 1,
                duration: 4 * 60 * 60,
                sleepDuration: 4 * 60 * 60,
                sleepSpan: 4 * 60 * 60,
                sleepStart: start.addingTimeInterval(-4 * 60 * 60),
                sleepEnd: start,
                sleepSource: "sleep_window",
                sleepStageSegments: [],
                strain: 0,
                avgHRV: 61,
                hrvWindowCount: count,
                restingHR: 56,
                avgRespiratoryRate: nil
            )
            let snapshot = SleepHistorySnapshot(
                rollups: [rollup],
                confirmedSleeps: []
            )
            let night = try XCTUnwrap(snapshot.nights.first)
            XCTAssertEqual(night.hrvWindowCount, count)
            let estimate = try XCTUnwrap(SessionStore.pendingSleepRecoveryEstimate(
                night,
                baseline: baseline,
                respiratoryBaseline: nil,
                now: now,
                physiologicalCycle: makeCycle(start: start)
            ))
            XCTAssertEqual(estimate.usesHRV, count >= 3,
                           "rollup count \(count) must not be promoted to three")
        }
    }

    func testPendingRecoveryCannotPersistDailyStrainTarget() throws {
        let pending = try XCTUnwrap(SessionStore.pendingSleepRecoveryEstimate(
            pendingNight(end: start, duration: 4 * 60 * 60),
            baseline: PersonalBaseline(),
            respiratoryBaseline: nil,
            now: start.addingTimeInterval(60),
            physiologicalCycle: makeCycle(start: start)
        ))
        XCTAssertEqual(pending.confidence, .unverified)
        XCTAssertNil(AtriaHomeModel.recoveryAuthorizedForStrainTarget(pending))

        let suite = "AtriaRecoveryProjectionCadenceTests.target.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertNil(AtriaDailyStrainTargetStore.resolve(
            recovery: AtriaHomeModel.recoveryAuthorizedForStrainTarget(pending),
            load: nil,
            recoveryIsAttributedToCurrentDay: false,
            loadIsPrepared: true,
            mutationAuthority: .preserveExisting,
            cycleStart: start,
            now: start.addingTimeInterval(60),
            defaults: defaults
        ))
        XCTAssertNil(AtriaDailyStrainTargetStore.loadSnapshot(defaults: defaults))
    }

    func testPendingRecoveryPreservesExistingCanonicalSameCycleTarget() throws {
        let suite = "AtriaRecoveryProjectionCadenceTests.target-preserve.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let canonical = try XCTUnwrap(AtriaDailyStrainTargetStore.resolve(
            recovery: 78,
            load: nil,
            recoveryIsAttributedToCurrentDay: true,
            loadIsPrepared: true,
            mutationAuthority: .canonical,
            cycleStart: start,
            now: start.addingTimeInterval(60),
            defaults: defaults
        ))

        let preserved = AtriaDailyStrainTargetStore.resolve(
            recovery: nil,
            load: nil,
            recoveryIsAttributedToCurrentDay: false,
            loadIsPrepared: true,
            mutationAuthority: .preserveExisting,
            cycleStart: start,
            now: start.addingTimeInterval(120),
            defaults: defaults
        )
        XCTAssertEqual(preserved, canonical)
        XCTAssertEqual(AtriaDailyStrainTargetStore.loadSnapshot(defaults: defaults),
                       canonical)
    }

    func testStaleFutureNapAndMalformedPendingReviewsFailClosed() {
        let authoritative = Metrics.RecoveryEstimate(percent: nil,
                                                     confidence: .learning,
                                                     usesHRV: false,
                                                     detail: "learning",
                                                     contributors: [])
        let now = start.addingTimeInterval(2 * 24 * 60 * 60)
        let stale = pendingNight(end: start, duration: 4 * 60 * 60)
        let future = pendingNight(end: now.addingTimeInterval(10 * 60),
                                  duration: 4 * 60 * 60)
        let nap = pendingNight(end: now,
                               duration: 60 * 60,
                               source: "nap_candidate")
        let malformed = SleepHistorySnapshot.Night(
            id: "malformed-pending",
            day: now,
            start: now.addingTimeInterval(-4 * 60 * 60),
            end: now,
            duration: 4 * 60 * 60,
            restingHR: 300,
            hrv: nil,
            respiratoryRate: nil,
            sleepEfficiency: 1.2,
            confidence: "review_needed",
            source: "sleep_window",
            confirmed: false,
            stageSegments: []
        )

        for rejected in [stale, future, nap, malformed] {
            XCTAssertEqual(SessionStore.presentationRecoveryEstimate(
                authoritative: authoritative,
                hasConfirmedMainSleep: false,
                hasFrozenRecovery: false,
                pendingSleepReview: rejected,
                baseline: PersonalBaseline(),
                respiratoryBaseline: nil,
                now: now,
                physiologicalCycle: makeCycle(start: start)
            ), authoritative)
        }
    }

    func testPendingPresentationRecoveryHasNoReadyHapticAuthority() throws {
        let projected = try XCTUnwrap(SessionStore.pendingSleepRecoveryEstimate(
            pendingNight(end: start, duration: 4 * 60 * 60),
            baseline: PersonalBaseline(),
            respiratoryBaseline: nil,
            now: start.addingTimeInterval(60),
            physiologicalCycle: makeCycle(start: start)
        ))

        XCTAssertEqual(projected.confidence, .unverified)
        XCTAssertFalse(AtriaHapticAlertCoordinator.shouldFireRecoveryReady(
            percent: projected.percent,
            isReadyForAlert: projected.confidence == .validated
                || projected.confidence == .personalBaseline,
            wasReady: false
        ))
    }

    private func makeCycle(start: Date) -> AtriaPhysiologicalCycle {
        AtriaPhysiologicalCycle(start: start,
                               boundaryKind: .mainSleep,
                               anchorSleepID: "night",
                               expectedInterval: 24 * 60 * 60)
    }

    private func estimate(_ percent: Int) -> Metrics.RecoveryEstimate {
        Metrics.RecoveryEstimate(percent: percent,
                                 confidence: .personalBaseline,
                                 usesHRV: true,
                                 detail: "test",
                                 contributors: [])
    }

    private func pendingNight(end: Date,
                              duration: TimeInterval,
                              source: String = "sleep_window",
                              hrvWindowCount: Int = 0) -> SleepHistorySnapshot.Night {
        SleepHistorySnapshot.Night(
            id: "pending-\(source)-\(Int(end.timeIntervalSince1970))",
            day: Calendar.current.startOfDay(for: end),
            start: end.addingTimeInterval(-duration),
            end: end,
            duration: duration,
            restingHR: 56,
            hrv: 61,
            hrvWindowCount: hrvWindowCount,
            respiratoryRate: nil,
            sleepEfficiency: 0.91,
            confidence: "review_needed",
            source: source,
            confirmed: false,
            stageSegments: []
        )
    }

    private func trustedBaseline(now: Date) -> PersonalBaseline {
        var baseline = PersonalBaseline()
        for index in 0..<PersonalBaseline.trustedMinimumSamples {
            baseline.learn(fromResting: 56 + (index % 3),
                           hrv: 58 + (index % 5),
                           at: now.addingTimeInterval(-Double(index + 1) * 24 * 60 * 60),
                           overnight: true)
        }
        return baseline
    }
}
