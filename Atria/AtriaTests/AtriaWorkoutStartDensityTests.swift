import XCTest
@testable import Atria

final class AtriaWorkoutStartDensityTests: XCTestCase {
    func testRecentActivityChangesOnlyWhenStartCommits() throws {
        let suite = "AtriaWorkoutStartDensityTests.recents.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set([AtriaWorkoutActivityType.walking.rawValue],
                     forKey: AtriaWorkoutRecentActivityStore.key)

        // Browsing/selecting is sheet-local; without the Start commit the store
        // remains byte-for-byte unchanged.
        let selection = AtriaWorkoutActivityType.running
        XCTAssertEqual(selection, .running)
        XCTAssertEqual(AtriaWorkoutRecentActivityStore.activities(defaults: defaults), [.walking])

        AtriaWorkoutRecentActivityStore.recordStarted(selection, defaults: defaults)
        XCTAssertEqual(AtriaWorkoutRecentActivityStore.activities(defaults: defaults), [.running, .walking])
        AtriaWorkoutRecentActivityStore.recordStarted(.walking, defaults: defaults)
        XCTAssertEqual(AtriaWorkoutRecentActivityStore.activities(defaults: defaults), [.walking, .running])
    }

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
        XCTAssertTrue(source.contains("static let key = \"atria.workout.recentActivityTypes\""))
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
        XCTAssertTrue(sheet.contains("private var activityButtonHeight: CGFloat"))
        XCTAssertTrue(sheet.contains("dynamicTypeSize.isAccessibilitySize ? 52 : 48"),
                      "Normal activity controls should be compact while accessibility sizes retain breathing room")
        XCTAssertTrue(sheet.contains(".scrollClipDisabled()"),
                      "The horizontal rail must not crop native Liquid Glass interaction")
        XCTAssertTrue(sheet.contains(".padding(.vertical, 8)"),
                      "Glass controls need a real animation gutter inside the scroll viewport")
        XCTAssertTrue(sheet.contains(".buttonBorderShape(.capsule)"))
        XCTAssertTrue(sheet.contains("transaction.animation = nil"),
                      "Reduce Motion must suppress optional selector transitions")
        XCTAssertTrue(sheet.contains(".accessibilityValue(configuration.activityType == type ? \"Selected\" : \"Not selected\")"))
        XCTAssertTrue(sheet.contains("AtriaWorkoutRecentActivityStore.recordStarted(value.activityType)"))
        let selectionStart = try XCTUnwrap(sheet.range(of: "private func selectActivity"))
        let selection = String(sheet[selectionStart.lowerBound...])
        XCTAssertFalse(selection.contains("UserDefaults.standard.set"),
                       "Selection and cancellation must not mutate recent workout history")
    }

    func testStartSheetStacksTargetControlsAtAccessibilitySizes() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let source = try String(contentsOf: testsDirectory.deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaLiveWorkoutView.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "struct AtriaWorkoutStartSheet: View"))
        let end = try XCTUnwrap(source.range(of: "enum AtriaWorkoutTargetChoice",
                                             range: start.upperBound..<source.endIndex))
        let sheet = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(sheet.contains("@Environment(\\.dynamicTypeSize) private var dynamicTypeSize"))
        XCTAssertTrue(sheet.contains("private var targetHeader: some View"))
        XCTAssertTrue(sheet.contains("if dynamicTypeSize.isAccessibilitySize"))
        XCTAssertTrue(sheet.contains("VStack(alignment: .leading, spacing: 8)"))
        XCTAssertTrue(sheet.contains("zonePicker(title: title, selection: selection)"))
        XCTAssertTrue(sheet.contains(".frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)"),
                      "The accessibility zone menu should use a full-width 52-point row")
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
