import XCTest
@testable import Atria

/// Opt-in data-sharing transmission policy (2026-07-08): the user's rule is
/// "only transmit while asleep OR not using the phone." These lock every
/// branch and the precedence order so the wiring (next) can't drift from it.
final class AtriaDataSharingPolicyTests: XCTestCase {
    private func decide(optedIn: Bool = true,
                        hasPending: Bool = true,
                        sleep: Bool = false,
                        idle: Bool = false,
                        battery: Double = 0.8,
                        charging: Bool = false) -> AtriaResearchUploadQueue.TransmitDecision {
        AtriaResearchUploadQueue.transmissionEligibility(
            optedIn: optedIn, hasPending: hasPending, withinSleepWindow: sleep,
            phoneIdle: idle, batteryFraction: battery, isCharging: charging)
    }

    func testHoldsWhenNotOptedIn() {
        // Opt-out beats everything, even asleep with a full battery.
        XCTAssertEqual(decide(optedIn: false, sleep: true), .hold(reason: "sharing_off"))
    }

    func testHoldsWhenNothingToSend() {
        XCTAssertEqual(decide(hasPending: false, sleep: true), .hold(reason: "nothing_pending"))
    }

    func testTransmitsWhileAsleep() {
        XCTAssertEqual(decide(sleep: true), .eligible(reason: "sleep_window"))
    }

    func testTransmitsWhilePhoneIdleAndAwake() {
        XCTAssertEqual(decide(sleep: false, idle: true), .eligible(reason: "phone_idle"))
    }

    func testHoldsWhileAwakeAndUsingPhone() {
        XCTAssertEqual(decide(sleep: false, idle: false), .hold(reason: "phone_in_use"))
    }

    func testHoldsOnLowBatteryUnplugged() {
        // Low battery holds even while asleep — battery care outranks the
        // sleep/idle window.
        XCTAssertEqual(decide(sleep: true, battery: 0.10, charging: false),
                       .hold(reason: "low_battery"))
    }

    func testLowBatteryButChargingDoesNotBlock() {
        XCTAssertEqual(decide(sleep: true, battery: 0.10, charging: true),
                       .eligible(reason: "sleep_window"))
    }

    func testUnknownBatteryNeverBlocks() {
        // Negative = monitoring off / unknown: the battery guard fails open,
        // the sleep/idle window still governs.
        XCTAssertEqual(decide(idle: true, battery: -1, charging: false),
                       .eligible(reason: "phone_idle"))
        XCTAssertEqual(decide(sleep: false, idle: false, battery: -1),
                       .hold(reason: "phone_in_use"))
    }

    func testPrecedenceOptOutBeatsPendingAndBattery() {
        XCTAssertEqual(decide(optedIn: false, hasPending: false, battery: 0.05),
                       .hold(reason: "sharing_off"))
    }

    func testIsEligibleAndReasonAccessors() {
        XCTAssertTrue(decide(sleep: true).isEligible)
        XCTAssertFalse(decide().isEligible)
        XCTAssertEqual(decide(sleep: true).reason, "sleep_window")
        XCTAssertEqual(decide().reason, "phone_in_use")
    }
}
