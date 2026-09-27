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

    // 2026-09-24: floors lowered (owner: "22% is still a good amount of
    // battery"): live off below 15 % (resume 18), flush deferred below 10 %
    // (resume 13).
    func testTwentyTwoPercentKeepsLiveMotionOn() {
        let d = P.evaluate(.init(strapBattery: 22, phoneBattery: 70), previous: nil)
        XCTAssertTrue(d.liveMotionAllowed)
        XCTAssertEqual(d.flush, .periodic(interval: 300))
    }

    func testStrapBelowFifteenStopsLiveButKeepsFlushing() {
        let d = P.evaluate(.init(strapBattery: 14, phoneBattery: 70), previous: nil)
        XCTAssertFalse(d.liveMotionAllowed)
        XCTAssertEqual(d.flush, .periodic(interval: 300))
    }

    func testStrapBelowTenDefersFlushLosslessly() {
        let d = P.evaluate(.init(strapBattery: 9, phoneBattery: 70), previous: nil)
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
        let phone = P.evaluate(.init(strapBattery: 12, phoneBattery: 40, phoneCharging: true), previous: nil)
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
        XCTAssertFalse(policy.decide(.init(strapBattery: 14, phoneBattery: 80)).liveMotionAllowed)
        // 16 % is above the block level but below the resume level: still off.
        XCTAssertFalse(policy.decide(.init(strapBattery: 16, phoneBattery: 80)).liveMotionAllowed)
        XCTAssertTrue(policy.decide(.init(strapBattery: 18, phoneBattery: 80)).liveMotionAllowed)
        // Flush pause resumes at 13 %, not 10 %.
        XCTAssertEqual(policy.decide(.init(strapBattery: 9, phoneBattery: 80)).flush, .paused)
        XCTAssertEqual(policy.decide(.init(strapBattery: 11, phoneBattery: 80)).flush, .paused)
        XCTAssertEqual(policy.decide(.init(strapBattery: 13, phoneBattery: 80)).flush, .periodic(interval: 300))
    }

    func testLiveDataNoteExplainsEveryPauseAndHidesWhenLive() {
        let live = P.Inputs(strapBattery: 60, phoneBattery: 80)
        XCTAssertNil(AtriaLiveDataNote.from(decision: P.evaluate(live, previous: nil), inputs: live,
                                            catchingUpHistory: false))
        XCTAssertEqual(AtriaLiveDataNote.from(decision: P.evaluate(live, previous: nil), inputs: live,
                                              catchingUpHistory: true), .catchingUpHistory)
        let lowStrap = P.Inputs(strapBattery: 12, phoneBattery: 80)
        XCTAssertEqual(AtriaLiveDataNote.from(decision: P.evaluate(lowStrap, previous: nil), inputs: lowStrap,
                                              catchingUpHistory: false), .liveMotionPausedStrapBattery(12))
        // 2026-09-27: the status pill already shows the %; the note gives the reason.
        XCTAssertEqual(AtriaLiveDataNote.liveMotionPausedStrapBattery(12).text, "Live steps paused to save strap battery")
        let lpm = P.Inputs(strapBattery: 60, phoneBattery: 80, phoneLowPowerMode: true)
        XCTAssertEqual(AtriaLiveDataNote.from(decision: P.evaluate(lpm, previous: nil), inputs: lpm,
                                              catchingUpHistory: false), .liveMotionPausedLowPowerMode)
        let hot = P.Inputs(strapBattery: 60, phoneBattery: 80, phoneThermal: .serious)
        XCTAssertEqual(AtriaLiveDataNote.from(decision: P.evaluate(hot, previous: nil), inputs: hot,
                                              catchingUpHistory: false), .liveMotionPausedPhoneHot)
    }

    /// Device 2026-09-27: 2A19 read 40–41 % while the 0x30 event read 33 %;
    /// the display jumped between them. 2A19 stays the authority while recent.
    func testBatteryEventDefersToRecentStandardService() {
        typealias B = AtriaBLEManager
        let now = 1_790_500_000.0
        XCTAssertTrue(B.batteryEventDefersToStandardService(
            lastSource: "live_2A19", lastAcceptedAtUnix: now - 600,
            eventReportsCharging: false, currentlyCharging: false, nowUnix: now))
        XCTAssertFalse(B.batteryEventDefersToStandardService(
            lastSource: "live_2A19", lastAcceptedAtUnix: now - 600,
            eventReportsCharging: true, currentlyCharging: false, nowUnix: now),
            "a charger change still comes through")
        XCTAssertFalse(B.batteryEventDefersToStandardService(
            lastSource: "live_2A19", lastAcceptedAtUnix: now - 2 * 3_600,
            eventReportsCharging: false, currentlyCharging: false, nowUnix: now),
            "a stale 2A19 reading does not block the event")
        XCTAssertFalse(B.batteryEventDefersToStandardService(
            lastSource: "live_battery_event", lastAcceptedAtUnix: now - 60,
            eventReportsCharging: false, currentlyCharging: false, nowUnix: now))
    }
}
