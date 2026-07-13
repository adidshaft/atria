import XCTest
@testable import Atria

final class AtriaStressDetailViewTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testInputSortsMeasuredReadingsAndClampsOnlyToDisplayDomain() {
        let readings = [
            AtriaStressDetailReading(date: now.addingTimeInterval(60), score: 4.2),
            AtriaStressDetailReading(date: now, score: -0.5)
        ]

        let input = AtriaStressDetailInput(state: scoredState(activation: 0.6),
                                           readings: readings,
                                           updatedAt: now)

        XCTAssertEqual(input.readings.map(\.date), [now, now.addingTimeInterval(60)])
        XCTAssertEqual(input.readings.map(\.score), [0, 3])
        XCTAssertEqual(try XCTUnwrap(input.score), 1.8, accuracy: 0.0001)
    }

    func testNonScoredStateNeverDisplaysNumericScore() {
        let state = AtriaStressState(level: nil,
                                     label: "Warming up",
                                     detail: "Building a live read",
                                     kind: .warmingUp,
                                     confidence: 0,
                                     rawActivation: 0.9,
                                     hrvAvailable: false)

        let input = AtriaStressDetailInput(state: state, readings: [], updatedAt: nil)

        XCTAssertNil(input.score)
    }

    func testTimelineLeavesRealGapInsteadOfConnectingIt() {
        let readings = [
            AtriaStressDetailReading(date: now, score: 0.4),
            AtriaStressDetailReading(date: now.addingTimeInterval(60), score: 0.8),
            AtriaStressDetailReading(date: now.addingTimeInterval(6 * 60 + 1), score: 1.5)
        ]

        let points = AtriaStressTimelinePoint.segment(readings)

        XCTAssertEqual(points.map(\.segment), [0, 0, 1])
    }

    func testTimelineUsesSingleSegmentAtGapBoundary() {
        let readings = [
            AtriaStressDetailReading(date: now, score: 0.4),
            AtriaStressDetailReading(date: now.addingTimeInterval(5 * 60), score: 0.8)
        ]

        XCTAssertEqual(AtriaStressTimelinePoint.segment(readings).map(\.segment), [0, 0])
    }

    private func scoredState(activation: Double) -> AtriaStressState {
        AtriaStressState(level: .medium,
                         label: "Medium",
                         detail: "HR + HRV vs your baseline",
                         kind: .scored,
                         confidence: 0.85,
                         rawActivation: activation,
                         hrvAvailable: true)
    }
}
