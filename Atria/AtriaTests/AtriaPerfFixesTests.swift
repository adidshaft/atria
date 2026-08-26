import XCTest
@testable import Atria

/// Deterministic coverage for the 2026-07-08 performance fixes (the original
/// point-in-time handoff remains in Git history). These exercise shipped logic at
/// realistic volumes WITHOUT a live strap session — the crash/jank only
/// manifest during continuous streaming, which unit tests can stand in for by
/// driving the pure functions directly.
// `@MainActor` because the functions under test live on `@MainActor` types
// (AtriaBLEManager / the SwiftUI Health screen); the logic itself is pure.
@MainActor
final class AtriaPerfFixesTests: XCTestCase {
    func testStrainConfidenceRequiresRealRestingHRAndDisclosesEstimatedMaxHR() {
        XCTAssertEqual(AtriaHomeModel.strainConfidence(
            hasRestingHeartRateEvidence: false,
            maxHRSource: .measured,
            hasLoadEvidence: true,
            resolvedRest: 60,
            maxHR: 190
        ), "learning")
        XCTAssertEqual(AtriaHomeModel.strainConfidence(
            hasRestingHeartRateEvidence: true,
            maxHRSource: .ageEstimate,
            hasLoadEvidence: true,
            resolvedRest: 58,
            maxHR: 187
        ), "provisional · age-estimated max HR")
        XCTAssertEqual(AtriaHomeModel.strainConfidence(
            hasRestingHeartRateEvidence: true,
            maxHRSource: .measured,
            hasLoadEvidence: true,
            resolvedRest: 58,
            maxHR: 192
        ), "local")
    }

    func testTachogramBeatIdentityIsStableAcrossAnalysisRefreshes() {
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let first = RRSample(t: timestamp, ms: 800, corrected: false, interpolated: false)
        let refreshed = RRSample(t: timestamp, ms: 805, corrected: true, interpolated: false)

        XCTAssertEqual(first.id, refreshed.id)
    }

    func testWidgetPublishesOnlyValidatedStrapSteps() {
        XCTAssertTrue(WidgetSnapshotPublisher.strapStepsAreValidated(state: "validated"))
        XCTAssertTrue(WidgetSnapshotPublisher.strapStepsAreValidated(state: "r10_live_validated"))
        XCTAssertFalse(WidgetSnapshotPublisher.strapStepsAreValidated(state: "r10_live_preliminary"))
        XCTAssertFalse(WidgetSnapshotPublisher.strapStepsAreValidated(state: "r10_live_calibrating"))
        XCTAssertFalse(WidgetSnapshotPublisher.strapStepsAreValidated(state: "research_unvalidated"))
    }

