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
        XCTAssertTrue(detail.contains("sharePresentationGate.requestPresentation()"))
        XCTAssertTrue(detail.contains("sharePresentationGate.completeRoutePreparation()"))
        XCTAssertTrue(detail.contains("if let steps = workout.workoutSteps"),
                      "Saved workout step evidence should remain visible in Activity detail")
        XCTAssertTrue(detail.contains("steps: steps"),
                      "Activity sharing should forward available workout step evidence")
        XCTAssertTrue(detail.contains(".disabled(hasUnsavedChanges || sharePresentationGate.requestIsPending)"))
        XCTAssertTrue(detail.contains("Save your changes before sharing."))
        XCTAssertTrue(detail.contains("Preparing the saved route."))
        XCTAssertTrue(detail.contains("Button(\"Delete workout\", systemImage: \"trash\", role: .destructive)"))
        XCTAssertTrue(detail.contains("guard store.deleteConfirmedWorkout(id: workout.id) else"),
                      "Route deletion and dismissal must be gated by durable workout deletion")
        let metadataDelete = try XCTUnwrap(detail.range(of: "guard store.deleteConfirmedWorkout(id: workout.id) else"))
        let routeDelete = try XCTUnwrap(detail.range(of: "AtriaWorkoutRouteStore.delete(workoutID: workout.id)",
                                                     range: metadataDelete.upperBound..<detail.endIndex))
        let deleteDismiss = try XCTUnwrap(detail.range(of: "dismiss()",
                                                       range: routeDelete.upperBound..<detail.endIndex))
        XCTAssertLessThan(metadataDelete.lowerBound, routeDelete.lowerBound)
        XCTAssertLessThan(routeDelete.lowerBound, deleteDismiss.lowerBound)
        XCTAssertTrue(detail.contains("switch AtriaWorkoutRouteStore.reconcile("),
                      "Atomic Save must inspect route persistence instead of dismissing unconditionally")
        XCTAssertTrue(detail.contains("let rollback = store.editConfirmedWorkout("),
                      "A route failure must restore the original canonical workout metadata")
        XCTAssertTrue(detail.contains("your original workout was kept unchanged"))
        XCTAssertFalse(detail.contains("ToolbarItemGroup(placement: .topBarTrailing)"),
                       "Workout actions and Save must not be fused into a nested Liquid Glass capsule")
        XCTAssertTrue(detail.contains("ToolbarSpacer(.fixed, placement: .topBarTrailing)"),
                      "A fixed toolbar spacer keeps the action menu and Save visually independent")
        XCTAssertTrue(detail.contains("Button(\"Save\", action: saveAll)"))
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
        XCTAssertTrue(add.contains("TextField(\"Activity name\", text: $activityLabel)"),
                      "Detected and manual activities must expose the same editable name field as saved workouts")
        XCTAssertTrue(add.contains("activitySubtype = subtype"))
        XCTAssertTrue(add.contains("activityLabel: activityLabel"))
        XCTAssertTrue(add.contains("activitySubtype: activitySubtype"),
                      "Name, type, subtype, and window must enter one canonical Save call")
        XCTAssertTrue(add.contains("onDismissCandidate: (() -> Bool)? = nil"))
        XCTAssertTrue(add.contains("Button(\"Dismiss suggestion\", systemImage: \"trash\", role: .destructive)"))
        XCTAssertTrue(add.contains("Removes this suggestion from Activity without deleting recorded strap data or day strain."))
        XCTAssertTrue(add.contains("settlingCandidateWindow: (start: Date, end: Date)? = nil"))
        XCTAssertTrue(add.contains("settlingCandidateWindow: settlingCandidateWindow"),
                      "Saving a review candidate must settle its original window inside canonical persistence")
        let addActionStart = try XCTUnwrap(add.range(of: "private func add()"))
        let addAction = String(add[addActionStart.lowerBound...])
        XCTAssertFalse(addAction.contains("onDismissCandidate?()"),
                       "Save must not perform a second UI-owned candidate dismissal write")
        XCTAssertTrue(add.contains("if onDismissCandidate()"),
                      "The callback remains available for the explicit Dismiss suggestion action")
        XCTAssertTrue(add.contains("settlingCandidateWindow == nil ? \"Add workout\" : \"Save\""),
                      "A reviewed detector candidate must use the same Save verb as sleep/nap reviews")
        XCTAssertTrue(add.contains("settlingCandidateWindow == nil ? \"Add workout\" : \"Review activity\""))
        XCTAssertTrue(source.contains("settlingCandidateWindow: (start: window.start"),
                      "Activity review presentation must retain the detector's original window")
        XCTAssertTrue(source.contains("store.dismissWorkoutCandidate(start: window.start"),
                      "Every Activity Center workout candidate needs a durable dismiss lifecycle")
        let homeSourceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaHomeView.swift")
        let homeSource = try String(contentsOf: homeSourceURL, encoding: .utf8)
        XCTAssertTrue(homeSource.contains("let detections = store.activityDetectionsForUI"),
                      "Dismissed generic detections must be removed from the Home Activity projection")
        XCTAssertTrue(homeSource.contains("_ = store.dismissWorkoutCandidate(start: candidate.start, end: candidate.end)"),
                      "Dismissing a home review must also dismiss its Activity Center projection")

        let sessionsSourceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/Sessions.swift")
        let sessionsSource = try String(contentsOf: sessionsSourceURL, encoding: .utf8)
        XCTAssertTrue(sessionsSource.contains("settlingCandidateWindow:"),
                      "Saving an adjusted sleep/nap review must durably settle its original detector window")
        XCTAssertTrue(sessionsSource.contains("addDismissedSleepCandidate(start: start, end: end)"),
                      "Confirming a sleep/nap candidate must prevent it from returning as actionable")
        XCTAssertTrue(sessionsSource.contains("let activityLabel: String?"))
        XCTAssertTrue(sessionsSource.contains("label: cleanedLabel ?? cleanedType ?? \"Live workout\""),
                      "Off-main confirmation must persist the reviewed name in its canonical workout write")
        XCTAssertTrue(sessionsSource.contains("workoutByMergingUserEditsAndStepEvidence"),
                      "Re-saving an already materialized candidate must update its complete user metadata atomically")
    }
}

