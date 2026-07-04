import XCTest
@testable import Atria

final class AtriaStressMonitorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let restingMaxHR: (rest: Int, max: Int) = (rest: 60, max: 190)

    // MARK: Baseline fixture

    /// Builds a `PersonalBaseline` with `dayCount` distinct fresh days (all
    /// overnight), each contributing a resting-HR sample alternating
    /// `restingMean +/- restingSD`. When `lnRMSSDMean`/`lnRMSSDSD` are supplied,
    /// the first `hrvSampleDays` of those days also carry an RMSSD value
    /// alternating around the given ln-space mean/sd, so the HRV trust gate
    /// (14 distinct days) can be controlled independently of the resting gate.
    private func makeBaseline(restingMean: Double,
                              restingSD: Double,
                              lnRMSSDMean: Double? = nil,
                              lnRMSSDSD: Double? = nil,
                              hrvSampleDays: Int = 0,
                              dayCount: Int = 20) -> PersonalBaseline {
        var samples: [PersonalBaseline.BaselineSample] = []
        for day in 0..<dayCount {
            let date = now.addingTimeInterval(-Double(day + 1) * 24 * 60 * 60)
            let sign = (day % 2 == 0) ? 1.0 : -1.0
            let restingHR = restingMean + sign * restingSD
            var rmssd: Double?
            if day < hrvSampleDays, let lnRMSSDMean, let lnRMSSDSD {
                rmssd = exp(lnRMSSDMean + sign * lnRMSSDSD)
            }
            samples.append(PersonalBaseline.BaselineSample(date: date,
                                                            restingHR: restingHR,
                                                            rmssd: rmssd,
                                                            overnight: true))
        }
        let hrvEMA = lnRMSSDMean.map(exp)
        return PersonalBaseline(restingHR: restingMean, hrvEMA: hrvEMA,
                                sessions: dayCount, updated: now, samples: samples)
    }

    // MARK: Scored cases

    func testCalmAtPersonalBaselineHROnly() {
        let baseline = makeBaseline(restingMean: 60, restingSD: 4)

        let state = AtriaStressMonitor.score(hrNow: 60,
                                             hrWindow: [60, 60, 60],
                                             rrWindowMs: [],
                                             hrvFallbackRMSSD: nil,
                                             baseline: baseline,
                                             restingMaxHR: restingMaxHR,
                                             workoutActive: false,
                                             zoneIndex: 0,
                                             inSleepWindow: false,
                                             hasContact: true,
                                             contactAgeSeconds: 300,
                                             now: now)

        XCTAssertEqual(state.kind, .scored)
        XCTAssertEqual(state.level, .calm)
        XCTAssertFalse(state.hrvAvailable)
        XCTAssertEqual(state.detail, "HR-only")
    }

    func testHighOnHRAndHRVDivergence() {
        let baseline = makeBaseline(restingMean: 55, restingSD: 3,
                                    lnRMSSDMean: log(45), lnRMSSDSD: 0.15,
                                    hrvSampleDays: 20)

        let state = AtriaStressMonitor.score(hrNow: 64,
                                             hrWindow: [64, 63, 64],
                                             rrWindowMs: [],
                                             hrvFallbackRMSSD: 5,
                                             baseline: baseline,
                                             restingMaxHR: restingMaxHR,
                                             workoutActive: false,
                                             zoneIndex: 0,
                                             inSleepWindow: false,
                                             hasContact: true,
                                             contactAgeSeconds: 300,
                                             now: now)

        XCTAssertEqual(state.kind, .scored)
        XCTAssertEqual(state.level, .high)
        XCTAssertTrue(state.hrvAvailable)
        XCTAssertEqual(state.detail, "HR + HRV vs your baseline")
    }

    func testHRVOnlyModeCapsEmittedLevelAtMedium() {
        // Resting baseline is trusted, but zero distinct HRV days means the
        // HRV baseline never reaches trust -- HR alone can push activation to
        // 1.0, but the emitted level must never claim "High" without HRV
        // corroboration.
        let baseline = makeBaseline(restingMean: 60, restingSD: 2, hrvSampleDays: 0)

        let state = AtriaStressMonitor.score(hrNow: 80,
                                             hrWindow: [80, 79, 80],
                                             rrWindowMs: [],
                                             hrvFallbackRMSSD: nil,
                                             baseline: baseline,
                                             restingMaxHR: restingMaxHR,
                                             workoutActive: false,
                                             zoneIndex: 0,
                                             inSleepWindow: false,
                                             hasContact: true,
                                             contactAgeSeconds: 300,
                                             now: now)

        XCTAssertEqual(state.kind, .scored)
        XCTAssertFalse(state.hrvAvailable)
        XCTAssertEqual(state.detail, "HR-only")
        XCTAssertEqual(state.level, .medium, "HR-only mode must cap at Medium, never High")
        XCTAssertNotEqual(state.level, .high)
    }

    // MARK: Suppression

    func testSuppressedWhileRecording() {
        let baseline = makeBaseline(restingMean: 60, restingSD: 4)

        let state = AtriaStressMonitor.score(hrNow: 150,
                                             hrWindow: [150],
                                             rrWindowMs: [],
                                             hrvFallbackRMSSD: nil,
                                             baseline: baseline,
                                             restingMaxHR: restingMaxHR,
                                             workoutActive: true,
                                             zoneIndex: 0,
                                             inSleepWindow: false,
                                             hasContact: true,
                                             contactAgeSeconds: 300,
                                             now: now)

        XCTAssertEqual(state.kind, .active)
        XCTAssertNil(state.level)
    }

    func testSuppressedAtZoneTwoOrAbove() {
        let baseline = makeBaseline(restingMean: 60, restingSD: 4)

        let state = AtriaStressMonitor.score(hrNow: 130,
                                             hrWindow: [130],
                                             rrWindowMs: [],
                                             hrvFallbackRMSSD: nil,
                                             baseline: baseline,
                                             restingMaxHR: restingMaxHR,
                                             workoutActive: false,
                                             zoneIndex: 2,
                                             inSleepWindow: false,
                                             hasContact: true,
                                             contactAgeSeconds: 300,
                                             now: now)

        XCTAssertEqual(state.kind, .active)
        XCTAssertNil(state.level)
    }

    func testSuppressedInSleepWindow() {
        let baseline = makeBaseline(restingMean: 60, restingSD: 4)

        let state = AtriaStressMonitor.score(hrNow: 58,
                                             hrWindow: [58],
                                             rrWindowMs: [],
                                             hrvFallbackRMSSD: nil,
                                             baseline: baseline,
                                             restingMaxHR: restingMaxHR,
                                             workoutActive: false,
                                             zoneIndex: 0,
                                             inSleepWindow: true,
                                             hasContact: true,
                                             contactAgeSeconds: 300,
                                             now: now)

        XCTAssertEqual(state.kind, .asleep)
        XCTAssertNil(state.level)
    }

    func testNoSignalWhenContactLost() {
        let baseline = makeBaseline(restingMean: 60, restingSD: 4)

        let state = AtriaStressMonitor.score(hrNow: 0,
                                             hrWindow: [],
                                             rrWindowMs: [],
                                             hrvFallbackRMSSD: nil,
                                             baseline: baseline,
                                             restingMaxHR: restingMaxHR,
                                             workoutActive: false,
                                             zoneIndex: nil,
                                             inSleepWindow: false,
                                             hasContact: false,
                                             contactAgeSeconds: 0,
                                             now: now)

        XCTAssertEqual(state.kind, .noSignal)
        XCTAssertNil(state.level)
    }

    func testWarmingUpDuringFirst120SecondsOfContact() {
        let baseline = makeBaseline(restingMean: 60, restingSD: 4)

        let state = AtriaStressMonitor.score(hrNow: 62,
                                             hrWindow: [62],
                                             rrWindowMs: [],
                                             hrvFallbackRMSSD: nil,
                                             baseline: baseline,
                                             restingMaxHR: restingMaxHR,
                                             workoutActive: false,
                                             zoneIndex: 0,
                                             inSleepWindow: false,
                                             hasContact: true,
                                             contactAgeSeconds: 30,
                                             now: now)

        XCTAssertEqual(state.kind, .warmingUp)
        XCTAssertNil(state.level)
    }

    // MARK: Honesty gating

    func testCalibratingWhenRestingBaselineNotYetTrusted() {
        let baseline = PersonalBaseline() // no samples at all

        let state = AtriaStressMonitor.score(hrNow: 62,
                                             hrWindow: [62],
                                             rrWindowMs: [],
                                             hrvFallbackRMSSD: nil,
                                             baseline: baseline,
                                             restingMaxHR: restingMaxHR,
                                             workoutActive: false,
                                             zoneIndex: 0,
                                             inSleepWindow: false,
                                             hasContact: true,
                                             contactAgeSeconds: 300,
                                             now: now)

        XCTAssertEqual(state.kind, .calibrating)
        XCTAssertNil(state.level)
        XCTAssertEqual(state.label, "Calibrating (0/14)")
    }

    func testCalibratingProgressReflectsFreshRestingSampleCount() {
        let baseline = makeBaseline(restingMean: 60, restingSD: 4, dayCount: 5)

        let state = AtriaStressMonitor.score(hrNow: 62,
                                             hrWindow: [62],
                                             rrWindowMs: [],
                                             hrvFallbackRMSSD: nil,
                                             baseline: baseline,
                                             restingMaxHR: restingMaxHR,
                                             workoutActive: false,
                                             zoneIndex: 0,
                                             inSleepWindow: false,
                                             hasContact: true,
                                             contactAgeSeconds: 300,
                                             now: now)

        XCTAssertEqual(state.kind, .calibrating)
        XCTAssertEqual(state.label, "Calibrating (5/14)")
    }
}
