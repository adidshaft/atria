import XCTest
@testable import Atria

/// Recovery model v4 (assessment P1.5 + P1.6): the sleep term compares to the
/// wearer's own robust sleep baseline once 14 confirmed nights exist, the HRV
/// comparator prefers the 30-day median/MAD receipt when trusted, and the
/// population-norm sleep fallback caps the confidence tier so a score never
/// claims "personal baseline" while one of its terms is a cohort guess.
final class AtriaRecoveryV4Tests: XCTestCase {
    private func trustedBaseline(now: Date,
                                 rmssd: (Int) -> Double = { [48.0, 52.0, 56.0][$0 % 3] }) -> PersonalBaseline {
        let samples = (0..<PersonalBaseline.trustedMinimumSamples).map { index in
            PersonalBaseline.BaselineSample(date: now.addingTimeInterval(Double(-index * 86_400)),
                                            restingHR: [58.0, 60.0, 62.0][index % 3],
                                            rmssd: rmssd(index),
                                            overnight: true)
        }
        return PersonalBaseline(restingHR: 60,
                                hrvEMA: 50,
                                sessions: PersonalBaseline.trustedMinimumSamples,
                                updated: now,
                                samples: samples)
    }

    private var personalSleepBaseline: AtriaAnalytics.Recovery.SleepBaselineStats {
        (hours: (location: 7.2, scale: 0.8, count: 20),
         efficiency: (location: 0.90, scale: 0.04, count: 20))
    }

    func testPersonalSleepBaselineDrivesSleepTermAndKeepsPersonalTier() throws {
        let now = Date()
        let estimate = AtriaAnalytics.Recovery.estimate(hrvSnapshot: nil,
                                                        fallbackRMSSD: 52,
                                                        restingNow: 58,
                                                        baseline: trustedBaseline(now: now),
                                                        sleepEfficiency: 0.90,
                                                        sleepDurationHours: 7.2,
                                                        sleepBaseline: personalSleepBaseline,
                                                        now: now)
        XCTAssertNotNil(estimate.percent)
        XCTAssertEqual(estimate.confidence, .personalBaseline,
                       "a personal sleep term plus trusted HRV/RHR keeps the personal tier")
        let sleep = try XCTUnwrap(estimate.contributors.first { $0.kind == .sleep })
        XCTAssertTrue(sleep.detail.contains("vs your median"),
                      "the sleep contributor discloses the personal comparator, got: \(sleep.detail)")
    }

    func testPopulationSleepFallbackCapsTierToUnverified() throws {
        let now = Date()
        let estimate = AtriaAnalytics.Recovery.estimate(hrvSnapshot: nil,
                                                        fallbackRMSSD: 52,
                                                        restingNow: 58,
                                                        baseline: trustedBaseline(now: now),
                                                        sleepEfficiency: 0.90,
                                                        sleepDurationHours: 7.2,
                                                        sleepBaseline: nil,
                                                        now: now)
        XCTAssertNotNil(estimate.percent)
        XCTAssertEqual(estimate.confidence, .unverified,
                       "a cohort-norm sleep term must cap the tier below personal baseline")
        let sleep = try XCTUnwrap(estimate.contributors.first { $0.kind == .sleep })
        XCTAssertTrue(sleep.detail.contains("calibrating"),
                      "the population fallback discloses calibration, got: \(sleep.detail)")
    }

    func testTrustedHistoryPrefersRobustThirtyDayMedianComparator() throws {
        let now = Date()
        let estimate = AtriaAnalytics.Recovery.estimate(hrvSnapshot: nil,
                                                        fallbackRMSSD: 52,
                                                        restingNow: 58,
                                                        baseline: trustedBaseline(now: now),
                                                        sleepEfficiency: 0.90,
                                                        sleepDurationHours: 7.2,
                                                        sleepBaseline: personalSleepBaseline,
                                                        now: now)
        let hrv = try XCTUnwrap(estimate.contributors.first { $0.kind == .hrv })
        XCTAssertTrue(hrv.detail.contains("vs 30-day median"),
                      "a trusted history reads the robust comparator, got: \(hrv.detail)")
    }