final class AtriaWorkoutSharePresentationGateTests: XCTestCase {
    func testShareTapWaitsForRouteAndPresentsExactlyOnceAfterPreparation() {
        var gate = AtriaWorkoutSharePresentationGate()

        XCTAssertFalse(gate.requestPresentation())
        XCTAssertTrue(gate.requestIsPending)
        XCTAssertFalse(gate.routeIsPrepared)

        XCTAssertTrue(gate.completeRoutePreparation())
        XCTAssertTrue(gate.routeIsPrepared)
        XCTAssertFalse(gate.requestIsPending)
        XCTAssertFalse(gate.completeRoutePreparation(),
                       "Completing route preparation twice must not replay the retained tap")
    }

    func testSharePresentsImmediatelyOnceRouteContextIsAuthoritative() {
        var gate = AtriaWorkoutSharePresentationGate()

        XCTAssertFalse(gate.completeRoutePreparation())
        XCTAssertTrue(gate.requestPresentation())
        XCTAssertFalse(gate.requestIsPending)
    }
}

@MainActor
final class AtriaActivityLifecycleTests: XCTestCase {
    func testWorkoutCandidateSaveDeleteAndManualReaddStaySingleAuthoritativeItem() throws {
        let store = SessionStore()
        let marker = "workout-lifecycle-" + UUID().uuidString
        let start = Date(timeIntervalSince1970: 2_260_000_000 + Double.random(in: 0..<100_000))
        let end = start.addingTimeInterval(35 * 60)
        let detection = ActivityDetection(id: UUID(),
                                          kind: .activityCandidate,
                                          confidence: .medium,
                                          start: start,
                                          end: end,
                                          duration: end.timeIntervalSince(start),
                                          avgHR: 0,
                                          peakHR: 0,
                                          reason: marker)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        defer {
            for workout in store.confirmedWorkouts where workout.reviewSource == marker {
                _ = store.deleteConfirmedWorkout(id: workout.id)
            }
            let unrelated = AtriaDismissedWorkoutCandidateStore.load().filter {
                !$0.overlaps(start: start, end: end)
            }
            AtriaDismissedWorkoutCandidateStore.save(unrelated)
        }

        let saved = try XCTUnwrap(store.confirmWorkoutWindowForUI(
            start: start,
            end: end,
            rest: 60,
            maxHR: 190,
            source: marker,
            preserveUserDeclaredActivityWithoutHeartRate: true,
            activityLabel: "Morning walk",
            activityType: AtriaWorkoutActivityType.walking.rawValue,
            reviewSource: marker
        ))
        XCTAssertEqual(saved.label, "Morning walk")

        let resaved = try XCTUnwrap(store.confirmWorkoutWindowForUI(
            start: start,
            end: end,
            rest: 60,
            maxHR: 190,
            source: marker,
            preserveUserDeclaredActivityWithoutHeartRate: true,
            activityLabel: "Incline walk",
            activityType: AtriaWorkoutActivityType.cardio.rawValue,
            activitySubtype: "Incline walk",
            reviewSource: marker,
            settlingCandidateWindow: (start: start, end: end)
        ))
        XCTAssertEqual(resaved.id, saved.id)
        XCTAssertEqual(resaved.label, "Incline walk")
        XCTAssertEqual(resaved.activityType, AtriaWorkoutActivityType.cardio.rawValue)
        XCTAssertEqual(resaved.activitySubtype, "Incline walk")
        XCTAssertEqual(store.confirmedWorkouts.filter { $0.id == saved.id }, [resaved],
                       "Saving complete candidate state must update one authoritative activity")
        // The candidate-backed Add sheet settles the original detector window
        // after persisting the confirmed activity. The tombstone may remain,
        // but the saved row—not another candidate—is the authoritative item.
        XCTAssertTrue(store.dismissWorkoutCandidate(start: start, end: end))
        XCTAssertTrue(AtriaDismissedWorkoutCandidateStore.load().contains {
            $0.overlaps(start: start, end: end)
        })
        XCTAssertTrue(AtriaActivityReviewProjection.visibleDetections(
            [detection],
            workoutReview: nil,
            confirmedWorkouts: [resaved],
            selectedDay: start,
            calendar: calendar
        ).isEmpty)

        XCTAssertTrue(store.deleteConfirmedWorkout(id: resaved.id))
        let readded = try XCTUnwrap(store.confirmWorkoutWindowForUI(
            start: start,
            end: end,
            rest: 60,
            maxHR: 190,
            source: marker,
            preserveUserDeclaredActivityWithoutHeartRate: true,
            activityType: AtriaWorkoutActivityType.walking.rawValue,
            reviewSource: marker
        ))

        XCTAssertEqual(readded.id, saved.id)
        XCTAssertEqual(store.confirmedWorkouts.filter { $0.id == readded.id }, [readded])
        XCTAssertFalse(AtriaDismissedWorkoutCandidateStore.load().contains {
            $0.overlaps(start: start, end: end)
        }, "An explicit re-add must clear the prior candidate/deletion tombstone")
    }

