import ActivityKit
import Foundation
import UIKit

enum AtriaLiveWorkoutAction: String, Codable, Equatable, Sendable {
    case pause
    case resume
    case end
}

struct AtriaPendingLiveWorkoutAction: Codable, Equatable, Sendable {
    let action: AtriaLiveWorkoutAction
    let workoutStartedAt: Date
    let issuedAt: Date
    /// Transport-only receipt for an atomically claimed file. Widget JSON from
    /// older and current builds omits it; the app attaches it after claiming.
    var claimReceipt: String? = nil

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.action == rhs.action
            && lhs.workoutStartedAt == rhs.workoutStartedAt
            && lhs.issuedAt == rhs.issuedAt
    }
}

/// Cross-process handoff from the Live Activity extension. The session start
/// is part of every command so a delayed tap from an old Live Activity can
/// never pause or end a newer workout.
enum AtriaLiveWorkoutActionStore {
    static let key = "atria.liveWorkout.pendingAction.v1"
    static let appGroupID = "group.com.adidshaft.atria"
    static let queueDirectoryName = "AtriaLiveWorkoutActions-v2"
    static let pendingFilePrefix = "pending-"
    static let claimedFilePrefix = "claimed-"
    static let maximumQueuedCommands = 16
    static let maximumCommandAge: TimeInterval = 5 * 60
    static let sessionMatchTolerance: TimeInterval = 1
    private static let futureClockTolerance: TimeInterval = 5
    private static let abandonedClaimAge: TimeInterval = 30

    /// Claims every pending command file before decoding it. A unique file per
    /// tap removes the extension's previous cross-process read/modify/write
    /// race, where Pause -> Resume (or Pause -> End) could lose one action.
    /// The legacy defaults blob is still drained during migration.
    static func consumeAll(now: Date = Date()) -> [AtriaPendingLiveWorkoutAction] {
        consumeAll(now: now,
                   defaults: UserDefaults(suiteName: appGroupID),
                   queueDirectoryURL: defaultQueueDirectoryURL())
    }

    /// Test and migration entry point that consumes only the supplied legacy
    /// defaults. Production callers use `consumeAll(now:)` above.
    static func consumeAll(now: Date,
                           defaults: UserDefaults?) -> [AtriaPendingLiveWorkoutAction] {
        consumeAll(now: now, defaults: defaults, queueDirectoryURL: nil)
    }

    static func consumeAll(now: Date,
                           defaults: UserDefaults?,
                           queueDirectoryURL: URL?) -> [AtriaPendingLiveWorkoutAction] {
        var commands = consumeClaimedFiles(now: now,
                                           queueDirectoryURL: queueDirectoryURL)
        commands.append(contentsOf: consumeLegacyDefaults(defaults))
        let sorted = commands
            .filter { isValid($0, now: now) }
            .sorted { lhs, rhs in
                if lhs.issuedAt == rhs.issuedAt {
                    return lhs.action.rawValue < rhs.action.rawValue
                }
                return lhs.issuedAt < rhs.issuedAt
            }
        let overflowCount = max(0, sorted.count - maximumQueuedCommands)
        for command in sorted.prefix(overflowCount) {
            acknowledge(command, queueDirectoryURL: queueDirectoryURL)
        }
        return Array(sorted.suffix(maximumQueuedCommands))
    }