    func testLiveCheckpointSlowDerivationsAreBoundedButRecoverFromClockChanges() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(SessionStore.shouldRefreshLiveCheckpointDerivedState(
            lastRefreshAt: nil,
            now: now,
            minimumInterval: 900
        ))
        XCTAssertFalse(SessionStore.shouldRefreshLiveCheckpointDerivedState(
            lastRefreshAt: now.addingTimeInterval(-899),
            now: now,
            minimumInterval: 900
        ))
        XCTAssertTrue(SessionStore.shouldRefreshLiveCheckpointDerivedState(
            lastRefreshAt: now.addingTimeInterval(-900),
            now: now,
            minimumInterval: 900
        ))
        XCTAssertTrue(SessionStore.shouldRefreshLiveCheckpointDerivedState(
            lastRefreshAt: now.addingTimeInterval(60),
            now: now,
            minimumInterval: 900
        ))
    }

    func testWorkoutAccumulatorSkipsTheAllDayPrefixOnRebuild() {
        let workoutStart = Date(timeIntervalSince1970: 1_800_100_000)
        let prefixStart = workoutStart.addingTimeInterval(-100_000)
        var samples = (0..<100_000).map {
            HRSample(t: prefixStart.addingTimeInterval(TimeInterval($0)), bpm: 62)
        }
        samples.append(contentsOf: (0...60).map {
            HRSample(t: workoutStart.addingTimeInterval(TimeInterval($0)), bpm: 130)
        })

        XCTAssertEqual(AtriaLiveWorkoutTRIMPAccumulator.firstIntegrationIndex(
            samples: samples,
            startedAt: workoutStart
        ), 100_001)
        XCTAssertEqual(AtriaLiveWorkoutTRIMPAccumulator.firstIntegrationIndex(
            samples: samples,
            startedAt: prefixStart
        ), 1)
        XCTAssertEqual(AtriaLiveWorkoutTRIMPAccumulator.firstIntegrationIndex(
            samples: samples,
            startedAt: workoutStart.addingTimeInterval(120)
        ), samples.count)
    }

    func testOpenWorkoutPauseHasStableAccumulatorIdentityAcrossLiveTicks() {
        let pauseStart = Date(timeIntervalSince1970: 1_800_000_000)
        let closed = [ExcludedInterval(start: pauseStart.addingTimeInterval(-120),
                                       end: pauseStart.addingTimeInterval(-60))]

        let first = AtriaLiveWorkoutTRIMPAccumulator.effectiveExcludedIntervals(
            closedIntervals: closed,
            openPauseStartedAt: pauseStart
        )
        let later = AtriaLiveWorkoutTRIMPAccumulator.effectiveExcludedIntervals(
            closedIntervals: closed,
            openPauseStartedAt: pauseStart
        )

        XCTAssertEqual(first, later)
        XCTAssertEqual(first.dropLast(), closed[...])
        XCTAssertEqual(first.last?.start, pauseStart)
        XCTAssertEqual(first.last?.end, .distantFuture)
    }

    func testLiveActivityProjectionDoesNotRecreateOpenPauseEveryTick() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let source = try String(contentsOf: testsDirectory.deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaHomeView.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private func updateLiveActivity("))
        let end = try XCTUnwrap(source.range(of: "private func liveWorkoutHeartRateAvailability(",
                                             range: start.upperBound..<source.endIndex))
        let update = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(update.contains("AtriaLiveWorkoutTRIMPAccumulator.effectiveExcludedIntervals("))
        XCTAssertTrue(update.contains("openPauseStartedAt: liveWorkoutPauseStartedAt"))
        XCTAssertFalse(update.contains("ExcludedInterval(start: pauseStartedAt, end: now)"))
    }

    func testOverviewLiveSampleProgressUsesTwentyDisplayBuckets() {
        XCTAssertEqual(AtriaOverviewLiveProjectionState.sessionProgressBucket(0), 0)
        XCTAssertEqual(AtriaOverviewLiveProjectionState.sessionProgressBucket(1), 1)
        XCTAssertEqual(AtriaOverviewLiveProjectionState.sessionProgressBucket(36), 1)
        XCTAssertEqual(AtriaOverviewLiveProjectionState.sessionProgressBucket(37), 2)
        XCTAssertEqual(AtriaOverviewLiveProjectionState.sessionProgressBucket(720), 20)
        XCTAssertEqual(AtriaOverviewLiveProjectionState.sessionProgressBucket(50_000), 20)

        let visibleBuckets = Set((0...720).map {
            AtriaOverviewLiveProjectionState.sessionProgressBucket($0)
        })
        XCTAssertEqual(visibleBuckets, Set(0...20))
    }

    func testHeartRatePlausibilityRejectsCorruptPacketsAndHoldsPostGapJumps() {
        XCTAssertEqual(AtriaBLEManager.heartRateHardUpperBound(profileMaxHR: 190), 220)
        XCTAssertEqual(AtriaBLEManager.heartRateHardUpperBound(profileMaxHR: 220), 240)
        XCTAssertTrue(AtriaBLEManager.heartRateIsPhysiologicallyPlausible(0, profileMaxHR: 190))
        XCTAssertTrue(AtriaBLEManager.heartRateIsPhysiologicallyPlausible(220, profileMaxHR: 190))
        XCTAssertFalse(AtriaBLEManager.heartRateIsPhysiologicallyPlausible(19, profileMaxHR: 190))
        XCTAssertFalse(AtriaBLEManager.heartRateIsPhysiologicallyPlausible(221, profileMaxHR: 190))
        XCTAssertFalse(AtriaBLEManager.heartRateIsPhysiologicallyPlausible(65_535, profileMaxHR: 220))

        let held = AtriaBLEManager.hrArtifactJumpDecision(rate: 145,
                                                          median: 90,
                                                          pendingRate: nil,
                                                          pendingAge: nil,
                                                          acceptedGap: 8)
        XCTAssertEqual(held.action, "hold")
        XCTAssertEqual(held.reason, "post_gap_unconfirmed_jump")

        let confirmed = AtriaBLEManager.hrArtifactJumpDecision(rate: 148,
                                                               median: 90,
                                                               pendingRate: 145,
                                                               pendingAge: 2,
                                                               acceptedGap: 8)
        XCTAssertEqual(confirmed.action, "accept")
        XCTAssertEqual(confirmed.reason, "confirmed_jump")
    }


    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Fix #1 — retention-roll trigger (bounds the live session)

    /// Below the retention span the live session is left intact.
    func testRetentionRoll_belowSpanCap_doesNotRoll() {
        // 1s under the 3h (10800s) cap, with plenty of samples.
        XCTAssertFalse(AtriaBLEManager.shouldRollLiveSession(spanSeconds: 10_799,
                                                             sampleCount: 100_000,
                                                             minSamples: 10,
                                                             retentionSpan: 10_800))
    }

    /// At exactly the cap (with enough samples) the session rolls.
    func testRetentionRoll_atSpanCap_rolls() {
        XCTAssertTrue(AtriaBLEManager.shouldRollLiveSession(spanSeconds: 10_800,
                                                            sampleCount: 100_000,
                                                            minSamples: 10,
                                                            retentionSpan: 10_800))
    }

    /// Span past the cap but too few samples must NOT roll (avoids finalizing a
    /// sliver — mirrors the autoSaveMinSamples guard in the live path).
    func testRetentionRoll_spanOKButTooFewSamples_doesNotRoll() {
        XCTAssertFalse(AtriaBLEManager.shouldRollLiveSession(spanSeconds: 20_000,
                                                             sampleCount: 9,
                                                             minSamples: 10,
                                                             retentionSpan: 10_800))
        // Exactly at the sample floor + at the cap => rolls (boundary).
        XCTAssertTrue(AtriaBLEManager.shouldRollLiveSession(spanSeconds: 10_800,
                                                            sampleCount: 10,
                                                            minSamples: 10,
                                                            retentionSpan: 10_800))
    }

    /// The real over-the-cap session pulled off the device (20,291 samples over
    /// ~5.6h continuous "All-day wear") is exactly what the fix now segments;
    /// a typical short segmented session (~9.5min) is left alone.
    func testRetentionRoll_realDeviceSessionShapes() {
        // 20,291 samples, ~5.6h continuous  -> rolls at 3h.
        XCTAssertTrue(AtriaBLEManager.shouldRollLiveSession(spanSeconds: 20_160,
                                                            sampleCount: 20_291,
                                                            minSamples: 10,
                                                            retentionSpan: 10_800))
        // Median device session (~570 samples, ~9.5min) -> never rolls.
        XCTAssertFalse(AtriaBLEManager.shouldRollLiveSession(spanSeconds: 570,
                                                             sampleCount: 570,
                                                             minSamples: 10,
                                                             retentionSpan: 10_800))
    }

    func testProductionSessionBoundariesNeverSynchronouslyWaitOnR10Queue() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsDirectory.deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaBLEManager.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertFalse(source.contains("r10MotionPipeline.currentSnapshotSynchronously()"))
        XCTAssertFalse(source.contains("r10MotionPipeline.rollSegmentSynchronously"))

        let start = try XCTUnwrap(source.range(of: "private func completeSessionBoundary("))
        let end = try XCTUnwrap(source.range(of: "private func waitForSessionInputBatchesToDrain(",
                                             range: start.upperBound..<source.endIndex))
        let body = String(source[start.lowerBound..<end.lowerBound])
        let prepare = try XCTUnwrap(body.range(of: "await motionPreparation.value()"))
        let durable = try XCTUnwrap(body.range(of: "await persistFinishedSessionDurably"))
        let commit = try XCTUnwrap(body.range(of: "await r10MotionPipeline.commitBoundary"))
        let reset = try XCTUnwrap(body.range(of: "resetLiveSessionStateAfterR10Boundary"))
        let release = try XCTUnwrap(body.range(of: "await r10MotionPipeline.releaseCommittedBoundaryFrames"))
        let forceRelease = try XCTUnwrap(body.range(of: "await r10MotionPipeline.forceReleaseCommittedBoundaryFrames"))
        let clearManagerFence = try XCTUnwrap(body.range(of: "r10SessionBoundaryID = nil"))
        XCTAssertLessThan(prepare.lowerBound, durable.lowerBound)
        XCTAssertLessThan(durable.lowerBound, commit.lowerBound)
        XCTAssertLessThan(commit.lowerBound, reset.lowerBound)
        XCTAssertLessThan(reset.lowerBound, release.lowerBound)
        XCTAssertLessThan(release.lowerBound, forceRelease.lowerBound)
        XCTAssertLessThan(forceRelease.lowerBound, clearManagerFence.lowerBound)
        XCTAssertTrue(body.contains("guard releasedMotion else"),
                      "the manager must never clear its boundary or report success with R10 still fenced")
        XCTAssertTrue(body.contains("abortSessionBoundary"),
                      "every failed persistence/commit path must retain the old segment")
        XCTAssertTrue(source.contains("r10MotionPipeline.enqueueBoundaryPreparation()"))
        XCTAssertTrue(body.contains("beginActiveJournalBoundaryFence"))
        XCTAssertTrue(body.contains("endActiveJournalBoundaryFence(id: id, committed: true)"))
        XCTAssertTrue(source.contains("bufferedSessionInputs.append(.heartRate"))
        XCTAssertTrue(source.contains("bufferedSessionInputs.append(.realtime"))
        XCTAssertTrue(source.contains("snapshotGeneration: snapshot.generation"))
    }

    func testLaunchStepLedgerRestorePrecedesActiveJournalR10Boundary() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsDirectory.deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaBLEManager.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        let restoreStart = try XCTUnwrap(
            source.range(of: "private func restoreActiveSessionJournalIfNeeded(reason: String)")
        )
        let restoreEnd = try XCTUnwrap(
            source.range(of: "private func resumeActiveSessionRestoreAfterStrapStepLedger()",
                         range: restoreStart.upperBound..<source.endIndex)
        )
        let restoreBody = String(source[restoreStart.lowerBound..<restoreEnd.lowerBound])
        XCTAssertTrue(restoreBody.contains("guard !strapStepLedgerRestoreInFlight"),
                      "journal recovery must not prepare an R10 boundary before the durable step prefix is seeded")

        let ledgerStart = try XCTUnwrap(
            source.range(of: "private func restoreStrapStepLedgerAtLaunch()")
        )
        let ledgerEnd = try XCTUnwrap(
            source.range(of: "private func scheduleStrapStepLedgerCheckpoint(",
                         range: ledgerStart.upperBound..<source.endIndex)
        )
        let ledgerBody = String(source[ledgerStart.lowerBound..<ledgerEnd.lowerBound])
        let seed = try XCTUnwrap(ledgerBody.range(of: "await self.r10MotionPipeline.seed"))
        let resume = try XCTUnwrap(
            ledgerBody.range(of: "self.resumeActiveSessionRestoreAfterStrapStepLedger()",
                             range: seed.upperBound..<ledgerBody.endIndex)
        )
        XCTAssertLessThan(seed.lowerBound, resume.lowerBound)
        XCTAssertGreaterThanOrEqual(
            ledgerBody.components(separatedBy: "resumeActiveSessionRestoreAfterStrapStepLedger()").count - 1,
            2,
            "both absent-ledger and successful-ledger completion must release deferred journal recovery"
        )

        XCTAssertTrue(source.contains(
            "activeSessionRestoreInFlightGeneration != nil ||\n            strapStepLedgerRestoreInFlight"
        ), "HR and realtime inputs must remain buffered across the launch ordering fence")
    }

    func testSessionBoundarySettlesOldJournalWriterBeforeSuccessOrFailureOutcome() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsDirectory.deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaBLEManager.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let beginStart = try XCTUnwrap(source.range(of: "private func beginActiveJournalBoundaryFence"))
        let endStart = try XCTUnwrap(source.range(of: "private func endActiveJournalBoundaryFence",
                                                  range: beginStart.upperBound..<source.endIndex))
        let abortStart = try XCTUnwrap(source.range(of: "private func abortSessionBoundary(",
                                                    range: endStart.upperBound..<source.endIndex))
        let begin = String(source[beginStart.lowerBound..<endStart.lowerBound])
        let end = String(source[endStart.lowerBound..<abortStart.lowerBound])
        XCTAssertTrue(begin.contains("while activeJournalSaveInFlight"),
                      "clear/reset must wait until the old detached writer and its main callback settle")
        XCTAssertTrue(begin.contains("activeJournalBoundaryFenceID = id"))
        XCTAssertTrue(end.contains("if committed"))
        XCTAssertTrue(end.contains("session_boundary_abort_restore"),
                      "failed SavedSession persistence must re-arm the retained live journal")
        XCTAssertTrue(source.contains("self.activeJournalBoundaryFenceID == nil"),
                      "an old completion must not schedule another write through the boundary fence")
    }

    func testCommittedSessionBoundaryRestartsNewJournalAfterBufferedReplay() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsDirectory.deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaBLEManager.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let boundaryStart = try XCTUnwrap(source.range(of: "private func completeSessionBoundary("))
        let boundaryEnd = try XCTUnwrap(source.range(
            of: "private func waitForSessionInputBatchesToDrain(",
            range: boundaryStart.upperBound..<source.endIndex
        ))
        let body = String(source[boundaryStart.lowerBound..<boundaryEnd.lowerBound])

        let clearManagerFence = try XCTUnwrap(body.range(of: "r10SessionBoundaryID = nil"))
        let replay = try XCTUnwrap(body.range(
            of: "replayBufferedSessionInputs()",
            range: clearManagerFence.upperBound..<body.endIndex
        ))
        let checkpoint = try XCTUnwrap(body.range(
            of: #"\(persistenceReason)_post_boundary_replay"#,
            range: replay.upperBound..<body.endIndex
        ))
        let committedLog = try XCTUnwrap(body.range(
            of: "ATRIADBG session_boundary status=committed",
            range: checkpoint.upperBound..<body.endIndex
        ))

        XCTAssertLessThan(clearManagerFence.lowerBound, replay.lowerBound)
        XCTAssertLessThan(replay.lowerBound, checkpoint.lowerBound)
        XCTAssertLessThan(checkpoint.lowerBound, committedLog.lowerBound)
        XCTAssertTrue(body.contains("if !session.isEmpty"),
                      "an empty new segment must not manufacture a journal")
        let postReplay = String(body[replay.lowerBound..<committedLog.lowerBound])
        XCTAssertTrue(postReplay.contains("persistActiveSessionJournalIfNeeded("))
        XCTAssertTrue(postReplay.contains("force: true"),
                      "the committed boundary must not leave restart durability to a later live callback")
    }

    func testBLEBacklogTrimKeepsFreshestUnconsumedEntries() {
        var queue = Array(0..<10)
        var consumed = 3
        let dropped = AtriaBLEManager.trimPendingQueue(&queue,
                                                       consumedCount: &consumed,
                                                       limit: 4)
        XCTAssertEqual(dropped, 3)
        XCTAssertEqual(consumed, 0)
        XCTAssertEqual(queue, [6, 7, 8, 9])

        var healthyQueue = Array(0..<6)
        var healthyConsumed = 2
        XCTAssertEqual(AtriaBLEManager.trimPendingQueue(&healthyQueue,
                                                        consumedCount: &healthyConsumed,
                                                        limit: 4), 0)
        XCTAssertEqual(healthyQueue, Array(0..<6))
        XCTAssertEqual(healthyConsumed, 2)
    }

    func testHeartRateIngressOverflowIsDurableMissingDataRatherThanSilentDrop() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsDirectory.deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaBLEManager.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let enqueueStart = try XCTUnwrap(source.range(of: "private nonisolated func enqueueHeartRateUpdate"))
        let dequeueStart = try XCTUnwrap(source.range(of: "private nonisolated func dequeuePendingHeartRateUpdateBatch",
                                                       range: enqueueStart.upperBound..<source.endIndex))
        let enqueue = String(source[enqueueStart.lowerBound..<dequeueStart.lowerBound])
        XCTAssertTrue(enqueue.contains("pendingHeartRateIngressOverflows"))
        XCTAssertTrue(enqueue.contains("heartRateIngressDropAttributions(receipts)"))
        XCTAssertTrue(enqueue.contains("callbackSource: $0.callbackSource"),
                      "overflow ownership must come from each evicted receipt")
        XCTAssertTrue(enqueue.contains("firstDroppedAt"))
        XCTAssertTrue(enqueue.contains("lastDroppedAt"))

        let markerStart = try XCTUnwrap(source.range(of: "private func recordHeartRateIngressOverflow"))
        let markerEnd = try XCTUnwrap(source.range(of: "private func handleParsedRealtimePacket",
                                                    range: markerStart.upperBound..<source.endIndex))
        let marker = String(source[markerStart.lowerBound..<markerEnd.lowerBound])
        XCTAssertTrue(marker.contains("AtriaHistoricalGapLedger.recordObservedGap"))
        XCTAssertTrue(marker.contains("markRangeLossBackfillRequired"))
        XCTAssertTrue(marker.contains("persistActiveSessionJournalIfNeeded"))
        XCTAssertTrue(marker.contains("no_interpolation"))
    }

    func testHeartRateOverflowDebtRemainsAttributedToItsProducingLink() throws {
        let fence = AtriaBLECallbackEpochFence()
        let strapID = UUID()
        let retiredPeripheral = NSObject()
        let activePeripheral = NSObject()
        _ = fence.activate(
            peripheralID: strapID,
            peripheralObjectID: ObjectIdentifier(retiredPeripheral)
        )
        let retiredSource = try XCTUnwrap(fence.captureIfAccepted(
            peripheralID: strapID,
            peripheralObjectID: ObjectIdentifier(retiredPeripheral),
            peripheralConnected: true
        ))
        fence.invalidate(
            ifMatching: strapID,
            peripheralObjectID: ObjectIdentifier(retiredPeripheral)
        )
        _ = fence.activate(
            peripheralID: strapID,
            peripheralObjectID: ObjectIdentifier(activePeripheral)
        )
        let activeSource = try XCTUnwrap(fence.captureIfAccepted(
            peripheralID: strapID,
            peripheralObjectID: ObjectIdentifier(activePeripheral),
            peripheralConnected: true
        ))
        let anchor = Date(timeIntervalSinceReferenceDate: 800_700_000)

        // Model the exact overflow edge: two retired-link receipts and one
        // active-link receipt are evicted when a newly appended active packet
        // pushes the queue beyond its bound.
        let attributed = AtriaBLEManager.heartRateIngressDropAttributions([
            .init(receivedAt: anchor, callbackSource: retiredSource),
            .init(receivedAt: anchor.addingTimeInterval(1), callbackSource: activeSource),
            .init(receivedAt: anchor.addingTimeInterval(2), callbackSource: retiredSource)
        ])

        XCTAssertEqual(attributed.count, 2)
        XCTAssertEqual(attributed[0].callbackSource, retiredSource)
        XCTAssertEqual(attributed[0].droppedCount, 2)
        XCTAssertEqual(attributed[0].firstDroppedAt, anchor)
        XCTAssertEqual(attributed[0].lastDroppedAt, anchor.addingTimeInterval(2))
        XCTAssertEqual(attributed[1].callbackSource, activeSource)
        XCTAssertEqual(attributed[1].droppedCount, 1)
        XCTAssertFalse(fence.owns(source: attributed[0].callbackSource),
                       "retired-link debt must be rejected, not charged to the current epoch")
        XCTAssertTrue(fence.owns(source: attributed[1].callbackSource))
    }

    func testLiveStrapStepResearchPublishesEveryChangedPipelineSnapshot() {
        XCTAssertFalse(AtriaBLEManager.shouldPublishLiveStrapStepResearch(currentCount: 12,
                                                                          publishedCount: 12))
        XCTAssertTrue(AtriaBLEManager.shouldPublishLiveStrapStepResearch(currentCount: 1,
                                                                         publishedCount: 0))
        XCTAssertTrue(AtriaBLEManager.shouldPublishLiveStrapStepResearch(currentCount: 4,
                                                                         publishedCount: 1))
        XCTAssertTrue(AtriaBLEManager.shouldPublishLiveStrapStepResearch(currentCount: 6,
                                                                         publishedCount: 1))
        XCTAssertTrue(AtriaBLEManager.shouldPublishLiveStrapStepResearch(currentCount: 4,
                                                                         publishedCount: 1))
        XCTAssertTrue(AtriaBLEManager.shouldPublishLiveStrapStepResearch(currentCount: 0,
                                                                         publishedCount: 42,
                                                                         force: true))

    }


    func testLiveStepWidgetPublisherIsIndependentFromHeartRateChanges() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaHomeView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private var liveStepWidgetUpdates"))
        let end = try XCTUnwrap(source.range(of: "private var workoutDetectionUpdates",
                                             range: start.upperBound..<source.endIndex))
        let publisher = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(publisher.contains("model.coreLiveStore.$state"))
        XCTAssertTrue(publisher.contains("state.strapStepResearchCount"))
        XCTAssertTrue(publisher.contains("state.strapStepResearchState"))
        XCTAssertFalse(publisher.contains("pulseLiveStore"))
        XCTAssertFalse(publisher.contains("liveStrapMotionCapturedAt"))
        XCTAssertTrue(source.contains("scheduleLiveSensorWidgetPatch(reason: \"live_steps\")"))
    }

    func testLongWearAnalysisDoesNotForceJournalWrites() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaBLEManager.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        let diagnosticStart = try XCTUnwrap(source.range(of:
            "private func runLongWearSupervisorDiagnostic"))
        let autoSaveStart = try XCTUnwrap(source.range(of:
            "private func runLongWearSupervisorAutoSave",
            range: diagnosticStart.upperBound..<source.endIndex))
        let watchdogStart = try XCTUnwrap(source.range(of:
            "private func scheduleNoDataWatchdogIfNeeded",
            range: autoSaveStart.upperBound..<source.endIndex))
        let diagnostic = source[diagnosticStart.lowerBound..<autoSaveStart.lowerBound]
        let autoSave = source[autoSaveStart.lowerBound..<watchdogStart.lowerBound]

        XCTAssertFalse(diagnostic.contains("persistActiveSessionJournalIfNeeded"))
        XCTAssertTrue(autoSave.contains("onSessionCheckpoint?(saved)"))
        XCTAssertTrue(autoSave.contains("persistActiveSessionJournalIfNeeded"))
        XCTAssertFalse(autoSave.contains("persistFinishedSession(saved"))
    }

    func testUnvalidatedStrapMotionPeaksNeverBecomeUserFacingSteps() {
        let samples = [
            AtriaIMUDecoder.Sample(xG: 0, yG: 0, zG: 1.00),
            AtriaIMUDecoder.Sample(xG: 0, yG: 0, zG: 1.30),
            AtriaIMUDecoder.Sample(xG: 0, yG: 0, zG: 1.00),
            AtriaIMUDecoder.Sample(xG: 0, yG: 0, zG: 1.35),
            AtriaIMUDecoder.Sample(xG: 0, yG: 0, zG: 1.00),
        ]

        let result = AtriaStrapStepResearch.estimate(samples: samples, sampleRateHz: 4)

        XCTAssertGreaterThan(result.peaks, 0)
        XCTAssertEqual(result.steps, 0)
        XCTAssertEqual(result.state, "research_unvalidated")
        XCTAssertFalse(AtriaStrapStepResearch.validatedDecoderAvailable)
    }

    func testLiveSessionSampleCountPublishCadenceKeepsDetectionExactButUIBounded() {
        let now = t0

        XCTAssertFalse(AtriaBLEManager.shouldPublishLiveSessionSampleCount(currentCount: 42,
                                                                           publishedCount: 42,
                                                                           lastPublishedAt: now,
                                                                           now: now))
        XCTAssertTrue(AtriaBLEManager.shouldPublishLiveSessionSampleCount(currentCount: 1,
                                                                          publishedCount: 0,
                                                                          lastPublishedAt: nil,
                                                                          now: now))
        XCTAssertFalse(AtriaBLEManager.shouldPublishLiveSessionSampleCount(currentCount: 5,
                                                                           publishedCount: 1,
                                                                           lastPublishedAt: now,
                                                                           now: now.addingTimeInterval(1)))
        XCTAssertTrue(AtriaBLEManager.shouldPublishLiveSessionSampleCount(currentCount: 11,
                                                                          publishedCount: 1,
                                                                          lastPublishedAt: now,
                                                                          now: now.addingTimeInterval(1)))
        XCTAssertTrue(AtriaBLEManager.shouldPublishLiveSessionSampleCount(currentCount: 60,
                                                                          publishedCount: 59,
                                                                          lastPublishedAt: now,
                                                                          now: now.addingTimeInterval(1)))
        XCTAssertTrue(AtriaBLEManager.shouldPublishLiveSessionSampleCount(currentCount: 720,
                                                                          publishedCount: 719,
                                                                          lastPublishedAt: now,
                                                                          now: now.addingTimeInterval(1)))
        XCTAssertTrue(AtriaBLEManager.shouldPublishLiveSessionSampleCount(currentCount: 900,
                                                                          publishedCount: 899,
                                                                          lastPublishedAt: now,
                                                                          now: now.addingTimeInterval(1)))
        XCTAssertTrue(AtriaBLEManager.shouldPublishLiveSessionSampleCount(currentCount: 6,
                                                                          publishedCount: 1,
                                                                          lastPublishedAt: now,
                                                                          now: now.addingTimeInterval(5.1)))
        XCTAssertTrue(AtriaBLEManager.shouldPublishLiveSessionSampleCount(currentCount: 0,
                                                                          publishedCount: 120,
                                                                          lastPublishedAt: now,
                                                                          now: now,
                                                                          force: true))
    }

    func testHomeSavedAggregateCacheKeyRollsAtLocalMidnight() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let yesterday = DateComponents(calendar: calendar,
                                       timeZone: calendar.timeZone,
                                       year: 2026,
                                       month: 7,
                                       day: 8,
                                       hour: 23,
                                       minute: 20).date!
        let beforeMidnightNow = DateComponents(calendar: calendar,
                                               timeZone: calendar.timeZone,
                                               year: 2026,
                                               month: 7,
                                               day: 8,
                                               hour: 23,
                                               minute: 59).date!
        let today = DateComponents(calendar: calendar,
                                   timeZone: calendar.timeZone,
                                   year: 2026,
                                   month: 7,
                                   day: 9,
                                   hour: 0,
                                   minute: 5).date!
        let yesterdaySession = savedAggregateSession(start: yesterday,
                                                     stepCount: 42)

        let beforeMidnight = SessionStore.homeSavedAggregate(from: [yesterdaySession],
                                                             rest: 60,
                                                             maxHR: 190,
                                                             biologicalSex: .unspecified,
                                                             calendar: calendar,
                                                             now: beforeMidnightNow,
                                                             rawSessionCount: 1)
        XCTAssertTrue(beforeMidnight.hasSavedToday)
        XCTAssertGreaterThan(beforeMidnight.savedTodayTRIMP, 0)
        XCTAssertEqual(beforeMidnight.savedTodayStrapSteps, 42)

        let afterMidnight = SessionStore.homeSavedAggregate(from: [yesterdaySession],
                                                            rest: 60,
                                                            maxHR: 190,
                                                            biologicalSex: .unspecified,
                                                            calendar: calendar,
                                                            now: today,
                                                            rawSessionCount: 1)
        XCTAssertFalse(afterMidnight.hasSavedToday)
        XCTAssertEqual(afterMidnight.savedTodayTRIMP, 0)
        XCTAssertEqual(afterMidnight.savedTodayStrapSteps, 0)

        let todaySession = savedAggregateSession(start: today,
                                                 stepCount: 11)
        let afterTodaySession = todaySession.end.addingTimeInterval(1)
        let refreshedToday = SessionStore.homeSavedAggregate(from: [todaySession, yesterdaySession],
                                                             rest: 60,
                                                             maxHR: 190,
                                                             biologicalSex: .unspecified,
                                                             calendar: calendar,
                                                             now: afterTodaySession,
                                                             rawSessionCount: 2)
        XCTAssertTrue(refreshedToday.hasSavedToday)
        XCTAssertGreaterThan(refreshedToday.savedTodayTRIMP, 0)
        XCTAssertEqual(refreshedToday.savedTodayStrapSteps, 11)
    }

    func testLiveStepMergeSubtractsCheckpointedActivePrefix() {
        XCTAssertEqual(AtriaHomeModel.mergedStrapStepResearchCount(savedToday: 1_000,
                                                                   savedActiveSession: 400,
                                                                   liveActiveSession: 550),
                       1_150)
        XCTAssertEqual(AtriaHomeModel.mergedStrapStepResearchCount(savedToday: 1_000,
                                                                   savedActiveSession: 400,
                                                                   liveActiveSession: 300),
                       1_000)
        XCTAssertEqual(AtriaHomeModel.mergedStrapStepResearchCount(savedToday: 1_000,
                                                                   savedActiveSession: 0,
                                                                   liveActiveSession: 300),
                       1_300)
    }

    func testSavedAggregateIdentifiesActiveCheckpointSteps() {
        let active = savedAggregateSession(start: t0, stepCount: 42)
        let completed = savedAggregateSession(start: t0.addingTimeInterval(60), stepCount: 100)
        let aggregate = SessionStore.homeSavedAggregate(from: [active, completed],
                                                        rest: 60,
                                                        maxHR: 190,
                                                        biologicalSex: .unspecified,
                                                        activeSessionID: active.id,
                                                        now: completed.end.addingTimeInterval(1))

        XCTAssertEqual(aggregate.savedTodayStrapSteps, 142)
        XCTAssertEqual(aggregate.savedActiveSessionStrapSteps, 42)
        XCTAssertEqual(aggregate.savedActiveSessionTRIMP,
                       active.trimp(rest: 60, max: 190),
                       accuracy: 0.000_001)
    }

    func testWorkoutStepPrefixUsesOnlyCanonicalStrapStepAnchors() {
        let active = savedAggregateSession(start: t0, stepCount: 42)
        let completed = savedAggregateSession(start: t0.addingTimeInterval(60), stepCount: 100)
        let prefix = SessionStore.workoutSavedStepPrefix(
            from: [active, completed],
            activeSessionID: active.id,
            now: completed.end.addingTimeInterval(1)
        )

        XCTAssertEqual(prefix.savedTodayStrapSteps, 142)
        XCTAssertEqual(prefix.savedActiveSessionStrapSteps, 42)
        XCTAssertEqual(prefix.savedActiveSessionTotalStrapSteps, 42)
    }

    func testLiveTRIMPMergeReplacesCheckpointedActivePrefix() {
        XCTAssertEqual(SessionStore.mergedTodayTRIMP(savedToday: 32,
                                                      savedActiveSession: 12,
                                                      liveActiveSession: 18),
                       38,
                       accuracy: 0.000_001)
        XCTAssertEqual(SessionStore.mergedTodayTRIMP(savedToday: 32,
                                                      savedActiveSession: 12,
                                                      liveActiveSession: 8),
                       32,
                       accuracy: 0.000_001,
                       "A restored live accumulator must not temporarily drop below its durable checkpoint")
        XCTAssertEqual(SessionStore.mergedTodayTRIMP(savedToday: 20,
                                                      savedActiveSession: 0,
                                                      liveActiveSession: 18),
                       38,
                       accuracy: 0.000_001)
    }

    func testPulseZoneContextMatchesRestFallbackOrderWithoutSessionDerivation() {
        XCTAssertEqual(AtriaHomeModel.pulseZoneContext(baselineResting: 55,
                                                       liveResting: 61,
                                                       latestSavedResting: 63,
                                                       maxHR: 188),
                       AtriaHomeModel.PulseZoneContext(rest: 55, maxHR: 188))
        XCTAssertEqual(AtriaHomeModel.pulseZoneContext(baselineResting: nil,
                                                       liveResting: 61,
                                                       latestSavedResting: 63,
                                                       maxHR: 188),
                       AtriaHomeModel.PulseZoneContext(rest: 61, maxHR: 188))
        XCTAssertEqual(AtriaHomeModel.pulseZoneContext(baselineResting: nil,
                                                       liveResting: nil,
                                                       latestSavedResting: 63,
                                                       maxHR: 188),
                       AtriaHomeModel.PulseZoneContext(rest: 63, maxHR: 188))
        XCTAssertEqual(AtriaHomeModel.pulseZoneContext(baselineResting: nil,
                                                       liveResting: nil,
                                                       latestSavedResting: nil,
                                                       maxHR: 188),
                       AtriaHomeModel.PulseZoneContext(rest: 60, maxHR: 188))
    }

    func testRestingHeartRateFallbackIsEvaluatedOnlyWhenNeeded() {
        var fallbackEvaluations = 0
        let savedFallback = {
            fallbackEvaluations += 1
            return 63
        }

        XCTAssertEqual(AtriaHomeModel.resolvedRestingHeartRate(baselineResting: 55,
                                                               liveResting: 61,
                                                               latestSavedResting: savedFallback),
                       55)
        XCTAssertEqual(fallbackEvaluations, 0)

        XCTAssertEqual(AtriaHomeModel.resolvedRestingHeartRate(baselineResting: nil,
                                                               liveResting: 61,
                                                               latestSavedResting: savedFallback),
                       61)
        XCTAssertEqual(fallbackEvaluations, 0)

        XCTAssertEqual(AtriaHomeModel.resolvedRestingHeartRate(baselineResting: nil,
                                                               liveResting: nil,
                                                               latestSavedResting: savedFallback),
                       63)
        XCTAssertEqual(fallbackEvaluations, 1)
    }

    func testRestingMetricContextPreservesMathDisplayAndRecoverySemantics() {
        let baselineWins = AtriaHomeModel.restingMetricContext(baselineResting: 55,
                                                               liveResting: 61,
                                                               latestSavedResting: 63)
        XCTAssertEqual(baselineWins.resolved, 55)
        XCTAssertEqual(baselineWins.displayText, "55")
        XCTAssertEqual(baselineWins.currentForRecovery, 61)
        XCTAssertTrue(baselineWins.hasEvidence)

        let savedFallback = AtriaHomeModel.restingMetricContext(baselineResting: nil,
                                                                liveResting: nil,
                                                                latestSavedResting: 63)
        XCTAssertEqual(savedFallback.resolved, 63)
        XCTAssertEqual(savedFallback.currentForRecovery, 63)
        XCTAssertEqual(savedFallback.displayText, "63")

        let baselineOnly = AtriaHomeModel.restingMetricContext(baselineResting: 55,
                                                               liveResting: nil,
                                                               latestSavedResting: nil)
        XCTAssertNil(baselineOnly.currentForRecovery)
        XCTAssertTrue(baselineOnly.hasEvidence)

        let learning = AtriaHomeModel.restingMetricContext(baselineResting: nil,
                                                           liveResting: nil,
                                                           latestSavedResting: nil)
        XCTAssertEqual(learning.resolved, 60)
        XCTAssertEqual(learning.displayText, "Learning")
        XCTAssertNil(learning.currentForRecovery)
        XCTAssertFalse(learning.hasEvidence)
    }

    func testPresentationRestingHeartRateUsesSleepCycleAuthoritiesOnly() {
        // 2026-08-04 provenance decision: "Resting" only ever shows a
        // sleep-derived value (main sleep, daily metric, rollup). The old
        // daytime fallbacks (live low-HR window, saved-wear restingStable)
        // surfaced awake-day estimates as "Resting" with no source label.
        XCTAssertEqual(SessionStore.presentationRestingHeartRate(
            sleepRestingHeartRate: 52,
            metricRestingHeartRate: 73,
            rollupRestingHeartRate: 72
        ), 52)
        XCTAssertEqual(SessionStore.presentationRestingHeartRate(
            sleepRestingHeartRate: nil,
            metricRestingHeartRate: 73,
            rollupRestingHeartRate: 72
        ), 73)
        XCTAssertEqual(SessionStore.presentationRestingHeartRate(
            sleepRestingHeartRate: nil,
            metricRestingHeartRate: nil,
            rollupRestingHeartRate: 72
        ), 72)
        XCTAssertNil(SessionStore.presentationRestingHeartRate(
            sleepRestingHeartRate: nil,
            metricRestingHeartRate: nil,
            rollupRestingHeartRate: nil
        ), "no sleep evidence must render the honest no-value token, never a daytime estimate")
        XCTAssertNil(SessionStore.presentationRestingHeartRate(
            sleepRestingHeartRate: 0,
            metricRestingHeartRate: 0,
            rollupRestingHeartRate: nil
        ), "zero readings are not evidence")
    }

    func testHealthMonitorUsesTheCurrentPhysiologicalCycleRecoveryEstimate() throws {
        // 2026-08-26: this assertion's subject lived in the orphaned Vitals
        // tab tree (AtriaVitalsTabContent, zero construction sites), removed
        // in that change. AtriaHomeView mounts AtriaHealthScreen for the
        // Vitals tab and always has, so this was guarding UI nobody could
        // open. Recorded rather than silently deleted: it means this behaviour
        // was BUILT AND TESTED but never reached the live screen.
        //
        // `healthMonitorRecoveryEstimate` belonged to AtriaHealthMonitorCard.
        // The invariant it guarded — read the hero's cycle-scoped estimate, do
        // not rebuild one from dailyRollupHistory, do not stamp it .validated —
        // is a good one, and the live screen must not reintroduce the shape it
        // forbade.
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let health = try String(
            contentsOf: testsDirectory.deletingLastPathComponent()
                .appendingPathComponent("Atria/AtriaHealthScreen.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(health.contains("heroStore.state.recoveryEstimate"),
                      "the live screen must read the hero's cycle estimate")

        let vitals = try String(
            contentsOf: testsDirectory.deletingLastPathComponent()
                .appendingPathComponent("Atria/AtriaVitalsCollectionSections.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(vitals.contains("healthMonitorRecoveryEstimate"),
                       "the dead card must stay removed")
    }

    func testCheckpointDiagnosticsDoNotEvaluateWhenLoggingIsDisabled() {
        var evaluations = 0
        let makeDiagnostic = {
            evaluations += 1
            return 42
        }

        let disabled: Int? = SessionStore.checkpointDiagnosticValue(loggingEnabled: false,
                                                                    makeValue: makeDiagnostic)
        XCTAssertNil(disabled)
        XCTAssertEqual(evaluations, 0)

        let enabled: Int? = SessionStore.checkpointDiagnosticValue(loggingEnabled: true,
                                                                   makeValue: makeDiagnostic)
        XCTAssertEqual(enabled, 42)
        XCTAssertEqual(evaluations, 1)
    }

    func testReconnectWatchdogsPreferFreshConnectionOverOldPacketTimestamps() {
        let oldPacket = Date(timeIntervalSince1970: 1_000)
        let reconnect = Date(timeIntervalSince1970: 1_300)

        XCTAssertEqual(AtriaBLEManager.latestLinkActivity([oldPacket, nil, reconnect]), reconnect)
        XCTAssertEqual(AtriaBLEManager.latestLinkActivity([nil, oldPacket, nil]), oldPacket)
        XCTAssertNil(AtriaBLEManager.latestLinkActivity([nil, nil]))
    }

    func testResidentMorningSettlementUsesWakeWindowAndThirtyMinuteCadence() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = Date(timeIntervalSince1970: 1_800_057_600)
        let at: (Int, Int) -> Date = { hour, minute in
            calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
        }

        XCTAssertFalse(SessionStore.shouldAttemptResidentMorningSettlement(now: at(6, 29),
                                                                             learnedWindowEndMinute: 6 * 60 + 30,
                                                                             lastAttemptAt: nil,
                                                                             calendar: calendar))
        XCTAssertTrue(SessionStore.shouldAttemptResidentMorningSettlement(now: at(6, 30),
                                                                            learnedWindowEndMinute: 6 * 60 + 30,
                                                                            lastAttemptAt: nil,
                                                                            calendar: calendar))
        XCTAssertFalse(SessionStore.shouldAttemptResidentMorningSettlement(now: at(6, 50),
                                                                             learnedWindowEndMinute: 6 * 60 + 30,
                                                                             lastAttemptAt: at(6, 30),
                                                                             calendar: calendar))
        XCTAssertTrue(SessionStore.shouldAttemptResidentMorningSettlement(now: at(7, 0),
                                                                            learnedWindowEndMinute: 6 * 60 + 30,
                                                                            lastAttemptAt: at(6, 30),
                                                                            calendar: calendar))
        XCTAssertFalse(SessionStore.shouldAttemptResidentMorningSettlement(now: at(12, 0),
                                                                             learnedWindowEndMinute: 6 * 60 + 30,
                                                                             lastAttemptAt: nil,
                                                                             calendar: calendar))
        XCTAssertFalse(SessionStore.shouldAttemptResidentMorningSettlement(now: at(8, 59),
                                                                             learnedWindowEndMinute: nil,
                                                                             lastAttemptAt: nil,
                                                                             calendar: calendar))
        XCTAssertTrue(SessionStore.shouldAttemptResidentMorningSettlement(now: at(9, 0),
                                                                            learnedWindowEndMinute: nil,
                                                                            lastAttemptAt: nil,
                                                                            calendar: calendar))
        XCTAssertTrue(SessionStore.shouldAttemptResidentMorningSettlement(now: at(11, 0),
                                                                            learnedWindowEndMinute: nil,
                                                                            lastAttemptAt: nil,
                                                                            calendar: calendar))
        XCTAssertFalse(SessionStore.shouldAttemptResidentMorningSettlement(now: at(11, 1),
                                                                             learnedWindowEndMinute: nil,
                                                                             lastAttemptAt: nil,
                                                                             calendar: calendar))
    }

    // Resident checkpoints retain one review intent at any hour. Central
    // admission runs it only while attended; a background checkpoint defers
    // that same latest-key request until scene-active.
    func testResidentSleepReviewRefreshFiresAtAnyHourOnFifteenMinuteCadence() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        // First attempt (no prior) is always allowed.
        XCTAssertTrue(SessionStore.shouldAttemptResidentSleepReviewRefresh(
            now: base, lastAttemptAt: nil))
        // Within the 15-minute throttle: suppressed.
        XCTAssertFalse(SessionStore.shouldAttemptResidentSleepReviewRefresh(
            now: base.addingTimeInterval(14 * 60), lastAttemptAt: base))
        // At/after the throttle: allowed again.
        XCTAssertTrue(SessionStore.shouldAttemptResidentSleepReviewRefresh(
            now: base.addingTimeInterval(15 * 60), lastAttemptAt: base))
        // Unlike morning settlement, the intent is not hour-gated; an
        // afternoon nap can request the next foreground review pass.
        let afternoon = base.addingTimeInterval(16 * 60 * 60 + 45 * 60)
        XCTAssertTrue(SessionStore.shouldAttemptResidentSleepReviewRefresh(
            now: afternoon, lastAttemptAt: nil))
        XCTAssertTrue(SessionStore.shouldAttemptResidentSleepReviewRefresh(
            now: afternoon.addingTimeInterval(20 * 60),
            lastAttemptAt: afternoon))
    }

    func testFailedConnectRecoveryRetainsSavedStrapAndBackoff() {
        XCTAssertEqual(AtriaBLEManager.failedConnectRecoveryDisposition(isSavedPeripheral: true,
                                                                         isActuallyConnecting: false),
                       .reconnectKnownAfterBackoff)
        XCTAssertEqual(AtriaBLEManager.failedConnectRecoveryDisposition(isSavedPeripheral: true,
                                                                         isActuallyConnecting: true),
                       .waitForExistingConnect)
        XCTAssertEqual(AtriaBLEManager.failedConnectRecoveryDisposition(isSavedPeripheral: false,
                                                                         isActuallyConnecting: false),
                       .scan)
    }

    func testAutomaticRecoveryIntentOnlyEscalatesWhileRequestsCoalesce() {
        XCTAssertEqual(AtriaBLEManager.mergedRecoveryIntent(.repairPipeline, .repairPipeline),
                       .repairPipeline)
        XCTAssertEqual(AtriaBLEManager.mergedRecoveryIntent(.repairPipeline, .rebuildConnection),
                       .rebuildConnection)
        XCTAssertEqual(AtriaBLEManager.mergedRecoveryIntent(.rebuildConnection, .repairPipeline),
                       .rebuildConnection)
    }

    func testRRJournalCadenceStaysCrashSafeWhileRespectingThermalPressure() {
        XCTAssertEqual(AtriaBLEManager.rrJournalMinimumInterval(cadenceMultiplier: 1), 60)
        XCTAssertEqual(AtriaBLEManager.rrJournalMinimumInterval(cadenceMultiplier: 1.5), 75)
        XCTAssertEqual(AtriaBLEManager.rrJournalMinimumInterval(cadenceMultiplier: 2.5), 75)
        XCTAssertEqual(AtriaBLEManager.rrJournalMinimumInterval(cadenceMultiplier: 4), 75)
    }

    func testStaleArchiveReconciliationCoalescesAndBacksOff() {
        let now = Date(timeIntervalSince1970: 2_000)
        XCTAssertFalse(AtriaBLEManager.shouldScheduleStaleRangeLossReconciliation(
            inFlight: true,
            lastAttemptAt: nil,
            now: now,
            minimumInterval: 120
        ))
        XCTAssertTrue(AtriaBLEManager.shouldScheduleStaleRangeLossReconciliation(
            inFlight: false,
            lastAttemptAt: nil,
            now: now,
            minimumInterval: 120
        ))
        XCTAssertFalse(AtriaBLEManager.shouldScheduleStaleRangeLossReconciliation(
            inFlight: false,
            lastAttemptAt: now.addingTimeInterval(-119),
            now: now,
            minimumInterval: 120
        ))
        XCTAssertTrue(AtriaBLEManager.shouldScheduleStaleRangeLossReconciliation(
            inFlight: false,
            lastAttemptAt: now.addingTimeInterval(-120),
            now: now,
            minimumInterval: 120
        ))
    }

    func testCanonicalCheckpointClockIsSharedAcrossProducers() {
        let now = Date(timeIntervalSince1970: 3_000)
        XCTAssertTrue(AtriaBLEManager.shouldRunCanonicalCheckpoint(now: now,
                                                                   lastCheckpointAt: nil,
                                                                   minimumInterval: 60))
        XCTAssertFalse(AtriaBLEManager.shouldRunCanonicalCheckpoint(now: now,
                                                                    lastCheckpointAt: now.addingTimeInterval(-59),
                                                                    minimumInterval: 60))
        XCTAssertTrue(AtriaBLEManager.shouldRunCanonicalCheckpoint(now: now,
                                                                   lastCheckpointAt: now.addingTimeInterval(-60),
                                                                   minimumInterval: 60))
    }

    func testRestingTrendKeepsLatestFourteenDaysAndSameDayMinimum() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.startOfDay(for: t0).addingTimeInterval(12 * 60 * 60)
        var sessions = (0..<15).map { daysAgo in
            restingTrendSession(start: now.addingTimeInterval(TimeInterval(-daysAgo) * 24 * 60 * 60),
                                resting: 60 + daysAgo)
        }
        sessions.append(restingTrendSession(start: now.addingTimeInterval(-3 * 24 * 60 * 60 + 60),
                                            resting: 41))

        let trend = SessionStore.restingTrend14(from: sessions, now: now, calendar: calendar)

        XCTAssertEqual(trend.count, 14)
        XCTAssertEqual(trend.first, 73)
        XCTAssertEqual(trend[10], 41)
        XCTAssertEqual(trend.last, 60)
    }

    func testRestingTrendHandlesEditsBackfillsAndCutoffExactly() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.startOfDay(for: t0).addingTimeInterval(12 * 60 * 60)
        let recent = restingTrendSession(start: now.addingTimeInterval(-24 * 60 * 60), resting: 62)
        let backfill = restingTrendSession(start: now.addingTimeInterval(-10 * 24 * 60 * 60), resting: 55)
        let exactlyAtCutoff = restingTrendSession(start: now.addingTimeInterval(-45 * 24 * 60 * 60),
                                                  resting: 70)
        let tooOld = restingTrendSession(start: now.addingTimeInterval(-45 * 24 * 60 * 60 - 1),
                                         resting: 40)
        let editedRecent = restingTrendSession(id: recent.id,
                                               start: recent.start,
                                               resting: 48)

        XCTAssertEqual(SessionStore.restingTrend14(from: [recent, backfill, exactlyAtCutoff, tooOld],
                                                    now: now,
                                                    calendar: calendar),
                       [70, 55, 62])
        XCTAssertEqual(SessionStore.restingTrend14(from: [editedRecent, backfill, exactlyAtCutoff, tooOld],
                                                    now: now,
                                                    calendar: calendar),
                       [70, 55, 48])
    }

    private func restingTrendSession(id: UUID = UUID(),
                                     start: Date,
                                     resting: Int) -> SavedSession {
        SavedSession(id: id,
                     start: start,
                     end: start.addingTimeInterval(8 * 60),
                     label: "Resting trend",
                     points: (0..<8).map { index in
                         SavedSession.Point(t: TimeInterval(index * 60), bpm: resting)
                     })
    }

    func testThermalJournalHeartbeatLeavesRecoveryWriteMargin() {
        XCTAssertEqual(AtriaBLEManager.thermalJournalCheckpointInterval, 60)
        XCTAssertLessThan(AtriaBLEManager.thermalJournalCheckpointInterval + 15, 90)

        let old = Date(timeIntervalSince1970: 1_000)
        let heartbeat = Date(timeIntervalSince1970: 1_060)
        XCTAssertEqual(ActiveSessionJournal.latestUpdatedAt(old, heartbeat), heartbeat)
        XCTAssertEqual(ActiveSessionJournal.latestUpdatedAt(heartbeat, old), heartbeat)
    }

    private func savedAggregateSession(start: Date, stepCount: Int) -> SavedSession {
        // Keep adjacent HR evidence inside the production 15-second continuity
        // limit; minute-spaced fixtures correctly produce zero load.
        let points = (0...120).map { sample in
            SavedSession.Point(t: TimeInterval(sample * 10), bpm: 150 + (sample % 3))
        }
        return SavedSession(id: UUID(),
                            start: start,
                            end: start.addingTimeInterval(20 * 60),
                            label: "Saved aggregate",
                            points: points,
                            strapStepResearchCount: stepCount,
                            strapStepResearchState: "research_unvalidated")
    }

    func testStressInputEvaluationSkipsUnchangedTicksUntilHistoryCadence() {
        let now = t0

        XCTAssertTrue(AtriaStressMonitorStore.shouldEvaluateStressInput(force: true,
                                                                        inputChanged: false,
                                                                        isNoSignal: false,
                                                                        lastEvaluatedAt: now,
                                                                        now: now))
        XCTAssertTrue(AtriaStressMonitorStore.shouldEvaluateStressInput(force: false,
                                                                        inputChanged: true,
                                                                        isNoSignal: false,
                                                                        lastEvaluatedAt: now,
                                                                        now: now.addingTimeInterval(5)))
        XCTAssertFalse(AtriaStressMonitorStore.shouldEvaluateStressInput(force: false,
                                                                         inputChanged: false,
                                                                         isNoSignal: false,
                                                                         lastEvaluatedAt: now,
                                                                         now: now.addingTimeInterval(5)))
        XCTAssertTrue(AtriaStressMonitorStore.shouldEvaluateStressInput(force: false,
                                                                        inputChanged: false,
                                                                        isNoSignal: false,
                                                                        lastEvaluatedAt: now,
                                                                        now: now.addingTimeInterval(30)))
        XCTAssertFalse(AtriaStressMonitorStore.shouldEvaluateStressInput(force: false,
                                                                         inputChanged: false,
                                                                         isNoSignal: true,
                                                                         lastEvaluatedAt: now,
                                                                         now: now.addingTimeInterval(60)))
        XCTAssertTrue(AtriaStressMonitorStore.shouldEvaluateStressInput(force: false,
                                                                        inputChanged: false,
                                                                        isNoSignal: false,
                                                                        lastEvaluatedAt: nil,
                                                                        now: now))
    }

    // MARK: - Fix #1b — skin-temp displays finalized sleep evidence

    func testSkinTemperatureCandidatesRemainResearchOnlyWithoutValidatedDecoder() {
        let sessions = [
            rawSkinTemperatureCandidateSession(daysAgo: 4, rawCandidate: 3_600),
            rawSkinTemperatureCandidateSession(daysAgo: 3, rawCandidate: 3_610),
            rawSkinTemperatureCandidateSession(daysAgo: 2, rawCandidate: 3_620),
            rawSkinTemperatureCandidateSession(daysAgo: 1, rawCandidate: 3_700)
        ]
        let summary = IMUAuditSummary(sessions: sessions).skinTemperatureDeviation

        XCTAssertNil(summary.latestDeltaCelsius)
        XCTAssertFalse(summary.isReady)
        XCTAssertEqual(summary.candidateFrames, 40)
        XCTAssertTrue(SessionStore.finalizedSkinTemperatureDeviationByMorningDay(sessions: sessions).isEmpty)
        XCTAssertNil(SessionStore.morningSkinTemperatureDeviation(for: sessions.last!.end,
                                                                  computedToday: nil,
                                                                  sessions: sessions))
    }

    func testSkinTemperatureDeviationIgnoresFreshActiveSession() {
        let activeID = UUID()
        let sessions = [
            decodedSkinTemperatureSession(daysAgo: 4, celsius: 36.0),
            decodedSkinTemperatureSession(daysAgo: 3, celsius: 36.1),
            decodedSkinTemperatureSession(daysAgo: 2, celsius: 36.2),
            decodedSkinTemperatureSession(daysAgo: 1, celsius: 37.0),
            decodedSkinTemperatureSession(id: activeID, daysAgo: 0, celsius: 42.0)
        ]

        let frozen = IMUAuditSummary(sessions: sessions,
                                     activeSessionID: activeID).skinTemperatureDeviation
        XCTAssertTrue(frozen.isReady)
        XCTAssertEqual(frozen.latestDeltaCelsius ?? 0, 0.9, accuracy: 1e-9)
        XCTAssertEqual(frozen.baselineSessions, 3)
        XCTAssertEqual(frozen.candidateFrames, 50)
        XCTAssertEqual(frozen.candidateValues, 5)

        let mutable = IMUAuditSummary(sessions: sessions).skinTemperatureDeviation
        XCTAssertEqual(mutable.latestDeltaCelsius ?? 0, 5.675, accuracy: 1e-9)
    }

    func testFinalizedSkinTemperatureDeviationBucketsByMorningDay() {
        let activeID = UUID()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let sessions = [
            decodedSkinTemperatureSession(daysAgo: 4, celsius: 36.0),
            decodedSkinTemperatureSession(daysAgo: 3, celsius: 36.1),
            decodedSkinTemperatureSession(daysAgo: 2, celsius: 36.2),
            decodedSkinTemperatureSession(daysAgo: 1, celsius: 37.0),
            decodedSkinTemperatureSession(id: activeID, daysAgo: 0, celsius: 42.0)
        ]

        let deviations = SessionStore.finalizedSkinTemperatureDeviationByMorningDay(sessions: sessions,
                                                                                    activeSessionID: activeID,
                                                                                    calendar: calendar)
        let finalizedDay = calendar.startOfDay(for: sessions[3].end)
        let activeDay = calendar.startOfDay(for: sessions[4].end)

        XCTAssertEqual(deviations[finalizedDay] ?? 0, 0.9, accuracy: 1e-9)
        XCTAssertNil(deviations[activeDay], "fresh active sleep-temp evidence must not finalize into daily history")
    }

    func testFinalizedSkinTemperatureDeviationUsesExpandingHistoricalBaseline() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let sessions = [
            decodedSkinTemperatureSession(daysAgo: 5, celsius: 36.0),
            decodedSkinTemperatureSession(daysAgo: 4, celsius: 36.1),
            decodedSkinTemperatureSession(daysAgo: 3, celsius: 36.2),
            decodedSkinTemperatureSession(daysAgo: 2, celsius: 36.3),
            decodedSkinTemperatureSession(daysAgo: 1, celsius: 37.0),
            decodedSkinTemperatureSession(daysAgo: 0, celsius: 35.9)
        ]

        let deviations = SessionStore.finalizedSkinTemperatureDeviationByMorningDay(sessions: sessions,
                                                                                    calendar: calendar)
        let firstDeviationDay = calendar.startOfDay(for: sessions[3].end)
        let secondDeviationDay = calendar.startOfDay(for: sessions[4].end)
        let thirdDeviationDay = calendar.startOfDay(for: sessions[5].end)

        XCTAssertEqual(deviations[firstDeviationDay] ?? 0, 0.2, accuracy: 1e-9)
        XCTAssertEqual(deviations[secondDeviationDay] ?? 0, 0.85, accuracy: 1e-9)
        XCTAssertEqual(deviations[thirdDeviationDay] ?? 0, -0.42, accuracy: 1e-9)
    }

    func testSkinTemperatureDeviationSummaryCacheTracksSourceRevisionsAndFallback() {
        let fallback = IMUAuditSummary.SkinTemperatureDeviationSummary(latestDeltaCelsius: nil,
                                                                       baselineSessions: 2,
                                                                       candidateFrames: 40,
                                                                       candidateValues: 4)
        let summary = SessionStore.skinTemperatureDeviationSummary(finalizedDeviationCelsius: 0.42,
                                                                   fallback: fallback,
                                                                   validatedSource: true)
        let record = SessionStore.SkinTemperatureDeviationSummaryCache(dailyMetricRevision: 7,
                                                                       dailyRollupRevision: 11,
                                                                       fallback: fallback,
                                                                       summary: summary)

        XCTAssertTrue(SessionStore.isSkinTemperatureDeviationSummaryCacheFresh(record,
                                                                               dailyMetricRevision: 7,
                                                                               dailyRollupRevision: 11,
                                                                               fallback: fallback))
        XCTAssertFalse(SessionStore.isSkinTemperatureDeviationSummaryCacheFresh(record,
                                                                                dailyMetricRevision: 8,
                                                                                dailyRollupRevision: 11,
                                                                                fallback: fallback))
        XCTAssertFalse(SessionStore.isSkinTemperatureDeviationSummaryCacheFresh(record,
                                                                                dailyMetricRevision: 7,
                                                                                dailyRollupRevision: 12,
                                                                                fallback: fallback))

        let changedFallback = IMUAuditSummary.SkinTemperatureDeviationSummary(latestDeltaCelsius: nil,
                                                                              baselineSessions: 2,
                                                                              candidateFrames: 41,
                                                                              candidateValues: 4)
        XCTAssertFalse(SessionStore.isSkinTemperatureDeviationSummaryCacheFresh(record,
                                                                                dailyMetricRevision: 7,
                                                                                dailyRollupRevision: 11,
                                                                                fallback: changedFallback))
    }

    func testMorningFrozenMetricRejectsUnvalidatedSkinTemperatureMap() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = t0.addingTimeInterval(10 * 3_600)
        let day = calendar.startOfDay(for: now)
        let preparedDeviation = 0.42
        let sleep = SleepHistorySnapshot(rollups: [], confirmedSleeps: [])

        let settled = SessionStore.makeMorningFrozenDailyMetric(for: day,
                                                                computed: [],
                                                                sessions: [],
                                                                sleep: sleep,
                                                                baseline: PersonalBaseline(),
                                                                maxHR: 190,
                                                                now: now,
                                                                skinTemperatureDeviationByDay: [day: preparedDeviation],
                                                                skinTemperatureSourceValidated: false,
                                                                calendar: calendar)

        XCTAssertNil(settled)

        let merged = SessionStore.mergeDailyMetricHistory(existing: [],
                                                          computed: [],
                                                          sessions: [],
                                                          sleep: sleep,
                                                          baseline: PersonalBaseline(),
                                                          maxHR: 190,
                                                          now: now,
                                                          skinTemperatureDeviationByDay: [day: preparedDeviation],
                                                          skinTemperatureSourceValidated: false,
                                                          calendar: calendar)

        XCTAssertTrue(merged.isEmpty)
    }

    func testCheckpointReconcilePolicySkipsDiskScanAfterDeferredLoad() {
        XCTAssertFalse(SessionStore.shouldReconcileSessionsBeforeLiveUpsert(
            reason: "checkpoint",
            hasCompletedDeferredSessionLoad: true
        ))
        XCTAssertFalse(SessionStore.shouldReconcileSessionsBeforeLiveUpsert(
            reason: "checkpoint",
            hasCompletedDeferredSessionLoad: false
        ))
        XCTAssertFalse(SessionStore.shouldReconcileSessionsBeforeLiveUpsert(
            reason: "add",
            hasCompletedDeferredSessionLoad: true
        ))
        XCTAssertFalse(SessionStore.shouldReconcileSessionsBeforeLiveUpsert(
            reason: "fast_launch",
            hasCompletedDeferredSessionLoad: true
        ))
        XCTAssertTrue(SessionStore.shouldReconcileSessionsBeforeLiveUpsert(
            reason: "explicit_backup_restore",
            hasCompletedDeferredSessionLoad: true
        ))
    }

    func testCanonicalSessionsAfterUpsertPreservesNewestOrderAndPreferredReplacement() {
        let replacedID = UUID()
        let newest = canonicalCacheSession(startOffset: 400, pointCount: 3)
        let existing = canonicalCacheSession(id: replacedID, startOffset: 100, pointCount: 3)
        let cached = [newest, existing]

        let inserted = canonicalCacheSession(startOffset: 250, pointCount: 3)
        let afterInsert = SessionStore.canonicalSessionsAfterUpsert(inserted, into: cached)
        XCTAssertEqual(afterInsert.map(\.id), [newest.id, inserted.id, existing.id])

        let richerReplacement = canonicalCacheSession(id: replacedID, startOffset: 300, pointCount: 6)
        let afterReplacement = SessionStore.canonicalSessionsAfterUpsert(richerReplacement, into: cached)
        XCTAssertEqual(afterReplacement.map(\.id), [newest.id, richerReplacement.id])
        XCTAssertEqual(afterReplacement[1].points.count, 6)

        let staleReplacement = canonicalCacheSession(id: replacedID, startOffset: 300, pointCount: 1)
        let afterStaleReplacement = SessionStore.canonicalSessionsAfterUpsert(staleReplacement, into: cached)
        XCTAssertEqual(afterStaleReplacement.map(\.id), cached.map(\.id))
        XCTAssertEqual(afterStaleReplacement.map { $0.points.count }, cached.map { $0.points.count })
    }

    func testFinalizedCanonicalUpsertForcesSameIDEvidenceReplacement() {
        let id = UUID()
        let existing = canonicalCacheSession(id: id, startOffset: 100, pointCount: 6)
        let edited = canonicalCacheSession(id: id, startOffset: 100, pointCount: 3)

        let checkpointResult = SessionStore.canonicalSessionsAfterUpsert(edited, into: [existing])
        XCTAssertEqual(checkpointResult.first?.points.count, 6)

        let finalizedResult = SessionStore.canonicalSessionsAfterUpsert(
            edited,
            into: [existing],
            replacesSameID: true
        )
        XCTAssertEqual(finalizedResult.first?.points.count, 3)
        XCTAssertEqual(finalizedResult.first?.id, id)
    }

    func testSameIDCheckpointCannotEraseStrongerResearchAggregates() {
        let id = UUID()
        var existing = canonicalCacheSession(id: id, startOffset: 100, pointCount: 3)
        existing.sensorResearchProbeFrames = 40
        existing.spo2ResearchCandidateFrames = 9
        existing.skinTempResearchCandidateFrames = 7
        existing.skinTempResearchCandidateValueSum = 25_249
        existing.skinTempResearchCandidateValueCount = 7
        existing.strapStepResearchCount = 123
        existing.strapStepResearchState = "r10_live_preliminary"

        var restarted = canonicalCacheSession(id: id, startOffset: 100, pointCount: 8)
        restarted.sensorResearchProbeFrames = 3
        restarted.spo2ResearchCandidateFrames = nil
        restarted.skinTempResearchCandidateFrames = 2
        restarted.skinTempResearchCandidateValueSum = 7_200
        restarted.skinTempResearchCandidateValueCount = 2
        restarted.strapStepResearchCount = 4
        restarted.strapStepResearchState = "connection_local"

        let merged = SessionStore.preservingMonotonicResearchAggregates(incoming: restarted,
                                                                         existing: existing)

        XCTAssertEqual(merged.points.count, 8)
        XCTAssertEqual(merged.sensorResearchProbeFrames, 40)
        XCTAssertEqual(merged.spo2ResearchCandidateFrames, 9)
        XCTAssertEqual(merged.skinTempResearchCandidateFrames, 7)
        XCTAssertEqual(merged.skinTempResearchCandidateValueSum, 25_249)
        XCTAssertEqual(merged.skinTempResearchCandidateValueCount, 7)
        XCTAssertEqual(merged.strapStepResearchCount, 123)
        XCTAssertEqual(merged.strapStepResearchState, "r10_live_preliminary")
        XCTAssertFalse(AtriaResearchProbe.validatedSpO2DecoderAvailable)
        XCTAssertFalse(AtriaResearchProbe.validatedSkinTemperatureDecoderAvailable)
    }

    func testAuthoritativeDeletedHistoricalDayDoesNotRestoreStaleMetric() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = t0.addingTimeInterval(5 * 24 * 3_600)
        let deletedDay = calendar.startOfDay(for: t0)
        let stale = SavedDailyMetric(day: deletedDay,
                                     recoveryPercent: 81,
                                     recoveryConfidence: "ready",
                                     hrv: 62,
                                     restingHR: 51,
                                     respiratoryRate: 14.2,
                                     sleepDuration: 7 * 3_600,
                                     sleepSpan: 8 * 3_600,
                                     sleepStart: deletedDay.addingTimeInterval(-7 * 3_600),
                                     sleepEnd: deletedDay,
                                     sleepSource: "strap",
                                     sleepStageSegments: [],
                                     sleepConsistencyPercent: 90,
                                     strain: 4,
                                     skinTemperatureDeviationCelsius: 0.3)

        let merged = SessionStore.mergeDailyMetricHistory(existing: [stale],
                                                          computed: [],
                                                          sessions: [],
                                                          sleep: .empty,
                                                          baseline: PersonalBaseline(),
                                                          maxHR: 190,
                                                          now: now,
                                                          authoritativeDays: [deletedDay],
                                                          calendar: calendar)

        XCTAssertTrue(merged.isEmpty)
    }

    func testAuthoritativeTodayDeletionRemovesFrozenMetricWithoutFreshEvidence() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = t0.addingTimeInterval(10 * 3_600)
        let today = calendar.startOfDay(for: now)
        let frozen = SavedDailyMetric(day: today,
                                      recoveryPercent: 76,
                                      recoveryConfidence: "ready",
                                      hrv: 54,
                                      restingHR: 55,
                                      respiratoryRate: 14,
                                      sleepDuration: 7 * 3_600,
                                      sleepSpan: 8 * 3_600,
                                      sleepStart: today.addingTimeInterval(-7 * 3_600),
                                      sleepEnd: today,
                                      sleepSource: "strap",
                                      sleepStageSegments: [],
                                      sleepConsistencyPercent: nil,
                                      strain: 2,
                                      skinTemperatureDeviationCelsius: 0.2)

        let merged = SessionStore.mergeDailyMetricHistory(existing: [frozen],
                                                          computed: [],
                                                          sessions: [],
                                                          sleep: .empty,
                                                          baseline: PersonalBaseline(),
                                                          maxHR: 190,
                                                          now: now,
                                                          authoritativeDays: [today],
                                                          calendar: calendar)

        XCTAssertTrue(merged.isEmpty)
    }

    func testRecoveredSkinTemperatureStaysBehindDecoderValidationGate() {
        // GAP-14: skin temperature stays behind a decoder-validation gate.
        // `productionSkinTemperatureDecoder` is deliberately nil until a
        // generation-specific decoder passes external-reference validation, so
        // full-drain recovery must never turn dense raw candidate frames into a
        // displayed temperature ("no temperature is displayed from candidate
        // frames alone"). When that decoder is validated, restore the minute-mean
        // decode expectations (anchor 910 → 32.5/33.5 °C) preserved in Git history.
        XCTAssertFalse(AtriaResearchProbe.validatedSkinTemperatureDecoderAvailable)
        XCTAssertNil(AtriaResearchProbe.productionSkinTemperatureDecoder)

        let session = canonicalCacheSession(startOffset: 0, pointCount: 4)
        let points = (0..<120).map { index in
            HistoricalArchive.SkinTemperatureRawPoint(
                t: session.start.addingTimeInterval(TimeInterval(index)),
                raw: index < 60 ? 900 : 920,
                strapIdentifier: "strap-a"
            )
        }

        // The same-device anchor density gate is decoder-independent and still
        // live: a dense same-device series clears the 100-sample floor, a sparse
        // one does not.
        XCTAssertNotNil(AtriaResearchProbe.whoop4SkinTemperatureAnchorRaw(points.map(\.raw)))
        XCTAssertNil(AtriaResearchProbe.whoop4SkinTemperatureAnchorRaw(
            Array(points.prefix(99)).map(\.raw)))

        // ...but recovery attaches no decoded temperature and no research
        // aggregates while the decoder is ungated, for dense or sparse input.
        let attached = SessionStore.attachRecoveredSkinTemperature(points, to: [session])
        XCTAssertNil(attached.first?.decodedSkinTemperatureCelsius)
        XCTAssertNil(attached.first?.skinTempResearchCandidateValueCount)

        let sparse = SessionStore.attachRecoveredSkinTemperature(
            Array(points.prefix(99)),
            to: [session]
        )
        XCTAssertNil(sparse.first?.decodedSkinTemperatureCelsius)
    }

    private func canonicalCacheSession(id: UUID = UUID(),
                                       startOffset: TimeInterval,
                                       pointCount: Int) -> SavedSession {
        let start = t0.addingTimeInterval(startOffset)
        let points = (0..<pointCount).map { index in
            SavedSession.Point(t: TimeInterval(index * 60), bpm: 58 + index)
        }
        return SavedSession(id: id,
                            start: start,
                            end: start.addingTimeInterval(TimeInterval(max(1, pointCount) * 60)),
                            label: "Canonical",
                            points: points)
    }

    private func rawSkinTemperatureCandidateSession(id: UUID = UUID(),
                                                    daysAgo: Int,
                                                    rawCandidate: Int) -> SavedSession {
        let start = t0.addingTimeInterval(TimeInterval(-daysAgo) * 24 * 60 * 60)
        return SavedSession(id: id,
                            start: start,
                            end: start.addingTimeInterval(8 * 60 * 60),
                            label: "Sleep temp",
                            points: [SavedSession.Point(t: 0, bpm: 58),
                                     SavedSession.Point(t: 60, bpm: 60)],
                            sleepWakeResearchState: "sleep_research",
                            sensorResearchProbeFrames: 10,
                            skinTempResearchCandidateFrames: 10,
                            skinTempResearchCandidateValueSum: rawCandidate,
                            skinTempResearchCandidateValueCount: 1)
    }

    private func decodedSkinTemperatureSession(id: UUID = UUID(),
                                               daysAgo: Int,
                                               celsius: Double) -> SavedSession {
        let start = t0.addingTimeInterval(TimeInterval(-daysAgo) * 24 * 60 * 60)
        let decoded = AtriaResearchProbe.DecodedSkinTemperatureCelsius.calibratedFixture(
            celsius: celsius,
            modelGeneration: .strap4,
            decoderVersion: "whoop4-calibrated-test-v1",
            source: .historical
        )!
        return SavedSession(id: id,
                            start: start,
                            end: start.addingTimeInterval(8 * 60 * 60),
                            label: "Sleep temp",
                            points: [SavedSession.Point(t: 0, bpm: 58),
                                     SavedSession.Point(t: 60, bpm: 60)],
                            sleepWakeResearchState: "sleep_research",
                            sensorResearchProbeFrames: 10,
                            skinTempResearchCandidateFrames: 10,
                            skinTempResearchCandidateValueSum: 826,
                            skinTempResearchCandidateValueCount: 1,
                            decodedSkinTemperatureCelsius: [decoded])
    }

    func testLatestLocalRMSSDSourcePrefersOvernightWindow() {
        var calendar = Calendar.current
        calendar.timeZone = TimeZone.current
        let day = calendar.startOfDay(for: t0)
        let daytime = hrvSession(start: day.addingTimeInterval(12 * 3_600),
                                 duration: 60 * 60,
                                 hrv: 71)
        let overnight = hrvSession(start: day.addingTimeInterval(22 * 3_600),
                                   duration: 7 * 3_600,
                                   hrv: 55)

        XCTAssertEqual(SessionStore.latestLocalRMSSD(in: [daytime]), 71)
        XCTAssertEqual(SessionStore.latestLocalRMSSD(in: [daytime, overnight]), 55)
    }

    func testRecoveryHRVSourceRequiresCurrentMorningMeasurementEnd() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let today = calendar.startOfDay(for: t0)
        let now = today.addingTimeInterval(12 * 3_600)
        let morning = hrvSession(start: today.addingTimeInterval(-2 * 3_600),
                                 duration: 8 * 3_600,
                                 hrv: 61)
        let previousMorning = hrvSession(start: today.addingTimeInterval(-26 * 3_600),
                                         duration: 8 * 3_600,
                                         hrv: 58)
        let daytime = hrvSession(start: today.addingTimeInterval(12 * 3_600),
                                 duration: 60 * 60,
                                 hrv: 72)

        XCTAssertEqual(SessionStore.recoveryEligibleHRVSource(
            SessionStore.latestLocalRMSSDSource(in: [morning]),
            on: now,
            calendar: calendar
        )?.value, 61)
        XCTAssertNil(SessionStore.recoveryEligibleHRVSource(
            SessionStore.latestLocalRMSSDSource(in: [previousMorning]),
            on: now,
            calendar: calendar
        ))
        XCTAssertNil(SessionStore.recoveryEligibleHRVSource(
            SessionStore.latestLocalRMSSDSource(in: [daytime]),
            on: today.addingTimeInterval(14 * 3_600),
            calendar: calendar
        ))
    }

    func testSavedSessionLocalHRVSummaryIsStableAcrossRepeatedReads() {
        let session = localRRSession(hrv: nil)

        XCTAssertEqual(session.localHRVWindowCount, 3)
        XCTAssertEqual(session.localRMSSD, 40)
        XCTAssertEqual(session.localRMSSD, 40)
        XCTAssertEqual(session.localHRVWindowCount, 3)
    }

    func testSavedSessionLowRateRRProducesThreeRealisticFiveMinuteWindows() {
        var beat = 0.0
        let rrPoints = (0..<600).map { index -> SavedSession.RRPoint in
            let ms = index.isMultiple(of: 2) ? 1_490 : 1_510
            beat += Double(ms) / 1_000
            return SavedSession.RRPoint(t: beat,
                                        ms: ms,
                                        source: .standardHeartRateMeasurement2A37)
        }
        let session = SavedSession(
            id: UUID(),
            start: t0,
            end: t0.addingTimeInterval(900),
            label: "Low-rate local RR",
            points: [SavedSession.Point(t: 0, bpm: 40),
                     SavedSession.Point(t: 900, bpm: 40)],
            rrPoints: rrPoints
        )

        XCTAssertEqual(session.localHRVWindowCount, 3)
        XCTAssertEqual(session.localRMSSD, 20)
    }

    func testSavedAndLiveHRVShareNonBridgingSuccessiveDifferencePolicy() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceDirectory = testsDirectory.deletingLastPathComponent().appendingPathComponent("Atria")
        let hrvSource = try String(contentsOf: sourceDirectory.appendingPathComponent("HRV.swift"), encoding: .utf8)
        let sessionsSource = try String(contentsOf: sourceDirectory.appendingPathComponent("Sessions.swift"), encoding: .utf8)

        XCTAssertTrue(hrvSource.contains("AtriaHRVSuccessiveDifferences.adjacentValues("))
        XCTAssertTrue(sessionsSource.contains("AtriaHRVSuccessiveDifferences.adjacentValues(kept)"))
        XCTAssertFalse(sessionsSource.contains("zip(kept.dropFirst(), kept)"))
    }

    func testSavedSessionLocalRMSSDStillPrefersPersistedHRV() {
        let session = localRRSession(hrv: 55)

        XCTAssertEqual(session.localRMSSD, 55)
        XCTAssertEqual(session.localHRVWindowCount, 3)
    }

    func testLatestLocalRMSSDSourceAfterUpsertKeepsOvernightRecoveryPreference() {
        var calendar = Calendar.current
        calendar.timeZone = TimeZone.current
        let day = calendar.startOfDay(for: t0)
        let overnight = hrvSession(start: day.addingTimeInterval(22 * 3_600),
                                   duration: 7 * 3_600,
                                   hrv: 55)
        let newerDaytime = hrvSession(start: day.addingTimeInterval(36 * 3_600),
                                      duration: 60 * 60,
                                      hrv: 72)

        let cached = SessionStore.latestLocalRMSSDSource(in: [overnight])
        let afterUpsert = SessionStore.latestLocalRMSSDSourceAfterUpsert(newerDaytime,
                                                                         cached: cached,
                                                                         sessions: [newerDaytime, overnight])

        XCTAssertEqual(afterUpsert?.sessionID, overnight.id)
        XCTAssertEqual(afterUpsert?.value, 55)
        XCTAssertEqual(afterUpsert?.priority, 1)
    }

    func testLatestLocalRMSSDSourceAfterUpsertRecomputesWhenCachedSourceIsRemoved() {
        var calendar = Calendar.current
        calendar.timeZone = TimeZone.current
        let day = calendar.startOfDay(for: t0)
        let sourceID = UUID()
        let olderOvernight = hrvSession(start: day.addingTimeInterval(21 * 3_600),
                                        duration: 7 * 3_600,
                                        hrv: 49)
        let originalSource = hrvSession(id: sourceID,
                                        start: day.addingTimeInterval(22 * 3_600),
                                        duration: 7 * 3_600,
                                        hrv: 55)
        let replacementWithoutHRV = hrvSession(id: sourceID,
                                               start: originalSource.start,
                                               duration: originalSource.duration,
                                               hrv: nil)

        let cached = SessionStore.latestLocalRMSSDSource(in: [originalSource, olderOvernight])
        let afterUpsert = SessionStore.latestLocalRMSSDSourceAfterUpsert(replacementWithoutHRV,
                                                                         cached: cached,
                                                                         sessions: [replacementWithoutHRV, olderOvernight])

        XCTAssertEqual(afterUpsert?.sessionID, olderOvernight.id)
        XCTAssertEqual(afterUpsert?.value, 49)
    }

    func testLatestReferenceValidatedHRVSourceAfterUpsertPromotesNewerValidatedSource() {
        let older = hrvSession(start: t0,
                               duration: 60 * 60,
                               hrv: 44,
                               hrvReferenceValidated: true)
        let newer = hrvSession(start: t0.addingTimeInterval(90 * 60),
                               duration: 60 * 60,
                               hrv: 62,
                               hrvReferenceValidated: true)

        let cached = SessionStore.latestReferenceValidatedHRVSource(in: [older])
        let afterUpsert = SessionStore.latestReferenceValidatedHRVSourceAfterUpsert(newer,
                                                                                    cached: cached,
                                                                                    sessions: [newer, older])

        XCTAssertEqual(afterUpsert?.sessionID, newer.id)
        XCTAssertEqual(afterUpsert?.value, 62)
    }

    func testDailyRespiratoryRatePreparationAveragesByMorningDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let day = calendar.startOfDay(for: t0)
        let first = respiratoryRateSession(start: day.addingTimeInterval(22 * 3_600),
                                           duration: 7 * 3_600,
                                           rate: 14)
        let second = respiratoryRateSession(start: day.addingTimeInterval(23 * 3_600),
                                            duration: 6 * 3_600,
                                            rate: 16)

        let preparation = SessionStore.makeDailyRespiratoryRatePreparation(sessions: [first, second],
                                                                           rest: 60,
                                                                           maxHR: 190,
                                                                           calendar: calendar)
        let morningDay = calendar.startOfDay(for: first.end)

        XCTAssertEqual(preparation.respiratoryRateByMorningDay[morningDay] ?? 0, 15, accuracy: 1e-9)
        XCTAssertEqual(preparation.candidateCount, 2)
    }

    func testTrendSessionRowsPrecomputeExpensiveRecoveryInputs() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let day = calendar.startOfDay(for: t0)
        let rr = localRRSession(hrv: nil)
        let validated = hrvSession(start: day.addingTimeInterval(60),
                                   duration: 60 * 60,
                                   hrv: 55,
                                   hrvReferenceValidated: true)
        let respiratory = respiratoryRateSession(start: day.addingTimeInterval(22 * 3_600),
                                                 duration: 7 * 3_600,
                                                 rate: 14)

        let rows = SessionStore.trendSessionRows(sessions: [rr, validated, respiratory],
                                                 rest: 60,
                                                 maxHR: 190,
                                                 calendar: calendar)

        XCTAssertEqual(rows.map(\.session.id), [rr.id, validated.id, respiratory.id])
        XCTAssertEqual(rows.map(\.day), [day, day, day])
        XCTAssertEqual(rows[0].localRMSSD, 40)
        XCTAssertEqual(rows[1].localRMSSD, 55)
        XCTAssertEqual(rows[1].referenceValidatedHRV, 55)
        XCTAssertEqual(rows[2].sleepRespiratoryRate ?? 0, 14, accuracy: 1e-9)
    }

    func testDailyMetricTrendDoesNotWeightSessionFragments() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let dayTwo = calendar.startOfDay(for: t0)
        let dayOne = calendar.date(byAdding: .day, value: -1, to: dayTwo)!
        let metrics = [
            dailyMetric(day: dayOne, recovery: 40, hrv: 30, restingHR: 70),
            dailyMetric(day: dayTwo, recovery: 80, hrv: 50, restingHR: 60)
        ]

        let sixFragmentSummary = SessionStore.dailyMetricTrendSummary(
            metrics: metrics,
            rollups: [],
            days: 7,
            now: dayTwo.addingTimeInterval(12 * 3_600),
            diagnosticSessionCount: 6,
            calendar: calendar
        )
        let twoSessionSummary = SessionStore.dailyMetricTrendSummary(
            metrics: metrics,
            rollups: [],
            days: 7,
            now: dayTwo.addingTimeInterval(12 * 3_600),
            diagnosticSessionCount: 2,
            calendar: calendar
        )

        XCTAssertEqual(sixFragmentSummary.avgRecovery, 60)
        XCTAssertEqual(sixFragmentSummary.avgRecovery, twoSessionSummary.avgRecovery)
        XCTAssertEqual(sixFragmentSummary.avgHRV, twoSessionSummary.avgHRV)
        XCTAssertEqual(sixFragmentSummary.avgRHR, twoSessionSummary.avgRHR)
        XCTAssertEqual(sixFragmentSummary.coverageDays, 2)
        XCTAssertEqual(sixFragmentSummary.sessions, 6,
                       "Session fragments remain diagnostics-only")
    }

    func testCrossMidnightDailyTrendBelongsToWakeDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let wakeDay = calendar.startOfDay(for: t0)
        let sleep = hrvSession(
            start: wakeDay.addingTimeInterval(-2 * 3_600),
            duration: 8 * 3_600,
            hrv: 48
        )
        let attributedDay = SessionStore.morningMetricDay(for: sleep,
                                                          calendar: calendar)
        XCTAssertEqual(attributedDay, wakeDay)
        XCTAssertNotEqual(attributedDay,
                          calendar.startOfDay(for: sleep.start))

        let summary = SessionStore.dailyMetricTrendSummary(
            metrics: [
                dailyMetric(day: attributedDay,
                            recovery: 72,
                            hrv: 48,
                            restingHR: 58)
            ],
            rollups: [],
            days: 1,
            now: wakeDay.addingTimeInterval(12 * 3_600),
            diagnosticSessionCount: 1,
            calendar: calendar
        )

        XCTAssertEqual(summary.coverageDays, 1)
        XCTAssertEqual(summary.avgRecovery, 72)
        XCTAssertEqual(summary.avgHRV, 48)
    }

    func testExerciseCatalogCustomCacheTracksStoredDataChanges() throws {
        let suiteName = "AtriaPerfFixesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let encoder = JSONEncoder()
        defaults.set(try encoder.encode(["Tempo squat", "tempo squat", " Cable row "]),
                     forKey: AtriaStrengthLog.customExercisesKey)
        XCTAssertEqual(AtriaWorkoutExerciseCatalog.customExercises(userDefaults: defaults),
                       ["Tempo squat", "Cable row"])

        defaults.set(try encoder.encode(["Nordic curl"]), forKey: AtriaStrengthLog.customExercisesKey)
        XCTAssertEqual(AtriaWorkoutExerciseCatalog.customExercises(userDefaults: defaults), ["Nordic curl"])

        AtriaWorkoutExerciseCatalog.saveCustomExercises(["Z press", "z press", "Hip thrust"],
                                                        userDefaults: defaults)
        XCTAssertEqual(AtriaWorkoutExerciseCatalog.customExercises(userDefaults: defaults),
                       ["Z press", "Hip thrust"])
    }

    func testExerciseCatalogFiltersPreloadedGroups() {
        let groups = [
            AtriaWorkoutExerciseGroup(title: "My exercises", exercises: ["Tempo squat", "Cable row"]),
            AtriaWorkoutExerciseGroup(title: "Cardio", exercises: ["Tempo run", "Outdoor walk"])
        ]

        XCTAssertEqual(AtriaWorkoutExerciseCatalog.filteredGroups(search: "tempo", groups: groups),
                       [AtriaWorkoutExerciseGroup(title: "My exercises", exercises: ["Tempo squat"]),
                        AtriaWorkoutExerciseGroup(title: "Cardio", exercises: ["Tempo run"])])
    }

    private func hrvSession(id: UUID = UUID(),
                            start: Date,
                            duration: TimeInterval,
                            hrv: Int?,
                            hrvReferenceValidated: Bool? = nil) -> SavedSession {
        let qualifiedStandardPoints = (0...900).map { index in
            SavedSession.RRPoint(
                t: Double(index),
                ms: index.isMultiple(of: 2) ? 980 : 1_020,
                source: .standardHeartRateMeasurement2A37
            )
        }
        return SavedSession(id: id,
                     start: start,
                     end: start.addingTimeInterval(duration),
                     label: "HRV",
                     points: [SavedSession.Point(t: 0, bpm: 58),
                              SavedSession.Point(t: 60, bpm: 59)],
                     hrv: hrv,
                     rrPoints: hrv == nil ? nil : qualifiedStandardPoints,
                     hrvReferenceValidated: hrvReferenceValidated)
    }

    private func dailyMetric(day: Date,
                             recovery: Int,
                             hrv: Int,
                             restingHR: Int) -> SavedDailyMetric {
        SavedDailyMetric(day: day,
                         recoveryPercent: recovery,
                         recoveryConfidence: "local",
                         hrv: hrv,
                         restingHR: restingHR,
                         respiratoryRate: 14,
                         sleepDuration: 7 * 3_600,
                         sleepSpan: 8 * 3_600,
                         sleepStart: day.addingTimeInterval(-8 * 3_600),
                         sleepEnd: day,
                         sleepSource: "confirmed",
                         sleepStageSegments: [],
                         sleepConsistencyPercent: 85,
                         strain: 6)
    }

    private func localRRSession(hrv: Int?) -> SavedSession {
        let rrPoints = (0...900).map { index in
            SavedSession.RRPoint(t: Double(index),
                                 ms: index.isMultiple(of: 2) ? 980 : 1_020,
                                 source: .standardHeartRateMeasurement2A37)
        }
        return SavedSession(id: UUID(),
                            start: t0,
                            end: t0.addingTimeInterval(900),
                            label: "Local RR",
                            points: [SavedSession.Point(t: 0, bpm: 60),
                                     SavedSession.Point(t: 900, bpm: 60)],
                            hrv: hrv,
                            rrPoints: rrPoints)
    }

    private func respiratoryRateSession(start: Date,
                                        duration: TimeInterval,
                                        rate: Double) -> SavedSession {
        SavedSession(id: UUID(),
                     start: start,
                     end: start.addingTimeInterval(duration),
                     label: "Respiratory sleep",
                     points: [SavedSession.Point(t: 0, bpm: 58),
                              SavedSession.Point(t: 60, bpm: 59)],
                     respiratoryRate: rate,
                     rrPoints: [SavedSession.RRPoint(
                        t: 0,
                        ms: 1_000,
                        source: .standardHeartRateMeasurement2A37
                     )],
                     sleepWakeResearchState: "sleep_research")
    }

    // MARK: - Fix #2 — stress-strip downsample + gap honesty

    private func stressHistory(count: Int,
                               start: Date,
                               cadence: TimeInterval = 30,
                               hrvAvailable: Bool = true,
                               activation: (Int) -> Double) -> [AtriaStressMonitorStore.StressHistoryPoint] {
        (0..<count).map { i in
            AtriaStressMonitorStore.StressHistoryPoint(t: start.addingTimeInterval(Double(i) * cadence),
                                                       activation: activation(i),
                                                       level: .low,
                                                       hrvAvailable: hrvAvailable)
        }
    }

    /// A dense two-segment day (12h @30s, split by a 10-minute gap) must (a)
    /// downsample well below the raw count, (b) keep the two runs as SEPARATE
    /// segments, and (c) never bridge the real blank — the honesty contract.
    func testReduceStressStrip_preservesGapAndDownsamples() {
        let seg0 = stressHistory(count: 720, start: t0) { i in 0.2 + 0.3 * Double(i % 5) / 5.0 }
        // 10-minute gap after seg0's last sample (> the 5-minute split threshold).
        let gapStart = t0.addingTimeInterval(Double(719) * 30 + 10 * 60)
        let seg1 = stressHistory(count: 720, start: gapStart) { i in 0.5 + 0.2 * Double(i % 4) / 4.0 }
        let history = seg0 + seg1

        let reduced = AtriaHealthScreen.reduceStressStrip(history)

        XCTAssertFalse(reduced.isEmpty)
        // Downsampled far below the ~1440 raw points, within the ~110 budget
        // (+ small per-segment slack).
        XCTAssertLessThan(reduced.count, history.count)
        XCTAssertLessThanOrEqual(reduced.count, 130)
        XCTAssertGreaterThan(reduced.count, 20)

        // Two distinct segments survive.
        XCTAssertEqual(Set(reduced.map(\.segment)), [0, 1])

        // The >5min blank is preserved: nothing is emitted inside the gap, and
        // segment 1 starts strictly after segment 0 ends by more than 5 minutes.
        let seg0Times = reduced.filter { $0.segment == 0 }.map(\.t)
        let seg1Times = reduced.filter { $0.segment == 1 }.map(\.t)
        let seg0Max = seg0Times.max()!
        let seg1Min = seg1Times.min()!
        XCTAssertGreaterThan(seg1Min.timeIntervalSince(seg0Max), 5 * 60,
                             "the real strap-off gap must stay blank, never interpolated")

        // Nothing synthesized out of the 0...3 chart domain, and time is
        // strictly increasing within each segment.
        for point in reduced {
            XCTAssert(point.value >= 0 && point.value <= 3)
        }
        XCTAssert(zip(seg0Times, seg0Times.dropFirst()).allSatisfy { $0 < $1 })
        XCTAssert(zip(seg1Times, seg1Times.dropFirst()).allSatisfy { $0 < $1 })
    }

    /// Each bucket's value is the REAL mean of its samples' activation (x3),
    /// nothing invented: a constant-activation run yields exactly that constant.
    func testReduceStressStrip_bucketValueIsHonestMean() {
        let history = stressHistory(count: 400, start: t0) { _ in 0.5 }
        let reduced = AtriaHealthScreen.reduceStressStrip(history)
        XCTAssertFalse(reduced.isEmpty)
        XCTAssertLessThan(reduced.count, history.count) // 400 > 150 => bucketed
        for point in reduced {
            XCTAssertEqual(point.value, 1.5, accuracy: 1e-9) // mean(0.5)*3
            XCTAssertEqual(point.segment, 0)
        }
    }

    /// Under the density threshold the raw points are already legible, so they
    /// pass through 1:1 (still segmented) — full fidelity for short sessions.
    func testReduceStressStrip_smallInputPassesThroughFullFidelity() {
        let history = stressHistory(count: 100, start: t0) { i in Double(i % 3) / 3.0 }
        let reduced = AtriaHealthScreen.reduceStressStrip(history)
        XCTAssertEqual(reduced.count, 100)
        XCTAssertEqual(Set(reduced.map(\.segment)), [0])
        for (i, point) in reduced.enumerated() {
            XCTAssertEqual(point.value, Double(i % 3) / 3.0 * 3, accuracy: 1e-9)
        }
    }

    func testReduceStressStrip_keepsHROnlyOnNumericLineWithoutInventingGap() {
        let history = [
            AtriaStressMonitorStore.StressHistoryPoint(t: t0,
                                                       activation: 0.3,
                                                       level: .low,
                                                       hrvAvailable: true),
            AtriaStressMonitorStore.StressHistoryPoint(t: t0.addingTimeInterval(30),
                                                       activation: 0.7,
                                                       level: .medium,
                                                       hrvAvailable: false),
            AtriaStressMonitorStore.StressHistoryPoint(t: t0.addingTimeInterval(60),
                                                       activation: 0.5,
                                                       level: .medium,
                                                       hrvAvailable: true),
        ]

        let reduced = AtriaHealthScreen.reduceStressStrip(history)

        XCTAssertEqual(reduced.count, 3)
        XCTAssertEqual(reduced[0].value, 0.9, accuracy: 1e-12)
        XCTAssertEqual(reduced[1].value, 2.1, accuracy: 1e-12)
        XCTAssertEqual(reduced[2].value, 1.5, accuracy: 1e-12)
        XCTAssertEqual(reduced.map(\.segment), [0, 0, 0],
                       "a complete HR-only estimate is numeric; only a real time gap splits the line")
    }

    /// Empty / single-point history yields nothing (matches the >1 guard).
    func testReduceStressStrip_degenerateInputs() {
        XCTAssertTrue(AtriaHealthScreen.reduceStressStrip([]).isEmpty)
        XCTAssertTrue(AtriaHealthScreen.reduceStressStrip(stressHistory(count: 1, start: t0) { _ in 0.5 }).isEmpty)
    }

    // MARK: - Fix #3 — latestRollup memo

    /// Same revision => the O(n) scan runs exactly once and the cached value is
    /// returned; a revision bump recomputes.
    func testLatestRollupCache_computesOncePerRevision() {
        let cache = AtriaHealthScreen.LatestRollupCache()
        var computeCount = 0
        let first = DailyRollupStoreEntry(day: t0, recovery: 60)

        let r1 = cache.latest(revision: 1) { computeCount += 1; return first }
        XCTAssertEqual(computeCount, 1)
        XCTAssertEqual(r1, first)

        // Same revision: must NOT recompute, even if the closure would return
        // something different — it returns the cached value.
        let r2 = cache.latest(revision: 1) {
            computeCount += 1
            return DailyRollupStoreEntry(day: t0.addingTimeInterval(86_400), recovery: 99)
        }
        XCTAssertEqual(computeCount, 1, "same revision must not rescan")
        XCTAssertEqual(r2, first)

        // Bumped revision: recompute.
        let third = DailyRollupStoreEntry(day: t0.addingTimeInterval(2 * 86_400), recovery: 42)
        let r3 = cache.latest(revision: 2) { computeCount += 1; return third }
        XCTAssertEqual(computeCount, 2)
        XCTAssertEqual(r3, third)
    }

    /// A nil result is cached too (an empty rollup history shouldn't rescan on
    /// every read).
    func testLatestRollupCache_cachesNilResult() {
        let cache = AtriaHealthScreen.LatestRollupCache()
        var computeCount = 0
        _ = cache.latest(revision: 7) { computeCount += 1; return nil }
        let again = cache.latest(revision: 7) { computeCount += 1; return nil }
        XCTAssertEqual(computeCount, 1)
        XCTAssertNil(again)
    }

    func testLatestRollupCacheRecomputesAtLocalDayRolloverWithoutRevisionChange() {
        let cache = AtriaHealthScreen.LatestRollupCache()
        let dayOne = Date(timeIntervalSince1970: 1_800_000_000)
        let dayTwo = dayOne.addingTimeInterval(24 * 60 * 60)
        var computeCount = 0

        _ = cache.latest(revision: 7, day: dayOne) { computeCount += 1; return nil }
        _ = cache.latest(revision: 7, day: dayTwo) { computeCount += 1; return nil }

        XCTAssertEqual(computeCount, 2)
    }

    func testStrainConfidenceDisclosesPartialDayWear() {
        // 2026-07-31: 81eea260 routed the label through the single
        // Metrics.StrainPresentation authority. Strain is an integral over
        // observed HR, so anything below the strong-coverage tier (95%) now
        // discloses `· partial` — including a half-worn day that the old
        // 50% threshold silently presented as complete.
        XCTAssertEqual(AtriaHomeModel.strainConfidence(
            hasRestingHeartRateEvidence: true,
            maxHRSource: .measured,
            hasLoadEvidence: true,
            resolvedRest: 58,
            maxHR: 192,
            wearCoverageFraction: 0.96
        ), "local")
        XCTAssertEqual(AtriaHomeModel.strainConfidence(
            hasRestingHeartRateEvidence: true,
            maxHRSource: .measured,
            hasLoadEvidence: true,
            resolvedRest: 58,
            maxHR: 192,
            wearCoverageFraction: 0.5
        ), "local · partial")
        XCTAssertEqual(AtriaHomeModel.strainConfidence(
            hasRestingHeartRateEvidence: true,
            maxHRSource: .measured,
            hasLoadEvidence: true,
            resolvedRest: 58,
            maxHR: 192,
            wearCoverageFraction: 0.2
        ), "local · partial")
        XCTAssertEqual(AtriaHomeModel.strainConfidence(
            hasRestingHeartRateEvidence: true,
            maxHRSource: .ageEstimate,
            hasLoadEvidence: true,
            resolvedRest: 58,
            maxHR: 187,
            wearCoverageFraction: 0.1
        ), "provisional · age-estimated max HR · partial")
        // Unknown coverage and learning states are unchanged.
        XCTAssertEqual(AtriaHomeModel.strainConfidence(
            hasRestingHeartRateEvidence: true,
            maxHRSource: .measured,
            hasLoadEvidence: true,
            resolvedRest: 58,
            maxHR: 192,
            wearCoverageFraction: nil
        ), "local")
        XCTAssertEqual(AtriaHomeModel.strainConfidence(
            hasRestingHeartRateEvidence: false,
            maxHRSource: .measured,
            hasLoadEvidence: true,
            resolvedRest: 58,
            maxHR: 192,
            wearCoverageFraction: 0.1
        ), "learning")
    }

    func testObservedWearUnionMergesOverlappingSessionsWithoutDoubleCounting() {
        let dayStart = Date(timeIntervalSince1970: 1_800_000_000)
        let intervals = [
            // All-day segment 08:00-12:00.
            (start: dayStart, end: dayStart.addingTimeInterval(4 * 3600)),
            // Workout checkpoint fully inside it (would double-count if summed).
            (start: dayStart.addingTimeInterval(3600),
             end: dayStart.addingTimeInterval(2 * 3600)),
            // Detached evening segment, partially clipped by the window end.
            (start: dayStart.addingTimeInterval(8 * 3600),
             end: dayStart.addingTimeInterval(11 * 3600)),
            // Entirely before the window: ignored.
            (start: dayStart.addingTimeInterval(-3600), end: dayStart),
        ]
        let union = AtriaHomeModel.observedWearUnionSeconds(
            intervals: intervals,
            windowStart: dayStart,
            windowEnd: dayStart.addingTimeInterval(10 * 3600)
        )
        XCTAssertEqual(union, 6 * 3600, accuracy: 1)
    }

    func testObservedHeartRateWearDoesNotPromoteSparseSessionEnvelope() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let end = start.addingTimeInterval(12 * 3_600)
        let sparse = SavedSession(
            id: UUID(),
            start: start,
            end: end,
            label: "Sparse journal",
            points: stride(from: 0.0, through: 600.0, by: 1.0).map {
                SavedSession.Point(t: $0, bpm: 80)
            }
        )
        let dense = SavedSession(
            id: UUID(),
            start: start,
            end: end,
            label: "Dense journal",
            points: stride(from: 0.0, through: 12 * 3_600.0, by: 10.0).map {
                SavedSession.Point(t: $0, bpm: 80)
            }
        )

        let sparseWear = AtriaHomeModel.observedHeartRateUnionSeconds(
            sessions: [sparse],
            windowStart: start,
            windowEnd: end
        )
        let denseWear = AtriaHomeModel.observedHeartRateUnionSeconds(
            sessions: [dense],
            windowStart: start,
            windowEnd: end
        )
        XCTAssertLessThan(sparseWear, 11 * 60)
        // The window is half-open, so the point exactly at `end` is excluded.
        // Dense ten-second evidence should therefore be within one cadence of
        // full wear, without fabricating coverage past the final accepted row.
        XCTAssertEqual(denseWear, 12 * 3_600, accuracy: 10)
    }

    func testDayWearCoverageWithholdsJudgementOnAYoungDay() {
        XCTAssertNil(AtriaHomeModel.dayWearCoverageFraction(
            observedSeconds: 600,
            dayElapsedSeconds: 3600
        ))
        XCTAssertEqual(AtriaHomeModel.dayWearCoverageFraction(
            observedSeconds: 2 * 3600,
            dayElapsedSeconds: 8 * 3600
        ) ?? -1, 0.25, accuracy: 0.001)
        // Overlap approximations can exceed elapsed time; clamp to 1.
        XCTAssertEqual(AtriaHomeModel.dayWearCoverageFraction(
            observedSeconds: 12 * 3600,
            dayElapsedSeconds: 8 * 3600
        ) ?? -1, 1.0, accuracy: 0.001)
    }

    func testRRQualityUsesNonPersistedContinuousBufferAcrossStorageRollover() {
        let rollover = t0.addingTimeInterval(3 * 60 * 60)
        let qualityWindowStart = rollover.addingTimeInterval(-300)

        XCTAssertTrue(AtriaBLEManager.shouldUseContinuousRRBuffer(
            continuityStart: qualityWindowStart,
            firstBufferedBeat: qualityWindowStart.addingTimeInterval(-0.8)
        ))
        XCTAssertFalse(AtriaBLEManager.shouldUseContinuousRRBuffer(
            continuityStart: qualityWindowStart,
            firstBufferedBeat: rollover.addingTimeInterval(0.8)
        ), "a new post-roll session buffer cannot claim coverage of the prior window")

        // The session-local archive may be empty immediately after the exact 3h
        // persistence rollover, while the non-persisted HRV buffer remains a
        // continuous physiological timeline. Its measured gap remains ~1s, not
        // the ~300s distance from the old quality-window start.
        let continuousBeats = stride(from: -300.0, through: 1.0, by: 1.0).map {
            rollover.addingTimeInterval($0)
        }
        let gap = AtriaBLEManager.maxRRBeatGap(
            inOrderedBeatTimes: continuousBeats,
            since: qualityWindowStart,
            now: rollover.addingTimeInterval(1.2)
        )
        XCTAssertEqual(gap ?? -1, 1.0, accuracy: 0.001)
    }

    func testRRQualityTimelineIncludesLeadingAndTrailingSilence() {
        let start = t0
        let beats = [
            start.addingTimeInterval(1.5),
            start.addingTimeInterval(2.5),
            start.addingTimeInterval(3.5),
        ]
        XCTAssertEqual(AtriaBLEManager.maxRRBeatGap(
            inOrderedBeatTimes: beats,
            since: start,
            now: start.addingTimeInterval(5.5)
        ) ?? -1, 2.0, accuracy: 0.001)
    }

}
