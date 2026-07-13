import ActivityKit
import Foundation
import UIKit

enum AtriaLiveWorkoutAction: String, Codable, Equatable {
    case pause
    case resume
    case end
}

struct AtriaPendingLiveWorkoutAction: Codable, Equatable {
    let action: AtriaLiveWorkoutAction
    let workoutStartedAt: Date
    let issuedAt: Date
}

/// Cross-process handoff from the Live Activity extension. The session start
/// is part of every command so a delayed tap from an old Live Activity can
/// never pause or end a newer workout.
enum AtriaLiveWorkoutActionStore {
    static let key = "atria.liveWorkout.pendingAction.v1"
    static let appGroupID = "group.com.adidshaft.atria"
    static let maximumCommandAge: TimeInterval = 5 * 60
    static let sessionMatchTolerance: TimeInterval = 1

    static func consumeAll(now: Date = Date(),
                           defaults: UserDefaults? = UserDefaults(suiteName: appGroupID)) -> [AtriaPendingLiveWorkoutAction] {
        guard let defaults,
              let data = defaults.data(forKey: key) else { return [] }
        // Consume before validation so malformed or stale commands cannot
        // repeatedly affect foreground launches.
        defaults.removeObject(forKey: key)
        let decoder = JSONDecoder()
        let commands = (try? decoder.decode([AtriaPendingLiveWorkoutAction].self, from: data))
            ?? (try? decoder.decode(AtriaPendingLiveWorkoutAction.self, from: data)).map { [$0] }
            ?? []
        return commands
            .filter {
                $0.issuedAt <= now.addingTimeInterval(5)
                    && now.timeIntervalSince($0.issuedAt) <= maximumCommandAge
            }
            .sorted { $0.issuedAt < $1.issuedAt }
    }

    static func matches(_ command: AtriaPendingLiveWorkoutAction,
                        workoutStartedAt: Date) -> Bool {
        abs(command.workoutStartedAt.timeIntervalSince(workoutStartedAt)) <= sessionMatchTolerance
    }

    /// The extension records the user's tap time, while app activation can be
    /// delayed by process launch or scene restoration. Apply the command at
    /// that durable tap time, bounded to the real workout and the current
    /// instant, so Pause/End never gains wake-up latency or a future timestamp.
    static func actionDate(_ command: AtriaPendingLiveWorkoutAction,
                           workoutStartedAt: Date,
                           now: Date = Date()) -> Date {
        min(max(command.issuedAt, workoutStartedAt), now)
    }
}

@MainActor
final class AtriaLiveActivityCoordinator {
    struct Snapshot: Equatable {
        var isRecording: Bool
        var heartRate: Int
        var heartRateCapturedAt: Date?
        var sensorHasContact: Bool
        var heartRateAvailability: AtriaLiveSensorAvailability = .unavailable
        var strain: Double
        var batteryLevel: Int
        var batteryChargeStatus: AtriaBLEManager.BatteryChargeStatus
        var readingCount: Int
        var mediaTitle: String
        var mediaArtist: String
        var mediaIsPlaying: Bool
        var mediaHasNowPlayingInfo: Bool
        var startedAt: Date
        var activityName: String
        var activitySystemImage: String
        var heartRateZoneIndex: Int
        var heartRateZoneName: String
        var steps: Int?
        var stepsAreEstimated: Bool
        var stepsCapturedAt: Date? = nil
        var stepsAvailability: AtriaLiveSensorAvailability = .unavailable
        var dailySteps: Int? = nil
        var dailyStepsAreEstimated: Bool = false
        var dailyStepGoal: Int? = nil
        var workoutStrain: Double
        var targetWorkoutStrain: Double? = nil
        var targetLowerHeartRateZone: Int? = nil
        var targetUpperHeartRateZone: Int? = nil
        var isPaused: Bool
        var elapsedDuration: TimeInterval
    }

    private var activity: Activity<AtriaLiveActivityAttributes>?
    private var startedAt: Date?
    private var lastSnapshot: Snapshot?
    private var lastActivitySnapshot: Snapshot?
    private var lastActivityUpdateAt: Date?
    private var pendingActivityUpdateTask: Task<Void, Never>?
    private var activityUpdateChain: Task<Void, Never>?
    private var hasReconciledExistingActivity = false
    private var isEndingActivity = false
    /// Keep workout metrics close to the strap without attempting one
    /// ActivityKit write for every 1 Hz sensor publication.
    private let minimumActivityUpdateInterval: TimeInterval = 5

