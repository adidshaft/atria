import XCTest
@testable import Atria

final class AtriaStrainDetailPresentationTests: XCTestCase {
    func testWorkoutRowsDistinguishBoundedWorkoutStrainFromDayStrain() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaOverviewSections.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertTrue(source.contains("workout strain"))
        XCTAssertTrue(source.contains("Each value is this workout’s heart-rate strain. Day strain above combines your full sleep-to-sleep day."))
    }

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

    func testPartialDayStrainKeepsMeasuredNumberAndAddsLimitation() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let overviewURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaOverviewSections.swift")
        let overview = try String(contentsOf: overviewURL, encoding: .utf8)
        let valueStart = try XCTUnwrap(overview.range(of: "private var strainHeroValue: String"))
        let valueEnd = try XCTUnwrap(overview.range(of: "private var dayStrainMetricsIncomplete", range: valueStart.upperBound..<overview.endIndex))
        let valueProjection = String(overview[valueStart.lowerBound..<valueEnd.lowerBound])

        XCTAssertTrue(overview.contains("if dayStrainMetricsIncomplete { return \"Partial · sparse HR\" }"))
        XCTAssertFalse(valueProjection.contains("return \"Incomplete\""),
                       "partial evidence must not replace a real strain number")
        XCTAssertTrue(valueProjection.contains("dayStrainMetricsIncomplete ? \"≥ \\(value)\" : value"),
                      "partial cumulative strain is an observed lower bound")

        let todayURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaTodayScreen.swift")
        let today = try String(contentsOf: todayURL, encoding: .utf8)
        XCTAssertTrue(today.contains("!displayHero.strainValue.hasPrefix(\"≥\")"))
        XCTAssertTrue(today.contains("displayHero.strainConfidence.localizedCaseInsensitiveContains(\"partial\")"))
        XCTAssertTrue(today.contains("incomplete ? \"Partial · sparse HR\""))
        XCTAssertTrue(today.contains("? \"≥ \\(displayHero.strainValue)\""))
    }

    func testNoEvidenceStrainRemainsLearningInsteadOfInventedZero() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let homeURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaHomeView.swift")
        let source = try String(contentsOf: homeURL, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "var strainValue: String"))
        let end = try XCTUnwrap(source.range(of: "var strainDetail: String", range: start.upperBound..<source.endIndex))
        let projection = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(projection.contains("strainConfidence.localizedCaseInsensitiveContains(\"learning\")"))
        XCTAssertTrue(projection.contains("return \"Learning\""))
        XCTAssertTrue(projection.contains("String(format: \"%.1f\", strain)"))
        XCTAssertTrue(projection.contains("? \"≥ \\(numeric)\""))
    }
}
