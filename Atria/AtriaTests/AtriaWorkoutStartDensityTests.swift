import XCTest

final class AtriaWorkoutStartDensityTests: XCTestCase {
    func testStartSheetUsesCompactRecentRailAndSearchableCatalog() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let source = try String(contentsOf: testsDirectory.deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaLiveWorkoutView.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "struct AtriaWorkoutStartSheet: View"))
        let end = try XCTUnwrap(source.range(of: "enum AtriaWorkoutTargetChoice",
                                             range: start.upperBound..<source.endIndex))
        let sheet = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(sheet.contains("ForEach(compactActivityTypes)"))
        XCTAssertTrue(sheet.contains("Text(\"More\")"))
        XCTAssertTrue(sheet.contains("Target lower zone"))
        XCTAssertTrue(sheet.contains("Target upper zone"))
        XCTAssertTrue(sheet.contains(".searchable(text: $activitySearch, prompt: \"Search activities\")"))
        XCTAssertTrue(sheet.contains("atria.workout.recentActivityTypes"))
        XCTAssertFalse(sheet.contains("ForEach(AtriaWorkoutActivityType.allCases) { type in"),
                       "The start sheet must not stack the complete catalog before HR-zone controls")
        XCTAssertTrue(sheet.contains(".buttonStyle(.glass)"))
        XCTAssertTrue(sheet.contains(".buttonStyle(.glassProminent)"))
    }
}