    func update(_ snapshot: Snapshot, forceActivityWrite: Bool = false) {
        let now = Date()
        if !hasReconciledExistingActivity {
            let existingActivities = Activity<AtriaLiveActivityAttributes>.activities
            if snapshot.isRecording,
               let matching = existingActivities.first(where: {
                   Self.activityBelongsToWorkout(activityStartedAt: $0.attributes.startedAt,
                                                 workoutStartedAt: snapshot.startedAt)
               }) {
                activity = matching
                startedAt = matching.attributes.startedAt
            }
            for existing in existingActivities where existing.id != activity?.id {
                // Never leave stale duplicate/orphan controls on the Lock Screen.
                // Their immutable start token cannot safely control this workout.
                Task {
                    await existing.end(nil, dismissalPolicy: .immediate)
                    AtriaDebugLog("ATRIADBG live_activity status=ended_orphan old_start=%@ new_start=%@",
                                  existing.attributes.startedAt.description,
                                  snapshot.startedAt.description)
                }
            }
            hasReconciledExistingActivity = true
        }

        // The merged live publisher fires frequently even when no workout is
        // active. After the one-time orphan reconciliation above, idle calls
        // must not enumerate ActivityKit state or construct authorization info.
        if !snapshot.isRecording {
            guard activity != nil, !isEndingActivity else {
                lastSnapshot = snapshot
                return
            }
            pendingActivityUpdateTask?.cancel()
            pendingActivityUpdateTask = nil
            let finalSnapshot = lastSnapshot ?? snapshot
            isEndingActivity = true
            let predecessor = activityUpdateChain
            activityUpdateChain = Task { @MainActor in
                if let predecessor { await predecessor.value }
                await endActivity(with: finalSnapshot)
            }
            lastSnapshot = snapshot
            return
        }

        if activity == nil {
            guard ActivityAuthorizationInfo().areActivitiesEnabled else {
                lastSnapshot = snapshot
                return
            }
            start(with: snapshot)
        } else if forceActivityWrite
                    ? lastActivitySnapshot != snapshot
                    : Self.shouldEnqueueActivityUpdate(previous: lastSnapshot,
                                                       current: snapshot) {
            if forceActivityWrite {
                enqueueActivityUpdate(snapshot, now: now, force: true)
            } else {
                enqueueActivityUpdate(snapshot, now: now)
            }
        }
        lastSnapshot = snapshot
    }

    /// `elapsedDuration` advances on every UI pulse, but ActivityKit renders its
    /// timer from an anchor and does not need a write for each tick. Ignore that
    /// field when deciding whether new sensor/session state needs scheduling.
    nonisolated static func shouldEnqueueActivityUpdate(previous: Snapshot?,
                                                        current: Snapshot) -> Bool {
        guard var previous else { return true }
        var current = current
        previous.elapsedDuration = 0
        current.elapsedDuration = 0
        return previous != current
    }

    nonisolated static func activityBelongsToWorkout(activityStartedAt: Date,
                                                     workoutStartedAt: Date) -> Bool {
        abs(activityStartedAt.timeIntervalSince(workoutStartedAt))
            <= AtriaLiveWorkoutActionStore.sessionMatchTolerance
    }

    private func start(with snapshot: Snapshot) {
        let startDate = snapshot.startedAt
        startedAt = startDate
        let attributes = AtriaLiveActivityAttributes(startedAt: startDate)
        let state = contentState(from: snapshot)

        do {
            activity = try Activity.request(attributes: attributes,
                                            content: ActivityContent(state: state,
                                                                     staleDate: staleDate(for: snapshot)),
                                            pushType: nil)
            AtriaDebugLog("ATRIADBG live_activity status=started bpm=%d strain=%.1f readings=%d media_now_playing=%d local_only=1",
                          snapshot.heartRate,
                          snapshot.strain,
                          snapshot.readingCount,
                          snapshot.mediaHasNowPlayingInfo ? 1 : 0)
        } catch {
            AtriaDebugLog("ATRIADBG live_activity status=start_failed error=%@ local_only=1",
                          String(describing: error))
        }
        lastActivitySnapshot = snapshot
        lastActivityUpdateAt = Date()
    }

    private func updateActivity(with snapshot: Snapshot) async {
        guard let activity else { return }
        await activity.update(ActivityContent(state: contentState(from: snapshot),
                                              staleDate: staleDate(for: snapshot)))
        lastActivitySnapshot = snapshot
        lastActivityUpdateAt = Date()
    }

