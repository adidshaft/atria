import AppIntents
import ActivityKit
import Foundation

enum AtriaLiveWorkoutControlCommand: String, AppEnum, Codable, Sendable {
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

/// The exact state that was durably committed by the app's canonical workout
/// owner. ActivityKit is allowed to render only one of these acknowledgements;
/// a missing acknowledgement leaves the queued command available for replay.
struct AtriaLiveWorkoutCanonicalCommandState: Sendable, Equatable {
    let isPaused: Bool
    let isEnding: Bool
    let elapsedDuration: TimeInterval
    let appliedAt: Date
}

/// Target-neutral dependency used by the shared Live Activity intent. Apple
/// executes `LiveActivityIntent` in the main app process, where AtriaApp
/// registers the root-owned runtime. The inert default is deliberately
/// fail-closed for previews/metadata extraction and never fabricates success.
struct AtriaLiveWorkoutCommandHandler: Sendable {
    typealias Apply = @MainActor @Sendable (
        AtriaLiveWorkoutControlCommand,
        Date,
        Date
    ) async -> AtriaLiveWorkoutCanonicalCommandState?

    let apply: Apply

    static let unavailable = Self { _, _, _ in nil }
}

private struct AtriaWidgetPendingWorkoutAction: Codable {
    let action: AtriaLiveWorkoutControlCommand
    let workoutStartedAt: Date
    let issuedAt: Date
}

private enum AtriaWidgetWorkoutActionStore {
    static let appGroupID = "group.com.adidshaft.atria"
    static let queueDirectoryName = "AtriaLiveWorkoutActions-v2"
    static let pendingFilePrefix = "pending-"

    static func save(_ action: AtriaLiveWorkoutControlCommand,
                     workoutStartedAt: Date,
                     issuedAt: Date) throws {
        let manager = FileManager.default
        guard let containerURL = manager.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else {
            throw AtriaWidgetWorkoutActionError.sharedContainerUnavailable
        }
        let directoryURL = containerURL.appendingPathComponent(queueDirectoryName,
                                                                isDirectory: true)
        do {
            try manager.createDirectory(at: directoryURL,
                                        withIntermediateDirectories: true,
                                        attributes: [.protectionKey: FileProtectionType.none])
        } catch {
            throw AtriaWidgetWorkoutActionError.commandWriteFailed
        }
        let pending = AtriaWidgetPendingWorkoutAction(action: action,
                                                      workoutStartedAt: workoutStartedAt,
                                                      issuedAt: issuedAt)
        let fileURL = directoryURL.appendingPathComponent(
            "\(pendingFilePrefix)\(UUID().uuidString).json"
        )
        do {
            // One atomically replaced, protection-free file per tap is the
            // crash fallback as well as the cross-process acknowledgement path.
            try JSONEncoder().encode(pending).write(to: fileURL, options: .atomic)
            try manager.setAttributes([.protectionKey: FileProtectionType.none],
                                      ofItemAtPath: fileURL.path)
        } catch {
            try? manager.removeItem(at: fileURL)
            throw AtriaWidgetWorkoutActionError.commandWriteFailed
        }
    }
}

private enum AtriaWidgetWorkoutActionError: Error {
    case sharedContainerUnavailable
    case commandWriteFailed
}

/// Interactive Lock Screen control executed in the main Atria process. The
/// queue write happens first, the root runtime applies and persists canonical
/// workout/route state second, and only then may ActivityKit show the result.
struct AtriaLiveWorkoutControlIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Control workout"
    static let description = IntentDescription("Pause, resume, or safely end the active Atria workout.")

    @Dependency(default: AtriaLiveWorkoutCommandHandler.unavailable)
    private var commandHandler: AtriaLiveWorkoutCommandHandler

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
        let issuedAt = Date()
        try AtriaWidgetWorkoutActionStore.save(action,
                                               workoutStartedAt: workoutStartedAt,
                                               issuedAt: issuedAt)
        guard let canonicalState = await commandHandler.apply(
            action,
            workoutStartedAt,
            issuedAt
        ) else {
            // Do not optimistically lie on the Lock Screen. The durable queue
            // remains available for the root runtime's next launch checkpoint.
            return .result()
        }
        await updateMatchingLiveActivity(canonicalState)
        return .result()
    }

    private func updateMatchingLiveActivity(
        _ canonicalState: AtriaLiveWorkoutCanonicalCommandState
    ) async {
        guard let activity = Activity<AtriaLiveActivityAttributes>.activities.first(where: {
            abs($0.attributes.startedAt.timeIntervalSince(workoutStartedAt)) <= 1
        }) else { return }

        var state = activity.content.state
        state.isPaused = canonicalState.isPaused
        state.isEnding = canonicalState.isEnding
        state.elapsedDuration = canonicalState.elapsedDuration
        state.timerAnchor = canonicalState.appliedAt.addingTimeInterval(
            -canonicalState.elapsedDuration
        )
        state.updatedAt = canonicalState.appliedAt

        // Preserve independent source freshness. A control tap must never make
        // stale pulse or motion evidence look newly sampled.
        let heartRateExpiry = state.heartRateCapturedAt?.addingTimeInterval(90)
        let stepsExpiry = state.stepsCapturedAt?.addingTimeInterval(15)
        let sourceExpiries = [
            (date: heartRateExpiry,
             canAdvance: state.sensorHasContact != false
                && (state.heartRateAvailability == nil || state.heartRateAvailability == .live)),
            (date: stepsExpiry,
             canAdvance: state.stepsAvailability == nil || state.stepsAvailability == .live)
        ].compactMap { source -> Date? in
            guard source.canAdvance,
                  let expiry = source.date,
                  expiry > canonicalState.appliedAt else { return nil }
            return expiry
        }
        let staleDate = sourceExpiries.min()
            ?? canonicalState.appliedAt
        await activity.update(ActivityContent(state: state,
                                              staleDate: staleDate))
    }
}
