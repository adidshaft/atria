import XCTest

/// The one-screen review (2026-09-27 rework) replaced the four-step wizard.
/// These pins keep the guarantees the wizard had.
final class AtriaWorkoutReviewCompactionTests: XCTestCase {
    private var sheet: String {
        get throws {
            let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            return try String(
                contentsOf: testsDirectory.deletingLastPathComponent()
                    .appendingPathComponent("Atria/AtriaWorkoutReviewSheet.swift"),
                encoding: .utf8
            )
        }
    }

    func testDetectedBroadActivityDoesNotInventAReviewSubtype() throws {
        let source = try sheet
        XCTAssertTrue(source.contains("_selectedSubtype = State(initialValue: nil)"))
        XCTAssertTrue(source.contains("selectedType = type\n        selectedSubtype = nil"))
    }

    func testReviewIsOneScreenWithHeartRateTimeAndActivity() throws {
        let source = try sheet
        XCTAssertFalse(source.contains("AtriaWorkoutReviewStep"), "no wizard steps")
        XCTAssertTrue(source.contains("DatePicker(\"Start\""))
        XCTAssertTrue(source.contains("DatePicker(\"End\""))
        XCTAssertTrue(source.contains("heartRateCard"))
        XCTAssertTrue(source.contains("AtriaWorkoutTypePicker(selection: typeBinding)"))
        XCTAssertTrue(source.contains("AtriaWorkoutExercisePicker(selection: $selectedExercises)"))
        XCTAssertTrue(source.contains(".searchable(text: $search, prompt: \"Search exercises\")"))
    }

    func testSaveCommitsTheCompleteDraftAtomically() throws {
        let source = try sheet
        XCTAssertTrue(source.contains("onSave(AtriaWorkoutReviewResult("))
        XCTAssertTrue(source.contains("start: start"))
        XCTAssertTrue(source.contains("end: end"))
        XCTAssertTrue(source.contains("activityType: selectedType.rawValue"))
        XCTAssertTrue(source.contains("activitySubtype: selectedSubtype"))
        XCTAssertTrue(source.contains("exerciseNames: selectedExercises"))
        XCTAssertTrue(source.contains("strengthSets: draft.strengthSets"))
        XCTAssertTrue(source.contains(".disabled(end <= start || isSaving)"))
    }

    func testAverageAndPeakComeOnlyFromHeartRateInsideTheWindow() throws {
        let source = try sheet
        XCTAssertTrue(source.contains("heartRate.filter { $0.t >= start && $0.t <= end }"))
        XCTAssertFalse(source.contains("draft.prompt.heartRate"),
                       "the detector's current reading is never shown as the window's average")
        XCTAssertFalse(source.contains("Share"), "sharing belongs to the post-save receipt")
    }

    func testControlsRemainAccessible() throws {
        let source = try sheet
        XCTAssertTrue(source.contains(".accessibilityLabel(\"Cancel workout review\")"))
        XCTAssertTrue(source.contains(".accessibilityLabel(\"Save workout\")"))
    }
}
