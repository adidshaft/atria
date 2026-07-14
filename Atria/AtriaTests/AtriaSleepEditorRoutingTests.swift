import XCTest
@testable import Atria

final class AtriaSleepEditorRoutingTests: XCTestCase {
    func testSleepEditorUsesSingleItemRouteInsteadOfBooleanSelectionRace() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaHomeView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let sessionsURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/Sessions.swift")
        let sessions = try String(contentsOf: sessionsURL, encoding: .utf8)

        XCTAssertTrue(source.contains("private struct AtriaSleepReviewSheetRoute: Identifiable"))
        XCTAssertTrue(source.contains("@State private var sleepReviewSheetRoute: AtriaSleepReviewSheetRoute?"))
        XCTAssertTrue(source.contains(".sheet(item: $sleepReviewSheetRoute) { route in"))
        XCTAssertTrue(source.contains("initialStart: route.night?.start"))
        XCTAssertTrue(source.contains("evidenceNight: route.night"),
                      "The single route must carry the exact reviewed sleep into edit/delete actions")
        XCTAssertTrue(source.contains("store.saveSleepReviewNightForUI("),
                      "Every sleep editor route must use the transactional review-save entry point")
        XCTAssertTrue(sessions.contains("cachedConfirmedSleeps.first(where: { $0.id == night.id })"),
                      "Confirmed sleep edits must resolve the exact durable record ID")
        XCTAssertTrue(sessions.contains("adjustConfirmedSleepWindow(existing: existing,"),
                      "Confirmed sleep Save must not fall back to overlap-based mutation")
        XCTAssertTrue(source.contains("onEditSleep: { night in\n                                    sleepReviewSheetRoute = AtriaSleepReviewSheetRoute(night: night)"))
        XCTAssertTrue(source.contains("onAddSleep: {\n                                    sleepReviewSheetRoute = AtriaSleepReviewSheetRoute(night: nil)"))
        XCTAssertFalse(source.contains("@State private var showSleepReviewSheet"))
        XCTAssertFalse(source.contains("@State private var sleepReviewSheetNight"))
    }

    func testActivityPreservesEveryConfirmedMainSleepWhileChoosingOneCanonicalDaySleep() {
        let calendar = Calendar(identifier: .gregorian)
        let day = Date(timeIntervalSince1970: 1_720_944_000)
        let shortStart = day.addingTimeInterval(60 * 60)
        let longStart = day.addingTimeInterval(4 * 60 * 60)
        let short = UserConfirmedSleep(id: "short-fragment",
                                       createdAt: day,
                                       start: shortStart,
                                       end: shortStart.addingTimeInterval(2 * 60 * 60),
                                       source: "manual_sleep",
                                       confidence: "confirmed",
                                       sessions: 1,
                                       samples: 10,
                                       avgHR: 60,
                                       peakHR: 70,
                                       restingHR: 55,
                                       hrv: nil,
                                       hrvWindowCount: nil,
                                       duration: 2 * 60 * 60,
                                       span: 2 * 60 * 60,
                                       reason: "test",
                                       motionSource: "test",
                                       motionValidated: true,
                                       stageSegments: nil,
                                       eventTimeZoneIdentifier: TimeZone.current.identifier)
        let long = UserConfirmedSleep(id: "major-sleep",
                                      createdAt: day,
                                      start: longStart,
                                      end: longStart.addingTimeInterval(7 * 60 * 60),
                                      source: "manual_sleep",
                                      confidence: "confirmed",
                                      sessions: 1,
                                      samples: 10,
                                      avgHR: 58,
                                      peakHR: 68,
                                      restingHR: 52,
                                      hrv: nil,
                                      hrvWindowCount: nil,
                                      duration: 7 * 60 * 60,
                                      span: 7 * 60 * 60,
                                      reason: "test",
                                      motionSource: "test",
                                      motionValidated: true,
                                      stageSegments: nil,
                                      eventTimeZoneIdentifier: TimeZone.current.identifier)

        let snapshot = SleepHistorySnapshot(rollups: [],
                                            confirmedSleeps: [long, short],
                                            calendar: calendar)
        XCTAssertEqual(snapshot.nights.first?.id, "major-sleep")
        XCTAssertEqual(snapshot.additionalMainNights.map(\.id), ["short-fragment"])
        XCTAssertEqual(Set(AtriaActivitySelectedDaySleeps.canonical(snapshot: snapshot,
                                                                    pendingReview: nil).map(\.id)),
                       Set(["major-sleep", "short-fragment"]))
    }

    func testSleepEditorSeparatesDestructiveAndSaveToolbarGlass() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaManualSleepSheet.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let toolbarStart = try XCTUnwrap(source.range(of: ".toolbar {"))
        let toolbarEnd = try XCTUnwrap(source.range(of: ".confirmationDialog(",
                                                   range: toolbarStart.upperBound..<source.endIndex))
        let toolbar = String(source[toolbarStart.lowerBound..<toolbarEnd.lowerBound])

        XCTAssertTrue(toolbar.contains("ToolbarSpacer(.fixed, placement: .topBarTrailing)"))
        XCTAssertTrue(toolbar.contains(".accessibilityLabel(\"Sleep actions\")"))
        XCTAssertTrue(toolbar.contains("Button(\"Save\")"))
        XCTAssertFalse(toolbar.contains("HStack("),
                       "Delete and Save must not be nested inside one Liquid Glass toolbar item")
    }

    func testCancelIsPresentationOnlyAndCannotDismissCandidate() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaManualSleepSheet.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let cancelStart = try XCTUnwrap(source.range(of: "private func cancelEditing()"))
        let nextSection = try XCTUnwrap(source.range(of: "/// Sensor-evidence header",
                                                     range: cancelStart.upperBound..<source.endIndex))
        let cancel = String(source[cancelStart.lowerBound..<nextSection.lowerBound])

        XCTAssertTrue(source.contains("Button(\"Cancel\", action: cancelEditing)"))
        XCTAssertTrue(cancel.contains("dismiss()"))
        XCTAssertFalse(cancel.contains("onRemove"),
                       "Cancel must never call the candidate-dismiss/delete callback")
        XCTAssertFalse(cancel.contains("onSave"),
                       "Cancel must never mutate or settle the reviewed window")
        XCTAssertFalse(source.contains(".onDisappear {\n                _ = onRemove"),
                       "Interactive or Cancel dismissal must also remain non-destructive")
    }

    func testReviewUsesTheSameExplicitDismissLanguageAsWorkoutSuggestions() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaManualSleepSheet.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("mode == .edit ? \"Delete \\(itemName)\" : \"Dismiss suggestion\""))
        XCTAssertTrue(source.contains("Dismiss this \\(itemName) suggestion?"))
        XCTAssertFalse(source.contains(": \"Not \\(itemName)\""),
                       "Sleep and nap candidates should use the same explicit Dismiss action as workout candidates")
    }
}
