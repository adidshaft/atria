import XCTest

final class AtriaWorkoutReviewCompactionTests: XCTestCase {
    func testDetectedBroadActivityDoesNotInventAReviewSubtype() throws {
        let source = try flow

        XCTAssertTrue(source.contains("_selectedSubtype = State(initialValue: nil)"))
        XCTAssertTrue(source.contains("selectedType = type\n        selectedSubtype = nil"))
        XCTAssertFalse(source.contains("_selectedSubtype = State(initialValue: suggestedType.subtypeOptions.first)"))
    }

    private var flow: String {
        get throws {
            let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            let source = try String(
                contentsOf: testsDirectory.deletingLastPathComponent()
                    .appendingPathComponent("Atria/AtriaHomeView.swift"),
                encoding: .utf8
            )
            let start = try XCTUnwrap(source.range(of: "private struct AtriaWorkoutReviewFlow: View"))
            let end = try XCTUnwrap(source.range(of: "private final class AtriaWorkoutSummaryExerciseHistoryMemo",
                                                 range: start.upperBound..<source.endIndex))
            return String(source[start.lowerBound..<end.lowerBound])
        }
    }

    func testReviewRendersOneCompactEditorSurfacePerStep() throws {
        let flow = try flow
        let body = try section(in: flow,
                               from: "var body: some View",
                               to: "private var header: some View")
        let header = try section(in: flow,
                                 from: "private var header: some View",
                                 to: "private var workoutReceiptBoard: some View")
        let time = try section(in: flow,
                               from: "private var timeStep: some View",
                               to: "private var typeStep: some View")
        let type = try section(in: flow,
                               from: "private var typeStep: some View",
                               to: "private var typeRevealHeader: some View")
        let exercises = try section(in: flow,
                                    from: "private var exerciseStep: some View",
                                    to: "private var exerciseQuickAddStrip: some View")
        let summary = try section(in: flow,
                                  from: "private var summaryStep: some View",
                                  to: "private var summaryReceiptLens: some View")

        XCTAssertFalse(body.contains("stepIndicator"))
        XCTAssertFalse(header.contains("workoutReceiptBoard"))
        XCTAssertFalse(time.contains("captureEvidenceStrip"))
        XCTAssertFalse(time.contains("reviewDecisionLens"))
        XCTAssertFalse(type.contains("suggestedTypeRunway"))
        XCTAssertFalse(type.contains("selectedTypeLens"))
        XCTAssertFalse(exercises.contains("exerciseSearchPrompt"))
        XCTAssertFalse(exercises.contains("exerciseCatalogPreview"))
        XCTAssertFalse(summary.contains("summaryReceiptLens"))

        XCTAssertTrue(time.contains("DatePicker(\"Start\""))
        XCTAssertTrue(time.contains("DatePicker(\"End\""))
        XCTAssertTrue(type.contains("ForEach(visibleWorkoutTypes)"))
        XCTAssertTrue(exercises.contains("TextField(\"Search exercises\""))
        XCTAssertTrue(summary.contains("Time, activity, and exercises save together."))
    }

    func testFinalSaveStillCommitsTheCompleteDraftAtomically() throws {
        let flow = try flow
        let action = try section(in: flow,
                                 from: "private func primaryAction()",
                                 to: "private func applyWorkoutType")

        XCTAssertTrue(flow.contains("step == .summary ? \"Save\" : \"Continue\""))
        XCTAssertFalse(flow.contains("step == .summary ? \"Save workout\" : \"Continue\""))
        XCTAssertTrue(action.contains("onSave(AtriaWorkoutReviewResult("))
        XCTAssertTrue(action.contains("start: start"))
        XCTAssertTrue(action.contains("end: end"))
        XCTAssertTrue(action.contains("activityType: selectedType.rawValue"))
        XCTAssertTrue(action.contains("activitySubtype: selectedSubtype"))
        XCTAssertTrue(action.contains("exerciseNames: selectedExerciseNames"))
        XCTAssertTrue(action.contains("strengthSets: draft.strengthSets"))
    }

    func testCompactedControlsRemainAccessible() throws {
        let flow = try flow

        XCTAssertTrue(flow.contains(".accessibilityLabel(\"Cancel workout review\")"))
        XCTAssertTrue(flow.contains(".accessibilityLabel(showsAllWorkoutTypes ? \"Show fewer workout types\""))
        XCTAssertTrue(flow.contains(".accessibilityLabel(\"Ready to save."))
        XCTAssertTrue(flow.contains("DatePicker(\"Start\""))
        XCTAssertTrue(flow.contains("DatePicker(\"End\""))
    }

    private func section(in source: String, from startToken: String, to endToken: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: startToken))
        let end = try XCTUnwrap(source.range(of: endToken,
                                             range: start.upperBound..<source.endIndex))
        return String(source[start.lowerBound..<end.lowerBound])
    }
}
