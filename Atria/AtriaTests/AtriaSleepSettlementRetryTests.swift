import XCTest
@testable import Atria

final class AtriaSleepSettlementRetryTests: XCTestCase {
    func testRetryTargetsEarliestUnsettledBoundary() {
        let now = Date(timeIntervalSince1970: 10_000)
        let firstEnd = now.addingTimeInterval(-10 * 60)
        let secondEnd = now.addingTimeInterval(-5 * 60)

        XCTAssertEqual(
            SessionStore.sleepSettlementRetryDelay(
                candidateEnds: [secondEnd, firstEnd],
                now: now
            ),
            20 * 60 + 1
        )
    }

    func testSettledCandidatesDoNotScheduleAnotherBoundaryRetry() {
        let now = Date(timeIntervalSince1970: 10_000)
        let settledEnd = now.addingTimeInterval(-31 * 60)

        XCTAssertNil(
            SessionStore.sleepSettlementRetryDelay(
                candidateEnds: [settledEnd],
                now: now
            )
        )
    }

    func testEmptyCandidateSetDoesNotScheduleRetry() {
        XCTAssertNil(
            SessionStore.sleepSettlementRetryDelay(
                candidateEnds: [],
                now: Date(timeIntervalSince1970: 10_000)
            )
        )
    }
}
