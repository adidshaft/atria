import XCTest
import UIKit
@testable import Atria

final class AtriaBackgroundProjectionTests: XCTestCase {

    // MARK: Environmental guard (pure)

    private func guarded(thermal: ProcessInfo.ThermalState,
                         lowPower: Bool,
                         battery: UIDevice.BatteryState,
                         level: Float) -> Bool {
        SessionStore.shouldStartBackgroundArchiveProjection(
            thermalState: thermal,
            isLowPowerModeEnabled: lowPower,
            batteryState: battery,
            batteryLevel: level)
    }

    func testGuardAllowsWhenCoolChargingNotLowPower() {
        XCTAssertTrue(guarded(thermal: .nominal, lowPower: false, battery: .charging, level: 0.9))
        XCTAssertTrue(guarded(thermal: .fair, lowPower: false, battery: .charging, level: 0.9))
        XCTAssertTrue(guarded(thermal: .nominal, lowPower: false, battery: .full, level: 0.3),
                      "a 'full' battery state counts as charging")
    }

    func testGuardBlocksUnderHeat() {
        XCTAssertFalse(guarded(thermal: .serious, lowPower: false, battery: .charging, level: 0.9))
        XCTAssertFalse(guarded(thermal: .critical, lowPower: false, battery: .charging, level: 0.9))
    }

    func testGuardBlocksUnderLowPowerMode() {
        XCTAssertFalse(guarded(thermal: .nominal, lowPower: true, battery: .charging, level: 0.9))
    }

    func testGuardBatteryFallbackWhenUnplugged() {
        XCTAssertTrue(guarded(thermal: .nominal, lowPower: false, battery: .unplugged, level: 0.60))
        XCTAssertTrue(guarded(thermal: .nominal, lowPower: false, battery: .unplugged, level: 0.50),
                      "boundary is inclusive (>= 0.5)")
        XCTAssertFalse(guarded(thermal: .nominal, lowPower: false, battery: .unplugged, level: 0.40))
    }

    func testGuardFailsClosedOnUnknownBattery() {
        // UIDevice reports -1 when the level is unknown; must not start.
        XCTAssertFalse(guarded(thermal: .nominal, lowPower: false, battery: .unknown, level: -1.0))
    }

    // MARK: Cooperative throttle
    //
    // The checkpoint no-ops on the main thread by design, so drive it off-main.

    private func checkpointOffMain(_ throttle: AtriaBackgroundProjectionThrottle,
                                   processedDelta: Int = 1) -> Bool {
        let exp = expectation(description: "off-main checkpoint")
        var result = false
        DispatchQueue.global(qos: .utility).async {
            result = throttle.cooperativeCheckpointShouldAbort(processedDelta: processedDelta)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 3)
        return result
    }

    func testThrottleInactiveNeverAborts() {
        let throttle = AtriaBackgroundProjectionThrottle()
        XCTAssertFalse(checkpointOffMain(throttle), "no begin() → inactive → never aborts, never sleeps")
    }

    func testThrottleAbortsWhenBudgetAlreadyElapsed() {
        let throttle = AtriaBackgroundProjectionThrottle()
        throttle.begin(budgetSeconds: 0)
        XCTAssertTrue(checkpointOffMain(throttle), "zero budget → deadline already passed → abort")
    }

    func testThrottleAbortsWhenCancelled() {
        let throttle = AtriaBackgroundProjectionThrottle()
        throttle.begin(budgetSeconds: 600)
        throttle.cancel()
        XCTAssertTrue(checkpointOffMain(throttle))
    }

    func testThrottleWithinBudgetAndFewFramesDoesNotAbort() {
        let throttle = AtriaBackgroundProjectionThrottle()
        throttle.begin(budgetSeconds: 600)
        // Fewer than the 64-frame cooperative batch → no sleep, no abort.
        XCTAssertFalse(checkpointOffMain(throttle, processedDelta: 10))
    }

    func testThrottleMainThreadIsAlwaysNoOp() {
        let throttle = AtriaBackgroundProjectionThrottle()
        throttle.begin(budgetSeconds: 0)
        // On the main (test) thread the guard short-circuits regardless of state.
        XCTAssertFalse(throttle.cooperativeCheckpointShouldAbort(processedDelta: 1000))
    }

    func testThrottleEndDeactivates() {
        let throttle = AtriaBackgroundProjectionThrottle()
        throttle.begin(budgetSeconds: 600)
        throttle.end()
        XCTAssertFalse(throttle.isActive)
        XCTAssertFalse(checkpointOffMain(throttle, processedDelta: 1000),
                       "after end() the throttle is inactive again")
    }
}