    func testOutlierNightCannotDragTheComparator() {
        let now = Date()
        // One corrupted 200 ms night among ordinary ~52 ms nights. The median/
        // MAD receipt shrugs it off; a mean/sd comparator would both inflate
        // the center and widen sd, mis-scoring a perfectly normal morning.
        let contaminated = trustedBaseline(now: now) { index in
            index == 5 ? 200.0 : [48.0, 52.0, 56.0][index % 3]
        }
        let estimate = AtriaAnalytics.Recovery.estimate(hrvSnapshot: nil,
                                                        fallbackRMSSD: 52,
                                                        restingNow: 60,
                                                        baseline: contaminated,
                                                        sleepEfficiency: 0.90,
                                                        sleepDurationHours: 7.2,
                                                        sleepBaseline: personalSleepBaseline,
                                                        now: now)
        let hrv = estimate.contributors.first { $0.kind == .hrv }
        XCTAssertNotNil(hrv)
        XCTAssertGreaterThan(hrv?.zScore ?? -10, -1.0,
                             "a typical night against a one-outlier history must not read as a large deficit")
    }

    func testContributorWeightsStillRenormalizeToOne() {
        let now = Date()
        let estimate = AtriaAnalytics.Recovery.estimate(hrvSnapshot: nil,
                                                        fallbackRMSSD: 52,
                                                        restingNow: 58,
                                                        baseline: trustedBaseline(now: now),
                                                        sleepEfficiency: 0.90,
                                                        sleepDurationHours: 7.2,
                                                        sleepBaseline: personalSleepBaseline,
                                                        respiratoryRate: 14.2,
                                                        respiratoryBaseline: (mean: 14.0, sd: 0.5, count: 20),
                                                        now: now)
        let total = estimate.contributors.map(\.weight).reduce(0, +)
        XCTAssertEqual(total, 1.0, accuracy: 0.0001)
    }

    func testSleepHistorySnapshotBaselineRequiresFourteenTrustedNights() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        func snapshot(nights: Int) -> SleepHistorySnapshot {
            let base = Date(timeIntervalSince1970: 1_780_000_000)
            let sleeps = (0..<nights).map { index -> UserConfirmedSleep in
                let end = base.addingTimeInterval(Double(-index) * 86_400)
                let start = end.addingTimeInterval(-7.4 * 3_600)
                return UserConfirmedSleep(id: "night-\(index)",
                                          createdAt: end,
                                          start: start,
                                          end: end,
                                          source: "manual_sleep",
                                          confidence: "manual_user_entered",
                                          sessions: 0,
                                          samples: 0,
                                          avgHR: 58,
                                          peakHR: 62,
                                          restingHR: 56,
                                          hrv: 52,
                                          hrvWindowCount: 3,
                                          duration: end.timeIntervalSince(start),
                                          span: end.timeIntervalSince(start),
                                          reason: "v4 baseline fixture",
                                          motionSource: "manual",
                                          motionValidated: false,
                                          stageSegments: nil,
                                          eventTimeZoneIdentifier: utc.timeZone.identifier)
            }
            return SleepHistorySnapshot(rollups: [], confirmedSleeps: sleeps, calendar: utc)
        }

        XCTAssertNil(snapshot(nights: 10).sleepBaselineStats?.hours,
                     "below 14 prior nights the personal sleep baseline must refuse")
        let mature = snapshot(nights: 16).sleepBaselineStats
        XCTAssertNotNil(mature?.hours)
        XCTAssertEqual(mature?.hours?.location ?? 0, 7.4, accuracy: 0.05,
                       "the personal baseline is the robust median of confirmed night hours")
    }
}