    private func endActivity(with snapshot: Snapshot) async {
        guard let activity else { return }
        await activity.end(ActivityContent(state: contentState(from: snapshot, isEnding: true),
                                           staleDate: nil),
                           dismissalPolicy: .after(Date().addingTimeInterval(30)))
        self.activity = nil
        isEndingActivity = false
        startedAt = nil
        lastActivitySnapshot = nil
        lastActivityUpdateAt = nil
        pendingActivityUpdateTask?.cancel()
        pendingActivityUpdateTask = nil
        activityUpdateChain = nil
        AtriaDebugLog("ATRIADBG live_activity status=ended bpm=%d strain=%.1f readings=%d media_now_playing=%d local_only=1",
                      snapshot.heartRate,
                      snapshot.strain,
                      snapshot.readingCount,
                      snapshot.mediaHasNowPlayingInfo ? 1 : 0)
    }

    private func contentState(from snapshot: Snapshot,
                              isEnding: Bool = false) -> AtriaLiveActivityAttributes.ContentState {
        let now = Date()
        let elapsed = max(0, snapshot.elapsedDuration)
        return AtriaLiveActivityAttributes.ContentState(heartRate: snapshot.heartRate,
                                                 strain: snapshot.strain,
                                                 batteryLevel: snapshot.batteryLevel,
                                                 batteryChargeStatus: snapshot.batteryChargeStatus.rawValue,
                                                 batteryChargeText: snapshot.batteryChargeStatus.label,
                                                 readingCount: snapshot.readingCount,
                                                 mediaTitle: snapshot.mediaTitle,
                                                 mediaArtist: snapshot.mediaArtist,
                                                 mediaIsPlaying: snapshot.mediaIsPlaying,
                                                 mediaHasNowPlayingInfo: snapshot.mediaHasNowPlayingInfo,
                                                 updatedAt: now,
                                                 heartRateCapturedAt: snapshot.heartRateCapturedAt,
                                                 sensorHasContact: snapshot.sensorHasContact,
                                                 heartRateAvailability: snapshot.heartRateAvailability,
                                                 activityName: snapshot.activityName,
                                                 activitySystemImage: snapshot.activitySystemImage,
                                                 heartRateZoneIndex: snapshot.heartRateZoneIndex,
                                                 heartRateZoneName: snapshot.heartRateZoneName,
                                                 steps: snapshot.steps,
                                                 stepsAreEstimated: snapshot.stepsAreEstimated,
                                                 stepsCapturedAt: snapshot.stepsCapturedAt,
                                                 stepsAvailability: snapshot.stepsAvailability,
                                                 dailySteps: snapshot.dailySteps,
                                                 dailyStepsAreEstimated: snapshot.dailyStepsAreEstimated,
                                                 dailyStepGoal: snapshot.dailyStepGoal,
                                                 workoutStrain: snapshot.workoutStrain,
                                                 targetWorkoutStrain: snapshot.targetWorkoutStrain,
                                                 targetLowerHeartRateZone: snapshot.targetLowerHeartRateZone,
                                                 targetUpperHeartRateZone: snapshot.targetUpperHeartRateZone,
                                                 isPaused: snapshot.isPaused,
                                                 isEnding: isEnding,
                                                 timerAnchor: now.addingTimeInterval(-elapsed),
                                                 elapsedDuration: elapsed)
    }

