import Foundation

extension Notification.Name {
    static let atriaWorkoutRuntimeDidApplyCommand = Notification.Name(
        "com.adidshaft.atria.workout-runtime-did-apply-command"
    )
}

/// Persisted identity of the cumulative coordinate chosen at Workout Start.
/// Never infer this again from a subsequently edited activity type: changing a
/// label mid-workout must not splice two unrelated detector clocks together.
enum AtriaWorkoutStepSourceVersion: String, Codable, Equatable, Sendable {
    case strapAccelerometerV1 = "strap_accelerometer_v1"
    case strapGyroCadenceAmbulatoryV1 = "strap_gyro_cadence_ambulatory_v1"

    static func frozen(
        for activityType: AtriaWorkoutActivityType,
        gyroCoordinate: AtriaWorkoutStepCoordinate?
    ) -> Self {
        switch activityType {
        case .walking, .running, .hiking:
            // A walk usually starts from stillness, before its first R10
            // frame can have produced a fresh count.  Requiring an existing
            // count here permanently froze such walks onto the
            // accelerometer-peak coordinate, which measures arm swings and
            // can undercount normal wrist gait by roughly half.  The cadence
            // source is still wholly strap-native; this merely chooses it
            // when the strap link is ready to capture the forthcoming walk.
            return gyroCoordinate?.isCaptureLinkReady == true
                ? .strapGyroCadenceAmbulatoryV1
                : .strapAccelerometerV1
        default:
            return .strapAccelerometerV1
        }
    }
}

/// One all-day step coordinate shared by foreground Home and headless
/// Lock-Screen commands. `liveActiveSession` is connection-local; the saved
/// prefix must be hydrated and reconciled before a pause/resume/end command can
/// safely compare it with the workout's Home-created starting anchor.
struct AtriaWorkoutStepCoordinate: Equatable {
    /// Pause/resume/end attach a count to an exact user action. Unlike a HUD
    /// render, an action-time coordinate must not borrow even the next 1 Hz
    /// motion frame; that would attribute post-tap steps to the earlier edge.
    static let actionFutureTolerance: TimeInterval = 0
    /// The HUD may retain a 15-second last-known count for continuity, but a
    /// pause/resume/end boundary needs a detector-applied coordinate close to
    /// the tap. R10 evaluates at 1 Hz; 2.5 seconds allows one delayed cadence
    /// without treating a visibly stale count as complete workout evidence.
    static let actionDetectorSnapshotMaximumAge: TimeInterval = 2.5

    let cumulativeCount: Int
    let hasEvidence: Bool
    let isEstimated: Bool
    let capturedAt: Date?
    /// Link readiness is distinct from evidence freshness.  It permits a
    /// newly-started ambulatory workout to select its strap cadence source
    /// before its first motion frame exists, while action boundaries still
    /// require `isLiveForCompletion` and therefore never invent a step.
    let isCaptureLinkReady: Bool
    let isLiveForCompletion: Bool

    static func make(savedPrefixHydrated: Bool,
                     savedToday: Int,
                     savedActiveSession: Int,
                     savedActiveSessionTotal: Int,
                     liveActiveSession: Int,
                     hasLiveStepEvidence: Bool,
                     isValidated: Bool,
                     capturedAt: Date?,
                     isConnected: Bool,
                     reconnectPending: Bool,
                     rangeLossBackfillPending: Bool,
                     now: Date) -> Self? {
        guard savedPrefixHydrated else { return nil }
        let cumulativeCount = AtriaHomeModel.mergedStrapStepResearchCount(
            savedToday: savedToday,
            savedActiveSession: savedActiveSession,
            savedActiveSessionTotal: savedActiveSessionTotal,
            liveActiveSession: liveActiveSession
        )
        let hasEvidence = cumulativeCount > 0 || hasLiveStepEvidence || capturedAt != nil
        let fresh = capturedAt.map {
            $0 <= now.addingTimeInterval(actionFutureTolerance)
                && now.timeIntervalSince($0) <= actionDetectorSnapshotMaximumAge
        } ?? false
        return Self(
            cumulativeCount: cumulativeCount,
            hasEvidence: hasEvidence,
            isEstimated: hasEvidence && !isValidated,
            capturedAt: capturedAt,
            isCaptureLinkReady: isConnected
                && !reconnectPending
                && !rangeLossBackfillPending,
            isLiveForCompletion: hasEvidence
                && fresh
                && isConnected
                && !reconnectPending
                && !rangeLossBackfillPending
        )
    }

