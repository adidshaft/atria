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
        let heartRateExpiry = state.heartRateCapturedAt?.addingTimeInterval(15)
        let stepsExpiry = state.stepsCapturedAt?.addingTimeInterval(15)
        let batteryExpiry = state.batteryCapturedAt?.addingTimeInterval(10 * 60)
        let sourceExpiries = [
            (date: heartRateExpiry,
             canAdvance: state.sensorHasContact != false
                && (state.heartRateAvailability == nil || state.heartRateAvailability == .live)),
            (date: stepsExpiry,
             canAdvance: state.stepsAvailability == nil || state.stepsAvailability == .live),
            (date: batteryExpiry,
             canAdvance: state.batteryAvailability == nil || state.batteryAvailability == .live)
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

/// Home Screen widgets and Control Center can start idle Live when the app
/// itself cannot. `Activity.request` from a background scene after install
/// bounce fails with `ActivityAuthorizationError.visibility` (device 186).
/// Apple only allows a new Live Activity from the foreground, a
/// user-initiated `LiveActivityIntent`, or APNs push-to-start.
enum AtriaIdleLiveActivityStart {
    static let lastStartErrorKey = "atria.liveActivity.lastStartError"
    static let snapshotKey = "atria.widgetSnapshot.v1"
    static let appGroupID = "group.com.adidshaft.atria"
    static let liveHeartRateFreshness: TimeInterval = 15

    struct SnapshotPayload: Codable, Equatable, Sendable {
        var heartRate: Int?
        var heartRateCapturedAt: Date?
        var heartRateZoneIndex: Int?
        var heartRateZoneName: String?
        var strain: Double?
        var batteryLevel: Int?
        var batteryCapturedAt: Date?
        var batteryChargeCapturedAt: Date?
        var batteryChargeStatus: String?
        var batteryChargeText: String?
        var steps: Int?
        var stepsAreEstimated: Bool?
        var stepsCapturedAt: Date?
        var dailyStepGoal: Int?
    }

    enum Outcome: Equatable, Sendable {
        case skipped
        case started
        case failed(String)
    }

    nonisolated static func shouldRequest(
        existingCount: Int,
        activitiesEnabled: Bool,
        heartRate: Int
    ) -> Bool {
        activitiesEnabled && existingCount == 0 && heartRate > 0
    }

    nonisolated static func decodePayload(from data: Data) -> SnapshotPayload? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let payload = try? decoder.decode(SnapshotPayload.self, from: data) {
            return payload
        }
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: string) {
                return date
            }
            let whole = ISO8601DateFormatter()
            whole.formatOptions = [.withInternetDateTime]
            if let date = whole.date(from: string) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unrecognized ISO-8601 date \(string)"
            )
        }
        return try? decoder.decode(SnapshotPayload.self, from: data)
    }

    nonisolated static func loadPayload(
        defaults: UserDefaults? = UserDefaults(suiteName: appGroupID)
    ) -> SnapshotPayload? {
        guard let data = defaults?.data(forKey: snapshotKey) else { return nil }
        return decodePayload(from: data)
    }

    nonisolated static func contentState(
        from payload: SnapshotPayload,
        now: Date
    ) -> AtriaLiveActivityAttributes.ContentState {
        let heartRate = max(0, payload.heartRate ?? 0)
        let heartRateAvailability = liveAvailability(
            capturedAt: payload.heartRateCapturedAt,
            now: now,
            freshness: liveHeartRateFreshness,
            hasValue: heartRate > 0
        )
        let batteryLevel = payload.batteryLevel ?? -1
        let batteryAvailability = liveAvailability(
            capturedAt: payload.batteryCapturedAt,
            now: now,
            freshness: 10 * 60,
            hasValue: batteryLevel >= 0
        )
        return AtriaLiveActivityAttributes.ContentState(
            heartRate: heartRate,
            strain: payload.strain ?? 0,
            batteryLevel: batteryLevel,
            batteryChargeStatus: payload.batteryChargeStatus ?? "unknown",
            batteryChargeText: payload.batteryChargeText ?? "",
            batteryCapturedAt: payload.batteryCapturedAt,
            batteryChargeCapturedAt: payload.batteryChargeCapturedAt,
            batteryAvailability: batteryAvailability,
            readingCount: 0,
            updatedAt: now,
            heartRateCapturedAt: payload.heartRateCapturedAt,
            sensorHasContact: heartRate > 0,
            heartRateAvailability: heartRateAvailability,
            activityName: "Live",
            activitySystemImage: "heart.fill",
            heartRateZoneIndex: payload.heartRateZoneIndex,
            heartRateZoneName: payload.heartRateZoneName,
            dailySteps: payload.steps,
            dailyStepsAreEstimated: payload.stepsAreEstimated,
            dailyStepsCapturedAt: payload.stepsCapturedAt,
            dailyStepGoal: payload.dailyStepGoal,
            isPaused: false,
            isEnding: false,
            elapsedDuration: 0,
            showsWorkoutControls: false
        )
    }

    nonisolated static func staleDate(
        heartRateCapturedAt: Date?,
        now: Date
    ) -> Date {
        heartRateCapturedAt?.addingTimeInterval(liveHeartRateFreshness) ?? now.addingTimeInterval(liveHeartRateFreshness)
    }

    nonisolated static func startIfNeeded(
        existingCount: Int,
        activitiesEnabled: Bool,
        payload: SnapshotPayload?,
        now: Date = Date(),
        request: (AtriaLiveActivityAttributes, AtriaLiveActivityAttributes.ContentState, Date) throws -> Void
    ) -> Outcome {
        let heartRate = payload?.heartRate ?? 0
        guard shouldRequest(
            existingCount: existingCount,
            activitiesEnabled: activitiesEnabled,
            heartRate: heartRate
        ) else {
            return .skipped
        }
        guard let payload else { return .failed("missing_widget_snapshot") }
        let attributes = AtriaLiveActivityAttributes(startedAt: now)
        let state = contentState(from: payload, now: now)
        let staleAt = staleDate(heartRateCapturedAt: payload.heartRateCapturedAt, now: now)
        do {
            try request(attributes, state, staleAt)
            return .started
        } catch {
            return .failed(String(describing: error))
        }
    }

    private nonisolated static func liveAvailability(
        capturedAt: Date?,
        now: Date,
        freshness: TimeInterval,
        hasValue: Bool
    ) -> AtriaLiveSensorAvailability {
        guard hasValue else { return .unavailable }
        guard let capturedAt, capturedAt <= now.addingTimeInterval(5) else {
            return hasValue ? .stale : .unavailable
        }
        return now.timeIntervalSince(capturedAt) <= freshness ? .live : .stale
    }
}

/// User-initiated start for idle Live. Apple runs this in the Atria process,
/// so `Activity.request` is allowed without bringing Today to the front.
struct AtriaStartIdleLiveActivityIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Show Atria Live"
    static let description = IntentDescription(
        "Show live heart rate on the Lock Screen and Dynamic Island."
    )
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        let outcome = AtriaIdleLiveActivityStart.startIfNeeded(
            existingCount: Activity<AtriaLiveActivityAttributes>.activities.count,
            activitiesEnabled: ActivityAuthorizationInfo().areActivitiesEnabled,
            payload: AtriaIdleLiveActivityStart.loadPayload()
        ) { attributes, state, staleAt in
            _ = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: staleAt),
                pushType: nil
            )
        }
        let defaults = UserDefaults.standard
        switch outcome {
        case .started:
            defaults.removeObject(forKey: AtriaIdleLiveActivityStart.lastStartErrorKey)
        case .failed(let message):
            defaults.set(message, forKey: AtriaIdleLiveActivityStart.lastStartErrorKey)
        case .skipped:
            break
        }
        return .result()
    }
}
