import XCTest
@testable import Atria

final class AtriaHRVDisplayFreshnessTests: XCTestCase {
    func testDisplayHRVRejectsOldSessionWithoutDiscardingRecentMeasurement() {
        let now = Date(timeIntervalSinceReferenceDate: 900_000_000)
        let recent = source(ending: now.addingTimeInterval(-4 * 60 * 60))
        let stale = source(ending: now.addingTimeInterval(-24 * 60 * 60 - 1))

        XCTAssertEqual(SessionStore.displayEligibleHRVSource(recent, on: now), recent)
        XCTAssertNil(SessionStore.displayEligibleHRVSource(stale, on: now))
    }

    func testDisplayHRVToleratesSmallClockSkewButRejectsFutureEvidence() {
        let now = Date(timeIntervalSinceReferenceDate: 900_000_000)

        XCTAssertNotNil(SessionStore.displayEligibleHRVSource(
            source(ending: now.addingTimeInterval(5 * 60)),
            on: now
        ))
        XCTAssertNil(SessionStore.displayEligibleHRVSource(
            source(ending: now.addingTimeInterval(5 * 60 + 1)),
            on: now
        ))
    }

    func testReadyLiveSnapshotUsesTheSameTwentyFourHourDisplayBoundary() {
        let now = Date(timeIntervalSinceReferenceDate: 900_000_000)
        XCTAssertTrue(snapshot(ending: now.addingTimeInterval(-24 * 60 * 60))
            .isDisplayEligible(on: now))
        XCTAssertFalse(snapshot(ending: now.addingTimeInterval(-24 * 60 * 60 - 1))
            .isDisplayEligible(on: now))
    }

    private func source(ending end: Date) -> SessionStore.LatestSessionMetricSource {
        SessionStore.LatestSessionMetricSource(sessionID: UUID(),
                                               start: end.addingTimeInterval(-300),
                                               end: end,
                                               value: 58,
                                               priority: 1)
    }

    private func snapshot(ending end: Date) -> HRVSnapshot {
        HRVSnapshot(rmssd: 58,
                    sdnn: 50,
                    pnn50: 20,
                    lnRMSSD: log(58),
                    confidence: 0.9,
                    kept: 180,
                    raw: 190,
                    rejectedOutOfRange: 0,
                    rejectedDeltaOver20Percent: 0,
                    rejectedHRMismatch: 0,
                    interpolated: 0,
                    windowSeconds: 300,
                    maxRRGapSeconds: 1,
                    respiratoryRate: nil,
                    measurementStart: end.addingTimeInterval(-300),
                    measurementEnd: end,
                    analyzedAt: end,
                    provenance: .localRRWindow)
    }
}
