import XCTest
@testable import Atria

/// Guards the interactive half of workout completion. Durability still owns
/// dismissal, but evidence analysis, route preparation and full-store flushing
/// must remain downstream of the terminal intent and outside the End button's
/// acknowledgement frame.
final class AtriaWorkoutEndResponsivenessTests: XCTestCase {
    private func appSource(_ filename: String) throws -> String {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        return try String(
            contentsOf: testsDirectory.deletingLastPathComponent()
                .appendingPathComponent("Atria/\(filename)"),
            encoding: .utf8
        )
    }

    func testEndTapAcknowledgesAndDebouncesBeforePauseFinalizationOrAwait() throws {
        let source = try appSource("AtriaLiveWorkoutView.swift")
        let start = try XCTUnwrap(source.range(of: "private func endWorkout()"))
        let end = try XCTUnwrap(source.range(of: "private func elapsedText(",
                                             range: start.upperBound..<source.endIndex))
        let body = String(source[start.lowerBound..<end.lowerBound])

        let guardRange = try XCTUnwrap(body.range(of: "guard !isEndingWorkout else { return }"))
        let acknowledgeRange = try XCTUnwrap(body.range(of: "isEndingWorkout = true"))
        let pauseRange = try XCTUnwrap(body.range(of: "finalizePauseIfNeeded()"))
        let taskRange = try XCTUnwrap(body.range(of: "Task { @MainActor in"))
        let awaitRange = try XCTUnwrap(body.range(of: "await onStop()"))

        XCTAssertLessThan(guardRange.lowerBound, acknowledgeRange.lowerBound)
        XCTAssertLessThan(acknowledgeRange.lowerBound, pauseRange.lowerBound)
        XCTAssertLessThan(pauseRange.lowerBound, taskRange.lowerBound)
        XCTAssertLessThan(taskRange.lowerBound, awaitRange.lowerBound)
    }

    func testBothWorkoutLayoutsExposeAnImmediateDisabledSavingState() throws {
        let source = try appSource("AtriaLiveWorkoutView.swift")
        let routeStart = try XCTUnwrap(source.range(of: "private var routeWorkoutActions:"))
        let routeEnd = try XCTUnwrap(source.range(of: "private var header:",
                                                  range: routeStart.upperBound..<source.endIndex))
        let route = String(source[routeStart.lowerBound..<routeEnd.lowerBound])
        XCTAssertTrue(route.contains("if isEndingWorkout"))
        XCTAssertTrue(route.contains("Label(\"Saving…\""))
        XCTAssertTrue(route.contains(".disabled(isEndingWorkout)"))

        let standardStart = try XCTUnwrap(source.range(of: "private var stopButton:"))
        let standardEnd = try XCTUnwrap(source.range(of: "private func endWorkout()",
                                                     range: standardStart.upperBound..<source.endIndex))
        let standard = String(source[standardStart.lowerBound..<standardEnd.lowerBound])
        XCTAssertTrue(standard.contains("if isEndingWorkout"))
        XCTAssertTrue(standard.contains("Text(\"Saving workout…\")"))
        XCTAssertTrue(standard.contains(".disabled(isEndingWorkout)"))
    }

    func testEndCriticalPathHasBoundedSensorWaitsAndDefersHeavyCompletion() throws {
        let home = try appSource("AtriaHomeView.swift")
        XCTAssertTrue(home.contains("timeout: Duration = .milliseconds(250)"))
        XCTAssertTrue(home.contains("finishQueryTimeout: Duration = .milliseconds(750)"))

        let start = try XCTUnwrap(home.range(of: "private func endWorkoutSession(startedAt: Date,"))
        let end = try XCTUnwrap(home.range(of: "private func workoutShareSnapshot(",
                                           range: start.upperBound..<home.endIndex))
        let completion = String(home[start.lowerBound..<end.lowerBound])
        let durable = try XCTUnwrap(completion.range(of: "await finalIntent.persistTerminal()"))
        let dismissAuthority = try XCTUnwrap(completion.range(of: "workoutSession = nil"))
        let deferred = try XCTUnwrap(completion.range(of: "Task { @MainActor in"))
        let analysis = try XCTUnwrap(completion.range(of: "await store.confirmWorkoutWindowForUIAsync"))

        XCTAssertLessThan(durable.lowerBound, dismissAuthority.lowerBound)
        XCTAssertLessThan(dismissAuthority.lowerBound, deferred.lowerBound)
        XCTAssertLessThan(deferred.lowerBound, analysis.lowerBound)
        XCTAssertFalse(String(completion[..<deferred.lowerBound]).contains("checkpointCurrentSession"))
        XCTAssertFalse(String(completion[..<deferred.lowerBound]).contains("confirmWorkoutWindowForUIAsync"))
        XCTAssertFalse(String(completion[..<deferred.lowerBound]).contains("workoutShareSnapshot"))
        for phase in [
            "motion_boundary",
            "step_evidence",
            "terminal_intent_durable",
            "ui_release_authorized",
            "background_completion_published",
        ] {
            XCTAssertTrue(completion.contains("phase=\(phase) elapsed_ms=%d"),
                          "Physical workout logs must preserve the \(phase) latency checkpoint")
        }
    }
}
