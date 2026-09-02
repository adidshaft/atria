import XCTest
@testable import Atria

/// 2026-09-02: the HRV and resting-HR detail heroes carried their 14-night
/// baseline progress as a text pill ("Learning · night 3 of 14"). The same
/// real count now rides the shared learning track under the state word,
/// the shape every other learning state uses; other metrics are untouched.
final class AtriaDetailHeroLearningTrackTests: XCTestCase {
    func testHeroTrackIsOptionalAndUsedByHRVAndRHROnly() throws {
        let overview = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaOverviewSections.swift"), encoding: .utf8)
        XCTAssertTrue(overview.contains("var heroLearning: AtriaMetricDetailHeroLearning? = nil"))
        XCTAssertEqual(overview.components(separatedBy: "heroLearning: AtriaMetricDetailHeroLearning? = nil,").count - 1, 2,
                       "both template initializers default the slot to nil")
        XCTAssertTrue(overview.contains("AtriaLearningProgressTrack(current: heroLearning.current,"))
        XCTAssertEqual(overview.components(separatedBy: "? learningNights(baseline.").count - 1, 2,
                       "HRV and RHR pass their baseline sample counts")
        // Respiratory (2026-09-02, same fire's follow-on): its band needs three
        // nights, so its track counts to the band's own minimum, not fourteen.
        XCTAssertTrue(overview.contains("? learningNights(respiratoryQualifiedNightCount,\n                                                         cap: Self.respiratoryBandMinimumNights)"))
        XCTAssertTrue(overview.contains("stats.count >= Self.respiratoryBandMinimumNights,"),
                      "the band and the track share one minimum")
        XCTAssertFalse(overview.contains("learningNightsState("),
                       "the text pill is superseded by the track")
        XCTAssertTrue(overview.contains("caption: \"\\(recorded) of \\(cap) nights\""))
        XCTAssertTrue(overview.contains("heroLearning.map { \"\\(heroValue), \\(heroState), \\($0.caption)\" }"),
                      "VoiceOver hears the count with the state")
    }
}
