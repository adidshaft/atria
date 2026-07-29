import XCTest
@testable import Atria

@MainActor
final class AtriaWorkoutSaveDurabilityTests: XCTestCase {
    private func unwrap<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
        try XCTUnwrap(value, file: file, line: line)
    }

    private func assertTrue(_ value: Bool,
                            _ message: @autoclosure () -> String = "",
                            file: StaticString = #filePath,
                            line: UInt = #line) {
        XCTAssertTrue(value, message(), file: file, line: line)
    }

    func testWorkoutStepNegativeCacheInvalidatesForArchiveWindowAndStrap() {
        XCTAssertFalse(SessionStore.shouldScanWorkoutStepEvidence(
            cachedFingerprint: "archive-v1",
            currentFingerprint: "archive-v1"
        ))
        XCTAssertTrue(SessionStore.shouldScanWorkoutStepEvidence(
            cachedFingerprint: "archive-v1",
            currentFingerprint: "archive-v2"
        ))
        XCTAssertTrue(SessionStore.shouldScanWorkoutStepEvidence(
            cachedFingerprint: nil,
            currentFingerprint: "archive-v1"
        ))
        XCTAssertTrue(SessionStore.shouldScanWorkoutStepEvidence(
            cachedFingerprint: "archive-v1",
            currentFingerprint: nil
        ), "an unavailable source token must fail open and never suppress a scan")

        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let base = SessionStore.workoutStepNegativeAttemptKey(
            workoutID: "walk",
            start: start,
            end: start.addingTimeInterval(90),
            strapIdentifier: "strap-a"
        )
        XCTAssertNotEqual(
            base,
            SessionStore.workoutStepNegativeAttemptKey(
                workoutID: "walk",
                start: start.addingTimeInterval(1),
                end: start.addingTimeInterval(90),
                strapIdentifier: "strap-a"
            )
        )
        XCTAssertNotEqual(
            base,
            SessionStore.workoutStepNegativeAttemptKey(
                workoutID: "walk",
                start: start,
                end: start.addingTimeInterval(91),
                strapIdentifier: "strap-a"
            )
        )
        XCTAssertNotEqual(
            base,
            SessionStore.workoutStepNegativeAttemptKey(
                workoutID: "walk",
                start: start,
                end: start.addingTimeInterval(90),
                strapIdentifier: "strap-b"
            )
        )
        XCTAssertTrue(base.contains(
            AtriaWhoop4GravityCadenceStepModel.algorithmVersion
        ))

        let fingerprint = HistoricalArchive.makeConsumerSourceFingerprint(
            catalogGeneration: 1,
            descriptors: []
        )
        let advanced = HistoricalArchive.makeConsumerSourceFingerprint(
            catalogGeneration: 2,
            descriptors: []
        )
        XCTAssertTrue(SessionStore.shouldCacheWorkoutStepNegative(
            read: .completeNoQualifiedEvidence,
            fingerprintBefore: fingerprint,
            fingerprintAfter: fingerprint
        ))
        XCTAssertFalse(SessionStore.shouldCacheWorkoutStepNegative(
            read: .incomplete,
            fingerprintBefore: fingerprint,
            fingerprintAfter: fingerprint
        ), "an interrupted or concurrently growing scan is never conclusive")
        XCTAssertFalse(SessionStore.shouldCacheWorkoutStepNegative(
            read: .completeNoQualifiedEvidence,
            fingerprintBefore: fingerprint,
            fingerprintAfter: advanced
        ), "archive advancement during the scan invalidates its negative result")
    }

    func testCandidateBackedSaveSettlesOriginalWindowWhileManualAddKeepsReAddSemantics() async throws {
        let originalDismissals = AtriaDismissedWorkoutCandidateStore.load()
        let store = SessionStore()
        var createdWorkoutIDs: [String] = []
        defer {
            for id in createdWorkoutIDs {
                Task { @MainActor in _ = await store.deleteConfirmedWorkout(id: id) }
            }
            AtriaDismissedWorkoutCandidateStore.save(originalDismissals)
        }

        // This store intentionally retains only its 64 newest windows. Other
        // tests may already have populated the shared simulator defaults with
        // far-future fixtures, so anchor beyond the newest existing tombstone
        // instead of assuming "today + 400 days" will survive that bound.
        let newestExistingEnd = originalDismissals.map(\.end).max() ?? Date()
        let seed = newestExistingEnd.addingTimeInterval(24 * 60 * 60 + Double.random(in: 0..<10_000))
        let candidateStart = seed
        let candidateEnd = candidateStart.addingTimeInterval(30 * 60)
        let adjustedStart = candidateEnd.addingTimeInterval(2 * 60 * 60)
        let adjustedEnd = adjustedStart.addingTimeInterval(45 * 60)

        let candidateBacked = try unwrap(await store.confirmWorkoutWindowForUI(
            start: adjustedStart,
            end: adjustedEnd,
            rest: 60,
            maxHR: 190,
            source: "candidate_atomic_save_test",
            preserveUserDeclaredActivityWithoutHeartRate: true,
            activityType: AtriaWorkoutActivityType.walking.rawValue,
            settlingCandidateWindow: (start: candidateStart, end: candidateEnd)
        ))
        createdWorkoutIDs.append(candidateBacked.id)

        XCTAssertTrue(AtriaDismissedWorkoutCandidateStore.load().contains {
            $0.overlaps(start: candidateStart, end: candidateEnd)
        }, "A successful canonical save must durably settle the original detector window even after the user adjusts it")

        let manualStart = adjustedEnd.addingTimeInterval(2 * 60 * 60)
        let manualEnd = manualStart.addingTimeInterval(40 * 60)
        XCTAssertTrue(store.dismissWorkoutCandidate(start: manualStart, end: manualEnd))
        XCTAssertTrue(AtriaDismissedWorkoutCandidateStore.load().contains {
            $0.overlaps(start: manualStart, end: manualEnd)
        })

        let manual = try unwrap(await store.confirmWorkoutWindowForUI(
            start: manualStart,
            end: manualEnd,
            rest: 60,
            maxHR: 190,
            source: "manual_readd_semantics_test",
            preserveUserDeclaredActivityWithoutHeartRate: true,
            activityType: AtriaWorkoutActivityType.walking.rawValue
        ))
        createdWorkoutIDs.append(manual.id)

        XCTAssertFalse(AtriaDismissedWorkoutCandidateStore.load().contains {
            $0.overlaps(start: manualStart, end: manualEnd)
        }, "A plain manual Add must continue clearing a prior overlapping dismissal rather than treating itself as a candidate review")
    }

    func testLegacyPendingWorkoutIntentDecodesWithoutNewerAnchors() throws {
        struct LegacyIntent: Encodable {
            let startedAt: Date
            let endedAt: Date?
            let activityType: String
            let strengthSets: [LoggedSet]
            let excludedIntervals: [ExcludedInterval]
        }
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let legacy = LegacyIntent(startedAt: start,
                                  endedAt: nil,
                                  activityType: AtriaWorkoutActivityType.walking.rawValue,
                                  strengthSets: [],
                                  excludedIntervals: [])

        let decoded = try JSONDecoder().decode(AtriaPendingWorkoutIntent.self,
                                               from: JSONEncoder().encode(legacy))

        XCTAssertEqual(decoded.startedAt, start)
        XCTAssertEqual(decoded.resolvedActivityType, .walking)
        XCTAssertEqual(decoded.startingStepCount, 0)
        XCTAssertEqual(decoded.pausedStepCount, 0)
        XCTAssertNil(decoded.pauseStartedStepCount)
        XCTAssertEqual(decoded.startingDayStrain, 0)
        XCTAssertNil(decoded.targetStrain)
        XCTAssertNil(decoded.targetZone)
        XCTAssertNil(decoded.lowerTargetZone)
        XCTAssertNil(decoded.upperTargetZone)
        XCTAssertNil(decoded.completedStepCount)
        XCTAssertNil(decoded.completedStepsAreEstimated)
        XCTAssertNil(decoded.completedStepsCapturedAt)
    }

    func testLegacyConfirmedWorkoutDecodesWithoutWorkoutStepEvidence() throws {
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let workout = UserConfirmedWorkout(id: "legacy-steps",
                                           createdAt: start,
                                           start: start,
                                           end: start.addingTimeInterval(600),
                                           label: "Walking",
                                           source: "live_workout_window",
                                           confidence: "live_window_user_confirmed",
                                           sessions: 1,
                                           samples: 60,
                                           avgHR: 110,
                                           peakHR: 130,
                                           p95HR: 126,
                                           p99HR: 129,
                                           thresholdHR: 100,
                                           streamCoveragePercent: 90,
                                           observedDuration: 540,
                                           reason: "legacy")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(workout)
        ) as? [String: Any])
        object.removeValue(forKey: "workoutSteps")
        object.removeValue(forKey: "workoutStepsAreEstimated")
        object.removeValue(forKey: "workoutStepsCapturedAt")

        let decoded = try JSONDecoder().decode(
            UserConfirmedWorkout.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertNil(decoded.workoutSteps)
        XCTAssertNil(decoded.workoutStepsAreEstimated)
        XCTAssertNil(decoded.workoutStepsCapturedAt)
    }

    func testPendingRecoveryEnrichesExistingWorkoutWithExactStepEvidence() async throws {
        let store = SessionStore()
        let marker = "step-recovery-\(UUID().uuidString)"
        let start = Date(timeIntervalSince1970: 2_050_000_000)
        let end = start.addingTimeInterval(10 * 60)
        let capturedAt = end.addingTimeInterval(-1)
        let original = try unwrap(await store.confirmWorkoutWindowForUI(
            start: start,
            end: end,
            rest: 60,
            maxHR: 190,
            source: marker,
            preserveUserDeclaredActivityWithoutHeartRate: true,
            activityType: AtriaWorkoutActivityType.walking.rawValue,
            reviewSource: marker
        ))
        defer {
            for workout in store.confirmedWorkouts where workout.reviewSource == marker {
                Task { @MainActor in _ = await store.deleteConfirmedWorkout(id: workout.id) }
            }
        }

        let recovered = try unwrap(await store.confirmWorkoutWindowForUI(
            start: start,
            end: end,
            rest: 60,
            maxHR: 190,
            source: marker,
            preserveUserDeclaredActivityWithoutHeartRate: true,
            activityType: AtriaWorkoutActivityType.walking.rawValue,
            reviewSource: marker,
            workoutSteps: 842,
            workoutStepsAreEstimated: false,
            workoutStepsCapturedAt: capturedAt
        ))

        XCTAssertEqual(recovered.id, original.id)
        XCTAssertEqual(recovered.workoutSteps, 842)
        XCTAssertEqual(recovered.workoutStepsAreEstimated, false)
        XCTAssertEqual(recovered.workoutStepsCapturedAt, capturedAt)
        XCTAssertEqual(store.confirmedWorkouts.filter { $0.id == original.id }.count, 1)

        assertTrue(await store.renameConfirmedWorkout(id: recovered.id, label: "Morning walk"))
        let renamed = try XCTUnwrap(store.confirmedWorkouts.first { $0.id == recovered.id })
        XCTAssertEqual(renamed.workoutSteps, 842)
        XCTAssertEqual(renamed.workoutStepsAreEstimated, false)
        XCTAssertEqual(renamed.workoutStepsCapturedAt, capturedAt)

        let metadataEdited = try await store.editConfirmedWorkout(
            id: renamed.id,
            label: "Outdoor walk",
            activityType: AtriaWorkoutActivityType.walking.rawValue,
            start: renamed.start,
            end: renamed.end,
            rest: 60,
            maxHR: 190
        ).get()
        XCTAssertEqual(metadataEdited.workoutSteps, 842)

        let windowEdited = try await store.editConfirmedWorkout(
            id: metadataEdited.id,
            label: metadataEdited.label,
            activityType: AtriaWorkoutActivityType.walking.rawValue,
            start: metadataEdited.start.addingTimeInterval(30),
            end: metadataEdited.end.addingTimeInterval(30),
            rest: 60,
            maxHR: 190
        ).get()
        XCTAssertNil(windowEdited.workoutSteps,
                     "A time edit must not reuse a step count from the old absolute window")
        XCTAssertNil(windowEdited.workoutStepsAreEstimated)
        XCTAssertNil(windowEdited.workoutStepsCapturedAt)
    }

    func testInitiallySelectedOutdoorWorkoutStartsRouteRecorder() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let source = try String(
            contentsOf: testsDirectory.deletingLastPathComponent()
                .appendingPathComponent("Atria/AtriaHomeView.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "private func beginWorkoutSession("))
        let end = try XCTUnwrap(source.range(of: "private func persistPendingWorkoutProgress(",
                                             range: start.upperBound..<source.endIndex))
        let begin = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(begin.contains("session.activityType.supportsRouteRecording"))
        XCTAssertTrue(begin.contains("workoutRouteRecorder.start(activityType: session.activityType"))
    }

    func testDeletedWorkoutWindowTombstoneIsDurableAndBounded() throws {
        let suite = "AtriaWorkoutSaveDurabilityTests.tombstone.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let start = Date(timeIntervalSince1970: 1_900_000_000)
        let entries = (0..<70).map { offset in
            let windowStart = start.addingTimeInterval(Double(offset) * 3_600)
            return AtriaDismissedWorkoutCandidate(start: windowStart,
                                                   end: windowStart.addingTimeInterval(45 * 60))
        }

        AtriaDismissedWorkoutCandidateStore.save(entries, defaults: defaults)
        let loaded = AtriaDismissedWorkoutCandidateStore.load(defaults: defaults)

        XCTAssertEqual(loaded.count, 64)
        XCTAssertEqual(loaded.first?.start, entries.last?.start)
        XCTAssertTrue(loaded.contains { $0.overlaps(start: entries.last!.start,
                                                    end: entries.last!.end) })
    }

    func testEveryExplicitWorkoutCompletionPathSharesOnlyAfterCanonicalPersistence() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let source = try String(
            contentsOf: testsDirectory.deletingLastPathComponent()
                .appendingPathComponent("Atria/AtriaHomeView.swift"),
            encoding: .utf8
        )
        let routeStore = try String(
            contentsOf: testsDirectory.deletingLastPathComponent()
                .appendingPathComponent("Atria/AtriaWorkoutRoute.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "private func endWorkoutSession(startedAt: Date,"))
        let end = try XCTUnwrap(source.range(of: "private func workoutShareSnapshot(for workout:",
                                             range: start.upperBound..<source.endIndex))
        let completion = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertEqual(completion.components(separatedBy: "title: \"Workout safely retained\"").count - 1, 2,
                       "Sparse save failures must remain explicit retrying states")
        XCTAssertEqual(completion.components(separatedBy: "workoutEndNotice = .retained(").count - 1, 2)
        XCTAssertFalse(source.contains("retainedWorkoutShareSnapshot"),
                       "A retained intent must never look like a final shareable workout")
        XCTAssertTrue(source.contains("case persisted("))
        XCTAssertTrue(source.contains("workout: UserConfirmedWorkout"),
                      "The shareable completion state must carry canonical persistence proof")
        XCTAssertTrue(routeStore.contains("routeFileURL: includeGPX ? gpxURL(for: route) : nil"))
        XCTAssertTrue(routeStore.contains("includeGPX: savedRoute != nil"),
                      "A canonical workout whose route is attaching must not expose a non-durable GPX file")
        XCTAssertTrue(completion.contains("message: workoutCompletionMessage(confirmed)"))
        XCTAssertFalse(completion.contains("queued it for Health export"),
                       "Completion copy cannot claim an optional export happened")
        XCTAssertFalse(completion.contains("stream coverage and queued"),
                       "A saved workout should not present internal transport diagnostics as its recap")
        XCTAssertTrue(source.contains("Heart-rate details will update if more strap data arrives."))
        XCTAssertTrue(source.contains("saved and ready to share."))
    }

    func testTerminalIntentFailureKeepsWorkoutOpenAndOffersRetry() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let appDirectory = testsDirectory.deletingLastPathComponent().appendingPathComponent("Atria")
        let home = try String(contentsOf: appDirectory.appendingPathComponent("AtriaHomeView.swift"),
                              encoding: .utf8)
        let live = try String(contentsOf: appDirectory.appendingPathComponent("AtriaLiveWorkoutView.swift"),
                              encoding: .utf8)
        let start = try XCTUnwrap(home.range(of: "private func endWorkoutSession(startedAt: Date,"))
        let end = try XCTUnwrap(home.range(of: "private func workoutShareSnapshot(for workout:",
                                           range: start.upperBound..<home.endIndex))
        let completion = String(home[start.lowerBound..<end.lowerBound])
        let persistenceGuard = try XCTUnwrap(completion.range(of: "guard let finalIntent = await finalIntent.persistTerminal() else"))
        let clearActiveWorkout = try XCTUnwrap(completion.range(of: "workoutSession = nil"))
        let asynchronousCompletion = try XCTUnwrap(completion.range(of: "Task { @MainActor in"))

        XCTAssertTrue(completion.contains("excludedIntervals: [ExcludedInterval]) async -> Bool"))
        XCTAssertLessThan(persistenceGuard.lowerBound, clearActiveWorkout.lowerBound)
        XCTAssertLessThan(persistenceGuard.lowerBound, asynchronousCompletion.lowerBound)
        XCTAssertTrue(completion.contains("status=terminal_intent_save_failed"))
        XCTAssertTrue(completion.contains("return false"))
        XCTAssertTrue(completion.contains("return true"))

        XCTAssertTrue(live.contains("let onStop: () async -> Bool"))
        XCTAssertTrue(live.contains("if await onStop() {\n                dismiss()"),
                      "A successful terminal save must preserve the existing dismissal flow")
        XCTAssertTrue(live.contains("showEndPersistenceError = true"))
        XCTAssertTrue(live.contains(".alert(\"Workout still running\""))
        XCTAssertTrue(live.contains("Button(\"Try again\", action: endWorkout)"))
        XCTAssertTrue(live.contains("Button(\"Keep recording\", role: .cancel)"))
        XCTAssertTrue(live.contains("Atria couldn't save the workout yet. Try ending it again."))
    }

    func testPendingWorkoutIntentSaveFailsClosedForNonFiniteTerminalState() throws {
        let suite = "AtriaWorkoutSaveDurabilityTests.intent-failure.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let intent = AtriaPendingWorkoutIntent(
            startedAt: Date(timeIntervalSince1970: 2_000_000_000),
            endedAt: Date(timeIntervalSince1970: 2_000_000_060),
            activityType: AtriaWorkoutActivityType.walking.rawValue,
            strengthSets: [],
            excludedIntervals: [],
            targetStrain: .nan,
            startingStepCount: 0,
            startingDayStrain: 0
        )

        XCTAssertFalse(intent.save(defaults: defaults))
        XCTAssertNil(AtriaPendingWorkoutIntent.load(defaults: defaults))
    }

    func testExplicitWorkoutKeepsRRJournalDurableWithoutAllDayMode() {
        XCTAssertTrue(AtriaBLEManager.shouldPersistRRJournal(
            longWearEnabled: false,
            activeExplicitWorkout: true
        ))
        XCTAssertTrue(AtriaBLEManager.shouldPersistRRJournal(
            longWearEnabled: true,
            activeExplicitWorkout: false
        ))
        XCTAssertFalse(AtriaBLEManager.shouldPersistRRJournal(
            longWearEnabled: false,
            activeExplicitWorkout: false
        ))
    }

    func testBalancedModeStillPersistsAcceptedLiveSession() {
        XCTAssertTrue(AtriaBLEManager.shouldPersistActiveSessionJournal(
            hasLiveSamples: true,
            longWearEnabled: false,
            activeExplicitWorkout: false
        ), "Collection mode must not discard already accepted samples")
        XCTAssertFalse(AtriaBLEManager.shouldPersistActiveSessionJournal(
            hasLiveSamples: false,
            longWearEnabled: true,
            activeExplicitWorkout: true
        ))
    }

    func testBackgroundEdgeCheckpointsExplicitWorkoutMetadataAndJournal() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let source = try String(
            contentsOf: testsDirectory.deletingLastPathComponent()
                .appendingPathComponent("Atria/AtriaHomeView.swift"),
            encoding: .utf8
        )
        let backgroundStart = try XCTUnwrap(source.range(of: "if phase == .background"))
        let tail = source[backgroundStart.lowerBound...]
        let backgroundEnd = try XCTUnwrap(tail.range(of: "return"))
        let branch = String(tail[..<backgroundEnd.lowerBound])

        XCTAssertTrue(branch.contains("mirrorLiveWorkoutStateToJournal()"))
        XCTAssertTrue(branch.contains("persistPendingWorkoutProgress()"))
        XCTAssertTrue(branch.contains("flushActiveSessionJournal(reason: \"explicit_workout_scene_background\")"))
        XCTAssertTrue(branch.contains("scheduleLiveSensorWidgetPatch("))
        XCTAssertTrue(branch.contains("reason: \"scene_background_live_workout\""))
        XCTAssertTrue(branch.contains("delay: .zero"))
        XCTAssertTrue(branch.contains("WidgetSnapshotPublisher.schedulePublish(store: store,"))
        XCTAssertTrue(branch.contains("reason: \"scene_background\""))
        XCTAssertTrue(branch.contains("flushWorkoutRouteAtBackgroundBoundary()"))
        XCTAssertTrue(source.contains("beginBackgroundTask("))
        XCTAssertTrue(source.contains("workoutRouteRecorder.flushCheckpoint(reason: \"scene_background\")"))
        XCTAssertTrue(source.contains("workoutRouteBackgroundLease.end()"))

        let activeWorkoutStart = try XCTUnwrap(branch.range(of: "if workoutSession != nil"))
        let idleStart = try XCTUnwrap(
            branch.range(of: "} else {", range: activeWorkoutStart.upperBound..<branch.endIndex)
        )
        let activeWorkoutBranch = branch[activeWorkoutStart.lowerBound..<idleStart.lowerBound]
        XCTAssertFalse(activeWorkoutBranch.contains("WidgetSnapshotPublisher.schedulePublish"),
                       "An active workout background edge must not rebuild the full daily widget projection")
    }

    func testPendingWorkoutBLEContinuityIsBoundedAndRequiresOpenIntent() throws {
        let suite = "AtriaWorkoutSaveDurabilityTests.ble.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 1_783_767_620)
        var intent = AtriaPendingWorkoutIntent(startedAt: now.addingTimeInterval(-50 * 60),
                                               endedAt: nil,
                                               activityType: AtriaWorkoutActivityType.strength.rawValue,
                                               strengthSets: [],
                                               excludedIntervals: [],
                                               startingStepCount: 0,
                                               startingDayStrain: 0)
        XCTAssertTrue(intent.save(defaults: defaults))
        XCTAssertTrue(AtriaPendingWorkoutIntent.isActiveForBLEContinuity(defaults: defaults,
                                                                         now: now))

        intent.endedAt = now
        XCTAssertTrue(intent.save(defaults: defaults))
        XCTAssertFalse(AtriaPendingWorkoutIntent.isActiveForBLEContinuity(defaults: defaults,
                                                                          now: now))

        intent.endedAt = nil
        intent = AtriaPendingWorkoutIntent(startedAt: now.addingTimeInterval(-25 * 60 * 60),
                                           endedAt: nil,
                                           activityType: intent.activityType,
                                           strengthSets: [],
                                           excludedIntervals: [],
                                           startingStepCount: 0,
                                           startingDayStrain: 0)
        XCTAssertTrue(intent.save(defaults: defaults))
        XCTAssertFalse(AtriaPendingWorkoutIntent.isActiveForBLEContinuity(defaults: defaults,
                                                                          now: now))
    }

    func testExplicitSaveAcceptsSparseRealHeartRate() {
        // Reproduces the gym failure: a 50-minute user-declared window with
        // only 60 real samples after background reconnects must still persist.
        XCTAssertTrue(SessionStore.explicitWorkoutSaveIsConfirmable(sampleCount: 60,
                                                                    requestedDuration: 50 * 60))
        XCTAssertTrue(SessionStore.explicitWorkoutSaveIsConfirmable(sampleCount: 2,
                                                                    requestedDuration: 60))
        XCTAssertTrue(SessionStore.explicitWorkoutSaveIsConfirmable(sampleCount: 2,
                                                                    requestedDuration: 1),
                      "an explicitly ended short workout must not enter an impossible retry loop")
        XCTAssertFalse(SessionStore.explicitWorkoutSaveIsConfirmable(sampleCount: 1,
                                                                     requestedDuration: 50 * 60))
        XCTAssertFalse(SessionStore.explicitWorkoutSaveIsConfirmable(sampleCount: 2,
                                                                     requestedDuration: 0))
    }

    func testExplicitUserActivityCanPersistWithoutInventingSensorMetrics() async throws {
        XCTAssertTrue(SessionStore.metadataOnlyWorkoutSaveIsConfirmable(
            isExplicitUserActivity: true,
            requestedDuration: 30 * 60
        ))
        XCTAssertTrue(SessionStore.metadataOnlyWorkoutSaveIsConfirmable(
            isExplicitUserActivity: true,
            requestedDuration: 1
        ), "a user-started short activity must still materialize in Activity Center")
        XCTAssertFalse(SessionStore.metadataOnlyWorkoutSaveIsConfirmable(
            isExplicitUserActivity: true,
            requestedDuration: 0
        ))
        XCTAssertFalse(SessionStore.metadataOnlyWorkoutSaveIsConfirmable(
            isExplicitUserActivity: false,
            requestedDuration: 30 * 60
        ), "Automatic detection must never create a workout without sensor evidence")

        let store = SessionStore()
        let marker = "metadata-only-" + UUID().uuidString
        let start = Date(timeIntervalSince1970: 2_100_000_000 + Double.random(in: 0..<100_000))
        let workout = try unwrap(await store.confirmWorkoutWindowForUI(
            start: start,
            end: start.addingTimeInterval(30 * 60),
            rest: 60,
            maxHR: 190,
            source: marker,
            preserveUserDeclaredActivityWithoutHeartRate: true,
            activityType: "Strength",
            reviewSource: marker
        ))
        defer { Task { @MainActor in _ = await store.deleteConfirmedWorkout(id: workout.id) } }

        XCTAssertEqual(workout.confidence, "user_confirmed_no_hr")
        XCTAssertEqual(workout.samples, 0)
        XCTAssertEqual(workout.avgHR, 0)
        XCTAssertEqual(workout.peakHR, 0)
        XCTAssertNil(workout.strain)
        XCTAssertNil(workout.activeEnergyKilocalories)
        XCTAssertNil(workout.zoneSeconds)
        XCTAssertEqual(workout.activityType, "Strength")
    }

    func testMetadataOnlyActivityEditorSavesWindowNameAndTypeAtomically() async throws {
        let store = SessionStore()
        let marker = "metadata-only-edit-" + UUID().uuidString
        let start = Date(timeIntervalSince1970: 2_110_000_000 + Double.random(in: 0..<100_000))
        let original = try unwrap(await store.confirmWorkoutWindowForUI(
            start: start,
            end: start.addingTimeInterval(30 * 60),
            rest: 60,
            maxHR: 190,
            source: marker,
            preserveUserDeclaredActivityWithoutHeartRate: true,
            activityType: "Strength",
            reviewSource: marker
        ))
        defer {
            for workout in store.confirmedWorkouts where workout.reviewSource == marker {
                Task { @MainActor in _ = await store.deleteConfirmedWorkout(id: workout.id) }
            }
        }

        let editedStart = start.addingTimeInterval(-5 * 60)
        let editedEnd = start.addingTimeInterval(42 * 60)
        let revisionBeforeSave = store.confirmedWorkoutsRevision
        let saved = try unwrap(try await store.editConfirmedWorkout(
            id: original.id,
            label: "  Chest & Triceps  ",
            activityType: "  Weightlifting  ",
            start: editedStart,
            end: editedEnd,
            rest: 60,
            maxHR: 190
        ).get())

        XCTAssertEqual(saved.label, "Chest & Triceps")
        XCTAssertEqual(saved.activityType, "Weightlifting")
        XCTAssertEqual(saved.start, editedStart)
        XCTAssertEqual(saved.end, editedEnd)
        XCTAssertEqual(saved.createdAt, original.createdAt)
        XCTAssertEqual(saved.confidence, "user_confirmed_no_hr")
        XCTAssertEqual(saved.samples, 0)
        XCTAssertEqual(saved.avgHR, 0)
        XCTAssertNil(saved.strain)
        XCTAssertNil(saved.activeEnergyKilocalories)
        XCTAssertNil(saved.zoneSeconds)
        XCTAssertFalse(store.confirmedWorkouts.contains(where: { $0.id == original.id }))
        XCTAssertEqual(store.confirmedWorkouts.filter { $0.id == saved.id }, [saved])
        XCTAssertEqual(store.confirmedWorkoutsRevision, revisionBeforeSave + 1)
    }

    func testActivitySubtypeCommitsAtomicallyAndCannotLeakAcrossTypeChanges() async throws {
        let store = SessionStore()
        let marker = "subtype-atomicity-" + UUID().uuidString
        let start = Date(timeIntervalSince1970: 2_115_000_000 + Double.random(in: 0..<100_000))
        let original = try unwrap(await store.confirmWorkoutWindowForUI(
            start: start,
            end: start.addingTimeInterval(30 * 60),
            rest: 60,
            maxHR: 190,
            source: marker,
            preserveUserDeclaredActivityWithoutHeartRate: true,
            activityType: "Strength",
            reviewSource: marker
        ))
        defer {
            for workout in store.confirmedWorkouts where workout.reviewSource == marker {
                Task { @MainActor in _ = await store.deleteConfirmedWorkout(id: workout.id) }
            }
        }

        let revisionBeforeStyle = store.confirmedWorkoutsRevision
        let styled = try await store.editConfirmedWorkout(id: original.id,
                                                    label: "Upper body",
                                                    activityType: "Strength",
                                                    activitySubtype: "  Push  ",
                                                    start: original.start,
                                                    end: original.end,
                                                    rest: 60,
                                                    maxHR: 190).get()
        XCTAssertEqual(styled.activitySubtype, "Push")
        XCTAssertEqual(store.confirmedWorkoutsRevision, revisionBeforeStyle + 1,
                       "Subtype and other metadata must persist in one revision")

        let changedType = try await store.editConfirmedWorkout(id: styled.id,
                                                         label: styled.label,
                                                         activityType: "Dance",
                                                         activitySubtype: styled.activitySubtype,
                                                         start: styled.start,
                                                         end: styled.end,
                                                         rest: 60,
                                                         maxHR: 190).get()
        XCTAssertEqual(changedType.activityType, "Dance")
        XCTAssertNil(changedType.activitySubtype,
                     "A strength-only subtype must not survive a change to Dance")
    }

    func testExplicitWorkoutPersistsStrengthLogAndPausedIntervals() async throws {
        let store = SessionStore()
        let marker = "strength-state-" + UUID().uuidString
        let start = Date(timeIntervalSince1970: 2_120_000_000 + Double.random(in: 0..<100_000))
        let set = LoggedSet(exercise: "Bench Press",
                            weightKg: 70,
                            reps: 8,
                            rpe: 8,
                            t: start.addingTimeInterval(8 * 60))
        let pause = ExcludedInterval(start: start.addingTimeInterval(12 * 60),
                                     end: start.addingTimeInterval(14 * 60))
        let workout = try unwrap(await store.confirmWorkoutWindowForUI(
            start: start,
            end: start.addingTimeInterval(30 * 60),
            rest: 60,
            maxHR: 190,
            source: marker,
            preserveUserDeclaredActivityWithoutHeartRate: true,
            activityType: "Strength",
            strengthSets: [set],
            excludedIntervals: [pause],
            reviewSource: marker
        ))
        defer { Task { @MainActor in _ = await store.deleteConfirmedWorkout(id: workout.id) } }

        XCTAssertEqual(workout.strengthSets, [set])
        XCTAssertEqual(workout.excludedIntervals, [pause])

        let decoded = try JSONDecoder().decode(
            UserConfirmedWorkout.self,
            from: JSONEncoder().encode(workout)
        )
        XCTAssertEqual(decoded.strengthSets, [set])
        XCTAssertEqual(decoded.excludedIntervals, [pause])
    }

    func testActivityEditorPreservesStrengthLogAndPausedIntervals() async throws {
        let store = SessionStore()
        let marker = "strength-edit-" + UUID().uuidString
        let start = Date(timeIntervalSince1970: 2_130_000_000 + Double.random(in: 0..<100_000))
        let set = LoggedSet(exercise: "Cable Pushdown",
                            weightKg: 25,
                            reps: 12,
                            rpe: 7.5,
                            t: start.addingTimeInterval(10 * 60))
        let pause = ExcludedInterval(start: start.addingTimeInterval(15 * 60),
                                     end: start.addingTimeInterval(17 * 60))
        let original = try unwrap(await store.confirmWorkoutWindowForUI(
            start: start,
            end: start.addingTimeInterval(35 * 60),
            rest: 60,
            maxHR: 190,
            source: marker,
            preserveUserDeclaredActivityWithoutHeartRate: true,
            activityType: "Strength",
            strengthSets: [set],
            excludedIntervals: [pause],
            reviewSource: marker
        ))
        defer {
            for workout in store.confirmedWorkouts where workout.reviewSource == marker {
                Task { @MainActor in _ = await store.deleteConfirmedWorkout(id: workout.id) }
            }
        }

        let revisionBeforeSave = store.confirmedWorkoutsRevision
        let saved = try unwrap(try await store.editConfirmedWorkout(
            id: original.id,
            label: "Chest & Triceps",
            activityType: "Weightlifting",
            start: start.addingTimeInterval(-60),
            end: start.addingTimeInterval(36 * 60),
            rest: 60,
            maxHR: 190
        ).get())

        XCTAssertEqual(saved.strengthSets, [set])
        XCTAssertEqual(saved.excludedIntervals, [pause])
        let persisted = try XCTUnwrap(store.confirmedWorkouts.first(where: { $0.id == saved.id }))
        XCTAssertEqual(persisted.strengthSets, [set])
        XCTAssertEqual(persisted.excludedIntervals, [pause])
        XCTAssertGreaterThanOrEqual(
            store.confirmedWorkoutsRevision,
            revisionBeforeSave + 1,
            "The editor must publish its durable revision; independent launch-time strain maintenance may also publish"
        )
    }

    func testActivityEditorRederivesMetricsWithoutCountingPreservedPauseIntervals() async throws {
        let store = SessionStore()
        // Xcode repetitions reuse the simulator container. Let SessionStore
        // finish merging its durable sessions before inserting this fixture;
        // otherwise a late deferred load can add a previous repetition's
        // synthetic session while the editor is rebuilding metrics.
        await store.waitForDeferredSessionLoadIfNeeded()
        // `add` also performs the launch-time safety-backup reconciliation.
        // Do that before choosing the fixture window so a backup retained by a
        // previous repetition cannot appear after the anchor was calculated.
        store.reconcileCanonicalSessionsFromBackupIfNeeded(
            reason: "pause_aware_edit_test_setup"
        )
        let marker = "pause-aware-edit-" + UUID().uuidString
        let sessionID = UUID()
        let newestLoadedEnd = store.sessions.map(\.end).max()
            ?? Date(timeIntervalSince1970: 2_140_000_000)
        let start = max(newestLoadedEnd,
                        Date(timeIntervalSince1970: 2_140_000_000))
            .addingTimeInterval(24 * 60 * 60 + Double.random(in: 0..<10_000))
        let end = start.addingTimeInterval(20 * 60)
        let pause = ExcludedInterval(start: start.addingTimeInterval(8 * 60),
                                     end: start.addingTimeInterval(12 * 60))
        let points = stride(from: 0.0, through: 20 * 60, by: 10).map { offset in
            let date = start.addingTimeInterval(offset)
            let isPaused = date >= pause.start && date <= pause.end
            return SavedSession.Point(t: offset, bpm: isPaused ? 180 : 80)
        }
        store.add(SavedSession(id: sessionID,
                               start: start,
                               end: end,
                               label: marker,
                               points: points,
                               hrv: nil,
                               eventTimeZoneIdentifier: "UTC"))
        defer {
            for workout in store.confirmedWorkouts where workout.reviewSource == marker {
                Task { @MainActor in _ = await store.deleteConfirmedWorkout(id: workout.id) }
            }
            store.deleteSession(id: sessionID)
            // Cancel the delayed fixture write and durably persist the cleaned
            // session set before a repeated test process opens this container.
            store.flushScheduledPersistence(reason: "pause_aware_edit_test_cleanup")
        }
        let original = try unwrap(await store.confirmWorkoutWindowForUI(
            start: start,
            end: end,
            rest: 60,
            maxHR: 190,
            source: marker,
            activityType: "Strength",
            excludedIntervals: [pause],
            reviewSource: marker
        ))

        XCTAssertEqual(original.zoneSeconds?["max"] ?? 0, 0, accuracy: 0.001)
        let saved = try unwrap(try await store.editConfirmedWorkout(
            id: original.id,
            label: "Strength edited",
            activityType: "Strength",
            start: start.addingTimeInterval(30),
            end: end.addingTimeInterval(-30),
            rest: 60,
            maxHR: 190
        ).get())

        XCTAssertEqual(saved.excludedIntervals, [pause])
        XCTAssertEqual(saved.samples, 90,
                       "Paused samples must not remain in the edited workout's sample count")
        XCTAssertEqual(saved.avgHR, 80)
        XCTAssertEqual(saved.peakHR, 80)
        XCTAssertEqual(saved.p95HR, 80)
        XCTAssertEqual(saved.p99HR, 80)
        XCTAssertGreaterThanOrEqual(saved.streamCoveragePercent, 95,
                                    "Coverage must use active duration rather than the paused wall-clock span")
        XCTAssertLessThanOrEqual(saved.observedDuration, 15 * 60,
                                 "Observed duration cannot include the four-minute pause")
        XCTAssertEqual(saved.zoneSeconds?["max"] ?? 0, 0, accuracy: 0.001,
                       "A time edit must not reintroduce paused high-HR samples into workout metrics")
    }

    func testPauseAwareWorkoutProjectionDeduplicatesOverlappingJournalTimestamps() {
        let start = Date(timeIntervalSince1970: 2_141_000_000)
        let pause = ExcludedInterval(start: start.addingTimeInterval(20),
                                     end: start.addingTimeInterval(30))
        let points = [
            SavedSession.Point(t: 0, bpm: 80),
            SavedSession.Point(t: 10, bpm: 81),
            // Persisted session + final journal flush can contain this same
            // absolute observation. Canonical-source order makes 82 win.
            SavedSession.Point(t: 40, bpm: 82),
            SavedSession.Point(t: 40, bpm: 180),
            SavedSession.Point(t: 25, bpm: 190),
            SavedSession.Point(t: 50, bpm: 83)
        ]

        let projected = SessionStore.activeWorkoutPointProjection(
            points: points,
            windowStart: start,
            windowEnd: start.addingTimeInterval(60),
            excludedIntervals: [pause]
        )

        XCTAssertEqual(projected.activeDuration, 50, accuracy: 0.001)
        XCTAssertEqual(projected.points.count, 4)
        XCTAssertEqual(projected.points.map(\.bpm), [80, 81, 82, 83])
        XCTAssertEqual(projected.points.map(\.t), [0, 10, 30, 40])
    }

    func testPendingWorkoutIntentRoundTripsAndClears() throws {
        let suite = "AtriaWorkoutSaveDurabilityTests.intent.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let start = Date(timeIntervalSince1970: 1_783_767_620)
        let end = start.addingTimeInterval(50 * 60)
        let pause = start.addingTimeInterval(20 * 60)
        let intent = AtriaPendingWorkoutIntent(startedAt: start,
                                               endedAt: end,
                                               activityType: AtriaWorkoutActivityType.strength.rawValue,
                                               strengthSets: [],
                                               excludedIntervals: [],
                                               pauseStartedAt: pause,
                                               targetStrain: 13.5,
                                               startingStepCount: 120,
                                               pausedStepCount: 34,
                                               pauseStartedStepCount: 612,
                                               completedStepCount: 458,
                                               completedStepsAreEstimated: false,
                                               completedStepsCapturedAt: end.addingTimeInterval(-1),
                                               startingDayStrain: 4.2)

        XCTAssertTrue(intent.save(defaults: defaults))
        XCTAssertEqual(AtriaPendingWorkoutIntent.load(defaults: defaults), intent)
        AtriaPendingWorkoutIntent.clear(defaults: defaults)
        XCTAssertNil(AtriaPendingWorkoutIntent.load(defaults: defaults))
    }

    func testPendingWorkoutAtomicStoreSurvivesColdReloadAndWritesOffMain() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-intent-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let intent = pendingAtomicIntent(start: start)
        let writer = AtriaPendingWorkoutIntentStore(directoryURL: directory,
                                                    legacyDefaults: nil)

        let created = await writer.createIfAbsent(intent)
        XCTAssertTrue(created)
        XCTAssertFalse(writer.lastPersistenceWasOnMainThread)
        XCTAssertEqual(writer.snapshot, intent)

        // A fresh instance has no in-memory/defaults state: the atomic file is
        // the only evidence available after a process termination.
        let cold = AtriaPendingWorkoutIntentStore(directoryURL: directory,
                                                  legacyDefaults: nil)
        let prepared = await cold.prepare()
        XCTAssertTrue(prepared)
        XCTAssertEqual(cold.snapshot, intent)
    }

    func testColdPendingWorkoutHydrationConservativelyProtectsBLEContinuity() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-cold-policy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AtriaPendingWorkoutIntentStore(directoryURL: directory,
                                                   legacyDefaults: nil)
        XCTAssertFalse(store.isPrepared)
        XCTAssertTrue(store.isActiveForBLEContinuity(),
                      "Unknown cold state must not downgrade BLE before disk hydration")
        let prepared = await store.prepare()
        XCTAssertTrue(prepared)
        XCTAssertFalse(store.isActiveForBLEContinuity(),
                       "A hydrated empty authority can safely leave workout continuity")
    }

    func testPendingWorkoutAtomicStoreTerminalRejectsLateProgress() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-terminal-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let start = Date(timeIntervalSince1970: 2_000_100_000)
        let original = pendingAtomicIntent(start: start)
        let store = AtriaPendingWorkoutIntentStore(directoryURL: directory,
                                                   legacyDefaults: nil)
        let created = await store.createIfAbsent(original)
        XCTAssertTrue(created)

        var terminal = original
        terminal.endedAt = start.addingTimeInterval(600)
        terminal.persistenceRevision = .max
        let terminalSaved = await store.persistTerminal(terminal)
        XCTAssertNotNil(terminalSaved)
        var lateProgress = original
        lateProgress.targetStrain = 12
        lateProgress.persistenceRevision = 1
        let lateSaved = await store.persistProgress(lateProgress)
        XCTAssertFalse(lateSaved)
        XCTAssertEqual(store.snapshot, terminal)
    }

    func testPendingWorkoutQueuedProgressCannotOverwriteTerminalAuthority() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-terminal-queued-progress-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let start = Date(timeIntervalSince1970: 2_000_125_000)
        let original = pendingAtomicIntent(start: start)
        let store = AtriaPendingWorkoutIntentStore(directoryURL: directory,
                                                   legacyDefaults: nil)
        let created = await store.createIfAbsent(original)
        XCTAssertTrue(created)

        // Exercise the coalesced UI path, rather than calling persistProgress
        // after End has already returned. Depending on which serial operation
        // begins first, this checkpoint is either cancelled or completes just
        // before End; in both cases it must never survive the terminal write.
        var queuedProgress = original
        queuedProgress.targetStrain = 12
        queuedProgress.persistenceRevision = 1
        let progressCompletion = expectation(description: "queued progress completed")
        store.enqueueProgress(queuedProgress) { _ in
            progressCompletion.fulfill()
        }

        var terminal = original
        terminal.endedAt = start.addingTimeInterval(600)
        terminal.activityType = AtriaWorkoutActivityType.walking.rawValue
        terminal.persistenceRevision = .max
        let savedTerminal = await store.persistTerminal(terminal)
        XCTAssertEqual(savedTerminal, terminal)

        await fulfillment(of: [progressCompletion], timeout: 1)
        XCTAssertEqual(store.snapshot, terminal,
                       "a queued checkpoint must not reopen or overwrite a saved terminal workout")
    }

    func testPendingWorkoutAtomicStoreTerminalRebasesOnNewestCanonicalProgress() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-terminal-race-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let start = Date(timeIntervalSince1970: 2_000_150_000)
        let original = pendingAtomicIntent(start: start)
        let store = AtriaPendingWorkoutIntentStore(directoryURL: directory,
                                                   legacyDefaults: nil)
        let created = await store.createIfAbsent(original)
        XCTAssertTrue(created)
        var newest = original
        newest.persistenceRevision = 4
        newest.pauseStartedAt = start.addingTimeInterval(300)
        newest.excludedIntervals = [ExcludedInterval(start: start.addingTimeInterval(100),
                                                     end: start.addingTimeInterval(150))]
        let newestSaved = await store.persistProgress(newest)
        XCTAssertTrue(newestSaved)

        // This stale Home capture was made before the Lock Screen pause above.
        var staleTerminal = original
        staleTerminal.endedAt = start.addingTimeInterval(600)
        staleTerminal.completedStepCount = 88
        staleTerminal.activityType = AtriaWorkoutActivityType.strength.rawValue
        staleTerminal.strengthSets = [LoggedSet(exercise: "Bench press",
                                               weightKg: 80,
                                               reps: 8,
                                               rpe: 8,
                                               t: start.addingTimeInterval(500))]
        staleTerminal.persistenceRevision = .max
        let committedValue = await store.persistTerminal(staleTerminal)
        let committed = try XCTUnwrap(committedValue)
        XCTAssertEqual(committed.pauseStartedAt, newest.pauseStartedAt)
        XCTAssertEqual(committed.excludedIntervals, newest.excludedIntervals)
        XCTAssertFalse(committed.stepAccountingIsComplete)
        XCTAssertNil(committed.completedStepCount,
                     "A terminal total derived before the canonical pause must fail closed")
        XCTAssertNil(committed.completedStepsAreEstimated)
        XCTAssertNil(committed.completedStepsCapturedAt)
        XCTAssertEqual(committed.activityType, staleTerminal.activityType)
        XCTAssertEqual(committed.strengthSets, staleTerminal.strengthSets)
        XCTAssertEqual(committed.endedAt, staleTerminal.endedAt)
        XCTAssertEqual(store.snapshot, committed)
    }

    func testPendingWorkoutAtomicStoreOldClearCannotDeleteNewerState() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-cas-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = pendingAtomicIntent(start: Date(timeIntervalSince1970: 2_000_200_000))
        var updated = original
        updated.targetStrain = 8
        let store = AtriaPendingWorkoutIntentStore(directoryURL: directory,
                                                   legacyDefaults: nil)
        let created = await store.createIfAbsent(original)
        XCTAssertTrue(created)
        updated.persistenceRevision = 1
        let replaced = await store.replace(expected: original, with: updated)
        XCTAssertTrue(replaced)
        let oldCleared = await store.clearIfUnchanged(original)
        XCTAssertFalse(oldCleared)
        XCTAssertEqual(store.snapshot, updated)
        let updatedCleared = await store.clearIfUnchanged(updated)
        XCTAssertTrue(updatedCleared)
        XCTAssertNil(store.snapshot)
    }

    func testPendingWorkoutAtomicStoreDelayedOlderProgressCannotRevertNewerOpenProgress() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-order-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = pendingAtomicIntent(start: Date(timeIntervalSince1970: 2_000_250_000))
        var older = original
        older.persistenceRevision = 1
        older.targetStrain = 6
        var newer = original
        newer.persistenceRevision = 2
        newer.targetStrain = 12
        let store = AtriaPendingWorkoutIntentStore(directoryURL: directory,
                                                   legacyDefaults: nil)
        let created = await store.createIfAbsent(original)
        XCTAssertTrue(created)
        let newerSaved = await store.persistProgress(newer)
        XCTAssertTrue(newerSaved)
        // Deliberately submit the old capture after the newer one has committed.
        let delayedOlderSaved = await store.persistProgress(older)
        XCTAssertFalse(delayedOlderSaved)
        XCTAssertEqual(store.snapshot, newer)
    }

    func testPendingWorkoutAtomicStoreMigratesLegacyOnlyAfterFileCommit() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-migrate-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "AtriaWorkoutSaveDurabilityTests.migrate.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let intent = pendingAtomicIntent(start: Date(timeIntervalSince1970: 2_000_300_000))
        XCTAssertTrue(intent.save(defaults: defaults))

        let store = AtriaPendingWorkoutIntentStore(directoryURL: directory,
                                                   legacyDefaults: defaults)
        let migrated = await store.prepare()
        XCTAssertTrue(migrated)
        XCTAssertEqual(store.snapshot, intent)
        XCTAssertNil(defaults.data(forKey: AtriaPendingWorkoutIntent.defaultsKey))
        let cold = AtriaPendingWorkoutIntentStore(directoryURL: directory,
                                                  legacyDefaults: nil)
        let coldPrepared = await cold.prepare()
        XCTAssertTrue(coldPrepared)
        XCTAssertEqual(cold.snapshot, intent)
    }

    func testPendingWorkoutAtomicStoreCorruptOrUnwritableAuthorityFailsClosed() async throws {
        let corruptDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-corrupt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: corruptDirectory,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: corruptDirectory) }
        try Data("not-json".utf8).write(
            to: corruptDirectory.appendingPathComponent("pending-workout-intent-v1.json"),
            options: .atomic
        )
        let corrupt = AtriaPendingWorkoutIntentStore(directoryURL: corruptDirectory,
                                                     legacyDefaults: nil)
        let corruptPrepared = await corrupt.prepare()
        XCTAssertFalse(corruptPrepared)
        let corruptCreated = await corrupt.createIfAbsent(
            pendingAtomicIntent(start: Date(timeIntervalSince1970: 2_000_400_000))
        )
        XCTAssertFalse(corruptCreated)
        XCTAssertNil(corrupt.snapshot)

        let blocked = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-blocked-\(UUID().uuidString)")
        try Data([0]).write(to: blocked)
        defer { try? FileManager.default.removeItem(at: blocked) }
        let unwritable = AtriaPendingWorkoutIntentStore(directoryURL: blocked,
                                                        legacyDefaults: nil)
        let unwritableCreated = await unwritable.createIfAbsent(
            pendingAtomicIntent(start: Date(timeIntervalSince1970: 2_000_500_000))
        )
        XCTAssertFalse(unwritableCreated)
        XCTAssertNil(unwritable.snapshot)
    }

    private func pendingAtomicIntent(start: Date) -> AtriaPendingWorkoutIntent {
        AtriaPendingWorkoutIntent(startedAt: start,
                                  endedAt: nil,
                                  activityType: AtriaWorkoutActivityType.walking.rawValue,
                                  strengthSets: [],
                                  excludedIntervals: [],
                                  startingStepCount: 42,
                                  startingDayStrain: 1.5)
    }

    func testCompletionClosesPauseWithoutDependingOnVisibleWorkoutView() {
        let start = Date(timeIntervalSince1970: 1_783_767_620)
        let endedAt = start.addingTimeInterval(50 * 60)
        let completedPause = ExcludedInterval(start: start.addingTimeInterval(10 * 60),
                                              end: start.addingTimeInterval(12 * 60))
        let openPause = start.addingTimeInterval(40 * 60)
        let intent = AtriaPendingWorkoutIntent(startedAt: start,
                                               endedAt: endedAt,
                                               activityType: AtriaWorkoutActivityType.strength.rawValue,
                                               strengthSets: [],
                                               excludedIntervals: [completedPause],
                                               pauseStartedAt: openPause,
                                               startingStepCount: 120,
                                               startingDayStrain: 4.2)

        XCTAssertEqual(intent.finalizedExcludedIntervals(), [
            completedPause,
            ExcludedInterval(start: openPause, end: endedAt)
        ])
    }

    func testRouteRetryStillOffersImmediateRouteAwareShareImage() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let source = try String(contentsOf: testsDirectory.deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaHomeView.swift"), encoding: .utf8)
        let routeStore = try String(contentsOf: testsDirectory.deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaWorkoutRoute.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "guard preparedRoute.routeWasPersisted else"))
        let tail = source[start.lowerBound...]
        let end = try XCTUnwrap(tail.range(of: "return"))
        let routeFailure = String(tail[..<end.upperBound])

        XCTAssertTrue(routeFailure.contains("routeArtifact: preparedRoute"))
        XCTAssertTrue(routeStore.contains("includeGPX: savedRoute != nil"))
        XCTAssertTrue(routeStore.contains("routeFileURL: includeGPX ? gpxURL(for: route) : nil"),
                      "An in-memory route preview must never imply the exact GPX write succeeded")
    }

    func testPendingWorkoutIntentDecodesPrePauseSchema() throws {
        let start = Date(timeIntervalSince1970: 1_783_767_620)
        let intent = AtriaPendingWorkoutIntent(startedAt: start,
                                               endedAt: nil,
                                               activityType: AtriaWorkoutActivityType.strength.rawValue,
                                               strengthSets: [],
                                               excludedIntervals: [],
                                               startingStepCount: 120,
                                               startingDayStrain: 4.2)
        let encoded = try JSONEncoder().encode(intent)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "pauseStartedAt")
        object.removeValue(forKey: "targetStrain")
        object.removeValue(forKey: "targetZone")
        object.removeValue(forKey: "pausedStepCount")
        object.removeValue(forKey: "pauseStartedStepCount")
        object.removeValue(forKey: "completedStepCount")
        object.removeValue(forKey: "completedStepsAreEstimated")
        object.removeValue(forKey: "completedStepsCapturedAt")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(AtriaPendingWorkoutIntent.self, from: legacyData)
        XCTAssertNil(decoded.pauseStartedAt)
        XCTAssertNil(decoded.targetStrain)
        XCTAssertNil(decoded.targetZone)
        XCTAssertEqual(decoded.pausedStepCount, 0)
        XCTAssertNil(decoded.pauseStartedStepCount)
        XCTAssertNil(decoded.completedStepCount)
        XCTAssertNil(decoded.completedStepsAreEstimated)
        XCTAssertNil(decoded.completedStepsCapturedAt)
        XCTAssertEqual(decoded.startedAt, start)
    }

    func testActivityEditorCommitIsAtomicAcrossWindowNameAndType() async throws {
        let store = SessionStore()
        let sessionID = UUID()
        let marker = "atomic-edit-" + UUID().uuidString
        // The confirmed-workout ledger is shared by every SessionStore. Keep
        // this edited window distinct from durable fixtures left by earlier
        // tests instead of depending on an eventually scheduled cleanup task.
        let start = max(
            Date(timeIntervalSince1970: 2_000_000_000),
            store.confirmedWorkouts.map(\.end).max()?.addingTimeInterval(24 * 60 * 60)
                ?? .distantPast
        )
        let end = start.addingTimeInterval(12 * 60)
        let points = stride(from: 0.0, through: 12 * 60, by: 10).map {
            SavedSession.Point(t: $0, bpm: 118 + (Int($0) / 10) % 18)
        }
        let session = SavedSession(id: sessionID,
                                   start: start,
                                   end: end,
                                   label: marker,
                                   points: points,
                                   hrv: nil,
                                   eventTimeZoneIdentifier: "UTC")
        store.add(session)

        let original = try unwrap(await store.confirmWorkoutWindowForUI(
            start: start,
            end: end,
            rest: 60,
            maxHR: 190,
            source: marker,
            activityType: "Cardio",
            reviewSource: marker
        ))
        addTeardownBlock { @MainActor in
            for workout in store.confirmedWorkouts where workout.reviewSource == marker {
                _ = await store.deleteConfirmedWorkout(id: workout.id)
            }
            store.deleteSession(id: sessionID)
        }

        let beforeFailure = store.confirmedWorkouts
        let missingDataStart = end.addingTimeInterval(24 * 60 * 60)
        let failed = await store.editConfirmedWorkout(id: original.id,
                                                label: "Should not partially save",
                                                activityType: "Strength",
                                                start: missingDataStart,
                                                end: missingDataStart.addingTimeInterval(30 * 60),
                                                rest: 60,
                                                maxHR: 190)
        XCTAssertEqual(failed, .failure(.insufficientStrapData))
        XCTAssertEqual(store.confirmedWorkouts, beforeFailure,
                       "A failed window derivation must not leak its name/type edits or remove the original")

        let revisionBeforeCommit = store.confirmedWorkoutsRevision
        let editedStart = start.addingTimeInterval(60)
        let editedEnd = end.addingTimeInterval(-60)
        let saved = try unwrap(try await store.editConfirmedWorkout(
            id: original.id,
            label: "  Chest & Triceps  ",
            activityType: "  Strength  ",
            start: editedStart,
            end: editedEnd,
            rest: 60,
            maxHR: 190
        ).get())

        XCTAssertEqual(saved.label, "Chest & Triceps")
        XCTAssertEqual(saved.activityType, "Strength")
        XCTAssertEqual(saved.start, editedStart)
        XCTAssertEqual(saved.end, editedEnd)
        XCTAssertEqual(saved.createdAt, original.createdAt)
        XCTAssertNotEqual(saved.id, original.id)
        XCTAssertFalse(store.confirmedWorkouts.contains(where: { $0.id == original.id }))
        XCTAssertEqual(store.confirmedWorkouts.filter { $0.id == saved.id }, [saved])
        XCTAssertEqual(store.confirmedWorkoutsRevision, revisionBeforeCommit + 1,
                       "One Save must produce one persisted workout-list revision")
    }

    func testArchiveRehydrationImprovesCoverageWithoutChangingUserWorkoutState() throws {
        let start = Date(timeIntervalSince1970: 1_783_767_620)
        let end = start.addingTimeInterval(50 * 60)
        let pause = ExcludedInterval(start: start.addingTimeInterval(20 * 60),
                                     end: start.addingTimeInterval(22 * 60))
        let set = LoggedSet(exercise: "Bench Press",
                            weightKg: 72.5,
                            reps: 8,
                            rpe: 8,
                            t: start.addingTimeInterval(15 * 60))
        var old = sparseConfirmedWorkout(start: start,
                                         end: end,
                                         samples: 2,
                                         coverage: 3,
                                         strengthSets: [set],
                                         excludedIntervals: [pause])
        old.workoutSteps = 1_204
        old.workoutStepsAreEstimated = false
        old.workoutStepsCapturedAt = end.addingTimeInterval(-1)
        let archive = stride(from: 0.0, through: 50 * 60, by: 10).map {
            HistoricalArchive.HeartRatePoint(t: start.addingTimeInterval($0),
                                             bpm: 105 + (Int($0) / 10) % 20)
        }
        let existing = [
            HistoricalArchive.HeartRatePoint(t: start, bpm: 105),
            HistoricalArchive.HeartRatePoint(t: start.addingTimeInterval(10), bpm: 106)
        ]
        let result = try XCTUnwrap(SessionStore.rehydratedConfirmedWorkout(
            old,
            existingPoints: existing,
            archivePoints: archive,
            rest: 60,
            maxHR: 190,
            profile: testAthleteProfile
        ))

        XCTAssertGreaterThan(result.streamCoveragePercent, old.streamCoveragePercent)
        XCTAssertGreaterThanOrEqual(result.samples, old.samples)
        XCTAssertEqual(result.samples, 288,
                       "Absolute-time duplicates must collapse, and all pause samples must stay excluded")
        XCTAssertEqual(result.id, old.id)
        XCTAssertEqual(result.createdAt, old.createdAt)
        XCTAssertEqual(result.start, old.start)
        XCTAssertEqual(result.end, old.end)
        XCTAssertEqual(result.label, old.label)
        XCTAssertEqual(result.source, old.source)
        XCTAssertEqual(result.confidence, old.confidence)
        XCTAssertEqual(result.activityType, old.activityType)
        XCTAssertEqual(result.activitySubtype, old.activitySubtype)
        XCTAssertEqual(result.exerciseNames, old.exerciseNames)
        XCTAssertEqual(result.strengthSets, old.strengthSets)
        XCTAssertEqual(result.excludedIntervals, old.excludedIntervals)
        XCTAssertEqual(result.reviewSource, old.reviewSource)
        XCTAssertEqual(result.eventTimeZoneIdentifier, old.eventTimeZoneIdentifier)
        XCTAssertEqual(result.workoutSteps, old.workoutSteps)
        XCTAssertEqual(result.workoutStepsAreEstimated, old.workoutStepsAreEstimated)
        XCTAssertEqual(result.workoutStepsCapturedAt, old.workoutStepsCapturedAt)
        XCTAssertEqual(result.reason, "historical_archive_real_hr")
        XCTAssertGreaterThan(result.avgHR, 0)
        XCTAssertNotNil(result.strain)
    }

    func testRecoveredWorkoutEvidenceAcceptsMoreExactSamplesAtSameRoundedCoverage() {
        let start = Date(timeIntervalSince1970: 1_783_767_620)
        let end = start.addingTimeInterval(50 * 60)
        let current = sparseConfirmedWorkout(start: start,
                                             end: end,
                                             samples: 100,
                                             coverage: 42)
        let stronger = sparseConfirmedWorkout(start: start,
                                              end: end,
                                              samples: 101,
                                              coverage: 42)

        XCTAssertTrue(SessionStore.recoveredWorkoutEvidenceIsStronger(stronger,
                                                                       than: current),
                      "Rounded coverage must not discard an additional exact recovered sample")
        XCTAssertFalse(SessionStore.recoveredWorkoutEvidenceIsStronger(current,
                                                                        than: stronger),
                       "A replay of weaker evidence must remain idempotent")
    }

    func testArchiveRehydrationRepairsNoHRConfidenceWhenRealHRBecomesAvailable() throws {
        let start = Date(timeIntervalSince1970: 1_783_767_620)
        let end = start.addingTimeInterval(20 * 60)
        var old = sparseConfirmedWorkout(start: start,
                                         end: end,
                                         samples: 0,
                                         coverage: 0)
        old = UserConfirmedWorkout(id: old.id,
                                   createdAt: old.createdAt,
                                   start: old.start,
                                   end: old.end,
                                   label: old.label,
                                   source: old.source,
                                   confidence: "user_confirmed_no_hr",
                                   sessions: old.sessions,
                                   samples: 0,
                                   avgHR: 0,
                                   peakHR: 0,
                                   p95HR: 0,
                                   p99HR: 0,
                                   thresholdHR: old.thresholdHR,
                                   streamCoveragePercent: 0,
                                   observedDuration: 0,
                                   reason: "no_strap_hr_samples",
                                   activityType: old.activityType,
                                   activitySubtype: old.activitySubtype,
                                   exerciseNames: old.exerciseNames,
                                   strengthSets: old.strengthSets,
                                   excludedIntervals: old.excludedIntervals,
                                   reviewSource: old.reviewSource,
                                   strain: nil,
                                   activeEnergyKilocalories: nil,
                                   activeEnergyConfidence: nil,
                                   zoneSeconds: nil,
                                   eventTimeZoneIdentifier: old.eventTimeZoneIdentifier)
        let archive = stride(from: 0.0, through: 20 * 60, by: 10).map {
            HistoricalArchive.HeartRatePoint(t: start.addingTimeInterval($0), bpm: 118)
        }

        let result = try XCTUnwrap(SessionStore.rehydratedConfirmedWorkout(
            old,
            existingPoints: [],
            archivePoints: archive,
            rest: 60,
            maxHR: 190,
            profile: testAthleteProfile
        ))

        XCTAssertEqual(result.confidence, "user_confirmed_recovered_hr")
        XCTAssertGreaterThan(result.samples, 0)
        XCTAssertGreaterThan(result.avgHR, 0)
        XCTAssertNotNil(result.strain)
    }

    func testHistoricalRehydrationEligibilityRepairsIncompleteLegacyRows() {
        let start = Date(timeIntervalSince1970: 1_783_767_620)
        let complete = sparseConfirmedWorkout(start: start,
                                              end: start.addingTimeInterval(50 * 60),
                                              samples: 3_000,
                                              coverage: 100)
        let missingMetrics = UserConfirmedWorkout(id: complete.id,
                                                  createdAt: complete.createdAt,
                                                  start: complete.start,
                                                  end: complete.end,
                                                  label: complete.label,
                                                  source: complete.source,
                                                  confidence: complete.confidence,
                                                  sessions: complete.sessions,
                                                  samples: complete.samples,
                                                  avgHR: complete.avgHR,
                                                  peakHR: complete.peakHR,
                                                  p95HR: complete.p95HR,
                                                  p99HR: complete.p99HR,
                                                  thresholdHR: complete.thresholdHR,
                                                  streamCoveragePercent: 100,
                                                  observedDuration: complete.observedDuration,
                                                  reason: complete.reason,
                                                  activityType: complete.activityType,
                                                  activitySubtype: complete.activitySubtype,
                                                  exerciseNames: complete.exerciseNames,
                                                  strengthSets: complete.strengthSets,
                                                  excludedIntervals: complete.excludedIntervals,
                                                  reviewSource: complete.reviewSource,
                                                  strain: nil,
                                                  activeEnergyKilocalories: complete.activeEnergyKilocalories,
                                                  activeEnergyConfidence: complete.activeEnergyConfidence,
                                                  zoneSeconds: nil,
                                                  eventTimeZoneIdentifier: complete.eventTimeZoneIdentifier)

        XCTAssertFalse(SessionStore.confirmedWorkoutNeedsArchiveRehydration(complete))
        XCTAssertTrue(SessionStore.confirmedWorkoutNeedsArchiveRehydration(missingMetrics))
    }

    func testHistoricalRehydrationDoesNotWaitForWalkingStepEvidence() {
        var completeWalking = sparseConfirmedWorkout(
            start: Date(timeIntervalSince1970: 1_785_000_000),
            end: Date(timeIntervalSince1970: 1_785_000_900),
            samples: 900,
            coverage: 100
        )
        completeWalking.activityType = AtriaWorkoutActivityType.walking.rawValue
        completeWalking.workoutSteps = nil
        completeWalking.workoutStepsAreEstimated = nil

        XCTAssertFalse(
            SessionStore.confirmedWorkoutNeedsArchiveRehydration(completeWalking),
            "Gate 2 HR publication must not wait for the independent Gate 4 motion lane"
        )
    }

    func testArchiveRehydrationUsesOneUnionWindowForEligibleWorkouts() throws {
        let firstStart = Date(timeIntervalSince1970: 1_783_767_620)
        let first = sparseConfirmedWorkout(
            start: firstStart,
            end: firstStart.addingTimeInterval(50 * 60),
            samples: 100,
            coverage: 50
        )
        let secondStart = firstStart.addingTimeInterval(24 * 60 * 60)
        let second = sparseConfirmedWorkout(
            start: secondStart,
            end: secondStart.addingTimeInterval(75 * 60),
            samples: 100,
            coverage: 50
        )

        let union = try XCTUnwrap(
            SessionStore.confirmedWorkoutArchiveUnionWindow([second, first])
        )

        XCTAssertEqual(union.start, first.start)
        XCTAssertEqual(union.end, second.end)
        XCTAssertNil(SessionStore.confirmedWorkoutArchiveUnionWindow([]))
    }

    func testArchiveRehydrationNeverReplacesWithEqualOrLowerCoverage() {
        let start = Date(timeIntervalSince1970: 1_783_767_620)
        let old = sparseConfirmedWorkout(start: start,
                                         end: start.addingTimeInterval(50 * 60),
                                         samples: 100,
                                         coverage: 90)
        let archive = stride(from: 0.0, through: 8 * 60, by: 10).map {
            HistoricalArchive.HeartRatePoint(t: start.addingTimeInterval($0), bpm: 115)
        }

        XCTAssertNil(SessionStore.rehydratedConfirmedWorkout(
            old,
            existingPoints: [],
            archivePoints: archive,
            rest: 60,
            maxHR: 190,
            profile: testAthleteProfile
        ))
    }

    func testHistoricalRecoveryResolutionRequiresMatchingWorkoutAtCoverageFloor() {
        let suite = "AtriaWorkoutSaveDurabilityTests.recovery-resolution.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let start = Date(timeIntervalSince1970: 1_783_767_620)
        let end = start.addingTimeInterval(50 * 60)
        let original = sparseConfirmedWorkout(start: start,
                                              end: end,
                                              samples: 58,
                                              coverage: 3)
        let subThreshold = sparseConfirmedWorkout(start: start,
                                                  end: end,
                                                  samples: 1_000,
                                                  coverage: 99)
        let complete = sparseConfirmedWorkout(start: start,
                                              end: end,
                                              samples: 1_100,
                                              coverage: 100)

        XCTAssertFalse(SessionStore.historicalRecoveryRequestIsSatisfied(
            original: original,
            replacement: subThreshold,
            requestedStart: start,
            requestedEnd: end
        ), "Improvement below complete coverage must remain pending")
        XCTAssertTrue(SessionStore.historicalRecoveryRequestIsSatisfied(
            original: original,
            replacement: complete,
            requestedStart: start,
            requestedEnd: end
        ))

        defaults.set(true, forKey: AtriaBLEManager.OfflineSyncDefaults.rangeLossBackfillPending)
        defaults.set(start.timeIntervalSince1970,
                     forKey: AtriaBLEManager.OfflineSyncDefaults.recoveryWindowStart)
        defaults.set(end.timeIntervalSince1970,
                     forKey: AtriaBLEManager.OfflineSyncDefaults.recoveryWindowEnd)
        XCTAssertFalse(SessionStore.resolveHistoricalRecoveryRequestIfSatisfied(
            by: [(original: original, replacement: subThreshold)],
            defaults: defaults
        ))
        XCTAssertTrue(defaults.bool(forKey: AtriaBLEManager.OfflineSyncDefaults.rangeLossBackfillPending))
        XCTAssertTrue(SessionStore.resolveHistoricalRecoveryRequestIfSatisfied(
            by: [(original: original, replacement: complete)],
            defaults: defaults
        ))
        XCTAssertFalse(defaults.bool(forKey: AtriaBLEManager.OfflineSyncDefaults.rangeLossBackfillPending))
        XCTAssertNil(defaults.object(forKey: AtriaBLEManager.OfflineSyncDefaults.recoveryWindowStart))
        XCTAssertNil(defaults.object(forKey: AtriaBLEManager.OfflineSyncDefaults.recoveryWindowEnd))
    }

    func testHistoricalRecoveryResolutionCannotBeSatisfiedByUnrelatedWorkout() {
        let suite = "AtriaWorkoutSaveDurabilityTests.recovery-isolation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let requestedStart = Date(timeIntervalSince1970: 1_783_767_620)
        let requestedEnd = requestedStart.addingTimeInterval(50 * 60)
        let unrelatedStart = requestedEnd.addingTimeInterval(30 * 60)
        let unrelatedEnd = unrelatedStart.addingTimeInterval(40 * 60)
        let unrelatedOriginal = sparseConfirmedWorkout(start: unrelatedStart,
                                                       end: unrelatedEnd,
                                                       samples: 20,
                                                       coverage: 5)
        let unrelatedReplacement = sparseConfirmedWorkout(start: unrelatedStart,
                                                          end: unrelatedEnd,
                                                          samples: 900,
                                                          coverage: 90)

        XCTAssertFalse(SessionStore.historicalRecoveryRequestIsSatisfied(
            original: unrelatedOriginal,
            replacement: unrelatedReplacement,
            requestedStart: requestedStart,
            requestedEnd: requestedEnd
        ), "Recovery of another workout must not clear the requested gym interval")

        defaults.set(true, forKey: AtriaBLEManager.OfflineSyncDefaults.rangeLossBackfillPending)
        defaults.set(requestedStart.timeIntervalSince1970,
                     forKey: AtriaBLEManager.OfflineSyncDefaults.recoveryWindowStart)
        defaults.set(requestedEnd.timeIntervalSince1970,
                     forKey: AtriaBLEManager.OfflineSyncDefaults.recoveryWindowEnd)
        XCTAssertFalse(SessionStore.resolveHistoricalRecoveryRequestIfSatisfied(
            by: [(original: unrelatedOriginal, replacement: unrelatedReplacement)],
            defaults: defaults
        ))
        XCTAssertTrue(defaults.bool(forKey: AtriaBLEManager.OfflineSyncDefaults.rangeLossBackfillPending))
    }

    func testArchiveRehydrationExcludesPausedHeartRateSpikes() throws {
        let start = Date(timeIntervalSince1970: 1_783_767_620)
        let end = start.addingTimeInterval(20 * 60)
        let pause = ExcludedInterval(start: start.addingTimeInterval(8 * 60),
                                     end: start.addingTimeInterval(12 * 60))
        let old = sparseConfirmedWorkout(start: start,
                                         end: end,
                                         samples: 2,
                                         coverage: 1,
                                         excludedIntervals: [pause])
        let archive = stride(from: 0.0, through: 20 * 60, by: 10).map { offset in
            let time = start.addingTimeInterval(offset)
            return HistoricalArchive.HeartRatePoint(t: time,
                                                     bpm: (time >= pause.start && time <= pause.end) ? 220 : 80)
        }
        let result = try XCTUnwrap(SessionStore.rehydratedConfirmedWorkout(
            old,
            existingPoints: [],
            archivePoints: archive,
            rest: 60,
            maxHR: 190,
            profile: testAthleteProfile
        ))

        XCTAssertEqual(result.peakHR, 80)
        XCTAssertEqual(result.avgHR, 80)
        XCTAssertEqual(result.zoneSeconds?["max"] ?? 0, 0, accuracy: 0.001)
        XCTAssertEqual(result.excludedIntervals, [pause])
    }

    func testWorkoutEndAwaitsAtomicIntentBeforeDismissAndKeepsIntentUntilFlush() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let source = try String(
            contentsOf: testsDirectory.deletingLastPathComponent()
                .appendingPathComponent("Atria/AtriaHomeView.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "private func endWorkoutSession(startedAt: Date,"))
        let tail = String(source[start.lowerBound...])
        let intent = try XCTUnwrap(tail.range(of: "await finalIntent.persistTerminal()"))
        let dismiss = try XCTUnwrap(tail.range(of: "workoutSession = nil"))
        let delayedWork = try XCTUnwrap(tail.range(of: "Task { @MainActor in"))

        XCTAssertLessThan(intent.lowerBound, dismiss.lowerBound)
        XCTAssertLessThan(dismiss.lowerBound, delayedWork.lowerBound)
        // The terminal intent remains the recovery authority until the single
        // completion-aware session flush succeeds. An eager flush here would
        // duplicate serialization when its write has already begun.
        XCTAssertFalse(tail.contains("requestPersistenceFlush(reason: \"live_workout_end_checkpoint\")"))
        XCTAssertTrue(tail.contains("flushScheduledPersistenceAsync(reason: \"live_workout_end_confirmed\")"))
        XCTAssertFalse(tail.contains("flushScheduledPersistence(reason: \"live_workout_end\")"))
    }

    func testWorkoutEndConsumesRebasedCanonicalIntentForCheckpointAndConfirmation() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let source = try String(
            contentsOf: testsDirectory.deletingLastPathComponent()
                .appendingPathComponent("Atria/AtriaHomeView.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "private func endWorkoutSession(startedAt: Date,"))
        let end = try XCTUnwrap(source.range(of: "private func workoutShareSnapshot(for workout:",
                                             range: start.upperBound..<source.endIndex))
        let body = String(source[start.lowerBound..<end.lowerBound])
        let durable = try XCTUnwrap(body.range(of: "guard let finalIntent = await finalIntent.persistTerminal() else"))
        let normalized = try XCTUnwrap(body.range(of: "let finalizedExcludedIntervals = finalIntent.finalizedExcludedIntervals()"))
        XCTAssertLessThan(durable.lowerBound, normalized.lowerBound)
        XCTAssertTrue(body.contains("strengthSets: finalIntent.strengthSets"))
        XCTAssertTrue(body.contains("excludedIntervals: finalizedExcludedIntervals"))
        XCTAssertFalse(String(body[normalized.lowerBound...]).contains("strengthSets: strengthSets"))
    }

    func testGuidedWorkoutSaveOffersTheSameShareExperienceAsLiveWorkoutCompletion() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let source = try String(
            contentsOf: testsDirectory.deletingLastPathComponent()
                .appendingPathComponent("Atria/AtriaHomeView.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "private func saveWorkoutReview("))
        let end = try XCTUnwrap(source.range(of: "private func formatWorkoutDuration(",
                                             range: start.upperBound..<source.endIndex))
        let saveFlow = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(saveFlow.contains("-> UserConfirmedWorkout?"),
                      "The review save callback must return the exact canonical workout accepted by the store")
        XCTAssertTrue(saveFlow.contains("return confirmed"))
        XCTAssertTrue(saveFlow.contains("let workoutID = confirmed.id"),
                      "Route lookup must capture only the canonical persisted ID before leaving the main actor")
        XCTAssertTrue(saveFlow.contains("loadPreparedShareArtifactAsync(workoutID: workoutID)"),
                      "Post-save sharing must resolve bounded route artifacts by the persisted workout ID")
        XCTAssertFalse(saveFlow.contains("AtriaWorkoutRouteStore.load(workoutID: workoutID)"),
                       "The full canonical route must not cross back to Home's main actor")
        XCTAssertTrue(saveFlow.contains("await Task.yield()"),
                      "The saved receipt must wait for the review save callback and dismissal turn")
        XCTAssertTrue(saveFlow.contains("routeArtifact: routeArtifact"),
                      "The share composer must receive canonical saved metrics and bounded route data")
        XCTAssertTrue(source.contains("settlingCandidateWindow: (draft.suggestedStart, draft.suggestedEnd)"),
                      "A guided review must preserve the detector's original window through an adjusted Save")
        XCTAssertTrue(saveFlow.contains("settlingCandidateWindow: settlingCandidateWindow"),
                      "The original detector window must be settled by the same canonical store transaction")
    }

    func testGuidedAdjustedWorkoutSettlesNonOverlappingCandidateOnlyAfterCanonicalSave() async throws {
        let marker = "guided-candidate-settlement-\(UUID().uuidString)"
        let originalStart = Date(timeIntervalSince1970: 2_320_000_000 + Double.random(in: 0..<100_000))
        let originalEnd = originalStart.addingTimeInterval(35 * 60)
        let adjustedStart = originalEnd.addingTimeInterval(3 * 60 * 60)
        let adjustedEnd = adjustedStart.addingTimeInterval(30 * 60)

        AtriaDismissedWorkoutCandidateStore.save(
            AtriaDismissedWorkoutCandidateStore.load().filter {
                !$0.overlaps(start: originalStart, end: originalEnd)
                    && !$0.overlaps(start: adjustedStart, end: adjustedEnd)
            }
        )
        let store = SessionStore()
        defer {
            for workout in store.confirmedWorkouts where workout.reviewSource == marker {
                Task { @MainActor in _ = await store.deleteConfirmedWorkout(id: workout.id) }
            }
            AtriaDismissedWorkoutCandidateStore.save(
                AtriaDismissedWorkoutCandidateStore.load().filter {
                    !$0.overlaps(start: originalStart, end: originalEnd)
                        && !$0.overlaps(start: adjustedStart, end: adjustedEnd)
                }
            )
        }

        let rejected = await store.confirmWorkoutWindowForUI(
            start: adjustedStart,
            end: adjustedStart,
            rest: 60,
            maxHR: 190,
            source: marker,
            preserveUserDeclaredActivityWithoutHeartRate: true,
            activityType: AtriaWorkoutActivityType.walking.rawValue,
            reviewSource: marker,
            settlingCandidateWindow: (originalStart, originalEnd)
        )
        XCTAssertNil(rejected)
        XCTAssertFalse(AtriaDismissedWorkoutCandidateStore.load().contains {
            $0.overlaps(start: originalStart, end: originalEnd)
        }, "A failed canonical Save must leave the detector candidate actionable")

        let saved = try unwrap(await store.confirmWorkoutWindowForUI(
            start: adjustedStart,
            end: adjustedEnd,
            rest: 60,
            maxHR: 190,
            source: marker,
            preserveUserDeclaredActivityWithoutHeartRate: true,
            activityType: AtriaWorkoutActivityType.walking.rawValue,
            reviewSource: marker,
            settlingCandidateWindow: (originalStart, originalEnd)
        ))
        XCTAssertGreaterThan(saved.start, originalEnd)
        XCTAssertTrue(AtriaDismissedWorkoutCandidateStore.load().contains {
            $0.overlaps(start: originalStart, end: originalEnd)
        }, "The original detector window must stay settled even when the saved edit no longer overlaps it")

        let originalDetection = ActivityDetection(id: UUID(),
                                                  kind: .activityCandidate,
                                                  confidence: .medium,
                                                  start: originalStart,
                                                  end: originalEnd,
                                                  duration: originalEnd.timeIntervalSince(originalStart),
                                                  avgHR: 112,
                                                  peakHR: 138,
                                                  reason: marker)
        XCTAssertTrue(SessionStore.activityDetectionsForUI(
            [originalDetection],
            dismissedCandidates: AtriaDismissedWorkoutCandidateStore.load()
        ).isEmpty)
    }

    func testGuidedWorkoutReviewCannotShareAnUnsavedDetectorDraft() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let source = try String(
            contentsOf: testsDirectory.deletingLastPathComponent()
                .appendingPathComponent("Atria/AtriaHomeView.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "private struct AtriaWorkoutReviewFlow: View"))
        let end = try XCTUnwrap(source.range(of: "private struct AtriaWorkoutSummaryExerciseHistory:",
                                             range: start.upperBound..<source.endIndex))
        let reviewFlow = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertFalse(reviewFlow.contains("AtriaWorkoutShareSheet"),
                       "The detector review must not own or present a share composer before save")
        XCTAssertFalse(reviewFlow.contains("Share workout"),
                       "Sharing is offered only by the canonical post-save receipt")
        XCTAssertFalse(reviewFlow.contains("makeWorkoutShareSnapshot"))
        XCTAssertFalse(reviewFlow.contains("averageHeartRate: draft.prompt.heartRate"),
                       "A current/peak detector reading must never be fabricated as average HR")
    }

    private var testAthleteProfile: AthleteProfile {
        AthleteProfile(age: 30,
                       measuredMaxHR: 190,
                       maxHRSource: .measured,
                       biologicalSex: .male,
                       weightKg: 75,
                       heightCm: 178,
                       updated: nil,
                       hasCompletedOnboarding: true)
    }

    private func sparseConfirmedWorkout(start: Date,
                                        end: Date,
                                        samples: Int,
                                        coverage: Int,
                                        strengthSets: [LoggedSet] = [],
                                        excludedIntervals: [ExcludedInterval] = []) -> UserConfirmedWorkout {
        UserConfirmedWorkout(id: "rehydrate-\(Int(start.timeIntervalSince1970))",
                             createdAt: start.addingTimeInterval(-60),
                             start: start,
                             end: end,
                             label: "Chest & Triceps",
                             source: "live_workout_window",
                             confidence: "live_window_manual_sparse_hr",
                             sessions: 1,
                             samples: samples,
                             avgHR: 110,
                             peakHR: 130,
                             p95HR: 125,
                             p99HR: 129,
                             thresholdHR: 125,
                             streamCoveragePercent: coverage,
                             observedDuration: end.timeIntervalSince(start) * Double(coverage) / 100,
                             reason: "insufficient_stream_coverage",
                             activityType: "Strength",
                             activitySubtype: "Chest",
                             exerciseNames: ["Bench Press", "Cable Pushdown"],
                             strengthSets: strengthSets,
                             excludedIntervals: excludedIntervals,
                             reviewSource: "live_workout",
                             strain: 2.1,
                             activeEnergyKilocalories: 80,
                             activeEnergyConfidence: "estimate",
                             zoneSeconds: ["aerobic": 60],
                             eventTimeZoneIdentifier: "Asia/Kolkata")
    }

    // MARK: Exact workout-start journal ownership

    private func durabilitySource(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testWorkoutCheckpointLabelPreservesAllDayJournalWithoutStartBoundary() {
        let workoutStart = Date(timeIntervalSince1970: 805_813_649)
        let allDayFirstSample = Date(timeIntervalSince1970: 805_809_485)
        // Buffer still contains pre-workout all-day samples: the workout label
        // must never be applied to the retained journal (F799A190 corruption).
        let preserved = AtriaBLEManager.workoutCheckpointLabel(
            requested: "Live workout",
            allDayLabel: "All-day wear",
            firstSampleAt: allDayFirstSample,
            notBefore: workoutStart
        )
        XCTAssertEqual(preserved.label, "All-day wear")
        XCTAssertTrue(preserved.preservedAllDay)
        // Boundary was committed: buffer begins exactly at the workout start.
        let owned = AtriaBLEManager.workoutCheckpointLabel(
            requested: "Live workout",
            allDayLabel: "All-day wear",
            firstSampleAt: workoutStart,
            notBefore: workoutStart
        )
        XCTAssertEqual(owned.label, "Live workout")
        XCTAssertFalse(owned.preservedAllDay)
        // Later samples only: still owned by the workout.
        let laterOwned = AtriaBLEManager.workoutCheckpointLabel(
            requested: "Live workout",
            allDayLabel: "All-day wear",
            firstSampleAt: workoutStart.addingTimeInterval(4),
            notBefore: workoutStart
        )
        XCTAssertEqual(laterOwned.label, "Live workout")
        // No ownership constraint (non-workout checkpoints) keeps the request.
        XCTAssertEqual(AtriaBLEManager.workoutCheckpointLabel(
            requested: "Checkpoint",
            allDayLabel: "All-day wear",
            firstSampleAt: allDayFirstSample,
            notBefore: nil
        ).label, "Checkpoint")
    }

    func testWorkoutStartBoundaryRequirementUsesExactPersistedStart() {
        let startedAt = Date(timeIntervalSince1970: 805_813_649)
        XCTAssertTrue(AtriaBLEManager.workoutStartBoundaryIsRequired(
            firstSampleAt: startedAt.addingTimeInterval(-4_164),
            startedAt: startedAt
        ))
        XCTAssertFalse(AtriaBLEManager.workoutStartBoundaryIsRequired(
            firstSampleAt: startedAt,
            startedAt: startedAt
        ))
        XCTAssertFalse(AtriaBLEManager.workoutStartBoundaryIsRequired(
            firstSampleAt: startedAt.addingTimeInterval(1),
            startedAt: startedAt
        ))
        XCTAssertFalse(AtriaBLEManager.workoutStartBoundaryIsRequired(
            firstSampleAt: nil,
            startedAt: startedAt
        ))
    }

    func testWorkoutStartCommitsExactBoundaryAfterIntentPersistence() throws {
        let home = try durabilitySource("AtriaHomeView.swift")
        let start = try XCTUnwrap(home.range(
            of: "private func makeWorkoutSession"
        ))
        let end = try XCTUnwrap(home.range(
            of: "private func beginWorkoutSession",
            range: start.upperBound..<home.endIndex
        ))
        let body = String(home[start.lowerBound..<end.lowerBound])
        let intentPersisted = try XCTUnwrap(body.range(
            of: "guard await intent.createPersisted()"
        ))
        let boundary = try XCTUnwrap(body.range(
            of: "commitWorkoutStartSessionBoundary(startedAt: boundaryStart)"
        ))
        let lease = try XCTUnwrap(body.range(
            of: "beginWorkoutMotionLease(startedAt: session.start"
        ))
        XCTAssertLessThan(intentPersisted.lowerBound, boundary.lowerBound,
                          "The exact boundary must follow the persisted intent start")
        XCTAssertLessThan(boundary.lowerBound, lease.lowerBound)
        XCTAssertTrue(body.contains("status=start_boundary_persist_failed action=retain_all_day_journal"))
    }

    func testWorkoutEndCheckpointPassesPersistedStartOwnership() throws {
        let home = try durabilitySource("AtriaHomeView.swift")
        let start = try XCTUnwrap(home.range(
            of: "private func endWorkoutSession(startedAt: Date,"
        ))
        let end = try XCTUnwrap(home.range(
            of: "private func workoutShareSnapshot(for workout:",
            range: start.upperBound..<home.endIndex
        ))
        let body = String(home[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("notBefore: finalIntent.startedAt"),
                      "The end checkpoint must carry the persisted exact workout start")
        XCTAssertTrue(body.contains("endWorkoutMotionLease(reason: \"workout_end\")"))
    }

    func testCheckpointOwnershipGuardRunsBeforeSnapshotAndFailsClosed() throws {
        let manager = try durabilitySource("AtriaBLEManager.swift")
        let start = try XCTUnwrap(manager.range(
            of: "func checkpointCurrentSession(label: String,"
        ))
        let end = try XCTUnwrap(manager.range(
            of: "private func shouldRollActiveSessionAfterLongGap",
            range: start.upperBound..<manager.endIndex
        ))
        let body = String(manager[start.lowerBound..<end.lowerBound])
        let ownership = try XCTUnwrap(body.range(
            of: "Self.workoutCheckpointLabel("
        ))
        let snapshot = try XCTUnwrap(body.range(
            of: "snapshotSession(label: label,"
        ))
        XCTAssertLessThan(ownership.lowerBound, snapshot.lowerBound,
                          "Label ownership must be decided before the buffer is snapshotted")
        XCTAssertTrue(body.contains("status=label_preserved reason=missing_workout_start_boundary"))
    }

    func testWorkoutStartBoundaryFailureRetainsAllDayJournal() throws {
        let manager = try durabilitySource("AtriaBLEManager.swift")
        let start = try XCTUnwrap(manager.range(
            of: "func commitWorkoutStartSessionBoundary(startedAt: Date)"
        ))
        let end = try XCTUnwrap(manager.range(
            of: "func checkpointCurrentSession(label: String,",
            range: start.upperBound..<manager.endIndex
        ))
        let body = String(manager[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("persistenceReason: \"workout_start_boundary\""))
        XCTAssertTrue(body.contains("resetWhenUnsavable: false"),
                      "A boundary that cannot persist must retain the live all-day session")
        XCTAssertTrue(body.contains("retain_all_day_journal_fail_closed"))
    }

    func testTerminalRecoveryAndCanonicalSyncReleaseMotionLease() throws {
        let runtime = try durabilitySource("AtriaWorkoutRuntime.swift")
        XCTAssertTrue(runtime.contains("endWorkoutMotionLease(reason: \"terminal_recovery\")"))
        let home = try durabilitySource("AtriaHomeView.swift")
        XCTAssertTrue(home.contains("endWorkoutMotionLease(reason: \"canonical_intent_terminal\")"))
        XCTAssertTrue(home.contains("beginWorkoutMotionLease(startedAt: pending.startedAt"),
                      "Relaunch recovery must re-adopt the lease from the persisted startedAt")
    }

    // MARK: - Abandoned workout recovery

    func testAbandonedRecoveryEndDateCapsNeverEndedIntentAtContinuityBound() {
        let started = Date(timeIntervalSince1970: 2_000_000_000)
        let intent = AtriaPendingWorkoutIntent(startedAt: started,
                                               endedAt: nil,
                                               activityType: "Walking",
                                               strengthSets: [],
                                               excludedIntervals: [],
                                               startingStepCount: 0,
                                               startingDayStrain: 0)
        // Fresh and mid-bound intents are legitimate — never finalized.
        XCTAssertNil(AtriaPendingWorkoutIntent.abandonedRecoveryEndDate(
            intent: intent, now: started.addingTimeInterval(60)))
        XCTAssertNil(AtriaPendingWorkoutIntent.abandonedRecoveryEndDate(
            intent: intent,
            now: started.addingTimeInterval(AtriaPendingWorkoutIntent.bleContinuityMaxAge)))
        // Past the bound: end is capped at the bound, never at "now" (a
        // 134 h elapsed timer must not become a 134 h workout).
        XCTAssertEqual(AtriaPendingWorkoutIntent.abandonedRecoveryEndDate(
            intent: intent,
            now: started.addingTimeInterval(134 * 3_600)
        ), started.addingTimeInterval(AtriaPendingWorkoutIntent.bleContinuityMaxAge))
        // Already-ended and absent intents are the terminal worker's domain.
        var ended = intent
        ended.endedAt = started.addingTimeInterval(1_800)
        XCTAssertNil(AtriaPendingWorkoutIntent.abandonedRecoveryEndDate(
            intent: ended, now: started.addingTimeInterval(134 * 3_600)))
        XCTAssertNil(AtriaPendingWorkoutIntent.abandonedRecoveryEndDate(
            intent: nil, now: started))
    }

    func testRuntimeFinalizesAbandonedIntentBeforeSchedulingTerminalRecovery() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaWorkoutRuntime.swift"), encoding: .utf8)
        let recover = try XCTUnwrap(source.range(of: "private func recoverAbandonedWorkoutIntentIfNeeded"))
        let body = String(source[recover.lowerBound...].prefix(1_400))
        XCTAssertTrue(body.contains("abandonedRecoveryEndDate"),
                      "finalization must use the capped policy end, not Date()")
        XCTAssertTrue(body.contains("persistTerminal()"),
                      "the abandoned intent must become terminal so the existing recovery worker owns completion")
        let replay = try XCTUnwrap(source.range(of: "await self.recoverAbandonedWorkoutIntentIfNeeded()"))
        let afterReplay = String(source[replay.upperBound...].prefix(200))
        XCTAssertTrue(afterReplay.contains("scheduleTerminalWorkoutRecovery()"),
                      "abandoned finalization must run before the terminal recovery scheduling it feeds")
    }

}
