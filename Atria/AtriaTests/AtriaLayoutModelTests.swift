import XCTest
@testable import Atria

final class AtriaLayoutModelTests: XCTestCase {
    func testVitalsSectionOrderRepairsMalformedAndDuplicateCSV() {
        let csv = "profile,unknown,hrv,profile"

        XCTAssertEqual(AtriaVitalsSection.ordered(from: csv),
                       [.profile, .hrv, .pulse, .recoveryStrain])
    }

    func testVitalsSectionDragAndBoundaryMovesStayStable() {
        let defaultCSV = AtriaVitalsSection.allCases.map(\.rawValue).joined(separator: ",")

        XCTAssertEqual(AtriaVitalsSection.draggedSection(from: AtriaVitalsSection.hrv.dragPayload), .hrv)
        XCTAssertNil(AtriaVitalsSection.draggedSection(from: "hrv"))
        XCTAssertEqual(AtriaVitalsSection.moving(.profile, before: .pulse, in: defaultCSV),
                       "profile,pulse,hrv,recoveryStrain")
        XCTAssertEqual(AtriaVitalsSection.moving(.pulse, direction: -1, in: defaultCSV), defaultCSV)
        XCTAssertEqual(AtriaVitalsSection.moving(.profile, direction: 1, in: defaultCSV), defaultCSV)
        XCTAssertEqual(AtriaVitalsSection.moving(.hrv, direction: 1, in: defaultCSV),
                       "pulse,recoveryStrain,hrv,profile")
    }

    func testTodayMetricVisibleReorderPreservesHiddenSlots() {
        let order = "recovery,respiratoryRate,hrv,stress,sleep"
        let hidden = AtriaTodayMetric.hiddenStorageValue(for: Set([AtriaTodayMetric.respiratoryRate.rawValue]))

        XCTAssertEqual(AtriaTodayMetric.moving(.stress,
                                               before: .hrv,
                                               in: order,
                                               hiddenCSV: hidden),
                       "recovery,respiratoryRate,stress,hrv,sleep")
    }

    func testTodayMetricDragPayloadRejectsRawValues() {
        XCTAssertEqual(AtriaTodayMetric.draggedMetric(from: AtriaTodayMetric.stress.dragPayload), .stress)
        XCTAssertNil(AtriaTodayMetric.draggedMetric(from: AtriaTodayMetric.stress.rawValue))
    }
}
