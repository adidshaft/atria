import XCTest
@testable import Atria

/// W1-A 2026-08-20 (step-latency Steps 1, 2, 4): pure-policy coverage for
/// the unified raw-lane radio-ownership predicate, the bounded capture-share
/// leg of the connected-raw continuation disposition, and the offload
/// admission diagnostic counter. All deterministic, all pure or on an
/// isolated per-test UserDefaults suite; no timing waits, no multi-save
/// integration tests.
final class AtriaRawLaneRadioOwnershipPolicyTests: XCTestCase {

    /// 2026-08-20T00:00:00Z — safely after the 2026-08-06 fixture floor
    /// (host device-use journal contamination affects only earlier anchors).
    private let anchor = Date(timeIntervalSince1970: 1_787_184_000)

    // MARK: - Step 1: unified "raw lane actively owns radio" predicate

    func testPendingContinuationWithIdleGapAdmitsOffload() {
        // Next evaluation comfortably in the future: the raw lane owns no
        // radio, so bank arming and closed-ticket offloads are admitted.
        XCTAssertFalse(
            AtriaBLEManager.connectedRawContinuationActivelyOwnsRadio(
                continuationPending: true,
                nextEvaluationNotBefore: anchor.addingTimeInterval(120),
                now: anchor
            )
        )
        // Exactly at the 60s floor counts as idle (>= floor), matching the
        // arm path's original inline test.
        XCTAssertFalse(
            AtriaBLEManager.connectedRawContinuationActivelyOwnsRadio(
                continuationPending: true,
                nextEvaluationNotBefore: anchor.addingTimeInterval(60),
                now: anchor
            )
        )
    }

    func testPendingContinuationWithImminentSliceDefersOffload() {
        XCTAssertTrue(
            AtriaBLEManager.connectedRawContinuationActivelyOwnsRadio(
                continuationPending: true,
                nextEvaluationNotBefore: anchor.addingTimeInterval(59),
                now: anchor
            )
        )
        // A next evaluation already due (in the past) is an active slice.
        XCTAssertTrue(
            AtriaBLEManager.connectedRawContinuationActivelyOwnsRadio(
                continuationPending: true,
                nextEvaluationNotBefore: anchor.addingTimeInterval(-5),
                now: anchor
            )
        )
    }

    func testPendingContinuationWithUnknownNextEvaluationFailsClosed() {
        XCTAssertTrue(
            AtriaBLEManager.connectedRawContinuationActivelyOwnsRadio(
                continuationPending: true,
                nextEvaluationNotBefore: nil,
                now: anchor
            )
        )
    }

    func testNoContinuationNeverOwnsRadio() {
        XCTAssertFalse(
            AtriaBLEManager.connectedRawContinuationActivelyOwnsRadio(
                continuationPending: false,
                nextEvaluationNotBefore: nil,
                now: anchor
            )
        )
        XCTAssertFalse(
            AtriaBLEManager.connectedRawContinuationActivelyOwnsRadio(
                continuationPending: false,
                nextEvaluationNotBefore: anchor.addingTimeInterval(1),
                now: anchor
            )
        )
    }

    // MARK: - Step 2: bounded capture-share disposition leg

    func testCaptureShareFiresAfterConfiguredProductiveSlices() {
        XCTAssertEqual(
            AtriaBLEManager.connectedRawHistoryCatchUpContinuationDisposition(
                backlogPending: true,
                cursorCaughtUp: false,
                durableRows: 200,
                frontierAdvanceSeconds: 90,
                thermalState: .nominal,
                durableProgressAuthorized: true,
                thermalInterruption: false,
                consecutiveProductiveSlices: 0,
                productiveSlicesSinceCaptureShare: 29
            ),
            .pauseForPresentCapture(120),
            "the 30th productive slice schedules one coarse capture pause"
        )
        XCTAssertEqual(
            AtriaBLEManager.connectedRawHistoryCatchUpContinuationDisposition(
                backlogPending: true,
                cursorCaughtUp: false,
                durableRows: 200,
                frontierAdvanceSeconds: 90,
                thermalState: .nominal,
                durableProgressAuthorized: true,
                thermalInterruption: false,
                consecutiveProductiveSlices: 0,
                productiveSlicesSinceCaptureShare: 28
            ),
            .resumeAfter(2),
            "below the cadence threshold the normal productive chain continues"
        )
    }