    private func enqueueActivityUpdate(_ snapshot: Snapshot,
                                       now: Date,
                                       force: Bool = false) {
        if force || shouldSendActivityUpdateImmediately(snapshot, now: now) {
            pendingActivityUpdateTask?.cancel()
            pendingActivityUpdateTask = nil
            enqueueSerializedActivityWrite(snapshot,
                                             protectsBackgroundWrite: force)
            return
        }

        guard pendingActivityUpdateTask == nil else { return }
        let delay = nextActivityUpdateDelay(now: now)
        pendingActivityUpdateTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            pendingActivityUpdateTask = nil
            guard let latest = lastSnapshot, latest.isRecording else { return }
            enqueueSerializedActivityWrite(latest)
        }
    }

    private func enqueueSerializedActivityWrite(_ snapshot: Snapshot,
                                                 protectsBackgroundWrite: Bool = false) {
        // The scene can be suspended almost immediately after entering the
        // background. Keep the process alive only for a forced boundary write,
        // and always return the assertion after ActivityKit has accepted it.
        // Normal five-second updates do not consume background execution time.
        let backgroundTask: UIBackgroundTaskIdentifier = protectsBackgroundWrite
            ? UIApplication.shared.beginBackgroundTask(withName: "Atria live workout snapshot")
            : .invalid
        let predecessor = activityUpdateChain
        activityUpdateChain = Task { @MainActor in
            defer {
                if backgroundTask != .invalid {
                    UIApplication.shared.endBackgroundTask(backgroundTask)
                }
            }
            if let predecessor { await predecessor.value }
            guard snapshot.isRecording, !isEndingActivity else { return }
            await updateActivity(with: snapshot)
        }
    }

    private func staleDate(for snapshot: Snapshot) -> Date {
        Self.sensorStaleDate(heartRateCapturedAt: snapshot.heartRateCapturedAt,
                             stepsCapturedAt: snapshot.stepsCapturedAt)
    }

    /// ActivityKit has one activity-level stale deadline, while HR and motion
    /// are independent streams. Use the newest genuine sensor timestamp for
    /// the system deadline; each metric still validates its own timestamp in
    /// the widget, so a fresh reconnecting motion stream cannot make old HR
    /// look live (or be hidden merely because HR stopped).
    nonisolated static func sensorStaleDate(heartRateCapturedAt: Date?,
                                            stepsCapturedAt: Date?,
                                            fallback: Date = Date(),
                                            freshnessWindow: TimeInterval = 90) -> Date {
        let newestSource = [heartRateCapturedAt, stepsCapturedAt]
            .compactMap { $0 }
            .max() ?? fallback
        return newestSource.addingTimeInterval(freshnessWindow)
    }

    private func shouldSendActivityUpdateImmediately(_ snapshot: Snapshot, now: Date) -> Bool {
        guard let lastActivitySnapshot, let lastActivityUpdateAt else { return true }
        return Self.shouldSendActivityUpdateImmediately(
            previous: lastActivitySnapshot,
            current: snapshot,
            elapsedSinceLastWrite: now.timeIntervalSince(lastActivityUpdateAt)
        )
    }

    /// Pure update policy for deterministic regression coverage. Signal-loss,
    /// zone and workout-state transitions bypass the cadence gate. Continuously
    /// changing HR, steps and strain are coalesced to the five-second cadence.
    nonisolated static func shouldSendActivityUpdateImmediately(previous: Snapshot,
                                                                current: Snapshot,
                                                                elapsedSinceLastWrite: TimeInterval) -> Bool {
        let elapsed = max(0, elapsedSinceLastWrite)

        if current.mediaTitle != previous.mediaTitle
            || current.mediaArtist != previous.mediaArtist
            || current.mediaIsPlaying != previous.mediaIsPlaying
            || current.mediaHasNowPlayingInfo != previous.mediaHasNowPlayingInfo
            || current.batteryLevel != previous.batteryLevel
            || current.batteryChargeStatus != previous.batteryChargeStatus {
            return true
        }

        if current.activityName != previous.activityName
            || current.activitySystemImage != previous.activitySystemImage
            || current.heartRateZoneIndex != previous.heartRateZoneIndex
            || current.targetWorkoutStrain != previous.targetWorkoutStrain
            || current.targetLowerHeartRateZone != previous.targetLowerHeartRateZone
            || current.targetUpperHeartRateZone != previous.targetUpperHeartRateZone
            || current.isPaused != previous.isPaused
            || current.sensorHasContact != previous.sensorHasContact
            || current.heartRateAvailability != previous.heartRateAvailability
            || (current.heartRate <= 0) != (previous.heartRate <= 0)
            || (current.heartRateCapturedAt == nil) != (previous.heartRateCapturedAt == nil)
            || (current.steps == nil) != (previous.steps == nil)
            || current.stepsAreEstimated != previous.stepsAreEstimated
            || (current.stepsCapturedAt == nil) != (previous.stepsCapturedAt == nil)
            || current.stepsAvailability != previous.stepsAvailability
            || (current.dailySteps == nil) != (previous.dailySteps == nil)
            || current.dailyStepsAreEstimated != previous.dailyStepsAreEstimated
            || current.dailyStepGoal != previous.dailyStepGoal {
            return true
        }

        // Goal progress is the same canonical, pause-aware workout projection
        // shown by the in-app HUD and Lock Screen.
        if let target = current.targetWorkoutStrain, target > 0,
           (previous.workoutStrain < target) != (current.workoutStrain < target) {
            return true
        }
        if let goal = current.dailyStepGoal, goal > 0,
           let previousSteps = previous.dailySteps,
           let currentSteps = current.dailySteps,
           !current.dailyStepsAreEstimated,
           (previousSteps < goal) != (currentSteps < goal) {
            return true
        }

        if elapsed >= 3,
           abs(current.heartRate - previous.heartRate) >= 4 {
            return true
        }

        return elapsed >= 5
    }

    private func nextActivityUpdateDelay(now: Date) -> UInt64 {
        guard let lastActivityUpdateAt else { return 0 }
        let remaining = max(0, minimumActivityUpdateInterval - now.timeIntervalSince(lastActivityUpdateAt))
        return UInt64(remaining * 1_000_000_000)
    }
}
