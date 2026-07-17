import XCTest
@testable import Atria

/// Detected-workout review improvements (2026-07-17): the multi-candidate
/// generator, visible/reversible dismissal, and the honest history surface.
final class AtriaDetectedActivityReviewTests: XCTestCase {
    private let rest = 55
    private let maxHR = 190

    /// Clean 35-minute effort at `start`: ramp 90->150 over 3 min, 28 min
    /// sustained ~150 bpm, 4 min cool-down; RR agrees with reported HR
    /// throughout (same recipe as testRealWorkoutCandidateSurvivesHardening).
    private func cleanEffortSession(start: Date, label: String) -> SavedSession {
        var points: [SavedSession.Point] = []
        var rrPoints: [SavedSession.RRPoint] = []
        var cursor: TimeInterval = 0
        func appendPhase(duration: TimeInterval, bpmAt: (TimeInterval) -> Int) {
            let phaseEnd = cursor + duration
            while cursor < phaseEnd {
                let bpm = bpmAt(cursor - (phaseEnd - duration))
                points.append(SavedSession.Point(t: cursor, bpm: bpm))
                rrPoints.append(SavedSession.RRPoint(
                    t: cursor,
                    ms: Int((60_000.0 / Double(bpm)).rounded()),
                    source: .standardHeartRateMeasurement2A37
                ))
                cursor += 2
            }
        }
        appendPhase(duration: 3 * 60) { t in 90 + Int((t / (3 * 60)) * 60) }
        appendPhase(duration: 28 * 60) { _ in 150 }
        appendPhase(duration: 4 * 60) { t in max(90, 150 - Int((t / (4 * 60)) * 60)) }
        return SavedSession(id: UUID(),
                            start: start,
                            end: start.addingTimeInterval(cursor),
                            label: label,
                            points: points,
                            rrPoints: rrPoints,
                            hrRaw2A37: points.count,
                            hrAccepted: points.count,
                            hrZero: 0,
                            hrArtifactHeld: 0,
                            hrArtifactDropped: 0,
                            hrAcceptedGaps: 0,
                            hrMaxAcceptedGap: 2)
    }

    private func confirmedWorkout(covering session: SavedSession) -> UserConfirmedWorkout {
        UserConfirmedWorkout(id: "confirmed-\(UUID().uuidString)",
                             createdAt: session.end,
                             start: session.start,
                             end: session.end,
                             label: session.label,
                             source: "test",
                             confidence: "medium",
                             sessions: 1,
                             samples: session.points.count,
                             avgHR: 140,
                             peakHR: 150,
                             p95HR: 150,
                             p99HR: 150,
                             thresholdHR: 122,
                             streamCoveragePercent: 100,
                             observedDuration: session.duration,
                             reason: "test")
    }

    // MARK: - Multi-candidate generator

    func testTwoSeparateEffortsBothSurfaceNewestFirstWhileSinglePathStillReturnsOne() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let morningRun = cleanEffortSession(start: base, label: "Morning run")
        let eveningGym = cleanEffortSession(start: base.addingTimeInterval(10 * 3600),
                                            label: "Evening gym")

        let candidates = SessionStore.makeWorkoutReviewCandidatesForCache(
            sessions: [morningRun, eveningGym],
            confirmedWorkouts: [],
            rest: rest,
            maxHR: maxHR
        )

        XCTAssertEqual(candidates.count, 2,
                       "a day with two unconfirmed efforts must offer both, not only the single best")
        XCTAssertGreaterThan(candidates[0].end, candidates[1].end, "newest window first")
        XCTAssertTrue(AtriaDismissedWorkoutCandidate(start: eveningGym.start, end: eveningGym.end)
            .overlaps(start: candidates[0].start, end: candidates[0].end),
                      "the newest offer covers the evening effort")
        XCTAssertTrue(AtriaDismissedWorkoutCandidate(start: morningRun.start, end: morningRun.end)
            .overlaps(start: candidates[1].start, end: candidates[1].end),
                      "the older offer covers the morning effort")
        for candidate in candidates {
            XCTAssertEqual(candidate.kind, .activityCandidate,
                           "an HR-only window is an activity candidate, never a found workout")
            XCTAssertGreaterThan(candidate.avgHR, 0)
            XCTAssertGreaterThan(candidate.peakHR, 0)
            XCTAssertGreaterThan(candidate.streamCoveragePercent, 0)
            XCTAssertFalse(candidate.reason.isEmpty)
            XCTAssertEqual(candidate.confidence, .medium,
                           "only detector-ready HR windows earn medium review confidence")
        }

