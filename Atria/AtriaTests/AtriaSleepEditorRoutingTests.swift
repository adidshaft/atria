import XCTest
@testable import Atria

final class AtriaSleepEditorRoutingTests: XCTestCase {
    func testSleepEditorUsesSingleItemRouteInsteadOfBooleanSelectionRace() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaHomeView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("private struct AtriaSleepReviewSheetRoute: Identifiable"))
        XCTAssertTrue(source.contains("@State private var sleepReviewSheetRoute: AtriaSleepReviewSheetRoute?"))
        XCTAssertTrue(source.contains(".sheet(item: $sleepReviewSheetRoute) { route in"))
        XCTAssertTrue(source.contains("initialStart: route.night?.start"))
        XCTAssertTrue(source.contains("originalStart: route.night?.start"))
        XCTAssertTrue(source.contains("onEditSleep: { night in\n                                    sleepReviewSheetRoute = AtriaSleepReviewSheetRoute(night: night)"))
        XCTAssertTrue(source.contains("onAddSleep: {\n                                    sleepReviewSheetRoute = AtriaSleepReviewSheetRoute(night: nil)"))
        XCTAssertFalse(source.contains("@State private var showSleepReviewSheet"))
        XCTAssertFalse(source.contains("@State private var sleepReviewSheetNight"))
    }
}
