import AppIntents
import ActivityKit
import Foundation

enum AtriaControlCaptureCommand: String, AppEnum, Codable {
    case start
    case stop

    static var typeDisplayName: LocalizedStringResource { "Atria capture command" }
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Atria capture command"

    static var caseDisplayRepresentations: [Self: DisplayRepresentation] {
        [
            .start: "Start",
            .stop: "Stop"
        ]
    }
}

enum AtriaControlIntentCommand: Codable, Equatable {
    case capture(AtriaControlCaptureCommand)
}

enum AtriaControlIntentCommandStore {
    private static let key = "atria.intent.pendingCommand.v1"
    private static let appGroupID = "group.com.adidshaft.atria"

    static func save(_ command: AtriaControlIntentCommand) {
        guard let data = try? JSONEncoder().encode(command) else { return }
        UserDefaults(suiteName: appGroupID)?.set(data, forKey: key)
    }
}

struct AtriaControlCaptureIntent: AppIntent {
    static let title: LocalizedStringResource = "Control Atria capture"
    static let description = IntentDescription("Ask Atria to start or stop local capture.")
    static let openAppWhenRun = true

    @Parameter(title: "Command")
    var command: AtriaControlCaptureCommand

    init() {
        command = .start
    }

    init(command: AtriaControlCaptureCommand) {
        self.command = command
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        AtriaControlIntentCommandStore.save(.capture(command))
        return .result(dialog: "\(command.dialogVerb) Atria capture.")
    }
}

private extension AtriaControlCaptureCommand {
    var dialogVerb: String {
        switch self {
        case .start: return "Starting"
        case .stop: return "Stopping"
        }
    }
}

enum AtriaLiveWorkoutControlCommand: String, AppEnum, Codable {
    case pause
    case resume
    case end

    static var typeDisplayName: LocalizedStringResource { "Workout action" }
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Workout action"

    static var caseDisplayRepresentations: [Self: DisplayRepresentation] {
        [
            .pause: "Pause",
            .resume: "Resume",
            .end: "End"
        ]
    }
}

private struct AtriaWidgetPendingWorkoutAction: Codable {
    let action: AtriaLiveWorkoutControlCommand
    let workoutStartedAt: Date
    let issuedAt: Date
}

private enum AtriaWidgetWorkoutActionStore {
    static let key = "atria.liveWorkout.pendingAction.v1"
    static let appGroupID = "group.com.adidshaft.atria"
    static let maximumQueuedCommands = 16

    static func save(_ action: AtriaLiveWorkoutControlCommand,
                     workoutStartedAt: Date,
                     issuedAt: Date) throws {
        guard let defaults = UserDefaults(suiteName: appGroupID) else {
            throw AtriaWidgetWorkoutActionError.sharedContainerUnavailable
        }
        let pending = AtriaWidgetPendingWorkoutAction(action: action,
                                                      workoutStartedAt: workoutStartedAt,
                                                      issuedAt: issuedAt)
        let decoder = JSONDecoder()
        let existing: [AtriaWidgetPendingWorkoutAction]
        if let data = defaults.data(forKey: key) {
            existing = (try? decoder.decode([AtriaWidgetPendingWorkoutAction].self, from: data))
                ?? (try? decoder.decode(AtriaWidgetPendingWorkoutAction.self, from: data)).map { [$0] }
                ?? []
        } else {
            existing = []
        }
        // App wake-up is not instantaneous. Preserve a short burst such as
        // Pause -> Resume or Pause -> End instead of allowing the latest tap to
        // overwrite the interval-defining command. The cap bounds defaults IO
        // if the app cannot launch for an extended period.
        let queued = Array((existing + [pending]).suffix(maximumQueuedCommands))
        defaults.set(try JSONEncoder().encode(queued), forKey: key)
    }
}

private enum AtriaWidgetWorkoutActionError: Error {
    case sharedContainerUnavailable
}

/// An interactive Live Activity action. `openAppWhenRun` deliberately routes
/// execution through the app's canonical workout owner; the extension also
/// updates the archived activity immediately so a tap has honest feedback
/// while the app scene wakes. The started-at token makes stale controls safe.
struct AtriaLiveWorkoutControlIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Control workout"
    static let description = IntentDescription("Pause, resume, or safely end the active Atria workout.")
    static let openAppWhenRun = true

    @Parameter(title: "Action")
    var action: AtriaLiveWorkoutControlCommand

    @Parameter(title: "Workout start")
    var workoutStartedAt: Date

    init() {
        action = .pause
        workoutStartedAt = .now
    }

    init(action: AtriaLiveWorkoutControlCommand, workoutStartedAt: Date) {
        self.action = action
        self.workoutStartedAt = workoutStartedAt
    }

    func perform() async throws -> some IntentResult {
        let now = Date()
        try AtriaWidgetWorkoutActionStore.save(action,
                                               workoutStartedAt: workoutStartedAt,
                                               issuedAt: now)
        await updateMatchingLiveActivity(now: now)
        return .result()
    }

    private func updateMatchingLiveActivity(now: Date) async {
        guard let activity = Activity<AtriaLiveActivityAttributes>.activities.first(where: {
            abs($0.attributes.startedAt.timeIntervalSince(workoutStartedAt)) <= 1
        }) else { return }

        var state = activity.content.state
        let elapsed: TimeInterval
        if state.isPaused ?? false {
            elapsed = max(0,
                          state.elapsedDuration
                          ?? state.updatedAt.timeIntervalSince(state.timerAnchor ?? activity.attributes.startedAt))
        } else {
            // `elapsedDuration` is only a snapshot; an active timer has kept
            // moving since that update, so derive the exact tap-time value
            // from its adjusted anchor instead of freezing several seconds low.
            elapsed = max(0,
                          now.timeIntervalSince(state.timerAnchor ?? activity.attributes.startedAt))
        }
        switch action {
        case .pause:
            state.isPaused = true
            state.isEnding = false
            state.elapsedDuration = elapsed
            state.timerAnchor = now.addingTimeInterval(-elapsed)
        case .resume:
            state.isPaused = false
            state.isEnding = false
            state.elapsedDuration = elapsed
            state.timerAnchor = now.addingTimeInterval(-elapsed)
        case .end:
            // Final confirmation and dismissal remain owned by the app so the
            // exact saved HR window is durable before the activity disappears.
            state.isPaused = true
            state.isEnding = true
            state.elapsedDuration = elapsed
            state.timerAnchor = now.addingTimeInterval(-elapsed)
        }
        state.updatedAt = now
        // Pause/end feedback must preserve the independent HR and motion
        // freshness clocks. A fresh step stream should keep the activity
        // current without re-stamping old heart rate.
        let latestSensorAt = [state.heartRateCapturedAt, state.stepsCapturedAt]
            .compactMap { $0 }
            .max() ?? now
        let staleDate = latestSensorAt.addingTimeInterval(90)
        await activity.update(ActivityContent(state: state,
                                              staleDate: staleDate))
    }
}
