import XCTest
@testable import Atria

final class AtriaBreathworkStressFeedbackTests: XCTestCase {
    func testScoredStressStateProducesClampedMeasuredReading() throws {
        let measuredAt = Date(timeIntervalSince1970: 1_800_000_000)
        let state = AtriaStressState(level: .high,
                                     label: "High",
                                     detail: "HR + HRV vs your baseline",
                                     kind: .scored,
                                     confidence: 0.85,
                                     rawActivation: 1.2,
                                     hrvAvailable: true)

        let reading = try XCTUnwrap(AtriaBreathworkStressReading(state: state,
                                                                 measuredAt: measuredAt))
        XCTAssertEqual(reading.score, 3)
        XCTAssertEqual(reading.measuredAt, measuredAt)
    }

    func testNonScoredStressStateFailsClosed() {
        let state = AtriaStressState(level: nil,
                                     label: "Warming up",
                                     detail: "Building a live read",
                                     kind: .warmingUp,
                                     confidence: 0,
                                     rawActivation: 0.8,
                                     hrvAvailable: false)

        XCTAssertNil(AtriaBreathworkStressReading(state: state, measuredAt: Date()))
    }

    func testFreshnessRejectsStaleAndFutureReadings() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        XCTAssertNotNil(AtriaBreathworkStressReading(score: 1.8,
                                                      measuredAt: now.addingTimeInterval(-90))?
            .fresh(at: now))
        XCTAssertNil(AtriaBreathworkStressReading(score: 1.8,
                                                   measuredAt: now.addingTimeInterval(-90.1))?
            .fresh(at: now))
        XCTAssertNil(AtriaBreathworkStressReading(score: 1.8,
                                                   measuredAt: now.addingTimeInterval(5.1))?
            .fresh(at: now))
        XCTAssertNil(AtriaBreathworkStressReading(score: .nan, measuredAt: now))
    }

    func testFeedbackReportsMeasuredDecreaseFromCapturedBaseline() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let baseline = try XCTUnwrap(AtriaBreathworkStressReading(score: 2.4, measuredAt: start))
        let current = try XCTUnwrap(AtriaBreathworkStressReading(score: 1.8,
                                                                 measuredAt: start.addingTimeInterval(120)))

        let feedback = try XCTUnwrap(AtriaBreathworkStressFeedback.make(
            current: current,
            baseline: baseline,
            now: start.addingTimeInterval(120)
        ))

        XCTAssertEqual(feedback.currentScore, 1.8, accuracy: 0.0001)
        XCTAssertEqual(feedback.delta ?? 0, -0.6, accuracy: 0.0001)
        XCTAssertEqual(feedback.direction, .down)
        XCTAssertEqual(feedback.valueText, "1.8")
        XCTAssertEqual(feedback.changeText, "down 0.6 from 2.4")
    }

    func testFeedbackShowsCurrentWithoutInventingMissingBaseline() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let current = try XCTUnwrap(AtriaBreathworkStressReading(score: 1.4, measuredAt: now))

        let feedback = try XCTUnwrap(AtriaBreathworkStressFeedback.make(current: current,
                                                                         baseline: nil,
                                                                         now: now))
        XCTAssertEqual(feedback.valueText, "1.4")
        XCTAssertNil(feedback.delta)
        XCTAssertNil(feedback.direction)
        XCTAssertNil(feedback.changeText)
    }

    func testFeedbackRejectsStaleCurrentInsteadOfShowingLastKnownScore() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let baseline = try XCTUnwrap(AtriaBreathworkStressReading(score: 2.0,
                                                                  measuredAt: now.addingTimeInterval(-180)))
        let staleCurrent = try XCTUnwrap(AtriaBreathworkStressReading(score: 1.0,
                                                                      measuredAt: now.addingTimeInterval(-91)))

        XCTAssertNil(AtriaBreathworkStressFeedback.make(current: staleCurrent,
                                                         baseline: baseline,
                                                         now: now))
    }
}
