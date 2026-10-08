import XCTest
@testable import Atria

/// Assessment P1.9 — journal tags pair to measured signals (HRV, then RHR)
/// so insights survive a Recovery model bump; the composite trails.
///
/// 2026-10-08 — findings are evidence-gated and ROUTED: a tag's expected
/// effect meets the measured direction, so "HRV higher on alcohol days" can
/// never read as a licence and "HRV lower on hydration days" never as a
/// reason to stop.
final class AtriaBehaviorPairingTests: XCTestCase {
    private func summary(_ tag: BehaviorJournalEntry.Tag,
                         days: Int = 8,
                         comparisonDays: Int = 20,
                         recovery: Double? = nil, recoveryP: Double? = 0.02,
                         hrv: Double? = nil, hrvP: Double? = 0.02,
                         rhr: Double? = nil, rhrP: Double? = 0.02) -> BehaviorCorrelationSummary {
        BehaviorCorrelationSummary(tag: tag, days: days,
                                   recoveryDelta: recovery, hrvDelta: hrv, rhrDelta: rhr,
                                   comparisonDays: comparisonDays,
                                   recoveryPValue: recovery == nil ? nil : recoveryP,
                                   hrvPValue: hrv == nil ? nil : hrvP,
                                   rhrPValue: rhr == nil ? nil : rhrP)
    }

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

    func testDerivedInsightsRankMeasuredSignalsAboveRecoveryWithinARoutingGroup() throws {
        let summaries = [
            summary(.sleep, recovery: 9, hrv: 3),
            summary(.hydration, rhr: -4),
        ]
        let insights = try XCTUnwrap(SessionStore.deriveInsightsCancellable(
            from: summaries,
            shouldContinue: { true }))

        XCTAssertEqual(insights.map(\.reading), [.helps, .helps, .helps])
        XCTAssertEqual(insights.map(\.metric), [.hrv, .rhr, .recovery],
                       "HRV leads, RHR second, the composite trails regardless of magnitude")
    }

    func testDerivedInsightsRouteActionableFirstAndCounterExpectedLast() throws {
        let summaries = [
            summary(.alcohol, hrv: 3),            // disruptive, measured better → noCostYet
            summary(.training, hrv: -6),          // neutral load
            summary(.hydration, hrv: 4),          // supportive, measured better → helps
            summary(.caffeine, rhr: 3),           // disruptive, measured worse → costs
            summary(.meditation, hrv: -3),        // supportive, measured worse → notHelpingYet
        ]
        let insights = try XCTUnwrap(SessionStore.deriveInsightsCancellable(
            from: summaries,
            shouldContinue: { true }))
        XCTAssertEqual(insights.map(\.reading),
                       [.helps, .costs, .neutralWorse, .noCostYet, .notHelpingYet])
        XCTAssertEqual(insights.map(\.tone),
                       [.supportive, .unsupportive, .unsupportive, .neutral, .neutral],
                       "no hue for a finding that runs against expectation")
    }

    func testDerivedInsightsRefuseThinOrInsignificantLanes() {
        let thin = SessionStore.deriveInsights(from: [
            summary(.alcohol, days: 3, hrv: 3),
            summary(.selfPleasure, days: 6, comparisonDays: 4, hrv: 3),
            summary(.caffeine, hrv: 3, hrvP: 0.4),
            summary(.caffeine, hrv: 1.5),
            summary(.sleep, hrv: 5, hrvP: nil),
        ])
        XCTAssertTrue(thin.isEmpty,
                      "3 tagged days, 4 comparison days, p 0.4, a 1.5 ms effect, or no p-value never surface: \(thin.map(\.id))")
    }

    func testFamilyWiseCorrectionDecidesHeadlineGradeAndIntimacyStaysOffToday() throws {
        // Three lanes searched → corrected threshold 0.10 / 3 ≈ 0.033.
        let insights = try XCTUnwrap(SessionStore.deriveInsightsCancellable(
            from: [
                summary(.hydration, hrv: 4, hrvP: 0.01),
                summary(.alcohol, hrv: -5, hrvP: 0.08),
                summary(.selfPleasure, hrv: 3, hrvP: 0.01),
            ],
            shouldContinue: { true }))
        let byTag = Dictionary(uniqueKeysWithValues: insights.map { ($0.id, $0) })
        XCTAssertEqual(byTag["hydration-hrv"]?.survivesCorrection, true)
        XCTAssertEqual(byTag["hydration-hrv"]?.isHeadlineGrade, true)
        XCTAssertEqual(byTag["alcohol-hrv"]?.survivesCorrection, false,
                       "p 0.08 clears the 0.10 lane gate but not the corrected threshold")
        XCTAssertEqual(byTag["alcohol-hrv"]?.isHeadlineGrade, false)
        XCTAssertEqual(byTag["selfPleasure-hrv"]?.isPrivate, true)
        XCTAssertEqual(byTag["selfPleasure-hrv"]?.isHeadlineGrade, false,
                       "an intimacy tag never rides Today's glanceable deck")

        let todayItems = AtriaTodayLearningsFeed.items(learned: [], behavior: insights)
        XCTAssertEqual(todayItems.map(\.id), ["behavior-hydration-hrv"])
    }

