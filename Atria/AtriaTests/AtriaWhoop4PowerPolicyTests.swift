import XCTest
@testable import Atria

final class AtriaWhoop4PowerPolicyTests: XCTestCase {
    typealias P = AtriaWhoop4PowerPolicy

    func testNormalRunsLiveWithFiveMinuteFlush() {
        let d = P.evaluate(.init(strapBattery: 80, phoneBattery: 70), previous: nil)
        XCTAssertTrue(d.liveMotionAllowed)
        XCTAssertEqual(d.flush, .periodic(interval: 300))
    }

    func testUnknownBatteryIsNeverTreatedAsLow() {
        let d = P.evaluate(.init(), previous: nil)
        XCTAssertTrue(d.liveMotionAllowed)
        XCTAssertEqual(d.reason, "normal")
    }

    func testStrapBelowTwentyFiveStopsLiveButKeepsFlushing() {
        let d = P.evaluate(.init(strapBattery: 22, phoneBattery: 70), previous: nil)
        XCTAssertFalse(d.liveMotionAllowed)
        XCTAssertEqual(d.flush, .periodic(interval: 300))
    }

    func testStrapBelowTwentyDefersFlushLosslessly() {
        let d = P.evaluate(.init(strapBattery: 18, phoneBattery: 70), previous: nil)
        XCTAssertFalse(d.liveMotionAllowed)
        XCTAssertEqual(d.flush, .paused)
    }

    func testStrapCriticalPausesEverythingExtra() {
        let d = P.evaluate(.init(strapBattery: 4, phoneBattery: 90, phoneCharging: true), previous: nil)
        XCTAssertEqual(d.flush, .paused)
        XCTAssertEqual(d.reason, "strap_critical")
    }

    func testChargingFlushesAsap() {
        let strap = P.evaluate(.init(strapBattery: 10, strapCharging: true, phoneBattery: 50), previous: nil)
        XCTAssertEqual(strap.flush, .asap)
        XCTAssertTrue(strap.liveMotionAllowed, "strap on charger: live allowed")
        let phone = P.evaluate(.init(strapBattery: 22, phoneBattery: 40, phoneCharging: true), previous: nil)
        XCTAssertEqual(phone.flush, .asap)
        XCTAssertFalse(phone.liveMotionAllowed, "low strap not charging: live stays off even if phone charges")
    }

    func testPhoneLowOrLowPowerModeConserves() {
        for input in [P.Inputs(strapBattery: 80, phoneBattery: 15),
                      P.Inputs(strapBattery: 80, phoneBattery: 80, phoneLowPowerMode: true),
                      P.Inputs(strapBattery: 80, phoneBattery: 80, phoneThermal: .serious)] {
            let d = P.evaluate(input, previous: nil)
            XCTAssertFalse(d.liveMotionAllowed)
            XCTAssertEqual(d.flush, .periodic(interval: 1_800))
        }
    }

    func testHysteresisPreventsFlapping() {
        var policy = P()
        XCTAssertFalse(policy.decide(.init(strapBattery: 24, phoneBattery: 80)).liveMotionAllowed)
        // 26 % is above the block level but below the resume level: still off.
        XCTAssertFalse(policy.decide(.init(strapBattery: 26, phoneBattery: 80)).liveMotionAllowed)
        XCTAssertTrue(policy.decide(.init(strapBattery: 30, phoneBattery: 80)).liveMotionAllowed)
        // Flush pause resumes at 25 %, not 20 %.
        XCTAssertEqual(policy.decide(.init(strapBattery: 19, phoneBattery: 80)).flush, .paused)
        XCTAssertEqual(policy.decide(.init(strapBattery: 21, phoneBattery: 80)).flush, .paused)
        XCTAssertEqual(policy.decide(.init(strapBattery: 25, phoneBattery: 80)).flush, .periodic(interval: 300))
    }
}
