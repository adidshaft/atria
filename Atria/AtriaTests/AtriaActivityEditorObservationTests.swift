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
        XCTAssertTrue(detail.contains("if let steps = completedWorkoutStepsText"),
                      "Activity detail must apply the completed-step provenance gate before showing steps")
        XCTAssertTrue(detail.contains("AtriaWorkoutSharePresentation.completedStepsText("))
        XCTAssertTrue(detail.contains("capturedAt: workout.workoutStepsCapturedAt"))
        XCTAssertTrue(detail.contains("workoutEndedAt: workout.end"))
        XCTAssertFalse(detail.contains("if let steps = workout.workoutSteps"),
                       "Activity detail must not expose stale or incomplete workout step evidence directly")
        XCTAssertTrue(detail.contains("steps: steps"),
                      "Activity sharing should forward only gated completed workout step evidence")
        XCTAssertTrue(detail.contains("|| isRouteTransactionInFlight)"))
        XCTAssertTrue(detail.contains("Save your changes before sharing."))
        XCTAssertTrue(detail.contains("Preparing the saved route."))
        XCTAssertTrue(detail.contains("Button(\"Delete workout\", systemImage: \"trash\", role: .destructive)"))
        XCTAssertTrue(detail.contains("guard await store.deleteConfirmedWorkout(id: workout.id) else"),
                      "Route deletion and dismissal must be gated by durable workout deletion")
        let metadataDelete = try XCTUnwrap(detail.range(of: "guard await store.deleteConfirmedWorkout(id: workout.id) else"))
        let routeDelete = try XCTUnwrap(detail.range(of: "AtriaWorkoutRouteStore.deleteAsync(workoutID: workout.id)",
                                                     range: metadataDelete.upperBound..<detail.endIndex))
        let deleteDismiss = try XCTUnwrap(detail.range(of: "dismiss()",
                                                       range: routeDelete.upperBound..<detail.endIndex))
        XCTAssertLessThan(metadataDelete.lowerBound, routeDelete.lowerBound)
        XCTAssertLessThan(routeDelete.lowerBound, deleteDismiss.lowerBound)
        XCTAssertTrue(detail.contains("switch await AtriaWorkoutRouteStore.reconcileAsync("),
                      "Atomic Save must inspect route persistence instead of dismissing unconditionally")
        XCTAssertTrue(detail.contains("loadPreparedPresentationAsync("),
                      "Route JSON, full-point map projection, and GPX preparation must stay off MainActor")
        XCTAssertFalse(detail.contains("AtriaWorkoutRouteStore.gpxURL(for:"),
                       "SwiftUI body/share projection must consume the prepared GPX URL without file I/O")
        XCTAssertTrue(detail.contains("let rollback = await store.editConfirmedWorkout("),
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
        XCTAssertTrue(add.contains("let isDetectorReview = reviewCandidateID != nil || settlingCandidateWindow != nil"))
        XCTAssertTrue(add.contains("? \"\"\n            : AtriaWorkoutActivityType.walking.rawValue"),
                      "A generic detector review must not silently become Walking")
        XCTAssertTrue(add.contains("|| activityType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty"),
                      "Saving detector evidence requires an explicit activity type")
        XCTAssertTrue(add.contains("activitySubtype = subtype"))
        XCTAssertTrue(add.contains("activityLabel: requestedLabel"))
        XCTAssertTrue(add.contains("activitySubtype: requestedSubtype"),
                      "Name, type, subtype, and window must enter one canonical Save call")
        XCTAssertTrue(add.contains("reviewSource: candidateID == nil"))
        XCTAssertTrue(add.contains("\"detected_activity_review\""))
        XCTAssertTrue(add.contains("reviewCandidateID: candidateID"),
                      "The exact reviewed detector identity must enter the atomic workout write")
        XCTAssertTrue(add.contains("onDismissCandidate: (() -> Bool)? = nil"))
        XCTAssertTrue(add.contains("Button(\"Dismiss suggestion\", systemImage: \"trash\", role: .destructive)"))
        XCTAssertTrue(add.contains("Removes this suggestion from Activity without deleting recorded strap data or day strain."))
        XCTAssertTrue(add.contains("settlingCandidateWindow: (start: Date, end: Date)? = nil"))
        XCTAssertTrue(add.contains("settlingCandidateWindow: candidateWindow"),
                      "Saving a review candidate must settle its original window inside canonical persistence")
        let addActionStart = try XCTUnwrap(add.range(of: "private func add()"))
        let addAction = String(add[addActionStart.lowerBound...])
        XCTAssertFalse(addAction.contains("onDismissCandidate?()"),
                       "Save must not perform a second UI-owned candidate dismissal write")
        XCTAssertTrue(addAction.contains("Task { @MainActor in"))
        XCTAssertTrue(addAction.contains("await store.confirmWorkoutWindowForUIAsync("),
                      "Activity review preparation must stay off MainActor for a large session store")
        XCTAssertFalse(addAction.contains("store.confirmWorkoutWindowForUI("),
                       "The Add/Review button must not run canonicalization and metric preparation synchronously")
        XCTAssertTrue(add.contains("@State private var isSaving = false"))
        XCTAssertTrue(add.contains(".interactiveDismissDisabled(isSaving)"))
        XCTAssertTrue(add.contains(".disabled(isSaving"),
                      "A second tap must not race the in-flight canonical save")
        XCTAssertTrue(add.contains("if onDismissCandidate()"),
                      "The callback remains available for the explicit Dismiss suggestion action")
        XCTAssertTrue(add.contains("settlingCandidateWindow == nil ? \"Add workout\" : \"Save\""),
                      "A reviewed detector candidate must use the same Save verb as sleep/nap reviews")
        XCTAssertTrue(add.contains("settlingCandidateWindow == nil ? \"Add workout\" : \"Review activity\""))
        XCTAssertTrue(source.contains("settlingCandidateWindow: (start: window.start"),
                      "Activity review presentation must retain the detector's original window")
        XCTAssertTrue(source.contains("store.dismissWorkoutCandidate(start: window.start"),
                      "Every Activity Center workout candidate needs a durable dismiss lifecycle")
        let historySourceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaHistorySection.swift")
        let historySource = try String(contentsOf: historySourceURL, encoding: .utf8)
        XCTAssertTrue(historySource.contains("reviewCandidateID: event.id.uuidString"),
                      "The Detections history entry must not bypass explicit detector labelling")
        XCTAssertTrue(historySource.contains("settlingCandidateWindow: (start: start, end: end)"))
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
    func testAsyncDetectedReviewSavePreservesProvenanceAndSettlesOriginalWindow() async throws {
        let store = SessionStore()
        let candidateID = "async-detected-review-" + UUID().uuidString
        let start = Date(timeIntervalSince1970: 2_279_000_000 + Double.random(in: 0..<100_000))
        let end = start.addingTimeInterval(25 * 60)

        defer {
            for workout in store.confirmedWorkouts where workout.reviewCandidateID == candidateID {
                Task { @MainActor in _ = await store.deleteConfirmedWorkout(id: workout.id) }
            }
            let unrelated = AtriaDismissedWorkoutCandidateStore.load().filter {
                !$0.overlaps(start: start, end: end)
            }
            AtriaDismissedWorkoutCandidateStore.save(unrelated)
        }

        let savedResult = await store.confirmWorkoutWindowForUIAsync(
            start: start,
            end: end,
            rest: 60,
            maxHR: 190,
            source: "manual_activity_add",
            preserveUserDeclaredActivityWithoutHeartRate: true,
            activityLabel: "Brisk walk",
            activityType: AtriaWorkoutActivityType.walking.rawValue,
            reviewSource: "detected_activity_review",
            reviewCandidateID: candidateID,
            settlingCandidateWindow: (start: start, end: end)
        )
        let saved = try XCTUnwrap(savedResult)

        XCTAssertEqual(saved.reviewSource, "detected_activity_review")
        XCTAssertEqual(saved.reviewCandidateID, candidateID)
        XCTAssertEqual(saved.activityCalibrationEvidence?.windowStart, start)
        XCTAssertEqual(saved.activityCalibrationEvidence?.windowEnd, end)
        XCTAssertTrue(AtriaDismissedWorkoutCandidateStore.load().contains {
            $0.overlaps(start: start, end: end)
        })
    }

    func testDetectedReviewProvenanceSurvivesReloadRenameAndWindowEdit() async throws {
        let store = SessionStore()
        let candidateID = "detected-review-" + UUID().uuidString
        let start = Date(timeIntervalSince1970: 2_280_000_000 + Double.random(in: 0..<100_000))
        let end = start.addingTimeInterval(30 * 60)

        defer {
            for workout in store.confirmedWorkouts where workout.reviewCandidateID == candidateID {
                Task { @MainActor in _ = await store.deleteConfirmedWorkout(id: workout.id) }
            }
            let unrelated = AtriaDismissedWorkoutCandidateStore.load().filter {
                !$0.overlaps(start: start, end: end.addingTimeInterval(10 * 60))
            }
            AtriaDismissedWorkoutCandidateStore.save(unrelated)
        }

        let savedResult = await store.confirmWorkoutWindowForUI(
            start: start,
            end: end,
            rest: 60,
            maxHR: 190,
            source: "manual_activity_add",
            preserveUserDeclaredActivityWithoutHeartRate: true,
            activityLabel: "Badminton drills",
            activityType: AtriaWorkoutActivityType.badminton.rawValue,
            reviewSource: "detected_activity_review",
            reviewCandidateID: candidateID,
            settlingCandidateWindow: (start: start, end: end)
        )
        let saved = try XCTUnwrap(savedResult)
        XCTAssertEqual(saved.reviewSource, "detected_activity_review")
        XCTAssertEqual(saved.reviewCandidateID, candidateID)
        let savedEvidence = try XCTUnwrap(saved.activityCalibrationEvidence)
        XCTAssertEqual(savedEvidence.status, "no_sensor_evidence")
        XCTAssertTrue(savedEvidence.bins.allSatisfy { $0.hrSampleCount == 0 })

        let reloaded = try JSONDecoder().decode(
            UserConfirmedWorkout.self,
            from: JSONEncoder().encode(saved)
        )
        XCTAssertEqual(reloaded.reviewSource, "detected_activity_review")
        XCTAssertEqual(reloaded.reviewCandidateID, candidateID)
        XCTAssertEqual(reloaded.activityCalibrationEvidence, savedEvidence)

        let renamedSuccessfully = await store.renameConfirmedWorkout(
            id: saved.id,
            label: "Badminton footwork"
        )
        XCTAssertTrue(renamedSuccessfully)
        let renamed = try XCTUnwrap(store.confirmedWorkouts.first { $0.id == saved.id })
        XCTAssertEqual(renamed.reviewCandidateID, candidateID)
        XCTAssertEqual(renamed.reviewSource, "detected_activity_review")
        XCTAssertEqual(renamed.activityCalibrationEvidence, savedEvidence)

        let editedResult = await store.editConfirmedWorkout(
            id: renamed.id,
            label: renamed.label,
            activityType: AtriaWorkoutActivityType.badminton.rawValue,
            start: start.addingTimeInterval(60),
            end: end.addingTimeInterval(60),
            rest: 60,
            maxHR: 190
        )
        let edited = try editedResult.get()
        XCTAssertEqual(edited.reviewCandidateID, candidateID,
                       "Changing the reviewed window must not sever its detector identity")
        XCTAssertEqual(edited.reviewSource, "detected_activity_review")
        let editedEvidence = try XCTUnwrap(edited.activityCalibrationEvidence)
        XCTAssertEqual(editedEvidence.windowStart, edited.start)
        XCTAssertEqual(editedEvidence.windowEnd, edited.end)
        XCTAssertEqual(editedEvidence.status, "no_sensor_evidence")
        XCTAssertNotEqual(editedEvidence.windowStart, savedEvidence.windowStart,
                          "A window edit must regenerate rather than retain stale features")
    }

    func testDetectorCalibrationSnapshotKeepsBoundedHRAndValidatedMotionFeatures() throws {
        let start = Date(timeIntervalSince1970: 2_281_000_000)
        let end = start.addingTimeInterval(10 * 60)
        let sessionID = UUID()
        let epochs = stride(from: 0.0, to: 10 * 60, by: 2 * 60).map { offset in
            AtriaRecoveredMotionEpoch(
                start: start.addingTimeInterval(offset),
                end: min(end, start.addingTimeInterval(offset + 2 * 60)),
                rows: 120,
                validatedRows: 120,
                stillnessRatio: 0.20,
                movementIntensity: 0.45,
                p95VectorDelta: 0.30,
                maximumGapSeconds: 1,
                measurementValidated: true,
                lowMotionQualified: false,
                reason: "test_validated_gravity"
            )
        }
        var session = SavedSession(
            id: sessionID,
            start: start,
            end: end,
            label: "calibration",
            points: stride(from: 0.0, to: 10 * 60, by: 30).map {
                SavedSession.Point(t: $0, bpm: 120 + Int($0 / 60))
            }
        )
        session.recoveredMotionEpochs = epochs

        let evidence = SessionStore.activityCalibrationEvidence(
            sessions: [session],
            start: start,
            end: end
        )

        XCTAssertEqual(evidence.status, "ready")
        XCTAssertEqual(evidence.schemaVersion, 1)
        XCTAssertEqual(evidence.sourceSessionIDs, [sessionID])
        XCTAssertEqual(evidence.bins.count, 2)
        XCTAssertTrue(evidence.bins.allSatisfy { $0.hrSampleCount > 0 })
        XCTAssertTrue(evidence.bins.allSatisfy { $0.validatedMotionCoverageFraction == 1 })
        XCTAssertEqual(evidence.motion.validatedCoverageFraction, 1)
        XCTAssertEqual(evidence.motion.provenance, AtriaRecoveredMotionEpoch.source)
    }

    func testWorkoutCandidateSaveDeleteAndManualReaddStaySingleAuthoritativeItem() async throws {
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
                Task { @MainActor in _ = await store.deleteConfirmedWorkout(id: workout.id) }
            }
            let unrelated = AtriaDismissedWorkoutCandidateStore.load().filter {
                !$0.overlaps(start: start, end: end)
            }
            AtriaDismissedWorkoutCandidateStore.save(unrelated)
        }

        let savedResult = await store.confirmWorkoutWindowForUI(
            start: start,
            end: end,
            rest: 60,
            maxHR: 190,
            source: marker,
            preserveUserDeclaredActivityWithoutHeartRate: true,
            activityLabel: "Morning walk",
            activityType: AtriaWorkoutActivityType.walking.rawValue,
            reviewSource: marker
        )
        let saved = try XCTUnwrap(savedResult)
        XCTAssertEqual(saved.label, "Morning walk")

        let resavedResult = await store.confirmWorkoutWindowForUI(
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
        )
        let resaved = try XCTUnwrap(resavedResult)
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

        let deleted = await store.deleteConfirmedWorkout(id: resaved.id)
        XCTAssertTrue(deleted)
        let readdedResult = await store.confirmWorkoutWindowForUI(
            start: start,
            end: end,
            rest: 60,
            maxHR: 190,
            source: marker,
            preserveUserDeclaredActivityWithoutHeartRate: true,
            activityType: AtriaWorkoutActivityType.walking.rawValue,
            reviewSource: marker
        )
        let readded = try XCTUnwrap(readdedResult)

        XCTAssertEqual(readded.id, saved.id)
        XCTAssertNil(readded.activityCalibrationEvidence,
                     "A manual add must never masquerade as labelled detector calibration")
        XCTAssertEqual(store.confirmedWorkouts.filter { $0.id == readded.id }, [readded])
        XCTAssertFalse(AtriaDismissedWorkoutCandidateStore.load().contains {
            $0.overlaps(start: start, end: end)
        }, "An explicit re-add must clear the prior candidate/deletion tombstone")
    }

    func testAdjustedNapCandidateSettlesOriginalWindowAndManualReaddClearsSuppression() async throws {
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
                Task { @MainActor in _ = await store.deleteConfirmedSleep(id: sleep.id) }
            }
            store.deleteSession(id: sessionID)
            let unrelated = AtriaDismissedSleepCandidateStore.load().filter {
                !$0.overlaps(start: originalStart, end: originalEnd)
            }
            AtriaDismissedSleepCandidateStore.save(unrelated)
        }

        store.add(session)
        let adjustedResult = await store.adjustSleepNight(
            originalStart: originalStart,
            originalEnd: originalEnd,
            newStart: originalStart.addingTimeInterval(5 * 60),
            newEnd: originalEnd.addingTimeInterval(-5 * 60),
            isNap: true,
            rest: 55,
            source: marker
        )
        let adjusted = try XCTUnwrap(adjustedResult)

        XCTAssertTrue(AtriaDismissedSleepCandidateStore.load().contains {
            $0.overlaps(start: originalStart, end: originalEnd)
        }, "A successful adjusted Save must settle the detector's original window")

        let deletedSleep = await store.deleteConfirmedSleep(id: adjusted.id)
        XCTAssertTrue(deletedSleep)
        let readdedResult = await store.addManualSleep(start: originalStart,
                                                       end: originalEnd,
                                                       isNap: true,
                                                       rest: 55,
                                                       source: marker)
        let readded = try XCTUnwrap(readdedResult)
        XCTAssertEqual(readded.start, originalStart)
        XCTAssertEqual(readded.end, originalEnd)
        XCTAssertFalse(AtriaDismissedSleepCandidateStore.load().contains {
            $0.overlaps(start: originalStart, end: originalEnd)
        }, "An explicit manual re-add must clear the old candidate/deletion suppression")
    }
}