    func testHeadlinesRouteOnExpectedEffectMeetingMeasuredDirection() {
        func insight(_ tag: BehaviorJournalEntry.Tag, _ metric: AtriaInsight.Metric,
                     _ delta: Double) -> AtriaInsight {
            AtriaInsight(id: "\(tag.rawValue)-x", tagLabel: tag.label, metric: metric,
                         delta: delta, days: 8, comparisonDays: 20,
                         expectedEffect: tag.expectedEffect, isPrivate: tag.isPrivate)
        }

        let helps = insight(.hydration, .hrv, 4)
        XCTAssertEqual(helps.reading, .helps)
        XCTAssertEqual(helps.headline, "HRV 4 ms higher on hydration days")
        XCTAssertEqual(helps.detail, "Keep it up. HRV ran 4 ms higher across 8 hydration days vs 20 others.")

        let costs = insight(.alcohol, .hrv, -5)
        XCTAssertEqual(costs.reading, .costs)
        XCTAssertEqual(costs.headline, "HRV 5 ms lower on alcohol days")
        XCTAssertEqual(costs.tone, .unsupportive)

        let noCost = insight(.alcohol, .hrv, 3)
        XCTAssertEqual(noCost.reading, .noCostYet)
        XCTAssertEqual(noCost.headline, "Alcohol isn't hurting HRV so far")
        XCTAssertEqual(noCost.detail,
                       "HRV ran 3 ms higher across 8 alcohol days vs 20 others. Too few to call it a benefit.")
        XCTAssertEqual(noCost.tone, .neutral)
        XCTAssertEqual(noCost.compactDeltaText, "+3 ms", "the number itself stays raw-signed")

        let noRHRCost = insight(.caffeine, .rhr, -2)
        XCTAssertEqual(noRHRCost.headline, "Caffeine isn't hurting resting HR so far")

        let notHelping = insight(.hydration, .hrv, -3)
        XCTAssertEqual(notHelping.reading, .notHelpingYet)
        XCTAssertEqual(notHelping.headline, "Hydration isn't lifting HRV yet")
        XCTAssertEqual(notHelping.detail,
                       "HRV ran 3 ms lower across 8 hydration days vs 20 others. Not a reason to stop.")
        XCTAssertEqual(insight(.meditation, .rhr, 2).headline, "Meditation isn't lowering resting HR yet")

        let neutral = insight(.selfPleasure, .hrv, 3)
        XCTAssertEqual(neutral.reading, .neutralBetter)
        XCTAssertEqual(neutral.headline, "HRV 3 ms higher on self-pleasure days")
        XCTAssertTrue(neutral.isPrivate)
        XCTAssertEqual(insight(.training, .rhr, 3).reading, .neutralWorse)
    }

    func testLowerRestingHeartRateReadsAsSupportive() {
        let calmer = AtriaInsight(id: "sleep-rhr", tagLabel: "Sleep", metric: .rhr,
                                  delta: -3, days: 6, expectedEffect: .supportive)
        XCTAssertTrue(calmer.isPositive)
        XCTAssertEqual(calmer.headline, "Resting HR 3 bpm lower on sleep days")
        XCTAssertEqual(calmer.detail, "Keep it up. Resting HR ran 3 bpm lower across 6 sleep days vs your other days.")
        XCTAssertEqual(calmer.symbolName, "moon.zzz.fill")
        XCTAssertEqual(calmer.compactDeltaText, "-3 bpm")

        let elevated = AtriaInsight(id: "caffeine-rhr", tagLabel: "Caffeine", metric: .rhr,
                                    delta: 3, days: 6, expectedEffect: .disruptive)
        XCTAssertFalse(elevated.isPositive)
        XCTAssertEqual(elevated.headline, "Resting HR 3 bpm higher on caffeine days")
        XCTAssertEqual(elevated.symbolName, "cup.and.saucer.fill")
        XCTAssertEqual(elevated.compactDeltaText, "+3 bpm")
    }

    func testEveryTagHasAnExpectedEffectAndOnlyIntimacyIsPrivate() {
        for tag in BehaviorJournalEntry.Tag.allCases {
            XCTAssertEqual(tag.isPrivate, tag == .sexualActivity || tag == .selfPleasure, "\(tag)")
        }
        XCTAssertEqual(BehaviorJournalEntry.Tag.alcohol.expectedEffect, .disruptive)
        XCTAssertEqual(BehaviorJournalEntry.Tag.hydration.expectedEffect, .supportive)
        XCTAssertEqual(BehaviorJournalEntry.Tag.training.expectedEffect, .neutral,
                       "load is expected to dip HRV short-term; reported plainly")
    }

    func testLanePValueNeedsASpreadOnBothSides() {
        XCTAssertNil(SessionStore.lanePValue([50], [40, 42, 44]))
        XCTAssertNil(SessionStore.lanePValue([50, 52], [40]))
        let separated = try? XCTUnwrap(SessionStore.lanePValue([60, 62, 61, 63, 60], [40, 42, 41, 43, 40]))
        XCTAssertLessThan(separated ?? 1, 0.01)
        let overlapping = try? XCTUnwrap(SessionStore.lanePValue([50, 44, 56, 47, 53], [49, 45, 55, 48, 52]))
        XCTAssertGreaterThan(overlapping ?? 0, 0.5)
    }
}