        // The single-candidate path is unchanged: exactly one best window,
        // and it is one of the windows the list offers.
        let single = SessionStore.makeWorkoutReviewCandidateForCache(
            sessions: [morningRun, eveningGym],
            confirmedWorkouts: [],
            rest: rest,
            maxHR: maxHR
        )
        XCTAssertNotNil(single)
        XCTAssertTrue(candidates.contains { $0.id == single?.id },
                      "the list variant must agree with the single-best summary about qualifying windows")
    }

    func testConfirmedAndDismissedWindowsAreExcludedFromCandidateList() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let morningRun = cleanEffortSession(start: base, label: "Morning run")
        let eveningGym = cleanEffortSession(start: base.addingTimeInterval(10 * 3600),
                                            label: "Evening gym")
        let sessions = [morningRun, eveningGym]

        let afterConfirm = SessionStore.makeWorkoutReviewCandidatesForCache(
            sessions: sessions,
            confirmedWorkouts: [confirmedWorkout(covering: morningRun)],
            rest: rest,
            maxHR: maxHR
        )
        XCTAssertEqual(afterConfirm.map(\.end), [eveningGym.end],
                       "a confirmed window must drop out while the other effort stays offered")

        let afterDismiss = SessionStore.makeWorkoutReviewCandidatesForCache(
            sessions: sessions,
            confirmedWorkouts: [],
            dismissedCandidates: [AtriaDismissedWorkoutCandidate(start: eveningGym.start,
                                                                 end: eveningGym.end)],
            rest: rest,
            maxHR: maxHR
        )
        XCTAssertEqual(afterDismiss.map(\.end), [morningRun.end],
                       "a dismissed window must drop out while the other effort stays offered")

        let afterBoth = SessionStore.makeWorkoutReviewCandidatesForCache(
            sessions: sessions,
            confirmedWorkouts: [confirmedWorkout(covering: morningRun)],
            dismissedCandidates: [AtriaDismissedWorkoutCandidate(start: eveningGym.start,
                                                                 end: eveningGym.end)],
            rest: rest,
            maxHR: maxHR
        )
        XCTAssertTrue(afterBoth.isEmpty)
    }

    func testOverlappingWindowsCollapseToOneOfferPerPhysicalEffort() {
        // One physical effort recorded as two chunks two minutes apart: the
        // replay evaluates each chunk AND the stitched aggregates. The list
        // must offer that effort once, never as several overlapping rows.
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let chunk1 = cleanEffortSession(start: base, label: "Run chunk")
        let chunk2 = cleanEffortSession(start: chunk1.end.addingTimeInterval(2 * 60),
                                        label: "Run chunk")

        let candidates = SessionStore.makeWorkoutReviewCandidatesForCache(
            sessions: [chunk1, chunk2],
            confirmedWorkouts: [],
            rest: rest,
            maxHR: maxHR
        )

        XCTAssertFalse(candidates.isEmpty)
        for (index, lhs) in candidates.enumerated() {
            for rhs in candidates.dropFirst(index + 1) {
                let window = AtriaDismissedWorkoutCandidate(start: lhs.start, end: lhs.end)
                XCTAssertFalse(window.overlaps(start: rhs.start, end: rhs.end),
                               "offered windows must never overlap each other")
            }
        }
        XCTAssertEqual(candidates.count, 1,
                       "two chunks of one effort collapse to the single strongest window")
    }

    func testContactCompromisedWindowNeverEntersTheList() {
        // Same artifact-night construction as
        // testArtifactContactGapNightProducesNoWorkoutCandidate.
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var points: [SavedSession.Point] = []
        var cursor: TimeInterval = 0
        while cursor < 20 * 60 {
            points.append(SavedSession.Point(t: cursor, bpm: 55))
            cursor += 5
        }
        var spacingToggle = false
        let artifactEnd = cursor + 22 * 60
        while cursor < artifactEnd {
            points.append(SavedSession.Point(t: cursor, bpm: 120))
            cursor += spacingToggle ? 12 : 5
            spacingToggle.toggle()
        }
        let tailEnd = cursor + 18 * 60
        while cursor < tailEnd {
            points.append(SavedSession.Point(t: cursor, bpm: 55))
            cursor += 5
        }
        let session = SavedSession(id: UUID(),
                                   start: start,
                                   end: start.addingTimeInterval(cursor),
                                   label: "Sleep",
                                   points: points,
                                   rrPoints: nil,
                                   hrRaw2A37: 1_000,
                                   hrAccepted: 600,
                                   hrZero: 300,
                                   hrArtifactHeld: 100,
                                   hrArtifactDropped: 100,
                                   hrAcceptedGaps: 4,
                                   hrMaxAcceptedGap: 150)
        XCTAssertTrue(session.hrContactCompromised)

        let candidates = SessionStore.makeWorkoutReviewCandidatesForCache(
            sessions: [session],
            confirmedWorkouts: [],
            rest: rest,
            maxHR: maxHR
        )
        XCTAssertTrue(candidates.isEmpty,
                      "the multi-candidate list must not weaken the contact-artifact fail-closed branch")
    }

    // MARK: - Dismissal visibility + restore round trip

    @MainActor
    func testDismissRestoreRoundTripMakesTheWindowOfferableAgain() {
        let store = SessionStore()
        // Unique far-future window so parallel test state can never collide.
        let start = Date(timeIntervalSince1970: 2_270_000_000 + Double.random(in: 0..<100_000))
        let end = start.addingTimeInterval(40 * 60)
        defer {
            let unrelated = AtriaDismissedWorkoutCandidateStore.load().filter {
                !$0.overlaps(start: start, end: end)
            }
            AtriaDismissedWorkoutCandidateStore.save(unrelated)
        }

        XCTAssertTrue(store.dismissWorkoutCandidate(start: start, end: end))
        XCTAssertTrue(store.dismissedWorkoutCandidatesForUI.contains {
            $0.overlaps(start: start, end: end)
        }, "a dismissal must be visible so it can be undone")
        XCTAssertTrue(AtriaDismissedWorkoutCandidateStore.load().contains {
            $0.overlaps(start: start, end: end)
        })

        XCTAssertTrue(store.restoreDismissedWorkoutCandidate(start: start, end: end))
        XCTAssertFalse(store.dismissedWorkoutCandidatesForUI.contains {
            $0.overlaps(start: start, end: end)
        })
        XCTAssertFalse(AtriaDismissedWorkoutCandidateStore.load().contains {
            $0.overlaps(start: start, end: end)
        }, "restore must remove the durable tombstone so the generator can re-offer the window")
        XCTAssertFalse(store.restoreDismissedWorkoutCandidate(start: start, end: end),
                       "restoring an already-restored window reports no change")
    }

    @MainActor
    func testRestoreClearsHomeBannerIDSuppressionForTheSameWindow() {
        let store = SessionStore()
        let start = Date(timeIntervalSince1970: 2_280_000_000 + Double.random(in: 0..<100_000))
        let end = start.addingTimeInterval(35 * 60)
        let idsKey = "atria.workoutReview.dismissedIDs"
        let legacyIDKey = "atria.workoutReview.dismissedID"
        let defaults = UserDefaults.standard
        let previousIDs = defaults.stringArray(forKey: idsKey)
        let previousLegacy = defaults.string(forKey: legacyIDKey)
        defer {
            if let previousIDs {
                defaults.set(previousIDs, forKey: idsKey)
            } else {
                defaults.removeObject(forKey: idsKey)
            }
            if let previousLegacy {
                defaults.set(previousLegacy, forKey: legacyIDKey)
            } else {
                defaults.removeObject(forKey: legacyIDKey)
            }
            let unrelated = AtriaDismissedWorkoutCandidateStore.load().filter {
                !$0.overlaps(start: start, end: end)
            }
            AtriaDismissedWorkoutCandidateStore.save(unrelated)
        }

        let matchingID = "\(Int(start.timeIntervalSince1970.rounded()))-\(Int(end.timeIntervalSince1970.rounded()))-single_session"
        let unrelatedID = "100-200-single_session"
        defaults.set([matchingID, unrelatedID], forKey: idsKey)
        defaults.set(matchingID, forKey: legacyIDKey)

        XCTAssertTrue(store.dismissWorkoutCandidate(start: start, end: end))
        XCTAssertTrue(store.restoreDismissedWorkoutCandidate(start: start, end: end))

        XCTAssertEqual(defaults.stringArray(forKey: idsKey), [unrelatedID],
                       "restore must clear the Home banner's ID suppression for the restored window only")
        XCTAssertNil(defaults.string(forKey: legacyIDKey))
    }

    func testWorkoutReviewDismissedIDPurgeKeepsUnparsableAndUnrelatedIDs() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let end = start.addingTimeInterval(30 * 60)
        let overlapping = "\(Int(start.timeIntervalSince1970) + 60)-\(Int(end.timeIntervalSince1970) - 60)-aggregate_chunks"
        let unrelated = "\(Int(start.timeIntervalSince1970) - 7_200)-\(Int(start.timeIntervalSince1970) - 3_600)-single_session"
        let malformed = "debug-saved-workout-review"

        let kept = SessionStore.workoutReviewDismissedIDs([overlapping, unrelated, malformed],
                                                          removingOverlapWithStart: start,
                                                          end: end)
        XCTAssertEqual(kept, [unrelated, malformed],
                       "purge drops only IDs whose encoded window overlaps; unparsable IDs stay (fail closed)")
    }

    // MARK: - Honest copy + wiring source scans

    private func projectSource(_ relativePath: String) throws -> String {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    func testDetectedActivitiesHistorySurfaceKeepsHonestCopy() throws {
        let source = try projectSource("Atria/AtriaHistorySection.swift")

        let sectionStart = try XCTUnwrap(source.range(of: "struct AtriaDetectedActivitiesSection: View"))
        let sectionEnd = try XCTUnwrap(source.range(of: "// MARK: - Full history",
                                                    range: sectionStart.upperBound..<source.endIndex))
        let section = String(source[sectionStart.lowerBound..<sectionEnd.lowerBound])

        XCTAssertTrue(section.contains("Text(\"Activity candidate\")"),
                      "an HR-only window is an activity candidate, never a found workout")
        XCTAssertFalse(source.contains("Workout found"),
                       "the history surface must never claim a workout was found from HR alone")
        XCTAssertTrue(section.contains("Coverage \\(candidate.streamCoveragePercent)% · Avg \\(candidate.avgHR) · Peak \\(candidate.peakHR) bpm"),
                      "rows show the real evidence: coverage, average and peak HR")
        XCTAssertTrue(section.contains("if candidate.confidence == .medium"),
                      "medium-confidence rows must state that activity type still needs confirmation")
        XCTAssertTrue(section.contains("Low confidence: \\(Self.reasonText(candidate.reason))"),
                      "low-confidence rows must say why, using the pipeline's own reason code")
        XCTAssertTrue(section.contains(".accessibilityElement(children: .combine)"),
                      "confidence and evidence must be included in the row's accessibility output")
        for fabricated in ["strain", "calorie", "kcal", "steps"] {
            XCTAssertFalse(section.lowercased().contains(fabricated),
                           "no synthesized \(fabricated) for HR-only windows")
        }
        XCTAssertTrue(section.contains("store?.dismissWorkoutCandidate(start: candidate.start"),
                      "dismiss goes through the durable store tombstone")
        XCTAssertTrue(section.contains("store?.restoreDismissedWorkoutCandidate(start: window.start"),
                      "dismissals are visible and reversible from the same surface")
        XCTAssertTrue(section.contains("Dismissed detections"))
        XCTAssertTrue(section.contains("SessionStore.workoutReviewCandidateReviewRequestedNotification"),
                      "review routes into the existing guided flow instead of a parallel save path")

        // The projection host must keep the narrow observation contract.
        XCTAssertTrue(source.contains("store.$dashboardRevision"),
                      "the projection store observes only dashboardRevision, never the whole SessionStore")
        XCTAssertTrue(source.contains("candidates: store.workoutReviewCandidatesForUI(rest: rest,"),
                      "rendered candidates come from the fail-closed review cache accessor")
    }

    func testHomeShellRoutesHistoryReviewRequestsIntoExistingGuidedFlow() throws {
        let homeSource = try projectSource("Atria/AtriaHomeView.swift")
        XCTAssertTrue(homeSource.contains("SessionStore.workoutReviewCandidateReviewRequestedNotification"),
                      "the Home shell must listen for history review requests")
        let receiveStart = try XCTUnwrap(homeSource.range(of: "for: SessionStore.workoutReviewCandidateReviewRequestedNotification"))
        let handler = String(homeSource[receiveStart.upperBound...].prefix(700))
        XCTAssertTrue(handler.contains("guard workoutSession == nil"),
                      "review presentation must fail closed during a live workout")
        XCTAssertTrue(handler.contains("presentWorkoutReview(candidate: candidate)"),
                      "history rows open the SAME AtriaWorkoutReviewDraft flow as the Home banner")

        let healthSource = try projectSource("Atria/AtriaHealthScreen.swift")
        XCTAssertTrue(healthSource.contains("AtriaDetectedActivitiesHost(store: store"),
                      "the detected activities surface is mounted with History in the Trends scope")
    }

    func testMultiCandidateGeneratorPinsActivityCandidateKind() throws {
        let sessionsSource = try projectSource("Atria/Sessions.swift")
        XCTAssertTrue(sessionsSource.contains("nonisolated static func makeWorkoutReviewCandidatesForCache"),
                      "the list variant must exist alongside the single-best path")
        let helperStart = try XCTUnwrap(sessionsSource.range(of: "private nonisolated static func workoutReviewCandidate(fromQualifiedWindow"))
        let helper = String(sessionsSource[helperStart.lowerBound...].prefix(4_000))
        XCTAssertTrue(helper.contains("kind: .activityCandidate"),
                      "every listed window stays an activity candidate until the user confirms its type")
        XCTAssertTrue(sessionsSource.contains("func restoreDismissedWorkoutCandidate(start: Date, end: Date) -> Bool"))
        XCTAssertTrue(sessionsSource.contains("var dismissedWorkoutCandidatesForUI: [AtriaDismissedWorkoutCandidate]"))
    }
}
