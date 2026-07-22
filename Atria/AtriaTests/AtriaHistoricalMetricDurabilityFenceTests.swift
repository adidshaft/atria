import XCTest
@testable import Atria

final class AtriaHistoricalMetricDurabilityFenceTests: XCTestCase {
    func testMetricEvidenceIsReleasedOnlyAfterSuccessfulFlush() {
        var fence = AtriaHistoricalMetricDurabilityFence()
        fence.begin(generation: 4)
        fence.recordPersistedMetric(
            generation: 4,
            metricUsable: true,
            effectiveUnix: 1_700_000_000
        )

        XCTAssertEqual(
            fence.durableFlushCompleted(generation: 4, succeeded: false),
            []
        )
        XCTAssertEqual(
            fence.durableFlushCompleted(generation: 4, succeeded: true),
            [.init(effectiveUnix: 1_700_000_000)]
        )
        XCTAssertEqual(
            fence.durableFlushCompleted(generation: 4, succeeded: true),
            []
        )
    }

    func testStaleCallbacksCannotReleaseFactsIntoNewGeneration() {
        var fence = AtriaHistoricalMetricDurabilityFence()
        fence.begin(generation: 7)
        fence.recordPersistedMetric(
            generation: 7,
            metricUsable: true,
            effectiveUnix: 100
        )
        fence.begin(generation: 8)
        fence.recordPersistedMetric(
            generation: 8,
            metricUsable: true,
            effectiveUnix: 200
        )

        XCTAssertEqual(
            fence.durableFlushCompleted(generation: 7, succeeded: true),
            []
        )
        XCTAssertEqual(
            fence.durableFlushCompleted(generation: 8, succeeded: true),
            [.init(effectiveUnix: 200)]
        )
    }

    func testUnusableOrUntimestampedRowsNeverBecomeGapEvidence() {
        var fence = AtriaHistoricalMetricDurabilityFence()
        fence.begin(generation: 2)
        fence.recordPersistedMetric(
            generation: 2,
            metricUsable: false,
            effectiveUnix: 100
        )
        fence.recordPersistedMetric(
            generation: 2,
            metricUsable: true,
            effectiveUnix: nil
        )

        XCTAssertEqual(
            fence.durableFlushCompleted(generation: 2, succeeded: true),
            []
        )
    }
}
