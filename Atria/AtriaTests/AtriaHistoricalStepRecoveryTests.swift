import XCTest
@testable import Atria

final class AtriaHistoricalStepRecoveryTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_752_000_000)

    func testHistoricalGravityNeverBecomesStepEvidence() {
        let gap = DateInterval(start: start, duration: 30 * 60)
        let result = AtriaHistoricalStepRecovery.recover(
            gap: gap,
            historicalGravityRows: 1_800
        )

        XCTAssertNil(AtriaHistoricalStepRecovery.stepDeltaFromHistoricalGravity())
        XCTAssertEqual(result.state, .missing)
        XCTAssertEqual(result.confidence, .unavailable)
        XCTAssertNil(result.recoveredStepDelta)
        XCTAssertEqual(result.reason, .historicalGravityNotStepCapable)
        XCTAssertEqual(result.provenance, [.whoop4HistoricalGravity1Hz])
        XCTAssertEqual(result.missingCoverageSeconds, 1_800)
    }

    func testValidatedNativeCounterCanRecoverExactMatchingGap() {
        let gap = DateInterval(start: start, duration: 10 * 60)
        let evidence = nativeEvidence(gap: gap, startCount: 12_000, endCount: 12_742)

        let result = AtriaHistoricalStepRecovery.recover(gap: gap, nativeCounter: evidence)

        XCTAssertEqual(result.state, .exactRecovered)
        XCTAssertEqual(result.confidence, .exact)
        XCTAssertEqual(result.recoveredStepDelta, 742)
        XCTAssertEqual(result.observedPreliminaryStepDelta, 0)
        XCTAssertEqual(result.missingCoverageSeconds, 0)
        XCTAssertEqual(result.reason, .exactNativeCounterDelta)
        XCTAssertEqual(result.provenance, [.whoop4NativeCumulativeCounter])
    }

    func testNativeCounterMustExactlyMatchGapBoundaries() {
        let gap = DateInterval(start: start, duration: 10 * 60)
        let wider = DateInterval(start: start.addingTimeInterval(-1),
                                 end: gap.end.addingTimeInterval(1))
        let evidence = nativeEvidence(gap: wider, startCount: 100, endCount: 200)

        let result = AtriaHistoricalStepRecovery.recover(gap: gap, nativeCounter: evidence)

        XCTAssertEqual(result.state, .missing)
        XCTAssertNil(result.recoveredStepDelta)
        XCTAssertEqual(result.reason, .nativeCounterIntervalMismatch)
    }

    func testCounterResetOrEpochChangeFailsClosed() {
        let gap = DateInterval(start: start, duration: 10 * 60)
        let reset = nativeEvidence(gap: gap, startCount: 500, endCount: 3)
        let changedEpoch = AtriaHistoricalStepRecovery.NativeCounterEvidence(
            start: gap.start,
            end: gap.end,
            startCount: 500,
            endCount: 503,
            startCounterEpochID: "boot-a",
            endCounterEpochID: "boot-b",
            provenance: .whoop4NativeCumulativeCounter,
            validationAuthority: "whoop4-step-counter-decoder-v1",
            validated: true
        )

        XCTAssertEqual(
            AtriaHistoricalStepRecovery.recover(gap: gap, nativeCounter: reset).reason,
            .nativeCounterRegression
        )
        XCTAssertEqual(
            AtriaHistoricalStepRecovery.recover(gap: gap, nativeCounter: changedEpoch).reason,
            .nativeCounterEpochMismatch
        )
    }

    func testUnvalidatedOrImplausibleNativeEvidenceFailsClosed() {
        let gap = DateInterval(start: start, duration: 10)
        var unvalidated = nativeEvidence(gap: gap, startCount: 0, endCount: 10,
                                         validated: false)
        XCTAssertEqual(
            AtriaHistoricalStepRecovery.recover(gap: gap, nativeCounter: unvalidated).reason,
            .nativeCounterUnvalidated
        )

        unvalidated = nativeEvidence(gap: gap, startCount: 0, endCount: 81)
        XCTAssertEqual(
            AtriaHistoricalStepRecovery.recover(gap: gap, nativeCounter: unvalidated).reason,
            .nativeCounterImplausibleCadence
        )
    }

    func testLiveLedgerDeltaRemainsPartialAndNeverFillsDisconnectedGap() {
        let gap = DateInterval(start: start, duration: 10 * 60)
        let local = AtriaHistoricalStepRecovery.LocalLedgerEvidence(
            start: gap.start,
            end: gap.start.addingTimeInterval(120),
            adjustedStepDelta: 94,
            rawStepDelta: 100,
            provenance: .r10LivePedometerPreliminary,
            detectorState: "r10_live_preliminary"
        )

        let result = AtriaHistoricalStepRecovery.recover(
            gap: gap,
            localLedger: [local],
            historicalGravityRows: 480
        )

        XCTAssertEqual(result.state, .partialObserved)
        XCTAssertEqual(result.confidence, .preliminary)
        XCTAssertNil(result.recoveredStepDelta)
        XCTAssertEqual(result.observedPreliminaryStepDelta, 94)
        XCTAssertEqual(result.observedPreliminaryRawStepDelta, 100)
        XCTAssertEqual(result.observedCoverageSeconds, 120)
        XCTAssertEqual(result.missingCoverageSeconds, 480)
        XCTAssertEqual(result.reason, .localLedgerOnly)
    }

    func testOverlappingLocalLedgerEvidenceIsNotSummed() {
        let gap = DateInterval(start: start, duration: 10 * 60)
        let first = localEvidence(start: gap.start, duration: 120, adjusted: 10, raw: 12)
        let overlap = localEvidence(start: gap.start.addingTimeInterval(60),
                                    duration: 120, adjusted: 20, raw: 22)

        let result = AtriaHistoricalStepRecovery.recover(gap: gap, localLedger: [first, overlap])

        XCTAssertEqual(result.state, .missing)
        XCTAssertNil(result.recoveredStepDelta)
        XCTAssertEqual(result.observedPreliminaryStepDelta, 0)
        XCTAssertEqual(result.reason, .ambiguousLocalLedgerEvidence)
    }

    func testLedgerAdapterPreservesLocalDetectorProvenance() {
        let segmentID = UUID()
        let before = ledgerRecord(segmentID: segmentID,
                                  updatedAt: start,
                                  cumulative: 1_000,
                                  raw: 1_100)
        let after = ledgerRecord(segmentID: segmentID,
                                 updatedAt: start.addingTimeInterval(60),
                                 cumulative: 1_050,
                                 raw: 1_155)

        let evidence = AtriaHistoricalStepRecovery.localLedgerEvidence(before: before, after: after)

        XCTAssertEqual(evidence?.adjustedStepDelta, 50)
        XCTAssertEqual(evidence?.rawStepDelta, 55)
        XCTAssertEqual(evidence?.provenance, .r10LivePedometerPreliminary)
        XCTAssertEqual(evidence?.detectorState, "r10_live_preliminary")
    }

    private func nativeEvidence(
        gap: DateInterval,
        startCount: Int64,
        endCount: Int64,
        validated: Bool = true
    ) -> AtriaHistoricalStepRecovery.NativeCounterEvidence {
        .init(
            start: gap.start,
            end: gap.end,
            startCount: startCount,
            endCount: endCount,
            startCounterEpochID: "boot-a",
            endCounterEpochID: "boot-a",
            provenance: .whoop4NativeCumulativeCounter,
            validationAuthority: "whoop4-step-counter-decoder-v1",
            validated: validated
        )
    }

    private func localEvidence(
        start: Date,
        duration: TimeInterval,
        adjusted: Int,
        raw: Int
    ) -> AtriaHistoricalStepRecovery.LocalLedgerEvidence {
        .init(start: start,
              end: start.addingTimeInterval(duration),
              adjustedStepDelta: adjusted,
              rawStepDelta: raw,
              provenance: .r10LivePedometerPreliminary,
              detectorState: "r10_live_preliminary")
    }

    private func ledgerRecord(
        segmentID: UUID,
        updatedAt: Date,
        cumulative: Int,
        raw: Int
    ) -> AtriaStrapStepLedger.Record {
        .init(schema: AtriaStrapStepLedger.schema,
              segmentID: segmentID,
              segmentStartedAt: start,
              updatedAt: updatedAt,
              segmentSteps: cumulative,
              segmentRawSteps: raw,
              cumulativeSteps: cumulative,
              cumulativeRawSteps: raw,
              deviceTimestamp: 123,
              state: "r10_live_preliminary")
    }
}