    func testCaptureSharePauseNeverDropsBelowIdleWindowPlusMargin() {
        // Even a misconfigured pause cannot recreate a sub-idle-window
        // interleave inside a raw continuation episode (rejected v5 flow):
        // the pure function clamps to the 60s idle window + 30s margin.
        XCTAssertEqual(
            AtriaBLEManager.connectedRawHistoryCatchUpContinuationDisposition(
                backlogPending: true,
                cursorCaughtUp: false,
                durableRows: 200,
                frontierAdvanceSeconds: 90,
                thermalState: .nominal,
                durableProgressAuthorized: true,
                thermalInterruption: false,
                consecutiveProductiveSlices: 0,
                productiveSlicesSinceCaptureShare: 29,
                presentCaptureSharePause: 10
            ),
            .pauseForPresentCapture(90)
        )
        XCTAssertEqual(
            AtriaBLEManager
                .connectedRawCatchUpPresentCaptureSharePauseSecondsDefault,
            120,
            "production default keeps the plan's 120s share (~6-7% of a 30min cycle)"
        )
    }

    func testCaptureShareYieldsToPendingPublicationWork() {
        // App-facing publication keeps its priority: when both legs are due,
        // the bounded publication yield wins (it is itself an armable idle
        // gap under the unified predicate, and the caller restarts the
        // capture cadence when a yield begins).
        XCTAssertEqual(
            AtriaBLEManager.connectedRawHistoryCatchUpContinuationDisposition(
                backlogPending: true,
                cursorCaughtUp: false,
                durableRows: 200,
                frontierAdvanceSeconds: 90,
                thermalState: .nominal,
                durableProgressAuthorized: true,
                thermalInterruption: false,
                consecutiveProductiveSlices: 0,
                publicationYieldNeeded: true,
                productiveSlicesSinceCaptureShare: 29
            ),
            .yieldForPublication(120)
        )
    }

    func testCaptureShareRequiresProductiveSlice() {
        // A dry slice keeps the conservative zero-progress retry; the
        // capture-share leg only ever interrupts sustained PRODUCTIVE drain.
        XCTAssertEqual(
            AtriaBLEManager.connectedRawHistoryCatchUpContinuationDisposition(
                backlogPending: true,
                cursorCaughtUp: false,
                durableRows: 0,
                frontierAdvanceSeconds: 0,
                thermalState: .nominal,
                durableProgressAuthorized: false,
                thermalInterruption: false,
                consecutiveProductiveSlices: 0,
                productiveSlicesSinceCaptureShare: 29
            ),
            .retryAfter(120)
        )
    }

    func testCaptureShareCadenceStretchesUnderStrapPowerConstraint() {
        // ITEM-4 binding: the strap-power-constrained cadence stretch must
        // also stretch the capture cadence — the slice-count threshold
        // doubles (30 -> 60) on top of the 15x slower slice cadence.
        XCTAssertEqual(
            AtriaBLEManager.connectedRawHistoryCatchUpContinuationDisposition(
                backlogPending: true,
                cursorCaughtUp: false,
                durableRows: 200,
                frontierAdvanceSeconds: 90,
                thermalState: .nominal,
                durableProgressAuthorized: true,
                thermalInterruption: false,
                consecutiveProductiveSlices: 0,
                strapPowerConstrained: true,
                productiveSlicesSinceCaptureShare: 29
            ),
            .resumeAfter(30),
            "29 productive slices do not reach the doubled constrained threshold"
        )
        XCTAssertEqual(
            AtriaBLEManager.connectedRawHistoryCatchUpContinuationDisposition(
                backlogPending: true,
                cursorCaughtUp: false,
                durableRows: 200,
                frontierAdvanceSeconds: 90,
                thermalState: .nominal,
                durableProgressAuthorized: true,
                thermalInterruption: false,
                consecutiveProductiveSlices: 0,
                strapPowerConstrained: true,
                productiveSlicesSinceCaptureShare: 59
            ),
            .pauseForPresentCapture(120)
        )
    }

