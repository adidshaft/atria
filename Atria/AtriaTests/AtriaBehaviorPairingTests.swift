import XCTest
@testable import Atria

/// Assessment P1.9 — journal tags pair to measured signals (HRV, then RHR)
/// so insights survive a Recovery model bump; the composite trails.
final class AtriaBehaviorPairingTests: XCTestCase {
    func testLeadCopyPrefersHRVThenRHRThenRecovery() {
        let all = BehaviorCorrelationSummary(tag: .sleep, days: 8,
                                             recoveryDelta: 5, hrvDelta: 6, rhrDelta: -2)
        XCTAssertEqual(all.impactMetricText, "HRV")
        XCTAssertEqual(all.impactValueText, "+6 ms")
        XCTAssertEqual(all.impactDelta ?? 0, 6, accuracy: 0.001)

        let rhrOnly = BehaviorCorrelationSummary(tag: .training, days: 5,
                                                 recoveryDelta: nil, hrvDelta: nil, rhrDelta: 3)
        XCTAssertEqual(rhrOnly.impactMetricText, "RHR")
        XCTAssertEqual(rhrOnly.impactValueText, "+3 bpm")
        XCTAssertEqual(rhrOnly.impactDelta ?? 0, -3, accuracy: 0.001,
                       "impactDelta is goodness-signed: a higher RHR is unsupportive")
        XCTAssertEqual(rhrOnly.rhrText, "+3 bpm", "display text stays raw-signed")

        let recoveryOnly = BehaviorCorrelationSummary(tag: .caffeine, days: 4,
                                                      recoveryDelta: -4, hrvDelta: nil, rhrDelta: nil)
        XCTAssertEqual(recoveryOnly.impactMetricText, "Recovery",
                       "the composite remains available, just secondary")
    }

    func testDerivedInsightsRankMeasuredSignalsAboveRecovery() throws {
        let summaries = [
            BehaviorCorrelationSummary(tag: .sleep, days: 8,
                                       recoveryDelta: 9, hrvDelta: 3, rhrDelta: nil),
            BehaviorCorrelationSummary(tag: .training, days: 6,
                                       recoveryDelta: nil, hrvDelta: nil, rhrDelta: 4),
        ]
        let insights = try XCTUnwrap(SessionStore.deriveInsightsCancellable(
            from: summaries,
            shouldContinue: { true }))

        XCTAssertEqual(insights.map(\.metric), [.hrv, .rhr, .recovery],
                       "HRV leads, RHR second, the composite trails regardless of magnitude")
    }

    func testLowerRestingHeartRateReadsAsSupportive() {
        let calmer = AtriaInsight(id: "sleep-rhr", tagLabel: "Sleep", metric: .rhr,
                                  delta: -3, days: 6)
        XCTAssertTrue(calmer.isPositive)
        XCTAssertEqual(calmer.headline, "RHR 3 bpm lower")

        let elevated = AtriaInsight(id: "caffeine-rhr", tagLabel: "Caffeine", metric: .rhr,
                                    delta: 3, days: 6)
        XCTAssertFalse(elevated.isPositive)
    }
}
