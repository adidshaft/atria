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
        XCTAssertTrue(sheet.contains("Text(\"Heart-rate target\")"))
        XCTAssertFalse(sheet.contains("Image(systemName: type.icon).font(.callout.weight(.bold))\n                Image(systemName: type.icon)"),
                       "A compact activity button must show one activity glyph, not a duplicated pair")
        XCTAssertTrue(sheet.contains("Label(selectedZoneRangeText, systemImage: \"scope\")"))
        XCTAssertTrue(sheet.contains("configuration.upperTargetZone = lower"),
                      "The visible target must not temporarily show a reversed range")
        XCTAssertTrue(sheet.contains("configuration.lowerTargetZone = upper"),
                      "Editing either boundary must keep the target valid")
        XCTAssertTrue(sheet.contains(".searchable(text: $activitySearch, prompt: \"Search activities\")"))
        XCTAssertTrue(sheet.contains("atria.workout.recentActivityTypes"))
        XCTAssertTrue(sheet.contains("resolvedInitial.activityType = recent ?? .walking"),
                      "The visible recent/default activity must also be the value that starts")
        XCTAssertTrue(sheet.contains("([configuration.activityType] + recent + preferred)"),
                      "The actual selection must remain visible at the front of the compact rail")
        XCTAssertTrue(sheet.contains("Label(\"Start \\(configuration.activityType.rawValue)\""),
                      "The primary action should name the activity it will start")
        XCTAssertFalse(sheet.contains("ForEach(AtriaWorkoutActivityType.allCases) { type in"),
                       "The start sheet must not stack the complete catalog before HR-zone controls")
        XCTAssertTrue(sheet.contains(".buttonStyle(.glass)"))
        XCTAssertTrue(sheet.contains(".buttonStyle(.glassProminent)"))
    }

    func testAppOptsIntoFrequentLiveActivityUpdatesForWorkoutMetrics() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let info = try String(contentsOf: testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Info.plist"), encoding: .utf8)

        XCTAssertTrue(info.contains("<key>NSSupportsLiveActivities</key>"))
        XCTAssertTrue(info.contains("<key>NSSupportsLiveActivitiesFrequentUpdates</key>"),
                      "Workout HR, zone, steps and goal progress require the Live Activity frequent-update opt-in")
    }
}