    func testCaptureShareDefaultsMatchPlannedCadence() {
        XCTAssertEqual(
            AtriaBLEManager
                .connectedRawCatchUpPresentCaptureShareAfterSlicesDefault,
            30
        )
        XCTAssertEqual(
            AtriaBLEManager
                .connectedRawCatchUpConstrainedPresentCaptureShareAfterSlicesDefault,
            60
        )
        XCTAssertEqual(
            AtriaBLEManager.connectedRawContinuationIdleWindowSeconds,
            60,
            "the idle floor must stay in lockstep with the arm path's original 60s test"
        )
    }

    // MARK: - Step 4: deferral-vs-admission observability counter

    func testOffloadAdmissionDiagCountsOutcomesPerDay() {
        let suiteName = "AtriaRawLaneRadioOwnershipPolicyTests.admission"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let noon = anchor.addingTimeInterval(12 * 3600)
        AtriaMotionBankOffloadAdmissionDiag.note(
            "deferred_raw_active", now: noon, defaults: defaults
        )
        AtriaMotionBankOffloadAdmissionDiag.note(
            "deferred_raw_active", now: noon.addingTimeInterval(60),
            defaults: defaults
        )
        AtriaMotionBankOffloadAdmissionDiag.note(
            "admitted_raw_idle", now: noon.addingTimeInterval(120),
            defaults: defaults
        )
        let state = AtriaMotionBankOffloadAdmissionDiag.load(
            defaults: defaults
        )
        XCTAssertEqual(state?.day, AtriaMotionBankDutyCycleDiag.dayKey(for: noon))
        XCTAssertEqual(state?.counts["deferred_raw_active"], 2)
        XCTAssertEqual(state?.counts["admitted_raw_idle"], 1)
    }

    func testOffloadAdmissionDiagSnapshotsYesterdayOnDayRollover() {
        let suiteName = "AtriaRawLaneRadioOwnershipPolicyTests.rollover"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let noon = anchor.addingTimeInterval(12 * 3600)
        AtriaMotionBankOffloadAdmissionDiag.note(
            "deferred_raw_active", now: noon, defaults: defaults
        )
        // Exactly 24h later is a different civil day in every timezone.
        let nextNoon = noon.addingTimeInterval(24 * 3600)
        AtriaMotionBankOffloadAdmissionDiag.note(
            "admitted_raw_idle", now: nextNoon, defaults: defaults
        )
        let state = AtriaMotionBankOffloadAdmissionDiag.load(
            defaults: defaults
        )
        XCTAssertEqual(
            state?.day, AtriaMotionBankDutyCycleDiag.dayKey(for: nextNoon)
        )
        XCTAssertEqual(state?.counts, ["admitted_raw_idle": 1])
        let yesterdayText = defaults.string(
            forKey: AtriaMotionBankOffloadAdmissionDiag.previousDayKey
        )
        let yesterday = yesterdayText
            .flatMap { $0.data(using: .utf8) }
            .flatMap {
                try? JSONDecoder().decode(
                    AtriaMotionBankOffloadAdmissionDiag.State.self, from: $0
                )
            }
        XCTAssertEqual(
            yesterday?.day, AtriaMotionBankDutyCycleDiag.dayKey(for: noon)
        )
        XCTAssertEqual(yesterday?.counts, ["deferred_raw_active": 1])
    }
}
