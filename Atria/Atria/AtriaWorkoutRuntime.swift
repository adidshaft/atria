import Foundation

extension Notification.Name {
    static let atriaWorkoutRuntimeDidApplyCommand = Notification.Name(
        "com.adidshaft.atria.workout-runtime-did-apply-command"
    )
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
            updated.pauseStartedStepCount = max(0, currentStepCount)
        case .resume:
            guard let pauseStartedAt = updated.pauseStartedAt else { return updated }
            let resumedAt = max(boundedDate, pauseStartedAt)
            if resumedAt > pauseStartedAt {
                updated.excludedIntervals.append(
                    ExcludedInterval(start: pauseStartedAt, end: resumedAt)
                )
            }
            if let pauseStepAnchor = updated.pauseStartedStepCount {
                updated.pausedStepCount += max(0, currentStepCount - pauseStepAnchor)
            }
            updated.pauseStartedAt = nil
            updated.pauseStartedStepCount = nil
        case .end:
            // End is terminal before any route/session side effect. An open
            // pause remains represented by pauseStartedAt so recovery closes
            // it exactly at endedAt via finalizedExcludedIntervals().
            if let pauseStepAnchor = updated.pauseStartedStepCount {
                updated.pausedStepCount += max(0, currentStepCount - pauseStepAnchor)
                updated.pauseStartedStepCount = nil
            }
            if hasCurrentStepEvidence {
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

    init(ble: AtriaBLEManager,
         store: SessionStore,
         routeRecorder: AtriaWorkoutRouteRecorder) {
        self.ble = ble
        self.store = store
        self.routeRecorder = routeRecorder
    }

    func handleLiveActivityCommand(
        _ requestedAction: AtriaLiveWorkoutControlCommand,
        workoutStartedAt: Date,
        issuedAt: Date
    ) async -> AtriaLiveWorkoutCanonicalCommandState? {
        let now = Date()
        let commands = await Self.performPendingActionLoad {
            AtriaLiveWorkoutActionStore.consumeAll(now: now)
        }
        return applyPendingActions(commands: commands,
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
            _ = await self.replayPendingActions()
            self.pendingActionReplayTask = nil
        }
    }

    /// Root-launch replay for a command whose process was interrupted after
    /// the queue write. Directory enumeration, atomic claims and JSON reads run
    /// away from MainActor; only the canonical state transaction returns here.
    @discardableResult
    func replayPendingActions(now: Date = Date()) async -> AtriaLiveWorkoutCanonicalCommandState? {
        let commands = await Self.performPendingActionLoad {
            AtriaLiveWorkoutActionStore.consumeAll(now: now)
        }
        return applyPendingActions(commands: commands,
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
    ) -> AtriaLiveWorkoutCanonicalCommandState? {
        guard !commands.isEmpty else { return nil }

        var canonicalState: AtriaLiveWorkoutCanonicalCommandState?
        var didApplyExpectedCommand = expectedAction == nil
        for command in commands {
            guard var intent = AtriaPendingWorkoutIntent.load() else {
                // Startup restoration can race the App Intent host. Release the
                // claim immediately; root-launch replay will retry it.
                AtriaLiveWorkoutActionStore.release(command)
                continue
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
            let motionCapturedAt = ble.liveStrapMotionCapturedAt
                ?? AtriaStrapStepLiveStatus.persistedMotionDate()
            guard let transitioned = AtriaWorkoutCommandTransaction.applying(
                command.action,
                to: intent,
                at: actionDate,
                currentStepCount: ble.liveStrapStepResearchCount,
                hasCurrentStepEvidence: ble.liveStrapStepResearchCount > 0 || motionCapturedAt != nil,
                currentStepsAreEstimated: !WidgetSnapshotPublisher.strapStepsAreValidated(
                    state: ble.liveStrapStepResearchState
                ),
                currentStepsCapturedAt: motionCapturedAt
            ) else {
                // A terminal intent proves this tap is obsolete and safe to ack.
                AtriaLiveWorkoutActionStore.acknowledge(command)
                continue
            }
            intent = transitioned
            guard intent.save() else {
                AtriaLiveWorkoutActionStore.release(command)
                continue
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
                break
            }
        }

        guard didApplyExpectedCommand, let canonicalState else { return nil }
        NotificationCenter.default.post(name: .atriaWorkoutRuntimeDidApplyCommand,
                                        object: nil)
        return canonicalState
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