    /// Builds a coordinate whose durable ledger already owns the cumulative
    /// prefix. This is used only by the explicitly ambulatory workout source;
    /// it is intentionally not routed into Home/day-step production totals.
    static func makeCumulative(
        savedPrefixHydrated: Bool,
        cumulativeCount: Int,
        hasEvidence: Bool,
        capturedAt: Date?,
        isConnected: Bool,
        reconnectPending: Bool,
        rangeLossBackfillPending: Bool,
        now: Date
    ) -> Self? {
        guard savedPrefixHydrated else { return nil }
        let count = max(0, cumulativeCount)
        let fresh = capturedAt.map {
            $0 <= now.addingTimeInterval(actionFutureTolerance)
                && now.timeIntervalSince($0) <= actionDetectorSnapshotMaximumAge
        } ?? false
        return Self(
            cumulativeCount: count,
            hasEvidence: hasEvidence,
            isEstimated: hasEvidence,
            capturedAt: capturedAt,
            isCaptureLinkReady: isConnected
                && !reconnectPending
                && !rangeLossBackfillPending,
            isLiveForCompletion: hasEvidence
                && fresh
                && isConnected
                && !reconnectPending
                && !rangeLossBackfillPending
        )
    }
}

/// A completed workout owns only the strap-derived boundary captured by its
/// frozen step coordinate. Atria never substitutes iPhone pedometer data for
/// a missing or preliminary strap interval: that would make a wrist product
/// report steps the strap did not observe.
struct AtriaCompletedWorkoutStepEvidence: Equatable {
    let count: Int
    let isEstimated: Bool
    let capturedAt: Date?

    static func select(strap: Self?) -> Self? {
        // Workout totals are a product claim, not a research readout.  Until
        // the frozen strap detector has a fresh, validated boundary, retain
        // no total at all.  In particular, do not turn an unavailable R10
        // interval into `~0 steps` or carry a preliminary strap estimate into
        // the saved workout/share card.  There is intentionally no phone
        // pedometer alternative here.
        guard let strap,
              strap.isEstimated == false,
              strap.capturedAt != nil else { return nil }
        return sanitized(strap)
    }

    private static func sanitized(_ evidence: Self) -> Self {
        Self(count: max(0, evidence.count),
             isEstimated: evidence.isEstimated,
             capturedAt: evidence.capturedAt)
    }
}

