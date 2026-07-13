import XCTest
@testable import Atria

final class AtriaStrainDetailPresentationTests: XCTestCase {
    func testTargetRailUsesWhoopScaleAndTwoPointTargetBand() {
        XCTAssertEqual(AtriaStrainTargetPresentation.progress(for: 10.5), 0.5, accuracy: 0.0001)
        XCTAssertEqual(AtriaStrainTargetPresentation.progress(for: 30), 1, accuracy: 0.0001)
        XCTAssertEqual(AtriaStrainTargetPresentation.targetRange(for: 12), 11...13)
        XCTAssertEqual(AtriaStrainTargetPresentation.targetRange(for: 0.5), 0...1.5)
    }

    func testStrainDetailUsesCompactTargetRailInsteadOfLargeCircularGauge() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaOverviewSections.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let detailTemplate = try XCTUnwrap(source.range(of: "private var detailTemplate: some View"))
        let start = try XCTUnwrap(
            source.range(of: "case .strain:", range: detailTemplate.upperBound..<source.endIndex)
        )
        let end = try XCTUnwrap(source.range(of: "case .sleepPerformance:", range: start.upperBound..<source.endIndex))
        let strainDetail = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(strainDetail.contains("heroStyle: .strain(score: strainHeroRawValue"))
        XCTAssertFalse(strainDetail.contains("AtriaStrainBandGauge("))
        XCTAssertTrue(source.contains("private struct AtriaStrainScoreHero"))
        XCTAssertTrue(source.contains("AtriaStrainTargetPresentation.progress(for: score)"))
    }
}
