import XCTest

final class AtriaPostWorkoutRecapTests: XCTestCase {
    private var source: String {
        get throws {
            let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            return try String(
                contentsOf: testsDirectory.deletingLastPathComponent()
                    .appendingPathComponent("Atria/AtriaHomeView.swift"),
                encoding: .utf8
            )
        }
    }

    func testCompletionUsesAnItemDrivenCompactRecapInsteadOfAlert() throws {
        let source = try source

        XCTAssertTrue(source.contains(".sheet(item: $workoutEndNotice, onDismiss: presentQueuedWorkoutShareIfNeeded)"))
        XCTAssertTrue(source.contains("AtriaWorkoutEndRecapSheet(notice: notice)"))
        XCTAssertTrue(source.contains(".presentationDetents([.medium])"))
        XCTAssertTrue(source.contains(".presentationCornerRadius(32)"))
        XCTAssertFalse(source.contains(".alert(item: $workoutEndNotice)"))

        let recap = try section(in: source,
                                from: "private struct AtriaWorkoutEndRecapSheet: View",
                                to: "private enum HomeTab:")
        XCTAssertTrue(recap.contains(".atriaGlassCard(cornerRadius: 24, emphasis: .strong)"))
        XCTAssertTrue(recap.contains("GlassEffectContainer(spacing: 12)"))
        XCTAssertTrue(recap.contains("Label(\"Share\", systemImage: \"square.and.arrow.up\")"))
        XCTAssertLessThan(recap.components(separatedBy: "Text(notice.message)").count - 1, 2,
                          "The recap must stay glanceable instead of repeating completion copy")
    }

    func testRetainedOutcomeCannotCarryOrExposeAShareSnapshot() throws {
        let source = try source
        let notice = try section(in: source,
                                 from: "private struct AtriaWorkoutEndNotice:",
                                 to: "private struct AtriaWorkoutShareReceipt:")
        let recap = try section(in: source,
                                from: "private struct AtriaWorkoutEndRecapSheet: View",
                                to: "private enum HomeTab:")

        XCTAssertTrue(notice.contains("workout: UserConfirmedWorkout"))
        XCTAssertTrue(notice.contains("snapshot: AtriaWorkoutShareSnapshot"))
        XCTAssertTrue(notice.contains("case retained(\n                activityType:"))
        XCTAssertFalse(notice.contains("case retained(\n                snapshot:"))
        XCTAssertTrue(notice.contains("guard case .persisted(_, let snapshot, _) = outcome else { return nil }"))
        XCTAssertTrue(recap.contains("if let snapshot = notice.persistedShareSnapshot"))
        XCTAssertFalse(source.contains("retainedWorkoutShareSnapshot"))
    }

    func testShareComposerWaitsForRecapDismissal() throws {
        let source = try source
        let presentation = try section(in: source,
                                       from: ".sheet(item: $workoutEndNotice",
                                       to: ".sheet(item: $completedWorkoutShareReceipt)")
        let handoff = try section(in: source,
                                  from: "private func presentQueuedWorkoutShareIfNeeded()",
                                  to: "private func presentWorkoutReview(")

        XCTAssertTrue(presentation.contains("queuedWorkoutShareSnapshot = snapshot"))
        XCTAssertFalse(presentation.contains("completedWorkoutShareReceipt ="),
                       "The composer must not compete with the recap during dismissal")
        XCTAssertTrue(handoff.contains("guard let snapshot = queuedWorkoutShareSnapshot else { return }"))
        XCTAssertTrue(handoff.contains("queuedWorkoutShareSnapshot = nil"))
        XCTAssertTrue(handoff.contains("completedWorkoutShareReceipt = AtriaWorkoutShareReceipt(snapshot: snapshot)"))
    }

    func testRetryingRouteIsHonestButCanonicalWorkoutRemainsShareable() throws {
        let source = try source
        let completion = try section(in: source,
                                     from: "private func endWorkoutSession(startedAt: Date,",
                                     to: "private func workoutShareSnapshot(for workout:")

        XCTAssertTrue(completion.contains("workoutEndNotice = .persisted(\n                            workout: confirmed"))
        XCTAssertTrue(completion.contains("routeState: .attaching"))
        XCTAssertTrue(completion.contains("finish its route details automatically"))
        XCTAssertTrue(completion.contains("schedulePendingWorkoutRecoveryRetries()"))
        XCTAssertTrue(completion.contains("AtriaWorkoutRouteStore.savePreparedShareArtifactAsync("))
        XCTAssertTrue(completion.contains("guard preparedRoute.routeWasPersisted else"))
        XCTAssertTrue(completion.contains("routeArtifact: preparedRoute"))
        XCTAssertFalse(completion.contains("AtriaWorkoutRouteStore.gpxURL(for:"))
        XCTAssertFalse(completion.contains("AtriaWorkoutShareSnapshot.routePreviewPoints(from:"))
    }

    private func section(in source: String, from startToken: String, to endToken: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: startToken))
        let end = try XCTUnwrap(source.range(of: endToken,
                                             range: start.upperBound..<source.endIndex))
        return String(source[start.lowerBound..<end.lowerBound])
    }
}