/// Pure canonical-state transition used by the root runtime and unit tests.
/// Sensor values are inputs, never inferred: pause-only step deltas are based
/// on the strap's current cumulative count, while unavailable evidence remains
/// the existing persisted value.
enum AtriaWorkoutCommandTransaction {
    static func applying(_ action: AtriaLiveWorkoutAction,
                         to original: AtriaPendingWorkoutIntent,
                         at actionDate: Date,
                         currentStepCount: Int,
                         hasCurrentStepEvidence: Bool = false,
                         currentStepsAreEstimated: Bool = true,
                         currentStepsCapturedAt: Date? = nil) -> AtriaPendingWorkoutIntent? {
        guard original.endedAt == nil else { return nil }
        var updated = original
        let boundedDate = max(original.startedAt, actionDate)

        switch action {
        case .pause:
            guard updated.pauseStartedAt == nil else { return updated }
            updated.pauseStartedAt = boundedDate
            if hasCurrentStepEvidence {
                updated.pauseStartedStepCount = max(0, currentStepCount)
            } else {
                updated.pauseStartedStepCount = nil
                updated.stepAccountingIsComplete = false
            }
        case .resume:
            guard let pauseStartedAt = updated.pauseStartedAt else { return updated }
            let resumedAt = max(boundedDate, pauseStartedAt)
            if resumedAt > pauseStartedAt {
                updated.excludedIntervals.append(
                    ExcludedInterval(start: pauseStartedAt, end: resumedAt)
                )
            }
            if let pauseStepAnchor = updated.pauseStartedStepCount,
               hasCurrentStepEvidence,
               updated.stepAccountingIsComplete {
                updated.pausedStepCount += max(0, currentStepCount - pauseStepAnchor)
            } else {
                updated.stepAccountingIsComplete = false
            }
            updated.pauseStartedAt = nil
            updated.pauseStartedStepCount = nil
        case .end:
            // End is terminal before any route/session side effect. An open
            // pause remains represented by pauseStartedAt so recovery closes
            // it exactly at endedAt via finalizedExcludedIntervals().
            if let pauseStepAnchor = updated.pauseStartedStepCount,
               hasCurrentStepEvidence,
               updated.stepAccountingIsComplete {
                updated.pausedStepCount += max(0, currentStepCount - pauseStepAnchor)
                updated.pauseStartedStepCount = nil
            } else if updated.pauseStartedAt != nil {
                updated.pauseStartedStepCount = nil
                updated.stepAccountingIsComplete = false
            }
            // End evidence is a snapshot, not a sticky progress field. A stale
            // motion clock or pending reconnect/backfill must clear any prior
            // provisional completion so recovery/share cannot present a partial
            // total as the whole workout.
            updated.completedStepCount = nil
            updated.completedStepsAreEstimated = nil
            updated.completedStepsCapturedAt = nil
            if hasCurrentStepEvidence, updated.stepAccountingIsComplete {
                updated.completedStepCount = max(
                    0,
                    currentStepCount - updated.startingStepCount - updated.pausedStepCount
                )
                updated.completedStepsAreEstimated = currentStepsAreEstimated
                updated.completedStepsCapturedAt = currentStepsCapturedAt
            }
            updated.endedAt = boundedDate
        }
        return updated
    }
}

/// App-lifetime workout command owner. Live Activity intents run in the main
/// process and reach this service through AppDependency even if no SwiftUI
/// workout screen is visible. The pending intent is the canonical crash-safe
/// record; route and journal changes happen only after that record is saved.
@MainActor
final class AtriaWorkoutRuntime {
    private let ble: AtriaBLEManager
    private let store: SessionStore
    let routeRecorder: AtriaWorkoutRouteRecorder
    /// Root scene activation can arrive through both SwiftUI and UIKit during
    /// the same transition. Keep one replay owner so those edges never scan the
    /// app-group command directory twice while the return animation is drawing.
    private var pendingActionReplayTask: Task<Void, Never>?
    /// A terminal intent is the crash-safe authority for a workout whose End
    /// command was accepted. Materializing that intent must not depend on the
    /// Home view existing: the app can be launched into another destination or
    /// suspended before Home's short presentation-level retry window runs.
    private var terminalWorkoutRecoveryTask: Task<Void, Never>?

    init(ble: AtriaBLEManager,
         store: SessionStore,
         routeRecorder: AtriaWorkoutRouteRecorder) {
        self.ble = ble
        self.store = store
        self.routeRecorder = routeRecorder
    }

    func suspendForCanonicalRestoreFailure() {
        pendingActionReplayTask?.cancel()
        pendingActionReplayTask = nil
        terminalWorkoutRecoveryTask?.cancel()
        terminalWorkoutRecoveryTask = nil
    }

    func handleLiveActivityCommand(
        _ requestedAction: AtriaLiveWorkoutControlCommand,
        workoutStartedAt: Date,
        issuedAt: Date
    ) async -> AtriaLiveWorkoutCanonicalCommandState? {
        await store.waitForDeferredSessionLoadIfNeeded()
        guard store.hasLoadedSavedSessions else { return nil }
        let now = Date()
        let commands = await Self.performPendingActionLoad {
            AtriaLiveWorkoutActionStore.consumeAll(now: now)
        }
        return await applyPendingActions(commands: commands,
                                         expectedAction: requestedAction,
                                         expectedWorkoutStartedAt: workoutStartedAt,
                                         expectedIssuedAt: issuedAt,
                                         now: now)
    }

