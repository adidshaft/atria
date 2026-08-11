import XCTest
@testable import Atria

@MainActor
final class AtriaRecoveredDataMutationTransactionTests: XCTestCase {
    private typealias Ticket = AtriaRecoveredDataRecomputeCoordinator.Ticket

    private final class RevokingCheckpoint: @unchecked Sendable {
        private let lock = NSLock()
        private let accepted: Int
        private(set) var visits = 0

        init(accepted: Int) { self.accepted = accepted }

        func shouldContinue() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            visits += 1
            return visits <= accepted
        }
    }

    private func workout(_ id: String, startOffset: TimeInterval) -> UserConfirmedWorkout {
        let start = Date(timeIntervalSince1970: 1_784_992_347 + startOffset)
        return UserConfirmedWorkout(id: id,
                                    createdAt: start,
                                    start: start,
                                    end: start.addingTimeInterval(360),
                                    label: "Walking",
                                    source: "live_workout_window",
                                    confidence: "live_window_manual_confirmed",
                                    sessions: 1,
                                    samples: 367,
                                    avgHR: 97,
                                    peakHR: 110,
                                    p95HR: 108,
                                    p99HR: 109,
                                    thresholdHR: 130,
                                    streamCoveragePercent: 100,
                                    observedDuration: 358.5,
                                    reason: "duration_below_10m_and_hr_below_threshold",
                                    activityType: "Walking",
                                    zoneSeconds: [:])
    }

    private func mutatedLabelWorkout(_ id: String, startOffset: TimeInterval) -> UserConfirmedWorkout {
        let base = workout(id, startOffset: startOffset)
        return UserConfirmedWorkout(id: base.id,
                                    createdAt: base.createdAt,
                                    start: base.start,
                                    end: base.end,
                                    label: "MutatedByRecoveredRun",
                                    source: base.source,
                                    confidence: base.confidence,
                                    sessions: base.sessions,
                                    samples: base.samples,
                                    avgHR: base.avgHR,
                                    peakHR: base.peakHR,
                                    p95HR: base.p95HR,
                                    p99HR: base.p99HR,
                                    thresholdHR: base.thresholdHR,
                                    streamCoveragePercent: base.streamCoveragePercent,
                                    observedDuration: base.observedDuration,
                                    reason: base.reason,
                                    activityType: base.activityType,
                                    zoneSeconds: base.zoneSeconds)
    }

    private func sleep(
        _ id: String,
        startOffset: TimeInterval,
        reason: String = "original"
    ) -> UserConfirmedSleep {
        let start = Date(timeIntervalSince1970: 1_800_000_000 + startOffset)
        let end = start.addingTimeInterval(7_200)
        return UserConfirmedSleep(
            id: id,
            createdAt: end,
            start: start,
            end: end,
            source: "sleep_window",
            confidence: "user_confirmed_hr_only",
            sessions: 1,
            samples: 120,
            avgHR: 60,
            peakHR: 70,
            restingHR: 55,
            hrv: nil,
            hrvWindowCount: nil,
            duration: end.timeIntervalSince(start),
            span: end.timeIntervalSince(start),
            reason: reason,
            motionSource: "unvalidated",
            motionValidated: false,
            stageSegments: nil,
            eventTimeZoneIdentifier: "UTC"
        )
    }

    private func mainSleep(
        _ id: String,
        start: Date,
        end: Date
    ) -> UserConfirmedSleep {
        UserConfirmedSleep(
            id: id,
            createdAt: end,
            start: start,
            end: end,
            source: "manual_sleep",
            confidence: "user_confirmed_hr_only",
            sessions: 1,
            samples: 120,
            avgHR: 60,
            peakHR: 70,
            restingHR: 55,
            hrv: nil,
            hrvWindowCount: nil,
            duration: end.timeIntervalSince(start),
            span: end.timeIntervalSince(start),
            reason: "cooperative fixture",
            motionSource: "manual",
            motionValidated: false,
            stageSegments: nil,
            eventTimeZoneIdentifier: "UTC"
        )
    }

    private var profile: AthleteProfile {
        AthleteProfile(
            age: 30,
            measuredMaxHR: 190,
            maxHRSource: .measured,
            updated: nil,
            hasCompletedOnboarding: true
        )
    }

    func testRollbackKeepsWorkoutsConfirmedWhileTheRecoveredRunWasDeriving() {
        // 2026-07-25: a manual 6-minute walk was confirmed and durably written
        // (confirmed-workouts.json held 40 records), and a relaunch brought the
        // file back to 39 with that id gone. Rollback must undo the recovered
        // run, not discard what the live pipeline confirmed during it.
        let preRun = [workout("old-a", startOffset: -8_000),
                      workout("old-b", startOffset: -4_000)]
        let liveAddition = workout("1784992347-1784992707-live_workout_window",
                                   startOffset: 0)

        let merged = SessionStore.mergeConfirmedWorkoutsPreservingLiveAdditions(
            preRun: preRun,
            current: preRun + [liveAddition]
        )
        XCTAssertEqual(merged.count, 3)
        XCTAssertTrue(merged.contains { $0.id == liveAddition.id },
                      "a user-confirmed workout added during the run must survive rollback")
        // Newest first, matching the store's ordering.
        XCTAssertEqual(merged.first?.id, liveAddition.id)
    }

    func testRollbackStillUndoesRecoveredRunMutationsToPreExistingWorkouts() {
        // Pre-run records win on id, so a genuine recovered-run mutation is
        // still undone — otherwise rollback would be a no-op.
        let preRun = [workout("shared", startOffset: -4_000)]
        let mutated = mutatedLabelWorkout("shared", startOffset: -4_000)

        let merged = SessionStore.mergeConfirmedWorkoutsPreservingLiveAdditions(
            preRun: preRun,
            current: [mutated]
        )
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.label, "Walking", "the pre-run image must win on id")
    }

    func testLifecycleRollbackRebasesConcurrentSleepAddEditAndDelete() {
        let originalA = sleep("a", startOffset: -20_000)
        let originalB = sleep("b", startOffset: -10_000)
        let editedA = sleep(
            "a",
            startOffset: -20_000,
            reason: "manual bounds edit during recovered derivation"
        )
        let addedC = sleep("c", startOffset: 0, reason: "manual confirm")

        let merged = SessionStore
            .mergeConfirmedSleepsPreservingConcurrentAuthority(
                preRun: [originalA, originalB],
                concurrentUpserts: [editedA.id: editedA, addedC.id: addedC],
                concurrentDeletedIDs: [originalB.id]
            )

        XCTAssertEqual(merged.map(\.id), ["c", "a"])
        XCTAssertEqual(
            merged.first(where: { $0.id == "a" })?.reason,
            editedA.reason,
            "a user edit after the snapshot must win over rollback"
        )
        XCTAssertFalse(merged.contains { $0.id == "b" },
                       "a concurrent delete must not be resurrected")
        XCTAssertTrue(merged.contains { $0.id == "c" },
                      "a concurrent manual confirmation must survive")
        XCTAssertFalse(merged.contains { $0.id == "recovered-provisional" },
                       "rollback may restore no recovered-owned provisional row")
    }

    func testConcurrentSleepMutationDeltaTracksEditsAddsAndTombstones() {
        let originalA = sleep("a", startOffset: -20_000)
        let originalB = sleep("b", startOffset: -10_000)
        let editedA = sleep("a", startOffset: -20_000, reason: "edited")
        let addedC = sleep("c", startOffset: 0, reason: "added")

        let delta = SessionStore.confirmedSleepMutationDelta(
            base: [originalA, originalB],
            desired: [editedA, addedC]
        )
        XCTAssertEqual(delta.deletedIDs, [originalB.id])
        XCTAssertEqual(delta.upserts[editedA.id], editedA)
        XCTAssertEqual(delta.upserts[addedC.id], addedC)
    }

    func testOrdinarySleepWriterRetainsDeltaAfterLifecycleGenerationLoss() {
        XCTAssertTrue(
            SessionStore.confirmedSleepWriteMustRecordConcurrentAuthority(
                transactionOrRollbackWasActiveAtStart: true,
                transactionOrRollbackIsActiveAtCompletion: false,
                recoveredOwnedMutation: false,
                completedGeneration: 41,
                requestedGeneration: 41,
                currentGeneration: 42
            ),
            "rollback generation supersession must not erase a user write that already persisted"
        )
        XCTAssertFalse(
            SessionStore.confirmedSleepWriteMustRecordConcurrentAuthority(
                transactionOrRollbackWasActiveAtStart: true,
                transactionOrRollbackIsActiveAtCompletion: false,
                recoveredOwnedMutation: true,
                completedGeneration: 41,
                requestedGeneration: 41,
                currentGeneration: 42
            ),
            "a stale recovered-owned repair must never enter the user-authority rebase"
        )
        XCTAssertFalse(
            SessionStore.confirmedSleepWriteMustRecordConcurrentAuthority(
                transactionOrRollbackWasActiveAtStart: true,
                transactionOrRollbackIsActiveAtCompletion: false,
                recoveredOwnedMutation: false,
                completedGeneration: 40,
                requestedGeneration: 41,
                currentGeneration: 42
            ),
            "a result from another writer generation is not this mutation's authority"
        )
        XCTAssertTrue(
            SessionStore.confirmedSleepWriteMustRecordConcurrentAuthority(
                transactionOrRollbackWasActiveAtStart: false,
                transactionOrRollbackIsActiveAtCompletion: true,
                recoveredOwnedMutation: false,
                completedGeneration: 41,
                requestedGeneration: 41,
                currentGeneration: 41
            ),
            "a writer that acquired the gate before transaction start must join the current rollback rebase when it completes"
        )
    }

    func testRecoveredSnapshotRefusesPreTransactionConfirmedWriter() async {
        let gate = AtriaConfirmedRecordTransactionGate()
        XCTAssertTrue(SessionStore.recoveredMutationSnapshotCanRegister(
            confirmedRecordTransactionHasActiveOwner: false
        ))
        await gate.acquire()
        XCTAssertTrue(gate.hasActiveOwner)
        XCTAssertFalse(SessionStore.recoveredMutationSnapshotCanRegister(
            confirmedRecordTransactionHasActiveOwner: gate.hasActiveOwner
        ), "a writer that predates the ticket must finish before snapshot admission")
        gate.release()
        XCTAssertFalse(gate.hasActiveOwner)
    }

    func testFinalRecoveredComponentWaitsForDurableCheckpointCompletion() {
        XCTAssertTrue(
            SessionStore.recoveredComponentRequiresCheckpointPersistence(
                succeeded: true,
                pendingComponentCount: 1,
                checkpointPersistenceCompleted: false
            )
        )
        XCTAssertFalse(
            SessionStore.recoveredComponentRequiresCheckpointPersistence(
                succeeded: true,
                pendingComponentCount: 2,
                checkpointPersistenceCompleted: false
            ),
            "an interior component must not enter the publication checkpoint"
        )
        XCTAssertFalse(
            SessionStore.recoveredComponentRequiresCheckpointPersistence(
                succeeded: false,
                pendingComponentCount: 1,
                checkpointPersistenceCompleted: false
            ),
            "failed derivation cannot persist a publishable checkpoint"
        )
        XCTAssertFalse(
            SessionStore.recoveredComponentRequiresCheckpointPersistence(
                succeeded: true,
                pendingComponentCount: 1,
                checkpointPersistenceCompleted: true
            ),
            "the persistence callback may complete the component exactly once"
        )
    }

    func testRecoveredCheckpointActivationRejectsProvisionalGeneration() {
        XCTAssertTrue(
            SessionStore.recoveredCurrentCheckpointPublicationIsCommitted(
                checkpointIdentity: nil,
                committedIdentity: nil
            ),
            "legacy schema-2 checkpoints remain compatible"
        )
        XCTAssertFalse(
            SessionStore.recoveredCurrentCheckpointPublicationIsCommitted(
                checkpointIdentity: "generation-a",
                committedIdentity: nil
            )
        )
        XCTAssertFalse(
            SessionStore.recoveredCurrentCheckpointPublicationIsCommitted(
                checkpointIdentity: "generation-a",
                committedIdentity: "generation-b"
            )
        )
        XCTAssertTrue(
            SessionStore.recoveredCurrentCheckpointPublicationIsCommitted(
                checkpointIdentity: "generation-a",
                committedIdentity: "generation-a"
            )
        )
    }

    func testRecoveredSleepSavePreparesCorpusOffMainBeforeBoundedInstall()
        throws {
        let testsDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: testsDirectory.deletingLastPathComponent()
                .appendingPathComponent("Atria/Sessions.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(
            of: "private func saveConfirmedSleeps("
        ))
        let end = try XCTUnwrap(source.range(
            of: "/// Learned sleep window for the capture duty cycle",
            range: start.upperBound..<source.endIndex
        ))
        let path = String(source[start.lowerBound..<end.lowerBound])
        let detached = try XCTUnwrap(path.range(
            of: "DispatchQueue.global(qos: .utility).async"
        ))
        let preparation = try XCTUnwrap(path.range(
            of: "Self.prepareConfirmedSleepSave("
        ))
        let install = try XCTUnwrap(path.range(
            of: "setCachedConfirmedSleeps("
        ))
        XCTAssertLessThan(detached.lowerBound, preparation.lowerBound)
        XCTAssertLessThan(preparation.lowerBound, install.lowerBound)
        XCTAssertTrue(path.contains(
            "if deferDerivedPublication,\n               let rebuiltBaseline = preparation.rebuiltBaseline"
        ))
        XCTAssertTrue(path.contains(
            "if !deferDerivedPublication {\n            sleepHistorySnapshot = SleepHistorySnapshot("
        ))
        XCTAssertFalse(path.contains(
            "let existingNeedByID = Dictionary(uniqueKeysWithValues: authoritativeCurrent.compactMap"
        ), "the MainActor save edge must not materialize confirmed-sleep maps")

        let concurrentLog = try XCTUnwrap(path.range(
            of: "confirmedSleepWriteMustRecordConcurrentAuthority("
        ))
        let staleGeneration = try XCTUnwrap(path.range(
            of: "guard generation == confirmedRecordWriteGeneration"
        ))
        XCTAssertLessThan(
            concurrentLog.lowerBound,
            staleGeneration.lowerBound,
            "a durable ordinary writer must log its delta before stale-generation rejection"
        )
    }

    func testRecoveredSleepRepairYieldsToConcurrentAddEditAndDelete() {
        let originalA = sleep("a", startOffset: -20_000)
        let originalB = sleep("b", startOffset: -10_000)
        let recoveredRepairA = sleep(
            "a",
            startOffset: -20_000,
            reason: "recovered stage repair"
        )
        let userEditedA = sleep(
            "a",
            startOffset: -20_000,
            reason: "user bounds edit"
        )
        let userAddedC = sleep("c", startOffset: 0, reason: "user confirm")

        let rebased = SessionStore.rebasedRecoveredConfirmedSleeps(
            base: [originalA, originalB],
            desired: [recoveredRepairA, originalB],
            current: [userEditedA, userAddedC]
        )

        XCTAssertEqual(rebased.map(\.id), ["a", "c"])
        XCTAssertEqual(rebased.first(where: { $0.id == "a" }), userEditedA,
                       "a recovered field repair cannot overwrite a newer user edit")
        XCTAssertFalse(rebased.contains { $0.id == "b" },
                       "a user delete cannot be resurrected")
        XCTAssertTrue(rebased.contains { $0.id == "c" },
                      "an independent user confirmation must survive")

        let uncontended = SessionStore.rebasedRecoveredConfirmedSleeps(
            base: [originalA],
            desired: [recoveredRepairA],
            current: [originalA]
        )
        XCTAssertEqual(uncontended, [recoveredRepairA])
    }

    func testSleepHistoryConstructionAbortsInsideConfirmedCorpus() {
        let corpus = (0..<1_024).map {
            sleep("sleep-\($0)", startOffset: TimeInterval($0 * 10_000))
        }
        let checkpoint = RevokingCheckpoint(accepted: 3)
        let snapshot = SleepHistorySnapshot(
            rollups: [],
            confirmedSleeps: corpus,
            shouldContinue: checkpoint.shouldContinue
        )
        XCTAssertTrue(snapshot.nights.isEmpty)
        XCTAssertLessThanOrEqual(checkpoint.visits, 4,
            "cancellation must stop before walking the remaining corpus")
    }

    func testSleepHistoryChecksAuthorityBeforeFilteringEvidenceLessRollups() {
        let reference = Date(timeIntervalSince1970: 1_800_000_000)
        let rollups = (0..<4_096).map { index in
            DailyRollup(
                day: reference.addingTimeInterval(TimeInterval(index) * 86_400),
                sessions: 0,
                activityCandidates: 0,
                workouts: 0,
                confirmedWorkouts: 0,
                restCandidates: 0,
                sleepReady: 0,
                sleepCandidates: index == 0 ? 1 : 0,
                duration: 6 * 60 * 60,
                sleepDuration: nil,
                sleepSpan: nil,
                sleepStart: nil,
                sleepEnd: nil,
                sleepSource: nil,
                sleepStageSegments: [],
                strain: 0,
                avgHRV: nil,
                restingHR: nil,
                avgRespiratoryRate: nil
            )
        }
        let checkpoint = RevokingCheckpoint(accepted: 8)

        let snapshot = SleepHistorySnapshot(
            rollups: rollups,
            confirmedSleeps: [],
            shouldContinue: checkpoint.shouldContinue
        )

        XCTAssertTrue(snapshot.nights.isEmpty)
        XCTAssertEqual(checkpoint.visits, 9,
            "evidence-less rows must reach the same bounded authority checkpoint")
    }

    func testBaselineRebuildCancelsInsideConfirmedSleepOverlapScan() {
        let sessionStart = Date(timeIntervalSince1970: 1_800_000_000)
        let session = SavedSession(
            id: UUID(),
            start: sessionStart,
            end: sessionStart.addingTimeInterval(60 * 60),
            label: "overlap scan fixture",
            points: [
                SavedSession.Point(t: 0, bpm: 55),
                SavedSession.Point(t: 60 * 60, bpm: 58),
            ]
        )
        var sleeps = (0..<2_048).map { index in
            let start = sessionStart.addingTimeInterval(
                TimeInterval(index + 2) * 24 * 60 * 60
            )
            return mainSleep(
                "non-overlap-\(index)",
                start: start,
                end: start.addingTimeInterval(6 * 60 * 60)
            )
        }
        sleeps.append(mainSleep(
            "eventual-overlap",
            start: sessionStart.addingTimeInterval(-60 * 60),
            end: session.end
        ))
        let checkpoint = RevokingCheckpoint(accepted: 4)

        let rebuilt = SessionStore.rebuildBaselineCancellable(
            from: [session],
            previousBaseline: PersonalBaseline(),
            profile: profile,
            confirmedSleeps: sleeps,
            shouldContinue: checkpoint.shouldContinue
        )

        XCTAssertNil(rebuilt)
        XCTAssertEqual(checkpoint.visits, 5,
            "revocation must stop the inner sleep-overlap walk")
    }

    func testConfirmedSleepExactWindowHRVScanIsCancellable() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let rrPoints = stride(from: 1.0, through: 16 * 60.0, by: 1.0).map {
            SavedSession.RRPoint(
                t: $0,
                ms: Int($0).isMultiple(of: 2) ? 980 : 1_020,
                source: .standardHeartRateMeasurement2A37
            )
        }
        let session = SavedSession(
            id: UUID(),
            start: start,
            end: start.addingTimeInterval(6 * 60 * 60),
            label: "exact-window RR fixture",
            points: [SavedSession.Point(t: 0, bpm: 52)],
            hrv: 42,
            rrPoints: rrPoints
        )
        let sleep = mainSleep(
            "exact-window-sleep",
            start: start,
            end: session.end
        )
        let checkpoint = RevokingCheckpoint(accepted: 10)

        let evidence = SessionStore.confirmedMainSleepHRVEvidenceCancellable(
            for: session,
            confirmedSleeps: [sleep],
            shouldContinue: checkpoint.shouldContinue
        )

        XCTAssertNil(evidence)
        XCTAssertEqual(checkpoint.visits, 11,
            "revocation must interrupt the exact RR-window row scan")
    }

    func testBaselineRebuildCancelsInsideFinalCanonicalSleepSeed() {
        let reference = Date(timeIntervalSince1970: 1_800_000_000)
        let sleeps = (0..<2_048).map { index in
            let end = reference.addingTimeInterval(
                TimeInterval(index) * 24 * 60 * 60
            )
            return mainSleep(
                "seed-\(index)",
                start: end.addingTimeInterval(-6 * 60 * 60),
                end: end
            )
        }
        let checkpoint = RevokingCheckpoint(accepted: 6)

        let rebuilt = SessionStore.rebuildBaselineCancellable(
            from: [],
            previousBaseline: PersonalBaseline(),
            profile: profile,
            confirmedSleeps: sleeps,
            shouldContinue: checkpoint.shouldContinue
        )

        XCTAssertNil(rebuilt)
        XCTAssertEqual(checkpoint.visits, 7,
            "the final canonical seed must not finish after authority revocation")
    }

    func testHomeAggregateCarriesConfirmedSleepRevisionInCacheIdentity() {
        let aggregate = SessionStore.homeSavedAggregate(
            from: [],
            rest: 55,
            maxHR: 190,
            biologicalSex: .unspecified,
            confirmedSleepsRevision: 17
        )
        XCTAssertEqual(aggregate.confirmedSleepsRevision, 17)
    }

    func testRecoveredInstallFencesCanonicalAndPhysiologicalSleepRevisions() {
        XCTAssertTrue(SessionStore.recoveredProjectionSourceRevisionsAreCurrent(
            canonicalRevision: 41,
            expectedCanonicalRevision: 41,
            confirmedSleepsRevision: 9,
            expectedConfirmedSleepsRevision: 9
        ))
        XCTAssertFalse(SessionStore.recoveredProjectionSourceRevisionsAreCurrent(
            canonicalRevision: 42,
            expectedCanonicalRevision: 41,
            confirmedSleepsRevision: 9,
            expectedConfirmedSleepsRevision: 9
        ))
        XCTAssertFalse(SessionStore.recoveredProjectionSourceRevisionsAreCurrent(
            canonicalRevision: 41,
            expectedCanonicalRevision: 41,
            confirmedSleepsRevision: 10,
            expectedConfirmedSleepsRevision: 9
        ), "a second-sleep edit/delete must fence an obsolete wake cutoff")
    }

    func testCurrentCycleSleepInstallUsesCapturedCanonicalAndSleepRevisions()
        throws {
        let testsDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: testsDirectory.deletingLastPathComponent()
                .appendingPathComponent("Atria/Sessions.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(
            of: "private func runRecoveredCurrentCyclePublicationStep("
        ))
        let end = try XCTUnwrap(source.range(
            of: "private func runRecoveredArchiveStatusStep(",
            range: start.upperBound..<source.endIndex
        ))
        let path = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(path.contains(
            "let sourceCanonicalRevision = self.canonicalSessionsRevision"
        ))
        XCTAssertTrue(path.contains(
            "let sourceConfirmedSleepsRevision ="
        ))
        XCTAssertTrue(path.contains(
            "Self.recoveredProjectionSourceRevisionsAreCurrent("
        ))
        let capture = try XCTUnwrap(path.range(
            of: "let sourceCanonicalRevision = self.canonicalSessionsRevision"
        ))
        let worker = try XCTUnwrap(path.range(
            of: "Self.historySnapshotProjectionQueue.async"
        ))
        let install = try XCTUnwrap(path.range(
            of: "self.sleepHistorySnapshot = prepared"
        ))
        let fence = try XCTUnwrap(path.range(
            of: "Self.recoveredProjectionSourceRevisionsAreCurrent("
        ))
        XCTAssertLessThan(capture.lowerBound, worker.lowerBound)
        XCTAssertLessThan(fence.lowerBound, install.lowerBound)
    }

    func testRecoveredCompactRetryRequiresExactLiveTicketAuthority() {
        XCTAssertTrue(SessionStore.recoveredCompactRetryShouldRun(
            taskIsCancelled: false,
            authorityShouldContinue: true,
            scheduledGeneration: 7,
            currentGeneration: 7
        ))
        XCTAssertFalse(SessionStore.recoveredCompactRetryShouldRun(
            taskIsCancelled: true,
            authorityShouldContinue: true,
            scheduledGeneration: 7,
            currentGeneration: 7
        ))
        XCTAssertFalse(SessionStore.recoveredCompactRetryShouldRun(
            taskIsCancelled: false,
            authorityShouldContinue: false,
            scheduledGeneration: 7,
            currentGeneration: 7
        ))
        XCTAssertFalse(SessionStore.recoveredCompactRetryShouldRun(
            taskIsCancelled: false,
            authorityShouldContinue: true,
            scheduledGeneration: 7,
            currentGeneration: 8
        ), "a retry captured by the old ticket cannot start after suspension")
    }

    func testFinalMutationEnvironmentRejectsInactiveForegroundOnly() {
        XCTAssertTrue(SessionStore.recoveredMainActorMutationEnvironmentAllows(
            applicationIsActive: true,
            isExplicitBackgroundAuthority: false
        ))
        XCTAssertFalse(SessionStore.recoveredMainActorMutationEnvironmentAllows(
            applicationIsActive: false,
            isExplicitBackgroundAuthority: false
        ))
        XCTAssertTrue(SessionStore.recoveredMainActorMutationEnvironmentAllows(
            applicationIsActive: false,
            isExplicitBackgroundAuthority: true
        ), "an exact BGProcessing lease remains independent of scene activity")
    }

    func testForegroundDeferredWorkAuthorityRetainsSkewedRequestAndRunsOnce() throws {
        var authority = AtriaForegroundDeferredWorkAuthority()
        authority.request()

        XCTAssertNil(authority.beginIfAuthorized(
            sceneIsActive: true,
            applicationIsActive: false,
            historicalProjectionIsBackgrounded: false
        ))
        XCTAssertTrue(authority.isPending)
        XCTAssertNil(authority.beginIfAuthorized(
            sceneIsActive: true,
            applicationIsActive: true,
            historicalProjectionIsBackgrounded: true
        ))

        let ticket = try XCTUnwrap(authority.beginIfAuthorized(
            sceneIsActive: true,
            applicationIsActive: true,
            historicalProjectionIsBackgrounded: false
        ))
        XCTAssertTrue(authority.isCurrent(ticket))
        XCTAssertNil(authority.beginIfAuthorized(
            sceneIsActive: true,
            applicationIsActive: true,
            historicalProjectionIsBackgrounded: false
        ), "didBecomeActive and scene-active retries must coalesce while running")

        authority.deferForLostAuthority(ticket)
        let retry = try XCTUnwrap(authority.beginIfAuthorized(
            sceneIsActive: true,
            applicationIsActive: true,
            historicalProjectionIsBackgrounded: false
        ))
        XCTAssertEqual(retry, ticket,
                       "a skew rejection retries the retained request without a source event")
        authority.complete(retry)
        XCTAssertFalse(authority.isPending)
        XCTAssertNil(authority.beginIfAuthorized(
            sceneIsActive: true,
            applicationIsActive: true,
            historicalProjectionIsBackgrounded: false
        ), "one completed foreground request cannot replay")

        authority.request()
        let replacement = try XCTUnwrap(authority.beginIfAuthorized(
            sceneIsActive: true,
            applicationIsActive: true,
            historicalProjectionIsBackgrounded: false
        ))
        XCTAssertNotEqual(replacement, ticket)
        XCTAssertFalse(authority.isCurrent(ticket),
                       "a stale canceled task cannot clear replacement ownership")
    }

    func testRevokedOrdinarySleepSettlementCannotAbsorbRecoveredFence() {
        let fingerprint = SessionStore.ForegroundSleepSettlementFingerprint(
            canonicalSessionsRevision: 10,
            confirmedSleepsRevision: 4,
            restingHR: 55,
            baselineRestingIsTrusted: true,
            baselineRestingIsNearTrusted: true,
            maxHR: 190
        )
        let ordinaryConfiguration = SessionStore
            .ForegroundSleepSettlementConfiguration(
                fingerprint: fingerprint,
                force: false,
                deferDerivedPublication: false,
                evaluationLookbackDays: 7,
                maximumEvaluationSessions: 512,
                autoConfirmLimit: 2,
                compactRetryRemainingAttempts: 1,
                staleRetryRemainingAttempts: 1
            )
        let recoveredConfiguration = SessionStore
            .ForegroundSleepSettlementConfiguration(
                fingerprint: fingerprint,
                force: true,
                deferDerivedPublication: true,
                evaluationLookbackDays: 14,
                maximumEvaluationSessions: 4_096,
                autoConfirmLimit: 14,
                compactRetryRemainingAttempts: 1,
                staleRetryRemainingAttempts: 1
            )
        let ordinaryAuthority = SessionStore
            .ForegroundSleepSettlementAuthority.processForeground(
                generation: 31
            )
        let g1 = SessionStore.ForegroundSleepSettlementPendingOwner(
            workerGeneration: 1,
            authority: ordinaryAuthority,
            configuration: ordinaryConfiguration,
            hasCompletionFence: false
        )

        XCTAssertFalse(
            AtriaHistoricalProjectionForegroundGate.leaseIsCurrent(
                leaseGeneration: 31,
                currentGeneration: 32,
                isBackgrounded: false
            ),
            "quick reactivation must not make the revoked G1 lease valid again"
        )

        let recoveredAuthority = SessionStore
            .ForegroundSleepSettlementAuthority(
                domain: .recoveredForeground,
                generation: 90,
                archiveRevision: 44
            )
        XCTAssertEqual(
            SessionStore.foregroundSleepSettlementAdmission(
                pending: g1,
                requestAuthority: recoveredAuthority,
                requestConfiguration: recoveredConfiguration,
                requestHasCompletionFence: true
            ),
            .supersede(workerGeneration: 1),
            "a fresh recovered fence must start its own compatible worker"
        )

        var pending: SessionStore.ForegroundSleepSettlementPendingOwner? =
            .init(
                workerGeneration: 2,
                authority: recoveredAuthority,
                configuration: recoveredConfiguration,
                hasCompletionFence: true
            )
        XCTAssertEqual(
            SessionStore.foregroundSleepSettlementAdmission(
                pending: pending,
                requestAuthority: recoveredAuthority,
                requestConfiguration: recoveredConfiguration,
                requestHasCompletionFence: true
            ),
            .join(workerGeneration: 2),
            "only the exact recovered authority and configuration may join G2"
        )
        XCTAssertEqual(
            SessionStore.foregroundSleepSettlementAdmission(
                pending: pending,
                requestAuthority: ordinaryAuthority,
                requestConfiguration: ordinaryConfiguration,
                requestHasCompletionFence: false
            ),
            .blockedByIncompatibleFencedOwner(workerGeneration: 2),
            "ordinary fire-and-forget work must retain a live fenced owner"
        )

        var publications = 0
        if SessionStore.foregroundSleepSettlementCompletionIsCurrent(
            completedGeneration: 1,
            pending: pending
        ) {
            publications += 1
            pending = nil
        }
        XCTAssertEqual(publications, 0,
                       "stale G1 completion may not consume G2 ownership")
        if SessionStore.foregroundSleepSettlementCompletionIsCurrent(
            completedGeneration: 2,
            pending: pending
        ) {
            publications += 1
            pending = nil
        }
        if SessionStore.foregroundSleepSettlementCompletionIsCurrent(
            completedGeneration: 2,
            pending: pending
        ) {
            publications += 1
        }
        XCTAssertEqual(publications, 1,
                       "G2 publishes exactly once and rejects duplicate completion")
    }

    func testRecoveredHistoryAdmissionAndUIKitResumeHaveProductionEdges()
        throws {
        let testsDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        let appDirectory = testsDirectory.deletingLastPathComponent()
            .appendingPathComponent("Atria")
        let sessions = try String(
            contentsOf: appDirectory.appendingPathComponent("Sessions.swift"),
            encoding: .utf8
        )
        let historyStart = try XCTUnwrap(sessions.range(
            of: "private func refreshHistorySnapshotCache("
        ))
        let historyEnd = try XCTUnwrap(sessions.range(
            of: "private struct CurrentCycleStepLegacyMigrationAdmission",
            range: historyStart.upperBound..<sessions.endIndex
        ))
        let history = String(
            sessions[historyStart.lowerBound..<historyEnd.lowerBound]
        )
        let worker = try XCTUnwrap(history.range(
            of: "Self.historySnapshotProjectionQueue.asyncAfter"
        ))
        let admission = String(history[..<worker.lowerBound])
        let offMain = String(history[worker.lowerBound...])
        XCTAssertFalse(admission.contains(
            "canonicalSessions(includeActiveJournal: true)"
        ))
        XCTAssertTrue(offMain.contains("loadActiveJournalSessionIfFresh("))
        XCTAssertTrue(offMain.contains("shouldContinue: executionShouldContinue"))

        let app = try String(
            contentsOf: appDirectory.appendingPathComponent("AtriaApp.swift"),
            encoding: .utf8
        )
        let activeNotification = try XCTUnwrap(app.range(
            of: "UIApplication.didBecomeActiveNotification"
        ))
        let activeTail = String(app[activeNotification.lowerBound...])
        XCTAssertTrue(activeTail.contains(
            "resumeRecoveredDataPublicationLeaseForForeground("
        ), "UIKit active must replay a SwiftUI-active admission race")
        XCTAssertTrue(activeTail.contains(
            "scheduleForegroundBLETransitionIfNeeded()"
        ), "UIKit active must also retry deferred BLE/archive work without a source event")

        let lifecycleStart = try XCTUnwrap(app.range(
            of: ".onChange(of: scenePhase)"
        ))
        let lifecycle = String(app[lifecycleStart.lowerBound..<activeNotification.lowerBound])
        let closeProcessGate = try XCTUnwrap(lifecycle.range(
            of: "AtriaHistoricalProjectionForegroundGate.isBackgrounded = true"
        ))
        let suspendRecovered = try XCTUnwrap(lifecycle.range(
            of: "store.suspendRecoveredDataPublicationLeaseForBackground("
        ))
        XCTAssertLessThan(closeProcessGate.lowerBound, suspendRecovered.lowerBound,
                          "Home authority must close before rollback publishers run")

        let schedulerStart = try XCTUnwrap(app.range(
            of: "private func scheduleForegroundBLETransitionIfNeeded()"
        ))
        let schedulerEnd = try XCTUnwrap(app.range(
            of: "private static func registerBackgroundTasks",
            range: schedulerStart.upperBound..<app.endIndex
        ))
        let scheduler = String(app[schedulerStart.lowerBound..<schedulerEnd.lowerBound])
        XCTAssertTrue(scheduler.contains("UIApplication.shared.applicationState == .active"))
        XCTAssertTrue(scheduler.contains("AtriaHistoricalProjectionForegroundGate.isBackgrounded"))
        XCTAssertTrue(scheduler.contains("foregroundBLETransitionAuthority.isCurrent(ticket)"))
        XCTAssertTrue(scheduler.contains("store.resumeDeferredForegroundArchiveWork("))

        let publishStart = try XCTUnwrap(sessions.range(of: "case .publish(let ticket):"))
        let publishEnd = try XCTUnwrap(sessions.range(
            of: "private func armRecoveredDataRecomputeTimeout(",
            range: publishStart.upperBound..<sessions.endIndex
        ))
        let publish = String(sessions[publishStart.lowerBound..<publishEnd.lowerBound])
        XCTAssertTrue(publish.contains(
            "shouldContinueForMainActorMutation("
        ))
        XCTAssertTrue(publish.contains(
            "UIApplication.shared.applicationState == .active"
        ))
        let dashboardPublication = try XCTUnwrap(
            publish.range(of: "publishDashboardRevision()")
        )
        let fencePublication = try XCTUnwrap(
            publish.range(of: "recoveredDataPublicationFence.publish(")
        )
        let diagnosticPublication = try XCTUnwrap(
            publish.range(
                of: "retireRecoveredDataExecutionIfCurrent(\n                    ticket: ticket,\n                    outcome: \"published\""
            )
        )
        XCTAssertLessThan(
            dashboardPublication.lowerBound,
            diagnosticPublication.lowerBound
        )
        XCTAssertLessThan(
            fencePublication.lowerBound,
            diagnosticPublication.lowerBound,
            "the diagnostic publish edge must follow the actual publication fence"
        )
        XCTAssertFalse(
            publish.contains("persistRecoveredCurrentCheckpoint()"),
            "publication may not queue checkpoint I/O and immediately report success"
        )
        let activation = try XCTUnwrap(publish.range(
            of: "recoveredCurrentCheckpointPublicationIdentityKey"
        ))
        XCTAssertLessThan(
            fencePublication.lowerBound,
            activation.lowerBound,
            "a crash-visible checkpoint marker must follow the real fence"
        )
        XCTAssertLessThan(
            activation.lowerBound,
            diagnosticPublication.lowerBound,
            "the diagnostic edge must follow checkpoint activation"
        )

        let completionStart = try XCTUnwrap(sessions.range(
            of: "private func completeRecoveredDataComponent("
        ))
        let completionEnd = try XCTUnwrap(sessions.range(
            of: "/// Re-evaluates only confirmed workouts",
            range: completionStart.upperBound..<sessions.endIndex
        ))
        let completion = String(
            sessions[completionStart.lowerBound..<completionEnd.lowerBound]
        )
        let durableCheckpoint = try XCTUnwrap(completion.range(
            of: "persistRecoveredCurrentCheckpoint("
        ))
        let coordinatorCompletion = try XCTUnwrap(completion.range(
            of: "recoveredDataRecompute.componentCompleted("
        ))
        XCTAssertLessThan(
            durableCheckpoint.lowerBound,
            coordinatorCompletion.lowerBound,
            "the final component must remain pending until checkpoint completion"
        )

        let suspendStart = try XCTUnwrap(sessions.range(
            of: "func suspendRecoveredDataPublicationLeaseForBackground("
        ))
        let suspendEnd = try XCTUnwrap(sessions.range(
            of: "func resumeRecoveredDataPublicationLeaseForForeground(",
            range: suspendStart.upperBound..<sessions.endIndex
        ))
        let suspend = String(
            sessions[suspendStart.lowerBound..<suspendEnd.lowerBound]
        )
        XCTAssertTrue(suspend.contains(
            "pendingRecoveredSleepReadinessRetry?.cancel()"
        ))
    }

    func testLifecycleCanonicalRollbackIsAConstantTimeCOWSwap() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let session = SavedSession(
            id: UUID(),
            start: start,
            end: start.addingTimeInterval(60),
            label: "Recovered",
            points: [],
            hrv: nil
        )
        let captured = Array(repeating: session, count: 250_000)
        let capturedAddress = captured.withUnsafeBufferPointer {
            $0.baseAddress
        }

        let restored = SessionStore
            .boundedRecoveredLifecycleCanonicalRestore(captured)

        XCTAssertEqual(restored.count, captured.count)
        XCTAssertEqual(
            restored.withUnsafeBufferPointer { $0.baseAddress },
            capturedAddress,
            "lifecycle rollback must share the captured buffer, not rebuild or sort it"
        )
    }

    func testRollbackPersistsTheMergedWorkoutImageInsteadOfTheStaleSnapshot() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let appDirectory = testsDirectory.deletingLastPathComponent().appendingPathComponent("Atria")
        let sessions = try String(
            contentsOf: appDirectory.appendingPathComponent("Sessions.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(sessions.range(
            of: "private func restoreRecoveredDataMutationSnapshot("
        )?.lowerBound)
        let end = try XCTUnwrap(sessions.range(
            of: "private func restoreRecoveredDefaultsData(",
            range: start..<sessions.endIndex
        )?.lowerBound)
        let rollback = String(sessions[start..<end])
        let compactRollback = rollback.filter { !$0.isWhitespace }

        XCTAssertTrue(rollback.contains(
            "let restoredConfirmedWorkouts = Self.mergeConfirmedWorkoutsPreservingLiveAdditions("
        ))
        XCTAssertTrue(compactRollback.contains(
            "letrestoredConfirmedWorkoutData=try?JSONEncoder().encode(restoredConfirmedWorkouts)"
        ))
        XCTAssertTrue(compactRollback.contains(
            "restoreRecoveredFileData(restoredConfirmedWorkoutData,"
        ))
        XCTAssertFalse(rollback.contains(
            "restoreRecoveredFileData(snapshot.confirmedWorkoutFileData,"
        ), "the pre-run file bytes must not overwrite workouts saved during derivation")
        XCTAssertTrue(rollback.contains("cachedHomeDashboardDiagnostics = nil"))
        XCTAssertTrue(rollback.contains("cachedHomeSavedAggregate = nil"))
        XCTAssertTrue(rollback.contains("recoveryProjectionCache.invalidate()"))
        XCTAssertTrue(rollback.contains("cachedTodayTRIMP = nil"))
        XCTAssertFalse(rollback.contains(
            "cachedHomeSavedAggregate = snapshot.homeSavedAggregate"
        ), "rollback must not restore a cache keyed to the old sleep boundary")
    }

    func testInjectedFailureRollsEveryCompletedMutationBackInReverseOrder() {
        let transaction = AtriaRecoveredDataMutationTransaction()
        let ticket = Ticket(generation: 7, archiveRevision: 41, reason: "fault_after_sleep")
        var state = ["published"]
        var rollbackOrder: [String] = []

        XCTAssertTrue(transaction.begin(ticket: ticket))
        for component in ["projection", "sleep", "rollup"] {
            let previous = state
            XCTAssertTrue(transaction.registerRollback(ticket: ticket) {
                rollbackOrder.append(component)
                state = previous
            })
            state.append(component)
        }

        XCTAssertEqual(state, ["published", "projection", "sleep", "rollup"])
        XCTAssertTrue(transaction.rollback(ticket: ticket))
        XCTAssertEqual(state, ["published"])
        XCTAssertEqual(rollbackOrder, ["rollup", "sleep", "projection"])
        XCTAssertNil(transaction.activeTicket)
    }

    func testFaultInjectionAfterEveryPipelineBoundaryRestoresPublishedImage() {
        let components = ["projection", "workout", "sleep", "history", "trends"]
        for faultAfter in 1...components.count {
            let transaction = AtriaRecoveredDataMutationTransaction()
            let ticket = Ticket(generation: UInt64(100 + faultAfter),
                                archiveRevision: UInt64(200 + faultAfter),
                                reason: "fault_\(faultAfter)")
            var state = ["published"]
            XCTAssertTrue(transaction.begin(ticket: ticket))

            for component in components.prefix(faultAfter) {
                let previous = state
                XCTAssertTrue(transaction.registerRollback(ticket: ticket) {
                    state = previous
                })
                state.append(component)
            }

            XCTAssertTrue(transaction.rollback(ticket: ticket), "fault boundary \(faultAfter)")
            XCTAssertEqual(state, ["published"], "fault boundary \(faultAfter)")
        }
    }

    func testCommitMakesPreparedMutationPermanentAndCannotLaterRollback() {
        let transaction = AtriaRecoveredDataMutationTransaction()
        let ticket = Ticket(generation: 8, archiveRevision: 42, reason: "success")
        var value = 1

        XCTAssertTrue(transaction.begin(ticket: ticket))
        XCTAssertTrue(transaction.registerRollback(ticket: ticket) { value = 1 })
        value = 2

        var commitCount = 0
        XCTAssertTrue(transaction.registerCommit(ticket: ticket) { commitCount += 1 })
        XCTAssertTrue(transaction.commit(ticket: ticket))
        XCTAssertFalse(transaction.rollback(ticket: ticket))
        XCTAssertEqual(value, 2)
        XCTAssertEqual(commitCount, 1)
    }

    func testStaleTicketCannotRegisterCommitOrRollbackReplacement() {
        let transaction = AtriaRecoveredDataMutationTransaction()
        let old = Ticket(generation: 9, archiveRevision: 43, reason: "old")
        let replacement = Ticket(generation: 10, archiveRevision: 44, reason: "replacement")
        var value = 0

        XCTAssertTrue(transaction.begin(ticket: old))
        XCTAssertTrue(transaction.registerRollback(ticket: old) { value = 0 })
        value = 1
        XCTAssertTrue(transaction.rollback(ticket: old))

        XCTAssertTrue(transaction.begin(ticket: replacement))
        XCTAssertFalse(transaction.registerRollback(ticket: old) { value = -1 })
        XCTAssertFalse(transaction.commit(ticket: old))
        XCTAssertFalse(transaction.rollback(ticket: old))
        XCTAssertEqual(transaction.activeTicket, replacement)
        XCTAssertEqual(value, 0)
    }

    func testDuplicateBeginFailsClosedInsteadOfDroppingExistingUndoJournal() {
        let transaction = AtriaRecoveredDataMutationTransaction()
        let first = Ticket(generation: 11, archiveRevision: 45, reason: "first")
        let second = Ticket(generation: 12, archiveRevision: 46, reason: "second")
        var value = 3

        XCTAssertTrue(transaction.begin(ticket: first))
        XCTAssertTrue(transaction.registerRollback(ticket: first) { value = 3 })
        value = 4
        XCTAssertFalse(transaction.begin(ticket: second))
        XCTAssertEqual(transaction.activeTicket, first)
        XCTAssertTrue(transaction.rollback(ticket: first))
        XCTAssertEqual(value, 3)
    }

    func testFailureDropsDeferredCommitSideEffects() {
        let transaction = AtriaRecoveredDataMutationTransaction()
        let ticket = Ticket(generation: 13, archiveRevision: 47, reason: "persist_failed")
        var commitCount = 0

        XCTAssertTrue(transaction.begin(ticket: ticket))
        XCTAssertTrue(transaction.registerCommit(ticket: ticket) { commitCount += 1 })
        XCTAssertTrue(transaction.rollback(ticket: ticket))
        XCTAssertEqual(commitCount, 0)
    }

    func testSessionStoreWiresEveryTerminalCoordinatorEffectThroughTransaction() throws {
        let testsURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsURL.deletingLastPathComponent()
            .appendingPathComponent("Atria/Sessions.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let compactSource = source.filter { !$0.isWhitespace }

        XCTAssertTrue(source.contains("guard beginRecoveredDataMutationTransaction(ticket: ticket)"))
        XCTAssertTrue(compactSource.contains(
            "guardself.registerRecoveredDataMutationSnapshot(ticket:ticket)"
        ))
        XCTAssertTrue(source.contains("rollbackRecoveredDataMutationTransaction(ticket: ticket)"))
        XCTAssertTrue(source.contains("guard commitRecoveredDataMutationTransaction(ticket: ticket)"))
        XCTAssertTrue(source.contains("pendingDailyMetricSaveWorkItem?.cancel()"))
        XCTAssertTrue(source.contains("confirmedWorkoutRehydrationGeneration &+= 1"))
        XCTAssertTrue(source.contains("foregroundSleepSettlementGeneration &+= 1"))
        XCTAssertTrue(source.contains("behaviorInsightsGeneration &+= 1"))
        XCTAssertTrue(source.contains("scheduleDailyMetricPersist(reason: \"recovered_transaction_commit\""))
        XCTAssertTrue(source.contains("recoveredDataMutationTransaction.registerCommit"))
        XCTAssertTrue(source.contains("publishDailyRollupSideEffects(preparation:"))
        XCTAssertTrue(source.contains("publishHistoricalRecoveryWindow("))
        XCTAssertTrue(source.contains("dailyRollupStore.beginRecoveredDataPublicationFence()"))
        XCTAssertTrue(source.contains("dailyRollupStore.endRecoveredDataPublicationFence()"))
    }

    func testNestedRecoveredAndRestoreRollupFencesPersistOnlyAfterBothEnd() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("atria-recovered-rollup-fence-\(UUID().uuidString).json")
        let store = DailyRollupStore(url: url, loadPersisted: false)
        let row = DailyRollupStoreEntry(day: Date(timeIntervalSince1970: 1_783_000_000),
                                        recovery: 77)

        store.beginRecoveredDataPublicationFence()
        await store.beginPersistenceFence()
        store.replaceAll([row])
        store.endRecoveredDataPublicationFence()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "ending one nested owner must not leak the prepared file")

        store.endPersistenceFence()
        let deadline = Date().addingTimeInterval(1)
        var decoded: [DailyRollupStoreEntry] = []
        while Date() < deadline {
            if let data = try? Data(contentsOf: url),
               let rows = try? JSONDecoder().decode([DailyRollupStoreEntry].self, from: data) {
                decoded = rows
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.recovery, row.recovery)
        XCTAssertEqual(decoded.first?.day, row.day)
    }
}
