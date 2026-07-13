import XCTest
@testable import Atria

final class AtriaActivityEditorObservationTests: XCTestCase {
    func testEditorSheetsKeepSessionStoreAsActionDependency() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaActivityMonitor.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        let detailStart = try XCTUnwrap(source.range(of: "private struct AtriaActivityWorkoutDetailSheet: View"))
        let addStart = try XCTUnwrap(
            source.range(of: "struct AtriaAddWorkoutSheet: View", range: detailStart.upperBound..<source.endIndex)
        )
        let detail = String(source[detailStart.lowerBound..<addStart.lowerBound])
        let add = String(source[addStart.lowerBound..<source.endIndex])

        XCTAssertTrue(detail.contains("let store: SessionStore"))
        XCTAssertFalse(detail.contains("@ObservedObject var store: SessionStore"))
        XCTAssertTrue(detail.contains("store.editConfirmedWorkout("))
        XCTAssertFalse(detail.contains("store.updateConfirmedWorkoutWindow("))
        XCTAssertFalse(detail.contains("store.renameConfirmedWorkout("))
        XCTAssertFalse(detail.contains("store.setConfirmedWorkoutActivityType("))
        let editorField = try XCTUnwrap(detail.range(of: "TextField(\"Workout name\""))
        let routeCard = try XCTUnwrap(detail.range(of: "routeCard", range: editorField.upperBound..<detail.endIndex))
        XCTAssertLessThan(editorField.lowerBound, routeCard.lowerBound,
                          "Editing controls must appear before route/analysis content")
        XCTAssertFalse(detail.contains("AtriaPanelSectionHeader(title: \"Workout\""))
        XCTAssertFalse(detail.contains("Times and stats come straight from the recorded session"))
        XCTAssertTrue(detail.contains("DisclosureGroup(isExpanded: $showsHeartRateAndRecovery)"))
        XCTAssertTrue(detail.contains(".task(id: showsHeartRateAndRecovery)"))
        XCTAssertTrue(detail.contains("guard showsHeartRateAndRecovery, !hasPreparedTrace else { return }"))
        XCTAssertTrue(detail.contains("hasPreparedTrace = true"))
        XCTAssertTrue(detail.contains("Image(systemName: \"square.and.arrow.up\")"))
        XCTAssertTrue(detail.contains("private var hasUnsavedChanges: Bool"))
        XCTAssertTrue(detail.contains(".disabled(hasUnsavedChanges)"))
        XCTAssertTrue(detail.contains("Save your changes before sharing."))
        XCTAssertTrue(detail.contains("Button(\"Delete workout\", systemImage: \"trash\", role: .destructive)"))
        XCTAssertEqual(detail.components(separatedBy: "AtriaWorkoutActivityType(rawValue: type)?.icon").count - 1,
                       1,
                       "The edit picker must show each activity's own symbol")
        XCTAssertTrue(detail.contains("AtriaWorkoutActivityType(rawValue: activityType)?.icon"),
                      "The selected edit value must retain its activity symbol")
        XCTAssertTrue(add.contains("let store: SessionStore"))
        XCTAssertFalse(add.contains("@ObservedObject var store: SessionStore"))
        XCTAssertFalse(add.contains("AtriaPanelSectionHeader(title: \"Add workout\""))
        XCTAssertFalse(add.contains("Atria builds the workout from the strap samples"))
        XCTAssertEqual(add.components(separatedBy: "AtriaWorkoutActivityType(rawValue: type)?.icon").count - 1,
                       1,
                       "The add picker must show each activity's own symbol")
        XCTAssertTrue(add.contains("AtriaWorkoutActivityType(rawValue: activityType)?.icon"),
                      "The selected add value must retain its activity symbol")
    }
}
