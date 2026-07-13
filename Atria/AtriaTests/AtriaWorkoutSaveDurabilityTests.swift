import XCTest
@testable import Atria

@MainActor
final class AtriaWorkoutSaveDurabilityTests: XCTestCase {
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
        XCTAssertEqual(decoded.startingDayStrain, 0)
        XCTAssertNil(decoded.lowerTargetZone)
        XCTAssertNil(decoded.upperTargetZone)
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

    func testEveryExplicitWorkoutCompletionPathOffersTruthfulSharing() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let source = try String(
            contentsOf: testsDirectory.deletingLastPathComponent()
                .appendingPathComponent("Atria/AtriaHomeView.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "private func endWorkoutSession(startedAt: Date,"))
        let end = try XCTUnwrap(source.range(of: "private func workoutShareSnapshot(for workout:",
                                             range: start.upperBound..<source.endIndex))
        let completion = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertEqual(completion.components(separatedBy: "title: \"Workout safely retained\"").count - 1, 3,
                       "Sparse evidence and a failed route attachment must all remain explicit retention states")
        XCTAssertEqual(completion.components(separatedBy: "shareSnapshot: retainedWorkoutShareSnapshot(").count - 1, 2,
                       "Both sparse-save fallbacks must offer the same completion share experience")
        XCTAssertTrue(source.contains("strain: \"--\""))
        XCTAssertTrue(source.contains("peakHeartRate: \"--\""))
        XCTAssertTrue(source.contains("routeFileURL: nil"),
                      "A pending workout recap must not expose a non-durable exact route file")
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
        XCTAssertTrue(branch.contains("flushWorkoutRouteAtBackgroundBoundary()"))
        XCTAssertTrue(source.contains("beginBackgroundTask("))
        XCTAssertTrue(source.contains("workoutRouteRecorder.flushCheckpoint(reason: \"scene_background\")"))
        XCTAssertTrue(source.contains("endWorkoutRouteBackgroundTaskIfNeeded()"))
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
        XCTAssertFalse(SessionStore.explicitWorkoutSaveIsConfirmable(sampleCount: 1,
                                                                     requestedDuration: 50 * 60))
    }

    func testExplicitUserActivityCanPersistWithoutInventingSensorMetrics() throws {
        XCTAssertTrue(SessionStore.metadataOnlyWorkoutSaveIsConfirmable(
            isExplicitUserActivity: true,
            requestedDuration: 30 * 60
        ))
        XCTAssertFalse(SessionStore.metadataOnlyWorkoutSaveIsConfirmable(
            isExplicitUserActivity: false,
            requestedDuration: 30 * 60
        ), "Automatic detection must never create a workout without sensor evidence")

        let store = SessionStore()
        let marker = "metadata-only-" + UUID().uuidString
        let start = Date(timeIntervalSince1970: 2_100_000_000 + Double.random(in: 0..<100_000))
        let workout = try XCTUnwrap(store.confirmWorkoutWindowForUI(
            start: start,
            end: start.addingTimeInterval(30 * 60),
            rest: 60,
            maxHR: 190,
            source: marker,
            preserveUserDeclaredActivityWithoutHeartRate: true,
            activityType: "Strength",
            reviewSource: marker
        ))
        defer { _ = store.deleteConfirmedWorkout(id: workout.id) }

        XCTAssertEqual(workout.confidence, "user_confirmed_no_hr")
        XCTAssertEqual(workout.samples, 0)
        XCTAssertEqual(workout.avgHR, 0)
        XCTAssertEqual(workout.peakHR, 0)
        XCTAssertNil(workout.strain)
        XCTAssertNil(workout.activeEnergyKilocalories)
        XCTAssertNil(workout.zoneSeconds)
        XCTAssertEqual(workout.activityType, "Strength")
    }

    func testMetadataOnlyActivityEditorSavesWindowNameAndTypeAtomically() throws {
        let store = SessionStore()
        let marker = "metadata-only-edit-" + UUID().uuidString
        let start = Date(timeIntervalSince1970: 2_110_000_000 + Double.random(in: 0..<100_000))
        let original = try XCTUnwrap(store.confirmWorkoutWindowForUI(
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
                _ = store.deleteConfirmedWorkout(id: workout.id)
            }
        }

        let editedStart = start.addingTimeInterval(-5 * 60)
        let editedEnd = start.addingTimeInterval(42 * 60)
        let revisionBeforeSave = store.confirmedWorkoutsRevision
        let saved = try XCTUnwrap(store.editConfirmedWorkout(
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

    func testActivitySubtypeCommitsAtomicallyAndCannotLeakAcrossTypeChanges() throws {
        let store = SessionStore()
        let marker = "subtype-atomicity-" + UUID().uuidString
        let start = Date(timeIntervalSince1970: 2_115_000_000 + Double.random(in: 0..<100_000))
        let original = try XCTUnwrap(store.confirmWorkoutWindowForUI(
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
                _ = store.deleteConfirmedWorkout(id: workout.id)
            }
        }

        let revisionBeforeStyle = store.confirmedWorkoutsRevision
        let styled = try store.editConfirmedWorkout(id: original.id,
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

        let changedType = try store.editConfirmedWorkout(id: styled.id,
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

    func testExplicitWorkoutPersistsStrengthLogAndPausedIntervals() throws {
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
        let workout = try XCTUnwrap(store.confirmWorkoutWindowForUI(
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
        defer { _ = store.deleteConfirmedWorkout(id: workout.id) }

        XCTAssertEqual(workout.strengthSets, [set])
        XCTAssertEqual(workout.excludedIntervals, [pause])

        let decoded = try JSONDecoder().decode(
            UserConfirmedWorkout.self,
            from: JSONEncoder().encode(workout)
        )
        XCTAssertEqual(decoded.strengthSets, [set])
        XCTAssertEqual(decoded.excludedIntervals, [pause])
    }

    func testActivityEditorPreservesStrengthLogAndPausedIntervals() throws {
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
        let original = try XCTUnwrap(store.confirmWorkoutWindowForUI(
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
                _ = store.deleteConfirmedWorkout(id: workout.id)
            }
        }

        let revisionBeforeSave = store.confirmedWorkoutsRevision
        let saved = try XCTUnwrap(store.editConfirmedWorkout(
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
        XCTAssertEqual(store.confirmedWorkoutsRevision, revisionBeforeSave + 1,
                       "Name, type, time, sets and pause state must commit in one durable revision")
    }

    func testActivityEditorRederivesMetricsWithoutCountingPreservedPauseIntervals() throws {
        let store = SessionStore()
        let marker = "pause-aware-edit-" + UUID().uuidString
        let sessionID = UUID()
        let start = Date(timeIntervalSince1970: 2_140_000_000 + Double.random(in: 0..<100_000))
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
        let original = try XCTUnwrap(store.confirmWorkoutWindowForUI(
            start: start,
            end: end,
            rest: 60,
            maxHR: 190,
            source: marker,
            activityType: "Strength",
            excludedIntervals: [pause],
            reviewSource: marker
        ))
        defer {
            for workout in store.confirmedWorkouts where workout.reviewSource == marker {
                _ = store.deleteConfirmedWorkout(id: workout.id)
            }
            store.deleteSession(id: sessionID)
        }

        XCTAssertEqual(original.zoneSeconds?["max"] ?? 0, 0, accuracy: 0.001)
        let saved = try XCTUnwrap(store.editConfirmedWorkout(
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
                                               startingStepCount: 120,
                                               startingDayStrain: 4.2)

        XCTAssertTrue(intent.save(defaults: defaults))
        XCTAssertEqual(AtriaPendingWorkoutIntent.load(defaults: defaults), intent)
        AtriaPendingWorkoutIntent.clear(defaults: defaults)
        XCTAssertNil(AtriaPendingWorkoutIntent.load(defaults: defaults))
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
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(AtriaPendingWorkoutIntent.self, from: legacyData)
        XCTAssertNil(decoded.pauseStartedAt)
        XCTAssertEqual(decoded.startedAt, start)
    }

    func testActivityEditorCommitIsAtomicAcrossWindowNameAndType() throws {
        let store = SessionStore()
        let sessionID = UUID()
        let marker = "atomic-edit-" + UUID().uuidString
        let start = Date(timeIntervalSince1970: 2_000_000_000)
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

        let original = try XCTUnwrap(store.confirmWorkoutWindowForUI(
            start: start,
            end: end,
            rest: 60,
            maxHR: 190,
            source: marker,
            activityType: "Cardio",
            reviewSource: marker
        ))
        defer {
            for workout in store.confirmedWorkouts where workout.reviewSource == marker {
                _ = store.deleteConfirmedWorkout(id: workout.id)
            }
            store.deleteSession(id: sessionID)
        }

        let beforeFailure = store.confirmedWorkouts
        let missingDataStart = end.addingTimeInterval(24 * 60 * 60)
        let failed = store.editConfirmedWorkout(id: original.id,
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
        let saved = try XCTUnwrap(store.editConfirmedWorkout(
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
        let old = sparseConfirmedWorkout(start: start,
                                         end: end,
                                         samples: 2,
                                         coverage: 3,
                                         strengthSets: [set],
                                         excludedIntervals: [pause])
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
        XCTAssertEqual(result.reason, "historical_archive_real_hr")
        XCTAssertGreaterThan(result.avgHR, 0)
        XCTAssertNotNil(result.strain)
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
                                                  coverage: 74)
        let complete = sparseConfirmedWorkout(start: start,
                                              end: end,
                                              samples: 1_100,
                                              coverage: 75)

        XCTAssertFalse(SessionStore.historicalRecoveryRequestIsSatisfied(
            original: original,
            replacement: subThreshold,
            requestedStart: start,
            requestedEnd: end
        ), "Improvement below 75% must remain pending")
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

    func testWorkoutEndDismissesBeforeCompletionAwarePersistenceAndKeepsIntentUntilFlush() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let source = try String(
            contentsOf: testsDirectory.deletingLastPathComponent()
                .appendingPathComponent("Atria/AtriaHomeView.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "private func endWorkoutSession(startedAt: Date,"))
        let tail = String(source[start.lowerBound...])
        let intent = try XCTUnwrap(tail.range(of: "persistPendingWorkoutProgress(endedAt: endedAt)"))
        let dismiss = try XCTUnwrap(tail.range(of: "workoutSession = nil"))
        let delayedWork = try XCTUnwrap(tail.range(of: "Task { @MainActor in"))

        XCTAssertLessThan(intent.lowerBound, dismiss.lowerBound)
        XCTAssertLessThan(dismiss.lowerBound, delayedWork.lowerBound)
        XCTAssertTrue(tail.contains("requestPersistenceFlush(reason: \"live_workout_end_checkpoint\")"))
        XCTAssertTrue(tail.contains("flushScheduledPersistenceAsync(reason: \"live_workout_end_confirmed\")"))
        XCTAssertFalse(tail.contains("flushScheduledPersistence(reason: \"live_workout_end\")"))
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

        XCTAssertTrue(saveFlow.contains("shareSnapshot: workoutShareSnapshot(for: confirmed)"))
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
}