    /// Schedule root-launch/foreground replay without doing app-group file I/O
    /// in the scene callback. Duplicate activation edges share the same task.
    func schedulePendingActionReplay() {
        guard pendingActionReplayTask == nil else { return }
        pendingActionReplayTask = Task { @MainActor [weak self] in
            // Leave the lifecycle callback immediately so SwiftUI can commit
            // the returning frame before any command side effect is applied.
            await Task.yield()
            guard let self else { return }
            guard await AtriaPendingWorkoutIntent.preparePersistence() else {
                self.pendingActionReplayTask = nil
                return
            }
            _ = await self.replayPendingActions()
            self.pendingActionReplayTask = nil
            await self.recoverAbandonedWorkoutIntentIfNeeded()
            self.scheduleTerminalWorkoutRecovery()
        }
    }

    /// A workout the user never ended must not run forever. Past the 24 h
    /// continuity bound the intent is finalized at the capped end and handed
    /// to the normal terminal-recovery worker: the workout saves with stats
    /// from its actual samples (coverage discloses real wear), the motion
    /// lease releases, and the result is visible in history where the user
    /// can adjust or delete it.
    private func recoverAbandonedWorkoutIntentIfNeeded() async {
        guard let intent = AtriaPendingWorkoutIntent.load(),
              let cappedEnd = AtriaPendingWorkoutIntent.abandonedRecoveryEndDate(
                  intent: intent
              ) else { return }
        var terminal = intent
        terminal.endedAt = cappedEnd
        guard await terminal.persistTerminal() != nil else { return }
        AtriaDebugLog("ATRIADBG workout_recovery status=abandoned_intent_finalized started_unix=%d capped_end_unix=%d action=terminal_recovery_owns_completion",
                      Int(intent.startedAt.timeIntervalSince1970),
                      Int(cappedEnd.timeIntervalSince1970))
    }

