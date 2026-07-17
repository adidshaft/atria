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

    func testAllNighterFailsClosedWithoutEvaluatingProvisionalAutoclosure() {
        var cache = SessionStore.RecoveryProjectionCache()
        var evaluations = 0
        func evaluate() -> Metrics.RecoveryEstimate {
            evaluations += 1
            return estimate(99)
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

        XCTAssertNil(projected.percent)
        XCTAssertEqual(projected.confidence, .unverified)
        XCTAssertFalse(projected.usesHRV)
        XCTAssertEqual(evaluations, 0)
    }

    func testOrdinaryInputChurnStaysStableUntilTTLButCycleChangesRefresh() {
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

        XCTAssertEqual(evaluations, 3)
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
}
