import SwiftUI
import XCTest
@testable import Atria

final class AtriaUIDensityCompletionTests: XCTestCase {
    private func source(_ relativePath: String) throws -> String {
        let testsURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let appURL = testsURL.deletingLastPathComponent().appendingPathComponent("Atria")
        return try String(contentsOf: appURL.appendingPathComponent(relativePath), encoding: .utf8)
    }

    func testHealthMonitorGridAdaptsBeforeAccessibilitySizes() {
        XCTAssertEqual(AtriaHealthMonitorGrid.columnCount(for: .large), 3)
        XCTAssertEqual(AtriaHealthMonitorGrid.columnCount(for: .xLarge), 3)
        XCTAssertEqual(AtriaHealthMonitorGrid.columnCount(for: .xxLarge), 2)
        XCTAssertEqual(AtriaHealthMonitorGrid.columnCount(for: .xxxLarge), 2)
        XCTAssertEqual(AtriaHealthMonitorGrid.columnCount(for: .accessibility1), 1)
        XCTAssertEqual(AtriaHealthMonitorGrid.columnCount(for: .accessibility5), 1)
    }

    func testOnboardingProfileFieldsStackAtAccessibilitySizesAndKeepFullHitTargets() throws {
        let source = try source("AtriaOnboardingFlow.swift")
        let start = try XCTUnwrap(source.range(of: "private func numericProfileField"))
        let end = try XCTUnwrap(source.range(of: "private func expectationStep",
                                              range: start.upperBound..<source.endIndex))
        let fields = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(source.contains("@Environment(\\.dynamicTypeSize) private var dynamicTypeSize"))
        XCTAssertTrue(fields.contains("private func profileFieldLayout"))
        XCTAssertTrue(fields.contains("if dynamicTypeSize.isAccessibilitySize"))
        XCTAssertTrue(fields.contains("VStack(alignment: .leading"))
        XCTAssertGreaterThanOrEqual(fields.components(separatedBy: ".frame(minHeight: 44)").count - 1, 3)
        XCTAssertFalse(fields.contains(".fixedSize()"),
                       "Numeric fields must be allowed to adapt rather than preserve a narrow fixed width")
    }

    func testOptionalProfileNumberPreservesPastedDecimalsAndGrouping() {
        XCTAssertEqual(AtriaOptionalProfileNumber.parse("72.5"), 72.5, accuracy: 0.000_001)
        XCTAssertEqual(AtriaOptionalProfileNumber.parse("72,5"), 72.5, accuracy: 0.000_001)
        XCTAssertEqual(AtriaOptionalProfileNumber.parse("1,805.5 cm"), 1_805.5, accuracy: 0.000_001)
        XCTAssertEqual(AtriaOptionalProfileNumber.parse("1.805,5 cm"), 1_805.5, accuracy: 0.000_001)
        XCTAssertEqual(AtriaOptionalProfileNumber.parse("180"), 180, accuracy: 0.000_001)
        XCTAssertEqual(AtriaOptionalProfileNumber.parse("Optional"), 0, accuracy: 0.000_001)
        XCTAssertEqual(AtriaOptionalProfileNumber.displayText(for: 72.5), "72.5")
        XCTAssertEqual(AtriaOptionalProfileNumber.displayText(for: 180), "180")
        XCTAssertEqual(AtriaOptionalProfileNumber.displayText(for: 0), "")
    }

    func testWorkoutLoadTilesReturnOnlyWhenSensorLoadBecomesReadable() throws {
        XCTAssertFalse(AtriaLiveWorkoutLoadVisibility.isReadable(
            hasSensorEvidence: false,
            loadIsComplete: false
        ))
        XCTAssertFalse(AtriaLiveWorkoutLoadVisibility.isReadable(
            hasSensorEvidence: true,
            loadIsComplete: false
        ))
        XCTAssertFalse(AtriaLiveWorkoutLoadVisibility.isReadable(
            hasSensorEvidence: false,
            loadIsComplete: true
        ))
        XCTAssertTrue(AtriaLiveWorkoutLoadVisibility.isReadable(
            hasSensorEvidence: true,
            loadIsComplete: true
        ))

        let source = try source("AtriaLiveWorkoutView.swift")
        XCTAssertTrue(source.contains("if loadIsReadable {"))
        XCTAssertTrue(source.contains("compactMetric(title: metricProjection.strainHUDTitle"))
        XCTAssertTrue(source.contains("compactMetric(title: metricProjection.activeCaloriesHUDTitle"))
    }

    /// 2026-09-02 moved the stack point below the accessibility sizes: at XXL
    /// and above, two columns hyphenated "Recov-ery" — and XXXL is the largest
    /// STANDARD size, so waiting for `isAccessibilitySize` left that break in
    /// a layout plenty of people use.
    func testAlertSettingsGridStacksFromExtraExtraLargeUpward() {
        XCTAssertEqual(AtriaAlertSettingsGrid.columnCount(for: .large), 2)
        XCTAssertEqual(AtriaAlertSettingsGrid.columnCount(for: .xLarge), 2)
        XCTAssertEqual(AtriaAlertSettingsGrid.columnCount(for: .xxLarge), 1)
        XCTAssertEqual(AtriaAlertSettingsGrid.columnCount(for: .xxxLarge), 1)
        XCTAssertEqual(AtriaAlertSettingsGrid.columnCount(for: .accessibility1), 1)
        XCTAssertEqual(AtriaAlertSettingsGrid.columnCount(for: .accessibility5), 1)
    }
}