    func testAdjustedNapCandidateSettlesOriginalWindowAndManualReaddClearsSuppression() throws {
        let store = SessionStore()
        let marker = "activity-lifecycle-" + UUID().uuidString
        let sessionID = UUID()
        let originalStart = Date(timeIntervalSince1970: 2_250_000_000 + Double.random(in: 0..<100_000))
        let originalEnd = originalStart.addingTimeInterval(40 * 60)
        let session = SavedSession(
            id: sessionID,
            start: originalStart,
            end: originalEnd,
            label: marker,
            points: stride(from: 0.0, through: 40 * 60, by: 60).map {
                SavedSession.Point(t: $0,
                                   bpm: 57 + (Int($0 / 60).isMultiple(of: 3) ? 1 : 0))
            },
            hrv: nil,
            eventTimeZoneIdentifier: "UTC"
        )

        defer {
            for sleep in store.confirmedSleeps where sleep.reason.contains(marker) {
                _ = store.deleteConfirmedSleep(id: sleep.id)
            }
            store.deleteSession(id: sessionID)
            let unrelated = AtriaDismissedSleepCandidateStore.load().filter {
                !$0.overlaps(start: originalStart, end: originalEnd)
            }
            AtriaDismissedSleepCandidateStore.save(unrelated)
        }

        store.add(session)
        let adjusted = try XCTUnwrap(store.adjustSleepNight(
            originalStart: originalStart,
            originalEnd: originalEnd,
            newStart: originalStart.addingTimeInterval(5 * 60),
            newEnd: originalEnd.addingTimeInterval(-5 * 60),
            isNap: true,
            rest: 55,
            source: marker
        ))

        XCTAssertTrue(AtriaDismissedSleepCandidateStore.load().contains {
            $0.overlaps(start: originalStart, end: originalEnd)
        }, "A successful adjusted Save must settle the detector's original window")

        XCTAssertTrue(store.deleteConfirmedSleep(id: adjusted.id))
        let readded = try XCTUnwrap(store.addManualSleep(start: originalStart,
                                                        end: originalEnd,
                                                        isNap: true,
                                                        rest: 55,
                                                        source: marker))
        XCTAssertEqual(readded.start, originalStart)
        XCTAssertEqual(readded.end, originalEnd)
        XCTAssertFalse(AtriaDismissedSleepCandidateStore.load().contains {
            $0.overlaps(start: originalStart, end: originalEnd)
        }, "An explicit manual re-add must clear the old candidate/deletion suppression")
    }
}
