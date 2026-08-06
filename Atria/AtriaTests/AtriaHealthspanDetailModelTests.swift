import XCTest
@testable import Atria

final class AtriaHealthspanDetailModelTests: XCTestCase {
    func testNotReadyPreparedPaceDoesNotProduceDisplayValue() {
        let model = AtriaHealthspanDetailModel(
            summary: .building(chronologicalAge: 35, blockers: ["14 days of heart data"]),
            paceOfAging: .init(isReady: false,
                              yearsPerCalendarYear: nil,
                              copyText: AtriaFitnessAge.paceCalibratingCopy)
        )

        XCTAssertNil(model.displayPace)
        XCTAssertNil(model.paceGaugePosition)
    }

    func testGaugeClampsOnlyMarkerPosition() {
        let summary = BiologicalAgeSummary(
            biologicalAge: 31,
            chronologicalAge: 35,
            ageDelta: -4,
            agingPaceText: "Fitness age",
            agingPaceDetail: "Prepared detail",
            factors: [],
            blockers: [],
            footnote: BiologicalAgeSummary.footnoteText
        )
        let model = AtriaHealthspanDetailModel(
            summary: summary,
            paceOfAging: .init(isReady: true,
                              yearsPerCalendarYear: 1.8,
                              copyText: "Prepared pace")
        )

        XCTAssertEqual(model.displayPace, 1.8)
        XCTAssertEqual(model.paceGaugePosition, 1)
    }

    func testPreparedTrendPointsAreSortedWithoutChangingValues() {
        let later = Date(timeIntervalSince1970: 200)
        let earlier = Date(timeIntervalSince1970: 100)
        let model = AtriaHealthspanDetailModel(
            summary: .building(chronologicalAge: 35, blockers: []),
            trendPoints: [
                .init(day: later, value: 32),
                .init(day: earlier, value: 34)
            ]
        )

        XCTAssertEqual(model.trendPoints.map(\.day), [earlier, later])
        XCTAssertEqual(model.trendPoints.map(\.value), [34, 32])
    }
}