    /// App-lifetime completion owner for an ended workout intent. Failed sensor,
    /// route, or persistence preparation keeps the immutable intent in place and
    /// retries with a bounded cadence for as long as this process remains alive.
    /// Confirmation is idempotent by workout ID, so a presentation-layer attempt
    /// racing this worker cannot create a duplicate workout.
    func scheduleTerminalWorkoutRecovery() {
        guard terminalWorkoutRecoveryTask == nil,
              AtriaPendingWorkoutIntent.load()?.endedAt != nil else { return }
        terminalWorkoutRecoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.terminalWorkoutRecoveryTask = nil }
            var retryDelay: TimeInterval = 2
            while !Task.isCancelled {
                await self.store.waitForDeferredSessionLoadIfNeeded()
                if await self.recoverTerminalWorkoutIntentIfNeeded() {
                    return
                }
                do {
                    try await Task.sleep(for: .seconds(retryDelay))
                } catch {
                    return
                }
                retryDelay = min(retryDelay * 2, 5 * 60)
            }
        }
    }

    /// Returns true when there is no longer a terminal intent for this worker,
    /// including successful completion or a concurrent owner replacing it.
    private func recoverTerminalWorkoutIntentIfNeeded() async -> Bool {
        guard let intent = AtriaPendingWorkoutIntent.load(),
              let endedAt = intent.endedAt else { return true }
        let routeDraft = await routeRecorder.finalizedDraft(
            startedAt: intent.startedAt,
            activityType: intent.resolvedActivityType,
            endedAt: endedAt
        )
        guard AtriaPendingWorkoutIntent.load() == intent else { return true }

        // An intent can survive an app update. Reapply the same strict
        // strap-only admission rule used by the foreground End path so an old
        // preliminary estimate cannot be materialized after relaunch.
        let stepEvidence = AtriaCompletedWorkoutStepEvidence.select(
            strap: intent.completedStepCount.map {
                AtriaCompletedWorkoutStepEvidence(
                    count: $0,
                    isEstimated: intent.completedStepsAreEstimated ?? true,
                    capturedAt: intent.completedStepsCapturedAt
                )
            }
        )
        let confirmed = await store.confirmWorkoutWindowForUIAsync(
            start: intent.startedAt,
            end: endedAt,
            rest: intent.calculationContext?.restingHeartRate
                ?? store.baseline.restingInt
                ?? 60,
            maxHR: intent.calculationContext?.maximumHeartRate
                ?? store.profile.maxHR,
            source: "pending_live_workout_root_recovery",
            preserveUserDeclaredActivityWithoutHeartRate: true,
            activityType: intent.resolvedActivityType == .other ? nil : intent.activityType,
            strengthSets: intent.strengthSets,
            excludedIntervals: intent.finalizedExcludedIntervals(),
            workoutSteps: stepEvidence?.count,
            workoutStepsAreEstimated: stepEvidence?.isEstimated,
            workoutStepsCapturedAt: stepEvidence?.capturedAt
        )
        guard let confirmed else { return false }

        if let routeDraft,
           await AtriaWorkoutRouteStore.saveAsync(routeDraft, workoutID: confirmed.id) == nil {
            // The canonical workout is safe, but retain the terminal intent so a
            // later pass can attach the exact route before clearing its checkpoint.
            return false
        }
        let persisted = await withCheckedContinuation {
            (continuation: CheckedContinuation<Bool, Never>) in
            store.flushScheduledPersistenceAsync(reason: "root_terminal_workout_recovery") { succeeded in
                continuation.resume(returning: succeeded)
            }
        }
        guard persisted else { return false }
        guard AtriaPendingWorkoutIntent.load() == intent else { return true }
        guard await AtriaPendingWorkoutIntent.clearIfUnchanged(intent) else { return false }
        // The intent is fully recovered and cleared; release the strap motion
        // ownership lease so no bounded activation outlives the workout.
        ble.endWorkoutMotionLease(reason: "terminal_recovery")
        routeRecorder.discardDurableCheckpoint()
        store.exportToHealthKit()
        AtriaDebugLog("ATRIADBG live_workout_recovery status=confirmed owner=root workout_id=%@ route=%d",
                      confirmed.id,
                      routeDraft == nil ? 0 : 1)
        return true
    }

    /// Root-launch replay for a command whose process was interrupted after
    /// the queue write. Directory enumeration, atomic claims and JSON reads run
    /// away from MainActor; only the canonical state transaction returns here.
    @discardableResult
    func replayPendingActions(now: Date = Date()) async -> AtriaLiveWorkoutCanonicalCommandState? {
        await store.waitForDeferredSessionLoadIfNeeded()
        guard store.hasLoadedSavedSessions else { return nil }
        let commands = await Self.performPendingActionLoad {
            AtriaLiveWorkoutActionStore.consumeAll(now: now)
        }
        return await applyPendingActions(commands: commands,
                                         expectedAction: nil,
                                         expectedWorkoutStartedAt: nil,
                                         expectedIssuedAt: nil,
                                         now: now)
    }

    /// Small reusable seam that proves filesystem-backed command discovery is
    /// not executed on MainActor. The result remains value-only and Sendable.
    nonisolated static func performPendingActionLoad<Value: Sendable>(
        _ operation: @escaping @Sendable () -> Value
    ) async -> Value {
        await Task.detached(priority: .userInitiated, operation: operation).value
    }

    private func applyPendingActions(
        commands: [AtriaPendingLiveWorkoutAction],
        expectedAction: AtriaLiveWorkoutControlCommand?,
        expectedWorkoutStartedAt: Date?,
        expectedIssuedAt: Date?,
        now: Date
    ) async -> AtriaLiveWorkoutCanonicalCommandState? {
        guard !commands.isEmpty else { return nil }

        var canonicalState: AtriaLiveWorkoutCanonicalCommandState?
        var didApplyExpectedCommand = expectedAction == nil
        for (commandIndex, command) in commands.enumerated() {
            guard var intent = AtriaPendingWorkoutIntent.load() else {
                // Startup restoration can race the App Intent host. Release the
                // complete ordered tail; applying a later Resume before this
                // Pause would invert canonical state.
                for pending in commands[commandIndex...] {
                    AtriaLiveWorkoutActionStore.release(pending)
                }
                break
            }
            guard AtriaLiveWorkoutActionStore.matches(
                command,
                workoutStartedAt: intent.startedAt
            ) else {
                AtriaLiveWorkoutActionStore.acknowledge(command)
                continue
            }
            let actionDate = AtriaLiveWorkoutActionStore.actionDate(
                command,
                workoutStartedAt: intent.startedAt,
                now: now
            )
            guard let motionBoundaryAt = await ble.synchronizeCurrentR10MotionAccounting() else {
                for pending in commands[commandIndex...] {
                    AtriaLiveWorkoutActionStore.release(pending)
                }
                break
            }
            // A promptly handled command uses the FIFO marker as its exact step
            // edge. A delayed launch replay preserves the original action time
            // and therefore fails live step evidence closed instead of borrowing
            // motion that occurred minutes later.
            let stepReferenceDate = motionBoundaryAt.timeIntervalSince(actionDate)
                <= AtriaWorkoutStepCoordinate.actionDetectorSnapshotMaximumAge
                ? max(actionDate, motionBoundaryAt)
                : actionDate
            guard let stepCoordinate = currentStepCoordinate(
                sourceVersion: intent.stepSourceVersion,
                now: stepReferenceDate
            ) else {
                // The Home-created starting anchor is in the merged all-day
                // coordinate. Until the saved prefix is hydrated, comparing it
                // with a connection-local count can underflow or invent paused
                // steps. Keep the entire ordered tail pending for a later replay.
                for pending in commands[commandIndex...] {
                    AtriaLiveWorkoutActionStore.release(pending)
                }
                break
            }
            guard let transitioned = AtriaWorkoutCommandTransaction.applying(
                command.action,
                to: intent,
                at: actionDate,
                currentStepCount: stepCoordinate.cumulativeCount,
                hasCurrentStepEvidence: stepCoordinate.isLiveForCompletion,
                currentStepsAreEstimated: stepCoordinate.isEstimated,
                currentStepsCapturedAt: stepCoordinate.isLiveForCompletion
                    ? stepCoordinate.capturedAt : nil
            ) else {
                // A terminal intent proves this tap is obsolete and safe to ack.
                AtriaLiveWorkoutActionStore.acknowledge(command)
                continue
            }
            let original = intent
            intent = transitioned
            intent.persistenceRevision = command.action == .end
                ? .max
                : original.persistenceRevision &+ 1
            guard await intent.replacePersisted(expected: original) else {
                // Preserve FIFO semantics across a transient write/CAS failure.
                // Every later claimed action returns to pending with this one.
                for pending in commands[commandIndex...] {
                    AtriaLiveWorkoutActionStore.release(pending)
                }
                break
            }

            applyDurableSideEffects(for: command.action,
                                    intent: intent,
                                    at: actionDate)
            AtriaLiveWorkoutActionStore.acknowledge(command)

            let appliedExpected = expectedAction.map {
                $0.rawValue == command.action.rawValue
                    && expectedWorkoutStartedAt.map {
                        abs($0.timeIntervalSince(command.workoutStartedAt))
                            <= AtriaLiveWorkoutActionStore.sessionMatchTolerance
                    } ?? true
                    && expectedIssuedAt.map {
                        abs($0.timeIntervalSince(command.issuedAt)) < 0.001
                    } ?? true
            } ?? true
            didApplyExpectedCommand = didApplyExpectedCommand || appliedExpected
            canonicalState = Self.canonicalState(from: intent,
                                                 appliedAt: actionDate)

            if command.action == .end {
                // End is terminal for this immutable workout token. Commands
                // later in the same burst cannot safely alter the ended record.
                commands.forEach(AtriaLiveWorkoutActionStore.acknowledge)
                scheduleTerminalWorkoutRecovery()
                break
            }
        }

        guard didApplyExpectedCommand, let canonicalState else { return nil }
        NotificationCenter.default.post(name: .atriaWorkoutRuntimeDidApplyCommand,
                                        object: nil)
        return canonicalState
    }

    private func currentStepCoordinate(
        sourceVersion: AtriaWorkoutStepSourceVersion,
        now: Date
    ) -> AtriaWorkoutStepCoordinate? {
        if sourceVersion == .strapGyroCadenceAmbulatoryV1 {
            return ble.ambulatoryWorkoutGyroStepCoordinate(now: now)
        }
        guard store.hasLoadedSavedSessions else { return nil }
        let rest = store.baseline.restingInt ?? 60
        let saved = store.homeSavedAggregate(
            rest: rest,
            maxHR: store.profile.maxHR,
            activeSessionID: ble.currentLiveSessionID,
            now: now
        )
        let capturedAt = ble.liveStrapStepCountCapturedAt
        return AtriaWorkoutStepCoordinate.make(
            savedPrefixHydrated: true,
            savedToday: saved.savedTodayStrapSteps,
            savedActiveSession: saved.savedActiveSessionStrapSteps,
            savedActiveSessionTotal: saved.savedActiveSessionTotalStrapSteps,
            liveActiveSession: ble.liveStrapStepResearchCount,
            hasLiveStepEvidence: ble.liveStrapStepResearchCount > 0,
            isValidated: WidgetSnapshotPublisher.strapStepsAreValidated(
                state: ble.liveStrapStepResearchState
            ),
            capturedAt: capturedAt,
            isConnected: ble.status == .connected,
            reconnectPending: ble.pendingKnownReconnectStartedAt != nil,
            rangeLossBackfillPending: ble.rangeLossBackfillPending,
            now: now
        )
    }

    private func applyDurableSideEffects(for action: AtriaLiveWorkoutAction,
                                         intent: AtriaPendingWorkoutIntent,
                                         at actionDate: Date) {
        switch action {
        case .pause:
            routeRecorder.pause(at: actionDate)
        case .resume:
            routeRecorder.resume(at: actionDate)
        case .end:
            if intent.resolvedActivityType.supportsRouteRecording {
                _ = routeRecorder.stop(at: actionDate)
            } else {
                routeRecorder.cancel()
            }
        }

        let mirroredIntervals: [ExcludedInterval]
        if intent.endedAt != nil {
            mirroredIntervals = intent.finalizedExcludedIntervals()
        } else if let pauseStartedAt = intent.pauseStartedAt {
            mirroredIntervals = intent.excludedIntervals + [
                ExcludedInterval(start: pauseStartedAt,
                                 end: max(actionDate, pauseStartedAt))
            ]
        } else {
            mirroredIntervals = intent.excludedIntervals
        }
        try? ActiveSessionJournal.mirrorStrengthState(
            strengthSets: intent.strengthSets,
            excludedIntervals: mirroredIntervals
        )
        ble.configureWorkoutZoneHaptics(
            workoutStartedAt: intent.endedAt == nil ? intent.startedAt : nil,
            lowerTargetZone: intent.lowerTargetZone,
            upperTargetZone: intent.upperTargetZone,
            maxHR: store.profile.maxHR,
            isPaused: intent.pauseStartedAt != nil
        )
        ble.flushActiveSessionJournal(reason: "live_activity_\(action.rawValue)")
        store.requestPersistenceFlush(reason: "live_activity_\(action.rawValue)")
    }

    private static func canonicalState(
        from intent: AtriaPendingWorkoutIntent,
        appliedAt: Date
    ) -> AtriaLiveWorkoutCanonicalCommandState {
        let projectionDate = intent.endedAt ?? appliedAt
        let intervals = intent.endedAt == nil
            ? intent.excludedIntervals
            : intent.finalizedExcludedIntervals()
        let duration = AtriaWorkoutMovingDuration.project(
            startedAt: intent.startedAt,
            excludedIntervals: intervals,
            pauseStartedAt: intent.endedAt == nil ? intent.pauseStartedAt : nil,
            now: projectionDate
        )
        return AtriaLiveWorkoutCanonicalCommandState(
            isPaused: intent.pauseStartedAt != nil || intent.endedAt != nil,
            isEnding: intent.endedAt != nil,
            elapsedDuration: duration,
            appliedAt: projectionDate
        )
    }
}
