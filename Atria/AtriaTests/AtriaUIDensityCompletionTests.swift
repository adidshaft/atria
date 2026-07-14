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
        let end = try XCTUnwrap(source.range(of: "private func setupStepTile",
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
}
