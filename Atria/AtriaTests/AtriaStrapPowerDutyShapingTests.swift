import XCTest
@testable import Atria

/// ITEM-4 2026-08-15 (strap 50%→11% field report): the connected raw
/// catch-up lane shapes its radio duty around the STRAP battery — floor with
/// resume hysteresis, charging exempt, unknown level permissive — and dry
/// slices back off exponentially instead of re-paying the history handshake
/// every fixed 120 s. Scheduling-only: no backlog flag is ever cleared.
final class AtriaStrapPowerDutyShapingTests: XCTestCase {
    func testConstraintFloorsHysteresisAndChargingExemption() {
        // Above floor, discharging → unconstrained.
        XCTAssertFalse(AtriaBLEManager.strapPowerConstrainedForRawCatchUp(
            batteryLevel: 40, isCharging: false, previouslyConstrained: false))
        // At/below floor, discharging → constrained.
        XCTAssertTrue(AtriaBLEManager.strapPowerConstrainedForRawCatchUp(
            batteryLevel: 20, isCharging: false, previouslyConstrained: false))
        XCTAssertTrue(AtriaBLEManager.strapPowerConstrainedForRawCatchUp(
            batteryLevel: 11, isCharging: false, previouslyConstrained: false))
        // Hysteresis: once constrained, 21-24% stays constrained; 25% clears.
        XCTAssertTrue(AtriaBLEManager.strapPowerConstrainedForRawCatchUp(
            batteryLevel: 23, isCharging: false, previouslyConstrained: true))
        XCTAssertFalse(AtriaBLEManager.strapPowerConstrainedForRawCatchUp(
            batteryLevel: 25, isCharging: false, previouslyConstrained: true))
        // Charging exempts at any level — a strap on its pack drains history
        // at full duty (the best time to spend radio).
        XCTAssertFalse(AtriaBLEManager.strapPowerConstrainedForRawCatchUp(
            batteryLevel: 8, isCharging: true, previouslyConstrained: true))
        // Unknown level is permissive, matching the motion-bank precedent.
        XCTAssertFalse(AtriaBLEManager.strapPowerConstrainedForRawCatchUp(
            batteryLevel: -1, isCharging: false, previouslyConstrained: true))
    }

    func testConstrainedBurstCapAppliesOnlyToFullRate() {
        XCTAssertEqual(AtriaBLEManager.connectedRawHistoryCatchUpTargetAcknowledgedPages(
            thermalState: .nominal, strapPowerConstrained: true), 4)
        XCTAssertEqual(AtriaBLEManager.connectedRawHistoryCatchUpTargetAcknowledgedPages(
            thermalState: .nominal, strapPowerConstrained: false), 16)
        // Serious heat already runs 4; the constraint must not deepen it.
        XCTAssertEqual(AtriaBLEManager.connectedRawHistoryCatchUpTargetAcknowledgedPages(
            thermalState: .serious, strapPowerConstrained: true), 4)
        // A background slice stays exactly one page regardless.
        XCTAssertEqual(AtriaBLEManager.connectedRawHistoryCatchUpTargetAcknowledgedPages(
            thermalState: .nominal, backgroundSlice: true, strapPowerConstrained: true), 1)
    }

    func testConstrainedCadenceStretchesWithoutBlockingConvergence() {
        // Productive constrained slice: resumes after the stretched delay.
        let constrained = AtriaBLEManager.connectedRawHistoryCatchUpContinuationDisposition(
            backlogPending: true,
            cursorCaughtUp: false,
            durableRows: 200,
            frontierAdvanceSeconds: 120,
            thermalState: .nominal,
            durableProgressAuthorized: true,
            thermalInterruption: false,
            consecutiveProductiveSlices: 0,
            strapPowerConstrained: true)
        guard case .resumeAfter(let delay) = constrained else {
            return XCTFail("productive constrained slice must resume, got \(constrained)")
        }
        XCTAssertEqual(delay, 30, "constrained productive cadence is 30 s")

        // Second consecutive productive slice under constraint takes the long pause.
        let paused = AtriaBLEManager.connectedRawHistoryCatchUpContinuationDisposition(
            backlogPending: true,
            cursorCaughtUp: false,
            durableRows: 200,
            frontierAdvanceSeconds: 120,
            thermalState: .nominal,
            durableProgressAuthorized: true,
            thermalInterruption: false,
            consecutiveProductiveSlices: 1,
            strapPowerConstrained: true)
        guard case .resumeAfter(let pause) = paused else {
            return XCTFail("second constrained slice must pause, got \(paused)")
        }
        XCTAssertEqual(pause, 60, "constrained duty pause is 60 s every 2 slices")

        // Unconstrained behavior is bit-identical to the shipped defaults.
        let baseline = AtriaBLEManager.connectedRawHistoryCatchUpContinuationDisposition(
            backlogPending: true,
            cursorCaughtUp: false,
            durableRows: 200,
            frontierAdvanceSeconds: 120,
            thermalState: .nominal,
            durableProgressAuthorized: true,
            thermalInterruption: false,
            consecutiveProductiveSlices: 0)
        guard case .resumeAfter(let base) = baseline else {
            return XCTFail("baseline must resume, got \(baseline)")
        }
        XCTAssertEqual(base, 2)

        // Completion is untouched: a caught-up cursor completes even while
        // constrained — the constraint can never strand a finished backlog.
        let complete = AtriaBLEManager.connectedRawHistoryCatchUpContinuationDisposition(
            backlogPending: true,
            cursorCaughtUp: true,
            durableRows: 0,
            frontierAdvanceSeconds: 0,
            thermalState: .nominal,
            durableProgressAuthorized: false,
            thermalInterruption: false,
            consecutiveProductiveSlices: 0,
            strapPowerConstrained: true)
        guard case .complete = complete else {
            return XCTFail("caught-up cursor must complete, got \(complete)")
        }
    }
}
