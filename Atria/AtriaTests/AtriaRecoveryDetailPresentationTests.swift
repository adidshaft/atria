import XCTest
@testable import Atria

final class AtriaRecoveryDetailPresentationTests: XCTestCase {
    func testImmatureComparisonExcludesTodayAndNamesRecentAuthority() {
        let text = AtriaRecoveryBaselineComparison.text(
            score: 73,
            monthValues: [65, 67, 68, 73],
            excludesLatest: true
        )

        XCTAssertEqual(text, "+6% vs your recent average")
    }

    func testThirtyQualifiedPriorScoresMayNameThirtyDayAuthority() {
        let previous = Array(repeating: 60.0, count: 30)
        let text = AtriaRecoveryBaselineComparison.text(
            score: 66,
            monthValues: previous + [66],
            excludesLatest: true
        )

        XCTAssertEqual(text, "+6% vs your 30-day average")
    }

    func testThirtyDayComparisonNeedsEnoughSavedScores() {
        XCTAssertNil(
            AtriaRecoveryBaselineComparison.text(
                score: 73,
                monthValues: [68, 73],
                excludesLatest: true
            )
        )
    }

    func testRecoveryDetailSelectsRingHeroWithoutChangingOtherMetrics() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaOverviewSections.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("heroStyle: .recoveryRing(score: recoveryHeroRawPercent"))
        XCTAssertTrue(source.contains("private struct AtriaRecoveryScoreHero"))
        XCTAssertTrue(source.contains("let heroStyle: AtriaMetricDetailHeroStyle"))
        XCTAssertTrue(source.contains("heroStyle: AtriaMetricDetailHeroStyle = .standard"))
    }
}