    private static func defaultQueueDirectoryURL() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent(queueDirectoryName, isDirectory: true)
    }

    private static func consumeLegacyDefaults(_ defaults: UserDefaults?) -> [AtriaPendingLiveWorkoutAction] {
        guard let defaults,
              let data = defaults.data(forKey: key) else { return [] }
        // Remove before decoding so malformed or stale migration data cannot
        // replay forever. New extension versions never write this blob.
        defaults.removeObject(forKey: key)
        let decoder = JSONDecoder()
        return (try? decoder.decode([AtriaPendingLiveWorkoutAction].self, from: data))
            ?? (try? decoder.decode(AtriaPendingLiveWorkoutAction.self, from: data)).map { [$0] }
            ?? []
    }

    private static func consumeClaimedFiles(now: Date,
                                            queueDirectoryURL: URL?) -> [AtriaPendingLiveWorkoutAction] {
        guard let queueDirectoryURL else { return [] }
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(
            at: queueDirectoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let consumerID = UUID().uuidString
        var commands: [AtriaPendingLiveWorkoutAction] = []
        for sourceURL in files where sourceURL.pathExtension == "json" {
            let name = sourceURL.lastPathComponent
            let isPending = name.hasPrefix(pendingFilePrefix)
            let isAbandonedClaim: Bool
            if name.hasPrefix(claimedFilePrefix),
               let modifiedAt = try? sourceURL.resourceValues(
                   forKeys: [.contentModificationDateKey]
               ).contentModificationDate {
                isAbandonedClaim = now.timeIntervalSince(modifiedAt) >= abandonedClaimAge
            } else {
                isAbandonedClaim = false
            }
            guard isPending || isAbandonedClaim else { continue }

            // A same-volume rename is the claim operation. If another app
            // activation already won it, `moveItem` fails and this consumer
            // simply skips the command.
            let claimedURL = queueDirectoryURL.appendingPathComponent(
                "\(claimedFilePrefix)\(consumerID)-\(UUID().uuidString).json"
            )
            do {
                try manager.moveItem(at: sourceURL, to: claimedURL)
                try? manager.setAttributes([.modificationDate: now],
                                           ofItemAtPath: claimedURL.path)
            } catch {
                continue
            }

            guard let data = try? Data(contentsOf: claimedURL),
                  var command = try? JSONDecoder().decode(
                      AtriaPendingLiveWorkoutAction.self,
                      from: data
                  ) else {
                // Malformed files can never be applied, so acknowledging them
                // now is safe and prevents a permanent launch poison pill.
                try? manager.removeItem(at: claimedURL)
                continue
            }
            guard isValid(command, now: now) else {
                // Expired and impossible-future actions are intentionally
                // rejected before they can affect any workout.
                try? manager.removeItem(at: claimedURL)
                continue
            }
            command.claimReceipt = claimedURL.lastPathComponent
            commands.append(command)
        }
        return commands
    }

    /// Acknowledge only after the canonical workout owner has durably applied
    /// (or safely rejected) the command. Until then the claimed file remains
    /// available for replay after the short abandoned-claim lease.
    static func acknowledge(_ command: AtriaPendingLiveWorkoutAction) {
        acknowledge(command, queueDirectoryURL: defaultQueueDirectoryURL())
    }

    static func acknowledge(_ command: AtriaPendingLiveWorkoutAction,
                            queueDirectoryURL: URL?) {
        guard let fileURL = claimedFileURL(for: command,
                                           queueDirectoryURL: queueDirectoryURL) else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Session restoration may briefly run after scene activation. Release a
    /// claim back to pending rather than losing the command or waiting for the
    /// abandoned-claim lease before the restored session can consume it.
    static func release(_ command: AtriaPendingLiveWorkoutAction) {
        release(command, queueDirectoryURL: defaultQueueDirectoryURL())
    }

    static func release(_ command: AtriaPendingLiveWorkoutAction,
                        queueDirectoryURL: URL?) {
        guard let sourceURL = claimedFileURL(for: command,
                                             queueDirectoryURL: queueDirectoryURL),
              let queueDirectoryURL else { return }
        let pendingURL = queueDirectoryURL.appendingPathComponent(
            "\(pendingFilePrefix)\(UUID().uuidString).json"
        )
        try? FileManager.default.moveItem(at: sourceURL, to: pendingURL)
    }

    private static func claimedFileURL(for command: AtriaPendingLiveWorkoutAction,
                                       queueDirectoryURL: URL?) -> URL? {
        guard let queueDirectoryURL,
              let receipt = command.claimReceipt,
              receipt == URL(fileURLWithPath: receipt).lastPathComponent,
              receipt.hasPrefix(claimedFilePrefix),
              receipt.hasSuffix(".json") else { return nil }
        return queueDirectoryURL.appendingPathComponent(receipt)
    }

    private static func isValid(_ command: AtriaPendingLiveWorkoutAction,
                                now: Date) -> Bool {
        command.issuedAt <= now.addingTimeInterval(futureClockTolerance)
            && now.timeIntervalSince(command.issuedAt) <= maximumCommandAge
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
        var activeEnergyKilocalories: Double? = nil
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
                                                 activeEnergyKilocalories: snapshot.activeEnergyKilocalories,
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
        let now = Date()
        return Self.sensorStaleDate(heartRateCapturedAt: snapshot.heartRateCapturedAt,
                                    stepsCapturedAt: snapshot.stepsCapturedAt,
                                    fallback: now,
                                    heartRateAvailability: snapshot.heartRateAvailability,
                                    stepsAvailability: snapshot.stepsAvailability,
                                    sensorHasContact: snapshot.sensorHasContact)
    }

    /// ActivityKit has one activity-level stale deadline, while HR and motion
    /// have independent freshness windows. Ask the system to redraw at the
    /// first source expiry. The widget then evaluates each source clock on its
    /// own, so 15-second motion staleness cannot keep looking live until the
    /// 90-second HR deadline (or incorrectly make fresh HR stale).
    nonisolated static func sensorStaleDate(heartRateCapturedAt: Date?,
                                            stepsCapturedAt: Date?,
                                            fallback: Date = Date(),
                                            heartRateFreshnessWindow: TimeInterval = 90,
                                            stepFreshnessWindow: TimeInterval = 15,
                                            heartRateAvailability: AtriaLiveSensorAvailability? = nil,
                                            stepsAvailability: AtriaLiveSensorAvailability? = nil,
                                            sensorHasContact: Bool? = nil) -> Date {
        let heartRateExpiry = heartRateCapturedAt?.addingTimeInterval(heartRateFreshnessWindow)
        let stepsExpiry = stepsCapturedAt?.addingTimeInterval(stepFreshnessWindow)
        let hasExplicitSourceState = heartRateAvailability != nil
            || stepsAvailability != nil
            || sensorHasContact != nil
        let expiries = [
            (date: heartRateExpiry,
             canAdvance: sensorHasContact != false
                && (heartRateAvailability == nil || heartRateAvailability == .live)),
            (date: stepsExpiry,
             canAdvance: stepsAvailability == nil || stepsAvailability == .live)
        ].compactMap { source -> Date? in
            guard source.canAdvance,
                  let expiry = source.date,
                  expiry > fallback else { return nil }
            return expiry
        }
        if let nextExpiry = expiries.min() { return nextExpiry }
        // Legacy call sites without source state retain the historical fallback.
        // Production snapshots pass explicit availability, so a workout with no
        // live source becomes stale now instead of pretending to be fresh for 90s.
        return hasExplicitSourceState
            ? fallback
            : fallback.addingTimeInterval(heartRateFreshnessWindow)
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
            || (current.activeEnergyKilocalories == nil) != (previous.activeEnergyKilocalories == nil)
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
