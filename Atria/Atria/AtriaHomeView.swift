import SwiftUI
import Combine
import UniformTypeIdentifiers
import UIKit

/// Makes workout control deadlines real rather than advisory. Cancelling a
/// task that is awaiting a FIFO motion marker does not itself resume that
/// await, so the old "sleep, then cancel" pattern could still hold Start/End
/// until the detector queue eventually reached the marker. This main-actor
/// gate resumes the UI at the deadline while the cancelled marker task remains
/// responsible for releasing any boundary it eventually acquires.
@MainActor
private final class AtriaWorkoutMotionBoundaryDeadline {
    private var continuation: CheckedContinuation<Date?, Never>?

    func install(_ continuation: CheckedContinuation<Date?, Never>) {
        precondition(self.continuation == nil)
        self.continuation = continuation
    }

    func finish(_ value: Date?) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: value)
    }
}

/// The Start control has a real interaction deadline too.  A workout cannot
/// be shown until its crash-recovery intent has been read and the strap-step
/// ledger has hydrated, but a blocked file queue must never leave the Start
/// button spinning indefinitely.  The late I/O is allowed to finish and warm
/// the next attempt; it cannot create or alter an intent after this gate has
/// already returned failure.
@MainActor
private final class AtriaWorkoutStartAuthorityDeadline {
    private var continuation: CheckedContinuation<Bool, Never>?

    func install(_ continuation: CheckedContinuation<Bool, Never>) {
        precondition(self.continuation == nil)
        self.continuation = continuation
    }

    func finish(_ value: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: value)
    }
}

/// Owns the short route-checkpoint assertion by reference so UIKit's
/// expiration callback never captures a transient SwiftUI value. Expiration
/// ends the assertion synchronously; suspension cannot strand a late Task.
@MainActor
private final class AtriaWorkoutRouteBackgroundLease {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    func begin() {
        end()
        identifier = UIApplication.shared.beginBackgroundTask(
            withName: "Atria workout route checkpoint"
        ) { [weak self] in
            MainActor.assumeIsolated {
                self?.end()
            }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}

/// A deliberately tiny first frame for a Start tap whose durable intent is
/// still being committed. It avoids presenting a fake live workout while
/// making a busy disk/serial queue visibly distinct from an ignored tap.
private struct AtriaSecuringWorkoutStartView: View {
    var body: some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large)
            Text("Securing workout…").font(.title3.weight(.semibold))
            Text("Saving your start safely")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Securing workout start")
    }
}

/// Settings presentation must not be owned by `AtriaHomeView`'s value state.
/// Toggling a root `@State` rebuilt the complete Home/TabView hierarchy before
/// SwiftUI could present the sheet, which made the gear appear to freeze while
/// live BLE updates were arriving. The Home view retains this coordinator by
/// identity but does not observe it; only the tiny host below observes changes.
@MainActor
private final class AtriaSettingsPresentationCoordinator: ObservableObject {
    @Published var isPresented = false
}

/// Only settings-owned inputs participate in parent reconciliation. The Home
/// shell receives pulse, step, strain and connection publishes continuously;
/// none of those should rebuild a presented Settings hierarchy.
private struct AtriaSettingsPresentationRevision: Equatable {
    let profile: AthleteProfile
    let restingBaseline: Int?
    let dailyRollupCount: Int
    let latestRollupDay: Date?
    let latestRollupRecovery: Int?
    let strapName: String
    let strapModel: String
    let strapGenerationDetail: String
    let strapFirmware: String
    let hapticSettings: AtriaHapticAlertSettings
    let heartRateBroadcastEnabled: Bool
    let batterySaverEnabled: Bool
    let aiCoachSettings: AtriaAICoachSettings
    let aiCoachHasAPIKey: Bool
    let maxHRSuggestion: AtriaMaxHRSuggestion?
    let developerModeEnabled: Bool
}

private struct AtriaSettingsPresentationHost: View, Equatable {
    @ObservedObject var coordinator: AtriaSettingsPresentationCoordinator
    let revision: AtriaSettingsPresentationRevision
    private let content: () -> AnyView

    init(coordinator: AtriaSettingsPresentationCoordinator,
         revision: AtriaSettingsPresentationRevision,
         content: @escaping () -> AnyView) {
        self.coordinator = coordinator
        self.revision = revision
        self.content = content
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.coordinator === rhs.coordinator && lhs.revision == rhs.revision
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .sheet(isPresented: $coordinator.isPresented) {
                AtriaDeferredSettingsSheet(content: content)
            }
    }
}

/// The presentation transaction gets one deliberately cheap frame before the
/// full Settings graph is requested. This keeps the gear responsive even when
/// live BLE/defaults publications are already occupying the main run loop.
/// Type erasure also prevents the large Settings body's generic metadata from
/// becoming part of the Home sheet host's first-frame type graph.
private struct AtriaDeferredSettingsSheet: View {
    let content: () -> AnyView

    @Environment(\.dismiss) private var dismiss
    @State private var isContentReady = false

    var body: some View {
        Group {
            if isContentReady {
                content()
            } else {
                NavigationStack {
                    ProgressView()
                        .controlSize(.small)
                        .navigationTitle("Settings")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Close") { dismiss() }
                                    .font(.body.weight(.semibold))
                            }
                        }
                }
            }
        }
        .task {
            guard !isContentReady else { return }
            // Sleeping across a display refresh, instead of mutating from
            // onAppear, lets the sheet commit and accept gestures first.
            try? await Task.sleep(for: .milliseconds(34))
            guard !Task.isCancelled else { return }
            isContentReady = true
        }
    }
}

struct AtriaHomeContainer: View, Equatable {
    let ble: AtriaBLEManager
    let store: SessionStore
    let workoutRouteRecorder: AtriaWorkoutRouteRecorder

    static func == (lhs: AtriaHomeContainer, rhs: AtriaHomeContainer) -> Bool {
        ObjectIdentifier(lhs.ble) == ObjectIdentifier(rhs.ble)
            && ObjectIdentifier(lhs.store) == ObjectIdentifier(rhs.store)
            && ObjectIdentifier(lhs.workoutRouteRecorder)
                == ObjectIdentifier(rhs.workoutRouteRecorder)
    }

    var body: some View {
        AtriaHomeView(ble: ble,
                      store: store,
                      workoutRouteRecorder: workoutRouteRecorder)
    }
}

fileprivate struct AtriaWorkoutDetectionPrompt: Equatable {
    let heartRate: Int
    let strain: Double
    let samples: Int
    let bpmOverRest: Int
    let restingHeartRate: Int
    let maxHeartRate: Int
    let motionSuggestedActivityType: AtriaWorkoutActivityType?

    init(heartRate: Int,
         strain: Double,
         samples: Int,
         bpmOverRest: Int,
         restingHeartRate: Int,
         maxHeartRate: Int,
         motionSuggestedActivityType: AtriaWorkoutActivityType? = nil) {
        self.heartRate = heartRate
        self.strain = strain
        self.samples = samples
        self.bpmOverRest = bpmOverRest
        self.restingHeartRate = restingHeartRate
        self.maxHeartRate = maxHeartRate
        self.motionSuggestedActivityType = motionSuggestedActivityType
    }

    var heartRateZone: Metrics.HeartRateZone? {
        Metrics.heartRateZone(bpm: heartRate, rest: restingHeartRate, max: maxHeartRate)
    }

    var confidenceLabel: String {
        if isReviewReady {
            return "Ready"
        }
        switch samples {
        case 720...:
            return "Strong signal"
        case 360...:
            return "Likely"
        default:
            return "Possible"
        }
    }

    var progressFraction: Double {
        min(max(Double(samples) / 720.0, 0.18), 1)
    }

    var evidenceMinutes: Int {
        max(1, Int((Double(samples) / 60.0).rounded()))
    }

    var reviewHint: String {
        isReviewReady ? "Review now" : "Keep wearing"
    }

    var isReviewReady: Bool {
        samples >= AtriaWorkoutPromptEvaluator.minimumContinuousElevatedSamples
            && bpmOverRest >= AtriaWorkoutPromptEvaluator.minimumBPMOverRest
    }

    var primaryTitle: String {
        isReviewReady ? "Review workout" : "Keep watching"
    }

    var headline: String {
        isReviewReady ? "Review this workout" : "Watching effort"
    }

    var subtitle: String {
        // Give the user something to judge WITH (2026-08-05 feedback: the
        // card showed neither when nor what, "which makes it very difficult
        // for user to guess"). Start time is derived from the contiguous
        // elevated-sample count, so it is approximate — say so with "≈".
        guard isReviewReady else {
            return "Atria is waiting for a steadier strap rise."
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        let approximateStart = formatter.string(
            from: Date().addingTimeInterval(-Double(samples))
        )
        var parts = ["Since ≈\(approximateStart)", "\(evidenceMinutes) min elevated"]
        if let motionSuggestedActivityType {
            parts.append("looks like \(motionSuggestedActivityType.rawValue.lowercased())")
        }
        return parts.joined(separator: " · ")
    }

    var typeSuggestions: [String] {
        if let motionSuggestedActivityType {
            return [motionSuggestedActivityType.rawValue, AtriaWorkoutActivityType.other.rawValue]
        }
        return [AtriaWorkoutActivityType.other.rawValue]
    }

    var exerciseSuggestions: [String] {
        []
    }

    var suggestedActivityType: AtriaWorkoutActivityType {
        // Heart rate establishes exertion, not the kind of movement. Default
        // to an explicit abstention until time-aligned motion evidence exists.
        motionSuggestedActivityType ?? .other
    }

    var suggestedActivityTypes: [AtriaWorkoutActivityType] {
        var resolved: [AtriaWorkoutActivityType] = []
        for suggestion in typeSuggestions {
            guard let type = AtriaWorkoutActivityType(suggestion: suggestion),
                  !resolved.contains(type) else { continue }
            resolved.append(type)
        }
        if !resolved.contains(suggestedActivityType) {
            resolved.insert(suggestedActivityType, at: 0)
        }
        return Array(resolved.prefix(3))
    }
}

fileprivate struct AtriaWorkoutReviewDraft: Identifiable, Equatable {
    let id = UUID()
    let prompt: AtriaWorkoutDetectionPrompt
    let suggestedStart: Date
    let suggestedEnd: Date
    var strengthSets: [LoggedSet] = []
    var strengthHistory: StrengthHistoryProjection = .empty

    static func == (lhs: AtriaWorkoutReviewDraft, rhs: AtriaWorkoutReviewDraft) -> Bool {
        lhs.id == rhs.id
            && lhs.prompt == rhs.prompt
            && lhs.suggestedStart == rhs.suggestedStart
            && lhs.suggestedEnd == rhs.suggestedEnd
            && lhs.strengthSets == rhs.strengthSets
            && lhs.strengthHistory == rhs.strengthHistory
    }
}

fileprivate struct AtriaWorkoutReviewResult: Equatable {
    let start: Date
    let end: Date
    let activityType: String
    let activitySubtype: String?
    let exerciseNames: [String]
    let strengthSets: [LoggedSet]
}

fileprivate enum AtriaWorkoutReviewStep: Int, CaseIterable {
    case time
    case type
    case exercises
    case summary

    var title: String {
        switch self {
        case .time: return "Time"
        case .type: return "Type"
        case .exercises: return "Exercises"
        case .summary: return "Save"
        }
    }
}

fileprivate struct AtriaConnectionDiagnosisLiveTrigger: Equatable {
    let status: AtriaBLEManager.Status
    let bluetoothPermissionDenied: Bool
    let batteryLevel: Int
    let batteryIsCharging: Bool
    let batteryRecentlyDropping: Bool
    let rrContinuityState: String
    let hasRecentHeartRateSample: Bool
    let officialAppCoexistenceRisk: AtriaBLEManager.OfficialAppCoexistenceRisk
    let lastScanRequestedAt: Date?
    let lastScanMatchAt: Date?
    let pendingKnownReconnectStartedAt: Date?
    let rangeLossBackfillPending: Bool

    init(_ state: AtriaHomeModel.CoreLiveState) {
        status = state.status
        bluetoothPermissionDenied = state.bluetoothPermissionDenied
        batteryLevel = state.batteryLevel
        batteryIsCharging = state.batteryIsCharging
        batteryRecentlyDropping = state.batteryRecentlyDropping
        rrContinuityState = state.rrContinuityState
        hasRecentHeartRateSample = state.hasRecentHeartRateSample
        officialAppCoexistenceRisk = state.officialAppCoexistenceRisk
        lastScanRequestedAt = state.lastScanRequestedAt
        lastScanMatchAt = state.lastScanMatchAt
        pendingKnownReconnectStartedAt = state.pendingKnownReconnectStartedAt
        rangeLossBackfillPending = state.rangeLossBackfillPending
    }
}

fileprivate struct AtriaConnectionDiagnosisPulseTrigger: Equatable {
    let hasPulseSignal: Bool
    let sensorHasContact: Bool

    init(_ state: AtriaHomeModel.PulseLiveState) {
        hasPulseSignal = state.hasPulseSignal
        sensorHasContact = state.sensorHasContact
    }
}

#if DEBUG
private enum AtriaScreenshotShowcase {
    struct HomeModelSnapshot {
        let status: AtriaHomeModel.StatusState
        let coreLive: AtriaHomeModel.CoreLiveState
        let heroPulse: AtriaHomeModel.HeroPulseState
        let pulseLive: AtriaHomeModel.PulseLiveState
        let pulseSparkline: AtriaHomeModel.PulseSparklineState
        let collectionLive: AtriaHomeModel.CollectionLiveState
        let hero: AtriaHomeModel.HeroSnapshot
        let snapshot: AtriaHomeModel.Snapshot
        let homeStats: AtriaHomeModel.HomeStatsState
    }

    static var isActive: Bool {
        ProcessInfo.processInfo.arguments.contains("live-zone")
    }
    static func homeModelSnapshot() -> HomeModelSnapshot? { nil }
}
#endif

private struct AtriaSleepReviewSheetRoute: Identifiable {
    let id = UUID()
    let night: SleepHistorySnapshot.Night?
}

/// Qualification gate for the daily share card.
///
/// A lower-bound strain (for example, "≥ 4.2" from partial-day wear) is still
/// useful evidence and remains visible as text, but it must not receive a full
/// progress fill, target marker, or target-zone colour. Those decorations
/// imply that the complete physiological day was observed.
enum AtriaDailyShareMetricTruth {
    static func strainIsQualified(value: String,
                                  confidence: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !AtriaCompactMetricPresentation.isPendingValue(trimmed) else {
            return false
        }
        return !trimmed.hasPrefix("≥")
            && !confidence.localizedCaseInsensitiveContains("partial")
    }
}

struct AtriaHomeView: View {
    private static let connectionDiagnosisPersistenceDelay: TimeInterval = 15
    private static let strainTargetGuidanceRefreshInterval: TimeInterval = 10 * 60
    private static let strainTargetGuidanceTimer = Timer.publish(every: strainTargetGuidanceRefreshInterval, on: .main, in: .common).autoconnect()
    /// Motion becomes stale after 15 seconds and HR after six. A dedicated
    /// active-workout clock lets the foreground HUD cross those truth
    /// boundaries even when the strap simply stops publishing (there is no
    /// sensor event at the instant freshness expires).
    nonisolated static let liveWorkoutFreshnessRefreshInterval: TimeInterval = 3
    private static let liveWidgetSnapshotMinimumInterval: TimeInterval = 45
    private static let liveWidgetSnapshotMeaningfulChangeInterval: TimeInterval = 15
    private static let liveWidgetSnapshotMeaningfulBPMDelta = 4
    private static let workoutPromptCooldown: TimeInterval = AtriaWorkoutPromptEvaluator.cooldown
    private static let workoutReviewSettleBPMOverRest = 20
    private static let workoutReviewRecentEndHoldSeconds: TimeInterval = 15 * 60
    private static let workoutReviewDismissedIDKey = "atria.workoutReview.dismissedID"
    private static let workoutReviewDismissedIDsKey = "atria.workoutReview.dismissedIDs"
    private static let workoutReviewDismissedIDsLimit = 24

    private struct AtriaWorkoutEndNotice: Identifiable, Equatable {
        enum RouteState: Equatable {
            case ready
            case attaching
        }

        enum Outcome: Equatable {
            /// `UserConfirmedWorkout` is returned only after the store's atomic
            /// canonical write succeeds. Keeping it beside the snapshot makes
            /// an unsaved completion structurally incapable of sharing.
            case persisted(
                workout: UserConfirmedWorkout,
                snapshot: AtriaWorkoutShareSnapshot,
                routeState: RouteState
            )
            case retained(
                activityType: AtriaWorkoutActivityType?,
                duration: TimeInterval?
            )
        }

        let id = UUID()
        let title: String
        let message: String
        let outcome: Outcome

        static func persisted(
            workout: UserConfirmedWorkout,
            snapshot: AtriaWorkoutShareSnapshot,
            title: String,
            message: String,
            routeState: RouteState = .ready
        ) -> Self {
            Self(title: title,
                 message: message,
                 outcome: .persisted(workout: workout,
                                     snapshot: snapshot,
                                     routeState: routeState))
        }

        static func retained(
            title: String,
            message: String,
            activityType: AtriaWorkoutActivityType? = nil,
            duration: TimeInterval? = nil
        ) -> Self {
            Self(title: title,
                 message: message,
                 outcome: .retained(activityType: activityType,
                                    duration: duration))
        }

        var persistedShareSnapshot: AtriaWorkoutShareSnapshot? {
            guard case .persisted(_, let snapshot, _) = outcome else { return nil }
            return snapshot
        }
    }

    private struct AtriaWorkoutShareReceipt: Identifiable {
        let id = UUID()
        let snapshot: AtriaWorkoutShareSnapshot
    }

    private struct AtriaWorkoutEndRecapSheet: View {
        private struct Metric: Identifiable {
            let title: String
            let value: String
            let systemImage: String
            var id: String { title }
        }

        @Environment(\.dismiss) private var dismiss

        let notice: AtriaWorkoutEndNotice
        let onShare: (AtriaWorkoutShareSnapshot) -> Void

        var body: some View {
            ZStack {
                AtriaDashboardBackdrop()
                    .ignoresSafeArea()

                VStack(spacing: 18) {
                    summary

                    Text(notice.message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .minimumScaleFactor(0.88)
                        .padding(.horizontal, 8)

                    Spacer(minLength: 0)
                    actions
                }
                .padding(.horizontal, 18)
                .padding(.top, 20)
                .padding(.bottom, 14)
            }
        }

        private var summary: some View {
            VStack(spacing: 16) {
                HStack(spacing: 12) {
                    Image(systemName: activitySystemImage)
                        .font(.system(size: 23, weight: .semibold))
                        .foregroundStyle(statusTint)
                        .frame(width: 50, height: 50)
                        .background(statusTint.opacity(0.14), in: Circle())

                    VStack(alignment: .leading, spacing: 3) {
                        Text(notice.title)
                            .font(.title3.weight(.bold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.80)
                        Text(activityTitle)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 4)

                    Label(statusTitle, systemImage: statusSystemImage)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(statusTint)
                        .labelStyle(.titleAndIcon)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(statusTint.opacity(0.12), in: Capsule())
                }

                if !metrics.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(metrics) { metric in
                            VStack(alignment: .leading, spacing: 5) {
                                Label(metric.title, systemImage: metric.systemImage)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Text(metric.value)
                                    .font(.headline.weight(.bold).monospacedDigit())
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.74)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 10)
                            .background(.primary.opacity(0.055),
                                        in: RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.inset, style: .continuous))
                        }
                    }
                }
            }
            .padding(16)
            .atriaGlassCard(cornerRadius: 24, emphasis: .strong)
            .accessibilityElement(children: .contain)
        }

        private var actions: some View {
            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 12) {
                    Button {
                        dismiss()
                    } label: {
                        Text("Done")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                    }
                    .atriaCardAction(prominent: notice.persistedShareSnapshot == nil,
                                     tint: statusTint)

                    if let snapshot = notice.persistedShareSnapshot {
                        Button {
                            onShare(snapshot)
                            dismiss()
                        } label: {
                            Label("Share", systemImage: "square.and.arrow.up")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .frame(height: 48)
                        }
                        .atriaCardAction(prominent: true, tint: statusTint)
                        .accessibilityHint("Opens the saved workout share image")
                    }
                }
            }
        }

        private var activityTitle: String {
            switch notice.outcome {
            case .persisted(_, let snapshot, _):
                return snapshot.activity
            case .retained(let activityType, _):
                return activityType?.rawValue ?? "Workout"
            }
        }

        private var activitySystemImage: String {
            switch notice.outcome {
            case .persisted(_, let snapshot, _):
                return snapshot.activitySystemImage
            case .retained(let activityType, _):
                return activityType?.icon ?? "figure.mixed.cardio"
            }
        }

        private var statusTitle: String {
            switch notice.outcome {
            case .persisted(_, _, .ready): return "Saved"
            case .persisted(_, _, .attaching): return "Route syncing"
            case .retained: return "Retrying"
            }
        }

        private var statusSystemImage: String {
            switch notice.outcome {
            case .persisted(_, _, .ready): return "checkmark.circle.fill"
            case .persisted(_, _, .attaching): return "arrow.triangle.2.circlepath"
            case .retained: return "clock.arrow.circlepath"
            }
        }

        private var statusTint: Color {
            switch notice.outcome {
            case .persisted(_, _, .ready): return .green
            case .persisted(_, _, .attaching), .retained: return .orange
            }
        }

        private var metrics: [Metric] {
            switch notice.outcome {
            case .retained(_, let duration):
                guard let duration else { return [] }
                return [Metric(title: "Duration",
                               value: Self.durationText(duration),
                               systemImage: "clock.fill")]
            case .persisted(_, let snapshot, _):
                var result = [Metric(title: "Duration",
                                     value: snapshot.duration,
                                     systemImage: "clock.fill")]
                if let distance = snapshot.distance {
                    result.append(Metric(title: "Distance",
                                         value: distance,
                                         systemImage: "location.fill"))
                }
                if let steps = snapshot.steps, result.count < 3 {
                    result.append(Metric(title: "Steps",
                                         value: steps,
                                         systemImage: "figure.walk"))
                }
                if let averageHeartRate = snapshot.averageHeartRate, result.count < 3 {
                    result.append(Metric(title: "Avg HR",
                                         value: averageHeartRate,
                                         systemImage: "heart.fill"))
                }
                if snapshot.strain != "--", result.count < 3 {
                    result.append(Metric(title: "Strain",
                                         value: snapshot.strain,
                                         systemImage: "flame.fill"))
                }
                if snapshot.peakHeartRate != "--", result.count < 3 {
                    result.append(Metric(title: "Peak HR",
                                         value: snapshot.peakHeartRate,
                                         systemImage: "waveform.path.ecg"))
                }
                return Array(result.prefix(3))
            }
        }

        private static func durationText(_ duration: TimeInterval) -> String {
            let minutes = max(1, Int((duration / 60).rounded()))
            guard minutes >= 60 else { return "\(minutes) min" }
            let hours = minutes / 60
            let remainder = minutes % 60
            return remainder == 0 ? "\(hours) hr" : "\(hours) hr \(remainder) min"
        }
    }

    private enum HomeTab: String, CaseIterable, Identifiable {
        case overview
        case vitals
        case journal
        // Repurposed 2026-07-06: this slot was the "Plan" tab, whose weekly-plan
        // and routine cards already lived on Today and Journal (pure redundancy).
        // It now hosts the Activity Monitor. The case name / "plan" raw value are
        // kept so the deep-link token and the pinned Tab selection value stay valid.
        case plan
        case chat
        case collection

        var id: String { rawValue }

        var deepLinkPath: String {
            switch self {
            case .overview: return "overview"
            case .vitals: return "vitals"
            case .journal: return "journal"
            case .plan: return "plan"
            case .chat: return "chat"
            case .collection: return "strap"
            }
        }

        static func deepLinkDestination(for url: URL) -> HomeTab? {
            guard url.scheme?.lowercased() == "atria" else { return nil }
            let pieces = ([url.host].compactMap { $0 } + url.pathComponents.filter { $0 != "/" })
                .map { $0.lowercased() }
            guard let token = pieces.first(where: { $0 != "tab" }) else { return nil }
            switch token {
            case "overview", "today": return .overview
            case "sleep-review", "sleep": return .overview
            case "vitals": return .vitals
            case "journal": return .journal
            case "plan": return .plan
            case "chat": return .chat
            // Static handoff compatibility marker for the previous aliases:
            // case "data", "collection": return .collection
            case "strap", "data", "collection": return .collection
            default: return nil
            }
        }

        var title: String {
            switch self {
            case .overview: return "Today"
            case .vitals: return "Vitals"
            case .journal: return "Journal"
            case .plan: return "Activity"
            case .chat: return "Assistant"
            case .collection: return "Strap"
            }
        }

        var systemImage: String {
            switch self {
            case .overview: return "house.fill"
            case .vitals: return "heart.text.square"
            case .journal: return "square.and.pencil"
            case .plan: return "list.bullet.rectangle.fill"
            case .chat: return "bubble.left.and.bubble.right.fill"
            case .collection: return "applewatch.radiowaves.left.and.right"
            }
        }
    }

    fileprivate enum WorkoutReviewHoldState: Equatable {
        case waitingForSettle(bpmOverRest: Int)
        case possibleSignal(reason: String)

        var title: String {
            switch self {
            case .waitingForSettle:
                return "Still watching effort"
            case .possibleSignal:
                return "Possible effort saved"
            }
        }

        var detail: String {
            switch self {
            case .waitingForSettle(let bpmOverRest):
                return "HR is still +\(bpmOverRest) over rest. Atria waits before asking."
            case .possibleSignal:
                return "Saved as possible effort. Atria will ask when the strap signal is stronger."
            }
        }

        var accessibilityText: String {
            switch self {
            case .waitingForSettle(let bpmOverRest):
                return "Workout review held while heart rate settles. Current heart rate is \(bpmOverRest) beats per minute over rest."
            case .possibleSignal:
                return "Workout review held because the strap signal looks like possible effort, not a strong workout."
            }
        }
    }

    let ble: AtriaBLEManager
    let store: SessionStore
    let workoutRouteRecorder: AtriaWorkoutRouteRecorder

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage("atriaAppearanceMode") private var appearanceMode = "system"
    @State private var model: AtriaHomeModel
    // The detected-activities fixture lives in the Health screen's Trends
    // scope under the Vitals tab; simctl cannot tap the tab bar, so the
    // screenshot loop needs the root tab routed too. DEBUG-only.
    @State private var selectedTab: HomeTab = Self.debugInitialHomeTab(
        arguments: ProcessInfo.processInfo.arguments
    )
    @State private var showRRImporter = false
    @State private var showHRImporter = false
    @State private var rrShareURL: URL?
    @State private var hrShareURL: URL?
    @State private var captureShareURL: URL?
    @State private var rrImportStatus = ""
    @State private var hrImportStatus = ""
    @State private var hasUnlockedPrimaryContent = false
    @State private var hasUnlockedSecondarySections = false
    @State private var showConnectionGuide = false
    // Retained by identity without subscribing the 10k-line Home hierarchy to
    // presentation changes. AtriaSettingsPresentationHost is the sole observer.
    @State private var settingsPresentation = AtriaSettingsPresentationCoordinator()
    @State private var showStrapScreen = false
    @State private var showAssistant = false
    @State private var showShareSheet = false
    @State private var incomingFaceOff: AtriaFaceOffPayload?
    // Force-present the sleep review/edit sheet from the "Review your sleep"
    // notification deep link, independent of the inline Overview review card's
    // gating (so the tap always lands somewhere actionable).
    @State private var sleepReviewSheetRoute: AtriaSleepReviewSheetRoute?
    @State private var sameDayMainSleepRoute: AtriaSameDayMainSleepChoice?
    // Plain read, not @AppStorage: this key has dots, which is the exact
    // KVO-storm hazard documented above for persistentHeartRateBroadcastEnabled
    // and homeLayoutConfigStorage (~790 evals/sec self-invalidation, 0x8BADF00D
    // crash loop, 2026-07-03) — this app writes "atria.*"-prefixed diagnostics
    // keys constantly, and a dotted @AppStorage key path re-fires on ANY of
    // them. AtriaHomeView never writes this value (AtriaSettingsView's own
    // TextField is the sole writer), so a live UserDefaults read at the two
    // use sites below is equivalent with zero subscription overhead.
    private var faceOffDisplayName: String {
        UserDefaults.standard.string(forKey: "atria.faceoff.displayName") ?? ""
    }
    @State private var showCustomizeSheet = false
    @State private var showWidgetProofSheet = false
    @State private var widgetProofSnapshot: WidgetSnapshot?
    @State private var workoutSession: AtriaWorkoutSession?
    @State private var workoutPersistenceRevision: UInt64 = 0
    @State private var showWorkoutStartSheet = false
    @State private var showAddActivitySheet = false
    /// A tap must be visibly acknowledged before the crash-safe intent write
    /// completes. This is deliberately not a workout: no clock, metrics, or
    /// motion lease is published until the atomic intent has read back.
    @State private var isSecuringWorkoutStart = false
    @State private var showWorkoutStartPersistenceError = false
    @State private var liveWorkoutLoggedSets: [LoggedSet] = []
    @State private var liveWorkoutStrengthHistory: StrengthHistoryProjection = .empty
    // Strength history is display-only context (PRs / recent sets), never an
    // authority required to start a workout. Keep its archive scan out of the
    // Start tap so a long-lived session store cannot make the control hang.
    @State private var liveWorkoutStrengthHistoryPreparationTask: Task<Void, Never>?
    @State private var liveWorkoutStrengthHistoryPreparationID = UUID()
    @State private var liveWorkoutExcludedIntervals: [ExcludedInterval] = []
    @State private var suppressNextExcludedIntervalPersistence = false
    @State private var liveWorkoutPauseStartedAt: Date?
    @State private var liveWorkoutTRIMPAccumulator = AtriaLiveWorkoutTRIMPAccumulator()
    // Retain by identity without subscribing Home's 10k-line hierarchy. The
    // presented AtriaLiveWorkoutView is the sole observer, so 750 ms live
    // metric publications cannot rebuild every underlying tab and sheet.
    @State private var liveWorkoutMetricStore = AtriaLiveWorkoutMetricStore()
    @State private var liveWorkoutMinimized = false
    @State private var workoutEndNotice: AtriaWorkoutEndNotice?
    @State private var queuedWorkoutShareSnapshot: AtriaWorkoutShareSnapshot?
    @State private var completedWorkoutShareReceipt: AtriaWorkoutShareReceipt?
    @State private var foregroundResumeTask: Task<Void, Never>?
    @State private var foregroundResumeAuthority =
        AtriaForegroundDeferredWorkAuthority()
    @State private var pendingWorkoutRecoveryTask: Task<Void, Never>?
    @State private var liveWorkoutFreshnessTask: Task<Void, Never>?
    // Lifetime owner only. Route publishes are observed by the presented live
    // workout map, not this entire tab shell; using StateObject here made every
    // one-second GPS snapshot invalidate the whole Home hierarchy.
    @State private var workoutRouteBackgroundLease = AtriaWorkoutRouteBackgroundLease()
    @State private var showCoexistenceModal = false
    @State private var officialAppInstalled: Bool = {
        guard let url = URL(string: "whoop://") else { return false }
        return UIApplication.shared.canOpenURL(url)
    }()
    @State private var didApplyDebugUIScreenLaunchArgument = false
    // Static handoff compatibility marker for the old segment state:
    // @State private var debugInitialOverviewSegment: AtriaTodaySegment = .today
    // @State private var activeOverviewSegment: AtriaTodaySegment = .today
    // _activeOverviewSegment = State(initialValue: debugOverviewSegment ?? .today)
    // private static func debugLaunchOverviewSegmentArgument(arguments: [String] = ProcessInfo.processInfo.arguments) -> AtriaTodaySegment?
    // return AtriaTodaySegment.debugLaunchValue(from: arguments[arguments.index(after: segmentIndex)])
    // onSegmentChange: { segment in
    // activeOverviewSegment = segment
    @State private var debugInitialOverviewSegment: AtriaLegacyOverviewDestination = .today
    @State private var debugShowsOverviewSegmentContent = false
    @State private var coexistenceSnoozedUntil: Date?
    @State private var connectionGuideSnoozedUntil: Date?
    @State private var connectionGuidePresentationToken = UUID()
    @State private var connectionGuidePresentationTask: Task<Void, Never>?
    @State private var connectionDiagnosisCandidate: AtriaConnectionDiagnosis?
    @State private var connectionDiagnosisCandidateSince: Date?
    @State private var connectionDiagnosisPromotionTask: Task<Void, Never>?
    @State private var visibleConnectionDiagnosis: AtriaConnectionDiagnosis?
    @State private var lastAutomaticConnectionSetupAt: Date?
    @State private var secondaryUnlockTask: Task<Void, Never>?
    @State private var overviewDiagnosticsKickoffTask: Task<Void, Never>?
    @State private var automaticConnectionSetupTask: Task<Void, Never>?
    @State private var homeAppearedAt: Date?
    @State private var hasLoggedPrimaryReady = false
    @State private var hasLoggedSecondaryReady = false
    @State private var hasLoggedDiagnosticsReady = false
    @State private var entitlements = AtriaEntitlements()
    @State private var hapticSettings = AtriaHapticAlertSettings.load()
    @State private var hapticCoordinator = AtriaHapticAlertCoordinator()
    @StateObject private var mediaController = AtriaMediaController()
    @StateObject private var heartRateBroadcaster = AtriaHeartRateBroadcaster()
    // Lifetime owner only. The narrow publisher subscription below evaluates
    // prompt context; Home itself does not render monitor fields. Observing the
    // object here would invalidate the entire tab shell on each 30-second
    // evidence refresh even when the visible prompt does not change.
    @State private var motionActivityMonitor = AtriaMotionActivityMonitor()
    @State private var liveActivityCoordinator = AtriaLiveActivityCoordinator()
    @State private var aiCoachSettings = AtriaAICoachSettings.load()
    @State private var aiCoachHasAPIKey = false
    @State private var batteryState: UIDevice.BatteryState = UIDevice.current.batteryState
    @State private var standByDismissedUntil: Date?
    @State private var missedDataBannerDismissedUntil: Date?
    @State private var confirmStartFreshFromBanner = false
    @State private var developerModeEnabled = AtriaDeveloperMode.isEnabled
    @State private var lastLiveWidgetSnapshotAt: Date?
    @State private var lastLiveWidgetSnapshotHeartRate: Int?
    @State private var workoutDetectionPrompt: AtriaWorkoutDetectionPrompt?
    @State private var workoutPromptDismissedUntil: Date?
    @State private var workoutPromptSuppressedForCurrentEpisode = false
    @State private var workoutPromptRecoveryStartedAt: Date?
    @State private var workoutReviewDraft: AtriaWorkoutReviewDraft?
    @State private var savedWorkoutReviewCandidate: WorkoutReviewCandidate?
    @State private var workoutReviewHoldState: WorkoutReviewHoldState?
    @State private var showConnectivityPill = false
    @State private var connectivityPillTask: Task<Void, Never>?
    @State private var notificationDeepLinkDrainTask: Task<Void, Never>?
    @State private var pendingSleepReviewDeepLink = false
    @State private var showJournalSheet = false
    @State private var workoutHeartRateBroadcastEnabled = false
    // Plain @State, not @AppStorage, for the same dotted-key KVO storm reason
    // as persistentHeartRateBroadcastEnabled below — after that key was fixed,
    // this one became the next storm driver (validated with _printChanges).
    // This view is the only writer; saveHomeLayoutConfig persists explicitly.
    @State private var homeLayoutConfigStorage = UserDefaults.standard.string(forKey: AtriaHomeLayoutConfig.storageKey) ?? ""
    // Deliberately NOT @AppStorage: the key contains dots, and UserDefaults KVO
    // treats dotted keys as key paths, so the observation fires for writes to
    // ANY `atria.*` key. This app writes diagnostics keys constantly (including
    // from this body's own onReceive side effects), which turned the AppStorage
    // subscription into a ~790 evals/sec self-invalidation storm that blew the
    // scene-create watchdog whenever broadcast was enabled and HR was live
    // (0x8BADF00D crash loop, 2026-07-03). Plain @State + explicit persistence
    // keeps the same behavior without the KVO subscription.
    @State private var persistentHeartRateBroadcastEnabled = AtriaHeartRateBroadcastPreference.isEnabled

    init(ble: AtriaBLEManager,
         store: SessionStore,
         workoutRouteRecorder: AtriaWorkoutRouteRecorder) {
        self.ble = ble
        self.store = store
        self.workoutRouteRecorder = workoutRouteRecorder
        let debugOverviewSegment = Self.debugLaunchOverviewSegmentArgument()
#if DEBUG
        let showsShowcaseFixture = AtriaScreenshotShowcase.isActive
#else
        let showsShowcaseFixture = false
#endif
        _debugInitialOverviewSegment = State(initialValue: debugOverviewSegment ?? .today)
        _debugShowsOverviewSegmentContent = State(initialValue: debugOverviewSegment != nil || showsShowcaseFixture)
        _model = State(initialValue: AtriaHomeModel(ble: ble, store: store))
    }

    var body: some View {
        homePresentationModifiers
    }

    private var homeLifecycleModifiers: some View {
        homeShellWithWorkoutPersistence
        .onAppear {
            scheduleHomeAppearAfterFirstFrame()
        }
        .onChange(of: selectedTab) { _, tab in
            handleSelectedTabChange(tab)
        }
        .sensoryFeedback(.selection, trigger: selectedTab)
        .sensoryFeedback(trigger: workoutEndNotice) { _, notice in
            notice == nil ? nil : .success
        }
        .onChange(of: hasUnlockedSecondarySections) { _, unlocked in
            handleSecondarySectionUnlockChange(unlocked)
        }
        .onChange(of: scenePhase) { _, phase in
            handleHomeScenePhaseChange(phase)
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.didBecomeActiveNotification
        )) { _ in
            scheduleForegroundResumeIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: AtriaHistoricalProjectionForegroundGate
                .didBecomeForegroundNotification
        )) { _ in
            scheduleForegroundResumeIfNeeded()
        }
        .onChange(of: hapticSettings) { _, settings in
            handleHapticSettingsChange(settings)
        }
        .onChange(of: persistentHeartRateBroadcastEnabled) { _, _ in
            updateHeartRateBroadcastState(reason: "settings")
        }
        .onChange(of: workoutHeartRateBroadcastEnabled) { _, _ in
            updateHeartRateBroadcastState(reason: "workout_toggle")
        }
        .onChange(of: workoutSession == nil) { _, ended in
            handleWorkoutSessionPresenceChange(ended)
        }
        .onChange(of: aiCoachSettings) { _, settings in
            handleAICoachSettingsChange(settings)
        }
    }

    private var homePublisherObservers: some View {
        homeLifecycleModifiers
        .onReceive(model.heroPulseStore.$state) { state in
            heartRateBroadcaster.publish(heartRate: state.heartRate)
        }
        .onReceive(heartRateBroadcaster.$isBroadcasting.removeDuplicates()) { active in
            model.setHeartRateBroadcastActive(active)
        }
        .onReceive(motionActivityMonitor.$context.removeDuplicates()) { _ in
            handleMotionActivityContextUpdate()
        }
        .onReceive(liveActivityUpdates) { _ in
            handleLiveActivityUpdate()
        }
        .onReceive(Self.strainTargetGuidanceTimer) { _ in
            model.refreshDailyGuidanceClock()
        }
        .onReceive(hapticUpdates) { _ in
            updateHapticCoordinator()
        }
        .onReceive(liveWidgetUpdates) { _ in
            publishLiveWidgetSnapshotIfNeeded()
        }
        .onReceive(liveStepWidgetUpdates) { _ in
            // Step updates are independent of pulse updates. Persist the exact
            // latest count with the light live-sensor patch so a quiet/absent
            // HR stream cannot leave widgets pinned to an older step value.
            scheduleLiveSensorWidgetPatch(reason: "live_steps")
        }
        .onReceive(workoutDetectionUpdates) { _ in
            handleWorkoutDetectionUpdate()
        }
        .onReceive(batteryWidgetUpdates) { _ in
            // A fresh strap battery read commonly lands after the scene has
            // already moved to background. The scene-edge snapshot therefore
            // still contains the hydrated/cached level unless battery changes
            // can publish independently of the foreground HR cadence.
            scheduleWidgetSnapshot(reason: "strap_battery_update")
        }
        .onReceive(NotificationCenter.default.publisher(
            for: AtriaWhoop4MotionTickDailyStore.didSaveNotification
        )) { _ in
            handleDurableStrapStepReceipt()
        }
        .onReceive(store.$dashboardRevision.throttle(for: .seconds(3), scheduler: RunLoop.main, latest: true)) { _ in
            handleDashboardRevisionUpdate()
        }
        .onReceive(NotificationCenter.default.publisher(for: SessionStore.historicalRecoveryNeededNotification)) { _ in
            ble.schedulePendingHistoricalRecovery(reason: "confirmed_workout_archive_gap")
        }
        .onReceive(NotificationCenter.default.publisher(for: SessionStore.historicalRecoveryResolvedNotification)) { _ in
            ble.schedulePendingHistoricalRecovery(reason: "confirmed_workout_rehydrated")
        }
        .onReceive(NotificationCenter.default.publisher(for: .atriaWorkoutRuntimeDidApplyCommand)) { _ in
            synchronizeWorkoutUIWithCanonicalIntent()
        }
        .onReceive(NotificationCenter.default.publisher(for: SessionStore.workoutReviewCandidateReviewRequestedNotification)) { note in
            handleWorkoutReviewCandidateNotification(note)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryStateDidChangeNotification)) { _ in
            batteryState = UIDevice.current.batteryState
        }
        .onReceive(NotificationCenter.default.publisher(for: NotificationDeliveryLogger.deepLinkNotification)) { _ in
            schedulePendingNotificationDeepLinkDrain()
        }
        .onReceive(store.$pendingSleepReviewNightForUI) { night in
            resolvePendingSleepReviewDeepLinkIfNeeded(publishedNight: night)
        }
        .onReceive(store.$pendingSameDayMainSleepChoiceForUI) { choice in
            sameDayMainSleepRoute = choice
        }
    }

    private var homePresentationModifiers: some View {
        homePublisherObservers
        .onOpenURL(perform: handleDeepLink)
        .sheet(item: $sameDayMainSleepRoute) { choice in
            AtriaSameDayMainSleepSheet(choice: choice) { primaryID in
                store.resolveSameDayMainSleepChoice(choice, primaryID: primaryID)
            }
        }
        .sheet(item: $sleepReviewSheetRoute, content: sleepReviewSheet(for:))
        .onDisappear {
            // H-series teardown that postdates the refactor into
            // stopHomeRefreshServices(): live-presentation gate + resume
            // authority must still stop with the screen.
            model.setLivePresentationActive(false)
            foregroundResumeAuthority.cancel()
            stopHomeRefreshServices()
        }
    }

    private func stopHomeRefreshServices() {
        connectionGuidePresentationTask?.cancel()
        connectionGuidePresentationTask = nil
        secondaryUnlockTask?.cancel()
        secondaryUnlockTask = nil
        overviewDiagnosticsKickoffTask?.cancel()
        overviewDiagnosticsKickoffTask = nil
        automaticConnectionSetupTask?.cancel()
        automaticConnectionSetupTask = nil
        foregroundResumeTask?.cancel()
        foregroundResumeTask = nil
        pendingWorkoutRecoveryTask?.cancel()
        pendingWorkoutRecoveryTask = nil
        connectionDiagnosisPromotionTask?.cancel()
        connectionDiagnosisPromotionTask = nil
        mediaController.setRefreshLoopActive(false)
        motionActivityMonitor.stop()
    }

    private func scheduleHomeAppearAfterFirstFrame() {
        // Run appear work AFTER the first frame commits. onAppear fires
        // mid-first-commit; mutating state here (content unlock, broadcast
        // setup) re-invalidates the graph before anything is on screen, which
        // under live BLE churn blew the 10-20s scene-create watchdog.
        Task { @MainActor in
            await Task.yield()
            handleHomeAppear()
        }
    }

    private func handleSecondarySectionUnlockChange(_ unlocked: Bool) {
        guard unlocked else { return }
        logSecondaryContentReadyIfNeeded()
    }

    private func handleHapticSettingsChange(_ settings: AtriaHapticAlertSettings) {
        settings.save()
        updateHapticCoordinator()
    }

    private func handleWorkoutSessionPresenceChange(_ ended: Bool) {
        if ended {
            workoutHeartRateBroadcastEnabled = false
            liveWorkoutTRIMPAccumulator.clear()
        }
        updateHeartRateBroadcastState(reason: ended ? "workout_end" : "workout_start")
        updateLiveActivity()
        updateLiveWorkoutFreshnessLoop()
    }

    private func handleAICoachSettingsChange(_ settings: AtriaAICoachSettings) {
        settings.save()
        refreshAICoachKeyState()
    }

    private func sleepReviewSheet(
        for route: AtriaSleepReviewSheetRoute
    ) -> some View {
        AtriaManualSleepSheet(initialStart: route.night?.start,
                              initialEnd: route.night?.end,
                              initialIsNap: route.night?.isNapEvidence,
                              // A review/edit keeps the strap-derived stage
                              // model. A new manual item has no sensor stage
                              // lineage to preserve.
                              preservesSensorStages: route.night != nil,
                              evidenceNight: route.night,
                              evidencePerformancePercent: route.night.flatMap {
                                  adaptiveSleepProjection(for: $0)?.performancePercent
                              },
                              mode: route.night.map { $0.confirmed ? .edit : .review } ?? .add,
                              onRemove: route.night.map { night in
                                  {
                                      let removed = night.confirmed
                                          ? await store.deleteConfirmedSleep(id: night.id)
                                          : store.dismissSleepCandidate(night)
                                      if removed { sleepReviewSheetRoute = nil }
                                      return removed
                                  }
                              }) { start, end, isNap in
            let rest = store.baseline.restingInt ?? 60
            let saved: Bool
            if let night = route.night {
                saved = await store.saveSleepReviewNightForUI(
                    night,
                    start: start,
                    end: end,
                    isNap: isNap,
                    rest: rest,
                    source: "notification_sleep_review"
                ) != nil
            } else {
                saved = await store.addManualSleep(start: start,
                                             end: end,
                                             isNap: isNap,
                                             rest: rest,
                                             source: "activity_add") != nil
            }
            if saved { sleepReviewSheetRoute = nil }
            return saved
        }
    }

    private func handleDashboardRevisionUpdate() {
        refreshSavedWorkoutReviewCandidate(reason: "dashboard_revision")
        if let candidate = savedWorkoutReviewCandidate {
            LocalNotificationScheduler.scheduleWorkoutReviewAfterCachePublicationIfNeeded(
                candidate,
                ble: ble
            )
        }
        scheduleWidgetSnapshot(reason: "dashboard_revision")
    }

    private func handleMotionActivityContextUpdate() {
        // Clear a visible prompt immediately if the phone identifies a car,
        // and apply only sustained native type suggestions to new prompts.
        updateWorkoutDetectionPrompt()
    }

    private func handleLiveActivityUpdate() {
        guard workoutSession != nil else { return }
        updateLiveActivity()
    }

    private func handleWorkoutDetectionUpdate() {
        guard workoutSession == nil else { return }
        updateWorkoutDetectionPrompt()
    }

    private func handleDurableStrapStepReceipt() {
        // The durable receipt can land before the async HistorySnapshot
        // rebuild. Refresh both app and widget directly from that receipt so a
        // verified strap subtotal never temporarily disappears.
        model.refreshDurableStepReceipt()
        scheduleWidgetSnapshot(reason: "durable_strap_steps")
    }

    private func handleWorkoutReviewCandidateNotification(_ note: Notification) {
        // History's "Detected activities" rows route into the SAME guided
        // review flow the Home banner uses (2026-07-17): confirm-type or
        // dismiss, never a parallel save path. Fail closed during a live
        // workout — the review sheet must not stack over an active session.
        guard workoutSession == nil,
              workoutReviewDraft == nil,
              let candidate = note.userInfo?[SessionStore.workoutReviewCandidateUserInfoKey] as? WorkoutReviewCandidate else { return }
        presentWorkoutReview(candidate: candidate)
    }

    private var homeShellWithWorkoutPersistence: some View {
        homeShellCore
            .onChange(of: workoutZoneHapticConfiguration, initial: true) { _, configuration in
                synchronizeWorkoutZoneHaptics(configuration)
            }
            .onChange(of: liveWorkoutLoggedSets) { _, _ in
                persistPendingWorkoutProgress()
            }
            .onChange(of: liveWorkoutExcludedIntervals) { _, _ in
                if suppressNextExcludedIntervalPersistence {
                    suppressNextExcludedIntervalPersistence = false
                    return
                }
                persistPendingWorkoutProgress()
            }
    }

    private func synchronizeWorkoutZoneHaptics(
        _ configuration: WorkoutZoneHapticConfiguration?
    ) {
        ble.configureWorkoutZoneHaptics(
            workoutStartedAt: configuration?.workoutStartedAt,
            lowerTargetZone: configuration?.lowerTargetZone,
            upperTargetZone: configuration?.upperTargetZone,
            maxHR: configuration?.maxHR ?? store.profile.maxHR,
            restingHR: configuration?.restingHR ?? store.baseline.restingInt ?? 60,
            isPaused: configuration?.isPaused ?? false
        )
    }

    private var homeShellCore: some View {
        ZStack {
            AtriaBackdropLayer(isDark: isDark, reduceTransparency: reduceTransparency)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            TabView(selection: $selectedTab) {
                Tab(HomeTab.overview.title,
                    systemImage: HomeTab.overview.systemImage,
                    value: HomeTab.overview) {
                    tabNavigation(title: "Today", showsHero: false) {
                        // Always render real content from first frame: the model is
                        // seeded synchronously (cold-start rollup/widget-snapshot
                        // seed, see AtriaHomeModel.makeColdStartSnapshot) so there is
                        // no "Preparing overview" placeholder gate here anymore.
                        // hasUnlockedPrimaryContent now only gates progressive
                        // diagnostics kickoff, not the base layout paint.
                        overviewContent
                    }
                }

                Tab(HomeTab.vitals.title,
                    systemImage: HomeTab.vitals.systemImage,
                    value: HomeTab.vitals) {
                    tabNavigation(title: "Vitals", showsHero: false) {
                        vitalsContent
                    }
                }

                Tab(HomeTab.journal.title,
                    systemImage: HomeTab.journal.systemImage,
                    value: HomeTab.journal) {
                    tabNavigation(title: "Journal", showsHero: false) {
                        journalContent
                    }
                }
                // The Daily Brief left Today (owner stack audit 2026-08-28);
                // the pending check-in now knocks from the tab it lives in.
                // Badge = questions remaining; hidden at zero.
                .badge(journalCheckInBadgeCount)

                Tab(HomeTab.plan.title,
                    systemImage: HomeTab.plan.systemImage,
                    value: HomeTab.plan) {
                    tabNavigation(title: "Activity", showsHero: false) {
                        planContent
                    }
                }
            }
            // iOS 26 already renders the interactive Liquid Glass capsule for
            // the tab items. Keeping the legacy tab-bar material behind that
            // capsule creates a second opaque black shelf across the safe area.
            // Let the shared Atria backdrop/content continue beneath the native
            // glass control instead.
            .toolbarBackground(.hidden, for: .tabBar)
            // Follow the dashboard's real ScrollView direction: swiping content
            // upward collapses the native glass bar to its selected-tab button,
            // and reversing direction restores all four destinations. The
            // system owns the transition, hit targets, and VoiceOver behavior;
            // no parallel drag or duplicated compact-navigation state is needed.
            .tabBarMinimizeBehavior(.onScrollDown)
            .tabViewBottomAccessory(isEnabled: shouldShowLiveAccessory) {
                AtriaLiveTabAccessoryHost(pulseStore: model.pulseLiveStore,
                                          metricStore: liveWorkoutMetricStore,
                                          workoutStart: workoutSession?.start,
                                          workoutSystemImage: workoutSession?.activityType.icon ?? AtriaWorkoutActivityType.other.icon,
                                          onOpenWorkout: reopenMinimizedWorkout)
            }

            AtriaHomeObservers(statusStore: model.statusStore,
                               snapshotStore: model.snapshotStore) { status in
                handleStatusChange(status)
            } onDiagnosticsReady: {
                overviewDiagnosticsKickoffTask?.cancel()
                overviewDiagnosticsKickoffTask = nil
                logDiagnosticsReadyIfNeeded()
            }

            settingsPresentationHost

            GeometryReader { proxy in
                let isLandscape = proxy.size.width > proxy.size.height
                if shouldShowStandBy(isLandscape: isLandscape) {
                    AtriaStandByOverlay(coreLiveStore: model.coreLiveStore,
                                        pulseLiveStore: model.pulseLiveStore,
                                        heroStore: model.heroStore) {
                        standByDismissedUntil = Date().addingTimeInterval(20 * 60)
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }
            }
            .ignoresSafeArea()
        }
        .environment(\.atriaEntitlements, entitlements)
        .preferredColorScheme(preferredColorScheme)
        .fileImporter(isPresented: $showRRImporter,
                      allowedContentTypes: [.commaSeparatedText, .plainText, .data],
                      allowsMultipleSelection: false,
                      onCompletion: handleRRImport)
        .fileImporter(isPresented: $showHRImporter,
                      allowedContentTypes: [.commaSeparatedText, .plainText, .data],
                      allowsMultipleSelection: false,
                      onCompletion: handleHRImport)
        .sheet(isPresented: $showConnectionGuide) {
            AtriaConnectionGuideSheetHost(statusStore: model.statusStore,
                                          context: connectionGuideContext) {
                connectionGuideSnoozedUntil = Date().addingTimeInterval(90)
                showConnectionGuide = false
                if model.statusStore.state.status != .connected {
                    ble.startScan(reason: "connection_guide_continue")
                }
            } retry: {
                connectionGuideSnoozedUntil = nil
                ble.startScan(reason: "connection_guide_retry")
            }
            .presentationDetents([.fraction(0.62), .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showShareSheet) {
            AtriaShareSheet(snapshot: makeTodayShareSnapshot(),
                            challengeURL: makeFaceOffChallengeURL())
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $workoutEndNotice, onDismiss: presentQueuedWorkoutShareIfNeeded) { notice in
            AtriaWorkoutEndRecapSheet(notice: notice) { snapshot in
                // Queue the composer and let this sheet finish dismissing first.
                // This avoids competing presentations and preserves the item-
                // driven rule that the share receipt exists only after save.
                queuedWorkoutShareSnapshot = snapshot
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(32)
        }
        .sheet(item: $completedWorkoutShareReceipt) { receipt in
            AtriaWorkoutShareSheet(snapshot: receipt.snapshot)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showWorkoutStartSheet) {
            AtriaWorkoutStartSheet(initial: AtriaWorkoutStartConfiguration(
                activityType: .other,
                targetStrain: model.heroStore.state.guidance.target,
                maxHeartRate: store.profile.maxHR
            ), onPrepare: {
                // Warm the two authorities while the picker is on screen.
                // This is strictly read-only: Start still requires both the
                // exact persisted intent and a hydrated strap-step ledger.
                prewarmLiveWorkoutStrengthHistory()
                _ = await AtriaPendingWorkoutIntent.preparePersistence()
                await store.waitForDeferredSessionLoadIfNeeded(timeoutSeconds: 1)
            }) { configuration in
                liveWorkoutLoggedSets = []
                liveWorkoutExcludedIntervals = []
                liveWorkoutMinimized = false
                isSecuringWorkoutStart = true
                showWorkoutStartSheet = false
                let started = await beginWorkoutSession(configuration: configuration)
                isSecuringWorkoutStart = false
                return started
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showAddActivitySheet) {
            // Reuse Activity's canonical manual-workout flow. This shortcut is
            // presentation-only; persistence and evidence rules stay owned by
            // AtriaAddWorkoutSheet and SessionStore.
            AtriaAddWorkoutSheet(store: store)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .alert("Workout couldn't start",
               isPresented: $showWorkoutStartPersistenceError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Atria couldn't secure the workout on this iPhone. Nothing was started or lost—try again.")
        }
        .sheet(item: $incomingFaceOff) { payload in
            AtriaFaceOffView(friend: payload,
                             mine: AtriaFaceOff.makePayload(name: faceOffDisplayName,
                                                            history: store.dailyMetricHistory))
        }
        .sheet(isPresented: $showCustomizeSheet) {
            AtriaCustomizeSheet(initialConfig: currentHomeLayoutConfig) { config in
                saveHomeLayoutConfig(config)
            }
        }
        .sheet(isPresented: $showWidgetProofSheet) {
            AtriaWidgetProofSheet(snapshot: widgetProofSnapshot,
                                  layoutConfig: currentHomeLayoutConfig)
        }
        .fullScreenCover(isPresented: liveWorkoutPresentationBinding) {
            if let session = workoutSession {
                AtriaLiveWorkoutView(pulseStore: model.pulseLiveStore,
                                     statusStore: model.statusStore,
                                     coreLiveStore: model.coreLiveStore,
                                     metricStore: liveWorkoutMetricStore,
                                     routeRecorder: workoutRouteRecorder,
                                     maxHR: store.profile.maxHR,
                                     restingHR: store.baseline.restingInt ?? 60,
                                     strengthBodyMassKg: {
                                         let frozenWeight = session.calculationContext?.profile.weightKg
                                         let currentWeight = store.profile.weightKg
                                         let weight = frozenWeight ?? currentWeight
                                         return weight > 0 ? weight : nil
                                     }(),
                                     strainTarget: model.heroStore.state.guidance.target,
                                     startDate: session.start,
                                     lowerTargetZone: session.lowerTargetZone,
                                     upperTargetZone: session.upperTargetZone,
                                     activityType: workoutActivityTypeBinding,
                                     targetChoice: workoutTargetChoiceBinding,
                                     strengthHistory: liveWorkoutStrengthHistory,
                                     loggedSets: $liveWorkoutLoggedSets,
                                     excludedIntervals: $liveWorkoutExcludedIntervals,
                                     pauseStartedAt: $liveWorkoutPauseStartedAt,
                                     heartRateBroadcastEnabled: $workoutHeartRateBroadcastEnabled,
                                     broadcastPersistsAfterWorkout: persistentHeartRateBroadcastEnabled,
                                     onMinimize: { liveWorkoutMinimized = true },
                                     onTogglePause: toggleLiveWorkoutPause,
                                     onStop: { await endWorkoutSession(startedAt: session.start,
                                                                       activityType: session.activityType,
                                                                       strengthSets: liveWorkoutLoggedSets,
                                                                       excludedIntervals: liveWorkoutExcludedIntervals) })
            } else if isSecuringWorkoutStart {
                AtriaSecuringWorkoutStartView()
            }
        }
        .interactiveDismissDisabled(isSecuringWorkoutStart)
        .sheet(item: $workoutReviewDraft) { draft in
            AtriaWorkoutReviewFlow(draft: draft) {
                workoutReviewDraft = nil
            } onSave: { @MainActor result in
                await saveWorkoutReview(
                    result,
                    settlingCandidateWindow: (draft.suggestedStart, draft.suggestedEnd)
                )
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showCoexistenceModal) {
            AtriaCoexistenceModal(context: connectionGuideContext) {
                acknowledgeCoexistenceModal(reason: "button")
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showJournalSheet) {
            NavigationStack {
                ScrollView(showsIndicators: false) {
                    AtriaOverviewMorningJournalHost(snapshotStore: model.snapshotStore,
                                                    store: store)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 18)
                }
                .scrollContentBackground(.hidden)
                .background {
                    AtriaBackdropLayer(isDark: isDark, reduceTransparency: reduceTransparency)
                        .ignoresSafeArea()
                }
                .navigationTitle("Journal")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") {
                            showJournalSheet = false
                        }
                    }
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .fullScreenCover(isPresented: $showStrapScreen) {
            NavigationStack {
                ScrollView {
                    collectionContent
                        .padding(.horizontal, 16)
                }
                .scrollContentBackground(.hidden)
                .background {
                    AtriaBackdropLayer(isDark: isDark, reduceTransparency: reduceTransparency)
                        .ignoresSafeArea()
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") {
                            showStrapScreen = false
                        }
                    }
                }
            }
        }
        // Assistant implemented (2026-07-07, user-directed): deterministic
        // Q&A from the app's own engines + the opt-in provider coach card.
        .fullScreenCover(isPresented: $showAssistant) {
            NavigationStack {
                ScrollView {
                    AtriaAssistantScreen(store: store,
                                         context: assistantCoachContext,
                                         coachPayload: assistantCoachPayload,
                                         aiCoachSettings: aiCoachSettings,
                                         aiCoachHasAPIKey: aiCoachHasAPIKey)
                }
                .scrollContentBackground(.hidden)
                .background {
                    AtriaBackdropLayer(isDark: isDark, reduceTransparency: reduceTransparency)
                        .ignoresSafeArea()
                }
                .navigationTitle("Assistant")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") {
                            showAssistant = false
                        }
                    }
                }
            }
        }
        .onReceive(ble.$officialAppCoexistenceRisk.removeDuplicates()) { risk in
            presentCoexistenceModalIfNeeded(for: risk)
            updateConnectionDiagnosisVisibility(reason: "coexistence_risk")
        }
        .onReceive(connectionDiagnosisUpdates) { _ in
            updateConnectionDiagnosisVisibility(reason: "connection_trigger")
        }
    }

    /// A zero-size leaf owns the modal subscription. Its content closure stays
    /// lazy, so the Settings graph (including optional developer tools) is not
    /// constructed during ordinary Home renders.
    private var settingsPresentationHost: some View {
        AtriaSettingsPresentationHost(coordinator: settingsPresentation,
                                      revision: settingsPresentationRevision) {
            AnyView(AtriaSettingsView(profile: model.profileStore.profile,
                              restingBaseline: store.baseline.restingInt,
                              strapName: ble.resolvedDeviceName,
                              strapModel: ble.strapModelLabel,
                              strapGenerationDetail: ble.strapGenerationDetail,
                              strapFirmware: ble.firmwareRevision,
                              onRenameStrap: { ble.setCustomDeviceName($0) },
                              onUpdateProfile: store.updateProfile,
                              hapticSettings: hapticSettings,
                              onUpdateHaptics: { hapticSettings = $0 },
                              heartRateBroadcastEnabled: persistentHeartRateBroadcastEnabled,
                              onUpdateHeartRateBroadcast: {
                                  persistentHeartRateBroadcastEnabled = $0
                                  AtriaHeartRateBroadcastPreference.setEnabled($0)
                              },
                              batterySaverEnabled: ble.standardHROnlyEnabled,
                              onUpdateBatterySaver: { ble.setStandardHROnlyEnabled($0) },
                              onCustomizeToday: {
                                  settingsPresentation.isPresented = false
                                  DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                      showCustomizeSheet = true
                                  }
                              },
                              aiCoachSettings: aiCoachSettings,
                              aiCoachHasAPIKey: aiCoachHasAPIKey,
                              onUpdateAICoachSettings: { aiCoachSettings = $0 },
                              onSaveAICoachAPIKey: { key in
                                  AtriaCoachKeychain.saveAPIKey(key, provider: aiCoachSettings.cloudProvider)
                                  refreshAICoachKeyState()
                              },
                              onDeleteAICoachAPIKey: {
                                  AtriaCoachKeychain.deleteAPIKey(provider: aiCoachSettings.cloudProvider)
                                  refreshAICoachKeyState()
                              },
                              maxHRSuggestion: debugMaxHRSuggestion ?? store.cachedMaxHRSuggestion,
                              onDismissMaxHRSuggestion: { observedPeak in
                                  store.dismissMaxHRSuggestion(observedPeak: observedPeak)
                              },
                              onExportHealth: { store.exportToHealthKit() },
                              buildResearchBundle: { await AtriaResearchBundleBuilder.build(store: store) },
                              buildResearchPreview: { await AtriaResearchBundleBuilder.preview(store: store) },
                              onSyncMissedData: {
                                  ble.requestOfflineHistoricalSyncIfNeeded(reason: "manual_user_request",
                                                                           force: true)
                              },
                              catchUpBoostSuggested: ble.catchUpBoostDecision() == .suggest,
                              catchUpBoostActive: ble.catchUpBoostActive,
                              catchUpBehindText: AtriaCatchUpBoost.behindDescription(
                                  behindSeconds: ble.catchUpBoostBehindSeconds()),
                              onSetCatchUpBoost: { on in
                                  let rest = model.homeStatsStore.state.restingHeartRate
                                  let maxHR = model.profileStore.profile.maxHR
                                  if on {
                                      ble.enableCatchUpBoost(rest: rest, maxHR: maxHR)
                                  } else {
                                      ble.revertCatchUpBoost(rest: rest, maxHR: maxHR,
                                                             reason: "user_off")
                                  }
                              },
                              strapHistoryGapPending:
                                model.collectionLiveStore.state.rangeLossBackfillPending,
                              onStartFreshClearGap: {
                                  ble.startFreshAcceptingMissedDataLoss(
                                      reason: "settings_start_fresh"
                                  )
                              },
                              onNutritionHealthToggle: { store.requestNutritionReadAuthorizationIfEnabled() },
                              backupStatusProvider: { store.sessionBackupStatus() },
                              onWriteBackup: { completion in
                                  store.writeSessionBackupAsync(label: "settings", completion: completion)
                              },
                              onVerifyBackup: { await store.verifyLatestSessionBackup() },
                              onRestoreBackup: { url in
                                  guard await store.restoreSessionBackup(from: url) else { return nil }
                                  return store.sessionBackupStatus()
                              },
                              onForgetStrap: { ble.forgetSavedStrap(reason: "user_settings") },
                              researchValidationContent: developerModeEnabled ? {
                                  AnyView(researchValidationContent)
                              } : nil,
                              onExitDeveloperMode: {
                                  AtriaDeveloperMode.disable()
                                  developerModeEnabled = false
                              }))
        }
        .equatable()
    }

    private var settingsPresentationRevision: AtriaSettingsPresentationRevision {
        let latestRollup = store.dailyRollupHistory.last
        return AtriaSettingsPresentationRevision(
            profile: model.profileStore.profile,
            restingBaseline: store.baseline.restingInt,
            dailyRollupCount: store.dailyRollupHistory.count,
            latestRollupDay: latestRollup?.day,
            latestRollupRecovery: latestRollup?.recovery,
            strapName: ble.resolvedDeviceName,
            strapModel: ble.strapModelLabel,
            strapGenerationDetail: ble.strapGenerationDetail,
            strapFirmware: ble.firmwareRevision,
            hapticSettings: hapticSettings,
            heartRateBroadcastEnabled: persistentHeartRateBroadcastEnabled,
            batterySaverEnabled: ble.standardHROnlyEnabled,
            aiCoachSettings: aiCoachSettings,
            aiCoachHasAPIKey: aiCoachHasAPIKey,
            maxHRSuggestion: debugMaxHRSuggestion ?? store.cachedMaxHRSuggestion,
            developerModeEnabled: developerModeEnabled
        )
    }

    private func handleDeepLink(_ url: URL) {
        if let faceOff = AtriaFaceOff.payload(from: url) {
            AtriaDebugLog("ATRIADBG faceoff_link status=decoded name_len=%d days=%d avg_recovery=%@",
                          faceOff.name.count,
                          faceOff.days.count,
                          faceOff.averageRecovery.map(String.init) ?? "nil")
            incomingFaceOff = faceOff
            hasUnlockedPrimaryContent = true
            return
        }
        if Self.isSleepReviewDeepLink(url) {
            // Land on Overview AND force-present the review/edit sheet for the
            // latest reviewable night, so a "Review your sleep" notification tap
            // always opens something actionable even if the inline card is hidden.
            selectedTab = .overview
            hasUnlockedPrimaryContent = true
            hasUnlockedSecondarySections = true
            switch store.sleepReviewResolutionForUI(rest: store.baseline.restingInt ?? 60,
                                                     source: "notification_sleep_review") {
            case .loading:
                pendingSleepReviewDeepLink = true
                AtriaDebugLog("ATRIADBG deeplink status=waiting target=sleep_review url=%@",
                              url.absoluteString)
            case .ready(let night):
                pendingSleepReviewDeepLink = false
                if let night {
                    sleepReviewSheetRoute = AtriaSleepReviewSheetRoute(night: night)
                }
                AtriaDebugLog("ATRIADBG deeplink status=handled target=sleep_review has_night=%d url=%@",
                              night == nil ? 0 : 1,
                              url.absoluteString)
            }
            return
        }
        guard let tab = HomeTab.deepLinkDestination(for: url) else { return }
#if DEBUG
        if url.absoluteString.lowercased().contains("heart-rate-timeline") {
            UserDefaults.standard.set(true, forKey: AtriaHealthScreen.debugOpenHeartRateTimelineKey)
        }
#endif
        if tab == .collection {
            showStrapScreen = true
        } else if tab == .chat {
            showAssistant = true
        } else {
            selectedTab = tab
        }
        hasUnlockedPrimaryContent = true
        if tab != .overview {
            hasUnlockedSecondarySections = true
        }
        if tab == .collection {
            model.loadDeferredDiagnosticsIfNeeded(reason: "deeplink_\(tab.deepLinkPath)")
        }
        AtriaDebugLog("ATRIADBG deeplink status=handled target=%@ url=%@",
                      tab.deepLinkPath,
                      url.absoluteString)
    }

    private func drainPendingNotificationDeepLink() {
        guard let url = AtriaNotificationDeepLinkInbox.shared.consume(
            sceneIsActive: scenePhase == .active
        ) else { return }
        handleDeepLink(url)
    }

    private func schedulePendingNotificationDeepLinkDrain() {
        notificationDeepLinkDrainTask?.cancel()
        notificationDeepLinkDrainTask = Task { @MainActor in
            // Let the foreground/launch transaction commit before changing the
            // root TabView selection. If the scene is not active, retain the
            // URL; the active scene edge schedules another drain.
            await Task.yield()
            guard !Task.isCancelled else { return }
            drainPendingNotificationDeepLink()
            notificationDeepLinkDrainTask = nil
        }
    }

    private func resolvePendingSleepReviewDeepLinkIfNeeded(
        publishedNight: SleepHistorySnapshot.Night?
    ) {
        guard pendingSleepReviewDeepLink else { return }
        switch store.sleepReviewResolutionForUI(rest: store.baseline.restingInt ?? 60,
                                                source: "notification_sleep_review_ready") {
        case .loading:
            return
        case .ready:
            // @Published delivers the new value from willSet, before the
            // backing property itself changes. Use the emitted candidate so a
            // cold-cache resolution cannot observe the previous nil value and
            // accidentally clear the pending route.
            pendingSleepReviewDeepLink = false
            if let night = publishedNight {
                sleepReviewSheetRoute = AtriaSleepReviewSheetRoute(night: night)
            }
            AtriaDebugLog("ATRIADBG deeplink status=resolved target=sleep_review has_night=%d",
                          publishedNight == nil ? 0 : 1)
        }
    }

    private static func isSleepReviewDeepLink(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "atria" else { return false }
        let pieces = ([url.host].compactMap { $0 } + url.pathComponents.filter { $0 != "/" })
            .map { $0.lowercased() }
        return pieces.contains("sleep-review") || pieces.contains("sleep")
    }

    private func postDebugNotificationDeepLinkIfRequested(arguments: [String] = ProcessInfo.processInfo.arguments) {
#if DEBUG
        guard arguments.contains("--atria-test-notification-deeplink-overview"),
              let url = URL(string: "atria://overview") else { return }
        AtriaDebugLog("ATRIADBG notification_deeplink_fixture status=posted url=%@",
                      url.absoluteString)
        Task { @MainActor in
            _ = AtriaNotificationDeepLinkInbox.shared.enqueue(
                url,
                responseKey: "debug|\(UUID().uuidString)"
            )
        }
#endif
    }

    private func enableDebugHeartRateBroadcastIfRequested(arguments: [String] = ProcessInfo.processInfo.arguments) {
#if DEBUG
        guard arguments.contains("--atria-test-hr-broadcast") else { return }
        persistentHeartRateBroadcastEnabled = true
        AtriaDebugLog("ATRIADBG hr_broadcast_fixture status=enabled persistent=1")
        updateHeartRateBroadcastState(reason: "debug_fixture")
#endif
    }

    private func triggerDebugStrainTargetHapticIfRequested(arguments: [String] = ProcessInfo.processInfo.arguments) {
#if DEBUG
        guard arguments.contains("--atria-test-strain-target-haptic") else { return }
        AtriaDebugLog("ATRIADBG haptic_alert_fixture kind=strain_target status=requested")
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            hapticCoordinator.update(AtriaHapticAlertCoordinator.Snapshot(status: .connected,
                                                                          isRecording: true,
                                                                          heartRate: 120,
                                                                          maxHR: 190,
                                                                          restingHR: 60,
                                                                          batteryLevel: 85,
                                                                          recoveryPercent: 68,
                                                                          recoveryIsReadyForAlert: true,
                                                                          strain: 12.4,
                                                                          strainTarget: 12.0,
                                                                          settings: AtriaHapticAlertSettings()))
        }
#endif
    }

    private var contentWidth: CGFloat {
        horizontalSizeClass == .regular ? 1120 : 720
    }

    private var shouldShowLiveAccessory: Bool {
#if DEBUG
        if Self.debugShowsMinimizedWorkout(arguments: ProcessInfo.processInfo.arguments) {
            return true
        }
#endif
        return workoutSession != nil && liveWorkoutMinimized
    }

    private var liveWorkoutPresentationBinding: Binding<Bool> {
        Binding {
            isSecuringWorkoutStart || (workoutSession != nil && !liveWorkoutMinimized)
        } set: { presented in
            if !presented, workoutSession != nil {
                liveWorkoutMinimized = true
            }
        }
    }

    private var workoutActivityTypeBinding: Binding<AtriaWorkoutActivityType> {
        Binding {
            workoutSession?.activityType ?? .other
        } set: { newType in
            workoutSession?.activityType = newType
            persistPendingWorkoutProgress()
            if let session = workoutSession, newType.supportsRouteRecording {
                workoutRouteRecorder.start(activityType: newType, startedAt: session.start)
                if workoutRouteRecorder.snapshot.isPaused {
                    workoutRouteRecorder.resume()
                }
            } else {
                // A temporary type change must not erase an outdoor route the
                // user has already recorded. Park location collection; resume
                // it if they switch back, or discard only when a non-route
                // workout is actually ended.
                workoutRouteRecorder.pause()
            }
            updateLiveActivity()
        }
    }

    /// The active session is the single owner of a workout target override.
    /// A committed picker edit is checkpointed immediately so minimizing the
    /// HUD or restoring after process termination preserves the same target.
    private var workoutTargetChoiceBinding: Binding<AtriaWorkoutTargetChoice?> {
        Binding {
            workoutSession?.targetChoice
        } set: { newChoice in
            guard var session = workoutSession else { return }
            session.setTargetChoice(newChoice)
            workoutSession = session
            persistPendingWorkoutProgress()
            updateLiveActivity()
        }
    }

    /// Equatable projection used only to synchronize the durable workout intent
    /// into the BLE sensor lifecycle. It is independent of full-screen workout
    /// presentation, so minimizing/reopening cannot reset or duplicate alerts.
    private struct WorkoutZoneHapticConfiguration: Equatable {
        let workoutStartedAt: Date
        let lowerTargetZone: Int?
        let upperTargetZone: Int?
        let maxHR: Int
        let restingHR: Int
        let isPaused: Bool
    }

    private var workoutZoneHapticConfiguration: WorkoutZoneHapticConfiguration? {
        guard let workoutSession else { return nil }
        return WorkoutZoneHapticConfiguration(
            workoutStartedAt: workoutSession.start,
            lowerTargetZone: workoutSession.lowerTargetZone,
            upperTargetZone: workoutSession.upperTargetZone,
            maxHR: workoutSession.calculationContext?.maximumHeartRate
                ?? store.profile.maxHR,
            // Same resting reference the live zone bar renders with, so the
            // target haptic fires at the exact HR-reserve BPM the user sees.
            restingHR: store.baseline.restingInt ?? 60,
            isPaused: liveWorkoutPauseStartedAt != nil
        )
    }

    /// Hydrated, all-day strap coordinate used for every foreground workout
    /// boundary. It deliberately bypasses the asynchronously published Home
    /// projection so a cold-start Start/Pause/Resume cannot observe a partial
    /// saved prefix.
    private func currentWorkoutStepCoordinate(
        sourceVersion: AtriaWorkoutStepSourceVersion = .strapAccelerometerV1,
        now: Date
    ) -> AtriaWorkoutStepCoordinate? {
        if sourceVersion == .strapGyroCadenceAmbulatoryV1 {
            return ble.ambulatoryWorkoutGyroStepCoordinate(now: now)
        }
        guard store.hasLoadedSavedSessions else { return nil }
        let saved = store.workoutSavedStepPrefix(
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
            hasContinuousValidatedMotion: ble.hasContinuousValidatedWorkoutMotion(now: now),
            now: now
        )
    }

    /// The user's tap is an interactive deadline, not a request to wait until
    /// the detector FIFO becomes available. `synchronizeCurrentR10...` cleans
    /// up a late boundary when cancelled; this wrapper independently resumes
    /// the UI when the deadline wins.
    private func synchronizedWorkoutMotionBoundary(
        timeout: Duration = .milliseconds(250)
    ) async -> Date? {
        let deadline = AtriaWorkoutMotionBoundaryDeadline()
        return await withCheckedContinuation { continuation in
            deadline.install(continuation)
            let synchronization = Task { @MainActor in
                let value = await ble.synchronizeCurrentR10MotionAccounting()
                deadline.finish(value)
            }
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                deadline.finish(nil)
                synchronization.cancel()
            }
        }
    }

    /// Bound the cold authority check at the Start tap.  The sheet pre-warms
    /// it, so this is normally an immediate snapshot read.  If the app is
    /// still restoring a large store, fail explicitly rather than hold an
    /// interactive control for the store's old eight-second wait (or longer
    /// when its I/O queue was occupied).  No unpersisted workout is ever
    /// presented as started.
    private func prepareWorkoutStartAuthority(
        timeout: Duration = .seconds(1)
    ) async -> Bool {
        let deadline = AtriaWorkoutStartAuthorityDeadline()
        return await withCheckedContinuation { continuation in
            deadline.install(continuation)
            let preparation = Task { @MainActor in
                deadline.finish(await AtriaPendingWorkoutIntent.preparePersistence())
            }
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                deadline.finish(false)
                // `prepare()` only hydrates a read-only snapshot. Cancelling
                // the waiter cannot cancel its serial disk operation, and we
                // intentionally let that operation warm a retry.
                preparation.cancel()
            }
        }
    }

    private func workoutStepLedgerIsReadyForStart(
        timeoutSeconds: TimeInterval = 1
    ) async -> Bool {
        await store.waitForDeferredSessionLoadIfNeeded(timeoutSeconds: timeoutSeconds)
        return store.hasLoadedSavedSessions
    }

    private func makeWorkoutSession(
        configuration: AtriaWorkoutStartConfiguration = .init()
    ) async -> AtriaWorkoutSession? {
        let requestedUptime = ProcessInfo.processInfo.systemUptime
        // The foreground Start button must use the same merged all-day
        // coordinate as headless controls. On a cold launch the UI projection
        // can publish before sessions.json finishes decoding, so await that
        // authority rather than anchoring against a connection-local count.
        guard await workoutStepLedgerIsReadyForStart() else {
            AtriaDebugLog("ATRIADBG live_workout_start status=deferred_session_hydration_unavailable action=fail_fast_retry_after_warm")
            return nil
        }
        // Starting the workout is more important than obtaining a perfectly
        // current step boundary. A reconnect/history transition can hold the
        // R10 boundary briefly; never let that make the Start button appear
        // dead. The persisted workout starts at the tap and step evidence stays
        // explicitly incomplete until fresh strap motion arrives.
        let stepBoundaryAt = await synchronizedWorkoutMotionBoundary()
        if stepBoundaryAt == nil {
            AtriaDebugLog("ATRIADBG live_workout_start status=step_boundary_unavailable action=fail_open_start_at_tap_time")
        }
        // The workout clock and all-day step anchor begin together after the
        // saved prefix is authoritative. Otherwise steps arriving during a
        // slow cold-start decode would be consumed by the anchor while the
        // session misleadingly claimed an earlier start time.
        let start = Date()
        let gyroCoordinate = ble.ambulatoryWorkoutGyroStepCoordinate(now: start)
        let stepSourceVersion = AtriaWorkoutStepSourceVersion.frozen(
            for: configuration.activityType,
            gyroCoordinate: gyroCoordinate
        )
        guard let stepCoordinate = currentWorkoutStepCoordinate(
            sourceVersion: stepSourceVersion,
            now: start
        ) else {
            AtriaDebugLog("ATRIADBG live_workout_start status=step_coordinate_unavailable")
            return nil
        }
        let calculationContext = AtriaWorkoutCalculationContext(
            restingHeartRate: store.baseline.restingInt ?? 60,
            profile: store.profile
        )
        let session = AtriaWorkoutSession(start: start,
                                          targetStrain: configuration.targetStrain,
                                          lowerTargetZone: configuration.lowerTargetZone,
                                          upperTargetZone: configuration.upperTargetZone,
                                          activityType: configuration.activityType,
                                          stepSourceVersion: stepSourceVersion,
                                          startingStepCount: stepCoordinate.cumulativeCount,
                                          startingDayStrain: model.heroStore.state.strain,
                                          calculationContext: calculationContext)
        let intent = AtriaPendingWorkoutIntent(startedAt: session.start,
                                               endedAt: nil,
                                               activityType: session.activityType.rawValue,
                                               strengthSets: [],
                                               excludedIntervals: [],
                                               pauseStartedAt: nil,
                                               targetStrain: session.targetStrain,
                                               targetZone: session.targetZone,
                                               lowerTargetZone: session.lowerTargetZone,
                                               upperTargetZone: session.upperTargetZone,
                                               startingStepCount: session.startingStepCount,
                                               stepSourceVersion: session.stepSourceVersion,
                                               pausedStepCount: session.pausedStepCount,
                                               pauseStartedStepCount: session.pauseStartedStepCount,
                                               stepAccountingIsComplete: session.stepAccountingIsComplete,
                                               startingDayStrain: session.startingDayStrain,
                                               calculationContext: session.calculationContext)
        guard await intent.createPersisted(), AtriaPendingWorkoutIntent.load() == intent else {
            AtriaDebugLog("ATRIADBG live_workout_start status=intent_persistence_failed")
            return nil
        }
        AtriaDebugLog("ATRIADBG live_workout_start_latency phase=intent_durable elapsed_ms=%d",
                      Int(((ProcessInfo.processInfo.systemUptime - requestedUptime) * 1_000).rounded()))
        workoutPersistenceRevision = intent.persistenceRevision
        // Seal the pre-workout all-day segment at the persisted exact start so
        // no later save can relabel it. The commit runs off the start tap so a
        // large all-day journal cannot delay the workout UI; correctness does
        // not depend on it finishing first, because the end-path ownership
        // guard fails closed (keeps the all-day label) whenever the buffer
        // still starts before the persisted workout start.
        let boundaryStart = session.start
        Task { @MainActor in
            if !(await ble.commitWorkoutStartSessionBoundary(startedAt: boundaryStart)) {
                AtriaDebugLog("ATRIADBG live_workout_start status=start_boundary_persist_failed action=retain_all_day_journal")
            }
        }
        ble.beginWorkoutMotionLease(startedAt: session.start, reason: "workout_start")
        return session
    }

    @discardableResult
    private func beginWorkoutSession(configuration: AtriaWorkoutStartConfiguration = .init(),
                                     finalizeRetriesRemaining: Int = 2) async -> Bool {
        let requestedUptime = ProcessInfo.processInfo.systemUptime
        guard workoutSession == nil else { return false }
        guard await prepareWorkoutStartAuthority() else {
            AtriaDebugLog("ATRIADBG live_workout_start status=intent_authority_unavailable action=fail_fast_retry_after_warm")
            showWorkoutStartPersistenceError = true
            return false
        }
        if let pending = AtriaPendingWorkoutIntent.load() {
            if pending.endedAt == nil {
                // An open workout owns the singleton intent. Restore it instead
                // of overwriting its exact start, sets, pauses and step anchor.
                restoreOrFinalizePendingWorkoutIntent()
                return false
            }
            // A previous *ended* segment still occupies the single crash-safe
            // slot because its confirm+clear runs async behind a large-store
            // flush. Refusing here silently dropped the next segment on
            // 2026-08-21 (Walk→Strength recorded nothing until a force-quit).
            // Finalize the previous workout INLINE first — its metadata-only
            // save needs no strap, so it clears the slot even when the link
            // dropped during the transition — then continue into the new
            // segment. The recovered workout stays in history.
            await finalizePendingWorkoutIntent(pending, showFailureNotice: false)
            if AtriaPendingWorkoutIntent.load()?.endedAt != nil {
                // Still occupied — rare transient I/O. Retry the inline finalize
                // a couple of times before falling back, so the new segment is
                // never lost to a slow flush.
                if finalizeRetriesRemaining > 0 {
                    try? await Task.sleep(for: .milliseconds(400))
                    guard workoutSession == nil else { return false }
                    return await beginWorkoutSession(
                        configuration: configuration,
                        finalizeRetriesRemaining: finalizeRetriesRemaining - 1
                    )
                }
                // Persistent failure: keep the crash-safe record, retry recovery
                // unbounded (no force-quit needed), and tell the user plainly.
                workoutEndNotice = .retained(
                    title: "Finishing previous workout",
                    message: "Atria is still saving your last workout. It will finish automatically — try starting again in a moment. Nothing was lost."
                )
                schedulePendingWorkoutRecoveryRetries()
                return false
            }
            // Slot freed — fall through and start the new segment below.
        }
        // `liveWorkoutStrengthHistory` is prepared while the activity picker
        // is visible. Starting with `.empty` is safe if the user taps before
        // that best-effort projection completes: it only suppresses historical
        // PR context briefly; it cannot alter workout timing, sets or steps.
        guard let session = await makeWorkoutSession(configuration: configuration) else {
            showWorkoutStartPersistenceError = true
            return false
        }
        workoutSession = session
        AtriaDebugLog("ATRIADBG live_workout_start_latency phase=ui_session_published elapsed_ms=%d",
                      Int(((ProcessInfo.processInfo.systemUptime - requestedUptime) * 1_000).rounded()))
        synchronizeWorkoutZoneHaptics(workoutZoneHapticConfiguration)
        if session.activityType.supportsRouteRecording {
            // The activity picker commits its type before the workout exists,
            // so the binding's later type-change hook does not run here. Start
            // Core Location explicitly for an initially selected outdoor type.
            workoutRouteRecorder.start(activityType: session.activityType,
                                        startedAt: session.start)
        }
        return true
    }

    /// Prepares strength-only display context off the main actor while the
    /// activity picker is open. The immutable `SavedSession` snapshot keeps
    /// the projection coherent even if live capture appends a later session.
    /// This deliberately does not await from the Start button.
    private func prewarmLiveWorkoutStrengthHistory() {
        liveWorkoutStrengthHistoryPreparationTask?.cancel()
        let preparationID = UUID()
        liveWorkoutStrengthHistoryPreparationID = preparationID
        let sessions = store.sessions
        liveWorkoutStrengthHistoryPreparationTask = Task { @MainActor [sessions] in
            let projection = await Task.detached(priority: .userInitiated) {
                AtriaStrengthLog.historyProjection(in: sessions)
            }.value
            guard !Task.isCancelled,
                  preparationID == liveWorkoutStrengthHistoryPreparationID else {
                return
            }
            liveWorkoutStrengthHistory = projection
        }
    }

    private func persistPendingWorkoutProgress(endedAt: Date? = nil) {
        guard let session = workoutSession else { return }
        workoutPersistenceRevision &+= 1
        let intent = AtriaPendingWorkoutIntent(startedAt: session.start,
                                  endedAt: endedAt,
                                  activityType: session.activityType.rawValue,
                                  strengthSets: liveWorkoutLoggedSets,
                                  excludedIntervals: liveWorkoutExcludedIntervals,
                                  pauseStartedAt: liveWorkoutPauseStartedAt,
                                  targetStrain: session.targetStrain,
                                  targetZone: session.targetZone,
                                  lowerTargetZone: session.lowerTargetZone,
                                  upperTargetZone: session.upperTargetZone,
                                  startingStepCount: session.startingStepCount,
                                  stepSourceVersion: session.stepSourceVersion,
                                  pausedStepCount: session.pausedStepCount,
                                  pauseStartedStepCount: session.pauseStartedStepCount,
                                  stepAccountingIsComplete: session.stepAccountingIsComplete,
                                  startingDayStrain: session.startingDayStrain,
                                  calculationContext: session.calculationContext,
                                  persistenceRevision: workoutPersistenceRevision)
        AtriaPendingWorkoutIntentStore.shared.enqueueProgress(intent) { saved in
            guard !saved else { return }
            let current = AtriaPendingWorkoutIntent.load()
            // Rejection is expected when a newer checkpoint or terminal End
            // already won. Only a still-missing revision is an I/O failure.
            guard current?.startedAt == intent.startedAt,
                  current?.endedAt == nil,
                  (current?.persistenceRevision ?? 0) < intent.persistenceRevision else { return }
            AtriaDebugLog("ATRIADBG live_workout_progress status=atomic_checkpoint_failed revision=%llu",
                          intent.persistenceRevision)
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                guard AtriaPendingWorkoutIntent.load()?.endedAt == nil else { return }
                let retried = await intent.persistProgress()
                if !retried,
                   (AtriaPendingWorkoutIntent.load()?.persistenceRevision ?? 0)
                    < intent.persistenceRevision {
                    AtriaDebugLog("ATRIADBG live_workout_progress status=atomic_checkpoint_retry_failed revision=%llu",
                                  intent.persistenceRevision)
                }
            }
        }
    }

    private func toggleLiveWorkoutPause() {
        let paused = liveWorkoutPauseStartedAt == nil
        Task { @MainActor in
            guard let actionAt = await ble.synchronizeCurrentR10MotionAccounting() else {
                AtriaDebugLog("ATRIADBG live_workout_pause status=step_boundary_unavailable")
                return
            }
            setLiveWorkoutPaused(paused, at: actionAt)
        }
    }

    private func setLiveWorkoutPaused(_ paused: Bool, at date: Date) {
        guard var session = workoutSession else { return }
        let actionCoordinate = currentWorkoutStepCoordinate(
            sourceVersion: session.stepSourceVersion,
            now: date
        )
        let hasLiveActionCoordinate = actionCoordinate?.isLiveForCompletion == true
        if paused {
            guard liveWorkoutPauseStartedAt == nil else { return }
            liveWorkoutPauseStartedAt = date
            session.pauseStartedStepCount = hasLiveActionCoordinate
                ? actionCoordinate?.cumulativeCount : nil
            if !hasLiveActionCoordinate {
                session.stepAccountingIsComplete = false
            }
            workoutRouteRecorder.pause(at: date)
        } else {
            guard let started = liveWorkoutPauseStartedAt else { return }
            let ended = max(date, started)
            if let pauseStartedStepCount = session.pauseStartedStepCount,
               hasLiveActionCoordinate,
               session.stepAccountingIsComplete,
               let currentStepCount = actionCoordinate?.cumulativeCount {
                let pauseSteps = max(0,
                                     currentStepCount - pauseStartedStepCount)
                session.pausedStepCount += pauseSteps
            } else {
                session.stepAccountingIsComplete = false
            }
            session.pauseStartedStepCount = nil
            // This method writes the complete pause transaction immediately.
            // Suppress the array observer's duplicate JSON checkpoint.
            suppressNextExcludedIntervalPersistence = true
            liveWorkoutExcludedIntervals.append(ExcludedInterval(start: started, end: ended))
            liveWorkoutPauseStartedAt = nil
            workoutRouteRecorder.resume(at: ended)
        }
        workoutSession = session
        mirrorLiveWorkoutStateToJournal()
        persistPendingWorkoutProgress()
        synchronizeWorkoutZoneHaptics(workoutZoneHapticConfiguration)
        updateLiveActivity()
    }

    private func mirrorLiveWorkoutStateToJournal(now: Date = Date()) {
        var intervals = liveWorkoutExcludedIntervals
        if let pauseStartedAt = liveWorkoutPauseStartedAt {
            intervals.append(ExcludedInterval(start: pauseStartedAt,
                                              end: max(now, pauseStartedAt)))
        }
        try? ActiveSessionJournal.mirrorStrengthState(strengthSets: liveWorkoutLoggedSets,
                                                      excludedIntervals: intervals)
    }

    /// Reconciles presentation state after the app-lifetime runtime has already
    /// committed a Lock Screen command. This is intentionally not the command
    /// owner: it never claims queue files and never precedes canonical saves.
    private func synchronizeWorkoutUIWithCanonicalIntent() {
        guard let pending = AtriaPendingWorkoutIntent.load() else { return }

        if pending.endedAt != nil {
            ble.endWorkoutMotionLease(reason: "canonical_intent_terminal")
            if workoutSession?.start == pending.startedAt {
                workoutSession = nil
                liveWorkoutLoggedSets = []
                liveWorkoutExcludedIntervals = []
                liveWorkoutPauseStartedAt = nil
                liveWorkoutMinimized = false
                synchronizeWorkoutZoneHaptics(nil)
                // The canonical owner has already committed the terminal
                // intent. Push that edge immediately so the Lock Screen cannot
                // remain visually active while final session assembly runs.
                updateLiveActivity(forceActivityWrite: true)
            }
            // Final workout construction can require the deferred sensor
            // archive. The terminal intent remains authoritative if suspension
            // interrupts this task; normal launch recovery retries it.
            Task { @MainActor in
                await store.waitForDeferredSessionLoadIfNeeded()
                restoreOrFinalizePendingWorkoutIntent(showFailureNotice: false)
                schedulePendingWorkoutRecoveryRetries()
            }
            return
        }

        guard var session = workoutSession else {
            restoreOrFinalizePendingWorkoutIntent(showFailureNotice: false)
            return
        }
        guard session.start == pending.startedAt else { return }
        session.targetStrain = pending.targetStrain
        session.targetZone = pending.targetZone
        session.lowerTargetZone = pending.lowerTargetZone
        session.upperTargetZone = pending.upperTargetZone
        session.activityType = pending.resolvedActivityType
        session.pausedStepCount = pending.pausedStepCount
        session.pauseStartedStepCount = pending.pauseStartedStepCount
        session.stepAccountingIsComplete = pending.stepAccountingIsComplete
        session.calculationContext = pending.calculationContext ?? session.calculationContext
        workoutSession = session
        liveWorkoutLoggedSets = pending.strengthSets
        liveWorkoutExcludedIntervals = pending.excludedIntervals
        liveWorkoutPauseStartedAt = pending.pauseStartedAt
        workoutPersistenceRevision = pending.persistenceRevision
        synchronizeWorkoutZoneHaptics(workoutZoneHapticConfiguration)
        updateLiveActivity(forceActivityWrite: true)
    }

    private func restoreOrFinalizePendingWorkoutIntent(showFailureNotice: Bool = true) {
        guard workoutSession == nil,
              let pending = AtriaPendingWorkoutIntent.load() else { return }
        if pending.endedAt != nil {
            Task { @MainActor in
                await finalizePendingWorkoutIntent(pending,
                                                   showFailureNotice: showFailureNotice)
            }
            return
        }

        liveWorkoutLoggedSets = pending.strengthSets
        liveWorkoutStrengthHistory = AtriaStrengthLog.historyProjection(in: store.sessions)
        liveWorkoutExcludedIntervals = pending.excludedIntervals
        liveWorkoutPauseStartedAt = pending.pauseStartedAt
        liveWorkoutMinimized = true
        workoutSession = AtriaWorkoutSession(start: pending.startedAt,
                                              targetStrain: pending.targetStrain,
                                              targetZone: pending.targetZone,
                                              lowerTargetZone: pending.lowerTargetZone,
                                              upperTargetZone: pending.upperTargetZone,
                                              activityType: pending.resolvedActivityType,
                                              stepSourceVersion: pending.stepSourceVersion,
                                              startingStepCount: pending.startingStepCount,
                                              pausedStepCount: pending.pausedStepCount,
                                              pauseStartedStepCount: pending.pauseStartedStepCount,
                                              stepAccountingIsComplete: pending.stepAccountingIsComplete,
                                              startingDayStrain: pending.startingDayStrain,
                                              calculationContext: pending.calculationContext)
        workoutPersistenceRevision = pending.persistenceRevision
        // Restored open workout: re-adopt the persisted motion ownership
        // lease (idempotent for the same start; a repeated lifecycle callback
        // on the same connection cannot resend the activation pair).
        ble.beginWorkoutMotionLease(startedAt: pending.startedAt,
                                    reason: "workout_restore")
        synchronizeWorkoutZoneHaptics(workoutZoneHapticConfiguration)
        if pending.resolvedActivityType.supportsRouteRecording {
            workoutRouteRecorder.start(activityType: pending.resolvedActivityType,
                                        startedAt: pending.startedAt)
            if let pauseStartedAt = pending.pauseStartedAt {
                workoutRouteRecorder.pause(at: pauseStartedAt)
            }
        }
    }

    private func finalizePendingWorkoutIntent(_ pending: AtriaPendingWorkoutIntent,
                                              showFailureNotice: Bool) async {
        guard let endedAt = pending.endedAt else { return }
        let recoveredRouteDraft = await workoutRouteRecorder.finalizedDraft(
            startedAt: pending.startedAt,
            activityType: pending.resolvedActivityType,
            endedAt: endedAt
        )
        // A newer workout may have replaced or cleared the singleton intent
        // while the route journal was being decoded on its utility queue.
        guard AtriaPendingWorkoutIntent.load() == pending else { return }
        let calculationContext = pending.calculationContext
        let rest = calculationContext?.restingHeartRate
            ?? store.baseline.restingInt
            ?? model.heroStore.state.restingHeartRate
        if let confirmed = await store.confirmWorkoutWindowForUIAsync(start: pending.startedAt,
                                                                end: endedAt,
                                                                rest: rest,
                                                                maxHR: calculationContext?.maximumHeartRate
                                                                    ?? store.profile.maxHR,
                                                                source: "pending_live_workout_recovery",
                                                                preserveUserDeclaredActivityWithoutHeartRate: true,
                                                                activityType: pending.resolvedActivityType == .other ? nil : pending.activityType,
                                                                strengthSets: pending.strengthSets,
                                                                excludedIntervals: pending.finalizedExcludedIntervals(),
                                                                workoutSteps: pending.completedStepCount,
                                                                workoutStepsAreEstimated: pending.completedStepsAreEstimated,
                                                                workoutStepsCapturedAt: pending.completedStepsCapturedAt) {
                let recoveredRouteArtifact: AtriaWorkoutRouteStore.PreparedShareArtifact?
                let routeDurable: Bool
                if let recoveredRouteDraft {
                    let prepared = await AtriaWorkoutRouteStore.savePreparedShareArtifactAsync(
                        recoveredRouteDraft,
                        workoutID: confirmed.id
                    )
                    routeDurable = prepared.routeWasPersisted
                    // Preserve recovery semantics: unlike an immediately ended
                    // workout, a route that is still retrying is not presented
                    // as attached merely because its in-memory draft survived.
                    recoveredRouteArtifact = prepared.routeWasPersisted ? prepared : nil
                } else {
                    recoveredRouteArtifact = nil
                    routeDurable = true
                }
                if routeDurable,
                   await AtriaPendingWorkoutIntent.clearIfUnchanged(pending) {
                    workoutRouteRecorder.discardDurableCheckpoint()
                }
                if showFailureNotice || routeDurable {
                    workoutEndNotice = .persisted(
                        workout: confirmed,
                        snapshot: workoutShareSnapshot(
                            for: confirmed,
                            routeArtifact: recoveredRouteArtifact
                        ),
                        title: routeDurable ? "Workout recovered" : "Workout saved",
                        message: routeDurable
                            ? "Atria restored \(formatWorkoutDuration(confirmed.duration)) from the saved workout window."
                            : "The workout is safe. Atria is still retrying its route attachment.",
                        routeState: routeDurable ? .ready : .attaching
                    )
                }
        } else if showFailureNotice {
            workoutEndNotice = .retained(
                title: "Workout safely retained",
                message: "The workout window is saved locally and will be retried when more strap evidence is available.",
                activityType: pending.resolvedActivityType,
                duration: endedAt.timeIntervalSince(pending.startedAt)
            )
        }
    }

    private func schedulePendingWorkoutRecoveryRetries() {
        pendingWorkoutRecoveryTask?.cancel()
        guard AtriaPendingWorkoutIntent.load()?.endedAt != nil else {
            pendingWorkoutRecoveryTask = nil
            return
        }
        // A terminal intent that hasn't confirmed+cleared must not require a
        // force-quit to resolve (2026-08-21 report). The bounded [2,10,30]s
        // schedule gave up after ~42s; a strap that reconnects a minute later
        // then stayed wedged. Retry with exponential backoff (capped at 5 min)
        // for as long as the ended intent survives and this view is alive.
        // confirm is idempotent by workout ID and clearIfUnchanged is a CAS, so
        // racing the runtime's own launch/scene recovery is safe.
        pendingWorkoutRecoveryTask = Task { @MainActor in
            defer { pendingWorkoutRecoveryTask = nil }
            var delay: TimeInterval = 2
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    return
                }
                guard !Task.isCancelled,
                      let terminal = AtriaPendingWorkoutIntent.load(),
                      terminal.endedAt != nil,
                      workoutSession == nil else { return }
                await finalizePendingWorkoutIntent(terminal, showFailureNotice: false)
                delay = min(delay * 2, 5 * 60)
            }
        }
    }

    private func reopenMinimizedWorkout() {
        guard workoutSession != nil else { return }
        liveWorkoutMinimized = false
    }

    /// Memoizes the merged side-effect publishers. Building them in a computed
    /// property recreated them on EVERY body evaluation, which tore down the
    /// onReceive subscription and reset the 750 ms throttle each time — under
    /// churny invalidation the throttle never gated and the side-effect work
    /// (Live Activity, widget snapshot, haptics) ran per-tick on main.
    private final class AtriaHomePublisherCache {
        var liveActivity: AnyPublisher<Void, Never>?
        var haptics: AnyPublisher<Void, Never>?
        var liveWidget: AnyPublisher<Void, Never>?
        var liveStepWidget: AnyPublisher<Void, Never>?
        var workoutDetection: AnyPublisher<Void, Never>?
        var batteryWidgetUpdates: AnyPublisher<Void, Never>?
        var connectionDiagnosis: AnyPublisher<Void, Never>?
    }

    @State private var publisherCache = AtriaHomePublisherCache()

    private var liveActivityUpdates: AnyPublisher<Void, Never> {
        if let cached = publisherCache.liveActivity { return cached }
        let publisher = Publishers.MergeMany([
            model.coreLiveStore.$state.map { _ in () }.eraseToAnyPublisher(),
            model.pulseLiveStore.$state.map { _ in () }.eraseToAnyPublisher(),
            model.heroStore.$state.map { _ in () }.eraseToAnyPublisher(),
            ble.$liveStrapStepCountCapturedAt.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            Self.strainTargetGuidanceTimer.map { _ in () }.eraseToAnyPublisher()
        ])
        .throttle(for: .milliseconds(750), scheduler: RunLoop.main, latest: true)
        .eraseToAnyPublisher()
        publisherCache.liveActivity = publisher
        return publisher
    }

    private var hapticUpdates: AnyPublisher<Void, Never> {
        if let cached = publisherCache.haptics { return cached }
        let publisher = Publishers.MergeMany([
            model.coreLiveStore.$state.map { _ in () }.eraseToAnyPublisher(),
            model.pulseLiveStore.$state.map { _ in () }.eraseToAnyPublisher(),
            model.collectionLiveStore.$state.map { _ in () }.eraseToAnyPublisher(),
            model.heroStore.$state.map { _ in () }.eraseToAnyPublisher()
        ])
        .throttle(for: .milliseconds(750), scheduler: RunLoop.main, latest: true)
        .eraseToAnyPublisher()
        publisherCache.haptics = publisher
        return publisher
    }

    private var liveWidgetUpdates: AnyPublisher<Void, Never> {
        if let cached = publisherCache.liveWidget { return cached }
        let publisher = model.pulseLiveStore.$state
            .map { _ in () }
            .throttle(for: .milliseconds(750), scheduler: RunLoop.main, latest: true)
            .eraseToAnyPublisher()
        publisherCache.liveWidget = publisher
        return publisher
    }

    private var liveStepWidgetUpdates: AnyPublisher<Void, Never> {
        if let cached = publisherCache.liveStepWidget { return cached }
        let publisher = Publishers.CombineLatest(
            model.coreLiveStore.$state.map { state in
                "\(state.strapStepResearchCount)|\(state.strapStepResearchState)"
            },
            ble.$liveStrapStepCountCapturedAt
        )
            .map { countAndState, capturedAt in
                "\(countAndState)|\(capturedAt?.timeIntervalSince1970 ?? 0)"
            }
            .removeDuplicates()
            .map { _ in () }
            .throttle(for: .seconds(5), scheduler: RunLoop.main, latest: true)
            .eraseToAnyPublisher()
        publisherCache.liveStepWidget = publisher
        return publisher
    }

    private var workoutDetectionUpdates: AnyPublisher<Void, Never> {
        if let cached = publisherCache.workoutDetection { return cached }
        let publisher = Publishers.MergeMany([
            model.coreLiveStore.$state.map { _ in () }.eraseToAnyPublisher(),
            model.pulseLiveStore.$state.map { _ in () }.eraseToAnyPublisher(),
            model.heroStore.$state.map { _ in () }.eraseToAnyPublisher()
        ])
        .throttle(for: .milliseconds(750), scheduler: RunLoop.main, latest: true)
        .eraseToAnyPublisher()
        publisherCache.workoutDetection = publisher
        return publisher
    }

    private var batteryWidgetUpdates: AnyPublisher<Void, Never> {
        if let cached = publisherCache.batteryWidgetUpdates { return cached }
        let publisher = Publishers.MergeMany([
            ble.$batteryLevel.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            ble.$batteryChargeStatus.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            ble.$batteryChargeLastVerifiedAt.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            ble.$batteryProjectionRevision.removeDuplicates().map { _ in () }.eraseToAnyPublisher()
        ])
        .map { _ in () }
        .debounce(for: .milliseconds(450), scheduler: RunLoop.main)
        .eraseToAnyPublisher()
        publisherCache.batteryWidgetUpdates = publisher
        return publisher
    }

    private var connectionDiagnosisUpdates: AnyPublisher<Void, Never> {
        if let cached = publisherCache.connectionDiagnosis { return cached }
        let publisher = Publishers.CombineLatest(
            model.coreLiveStore.$state
                .map(AtriaConnectionDiagnosisLiveTrigger.init)
                .removeDuplicates(),
            model.pulseLiveStore.$state
                .map(AtriaConnectionDiagnosisPulseTrigger.init)
                .removeDuplicates()
        )
        .map { _ in () }
        .eraseToAnyPublisher()
        publisherCache.connectionDiagnosis = publisher
        return publisher
    }

    private func scheduleOverviewDiagnosticsKickoff(reason: String,
                                                    delayNanoseconds: UInt64) {
        guard selectedTab == .overview else { return }
        guard !model.snapshotStore.diagnosticsReady else { return }
        guard model.coreLiveStore.state.status == .connected else { return }
        overviewDiagnosticsKickoffTask?.cancel()
        overviewDiagnosticsKickoffTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled else { return }
            guard selectedTab == .overview else { return }
            guard model.coreLiveStore.state.status == .connected else { return }
            model.loadDeferredDiagnosticsIfNeeded(reason: reason)
        }
    }

    private func secondaryUnlockDelayNanoseconds(for status: AtriaBLEManager.Status) -> UInt64 {
        switch status {
        case .connected:
            return 300_000_000
        case .connecting, .scanning:
            return 320_000_000
        case .poweredOff, .disconnected:
            return 180_000_000
        }
    }

    private func consumePendingIntentCommandIfNeeded() {
        guard let command = AtriaIntentCommandStore.consume() else { return }
        switch command {
        case .open(let destination):
            performMotionAwareUpdate {
                switch destination {
                case .today:
                    selectedTab = .overview
                case .vitals:
                    selectedTab = .vitals
                case .journal:
                    selectedTab = .journal
                case .collection:
                    showStrapScreen = true
                }
            }
        case .capture(let command):
            if command == .start && !ble.isRecording {
                ble.toggleRecording()
            } else if command == .stop && ble.isRecording {
                ble.toggleRecording()
            }
            performMotionAwareUpdate {
                showStrapScreen = true
            }
        case .focus(let mode):
            AtriaIntentCommandStore.persistFocusMode(mode)
            let rest = model.homeStatsStore.state.restingHeartRate
            let maxHR = model.profileStore.profile.maxHR
            switch mode {
            case .off:
                ble.setLongWearModeEnabled(false, rest: rest, maxHR: maxHR)
            case .workout:
                ble.setCollectionProfile(.maxCoverage, rest: rest, maxHR: maxHR)
                ble.setLongWearModeEnabled(true, rest: rest, maxHR: maxHR)
            case .sleep:
                ble.setCollectionProfile(.batterySaver, rest: rest, maxHR: maxHR)
                ble.setLongWearModeEnabled(true, rest: rest, maxHR: maxHR)
            }
            performMotionAwareUpdate {
                showStrapScreen = true
            }
        }
    }

    private func applyDebugUIScreenLaunchArgumentIfNeeded(arguments: [String] = ProcessInfo.processInfo.arguments) {
#if DEBUG
        guard !didApplyDebugUIScreenLaunchArgument else { return }
        let requestedScreen: String
        if arguments.contains("--atria-open-settings") {
            requestedScreen = "settings"
        } else if let debugScreen = Self.debugRequestedUIScreen(arguments: arguments) {
            requestedScreen = debugScreen
        } else {
            requestedScreen = "overview"
        }

        let requestedOverviewSegment = Self.debugLaunchOverviewSegmentArgument(arguments: arguments)
        let metricDetailFixtures = ["recovery-detail", "recovery-detail-nutrition", "hrv-detail", "rhr-detail", "respiratory-detail", "sleep-detail", "strain-detail"]
        let shouldOpenMetricDetailFixture = Self.debugLaunchFixtureValue(arguments: arguments).map { metricDetailFixtures.contains($0) } ?? false
        let overviewContentFixtures = ["sleep-plan-bedtime", "north-star-highlights"]
        let shouldShowOverviewFixture = Self.debugLaunchFixtureValue(arguments: arguments).map { overviewContentFixtures.contains($0) } ?? false
        let shouldOpenShareSheet = arguments.contains("--atria-open-share-sheet")
        let shouldOpenCustomizeSheet = arguments.contains("--atria-open-customize")
        let shouldOpenWidgetProof = arguments.contains("--atria-open-widget-proof")
        let shouldOpenConnectionGuide = arguments.contains("--atria-open-connection-guide")
        let shouldOpenJournalSheet = arguments.contains("--atria-open-journal")
        let shouldStartWorkout = arguments.contains("--atria-start-workout")
        let shouldSeedCustomLayout = arguments.contains("--atria-seed-custom-layout")
        let shouldSeedStrengthWorkoutProof = arguments.contains("--atria-seed-strength-workout-proof")
        let shouldOpenHeartRateTimeline = Self.debugLaunchFixtureValue(arguments: arguments) == "heart-rate-timeline"
        let shouldShowConnectivityPillFixture = Self.debugLaunchFixtureValue(arguments: arguments) == "refresh-connectivity-pill"
        guard requestedScreen != "overview"
                || requestedOverviewSegment != nil
                || shouldOpenMetricDetailFixture
                || shouldShowOverviewFixture
                || arguments.contains("--atria-open-settings")
                || shouldOpenShareSheet
                || shouldOpenCustomizeSheet
                || shouldOpenWidgetProof
                || shouldOpenConnectionGuide
                || shouldOpenJournalSheet
                || shouldStartWorkout
                || shouldSeedCustomLayout
                || shouldSeedStrengthWorkoutProof
                || shouldOpenHeartRateTimeline
                || shouldShowConnectivityPillFixture else {
            return
        }

        didApplyDebugUIScreenLaunchArgument = true
        hasUnlockedPrimaryContent = true
        hasUnlockedSecondarySections = true
        if shouldOpenHeartRateTimeline {
            UserDefaults.standard.set(true, forKey: AtriaHealthScreen.debugOpenHeartRateTimelineKey)
        }
        if shouldShowConnectivityPillFixture {
            selectedTab = .overview
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(800))
                await handleConnectivityRefresh()
            }
        }
        if shouldSeedCustomLayout {
            saveHomeLayoutConfig(Self.debugSeededHomeLayoutConfig())
            selectedTab = .overview
        }
        if shouldSeedStrengthWorkoutProof {
            selectedTab = .overview
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(700))
                await store.seedDebugStrengthWorkoutProofIfRequested(arguments: arguments)
            }
        }
        if let requestedOverviewSegment {
            debugInitialOverviewSegment = requestedOverviewSegment
            debugShowsOverviewSegmentContent = true
        }
        if shouldOpenMetricDetailFixture {
            debugShowsOverviewSegmentContent = true
        }
        if shouldShowOverviewFixture {
            debugShowsOverviewSegmentContent = true
        }
        if shouldOpenShareSheet {
            selectedTab = .overview
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(700))
                showShareSheet = true
            }
            return
        }
        if shouldOpenCustomizeSheet {
            selectedTab = .overview
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(700))
                showCustomizeSheet = true
            }
            return
        }
        if shouldOpenWidgetProof {
            selectedTab = .overview
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(700))
                widgetProofSnapshot = WidgetSnapshotPublisher.publish(store: store,
                                                                      ble: ble,
                                                                      reason: "cd11_widget_proof")
                showWidgetProofSheet = true
            }
            return
        }
        if shouldOpenConnectionGuide {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(700))
                showConnectionGuide = true
            }
        }
        if shouldOpenJournalSheet {
            selectedTab = .overview
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(700))
                showJournalSheet = true
            }
        }
        if shouldStartWorkout {
            selectedTab = .overview
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(700))
                liveWorkoutLoggedSets = []
                liveWorkoutExcludedIntervals = []
                liveWorkoutMinimized = false
                _ = await beginWorkoutSession()
            }
        }
        switch requestedScreen {
        case "today", "overview":
            selectedTab = requestedOverviewSegment == .trends ? .vitals : .overview
        case "vitals":
            selectedTab = .vitals
        // Static handoff compatibility marker for the previous debug route:
        // case "data", "collection", "history":
        case "journal":
            selectedTab = .journal
        case "chat":
            showAssistant = true
        // "activity" alias (2026-08-04): the Plan tab IS the Activity Monitor
        // now; the natural name should reach it in the screenshot loop.
        case "plan", "activity":
            selectedTab = .plan
        case "strap", "data", "collection", "history":
            showStrapScreen = true
            model.loadDeferredDiagnosticsIfNeeded(reason: "debug_ui_screen")
        case "settings":
            selectedTab = .overview
            Task { @MainActor in
                for delay in [100, 450, 900] {
                    try? await Task.sleep(for: .milliseconds(delay))
                    settingsPresentation.isPresented = false
                    await Task.yield()
                    settingsPresentation.isPresented = true
                }
            }
        default:
            if requestedOverviewSegment == .trends {
                selectedTab = .vitals
            } else {
                selectedTab = .overview
            }
        }
#endif
    }

    private var debugMaxHRSuggestion: AtriaMaxHRSuggestion? {
#if DEBUG
        guard Self.debugLaunchFixtureValue(arguments: ProcessInfo.processInfo.arguments) == "max-hr-suggestion" else {
            return nil
        }
        return AtriaMaxHRSuggestion(observedPeak: 193, currentMaxHR: 190)
#else
        return nil
#endif
    }

    private static func debugInitialHomeTab(arguments: [String]) -> HomeTab {
        #if DEBUG
        if debugLaunchFixtureValue(arguments: arguments) == "detected-activities" {
            return .vitals
        }
        // The Sleep scope's own screenshot fixture (sleep-scope) already
        // exists in AtriaHealthScreen; it just needs the root tab routed the
        // same way the Trends fixture routes it. Same rationale: neither
        // simctl nor iPhone Mirroring can reliably tap the tab bar.
        if debugLaunchFixtureValue(arguments: arguments) == "sleep-scope" {
            return .vitals
        }
        // Same screenshot-loop rationale as above: neither simctl nor iPhone
        // Mirroring can tap the tab bar, so device marker verification routes
        // the root tab at launch. DEBUG-only; carries no fixture data.
        if debugLaunchFixtureValue(arguments: arguments) == "activity-tab" {
            return .plan
        }
        #endif
        return .overview
    }

    #if DEBUG
    private static func debugLaunchFixtureValue(arguments: [String]) -> String? {
        if let environmentValue = ProcessInfo.processInfo.environment["ATRIA_UI_FIXTURE"],
           !environmentValue.isEmpty {
            return environmentValue
        }
        guard let fixtureIndex = arguments.firstIndex(of: "--atria-ui-fixture") else { return nil }
        let valueIndex = arguments.index(after: fixtureIndex)
        guard arguments.indices.contains(valueIndex) else { return nil }
        return arguments[valueIndex]
    }

    private static func debugWorkoutLoggedSets(arguments: [String]) -> [LoggedSet] {
        guard ["live-workout-set-saved", "live-workout-minimized"].contains(debugLaunchFixtureValue(arguments: arguments) ?? "") else {
            return []
        }
        let now = Date()
        return [
            LoggedSet(exercise: "Barbell bench press",
                      weightKg: 80,
                      reps: 5,
                      rpe: nil,
                      t: now.addingTimeInterval(-95)),
            LoggedSet(exercise: "Barbell bench press",
                      weightKg: 82.5,
                      reps: 5,
                      rpe: nil,
                      t: now.addingTimeInterval(-18))
        ]
    }

    private static func debugWorkoutExcludedIntervals(arguments: [String]) -> [ExcludedInterval] {
        guard debugLaunchFixtureValue(arguments: arguments) == "live-workout-paused" else {
            return []
        }
        let now = Date()
        return [ExcludedInterval(start: now.addingTimeInterval(-420),
                                 end: now.addingTimeInterval(-300))]
    }

    private static func debugShowsMinimizedWorkout(arguments: [String]) -> Bool {
        debugLaunchFixtureValue(arguments: arguments) == "live-workout-minimized"
    }

    private static func debugSeededHomeLayoutConfig() -> AtriaHomeLayoutConfig {
        AtriaHomeLayoutConfig(glanceMetrics: ["sleep", "recovery", "strain"],
                              sizeOverrides: ["sleep": "wideShort"],
                              showLiveStrip: false,
                              showHighlights: false,
                              showPlan: false,
                              showAICoach: false,
                              ringCenterMetric: .sleep,
                              legendStatStyle: .value,
                              accent: .coral)
            .validated()
    }

    private static func debugRequestedUIScreen(arguments: [String]) -> String? {
        if let environmentValue = ProcessInfo.processInfo.environment["ATRIA_UI_SCREEN"],
           !environmentValue.isEmpty {
            return environmentValue.lowercased()
        }
        guard let screenIndex = arguments.firstIndex(of: "--atria-ui-screen") else { return nil }
        let valueIndex = arguments.index(after: screenIndex)
        guard arguments.indices.contains(valueIndex) else { return nil }
        return arguments[valueIndex].lowercased()
    }

    private static func debugDashboardAutoScrollEnabled(arguments: [String]) -> Bool {
        debugLaunchFixtureValue(arguments: arguments) == "dashboard-autoscroll"
            || ProcessInfo.processInfo.environment["ATRIA_DASHBOARD_AUTOSCROLL"] == "1"
    }
    #endif

    #if DEBUG
    private func applyDebugLiveZoneFixtureIfNeeded(arguments: [String] = ProcessInfo.processInfo.arguments) {
        let isLiveZoneFixture = Self.debugLaunchFixtureValue(arguments: arguments) == "live-zone"
        let fixture = Self.debugLaunchFixtureValue(arguments: arguments)
        guard arguments.contains("live-zone")
                || isLiveZoneFixture
                || fixture == "pending-sleep-review"
                || fixture == "pending-sleep-provisional-recovery"
                || ["recovery-detail", "hrv-detail", "rhr-detail", "respiratory-detail", "sleep-detail", "strain-detail"].contains(fixture)
                || fixture == "sleep-plan-bedtime"
                || fixture == "weekly-report" else { return }
        let protectsSleepCapture = arguments.contains("sleep-capture-protected")
        let heartRate = protectsSleepCapture ? 72 : 142
        let rest = 58
        let maxHR = 190
        let zone = Metrics.heartRateZone(bpm: heartRate, rest: rest, max: maxHR)

        hasUnlockedPrimaryContent = true
        hasUnlockedSecondarySections = true

        var status = model.statusStore.state
        status.status = .connected
        status.bluetoothPermissionDenied = false
        model.statusStore.state = status

        var core = model.coreLiveStore.state
        core.status = .connected
        core.deviceName = "WHOOP Strap"
        core.displayDeviceName = "Strap"
        core.batteryLevel = 72
        core.batteryIsCharging = false
        core.batteryChargeStatus = .notCharging
        core.batteryRecentlyDropping = false
        core.sessionSampleCount = 742
        core.hasRecentHeartRateSample = true
        core.liveTRIMP = protectsSleepCapture ? 2.4 : 26
        core.liveActiveCalories = protectsSleepCapture ? 32 : 186
        core.lastScanMatchAt = Date()
        core.pendingKnownReconnectStartedAt = nil
        core.pendingKnownReconnectReason = ""
        core.rangeLossBackfillPending = protectsSleepCapture
        model.coreLiveStore.state = core

        model.heroPulseStore.state = AtriaHomeModel.HeroPulseState(heartRate: heartRate,
                                                                    hasContact: true,
                                                                    sensorHasContact: true,
                                                                    heartRateZone: zone,
                                                                    recentRRSamples: Self.debugBreathworkRRSamples())
        model.pulseLiveStore.state = AtriaHomeModel.PulseLiveState(heartRate: heartRate,
                                                                   hasContact: true,
                                                                   sensorHasContact: true,
                                                                   averageHeartRate: 128,
                                                                   peakHeartRate: 151,
                                                                   heartRateZone: zone,
                                                                   recentRRSamples: Self.debugBreathworkRRSamples())
    }

    private func sustainDebugLiveZoneFixtureIfNeeded(arguments: [String] = ProcessInfo.processInfo.arguments) {
        let isLiveZoneFixture = Self.debugLaunchFixtureValue(arguments: arguments) == "live-zone"
        let fixture = Self.debugLaunchFixtureValue(arguments: arguments)
        guard arguments.contains("live-zone")
                || isLiveZoneFixture
                || fixture == "pending-sleep-review"
                || fixture == "pending-sleep-provisional-recovery"
                || ["recovery-detail", "hrv-detail", "rhr-detail", "respiratory-detail", "sleep-detail", "strain-detail"].contains(fixture)
                || fixture == "sleep-plan-bedtime"
                || fixture == "weekly-report" else { return }
        Task { @MainActor in
            for _ in 0..<18 {
                applyDebugLiveZoneFixtureIfNeeded(arguments: arguments)
                try? await Task.sleep(for: .milliseconds(350))
            }
        }
    }

    private static func debugBreathworkRRSamples(now: Date = Date()) -> [AtriaBreathworkSession.RRSample] {
        var output: [AtriaBreathworkSession.RRSample] = []
        var date = now.addingTimeInterval(-180)
        var index = 0
        while date <= now {
            let inFinalMinute = date >= now.addingTimeInterval(-60)
            let base = inFinalMinute ? 930 : 800
            let wave = (index % 6) * (inFinalMinute ? 9 : 4)
            let ms = base + wave
            output.append(AtriaBreathworkSession.RRSample(date: date, ms: ms))
            date = date.addingTimeInterval(Double(ms) / 1000.0)
            index += 1
        }
        return output
    }
    #else
    private func applyDebugLiveZoneFixtureIfNeeded(arguments: [String] = ProcessInfo.processInfo.arguments) {}
    private func sustainDebugLiveZoneFixtureIfNeeded(arguments: [String] = ProcessInfo.processInfo.arguments) {}
    #endif

    private var isDebugUIScreenLaunchActive: Bool {
#if DEBUG
        Self.debugRequestedUIScreen(arguments: ProcessInfo.processInfo.arguments) != nil
            || Self.debugLaunchOverviewSegmentArgument(arguments: ProcessInfo.processInfo.arguments) != nil
            || Self.debugLaunchFixtureValue(arguments: ProcessInfo.processInfo.arguments) != nil
            || ProcessInfo.processInfo.arguments.contains("--atria-open-settings")
            || ProcessInfo.processInfo.arguments.contains("--atria-open-connection-guide")
#else
        false
#endif
    }

    private var debugShowsSleepPlanBedtimeFixture: Bool {
#if DEBUG
        Self.debugLaunchFixtureValue(arguments: ProcessInfo.processInfo.arguments) == "sleep-plan-bedtime"
#else
        false
#endif
    }

    private var debugShowsNorthStarTodayFixture: Bool {
#if DEBUG
        Self.debugLaunchFixtureValue(arguments: ProcessInfo.processInfo.arguments) == "north-star-highlights"
#else
        false
#endif
    }

    private static func debugLaunchOverviewSegmentArgument(arguments: [String] = ProcessInfo.processInfo.arguments) -> AtriaLegacyOverviewDestination? {
#if DEBUG
        guard let segmentIndex = arguments.firstIndex(of: "--atria-ui-overview-segment"),
              arguments.indices.contains(arguments.index(after: segmentIndex)) else { return nil }
        return AtriaLegacyOverviewDestination.debugLaunchValue(from: arguments[arguments.index(after: segmentIndex)])
#else
        return nil
#endif
    }

    private func performMotionAwareUpdate(_ update: () -> Void) {
        if reduceMotion {
            update()
        } else {
            withAnimation(.snappy(duration: AtriaDesignTokens.Motion.standard)) {
                update()
            }
        }
    }

    private func updateHapticCoordinator() {
        hapticCoordinator.update(AtriaHapticAlertCoordinator.Snapshot(
            status: model.coreLiveStore.state.status,
            isRecording: model.collectionLiveStore.state.isRecording,
            heartRate: model.pulseLiveStore.state.heartRate,
            maxHR: model.profileStore.profile.maxHR,
            restingHR: store.baseline.restingInt ?? 60,
            batteryLevel: model.coreLiveStore.state.batteryLevel,
            recoveryPercent: model.heroStore.state.recoveryEstimate.percent,
            recoveryIsReadyForAlert: model.heroStore.state.recoveryEstimate.confidence == .validated
                || model.heroStore.state.recoveryEstimate.confidence == .personalBaseline,
            strain: model.heroStore.state.strain,
            strainTarget: model.heroStore.state.guidance.target,
            settings: hapticSettings
        ))
    }

    private func updateHeartRateBroadcastState(reason: String) {
        let enabled = persistentHeartRateBroadcastEnabled || (workoutSession != nil && workoutHeartRateBroadcastEnabled)
        heartRateBroadcaster.setEnabled(enabled)
        model.setHeartRateBroadcastActive(heartRateBroadcaster.isBroadcasting)
        AtriaDebugLog("ATRIADBG hr_broadcast_ui enabled=%d persistent=%d workout=%d active=%d reason=%@",
                      enabled ? 1 : 0,
                      persistentHeartRateBroadcastEnabled ? 1 : 0,
                      workoutHeartRateBroadcastEnabled ? 1 : 0,
                      heartRateBroadcaster.isBroadcasting ? 1 : 0,
                      reason)
    }

    private func updateLiveWorkoutFreshnessLoop() {
        liveWorkoutFreshnessTask?.cancel()
        liveWorkoutFreshnessTask = nil
        guard workoutSession != nil else { return }
        liveWorkoutFreshnessTask = Task { @MainActor in
            while !Task.isCancelled, workoutSession != nil {
                try? await Task.sleep(for: .seconds(Self.liveWorkoutFreshnessRefreshInterval))
                guard !Task.isCancelled, workoutSession != nil else { return }
                // The accumulator is append-only, so a no-sample tick is O(1).
                // Its purpose is to transition source availability at the
                // timestamp boundary, not to manufacture new metric values.
                updateLiveActivity()
            }
        }
    }

    private func updateLiveActivity(forceActivityWrite: Bool = false) {
        let now = Date()
        let pulse = model.pulseLiveStore.state
        let heartRate = pulse.heartRate
        // The pulse projection already resolved the best available resting-HR
        // authority. Reusing it prevents a baseline-nil Live Activity from
        // silently falling back to 60 bpm and disagreeing with Vitals.
        let zone = pulse.heartRateZone
        let session = workoutSession
        let activityType = session?.activityType ?? .other
        let loadExclusions = AtriaLiveWorkoutTRIMPAccumulator.effectiveExcludedIntervals(
            closedIntervals: liveWorkoutExcludedIntervals,
            openPauseStartedAt: liveWorkoutPauseStartedAt
        )
        let heartRateAvailability = liveWorkoutHeartRateAvailability(now: now)
        let metricProjection = makeLiveWorkoutMetricProjection(session: session,
                                                               now: now,
                                                               excludedIntervals: loadExclusions,
                                                               sensorAvailability: heartRateAvailability)
        let storedDailyStepGoal = UserDefaults.standard.integer(forKey: "atria.target.steps.goal")
        let dailyStepGoal = storedDailyStepGoal > 0 ? storedDailyStepGoal : 8_000
        let dailySteps = model.coreLiveStore.state.dailyStepPresentation
        let displayableBatteryLevel = ble.displayableBatteryLevel(now: now)
        let batteryCapturedAt = [ble.lastVerifiedBatteryLevelAt,
                                 ble.batteryDisplayCorroboratedAt(now: now)]
            .compactMap { $0 }
            .max()
        let batteryAvailability: AtriaLiveSensorAvailability = {
            guard displayableBatteryLevel != nil else { return .unavailable }
            return model.coreLiveStore.state.status == .connected
                ? .live : .reconnecting
        }()
        liveWorkoutMetricStore.publishIfChanged(metricProjection)
        let movingDuration = session.map {
            AtriaWorkoutMovingDuration.project(
                startedAt: $0.start,
                excludedIntervals: liveWorkoutExcludedIntervals,
                pauseStartedAt: liveWorkoutPauseStartedAt,
                now: now
            )
        } ?? 0
        liveActivityCoordinator.update(AtriaLiveActivityCoordinator.Snapshot(
            isRecording: session != nil,
            heartRate: heartRate,
            heartRateCapturedAt: ble.lastAcceptedHeartRateAt,
            sensorHasContact: pulse.sensorHasContact,
            heartRateAvailability: heartRateAvailability,
            strain: model.heroStore.state.strain,
            batteryLevel: displayableBatteryLevel ?? -1,
            batteryCapturedAt: displayableBatteryLevel == nil ? nil : batteryCapturedAt,
            batteryChargeCapturedAt: model.coreLiveStore.state.batteryChargeLastVerifiedAt,
            batteryAvailability: batteryAvailability,
            batteryChargeStatus: model.coreLiveStore.state.batteryChargeStatus,
            readingCount: model.coreLiveStore.state.sessionSampleCount,
            startedAt: session?.start ?? Date(),
            activityName: activityType == .other ? "Workout" : activityType.rawValue,
            activitySystemImage: activityType.icon,
            heartRateZoneIndex: zone?.index,
            heartRateZoneName: zone?.name,
            // Preserve the last source value and source clock in ActivityKit;
            // availability controls whether it is rendered. Clearing both on
            // staleness would erase the useful "last at" provenance.
            steps: metricProjection.steps.count,
            stepsAreEstimated: metricProjection.steps.count != nil
                && metricProjection.steps.isEstimated,
            stepsCapturedAt: metricProjection.steps.capturedAt,
            stepsAvailability: metricProjection.steps.availability,
            // The daily goal uses the same physiological-cycle authority as
            // Home and the widget. Workout-local source freshness must never
            // expose the raw research counter as an all-day total.
            dailySteps: dailySteps.count,
            dailyStepsAreEstimated: dailySteps.count != nil && !dailySteps.isValidated,
            dailyStepsCapturedAt: dailySteps.count == nil ? nil : dailySteps.capturedAt,
            dailyStepsIsLowerBound: dailySteps.count != nil
                && dailySteps.source == .verifiedCanonical
                && dailySteps.completeness == .partial,
            dailyStepGoal: dailyStepGoal,
            workoutStrain: metricProjection.strain,
            workoutStrainCapturedAt: metricProjection.loadIsComplete
                ? ble.lastAcceptedHeartRateAt : nil,
            workoutStrainAvailability: metricProjection.loadIsComplete
                ? heartRateAvailability : .unavailable,
            targetWorkoutStrain: AtriaWorkoutTargetMath.effectiveTarget(
                choice: session?.targetChoice,
                guidanceTarget: model.heroStore.state.guidance.target
            ),
            activeEnergyKilocalories: metricProjection.loadIsComplete
                ? metricProjection.activeCalories : nil,
            targetLowerHeartRateZone: session?.lowerTargetZone,
            targetUpperHeartRateZone: session?.upperTargetZone,
            isPaused: liveWorkoutPauseStartedAt != nil,
            elapsedDuration: movingDuration
        ), forceActivityWrite: forceActivityWrite)
    }

    private func liveWorkoutHeartRateAvailability(now: Date) -> AtriaLiveSensorAvailability {
        let pulse = model.pulseLiveStore.state
        let core = model.coreLiveStore.state
        if pulse.hasPulseSignal,
           pulse.sensorHasContact,
           let capturedAt = ble.lastAcceptedHeartRateAt,
           capturedAt <= now.addingTimeInterval(5),
           now.timeIntervalSince(capturedAt) <= AtriaHomeModel.liveHeartRateFreshnessInterval {
            return .live
        }
        if core.status != .connected
            || core.rangeLossBackfillPending
            || core.isInRecentLiveRecovery(now: now) {
            return .reconnecting
        }
        return ble.lastAcceptedHeartRateAt == nil ? .unavailable : .stale
    }

    private func makeLiveWorkoutMetricProjection(
        session: AtriaWorkoutSession?,
        now: Date,
        excludedIntervals: [ExcludedInterval],
        sensorAvailability: AtriaLiveSensorAvailability
    ) -> AtriaLiveWorkoutMetricProjection {
        guard let session else { return .empty }
        let core = model.coreLiveStore.state
        let selectedCoordinate = currentWorkoutStepCoordinate(
            sourceVersion: session.stepSourceVersion,
            now: now
        )
        let capturedAt = selectedCoordinate?.capturedAt
        let isReconnecting = core.status != .connected
            || core.rangeLossBackfillPending
            || core.isInRecentLiveRecovery(now: now)
        let steps = AtriaLiveWorkoutStepProjection.make(
            totalCount: selectedCoordinate?.cumulativeCount ?? 0,
            startingCount: session.startingStepCount,
            pausedCount: session.pausedStepCount,
            pauseStartedCount: session.pauseStartedStepCount,
            hasStepEvidence: session.stepAccountingIsComplete
                && selectedCoordinate?.isLiveForCompletion == true,
            isValidated: selectedCoordinate?.isEstimated == false,
            capturedAt: capturedAt,
            isReconnecting: isReconnecting,
            now: now
        )
        let calculationContext = session.calculationContext
            ?? AtriaWorkoutCalculationContext(
                restingHeartRate: store.baseline.restingInt ?? 60,
                profile: store.profile
            )
        let sensorMetrics = liveWorkoutTRIMPAccumulator.metrics(
            samples: ble.session,
            startedAt: session.start,
            rest: calculationContext.restingHeartRate,
            maxHR: calculationContext.maximumHeartRate,
            profile: calculationContext.profile,
            excludedIntervals: excludedIntervals
        )
        return AtriaLiveWorkoutMetricProjection(
            strain: Metrics.strain(fromTRIMP: sensorMetrics.trimp),
            activeCalories: sensorMetrics.isComplete ? sensorMetrics.activeCalories : nil,
            steps: steps,
            motion: AtriaLiveWorkoutMotionProjection.make(
                capturedAt: ble.liveStrapMotionCapturedAt.flatMap {
                    $0 >= session.start ? $0 : nil
                },
                hasContinuousValidatedMotion: ble.hasContinuousValidatedWorkoutMotion(now: now),
                isReconnecting: isReconnecting,
                now: now
            ),
            sensorAvailability: sensorAvailability,
            sensorCapturedAt: ble.lastAcceptedHeartRateAt.flatMap {
                $0 >= session.start ? $0 : nil
            },
            hasSensorEvidence: sensorMetrics.hasEvidence,
            loadIsComplete: sensorMetrics.isComplete
        )
    }

    private func completedWorkoutStepEvidence(
        session: AtriaWorkoutSession?,
        now: Date
    ) -> (count: Int, isEstimated: Bool, capturedAt: Date?)? {
        guard let session, session.stepAccountingIsComplete else { return nil }
        guard let coordinate = currentWorkoutStepCoordinate(
            sourceVersion: session.stepSourceVersion,
            now: now
        ),
              coordinate.isLiveForCompletion else { return nil }
        let openPauseSteps = session.pauseStartedStepCount.map {
            max(0, coordinate.cumulativeCount - $0)
        } ?? 0
        let count = max(0,
                        coordinate.cumulativeCount
                            - session.startingStepCount
                            - session.pausedStepCount
                            - openPauseSteps)
        return (count, coordinate.isEstimated, coordinate.capturedAt)
    }

    private func publishLiveWidgetSnapshotIfNeeded(now: Date = Date()) {
        guard scenePhase == .active else { return }
        let heartRate = model.pulseLiveStore.state.heartRate
        if heartRate <= 0 {
            // A zero is a meaningful transition: publish once so widgets clear
            // their previous BPM instead of retaining a stale live reading.
            guard lastLiveWidgetSnapshotHeartRate != nil else { return }
            lastLiveWidgetSnapshotAt = now
            lastLiveWidgetSnapshotHeartRate = nil
            scheduleWidgetSnapshot(reason: "live_signal_cleared")
            return
        }
        let elapsed = lastLiveWidgetSnapshotAt.map { now.timeIntervalSince($0) }
        let meaningfulDelta = lastLiveWidgetSnapshotHeartRate.map {
            abs(heartRate - $0) >= Self.liveWidgetSnapshotMeaningfulBPMDelta
        } ?? true
        let cadenceReady = elapsed.map { $0 >= Self.liveWidgetSnapshotMinimumInterval } ?? true
        let changeReady = meaningfulDelta
            && (elapsed.map { $0 >= Self.liveWidgetSnapshotMeaningfulChangeInterval } ?? true)
        guard cadenceReady || changeReady else {
            return
        }
        lastLiveWidgetSnapshotAt = now
        lastLiveWidgetSnapshotHeartRate = heartRate
        scheduleWidgetSnapshot(reason: cadenceReady ? "live_throttled" : "live_bpm_delta")
    }

    private func scheduleWidgetSnapshot(reason: String) {
        let isLiveOnlyReason = reason == "live_signal_cleared"
            || reason == "live_throttled"
            || reason == "live_bpm_delta"
            || reason == "strap_battery_update"
            || reason == "durable_strap_steps"
        guard workoutSession != nil, isLiveOnlyReason else {
            // Stable dashboard authority (sleep, Recovery, RHR, HRV, layout)
            // must still rebuild during a workout. Laundering it through the
            // live-only patch leaves those fields stale until the workout ends.
            WidgetSnapshotPublisher.schedulePublish(store: store,
                                                     ble: ble,
                                                     reason: reason)
            return
        }
        scheduleLiveSensorWidgetPatch(reason: reason)
    }

    private func scheduleLiveSensorWidgetPatch(
        reason: String,
        forceImmediateTimelineReload: Bool = false,
        delay: Duration = .milliseconds(60)
    ) {
        let core = model.coreLiveStore.state
        let pulse = model.pulseLiveStore.state
        let liveHeartRate = pulse.sensorHasContact && pulse.heartRate > 0
            ? pulse.heartRate
            : nil
        let dailySteps = core.dailyStepPresentation
        let steps = dailySteps.count
        let displayableBatteryLevel = ble.displayableBatteryLevel()
        WidgetSnapshotPublisher.scheduleLiveWorkoutPatch(
            heartRate: liveHeartRate,
            heartRateCapturedAt: liveHeartRate == nil ? nil : ble.lastAcceptedHeartRateAt,
            heartRateZoneIndex: liveHeartRate == nil
                ? nil : pulse.heartRateZone?.index,
            heartRateZoneName: liveHeartRate == nil
                ? nil : pulse.heartRateZone?.name,
            steps: steps,
            stepsAreEstimated: steps != nil
                && (!dailySteps.isValidated
                    || (dailySteps.source == .verifiedCanonical
                        && dailySteps.completeness == .partial)),
            stepsCapturedAt: steps == nil ? nil : dailySteps.capturedAt,
            stepsSource: WidgetSnapshotPublisher.stepSourceIdentifier(dailySteps.source),
            stepsCompleteness: WidgetSnapshotPublisher.stepCompletenessIdentifier(
                dailySteps.completeness
            ),
            stepsCoverageFraction: dailySteps.coverageFraction,
            stepsAuthorityVersion: steps == nil
                ? nil
                : WidgetSnapshotPublisher.qualifiedStepAuthorityVersion,
            // 2026-08-20 (widget-sync RC4, §13.6 pre-render): the live lane
            // carries the same rendered strings the in-app Steps card shows
            // for this exact presentation, so an accepted live patch replaces
            // the pre-rendered text together with the family it describes.
            stepsValueText: steps == nil ? nil : dailySteps.valueText,
            stepsStatusText: steps == nil ? nil : dailySteps.detailText,
            strain: model.heroStore.state.strain,
            strainDetail: model.heroStore.state.strainDetail,
            strainCapturedAt: ble.lastAcceptedHeartRateAt,
            batteryLevel: displayableBatteryLevel,
            batteryCapturedAt: displayableBatteryLevel == nil ? nil : ble.lastVerifiedBatteryLevelAt,
            batteryCorroboratedAt: displayableBatteryLevel == nil
                ? nil : ble.batteryDisplayCorroboratedAt(),
            batteryChargeCapturedAt: displayableBatteryLevel != nil
                && (core.batteryChargeStatus == .charging || core.batteryChargeStatus == .full)
                ? core.batteryChargeLastVerifiedAt : nil,
            batteryChargeStatus: displayableBatteryLevel == nil
                ? AtriaBLEManager.BatteryChargeStatus.levelOnly.rawValue
                : core.batteryChargeStatus.rawValue,
            batteryChargeText: displayableBatteryLevel == nil
                ? AtriaBLEManager.BatteryChargeStatus.levelOnly.label
                : core.batteryChargeStatus.label,
            reason: reason,
            forceImmediateTimelineReload: forceImmediateTimelineReload,
            delay: delay
        )
    }

    private func updateWorkoutDetectionPrompt(now: Date = Date()) {
        guard debugWorkoutDetectionPrompt == nil else {
            setWorkoutDetectionPromptIfChanged(nil)
            return
        }
        guard scenePhase == .active else { return }
        guard workoutSession == nil else {
            setWorkoutDetectionPromptIfChanged(nil)
            return
        }
        guard model.coreLiveStore.state.status == .connected else {
            setWorkoutDetectionPromptIfChanged(nil)
            return
        }
        let heartRate = model.pulseLiveStore.state.heartRate
        let rest = model.homeStatsStore.state.restingHeartRate
        // A dismissal belongs to the current physiological episode, not just a
        // 45-minute timer. Keep it dismissed until HR has genuinely recovered
        // for five minutes; otherwise the same car ride/stress plateau could
        // nag the user again while it is still happening.
        if heartRate - rest < 15 {
            if workoutPromptRecoveryStartedAt == nil {
                workoutPromptRecoveryStartedAt = now
            } else if let recoveryStartedAt = workoutPromptRecoveryStartedAt,
                      now.timeIntervalSince(recoveryStartedAt) >= 5 * 60 {
                workoutPromptSuppressedForCurrentEpisode = false
                workoutPromptDismissedUntil = nil
            }
        } else {
            workoutPromptRecoveryStartedAt = nil
        }
        if workoutPromptSuppressedForCurrentEpisode
            || AtriaWorkoutPromptEvaluator.isInCooldown(dismissedUntil: workoutPromptDismissedUntil, now: now) {
            setWorkoutDetectionPromptIfChanged(nil)
            return
        }
        // Show the same day-strain the hero ring shows (saved + live TRIMP) so
        // the workout prompt never disagrees with the number on the main screen.
        let strain = model.heroStore.state.strain
        let bpmOverRest = max(0, heartRate - rest)
        let motionDecision = AtriaMotionActivityGate.evaluate(motionActivityMonitor.context,
                                                              now: now)
        motionActivityMonitor.recordGateDecision(motionDecision, now: now)
        guard !motionDecision.vetoesWorkoutPrompt else {
            setWorkoutDetectionPromptIfChanged(nil)
            return
        }
        let evaluation = AtriaWorkoutPromptEvaluator.evaluate(samples: ble.session,
                                                             currentHeartRate: heartRate,
                                                             restingHeartRate: rest,
                                                             maxHeartRate: store.profile.maxHR,
                                                             hasContact: model.pulseLiveStore.state.sensorHasContact,
                                                             signalQuality: ble.workoutPromptSignalQuality(now: now),
                                                             now: now)
        let detectedSamples = max(evaluation.longestElevatedBout, evaluation.longestZoneBout)
        let nextPrompt = evaluation.shouldPrompt
            ? AtriaWorkoutDetectionPrompt(heartRate: heartRate,
                                          strain: strain,
                                          samples: detectedSamples,
                                          bpmOverRest: bpmOverRest,
                                          restingHeartRate: rest,
                                          maxHeartRate: store.profile.maxHR,
                                          motionSuggestedActivityType: motionDecision.suggestedActivityType)
            : nil
        setWorkoutDetectionPromptIfChanged(nextPrompt)
    }

    private func setWorkoutDetectionPromptIfChanged(_ nextPrompt: AtriaWorkoutDetectionPrompt?) {
        guard workoutDetectionPrompt != nextPrompt else { return }
        workoutDetectionPrompt = nextPrompt
    }

    #if DEBUG
    private var debugWorkoutReviewDraft: AtriaWorkoutReviewDraft? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let fixtureIndex = arguments.firstIndex(of: "--atria-ui-fixture") else { return nil }
        let valueIndex = arguments.index(after: fixtureIndex)
        guard arguments.indices.contains(valueIndex),
              arguments[valueIndex] == "workout-review-flow" else {
            return nil
        }
        let now = Date()
        return AtriaWorkoutReviewDraft(prompt: AtriaWorkoutDetectionPrompt(heartRate: 142,
                                                                           strain: 6.4,
                                                                           samples: 420,
                                                                           bpmOverRest: 52,
                                                                           restingHeartRate: 60,
                                                                           maxHeartRate: 190),
                                       suggestedStart: now.addingTimeInterval(-42 * 60),
                                       suggestedEnd: now)
    }

    private var debugWorkoutDetectionPrompt: AtriaWorkoutDetectionPrompt? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let fixtureIndex = arguments.firstIndex(of: "--atria-ui-fixture") else { return nil }
        let valueIndex = arguments.index(after: fixtureIndex)
        guard arguments.indices.contains(valueIndex),
              arguments[valueIndex] == "workout-detection"
                || arguments[valueIndex] == "workout-detection-ready"
                || arguments[valueIndex] == "workout-detection-zone-path" else {
            return nil
        }
        let fixture = arguments[valueIndex]
        let ready = fixture == "workout-detection-ready" || fixture == "workout-detection-zone-path"
        return AtriaWorkoutDetectionPrompt(heartRate: 142,
                                           strain: ready ? 9.2 : 6.4,
                                           samples: ready ? 960 : 420,
                                           bpmOverRest: 52,
                                           restingHeartRate: 60,
                                           maxHeartRate: 190)
    }

    private var debugSavedWorkoutReviewCandidate: WorkoutReviewCandidate? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let fixtureIndex = arguments.firstIndex(of: "--atria-ui-fixture") else { return nil }
        let valueIndex = arguments.index(after: fixtureIndex)
        guard arguments.indices.contains(valueIndex),
              arguments[valueIndex] == "saved-workout-review" else {
            return nil
        }
        let now = Date()
        return WorkoutReviewCandidate(id: "debug-saved-workout-review",
                                      start: now.addingTimeInterval(-76 * 60),
                                      end: now.addingTimeInterval(-8 * 60),
                                      kind: .activityCandidate,
                                      confidence: .medium,
                                      duration: 68 * 60,
                                      avgHR: 118,
                                      peakHR: 156,
                                      streamCoveragePercent: 58,
                                      observedDuration: 39 * 60,
                                      droppedGapSeconds: 18 * 60,
                                      maxSampleGap: 11 * 60,
                                      gapCount: 2,
                                      reason: "debug_fixture_saved_workout_review")
    }

    private var debugWorkoutReviewHoldState: WorkoutReviewHoldState? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let fixtureIndex = arguments.firstIndex(of: "--atria-ui-fixture") else { return nil }
        let valueIndex = arguments.index(after: fixtureIndex)
        guard arguments.indices.contains(valueIndex) else { return nil }
        switch arguments[valueIndex] {
        case "workout-review-hold-settle":
            return .waitingForSettle(bpmOverRest: 31)
        case "workout-review-hold-possible":
            return .possibleSignal(reason: "low_coverage_possible_effort")
        default:
            return nil
        }
    }
    #else
    private var debugWorkoutReviewDraft: AtriaWorkoutReviewDraft? { nil }
    private var debugWorkoutDetectionPrompt: AtriaWorkoutDetectionPrompt? { nil }
    private var debugSavedWorkoutReviewCandidate: WorkoutReviewCandidate? { nil }
    private var debugWorkoutReviewHoldState: WorkoutReviewHoldState? { nil }
    #endif

    @discardableResult
    private func endWorkoutSession(startedAt: Date) async -> Bool {
        await endWorkoutSession(startedAt: startedAt,
                          endedAt: Date(),
                          activityType: workoutSession?.activityType ?? .other,
                          strengthSets: [],
                          excludedIntervals: [])
    }

    @discardableResult
    private func endWorkoutSession(startedAt: Date,
                                   endedAt: Date = Date(),
                                   activityType: AtriaWorkoutActivityType,
                                   strengthSets: [LoggedSet],
                                   excludedIntervals: [ExcludedInterval]) async -> Bool {
        let label = "Live workout"
        let endRequestedUptime = ProcessInfo.processInfo.systemUptime
        // Ending a workout must never trap the user: reconnect storms can
        // starve the R10 boundary marker indefinitely (2026-07-15 23:00 IST,
        // repeated dead End taps on the walk home). Wait briefly for the
        // exact marker, then fail open to the tap time — step accounting
        // simply stays marked incomplete rather than inventing counts.
        let motionBoundaryAt = await synchronizedWorkoutMotionBoundary()
        if motionBoundaryAt == nil {
            AtriaDebugLog("ATRIADBG live_workout_end status=step_boundary_unavailable action=fail_open_end_at_tap_time")
        }
        AtriaDebugLog("ATRIADBG live_workout_end_latency phase=motion_boundary elapsed_ms=%d",
                      Int(((ProcessInfo.processInfo.systemUptime - endRequestedUptime) * 1_000).rounded()))
        let endedAt = max(endedAt, motionBoundaryAt ?? endedAt)
        let strapStepEvidence = completedWorkoutStepEvidence(session: workoutSession, now: endedAt)
        let strapEvidence: AtriaCompletedWorkoutStepEvidence? = strapStepEvidence.map {
            AtriaCompletedWorkoutStepEvidence(count: $0.count,
                                               isEstimated: $0.isEstimated,
                                               capturedAt: $0.capturedAt)
        }
        AtriaDebugLog("ATRIADBG live_workout_end_latency phase=step_evidence elapsed_ms=%d",
                      Int(((ProcessInfo.processInfo.systemUptime - endRequestedUptime) * 1_000).rounded()))
        // A missing dense strap boundary stays unavailable; phone motion is
        // never promoted into a wrist-derived workout total.
        let stepEvidence = AtriaCompletedWorkoutStepEvidence.select(strap: strapEvidence)
        workoutPersistenceRevision &+= 1
        let finalIntent = AtriaPendingWorkoutIntent(
            startedAt: startedAt,
            endedAt: endedAt,
            activityType: activityType.rawValue,
            strengthSets: strengthSets,
            excludedIntervals: excludedIntervals,
            pauseStartedAt: liveWorkoutPauseStartedAt,
            targetStrain: workoutSession?.targetStrain,
            targetZone: workoutSession?.targetZone,
            lowerTargetZone: workoutSession?.lowerTargetZone,
            upperTargetZone: workoutSession?.upperTargetZone,
            startingStepCount: workoutSession?.startingStepCount ?? 0,
            stepSourceVersion: workoutSession?.stepSourceVersion ?? .strapAccelerometerV1,
            pausedStepCount: workoutSession?.pausedStepCount ?? 0,
            pauseStartedStepCount: workoutSession?.pauseStartedStepCount,
            stepAccountingIsComplete: workoutSession?.stepAccountingIsComplete ?? false,
            completedStepCount: stepEvidence?.count,
            completedStepsAreEstimated: stepEvidence?.isEstimated,
            completedStepsCapturedAt: stepEvidence?.capturedAt,
            startingDayStrain: workoutSession?.startingDayStrain ?? 0,
            calculationContext: workoutSession?.calculationContext,
            persistenceRevision: .max
        )
        // Persist the user's intent before touching the live journal or UI. If
        // any later write fails, launch recovery can rebuild this exact window.
        // Keep the normal state-owned checkpoint first, then normalize the
        // terminal pause below. This preserves the established lifecycle
        // checkpoint contract while making the completed record authoritative.
        guard let finalIntent = await finalIntent.persistTerminal() else {
            AtriaDebugLog("ATRIADBG live_workout_end status=terminal_intent_save_failed started_unix=%d",
                          Int(startedAt.timeIntervalSince1970.rounded()))
            return false
        }
        AtriaDebugLog("ATRIADBG live_workout_end_latency phase=terminal_intent_durable elapsed_ms=%d",
                      Int(((ProcessInfo.processInfo.systemUptime - endRequestedUptime) * 1_000).rounded()))
        // The workout stopped successfully: release the strap motion ownership
        // lease and cancel its bounded activation tasks.
        ble.endWorkoutMotionLease(reason: "workout_end")
        let finalizedExcludedIntervals = finalIntent.finalizedExcludedIntervals()
        // Give the tap immediate visual acknowledgement. The durable pending
        // intent above remains the crash-recovery authority while the ordered
        // route/session/workout writes finish just after the dismissal frame.
        workoutSession = nil
        synchronizeWorkoutZoneHaptics(nil)
        liveWorkoutLoggedSets = []
        liveWorkoutExcludedIntervals = []
        liveWorkoutPauseStartedAt = nil
        liveWorkoutMinimized = false
        AtriaDebugLog("ATRIADBG live_workout_end_latency phase=ui_release_authorized elapsed_ms=%d",
                      Int(((ProcessInfo.processInfo.systemUptime - endRequestedUptime) * 1_000).rounded()))
        Task { @MainActor in
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(50))
        let routeDraft: AtriaWorkoutRouteRecorder.Draft?
        if finalIntent.resolvedActivityType.supportsRouteRecording {
            routeDraft = workoutRouteRecorder.stop(at: endedAt)
        } else {
            workoutRouteRecorder.cancel()
            routeDraft = nil
        }
        let checkpointed = await ble.checkpointCurrentSession(
            label: label,
            reason: "live_workout_end",
            strengthSets: finalIntent.strengthSets,
            excludedIntervals: finalizedExcludedIntervals,
            notBefore: finalIntent.startedAt
        )
        // checkpointCurrentSession already schedules this revision. Do not
        // force an eager full-store write here: once that write starts it
        // cannot be cancelled, and the completion-aware flush below would
        // serialize the same large store again. The exact pending intent stays
        // armed until that single awaited flush succeeds.
        let calculationContext = finalIntent.calculationContext
        let rest = calculationContext?.restingHeartRate
            ?? store.baseline.restingInt
            ?? model.heroStore.state.restingHeartRate
        let confirmed = await store.confirmWorkoutWindowForUIAsync(start: startedAt,
                                                        end: endedAt,
                                                        rest: rest,
                                                        maxHR: calculationContext?.maximumHeartRate
                                                            ?? store.profile.maxHR,
                                                        source: "live_workout_end",
                                                        preserveUserDeclaredActivityWithoutHeartRate: true,
                                                        activityType: finalIntent.resolvedActivityType == .other
                                                            ? nil
                                                            : finalIntent.activityType,
                                                        strengthSets: finalIntent.strengthSets,
                                                        excludedIntervals: finalizedExcludedIntervals,
                                                        workoutSteps: finalIntent.completedStepCount,
                                                        workoutStepsAreEstimated: finalIntent.completedStepsAreEstimated,
                                                        workoutStepsCapturedAt: finalIntent.completedStepsCapturedAt)
        if let confirmed {
            store.exportToHealthKit()
            if let routeDraft {
                AtriaWorkoutRouteStore.savePreparedShareArtifactAsync(
                    routeDraft,
                    workoutID: confirmed.id
                ) { preparedRoute in
                    guard preparedRoute.routeWasPersisted else {
                        schedulePendingWorkoutRecoveryRetries()
                        workoutEndNotice = .persisted(
                            workout: confirmed,
                            snapshot: workoutShareSnapshot(
                                for: confirmed,
                                routeArtifact: preparedRoute
                            ),
                            title: "Workout saved",
                            message: "Atria saved the workout and will finish its route details automatically.",
                            routeState: .attaching
                        )
                        return
                    }
                    store.flushScheduledPersistenceAsync(reason: "live_workout_end_confirmed") { succeeded in
                        guard succeeded else {
                            schedulePendingWorkoutRecoveryRetries()
                            return
                        }
                        Task { @MainActor in
                            if await AtriaPendingWorkoutIntent.clearIfUnchanged(finalIntent) {
                                workoutRouteRecorder.discardDurableCheckpoint()
                            }
                        }
                    }
                    workoutEndNotice = .persisted(
                        workout: confirmed,
                        snapshot: workoutShareSnapshot(
                            for: confirmed,
                            routeArtifact: preparedRoute
                        ),
                        title: "Workout saved",
                        message: workoutCompletionMessage(confirmed)
                    )
                }
            } else {
                store.flushScheduledPersistenceAsync(reason: "live_workout_end_confirmed") { succeeded in
                    guard succeeded else {
                        schedulePendingWorkoutRecoveryRetries()
                        return
                    }
                    Task { @MainActor in
                        if await AtriaPendingWorkoutIntent.clearIfUnchanged(finalIntent) {
                            workoutRouteRecorder.discardDurableCheckpoint()
                        }
                    }
                }
                workoutEndNotice = .persisted(
                    workout: confirmed,
                    snapshot: workoutShareSnapshot(for: confirmed),
                    title: "Workout saved",
                    message: workoutCompletionMessage(confirmed)
                )
            }
        } else if checkpointed {
            workoutSession = nil
            liveWorkoutLoggedSets = []
            liveWorkoutExcludedIntervals = []
            liveWorkoutPauseStartedAt = nil
            liveWorkoutMinimized = false
            workoutEndNotice = .retained(
                title: "Workout safely retained",
                message: "Atria saved this exact workout window and will retry it from the local strap evidence.",
                activityType: activityType,
                duration: endedAt.timeIntervalSince(startedAt)
            )
            schedulePendingWorkoutRecoveryRetries()
        } else {
            workoutSession = nil
            liveWorkoutLoggedSets = []
            liveWorkoutExcludedIntervals = []
            liveWorkoutPauseStartedAt = nil
            liveWorkoutMinimized = false
            workoutEndNotice = .retained(
                title: "Workout safely retained",
                message: "The workout window is saved locally even though heart-rate evidence has not arrived yet.",
                activityType: activityType,
                duration: endedAt.timeIntervalSince(startedAt)
            )
            schedulePendingWorkoutRecoveryRetries()
        }

        AtriaDebugLog("ATRIADBG live_workout_end checkpointed=%d confirmed=%d started_unix=%d",
              checkpointed ? 1 : 0,
              confirmed == nil ? 0 : 1,
              Int(startedAt.timeIntervalSince1970.rounded()))
        AtriaDebugLog("ATRIADBG live_workout_end_latency phase=background_completion_published elapsed_ms=%d",
                      Int(((ProcessInfo.processInfo.systemUptime - endRequestedUptime) * 1_000).rounded()))
        }
        return true
    }

    private func workoutShareSnapshot(for workout: UserConfirmedWorkout,
                                      routeArtifact: AtriaWorkoutRouteStore.PreparedShareArtifact? = nil) -> AtriaWorkoutShareSnapshot {
        let shareMetrics = AtriaWorkoutMetricPresentation.shareMetrics(workout)
        let zoneKeys = ["warmup", "fatBurn", "aerobic", "anaerobic", "max"]
        let zoneTints = ["#56d7ff", "#42f59b", "#f5d142", "#ff8a3d", "#ff4f7b"]
        let zones = shareMetrics.includesZoneMinutes ? zoneKeys.enumerated().map({ offset, key in
            AtriaWorkoutShareSnapshot.ZoneMinute(
                id: offset + 1,
                label: "Z\(offset + 1)",
                minutes: Int(((workout.zoneSeconds?[key] ?? 0) / 60).rounded()),
                tintHex: zoneTints[offset]
            )
        }) : []
        let activity = AtriaWorkoutActivityType.resolved(activityType: workout.activityType,
                                                         subtype: workout.activitySubtype,
                                                         label: workout.label)
        return AtriaWorkoutShareSnapshot(
            date: workout.end,
            activity: workout.activitySubtype ?? workout.activityType ?? workout.label,
            duration: formatWorkoutDuration(workout.duration),
            strain: shareMetrics.strain,
            peakHeartRate: shareMetrics.peakHeartRate,
            zoneMinutes: zones,
            averageHeartRate: shareMetrics.averageHeartRate,
            distance: routeArtifact.map { workoutShareDistance($0.distanceMeters) },
            pace: routeArtifact?.averagePaceSecondsPerKilometer.map(workoutSharePace),
            steps: workoutShareSteps(count: workout.workoutSteps,
                                     isEstimated: workout.workoutStepsAreEstimated,
                                     capturedAt: workout.workoutStepsCapturedAt,
                                     workoutEndedAt: workout.end,
                                     activity: activity),
            activitySystemImage: AtriaActivityDisplayIcon.icon(
                activityType: workout.activityType,
                subtype: workout.activitySubtype,
                label: workout.label
            ),
            routeFileURL: routeArtifact?.routeFileURL,
            routePoints: routeArtifact?.routePoints ?? []
        )
    }

    /// Keep completion copy glanceable and honest. A user-declared workout is
    /// saved even when the strap stream has gaps; the recap must not turn that
    /// success into a technical coverage report or claim an optional Health
    /// export happened. The share card carries the available measured detail.
    private func workoutCompletionMessage(_ workout: UserConfirmedWorkout) -> String {
        let duration = formatWorkoutDuration(workout.duration)
        if AtriaWorkoutMetricPresentation.metricsAreIncomplete(workout) {
            return "\(duration) saved. Heart-rate details will update if more strap data arrives."
        }
        return "\(duration) saved and ready to share."
    }

    private func workoutShareSteps(count: Int?,
                                   isEstimated: Bool?,
                                   capturedAt: Date?,
                                   workoutEndedAt: Date,
                                   activity: AtriaWorkoutActivityType) -> String? {
        AtriaWorkoutSharePresentation.completedStepsText(
            count: count,
            isEstimated: isEstimated,
            capturedAt: capturedAt,
            workoutEndedAt: workoutEndedAt,
            activity: activity
        )
    }

    private func workoutShareDistance(_ meters: Double) -> String {
        meters >= 1_000 ? String(format: "%.2f km", meters / 1_000) : "\(Int(meters.rounded())) m"
    }

    private func workoutSharePace(_ seconds: TimeInterval) -> String {
        "\(Int(seconds) / 60):\(String(format: "%02d", Int(seconds) % 60))/km"
    }

    private func presentQueuedWorkoutShareIfNeeded() {
        guard let snapshot = queuedWorkoutShareSnapshot else { return }
        queuedWorkoutShareSnapshot = nil
        completedWorkoutShareReceipt = AtriaWorkoutShareReceipt(snapshot: snapshot)
    }

    private func presentWorkoutReview(prompt: AtriaWorkoutDetectionPrompt, now: Date = Date()) {
        let observedSeconds = TimeInterval(max(60, prompt.evidenceMinutes * 60))
        workoutDetectionPrompt = nil
        workoutReviewHoldState = nil
        workoutReviewDraft = AtriaWorkoutReviewDraft(prompt: prompt,
                                                     suggestedStart: now.addingTimeInterval(-observedSeconds),
                                                     suggestedEnd: now,
                                                     strengthHistory: AtriaStrengthLog.historyProjection(in: store.sessions))
    }

    private func presentWorkoutReview(candidate: WorkoutReviewCandidate) {
        let rest = store.baseline.restingInt ?? model.heroStore.state.restingHeartRate
        let prompt = AtriaWorkoutDetectionPrompt(heartRate: candidate.peakHR,
                                                 strain: 0,
                                                 samples: max(180, Int(candidate.duration.rounded())),
                                                 bpmOverRest: max(0, candidate.peakHR - rest),
                                                 restingHeartRate: rest,
                                                 maxHeartRate: store.profile.maxHR)
        savedWorkoutReviewCandidate = nil
        workoutDetectionPrompt = nil
        workoutReviewHoldState = nil
        workoutReviewDraft = AtriaWorkoutReviewDraft(prompt: prompt,
                                                     suggestedStart: candidate.start,
                                                     suggestedEnd: candidate.end,
                                                     strengthHistory: AtriaStrengthLog.historyProjection(in: store.sessions))
    }

    private func dismissSavedWorkoutReviewCandidate(_ candidate: WorkoutReviewCandidate) {
        UserDefaults.standard.set(candidate.id, forKey: Self.workoutReviewDismissedIDKey)
        rememberDismissedWorkoutReviewCandidate(candidate)
        _ = store.dismissWorkoutCandidate(start: candidate.start, end: candidate.end)
        savedWorkoutReviewCandidate = nil
        workoutReviewHoldState = nil
    }

    private func rememberDismissedWorkoutReviewCandidate(_ candidate: WorkoutReviewCandidate) {
        var ids = dismissedWorkoutReviewCandidateIDs()
        ids.removeAll { $0 == candidate.id }
        ids.insert(candidate.id, at: 0)
        ids = Array(ids.prefix(Self.workoutReviewDismissedIDsLimit))
        UserDefaults.standard.set(ids, forKey: Self.workoutReviewDismissedIDsKey)
        AtriaDebugLog("ATRIADBG workout_review_candidate dismissed id=%@ retained=%d reason=user_marked_not_workout",
                      candidate.id,
                      ids.count)
    }

    private func dismissedWorkoutReviewCandidateIDs() -> [String] {
        let ids = UserDefaults.standard.stringArray(forKey: Self.workoutReviewDismissedIDsKey) ?? []
        if ids.isEmpty,
           let legacyID = UserDefaults.standard.string(forKey: Self.workoutReviewDismissedIDKey),
           !legacyID.isEmpty {
            return [legacyID]
        }
        return ids
    }

    private func workoutReviewCandidateWasDismissed(_ candidate: WorkoutReviewCandidate) -> Bool {
        dismissedWorkoutReviewCandidateIDs().contains(candidate.id)
    }

    private func refreshSavedWorkoutReviewCandidate(reason: String) {
        guard debugWorkoutReviewDraft == nil else { return }
        guard selectedTab == .overview else { return }
        guard workoutSession == nil else {
            savedWorkoutReviewCandidate = nil
            workoutReviewHoldState = nil
            return
        }
        let rest = store.baseline.restingInt ?? model.heroStore.state.restingHeartRate
        let liveBPMOverRest = max(0, model.pulseLiveStore.state.heartRate - rest)
        let candidate = store.latestWorkoutReviewCandidate(rest: rest,
                                                           maxHR: store.profile.maxHR,
                                                           source: reason)
        // The store already enforces a 10-minute post-end settle; only hold on
        // elevated live HR while the candidate window itself is still recent,
        // otherwise an all-day wearer above rest+20 never gets an evaluation.
        if let candidate,
           model.coreLiveStore.state.status == .connected,
           liveBPMOverRest > Self.workoutReviewSettleBPMOverRest,
           Date().timeIntervalSince(candidate.end) < Self.workoutReviewRecentEndHoldSeconds {
            AtriaDebugLog("ATRIADBG workout_review_candidate status=holding source=%@ reason=live_hr_not_settled bpm_over_rest=%d seconds_since_end=%.0f",
                          reason,
                          liveBPMOverRest,
                          Date().timeIntervalSince(candidate.end))
            savedWorkoutReviewCandidate = nil
            workoutReviewHoldState = .waitingForSettle(bpmOverRest: liveBPMOverRest)
            return
        }
        if let candidate, !candidate.isReviewPromptWorthy {
            savedWorkoutReviewCandidate = nil
            workoutReviewHoldState = .possibleSignal(reason: candidate.reason)
        } else if let candidate,
                  workoutReviewCandidateWasDismissed(candidate) {
            savedWorkoutReviewCandidate = nil
            workoutReviewHoldState = nil
        } else {
            savedWorkoutReviewCandidate = candidate
            workoutReviewHoldState = nil
        }
    }

    /// Returns only the canonical workout that the store accepted. The review
    /// sheet never owns a share snapshot: post-save sharing is offered through
    /// `workoutEndNotice` below, using persisted workout metrics and any route
    /// already associated with that exact workout ID.
    @discardableResult
    private func saveWorkoutReview(
        _ result: AtriaWorkoutReviewResult,
        settlingCandidateWindow: (start: Date, end: Date)
    ) async -> UserConfirmedWorkout? {
        let rest = store.baseline.restingInt ?? model.heroStore.state.restingHeartRate
        // user_adjusted semantics (2026-08-01, mirrors sleep's
        // user_adjusted_window): when the user moved either bound of the
        // detected window by a minute or more, the persisted workout records
        // user authorship of the window instead of detector authorship. The
        // save path, settlement of the original detector window, and review
        // lifecycle (reviewSource) are unchanged.
        let windowWasUserAdjusted =
            abs(result.start.timeIntervalSince(settlingCandidateWindow.start)) >= 60
            || abs(result.end.timeIntervalSince(settlingCandidateWindow.end)) >= 60
        let saveSource = windowWasUserAdjusted
            ? "user_adjusted_workout_window"
            : "guided_workout_review"
        let confirmed = await store.confirmWorkoutWindowForUI(start: result.start,
                                                        end: result.end,
                                                        rest: rest,
                                                        maxHR: store.profile.maxHR,
                                                        source: saveSource,
                                                        activityType: result.activityType,
                                                        activitySubtype: result.activitySubtype,
                                                        exerciseNames: result.exerciseNames,
                                                        strengthSets: result.strengthSets,
                                                        reviewSource: "guided_workout_review",
                                                        settlingCandidateWindow: settlingCandidateWindow)
        workoutReviewDraft = nil
        savedWorkoutReviewCandidate = nil
        workoutReviewHoldState = nil
        workoutPromptDismissedUntil = Date().addingTimeInterval(Self.workoutPromptCooldown)

        if let confirmed {
            store.exportToHealthKit()
            scheduleSavedWorkoutReviewNotice(confirmed,
                                             exerciseCount: result.exerciseNames.count)
        } else {
            workoutEndNotice = .retained(
                title: "Workout review kept",
                message: "Atria kept the strap evidence, but that window still needs cleaner coverage before it can become a confirmed workout."
            )
        }
        return confirmed
    }

    /// Defers modal presentation until the save callback has returned and the
    /// review sheet can dismiss cleanly. Route decoding, point downsampling and
    /// GPX generation stay on the route persistence queue; Home receives only
    /// bounded immutable inputs stored under the canonical workout ID.
    private func scheduleSavedWorkoutReviewNotice(_ confirmed: UserConfirmedWorkout,
                                                  exerciseCount: Int) {
        let workoutID = confirmed.id
        Task { @MainActor in
            let routeArtifact = await AtriaWorkoutRouteStore
                .loadPreparedShareArtifactAsync(workoutID: workoutID)
            await Task.yield()
            let exerciseText = exerciseCount == 0 ? "" : " · \(exerciseCount) exercises"
            workoutEndNotice = .persisted(
                workout: confirmed,
                snapshot: workoutShareSnapshot(
                    for: confirmed,
                    routeArtifact: routeArtifact
                ),
                title: "\(confirmed.label) saved",
                message: "\(formatWorkoutDuration(confirmed.duration)) confirmed from strap HR\(exerciseText)."
            )
        }
    }

    private func formatWorkoutDuration(_ duration: TimeInterval) -> String {
        let minutes = max(1, Int((duration / 60).rounded()))
        if minutes < 60 {
            return "\(minutes) min"
        }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours) hr" : "\(hours) hr \(remainder) min"
    }

    private func updateMediaRefreshLoop() {
        let isActive = scenePhase == .active
        let isConnected = model.coreLiveStore.state.status == .connected
        mediaController.setRefreshLoopActive(isActive && isConnected)
    }

    private func handleHomeAppear() {
        model.setScenePresentationActive(scenePhase == .active)
        // UIKit may have delivered a notification response before this view's
        // publisher subscription existed. Schedule the sticky route before
        // optional diagnostics, but apply it only after the active first frame.
        schedulePendingNotificationDeepLinkDrain()
        if scenePhase == .active {
            motionActivityMonitor.start()
        }
        applyDebugUIScreenLaunchArgumentIfNeeded()
        applyDebugLiveZoneFixtureIfNeeded()
        sustainDebugLiveZoneFixtureIfNeeded()
        if workoutReviewDraft == nil, let debugWorkoutReviewDraft {
            workoutReviewDraft = debugWorkoutReviewDraft
        }
        postDebugNotificationDeepLinkIfRequested()
        enableDebugHeartRateBroadcastIfRequested()
        triggerDebugStrainTargetHapticIfRequested()
        // Hydrate the file-backed authority away from the main actor before
        // either restoration or Start is allowed to mutate it.
        Task { @MainActor in
            guard await AtriaPendingWorkoutIntent.preparePersistence() else { return }
            if AtriaPendingWorkoutIntent.load()?.endedAt == nil {
                restoreOrFinalizePendingWorkoutIntent()
            } else {
                await store.waitForDeferredSessionLoadIfNeeded()
                restoreOrFinalizePendingWorkoutIntent()
            }
            schedulePendingWorkoutRecoveryRetries()
        }
        #if DEBUG
        if workoutSession == nil,
           ProcessInfo.processInfo.arguments.contains("--atria-show-workout") {
            let fixture = Self.debugLaunchFixtureValue(arguments: ProcessInfo.processInfo.arguments)
            liveWorkoutLoggedSets = Self.debugWorkoutLoggedSets(arguments: ProcessInfo.processInfo.arguments)
            liveWorkoutExcludedIntervals = Self.debugWorkoutExcludedIntervals(arguments: ProcessInfo.processInfo.arguments)
            liveWorkoutMinimized = Self.debugShowsMinimizedWorkout(arguments: ProcessInfo.processInfo.arguments)
            selectedTab = liveWorkoutMinimized ? .vitals : selectedTab
            Task { @MainActor in
                workoutSession = await makeWorkoutSession()
                if fixture == "live-workout-set-saved" {
                    workoutSession?.activityType = .strength
                    persistPendingWorkoutProgress()
                }
            }
        }
        #endif
        refreshSavedWorkoutReviewCandidate(reason: "home_appear")
        // A review candidate is an in-memory projection, not a persisted row.
        // Prime it explicitly on launch instead of waiting for a notification
        // deep link or a later evidence invalidation to request the cache.
        _ = store.sleepReviewResolutionForUI(
            rest: store.baseline.restingInt ?? 60,
            source: "home_appear"
        )
        presentCoexistenceModalIfNeeded(for: ble.officialAppCoexistenceRisk)
        guard !hasUnlockedPrimaryContent else { return }
        UIDevice.current.isBatteryMonitoringEnabled = true
        batteryState = UIDevice.current.batteryState
        if homeAppearedAt == nil {
            homeAppearedAt = Date()
        }
        ble.setForegroundHighFrequencyDisplayMode(selectedTab == .vitals)
        model.setPulseDetailMode(active: selectedTab == .vitals)
        if !isDebugUIScreenLaunchActive {
            consumePendingIntentCommandIfNeeded()
        }
        refreshAICoachKeyState()
        runCoexistenceSnoozeSelfTestIfRequested()
        updateHeartRateBroadcastState(reason: "home_appear")
        updateMediaRefreshLoop()
        updateLiveActivity()
        updateHapticCoordinator()
        updateConnectionDiagnosisVisibility(reason: "home_appear")
        scheduleAutomaticConnectionSetupIfNeeded(reason: "home_appear",
                                                 delayNanoseconds: 60_000_000)
        hasUnlockedPrimaryContent = true
        logPrimaryContentReadyIfNeeded()
        secondaryUnlockTask?.cancel()
        secondaryUnlockTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: secondaryUnlockDelayNanoseconds(for: model.coreLiveStore.state.status))
            guard !Task.isCancelled else { return }
            hasUnlockedSecondarySections = true
        }
        scheduleOverviewDiagnosticsKickoff(reason: "home_overview_idle",
                                           delayNanoseconds: 6_800_000_000)
        presentConnectionGuideIfNeeded()
    }

    private func handleSelectedTabChange(_ tab: HomeTab) {
        // Activity owns several archive-sized value projections. Keep them
        // current while the tab is visible, but do not rebuild/compare those
        // arrays for every broad dashboard publish while the wearer is on
        // Today, Vitals, Journal, or inside a live workout. Activation requests
        // one coalesced refresh after the tab transition gets its first frame.
        model.setActivityProjectionActive(tab == .plan)
        // Defer radio/diagnostics reconfiguration to the next runloop so the
        // tab transition renders immediately instead of janking while we
        // reconfigure BLE notifications and kick off diagnostics work.
        Task { @MainActor in
            ble.setForegroundHighFrequencyDisplayMode(tab == .vitals)
            model.setPulseDetailMode(active: tab == .vitals)
            if tab != .overview {
                overviewDiagnosticsKickoffTask?.cancel()
                overviewDiagnosticsKickoffTask = nil
                hasUnlockedPrimaryContent = true
                hasUnlockedSecondarySections = true
                if tab == .collection {
                    model.loadDeferredDiagnosticsIfNeeded(reason: "tab_\(tab.rawValue)")
                }
            } else if !model.snapshotStore.diagnosticsReady {
                refreshSavedWorkoutReviewCandidate(reason: "overview_return")
                scheduleOverviewDiagnosticsKickoff(reason: "overview_return_idle",
                                                   delayNanoseconds: 6_800_000_000)
            }
        }
    }

    private func handleHomeScenePhaseChange(_ phase: ScenePhase) {
        // Revoke presentation before any inactive/background edge work. BLE,
        // journals, stress persistence, widgets, and ActivityKit remain owned
        // by their independent bounded lanes below.
        model.setScenePresentationActive(phase == .active)
        updateMediaRefreshLoop()
        guard phase == .active else {
            foregroundResumeTask?.cancel()
            foregroundResumeTask = nil
            foregroundResumeAuthority.cancel()
            connectionDiagnosisPromotionTask?.cancel()
            connectionDiagnosisPromotionTask = nil
            if phase == .background {
                // Schedule the small current/previous-hour stress checkpoint;
                // its protected encoding + fsynced atomic replacement stays on
                // the persistence utility queue and never blocks this edge.
                model.stressMonitorStore.flushHistoryCheckpoint()
                // This view owns the workout's exact type, sets, pause state
                // and route. Checkpoint those at the true background edge;
                // AtriaApp independently owns the broader lifecycle flush.
                if workoutSession != nil {
                    // The scene can be suspended immediately after this edge.
                    // Bypass the normal cadence so the Lock Screen receives
                    // the newest strap metrics before that suspension.
                    updateLiveActivity(forceActivityWrite: true)
                    mirrorLiveWorkoutStateToJournal()
                    persistPendingWorkoutProgress()
                    ble.flushActiveSessionJournal(reason: "explicit_workout_scene_background")
                    // A live workout only changes pulse, steps, strain and
                    // battery here. Rebuilding recovery, sleep, rollups and
                    // the complete widget payload on the main actor competes
                    // with the app-switch animation and made workout resumes
                    // appear frozen. Patch the already-durable snapshot while
                    // preserving every workout checkpoint above.
                    scheduleLiveSensorWidgetPatch(
                        reason: "scene_background_live_workout",
                        forceImmediateTimelineReload: true,
                        delay: .zero
                    )
                } else {
                    // Outside a workout this is a low-frequency durability
                    // edge, so refresh the complete daily projection.
                    WidgetSnapshotPublisher.schedulePublish(store: store,
                                                             ble: ble,
                                                             reason: "scene_background",
                                                             forceImmediateTimelineReload: true,
                                                             delay: .zero)
                }
                if AtriaSceneResumePolicy.shouldStopMotionMonitor(isBackground: true) {
                    motionActivityMonitor.stop()
                }
                flushWorkoutRouteAtBackgroundBoundary()
            }
            return
        }
        schedulePendingNotificationDeepLinkDrain()
        requestForegroundResumeIfNeeded()
    }

    private func requestForegroundResumeIfNeeded() {
        foregroundResumeAuthority.request()
        scheduleForegroundResumeIfNeeded()
    }

    private func scheduleForegroundResumeIfNeeded() {
        guard foregroundResumeTask == nil,
              let ticket = foregroundResumeAuthority.beginIfAuthorized(
                sceneIsActive: scenePhase == .active,
                applicationIsActive:
                    UIApplication.shared.applicationState == .active,
                historicalProjectionIsBackgrounded:
                    AtriaHistoricalProjectionForegroundGate.isBackgrounded
              ) else { return }
        foregroundResumeTask = Task { @MainActor in
            // Let the returning scene draw first. Widget encoding, Keychain reads,
            // sleep settlement and notification scheduling are useful but not
            // prerequisites for the first interactive frame.
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled,
                  foregroundResumeAuthority.isCurrent(ticket) else { return }
            guard AtriaForegroundDeferredWorkAuthority
                .environmentIsAuthorized(
                    sceneIsActive: scenePhase == .active,
                    applicationIsActive:
                        UIApplication.shared.applicationState == .active,
                    historicalProjectionIsBackgrounded:
                        AtriaHistoricalProjectionForegroundGate.isBackgrounded
                ) else {
                foregroundResumeAuthority.deferForLostAuthority(ticket)
                foregroundResumeTask = nil
                return
            }
            // Historical progress is intentionally silent while inactive. Pull
            // only that missed presentation into CoreLive after the returning
            // scene has drawn, without the archive/diagnostic work of forceRefresh.
            model.refreshHistoricalRecoveryPresentationForForeground()
            // Handoff-12 CP2: one bounded stress-continuity reconciliation per
            // foreground return. Minutes the live scorer missed (background,
            // starved MainActor, skipped tick, relaunch) replay from canonical
            // resident evidence through the same v3 kernel; the generation
            // gate and 750 ms debounce keep this to one coalesced worker.
            model.enqueueStressContinuityReconciliation()
            motionActivityMonitor.start()
            // A diagnosis that began before suspension needs one fresh
            // derivation on return. Its persistence gate is then owned by a
            // single deadline task instead of waking the entire Home view
            // every five seconds while the app is otherwise idle.
            updateConnectionDiagnosisVisibility(reason: "scene_foreground_deferred")

            // Live/store publishers already coalesce widget refreshes. A
            // foreground edge must not synchronously rebuild/encode the widget
            // payload on the main actor while the return animation is running.
            // Official-app presence is initialized once, and coach key state is
            // refreshed by the settings/key mutation paths that can change it.
            if !isDebugUIScreenLaunchActive {
                consumePendingIntentCommandIfNeeded()
            }
            if workoutSession != nil {
                // A suspended process may not have delivered the final sensor
                // publisher pulse. Refresh the complete HR/zone/steps/strain/
                // calorie snapshot after the first returning frame, before any
                // sleep/archive settlement work, and let the coordinator's
                // bounded writer coalesce it with an in-flight ActivityKit call.
                updateLiveActivity(forceActivityWrite: true)
            }
            updateHapticCoordinator()

            try? await Task.sleep(for: .milliseconds(520))
            guard !Task.isCancelled,
                  foregroundResumeAuthority.isCurrent(ticket) else { return }
            guard AtriaForegroundDeferredWorkAuthority
                .environmentIsAuthorized(
                    sceneIsActive: scenePhase == .active,
                    applicationIsActive:
                        UIApplication.shared.applicationState == .active,
                    historicalProjectionIsBackgrounded:
                        AtriaHistoricalProjectionForegroundGate.isBackgrounded
                ) else {
                foregroundResumeAuthority.deferForLostAuthority(ticket)
                foregroundResumeTask = nil
                return
            }
            // Morning settlement can scan saved evidence. Keep it outside the
            // app-switch animation; the store still applies its own cadence gate.
            // Never scan the sleep archive while the user is returning to an
            // active workout; workout controls and BLE continuity own this
            // foreground window. The next non-workout foreground can settle it.
            if workoutSession == nil {
                if let settlementLease = AtriaHistoricalProjectionForegroundGate
                    .captureForegroundLease() {
                    store.autoConfirmSleepOnForegroundIfUseful(
                        reason: "scene_foreground_deferred",
                        settlementAuthority: .processForeground(
                            generation: settlementLease.generation
                        ),
                        executionShouldContinue: {
                            AtriaHistoricalProjectionForegroundGate.isCurrent(
                                settlementLease
                            )
                        }
                    )
                }
                _ = store.sleepReviewResolutionForUI(
                    rest: store.baseline.restingInt ?? 60,
                    source: "scene_foreground_deferred"
                )
                // The first live-HR widget publish can race the deferred
                // confirmed-sleep projection load. Republish once after sleep
                // settlement so widgets cannot retain the pre-merge/raw-span
                // duration while Today already shows the canonical effective
                // duration.
                WidgetSnapshotPublisher.schedulePublish(
                    store: store,
                    ble: ble,
                    reason: "scene_foreground_sleep_projection",
                    delay: .milliseconds(80)
                )
                Task { await AtriaResearchUploadQueue.runForegroundCatchUpIfMissed(store: store) }
                let lastJournalActivity = [store.behaviorJournalEntries.map(\.day).max(),
                                           store.journalAnswers.latestActivityDay()]
                    .compactMap { $0 }
                    .max()
                LocalNotificationScheduler.scheduleEveningJournalCheckIn(lastJournalActivity: lastJournalActivity)
                LocalNotificationScheduler.scheduleMorningJournalCheckIn(lastJournalActivity: lastJournalActivity)
                // Observational event pass (2026-08-13): same-day second-sleep
                // prompt, opt-in bedtime wind-down, and the opt-in sync-truth
                // notifications (catch-up complete, parked interval). Reads
                // published state only; every event carries a durable dedup key.
                LocalNotificationScheduler.runEventObservationPass(store: store)
            }
            foregroundResumeAuthority.complete(ticket)
            foregroundResumeTask = nil
        }
    }

    private func flushWorkoutRouteAtBackgroundBoundary() {
        workoutRouteBackgroundLease.begin()
        workoutRouteRecorder.flushCheckpoint(reason: "scene_background") {
            workoutRouteBackgroundLease.end()
        }
    }

    private func refreshAICoachKeyState() {
        aiCoachHasAPIKey = AtriaCoachKeychain.hasAPIKey(provider: aiCoachSettings.cloudProvider)
    }

    private var isDark: Bool {
        colorScheme == .dark
    }

    private var preferredColorScheme: ColorScheme? {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--atria-ui-follow-system-appearance") {
            return nil
        }
#endif
        switch appearanceMode {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    private func shouldShowStandBy(isLandscape: Bool) -> Bool {
        guard isLandscape else { return false }
        guard !AtriaTransientPresentationState.suppressesStandBy else { return false }
        guard model.coreLiveStore.state.status == .connected else { return false }
        guard batteryState == .charging || batteryState == .full else { return false }
        if let standByDismissedUntil, standByDismissedUntil > Date() {
            return false
        }
        return true
    }

    private func tabNavigation<Content: View>(title: String,
                                              showsHero: Bool = true,
                                              @ViewBuilder content: @escaping () -> Content) -> some View {
        NavigationStack {
            AtriaDashboardScrollSurface(showsCompactTodayHeader: title == "Today",
                                        prefersLiveActivityStatus: workoutSession != nil,
                                        refresh: handleConnectivityRefresh,
                                        taskID: debugDashboardAutoScrollTaskID(title: title)) { scrollProxy in
                await runDebugDashboardAutoScrollIfNeeded(proxy: scrollProxy, title: title)
            } content: {
                // This wrapper has only four direct children. Making it lazy
                // nests a LazyVStack around screens (Today, Vitals, Activity)
                // that already own their own lazy content. On a physical
                // iPhone that nested layout stopped extending the ScrollView's
                // reachable content size after the weekly-plan row, leaving
                // every later Today card—including the durable Strap steps
                // receipt—present in the view graph but impossible to scroll
                // to. Keep the outer shell eager and let each screen retain
                // its own bounded/lazy rendering.
                VStack(spacing: 18) {
                    Color.clear
                        .frame(height: 1)
                        .id(Self.debugDashboardScrollTopID)
                    if showsHero && !debugShowsSleepPlanBedtimeFixture {
                        hero
                    }
                    content()
                    Color.clear
                        .frame(height: 1)
                        .id(Self.debugDashboardScrollBottomID)
                }
                .frame(maxWidth: contentWidth)
                // 12pt gutter (user feedback 2026-07-07: "a lot of unused
                // space on the sides" — three inset layers stacked to
                // 44-46pt/side; this is the shared knob).
                .padding(.horizontal, 12)
                // Back to the standard gutter: the 4pt here, and the negative
                // bottom padding on the notice, both existed only to close the
                // void that a floating inset card opened above the greeting.
                // Edge-to-edge chrome ends flush, so content spaces normally.
                .padding(.top, 4)
                .padding(.bottom, scrollBottomClearance)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle(title)
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    topChrome
                    // Full-bleed: the notice spans the width flush against the
                    // chrome above it, so it takes no inset or gap of its own.
                    //
                    // The calibration-progress qualifiers (RHR learning, HRV
                    // calibrating, VO₂ estimating) no longer page through this
                    // pinned band (2026-08-20 declutter R1): each metric's own
                    // tile already discloses the same maturity — HRV/RHR
                    // "Calibrating · night N of 14" and VO₂ "Improving · day
                    // N of M" — so the band carries sync-truth states only.
                    AtriaHomeRecoveryStatusHost(coreLiveStore: model.coreLiveStore)
                    if showConnectivityPill {
                        connectivityPill
                            .padding(.horizontal, 16)
                            .padding(.bottom, 8)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .background {
                    // Occluding scrim (2026-07-08, device-reported): the chrome
                    // band is transparent between the status chip and the icon
                    // buttons, so scrolled content bled through behind them
                    // ("This week", glance rows showing through the pill).
                    //
                    // That scrim was a single gradient sized to the band, opaque
                    // only to 62% of its height. The band is variable-height --
                    // topChrome, plus the recovery-status banner, plus an
                    // optional connectivity pill -- so a PROPORTIONAL stop cannot
                    // reliably cover it. The banner sat inside the 0.62→1.0 fade,
                    // which is exactly where content kept showing through
                    // ("…rain" from the Strain chip beside the status chip,
                    // "This week" rows behind the banner).
                    //
                    // The band is now fully opaque and the dissolve moved below
                    // it at a FIXED height, so the softness no longer comes at
                    // the cost of the band's own occlusion, whatever it contains.
                    Color(.systemBackground)
                        .ignoresSafeArea(edges: .top)
                        .allowsHitTesting(false)
                }
                .overlay(alignment: .bottom) {
                    LinearGradient(
                        colors: [
                            Color(.systemBackground),
                            Color(.systemBackground).opacity(0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 14)
                    // Sits entirely BELOW the band rather than eating into it.
                    .offset(y: 14)
                    .allowsHitTesting(false)
                }
            }
        }
    }

    private var scrollBottomClearance: CGFloat {
        shouldShowLiveAccessory ? 260 : 188
    }

    private static let debugDashboardScrollTopID = "atria-dashboard-scroll-top"
    private static let debugDashboardScrollBottomID = "atria-dashboard-scroll-bottom"

    private func debugDashboardAutoScrollTaskID(title: String) -> String {
#if DEBUG
        Self.debugDashboardAutoScrollEnabled(arguments: ProcessInfo.processInfo.arguments) ? title : "off"
#else
        "off"
#endif
    }

    @MainActor
    private func runDebugDashboardAutoScrollIfNeeded(proxy: ScrollViewProxy, title: String) async {
#if DEBUG
        // Any tab, not just Today. Every tab renders through this same
        // tabNavigation scroll surface, and the Today-only restriction meant
        // below-the-fold content on Vitals, Journal and Activity could not be
        // screenshot-verified at all when the simulator panel is unavailable --
        // simctl can capture but cannot scroll. The task ID is already
        // per-title, so each tab drives its own independent scroll.
        guard Self.debugDashboardAutoScrollEnabled(arguments: ProcessInfo.processInfo.arguments) else { return }
        try? await Task.sleep(for: .milliseconds(900))
        while !Task.isCancelled {
            withAnimation(.easeInOut(duration: 1.45)) {
                proxy.scrollTo(Self.debugDashboardScrollBottomID, anchor: .bottom)
            }
            try? await Task.sleep(for: .milliseconds(1750))
            withAnimation(.easeInOut(duration: 1.45)) {
                proxy.scrollTo(Self.debugDashboardScrollTopID, anchor: .top)
            }
            try? await Task.sleep(for: .milliseconds(1750))
        }
#endif
    }

    /// Context for the Assistant's deterministic answers — the same hero
    /// state the Today screen feeds its coach card.
    private var assistantCoachContext: AtriaCoachContext {
        let hero = model.heroStore.state
        return AtriaCoachContext(guidance: hero.guidance,
                                 strain: hero.strain,
                                 recoveryText: hero.recoveryValue,
                                 hrvText: hero.hrvValue,
                                 stressText: hero.stressValue,
                                 stressMetricTitle: hero.stressMetricTitle,
                                 stressEvidenceMode: hero.stressEvidenceMode,
                                 stressIsHROnlyEstimate: hero.stressDetail
                                    .localizedCaseInsensitiveContains("HR-only"),
                                 baselineSamples: hero.baselineSamples,
                                 sessionsCount: hero.sessionsCount)
    }

    /// Built on demand — the assistant cover opens rarely, so a fresh
    /// last-7 payload is fine (same builder + baselines as the Today card).
    private var assistantCoachPayload: AtriaCoachPayload? {
        AtriaCoachPayload.fromRollups(rollups: Array(store.dailyRollupHistory.prefix(7)),
                                      fallback: assistantCoachContext,
                                      baselines: [
                                          "recovery": .init(low: 0, high: 100),
                                          "strain": .init(low: 0, high: model.heroStore.state.guidance.target ?? 20),
                                          "hrv": .init(low: nil, high: nil),
                                          "rhr": .init(low: nil, high: nil)
                                      ])
    }


    private var topChrome: some View {
        AtriaHomeTopChrome(statusStore: model.statusStore,
                           coreLiveStore: model.coreLiveStore,
                           pulseLiveStore: model.pulseLiveStore,
                           prefersLiveActivityStatus: workoutSession != nil,
                           onShowSettings: {
                               settingsPresentation.isPresented = true
                           },
                           onShowStrap: {
                               showStrapScreen = true
                           },
                           activityStartIsAvailable: workoutSession == nil && !isSecuringWorkoutStart,
                           onStartActivity: {
                               guard workoutSession == nil, !isSecuringWorkoutStart else { return }
                               showWorkoutStartSheet = true
                           },
                           onAddActivity: {
                               showAddActivitySheet = true
                           },
                           onTapStatusWhenNotConnected: {
                               ble.startScan(reason: "home_status_chip")
                           })
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var connectivityPill: some View {
        GlassEffectContainer(spacing: 4) {
            Text(connectivityPillText)
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .glassEffect(.regular, in: .capsule)
                .accessibilityLabel(connectivityPillText)
        }
    }

    private var connectivityPillText: String {
        let live = model.coreLiveStore.state
        // Pull-to-refresh feedback must never render a second battery value or
        // timestamp below the canonical header snapshot. A fresh HR packet can
        // prove connection without refreshing battery, which was how the old
        // lower pill contradicted the header (for example 80% now vs 81% 32m).
        switch live.status {
        case .connected:
            return "Refreshing strap…"
        case .connecting:
            return "Connecting to strap…"
        case .scanning:
            return "Looking for strap…"
        case .poweredOff:
            return "Bluetooth is off"
        case .disconnected:
            return "Strap is disconnected"
        }
    }

    private func handleConnectivityRefresh() async {
        await MainActor.run {
            ble.requestStrapStatusRead(reason: "pull_to_refresh")
            // A refresh is also an explicit request to advance stale strap
            // history. Queue the exact connected-object/epoch lane; the next
            // accepted 2A37 packet mints authority without disconnecting live
            // HR or granting a reason string generic transport authority.
            ble.queueConnectedRawHistoryCatchUpIntent(
                reason: "pull_to_refresh"
            )
            model.forceRefresh()
            showConnectivityPill = true
            connectivityPillTask?.cancel()
            connectivityPillTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(2_500))
                withAnimation(.snappy(duration: AtriaDesignTokens.Motion.standard)) {
                    showConnectivityPill = false
                }
            }
        }
    }

    /// The header owns the outcome of a history transaction; the recovery
    /// surface merely renders that small, already-published truth between the
    /// strap pill and greeting. It intentionally has no action, so a glance at
    /// a pending gap cannot launch another competing recovery attempt.
    private struct AtriaHomeRecoveryStatusHost: View {
        @ObservedObject var coreLiveStore: AtriaHomeModel.CoreLiveStore
        /// Read inside the timeline tick rather than captured as a value, so a
        /// maturing baseline reaches the banner without depending on a
        /// publisher hop from the session store.
        var maturityText: () -> String? = { nil }
        /// HRV matures much more slowly than resting HR (sleep-window-only
        /// qualification), so it gets its own paged card here — the value is
        /// shown wherever it is computable and this row discloses how far the
        /// calibration has to go.
        var hrvMaturityText: () -> String? = { nil }
        /// VO₂ max publishes a visibly preliminary value from 7 qualified RHR
        /// days; this row discloses the remaining calibration (2026-07-31
        /// device review), mirroring the two maturity cards above.
        var vo2MaturityText: () -> String? = { nil }

        /// Refresh the notice set periodically while keeping cards user-
        /// controlled: multiple notices are paged horizontally instead of
        /// silently rotating underneath the user's finger.
        private static let refreshInterval: TimeInterval = 15

        var body: some View {
            TimelineView(.periodic(from: .now, by: Self.refreshInterval)) { context in
                let notices = notices(now: context.date)
                if !notices.isEmpty {
                    GlassEffectContainer(spacing: 10) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            // Page spacing must be >= 2x the 16pt content
                            // margin (2026-07-31 device review: "leaking from
                            // both sides"). Each page is container-width minus
                            // the margins, so a 10pt gap left the neighboring
                            // pages' edges visible inside the margin band on
                            // both sides of the screen; 32pt puts each
                            // neighbor exactly offscreen and keeps the paging
                            // stride equal to the viewport width.
                            LazyHStack(spacing: 32) {
                                ForEach(Array(notices.enumerated()), id: \.offset) { index, status in
                                    HStack(spacing: 8) {
                                        ViewThatFits(in: .horizontal) {
                                            Label(status.title, systemImage: status.symbol)
                                                .fixedSize(horizontal: true, vertical: false)
                                            Label(status.compactTitle, systemImage: status.symbol)
                                                .lineLimit(1)
                                                .minimumScaleFactor(0.82)
                                        }
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.primary)

                                        Spacer(minLength: 0)

                                        if notices.count > 1 {
                                            HStack(spacing: 3) {
                                                ForEach(0..<notices.count, id: \.self) { dot in
                                                    Circle()
                                                        .fill(Color.primary.opacity(dot == index ? 0.55 : 0.18))
                                                        .frame(width: 4, height: 4)
                                                }
                                            }
                                            .accessibilityHidden(true)
                                        }
                                    }
                                    .padding(.horizontal, 12)
                                    .frame(height: 32)
                                    .containerRelativeFrame(.horizontal)
                                    .glassEffect(.regular, in: .rect(cornerRadius: 18))
                                    .accessibilityElement(children: .combine)
                                    .accessibilityLabel(notices.count > 1
                                                        ? "\(status.accessibilityLabel) Notice \(index + 1) of \(notices.count)."
                                                        : status.accessibilityLabel)
                                    .id(index)
                                }
                            }
                            .scrollTargetLayout()
                        }
                        .scrollTargetBehavior(.paging)
                        .contentMargins(.horizontal, 16, for: .scrollContent)
                        .scrollIndicators(.hidden)
                    }
                    .frame(height: 32)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .animation(.snappy(duration: AtriaDesignTokens.Motion.standard), value: coreLiveStore.state.historicalRecoveryPresentation)
        }

        /// Advances on a wall-clock boundary so every rotating banner in the
        /// app lands on the same phase, instead of drifting per view lifetime.
        static func rotationIndex(now: Date, count: Int) -> Int {
            guard count > 1 else { return 0 }
            let step = Int((now.timeIntervalSinceReferenceDate / refreshInterval).rounded(.down))
            return ((step % count) + count) % count
        }

        /// Every actionable or explanatory notice that is true right now, most
        /// actionable first. A healthy live capture stays in the compact strap
        /// chip above; it is a state, not dashboard content worth spending a
        /// full row on.
        private func notices(now: Date) -> [Status] {
            var result: [Status] = []
            if let status = status(now: now) {
                result.append(status)
            }
            if let maturity = maturityText() {
                result.append(Status(title: maturity,
                                     symbol: "chart.line.uptrend.xyaxis",
                                     accessibilityLabel: "\(maturity). Estimates improve as the baseline fills in."))
            }
            if let hrvMaturity = hrvMaturityText() {
                result.append(Status(title: hrvMaturity,
                                     symbol: "waveform.path.ecg",
                                     accessibilityLabel: "\(hrvMaturity). Recovery gains HRV evidence as calibration nights accumulate."))
            }
            if let vo2Maturity = vo2MaturityText() {
                result.append(Status(title: vo2Maturity,
                                     symbol: "lungs.fill",
                                     accessibilityLabel: "\(vo2Maturity). The estimate keeps improving as qualified resting-HR days accumulate."))
            }
            return result
        }

        private func status(now: Date) -> Status? {
            let live = coreLiveStore.state
            switch live.historicalRecoveryPresentation {
            case .syncing(let savedRecords):
                let copy = AtriaHomeRecoverySyncPresentation.copy(
                    savedRecords: savedRecords,
                    drainedThroughUnix: UserDefaults.standard.object(
                        forKey: AtriaBLEManager.OfflineSyncDefaults.drainedThroughUnix
                    ) as? Double,
                    now: now
                )
                return Status(title: copy.title,
                              symbol: "arrow.triangle.2.circlepath",
                              accessibilityLabel: copy.accessibilityLabel,
                              compactTitle: copy.compactTitle)
            case .verified:
                return Status(title: "Recovery verified",
                              symbol: "checkmark.seal.fill",
                              accessibilityLabel: "Historical recovery verified for the pending data gap.")
            case .partial(let savedRecords):
                let suffix = savedRecords > 0 ? " · \(savedRecords) saved" : ""
                return Status(title: "Recovery partial\(suffix)",
                              symbol: "exclamationmark.triangle.fill",
                              accessibilityLabel: "This recovery saved \(savedRecords) records, but recovery of the missing interval is not verified.")
            case .needsAttention:
                if let synced = syncedStatusIfCurrent(now: now) { return synced }
                guard live.rangeLossBackfillPending else {
                    return nil
                }
                return pendingGapStatus()
            case .idle:
                if let synced = syncedStatusIfCurrent(now: now) { return synced }
                if live.rangeLossBackfillPending {
                    return pendingGapStatus()
                }
                return nil
            }
        }

        /// True while the automatic history recovery for the current gap set
        /// has terminally parked on an unrepairable flash sequence
        /// discontinuity. The gap stays visible as data-quality truth; the
        /// copy must distinguish "still repairing" from "won't retry
        /// automatically" and must never read as fully synced.
        private var sequenceGapParkedTerminal: Bool {
            UserDefaults.standard.object(
                forKey: AtriaBLEManager.OfflineSyncDefaults.sequenceGapParkedAt
            ) != nil
        }

        private func pendingGapStatus() -> Status {
            if sequenceGapParkedTerminal {
                return Status(
                    title: "Strap history gap · interval unavailable",
                    symbol: "exclamationmark.triangle.fill",
                    accessibilityLabel: "One historical interval on the strap could not be recovered after repeated attempts and is marked unavailable. New strap data can reopen recovery."
                )
            }
            return Status(
                title: "Strap data gap · history incomplete",
                symbol: "exclamationmark.triangle.fill",
                accessibilityLabel: "Some strap history is missing. The gap has not been reconciled."
            )
        }

        /// A positive terminal state: the durable strap-history frontier is
        /// current (within a few seconds of now), so there is nothing meaningful
        /// to catch up on. This takes precedence over a lingering (likely
        /// unrecoverable) older range-loss flag so the banner never reads as a
        /// gap while recent history is fully synced. Returns nil when the frontier
        /// is missing or genuinely behind — never fabricating a "synced" claim.
        private func syncedStatusIfCurrent(now: Date) -> Status? {
            let defaults = UserDefaults.standard
            let frontierCurrent: Bool = {
                guard let frontier = defaults.object(
                    forKey: AtriaBLEManager.OfflineSyncDefaults.drainedThroughUnix
                ) as? Double, frontier > 0 else { return false }
                let behind = now.timeIntervalSince1970 - frontier
                return behind >= 0 && behind <= Self.syncedFrontierWindow
            }()
            // Second honest path: the strap's own recent pending-records
            // report says the ring buffer is caught up. Between catch-up
            // slices the drained frontier ages past the 5-second window even
            // though nothing material is left on the strap, so keying only on
            // the frontier kept the banner from ever settling on "Synced".
            let strapCaughtUp = AtriaHomeRecoverySyncPresentation
                .strapReportsCaughtUp(
                    flushDebtLevelRaw: defaults.string(
                        forKey: AtriaBLEManager.OfflineSyncDefaults.flushDebtLevel
                    ),
                    flushDebtObservedAtUnix: defaults.object(
                        forKey: AtriaBLEManager.OfflineSyncDefaults.flushDebtObservedAt
                    ) as? Double,
                    nowUnix: now.timeIntervalSince1970
                )
            guard frontierCurrent || strapCaughtUp else { return nil }
            // A terminally parked older interval is excluded from "Synced":
            // the frontier being current is true, but the claim must carry
            // the unavailable-interval truth beside it.
            if sequenceGapParkedTerminal {
                return Status(
                    title: "Synced · older interval unavailable",
                    symbol: "checkmark.circle.fill",
                    accessibilityLabel: "Strap history is synced through now, but one older historical interval could not be recovered after repeated attempts and is unavailable."
                )
            }
            // A pending range-loss backfill means earlier history is KNOWN to
            // be missing and is waiting to be refetched. "Synced" on its own
            // reads as "nothing left to get", and there already is a precedent
            // for qualifying it — the terminal-park branch directly above.
            //
            // Device 2026-08-27: this owner's app showed a bare "Synced" while
            // `rangeLossBackfillPending` had been true since 24 Aug — three
            // days — because the frontier was current and the strap reported
            // caught up. Both of those were true and neither was the whole
            // truth: 81 minutes of hole in the 26 Aug afternoon is exactly what
            // that backfill exists to fill, and that hole is why the night's HR
            // coverage came to 0.789 against the 0.80 auto-confirm floor.
            //
            // The frontier claim stays intact; it just stops standing alone.
            if defaults.bool(
                forKey: AtriaBLEManager.OfflineSyncDefaults.rangeLossBackfillPending
            ) {
                // Say HOW MUCH. The backlog that starved sleep confirmation
                // grew to 15.5 h over three days behind this exact banner; a
                // size that is visible cannot silently compound. The ledger
                // read is memoised on its own generation counter so the render
                // path stats the file only when the ledger actually changed.
                let backlog = AtriaHomeRecoverySyncPresentation
                    .memoisedGapBacklogText(defaults: defaults, now: now)
                return Status(
                    title: backlog.map { "Synced · filling \($0)" }
                        ?? "Synced · filling earlier gaps",
                    symbol: "checkmark.circle.badge.questionmark",
                    accessibilityLabel: "Strap history is synced through now, "
                        + "but an earlier stretch is known to be missing and is "
                        + "still being refetched."
                        + (backlog.map { " About \($0.replacingOccurrences(of: " of gaps", with: "")) remain." } ?? ""),
                    compactTitle: "Synced · filling gaps"
                )
            }
            return Status(title: "Synced",
                          symbol: "checkmark.circle.fill",
                          accessibilityLabel: "Strap history is synced through now.")
        }

        /// The durable frontier is treated as current within this window — the
        /// user's "no more than a few seconds of gap" bar. A caught-up strap
        /// tracks the ~1 Hz live capture, so this cleanly separates "synced" from
        /// a minutes/hours-behind backlog.
        static let syncedFrontierWindow: TimeInterval = 5

        private struct Status {
            let title: String
            let symbol: String
            let accessibilityLabel: String
            let compactTitle: String

            init(title: String,
                 symbol: String,
                 accessibilityLabel: String,
                 compactTitle: String? = nil) {
                self.title = title
                self.symbol = symbol
                self.accessibilityLabel = accessibilityLabel
                self.compactTitle = compactTitle ?? title
            }
        }
    }

    private var hero: some View {
        AtriaHeroPanelHost(statusStore: model.statusStore,
                           liveStore: model.coreLiveStore,
                           heroStore: model.heroStore,
                           pulseStore: model.heroPulseStore)
    }

    private var currentHomeLayoutConfig: AtriaHomeLayoutConfig {
        guard let data = homeLayoutConfigStorage.data(using: .utf8),
              !data.isEmpty,
              let config = try? AtriaHomeLayoutConfig.decoded(from: data) else {
            return .default
        }
        return config
    }

    private func saveHomeLayoutConfig(_ config: AtriaHomeLayoutConfig) {
        guard let data = try? config.validated().encodedData(),
              let json = String(data: data, encoding: .utf8) else {
            return
        }
        homeLayoutConfigStorage = json
        UserDefaults.standard.set(json, forKey: AtriaHomeLayoutConfig.storageKey)
    }

    private func makeTodayShareSnapshot() -> AtriaShareSnapshot {
        let now = Date()
        let hero = model.heroStore.state
        let live = model.coreLiveStore.state
        // Share the same wake-to-wake sleep evidence rendered by Today/Home.
        // Sleep History deliberately retains older nights, so reading
        // `latestMainSleep` (or the cached hero fallback) here can export the
        // prior night after the no-sleep rollover boundary.
        let sleep = AtriaOverviewCurrentSleep.resolveDisplayEvidence(
            from: store.sleepHistorySnapshot,
            pendingReview: store.pendingSleepReviewNightForUI,
            now: now
        )
        let sleepValue = sleep?.durationText ?? ""
        let sleepDetail = sleep?.confirmationText ?? "No sleep this cycle"
        let sleepIsConfirmedNight = sleep?.confirmed == true && sleep?.isNapEvidence != true
        let sleepProjection = sleepIsConfirmedNight
            ? sleep.flatMap(adaptiveSleepProjection)
            : nil
        let sleepFill = sleepProjection.map {
            min(max(Double($0.performancePercent) / 100.0, 0), 1)
        }
        let sleepZone = sleepProjection.flatMap {
            Metrics.sleepPerformanceZone(
                $0.performancePercent,
                neededHours: $0.needHours
            )
        }
        let recoveryPercent = hero.recoveryEstimate.percent
        let defaults = UserDefaults.standard
        let recoveryTarget = AtriaMetricTarget.recovery(
            greenLower: (defaults.object(forKey: "atria.target.recovery.greenLower") as? Double) ?? 67,
            yellowLower: (defaults.object(forKey: "atria.target.recovery.yellowLower") as? Double) ?? 34
        )
        let recoveryZone = Metrics.recoveryZone(recoveryPercent, target: recoveryTarget)
        let strainGreenBand = (defaults.object(forKey: "atria.target.strain.greenBand") as? Double) ?? 1.5
        let strainYellowBand = (defaults.object(forKey: "atria.target.strain.yellowBand") as? Double) ?? 3.0
        let strainValue = pendingShareValue(hero.strainValue)
        let strainIsQualified = AtriaDailyShareMetricTruth.strainIsQualified(
            value: strainValue,
            confidence: hero.strainConfidence
        )
        let strainFill = AtriaRingMetricProjection.strainFill(strain: hero.strain,
                                                              isPending: !strainIsQualified)
        let strainProgress = strainIsQualified ? AtriaRingMetricProjection.strainTargetProgress(
            strain: hero.strain,
            target: hero.guidance.target
        ) : nil
        let strainZone = strainIsQualified ? Metrics.strainZone(
            strain: hero.strain,
            target: hero.guidance.target,
            greenBand: strainGreenBand,
            yellowBand: strainYellowBand
        ) : nil
        let recoveryValue = recoveryPercent.map { "\($0)%" } ?? ""
        let stats = [
            AtriaShareSnapshot.Stat(id: "recovery",
                                    title: "Recovery",
                                    value: recoveryValue,
                                    detail: hero.recoveryDetail),
            AtriaShareSnapshot.Stat(id: "sleep",
                                    title: "Sleep",
                                    value: pendingShareValue(sleepValue),
                                    detail: sleepDetail),
            AtriaShareSnapshot.Stat(id: "strain",
                                    title: "Day strain",
                                    value: pendingShareValue(hero.strainValue),
                                    detail: hero.strainDetail),
            AtriaShareSnapshot.Stat(id: "hrv",
                                    title: "HRV",
                                    value: pendingShareValue(hero.hrvValue),
                                    detail: hero.hrvDetail),
            AtriaShareSnapshot.Stat(id: "rhr",
                                    title: "RHR",
                                    value: pendingShareValue(hero.restingHeartRateText),
                                    detail: "resting bpm"),
            AtriaShareSnapshot.Stat(id: "peak_hr",
                                    title: "Peak HR",
                                    value: model.pulseLiveStore.state.peakHeartRate.map { "\($0)" } ?? "",
                                    detail: "today"),
            AtriaShareSnapshot.Stat(id: "calories",
                                    title: "Calories",
                                    value: live.liveActiveCalories.map { "\(Int($0.rounded()))" } ?? "",
                                    detail: "active estimate")
        ]
        return AtriaShareSnapshot(date: now,
                                  recovery: AtriaShareSnapshot.Ring(title: "Recovery",
                                                                    value: recoveryValue,
                                                                    detail: hero.recoveryDetail,
                                                                    tintHex: AtriaRingMetricProjection.zoneTintHex(recoveryZone?.level),
                                                                    fill: recoveryPercent.map { Double($0) / 100.0 }),
                                  sleep: AtriaShareSnapshot.Ring(title: "Sleep",
                                                                 value: pendingShareValue(sleepValue),
                                                                 detail: sleepDetail,
                                                                 tintHex: AtriaRingMetricProjection.achievementTintHex(fill: sleepFill),
                                                                 fill: sleepFill,
                                                                 stateTintHex: sleepZone.map { AtriaRingMetricProjection.zoneTintHex($0.level) },
                                                                 targetFraction: sleepProjection == nil ? nil : 1.0),
                                  strain: AtriaShareSnapshot.Ring(title: "Strain",
                                                                  value: strainValue,
                                                                  detail: hero.strainDetail,
                                                                  tintHex: AtriaRingMetricProjection.strainTintHex(
                                                                    targetProgress: strainProgress,
                                                                    actualFill: strainFill
                                                                  ),
                                                                  fill: strainFill,
                                                                  stateTintHex: strainZone.map { AtriaRingMetricProjection.zoneTintHex($0.level) },
                                                                  targetFraction: strainIsQualified
                                                                    ? AtriaRingMetricProjection.strainTargetFraction(hero.guidance.target)
                                                                    : nil),
                                  stats: stats)
    }

    /// Share and review must grade the same effective night against the same
    /// adaptive need as Today: baseline + debt + prior strain - nap credit.
    /// The configured duration goal remains a planning preference, not an
    /// alternate scoring authority.
    private func adaptiveSleepProjection(
        for night: SleepHistorySnapshot.Night
    ) -> (needHours: Double, performancePercent: Int)? {
        let calendar = Calendar.current
        let priorDay = calendar.date(
            byAdding: .day,
            value: -1,
            to: calendar.startOfDay(for: night.day)
        )
        let yesterdayStrain = priorDay.flatMap { day in
            store.dailyRollupHistory.first {
                calendar.isDate($0.day, inSameDayAs: day)
            }?.strain
        }
        let need = store.sleepHistorySnapshot.sleepNeedHours(
            for: night,
            baseNeedHours: SessionStore.configuredSleepBaseNeedHours(),
            yesterdayStrain: yesterdayStrain,
            calendar: calendar
        )
        guard let need else { return nil }
        return (
            needHours: need,
            performancePercent: AtriaSleepBudget.performancePercent(
                slept: night.durationHours,
                needed: need
            )
        )
    }

    /// Share cards must never print a placeholder as if it were a measurement,
    /// so this routes through the canonical pending check rather than keeping
    /// its own token list.
    private func pendingShareValue(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return AtriaCompactMetricPresentation.isPendingValue(trimmed) ? "" : trimmed
    }


    private var overviewContent: some View {
        // One notifications block (user's strict rule, 2026-07-07): the
        // workout item, sleep item, and plan card render together inside
        // AtriaTodayScreen's plan section, under the ring. State and actions
        // stay here; only the rendering location moved. Max 3 items: the
        // workout banners are mutually exclusive and the sleep section shows
        // at most one surface.
        let todayNotifications = AnyView(Group {
            if let prompt = debugWorkoutDetectionPrompt ?? workoutDetectionPrompt, workoutSession == nil {
                AtriaWorkoutDetectionBanner(prompt: prompt) {
                    workoutDetectionPrompt = nil
                    workoutPromptSuppressedForCurrentEpisode = true
                    workoutPromptRecoveryStartedAt = nil
                    workoutPromptDismissedUntil = Date().addingTimeInterval(Self.workoutPromptCooldown)
                } onStart: {
                    presentWorkoutReview(prompt: prompt)
                }
            }

            if let candidate = debugSavedWorkoutReviewCandidate ?? savedWorkoutReviewCandidate,
               workoutSession == nil,
               workoutReviewDraft == nil,
               (debugWorkoutDetectionPrompt ?? workoutDetectionPrompt) == nil {
                AtriaSavedWorkoutReviewBanner(candidate: candidate,
                                             restingHeartRate: store.baseline.restingInt ?? model.heroStore.state.restingHeartRate,
                                             maxHeartRate: store.profile.maxHR) {
                    dismissSavedWorkoutReviewCandidate(candidate)
                } onReview: {
                    presentWorkoutReview(candidate: candidate)
                }
            }

            if let holdState = workoutReviewHoldStateForDisplay,
               workoutSession == nil,
               workoutReviewDraft == nil,
               (debugWorkoutDetectionPrompt ?? workoutDetectionPrompt) == nil,
               (debugSavedWorkoutReviewCandidate ?? savedWorkoutReviewCandidate) == nil {
                AtriaWorkoutReviewHoldBanner(state: holdState)
            }

            AtriaTodaySleepReviewSection(store: store)
        })

        return VStack(spacing: 18) {
#if DEBUG
            // Screenshot hook (2026-07-30): the workout-review/notifications block
            // renders inside AtriaTodayScreen UNDER the ring (below the fold) and
            // simctl can't scroll, so float a copy to the top for headless capture.
            if ProcessInfo.processInfo.arguments.contains("--atria-ui-notifications-top") {
                todayNotifications
            }
#endif
            if shouldLeadWithSystemBanners && !debugShowsSleepPlanBedtimeFixture && !debugShowsNorthStarTodayFixture {
                overviewSystemBanners
            }

            AtriaTodayScreen(liveStore: model.coreLiveStore,
                             pulseStore: model.heroPulseStore,
                             stressMonitorStore: model.stressMonitorStore,
                             heroStore: model.heroStore,
                             homeStatsStore: model.homeStatsStore,
                             profileMetricsStore: model.profileMetricsStore,
                             sessionProjectionStore: model.todaySessionProjectionStore,
                             snapshotStore: model.snapshotStore,
                             store: store,
                             layoutConfig: currentHomeLayoutConfig,
                             hasUnlockedSecondarySections: hasUnlockedSecondarySections,
                             aiCoachSettings: aiCoachSettings,
                             aiCoachHasAPIKey: aiCoachHasAPIKey,
                             hapticSettings: hapticSettings,
                             horizontalSizeClass: horizontalSizeClass,
                             connectionContext: connectionGuideContext,
                             debugShowsSegmentContent: debugShowsOverviewSegmentContent,
                             suppressSleepSyncPrompt: hasPrimaryReviewAction,
                             initialSegment: debugInitialOverviewSegment,
                             onAICoachSettingsChange: { settings in
                                 aiCoachSettings = settings
                             },
                             onSaveAICoachAPIKey: { key in
                                 AtriaCoachKeychain.saveAPIKey(key, provider: aiCoachSettings.cloudProvider)
                                 refreshAICoachKeyState()
                             },
                             onDeleteAICoachAPIKey: {
                                 AtriaCoachKeychain.deleteAPIKey(provider: aiCoachSettings.cloudProvider)
                                 refreshAICoachKeyState()
                             },
                             onShowConnectionGuide: {
                                 connectionGuideSnoozedUntil = nil
                                 showConnectionGuide = true
                             },
                             onOpenVitals: {
                                 performMotionAwareUpdate {
                                     selectedTab = .vitals
                                 }
                             },
                             onOpenCollection: {
                                 // `.collection` is not one of the four TabView
                                 // tags (overview/vitals/journal/chat), so
                                 // selecting it showed a blank tab. The strap
                                 // collection lives in a fullScreenCover -- open
                                 // it the same way topChrome and the deep-link
                                 // handler do (IA fix, 2026-07-06).
                                 showStrapScreen = true
                             },
                             onOpenJournal: {
                                 selectedTab = .journal
                             },
                             onOpenShare: {
                                 showShareSheet = true
                             },
                             onStartWorkout: {
                                 showWorkoutStartSheet = true
                             },
                             onLayoutConfigChange: { config in
                                 saveHomeLayoutConfig(config)
                             },
                             onCustomizeToday: {
                                 showCustomizeSheet = true
                             },
                             systemNotifications: todayNotifications)

            if !debugShowsNorthStarTodayFixture && !shouldLeadWithSystemBanners {
                overviewSystemBanners
            }
            // Live strap catch-up progress, the last row of Overview — but
            // only when no system banner is up: a banner plus this footer told
            // the same sync story twice (owner stack audit 2026-08-28). The
            // footer returns once the banner resolves or is dismissed.
            if !debugShowsNorthStarTodayFixture,
               connectionDiagnosis == nil, !shouldShowMissedDataBanner {
                AtriaSyncProgressFooter(
                    liveHeartRateIsCurrent:
                        model.coreLiveStore.state.hasRecentHeartRateSample
                )
            }
        }
    }

    /// Questions left in today's check-in, for the Journal tab badge. Zero
    /// (hidden) once complete — the badge is the brief's only knock now.
    private var journalCheckInBadgeCount: Int {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let entry = store.behaviorJournalEntries.first {
            calendar.isDate($0.day, inSameDayAs: today)
        }
        let progress = AtriaJournalCheckInProgress.resolve(
            trackedTags: AtriaTrackedBehaviors.parse(
                UserDefaults.standard.string(
                    forKey: AtriaTrackedBehaviors.storageKey) ?? ""),
            todayEntry: entry,
            answersByQuestion: store.journalAnswers.answersByQuestion(
                for: today, calendar: calendar))
        return progress.isComplete
            ? 0
            : max(0, progress.totalCount - progress.answeredCount)
    }

    @ViewBuilder
    private var overviewSystemBanners: some View {
        if let diagnosis = connectionDiagnosis {
            AtriaConnectionDiagnosisBanner(diagnosis: diagnosis) {
                connectionGuideSnoozedUntil = nil
                showConnectionGuide = true
            }
        } else if shouldShowMissedDataBanner {
            AtriaMissedDataBanner(protectsLiveStream: missedDataBackfillIsDeferredForLiveStream) {
                missedDataBannerDismissedUntil = Date().addingTimeInterval(60 * 60)
            } onSync: {
                missedDataBannerDismissedUntil = nil
                ble.queueConnectedRawHistoryCatchUpIntent(
                    reason: "home_missed_data_banner"
                )
            } onStartFresh: {
                confirmStartFreshFromBanner = true
            }
            .confirmationDialog("Start fresh?",
                                isPresented: $confirmStartFreshFromBanner,
                                titleVisibility: .visible) {
                Button("Start fresh", role: .destructive) {
                    ble.startFreshAcceptingMissedDataLoss(reason: "home_banner_start_fresh")
                    missedDataBannerDismissedUntil = nil
                }
                Button("Keep waiting", role: .cancel) {}
            } message: {
                Text("Earlier data that wasn't recorded will be marked done. Your live tracking and new data are unaffected.")
            }
        }
    }

    private var connectionDiagnosis: AtriaConnectionDiagnosis? {
        visibleConnectionDiagnosis
    }

    private var hasPrimaryReviewAction: Bool {
        hasWorkoutReviewAction || hasPendingSleepReviewAction
    }

    private var shouldLeadWithSystemBanners: Bool {
        // Static handoff compatibility marker for the pre-IA-2 segment gate:
        // !hasPrimaryReviewAction && activeOverviewSegment == .today
        false
    }

    private var hasWorkoutReviewAction: Bool {
        workoutSession == nil && (
            (debugWorkoutDetectionPrompt ?? workoutDetectionPrompt) != nil ||
            (debugSavedWorkoutReviewCandidate ?? savedWorkoutReviewCandidate) != nil ||
            workoutReviewHoldStateForDisplay != nil
        )
    }

    private var hasPendingSleepReviewAction: Bool {
        #if DEBUG
        if Self.debugLaunchFixtureValue(arguments: ProcessInfo.processInfo.arguments) == "pending-sleep-review" {
            return true
        }
        #endif
        if store.sleepHistorySnapshot.latestReviewable?.confirmed == false {
            return true
        }
        // This value is already prepared on the utility queue and published by
        // SessionStore. Never validate the sleep-review cache from a SwiftUI
        // body path: doing so may load/rebuild the multi-megabyte
        // active journal synchronously, so an unrelated root state change (the
        // Settings gear was the visible trigger) can stall the main thread.
        return store.pendingSleepReviewNightForUI != nil
    }

    private var workoutReviewHoldStateForDisplay: WorkoutReviewHoldState? {
        if let debugWorkoutReviewHoldState {
            return debugWorkoutReviewHoldState
        }
        return nil
    }

    private func updateConnectionDiagnosisVisibility(reason: String, now: Date = Date()) {
        LocalNotificationScheduler.refreshActionableConnectionMaintenance(ble: ble, reason: reason)
        let next = AtriaConnectionDiagnosis.derive(live: model.coreLiveStore.state,
                                                   pulse: model.pulseLiveStore.state,
                                                   officialAppInstalled: officialAppInstalled)
        guard let next else {
            if visibleConnectionDiagnosis != nil || connectionDiagnosisCandidate != nil {
                AtriaDebugLog("ATRIADBG connection_diagnosis status=hidden reason=%@ action=clear", reason)
            }
            if visibleConnectionDiagnosis?.sendsLocalNotification == true ||
                connectionDiagnosisCandidate?.sendsLocalNotification == true {
                LocalNotificationScheduler.cancelActionableConnectionDiagnosis(reason: "diagnosis_cleared_\(reason)")
            }
            resetConnectionDiagnosisCandidate()
            setVisibleConnectionDiagnosis(nil)
            return
        }

        if visibleConnectionDiagnosis?.sendsLocalNotification == true,
           visibleConnectionDiagnosis?.title != next.title {
            LocalNotificationScheduler.cancelActionableConnectionDiagnosis(title: visibleConnectionDiagnosis?.title,
                                                                           reason: "diagnosis_changed_\(reason)")
        }
        if !next.sendsLocalNotification,
           visibleConnectionDiagnosis?.sendsLocalNotification == true ||
            connectionDiagnosisCandidate?.sendsLocalNotification == true {
            LocalNotificationScheduler.cancelActionableConnectionDiagnosis(reason: "diagnosis_non_actionable_\(reason)")
        }

        if next.showsImmediately {
            if next.sendsLocalNotification && visibleConnectionDiagnosis != next {
                LocalNotificationScheduler.scheduleActionableConnectionDiagnosis(title: next.title,
                                                                                 body: next.action,
                                                                                 reason: reason,
                                                                                 now: now)
            }
            startConnectionDiagnosisCandidate(next, now: now)
            setVisibleConnectionDiagnosis(next)
            return
        }

        if connectionDiagnosisCandidate != next {
            startConnectionDiagnosisCandidate(next, now: now)
            setVisibleConnectionDiagnosis(nil)
            AtriaDebugLog("ATRIADBG connection_diagnosis status=pending reason=%@ title=%@ delay_s=%.0f",
                  reason,
                  next.title,
                  Self.connectionDiagnosisPersistenceDelay)
            return
        }

        let elapsed = connectionDiagnosisCandidateSince.map { now.timeIntervalSince($0) } ?? 0
        guard elapsed >= Self.connectionDiagnosisPersistenceDelay else {
            setVisibleConnectionDiagnosis(nil)
            return
        }
        if visibleConnectionDiagnosis != next {
            AtriaDebugLog("ATRIADBG connection_diagnosis status=visible reason=%@ title=%@ elapsed_s=%.0f",
                  reason,
                  next.title,
                  elapsed)
            // Persistence-gated diagnoses (e.g. "Fit check needed") only notify once
            // they have stayed visible past the candidate delay — avoids alerting on
            // momentary poor-contact blips.
            if next.sendsLocalNotification {
                LocalNotificationScheduler.scheduleActionableConnectionDiagnosis(title: next.title,
                                                                                 body: next.action,
                                                                                 reason: reason,
                                                                                 now: now)
            }
        }
        setVisibleConnectionDiagnosis(next)
    }

    private func resetConnectionDiagnosisCandidate() {
        connectionDiagnosisPromotionTask?.cancel()
        connectionDiagnosisPromotionTask = nil
        if connectionDiagnosisCandidate != nil {
            connectionDiagnosisCandidate = nil
        }
        if connectionDiagnosisCandidateSince != nil {
            connectionDiagnosisCandidateSince = nil
        }
    }

    private func startConnectionDiagnosisCandidate(_ diagnosis: AtriaConnectionDiagnosis, now: Date) {
        guard connectionDiagnosisCandidate != diagnosis else { return }
        connectionDiagnosisPromotionTask?.cancel()
        connectionDiagnosisPromotionTask = nil
        connectionDiagnosisCandidate = diagnosis
        connectionDiagnosisCandidateSince = now
        guard !diagnosis.showsImmediately else { return }
        connectionDiagnosisPromotionTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(Self.connectionDiagnosisPersistenceDelay))
            } catch {
                return
            }
            guard !Task.isCancelled, scenePhase == .active else {
                connectionDiagnosisPromotionTask = nil
                return
            }
            connectionDiagnosisPromotionTask = nil
            updateConnectionDiagnosisVisibility(reason: "candidate_deadline")
        }
    }

    private func setVisibleConnectionDiagnosis(_ diagnosis: AtriaConnectionDiagnosis?) {
        guard visibleConnectionDiagnosis != diagnosis else { return }
        visibleConnectionDiagnosis = diagnosis
    }

    private var shouldShowMissedDataBanner: Bool {
        if Self.debugShowsCatchUpPill(arguments: ProcessInfo.processInfo.arguments) { return true }
        guard model.collectionLiveStore.state.rangeLossBackfillPending else { return false }
        guard showsMissedDataBannerForCurrentStatus else { return false }
        guard selectedTab == .overview else { return false }
        if let missedDataBannerDismissedUntil, missedDataBannerDismissedUntil > Date() {
            return false
        }
        return true
    }

    private var showsMissedDataBannerForCurrentStatus: Bool {
        switch model.statusStore.state.status {
        case .connected:
            return model.coreLiveStore.state.sessionSampleCount > 0
        case .disconnected, .poweredOff:
            return model.coreLiveStore.state.sessionSampleCount == 0
        case .connecting, .scanning:
            return true
        }
    }

    private var missedDataBackfillIsDeferredForLiveStream: Bool {
        model.statusStore.state.status == .connected
            && model.coreLiveStore.state.sessionSampleCount > 0
    }

    #if DEBUG
    private static func debugShowsCatchUpPill(arguments: [String]) -> Bool {
        guard let fixtureIndex = arguments.firstIndex(of: "--atria-ui-fixture") else { return false }
        let valueIndex = arguments.index(after: fixtureIndex)
        return arguments.indices.contains(valueIndex)
            && arguments[valueIndex] == "catching-up-pill"
    }
    #else
    private static func debugShowsCatchUpPill(arguments _: [String]) -> Bool { false }
    #endif

    private func presentCoexistenceModalIfNeeded(for risk: AtriaBLEManager.OfficialAppCoexistenceRisk) {
        guard risk == .suspected else { return }
        // Never auto-interrupt the user when the official strap app isn't even installed — those
        // drops are battery/range and are handled silently by auto-reconnect. The
        // recovery steps stay available on demand via the "?" connection guide.
        guard officialAppInstalled else { return }
        Task { @MainActor in
            await Task.yield()
            let snoozed = coexistenceSnoozedUntil.map { Date() < $0 } ?? false
            if !snoozed, !showCoexistenceModal {
                showCoexistenceModal = true
            }
        }
    }

    private func acknowledgeCoexistenceModal(reason: String) {
        coexistenceSnoozedUntil = Date().addingTimeInterval(60 * 60)
        showCoexistenceModal = false
        recordCoexistenceSnoozeVerification(status: "acknowledged", reason: reason)
    }

    private func runCoexistenceSnoozeSelfTestIfRequested(arguments: [String] = ProcessInfo.processInfo.arguments) {
#if DEBUG
        guard arguments.contains("--atria-verify-coexistence-snooze") else { return }
        showCoexistenceModal = true
        acknowledgeCoexistenceModal(reason: "debug_launch_arg")
        presentCoexistenceModalIfNeeded(for: .suspected)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 180_000_000)
            let snoozed = coexistenceSnoozedUntil.map { Date() < $0 } ?? false
            let passed = snoozed && !showCoexistenceModal
            recordCoexistenceSnoozeVerification(status: passed ? "pass" : "fail",
                                                reason: "debug_launch_arg")
        }
#endif
    }

    private func recordCoexistenceSnoozeVerification(status: String, reason: String) {
#if DEBUG
        let defaults = UserDefaults.standard
        defaults.set(status, forKey: "atria.link.coexistenceSnoozeVerificationStatus")
        defaults.set(reason, forKey: "atria.link.coexistenceSnoozeVerificationReason")
        defaults.set(Date().timeIntervalSince1970, forKey: "atria.link.coexistenceSnoozeVerificationAt")
#endif
    }

    private var journalContent: some View {
        AtriaJournalTab(store: store)
    }

    // The former Plan tab is now the Activity Monitor: every logged sleep, nap
    // and workout in one place, each row routing to the existing editors. Sleep
    // rows reuse the same manual-sleep sheet the rest of the app adjusts nights
    // with (seeded night = edit, nil = add).
    private var planContent: some View {
        AtriaActivityMonitorTab(activityStore: model.activityStore,
                                stressMonitorStore: model.stressMonitorStore,
                                store: store,
                                onEditSleep: { night in
                                    sleepReviewSheetRoute = AtriaSleepReviewSheetRoute(night: night)
                                },
                                onAddSleep: {
                                    sleepReviewSheetRoute = AtriaSleepReviewSheetRoute(night: nil)
                                })
    }

    private func makeFaceOffChallengeURL() -> URL? {
        let name = faceOffDisplayName.isEmpty ? "A friend" : faceOffDisplayName
        guard let payload = AtriaFaceOff.makePayload(name: name,
                                                     history: store.dailyMetricHistory) else { return nil }
        return AtriaFaceOff.url(for: payload)
    }

    private var vitalsContent: some View {
        AtriaHealthScreen(isActive: selectedTab == .vitals,
                          liveStore: model.coreLiveStore,
                          pulseStore: model.pulseLiveStore,
                          pulseSparklineStore: model.pulseSparklineStore,
                          heroStore: model.heroStore,
                          homeStatsStore: model.homeStatsStore,
                          profileStore: model.profileStore,
                          profileMetricsStore: model.profileMetricsStore,
                          stressMonitorStore: model.stressMonitorStore,
                          store: store,
                          ble: ble,
                          horizontalSizeClass: horizontalSizeClass,
                          onViewPlan: {
                              selectedTab = .overview
                          })
    }

    @ViewBuilder
    private var collectionContent: some View {
        #if DEBUG
        if Self.debugRequestedUIScreen(arguments: ProcessInfo.processInfo.arguments) == "history" {
            HistoryView(store: store)
        } else {
            collectionTabContent
        }
        #else
        collectionTabContent
        #endif
    }

    private var collectionTabContent: some View {
        AtriaStrapScreen(statusStore: model.statusStore,
                         coreLiveStore: model.coreLiveStore,
                         pulseLiveStore: model.pulseLiveStore,
                         collectionLiveStore: model.collectionLiveStore,
                         store: store,
                         ble: ble,
                         horizontalSizeClass: horizontalSizeClass,
                         showRRImporter: $showRRImporter,
                         showHRImporter: $showHRImporter,
                         rrShareURL: $rrShareURL,
                         hrShareURL: $hrShareURL,
                         captureShareURL: $captureShareURL,
                         rrImportStatus: $rrImportStatus,
                         hrImportStatus: $hrImportStatus,
                         hapticSettings: $hapticSettings,
                         officialAppInstalled: officialAppInstalled,
                         developerModeEnabled: developerModeEnabled,
                         onShowConnectionGuide: {
                             showStrapScreen = false
                             connectionGuideSnoozedUntil = nil
                             showConnectionGuide = true
                         })
    }

    private var researchValidationContent: some View {
        AtriaCollectionResearchValidationContent(collectionLiveStore: model.collectionLiveStore,
                                                 homeStatsStore: model.homeStatsStore,
                                                 snapshotStore: model.snapshotStore,
                                                 profileStore: model.profileStore,
                                                 profileMetricsStore: model.profileMetricsStore,
                                                 store: store,
                                                 ble: ble,
                                                 showRRImporter: $showRRImporter,
                                                 showHRImporter: $showHRImporter,
                                                 rrShareURL: $rrShareURL,
                                                 hrShareURL: $hrShareURL,
                                                 rrImportStatus: rrImportStatus,
                                                 hrImportStatus: hrImportStatus)
    }

    private func handleRRImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else {
                rrImportStatus = "No beat-to-beat file selected"
                return
            }
            let passed = store.importRRReferenceCSVForUI(from: url)
            rrImportStatus = passed ? "Beat-to-beat file matched" : "Not yet validated against a reference monitor"
            model.forceRefresh()
        case .failure:
            rrImportStatus = "Beat-to-beat import failed"
        }
    }

    private func handleHRImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else {
                hrImportStatus = "No heart-rate file selected"
                return
            }
            let passed = store.importHRReferenceCSVForUI(from: url)
            hrImportStatus = passed ? "Heart-rate check passed" : "Heart-rate check still pending"
            model.forceRefresh()
        case .failure:
            hrImportStatus = "Heart-rate import failed"
        }
    }

    private func presentConnectionGuideIfNeeded() {
        connectionGuidePresentationTask?.cancel()
        connectionGuidePresentationTask = nil
        let defaults = UserDefaults.standard
        let successes = defaults.integer(forKey: AtriaBLEManager.LinkDefaults.successes)
        let attempts = defaults.integer(forKey: AtriaBLEManager.LinkDefaults.attempts)
        let failures = defaults.integer(forKey: AtriaBLEManager.LinkDefaults.failures)
        guard store.profile.hasCompletedOnboarding,
              !isDebugUIScreenLaunchActive,
              successes == 0,
              !isConnectionGuideSnoozed,
              model.coreLiveStore.state.status != .connected else { return }
        let status = model.coreLiveStore.state.status
        let needsImmediateHelp = status == .poweredOff
        let hasAutomaticPassStarted = attempts > 0 || failures > 0
        guard needsImmediateHelp || hasAutomaticPassStarted else { return }
        let token = UUID()
        connectionGuidePresentationToken = token
        let delay: TimeInterval
        switch status {
        case .poweredOff:
            delay = 0.8
        case .disconnected:
            delay = failures > 0 ? 2.0 : 5.5
        case .scanning, .connecting:
            delay = failures > 0 ? 5.0 : 8.5
        case .connected:
            delay = 0
        }
        connectionGuidePresentationTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard connectionGuidePresentationToken == token,
                  store.profile.hasCompletedOnboarding,
                  UserDefaults.standard.integer(forKey: AtriaBLEManager.LinkDefaults.successes) == 0,
                  !isConnectionGuideSnoozed,
                  model.coreLiveStore.state.status != .connected else { return }
            showConnectionGuide = true
            logHomeTiming(event: "connection_guide_presented", status: model.coreLiveStore.state.status)
        }
    }

    private func scheduleAutomaticConnectionSetupIfNeeded(reason: String,
                                                          delayNanoseconds: UInt64) {
        guard model.coreLiveStore.state.status == .disconnected else { return }
        automaticConnectionSetupTask?.cancel()
        automaticConnectionSetupTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled else { return }
            guard model.coreLiveStore.state.status == .disconnected else { return }
            let now = Date()
            let minimumSpacing: TimeInterval =
                UserDefaults.standard.integer(forKey: AtriaBLEManager.LinkDefaults.successes) == 0 ? 2.2 : 4.5
            if let lastAutomaticConnectionSetupAt,
               now.timeIntervalSince(lastAutomaticConnectionSetupAt) < minimumSpacing {
                return
            }
            lastAutomaticConnectionSetupAt = now
            ble.startScan(reason: reason)
        }
    }

    private func handleStatusChange(_ status: AtriaBLEManager.Status) {
        updateMediaRefreshLoop()
        if status == .connected {
            automaticConnectionSetupTask?.cancel()
            automaticConnectionSetupTask = nil
            connectionGuideSnoozedUntil = nil
            showConnectionGuide = false
            connectionGuidePresentationToken = UUID()
            logHomeTiming(event: "connected", status: status)
            if selectedTab == .overview, !model.snapshotStore.diagnosticsReady {
                scheduleOverviewDiagnosticsKickoff(reason: "connected_overview_idle",
                                                   delayNanoseconds: 6_800_000_000)
            }
            return
        }

        if status == .disconnected {
            scheduleAutomaticConnectionSetupIfNeeded(reason: "status_\(status.logToken)",
                                                     delayNanoseconds: 120_000_000)
        } else {
            automaticConnectionSetupTask?.cancel()
            automaticConnectionSetupTask = nil
        }

        if status == .disconnected || status == .poweredOff {
            presentConnectionGuideIfNeeded()
        }
    }

    private var isConnectionGuideSnoozed: Bool {
        guard let connectionGuideSnoozedUntil else { return false }
        return connectionGuideSnoozedUntil > Date()
    }

    private var connectionGuideContext: AtriaConnectionGuideContext {
        let defaults = UserDefaults.standard
        return AtriaConnectionGuideContext(
            hasEverConnected: defaults.integer(forKey: AtriaBLEManager.LinkDefaults.successes) > 0,
            attempts: defaults.integer(forKey: AtriaBLEManager.LinkDefaults.attempts),
            failures: defaults.integer(forKey: AtriaBLEManager.LinkDefaults.failures),
            lastStatus: defaults.string(forKey: AtriaBLEManager.LinkDefaults.lastStatus) ?? "idle",
            lastReason: defaults.string(forKey: AtriaBLEManager.LinkDefaults.lastReason) ?? "waiting",
            officialAppCoexistenceRisk: model.statusStore.state.officialAppCoexistenceRisk,
            officialAppInstalled: officialAppInstalled
        )
    }

    private func logPrimaryContentReadyIfNeeded() {
        guard !hasLoggedPrimaryReady else { return }
        hasLoggedPrimaryReady = true
        logHomeTiming(event: "primary_ready", status: model.coreLiveStore.state.status)
    }

    private func logSecondaryContentReadyIfNeeded() {
        guard !hasLoggedSecondaryReady else { return }
        hasLoggedSecondaryReady = true
        logHomeTiming(event: "secondary_ready", status: model.coreLiveStore.state.status)
    }

    private func logDiagnosticsReadyIfNeeded() {
        guard !hasLoggedDiagnosticsReady else { return }
        hasLoggedDiagnosticsReady = true
        logHomeTiming(event: "diagnostics_ready", status: model.coreLiveStore.state.status)
    }

    private func logHomeTiming(event: String, status: AtriaBLEManager.Status) {
        let elapsedMS = Int((Date().timeIntervalSince(homeAppearedAt ?? Date())) * 1000)
        AtriaDebugLog("ATRIADBG home_launch_timing event=%@ elapsed_ms=%d status=%@ tab=%@",
                      event,
                      elapsedMS,
                      status.logToken,
                      selectedTab.rawValue)
    }
}

/// Compact, truthful copy for the recovery chip near the top of Overview. The
/// durable archive frontier is optional: until it exists (or when it is
/// invalid), the chip keeps its prior copy instead of inventing a synced time.
/// A shorter title preserves the frontier on narrow widths and at larger
/// Dynamic Type sizes; VoiceOver always receives the complete status.
enum AtriaHomeRecoverySyncPresentation {
    struct Copy: Equatable {
        let title: String
        let compactTitle: String
        let accessibilityLabel: String
    }

    /// The strap itself recently reported a caught-up ring buffer
    /// (`pending_records` inside the ~2-minute caught-up band from a 0x22
    /// getDataRange response). That is the honest "nothing material left to
    /// sync" signal even while the drained frontier sits one slice-cadence
    /// behind now; keyed only on the 5-second frontier window, the banner
    /// could never read "Synced" between catch-up slices on a healthy link.
    /// Staleness fails closed: an old observation (link lost, app suspended)
    /// never fabricates a synced claim.
    private static var gapBacklogMemo: (generation: Int, text: String?)?

    /// Ledger-generation-memoised wrapper so the status render only touches
    /// the ledger file when a drain actually changed it.
    static func memoisedGapBacklogText(defaults: UserDefaults,
                                       now: Date) -> String? {
        let generation = defaults.integer(
            forKey: AtriaHistoricalGapLedger.generationKey
        )
        if let memo = gapBacklogMemo, memo.generation == generation {
            return memo.text
        }
        let text = gapBacklogText(
            seconds: unresolvedGapSeconds(
                windows: AtriaHistoricalGapLedger
                    .windowsForEvidence(defaults: defaults),
                now: now
            )
        )
        gapBacklogMemo = (generation, text)
        return text
    }

    /// Total genuinely-missing time across the gap ledger, in seconds.
    ///
    /// A coalesced envelope can SPAN days while missing only minutes — its
    /// `expectedSecondBits` mask is the truth (device 2026-08-27: a 61.6 h
    /// envelope whose mask held 15.52 h). An ordinary window with no mask is
    /// missing end-to-end. `coveredSecondBits` is deliberately ignored: it is
    /// unpopulated in production data, and treating empty as "no progress"
    /// would overstate.
    ///
    /// This number existing on screen is the point. The 15.5 h backlog that
    /// starved sleep confirmation for three days was reachable only by pulling
    /// the container and decoding the mask by hand.
    static func unresolvedGapSeconds(
        windows: [AtriaHistoricalGapLedger.Window],
        now: Date
    ) -> TimeInterval {
        windows.reduce(0) { total, window in
            if let bits = window.expectedSecondBits {
                let missing = bits.reduce(0) { $0 + $1.nonzeroBitCount }
                return total + TimeInterval(missing)
            }
            let end = window.end ?? now
            guard end > window.start else { return total }
            return total + end.timeIntervalSince(window.start)
        }
    }

    /// "12m of gaps" / "2.3h of gaps" / nil under a minute (not worth a claim).
    static func gapBacklogText(seconds: TimeInterval) -> String? {
        guard seconds >= 60 else { return nil }
        if seconds < 3_600 { return "\(Int((seconds / 60).rounded()))m of gaps" }
        return String(format: "%.1fh of gaps", seconds / 3_600)
    }

    static func strapReportsCaughtUp(
        flushDebtLevelRaw: String?,
        flushDebtObservedAtUnix: Double?,
        nowUnix: Double,
        freshnessWindow: TimeInterval = 120
    ) -> Bool {
        guard flushDebtLevelRaw
                == AtriaBLEManager.FlushDebtLevel.caughtUp.rawValue,
              let observedAt = flushDebtObservedAtUnix,
              observedAt.isFinite,
              observedAt > 0 else { return false }
        let age = nowUnix - observedAt
        return age >= 0 && age <= freshnessWindow
    }

    static func copy(savedRecords: Int,
                     drainedThroughUnix: Double?,
                     now: Date,
                     calendar: Calendar = .current,
                     locale: Locale = .current) -> Copy {
        let savedRecords = max(0, savedRecords)
        let through = syncedThroughText(drainedThroughUnix: drainedThroughUnix,
                                        now: now,
                                        calendar: calendar,
                                        locale: locale)

        var titleParts = ["Syncing strap history"]
        // Keep the channel word in the compact fallback (shown when the full
        // title does not fit, e.g. narrow widths): "Syncing history · …" so the
        // banner never reads as if all data — including current live HR — is
        // behind. Still shorter than the full "Syncing strap history · …".
        var compactParts = ["Syncing history"]
        if savedRecords > 0 {
            titleParts.append("\(savedRecords) saved")
            compactParts.append("\(savedRecords) saved")
        }
        // "newest", NOT "through". `drainedThroughUnix` is a monotone MAX of
        // durable record timestamps — `advancedDurableHistoricalFrontier` takes
        // `.max()` and never regresses, and its own docstring calls it the
        // "display-only strap-history frontier". A drain fills oldest-first and
        // routinely lands rows BEHIND it; motion-only records carrying no heart
        // rate advance it too; and "Start fresh" sets it to now while
        // abandoning the un-drained backlog outright.
        //
        // So "through 7:02 PM" claimed a completeness the value never had, and
        // the owner's question — "idk when it's fully synced" — is exactly the
        // question this string appeared to answer and did not. It reports how
        // far the drain has REACHED, not how much it has filled.
        if let through {
            titleParts.append("newest \(through)")
            compactParts.append("newest \(through)")
        }

        var accessibilityParts = ["History sync in progress."]
        if savedRecords > 0 {
            accessibilityParts.append(
                "\(savedRecords) records durably saved in this recovery."
            )
        }
        if let through {
            // The old VoiceOver line was the strongest claim of the three —
            // "Strap history is durably synced through X." — and was followed
            // immediately by "Missing data is not yet verified.", which
            // contradicted it. One honest sentence replaces both.
            accessibilityParts.append(
                "The newest saved record is from \(through). Earlier stretches "
                    + "may still be filling in."
            )
        } else {
            accessibilityParts.append("Missing data is not yet verified.")
        }

        return Copy(title: titleParts.joined(separator: " · "),
                    compactTitle: compactParts.joined(separator: " · "),
                    accessibilityLabel: accessibilityParts.joined(separator: " "))
    }

    private static func syncedThroughText(drainedThroughUnix: Double?,
                                          now: Date,
                                          calendar: Calendar,
                                          locale: Locale) -> String? {
        guard let drainedThroughUnix,
              drainedThroughUnix.isFinite,
              drainedThroughUnix > 0,
              drainedThroughUnix <= now.timeIntervalSince1970 else {
            return nil
        }
        let frontier = Date(timeIntervalSince1970: drainedThroughUnix)
        let timeFormatter = DateFormatter()
        timeFormatter.calendar = calendar
        timeFormatter.locale = locale
        timeFormatter.timeZone = calendar.timeZone
        timeFormatter.timeStyle = .short
        timeFormatter.dateStyle = .none

        let time = timeFormatter.string(from: frontier)
        if calendar.isDate(frontier, inSameDayAs: now) {
            return time
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(frontier, inSameDayAs: yesterday) {
            return "\(time) yesterday"
        }

        let dayFormatter = DateFormatter()
        dayFormatter.calendar = calendar
        dayFormatter.locale = locale
        dayFormatter.timeZone = calendar.timeZone
        dayFormatter.setLocalizedDateFormatFromTemplate("EEE")
        return "\(time) \(dayFormatter.string(from: frontier))"
    }
}

/// Honest copy for the missed-data banner. The old banner showed the gap's AGE
/// (hours since it was first opened) as "Data gap · 85.4 h", which reads as
/// "85.4 h of data is missing" AND implies a sync will recover it. In reality the
/// only recoverable data is what is still on the strap's ring buffer
/// (`strapPendingRecords`, ~1 record/sec); everything older was overwritten
/// (finite buffer, no seek) and is gone. This maps the real signals to copy that
/// never over-promises recovery. Pure + unit-tested; the view just renders it.
/// Live strap catch-up progress for the very bottom of Overview. Honest and
/// display-only: it renders the same persisted signals the drain itself
/// writes (frontier, durable-flush recency, lease, backlog ticket) and hides
/// entirely when there is nothing to catch up — a caught-up strap earns a
/// quiet screen, not a badge.
enum AtriaSyncProgressFooterPresentation {
    struct Footer: Equatable {
        let headline: String
        let detail: String
        /// Full-sentence status for VoiceOver: keeps the backlog wording and
        /// the reassurance clauses ("live HR current", "paused · resumes in
        /// the background") that the numbers-first visible detail no longer
        /// carries — relocated, never deleted. The state icon still carries
        /// active/paused visually.
        let accessibilityDetail: String
        let active: Bool
    }

    /// Mirrors the drain's own caught-up floor (~2 min at 1 Hz).
    static let caughtUpRecordFloor = 120

    /// A frontier this far behind is worth showing even when no ticket is
    /// pending and the strap-debt observation has gone stale (2026-08-07: a
    /// strap-off pause cleared the ticket, the count aged out, and the footer
    /// vanished while 12 h behind — "behind" is itself the reason to show).
    static let behindDisplayFloor: TimeInterval = 30 * 60

    static func behindText(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        let m = s / 60
        if m < 1 { return "moments" }
        if m < 60 { return "\(m)m" }
        return "\(m / 60)h \(m % 60)m"
    }

    static func footer(drainedThroughUnix: Double?,
                       backlogPending: Bool,
                       debtRecords: Int?,
                       debtObservedAgeSeconds: TimeInterval?,
                       secondsSinceLastFlush: TimeInterval?,
                       backgroundLeaseActive: Bool,
                       liveHeartRateIsCurrent: Bool = false,
                       now: Date,
                       calendar: Calendar = .current) -> Footer? {
        let debtFresh = debtObservedAgeSeconds.map {
            $0.isFinite && $0 >= 0
                && $0 <= AtriaMissedDataBannerPresentation.debtFreshnessWindow
        } ?? false
        let freshBacklogRecords = debtFresh ? (debtRecords ?? 0) : 0
        // A FRESH caught-up strap reading is the one signal allowed to hide a
        // stale-looking frontier (the remaining lag is phone-side processing,
        // not missing strap data).
        let freshlyCaughtUp = debtFresh
            && (debtRecords ?? 0) <= caughtUpRecordFloor
        let behindSeconds = drainedThroughUnix.map {
            now.timeIntervalSince1970 - $0
        }
        let visiblyBehind = !freshlyCaughtUp
            && (behindSeconds ?? 0) >= behindDisplayFloor
        // Show while there is genuinely something to catch up on — a pending
        // ticket, a fresh nonzero strap count, or an hours-old frontier.
        guard backlogPending
                || freshBacklogRecords > caughtUpRecordFloor
                || visiblyBehind else {
            return nil
        }
        let active: Bool = {
            if let age = secondsSinceLastFlush,
               age <= AtriaMissedDataBannerPresentation.activeDrainRecencyWindow {
                return true
            }
            return backgroundLeaseActive
        }()
        let stateText = active
            ? "catching up now"
            : "paused · resumes in the background"
        let liveText = liveHeartRateIsCurrent
            ? "live HR current · "
            : ""
        guard let drainedThroughUnix, drainedThroughUnix > 0,
              drainedThroughUnix <= now.timeIntervalSince1970 else {
            // No trustworthy frontier yet — state only, never a made-up time.
            let detail = liveText + stateText
            let capitalized = detail.prefix(1).uppercased() + detail.dropFirst()
            return Footer(headline: "Strap history backfill",
                          detail: capitalized,
                          accessibilityDetail: capitalized,
                          active: active)
        }
        let frontier = Date(timeIntervalSince1970: drainedThroughUnix)
        let timeFormatter = DateFormatter()
        timeFormatter.calendar = calendar
        timeFormatter.timeZone = calendar.timeZone
        timeFormatter.timeStyle = .short
        timeFormatter.dateStyle = .none
        let dayText: String
        if calendar.isDate(frontier, inSameDayAs: now) {
            dayText = ""
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
                  calendar.isDate(frontier, inSameDayAs: yesterday) {
            dayText = " yesterday"
        } else {
            let dayFormatter = DateFormatter()
            dayFormatter.calendar = calendar
            dayFormatter.timeZone = calendar.timeZone
            dayFormatter.dateFormat = "EEE"
            dayText = " \(dayFormatter.string(from: frontier))"
        }
        let behind = now.timeIntervalSince(frontier)
        let throughText = "\(timeFormatter.string(from: frontier))\(dayText)"
        // Same frontier, same correction as the banner above: this reads the
        // newest-ever watermark, so "through X" and "N behind" both overstated
        // it. `behind` is `now - frontier` — the AGE OF THE NEWEST RECORD, not
        // the size of the backlog, which is larger whenever holes remain behind
        // the frontier.
        return Footer(
            headline: "Newest strap record \(throughText)",
            // Numbers-first visible line; the reassurance clauses live in
            // accessibilityDetail (and the icon still shows active/paused).
            detail: "Newest \(throughText) · \(behindText(behind)) old",
            accessibilityDetail: "Newest record \(behindText(behind)) old · \(liveText)\(stateText)",
            active: active
        )
    }
}

private struct AtriaSyncProgressFooter: View {
    let liveHeartRateIsCurrent: Bool
    @State private var now = Date()
    private let refresh = Timer.publish(every: 30, on: .main, in: .common)
        .autoconnect()

    var body: some View {
        Group {
            if let footer {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: footer.active
                          ? "arrow.triangle.2.circlepath"
                          : "pause.circle")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(footer.active ? Color.cyan : Color.secondary)
                        .frame(width: 30, height: 30)
                        .background(AtriaIconTileBackground(
                            cornerRadius: 9,
                            tint: footer.active ? .cyan : .gray))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(footer.headline)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                        Text(footer.detail)
                            .font(.caption2)
                            .foregroundStyle(Color.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color(uiColor: .secondarySystemBackground),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(footer.headline). \(footer.accessibilityDetail).")
            }
        }
        .onReceive(refresh) { now = $0 }
    }

    private var footer: AtriaSyncProgressFooterPresentation.Footer? {
        let defaults = UserDefaults.standard
        let flushAt = defaults.object(
            forKey: AtriaBLEManager.OfflineSyncDefaults.lastDurableFlushBoundaryOKAt
        ) as? Double
        let debtObservedAt = defaults.object(
            forKey: AtriaBLEManager.OfflineSyncDefaults.flushDebtObservedAt
        ) as? Double
        return AtriaSyncProgressFooterPresentation.footer(
            drainedThroughUnix: defaults.object(
                forKey: AtriaBLEManager.OfflineSyncDefaults.drainedThroughUnix
            ) as? Double,
            backlogPending: defaults.bool(
                forKey: AtriaBLEManager.OfflineSyncDefaults.rangeLossBackfillPending
            ),
            debtRecords: defaults.object(
                forKey: AtriaBLEManager.OfflineSyncDefaults.flushDebtPendingRecords
            ) as? Int,
            debtObservedAgeSeconds: debtObservedAt.map {
                now.timeIntervalSince1970 - $0
            },
            secondsSinceLastFlush: flushAt.map {
                max(0, now.timeIntervalSince1970 - $0)
            },
            backgroundLeaseActive: defaults.string(
                forKey: AtriaBLEManager.OfflineSyncDefaults.backgroundLeaseStatus
            ) == "active",
            liveHeartRateIsCurrent: liveHeartRateIsCurrent,
            now: now
        )
    }
}

enum AtriaMissedDataBannerPresentation {
    struct Copy: Equatable {
        let title: String
        let subtitle: String
        /// True when there is genuinely recoverable data (so a Sync affordance is
        /// honest). False when the gap is effectively lost — the view then hides
        /// the futile sync button and offers only dismissal / start-fresh.
        let offersRecovery: Bool
    }

    /// ~5 min still bankable on the strap is the floor for calling catch-up
    /// "recoverable" rather than effectively lost.
    static let recoverableRecordFloor = 300

    /// A durable flush landing within this window means the background drain is
    /// actively working right now — even if the app is foreground/connected and
    /// the top-level status reads "deferred". Device forensics (2026-08-03)
    /// showed the drain flushing every ~2 min while the banner still displayed a
    /// 28-min-stale "~8 min on the strap", which read as "stuck". Leading with
    /// the fresh flush time is what makes a working drain look working.
    static let activeDrainRecencyWindow: TimeInterval = 12 * 60

    /// Relative "how long ago" for a durable-flush timestamp. Short by design so
    /// it never clips the single caption line.
    static func relativeAgo(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        if s < 60 { return "just now" }
        let m = s / 60
        if m < 60 { return "\(m)m ago" }
        return "\(m / 60)h ago"
    }

    /// A pending count older than this cannot prove anything about what is
    /// still on the strap (matches the drain engine's own stale-debt window in
    /// `currentFlushDebtLevel`).
    static let debtFreshnessWindow: TimeInterval = 15 * 60

    /// - Parameters:
    ///   - secondsSinceLastFlush: age of the last durable flush boundary
    ///     (`lastDurableFlushBoundaryOKAt`) — the ground-truth "is it actually
    ///     draining" signal, independent of the stale pending count.
    ///   - backgroundLeaseActive: the app holds live background execution for the
    ///     drain (`backgroundLeaseStatus == "active"`).
    ///   - debtObservedAgeSeconds: age of the pending-count observation itself
    ///     (`flushDebtObservedAt`). `nil` means never observed.
    ///   - backlogPending: the durable range-loss/backlog ticket
    ///     (`rangeLossBackfillPending`) — proof of a real gap independent of
    ///     the possibly-stale count.
    /// This many consecutive zero-progress catch-up slices (each a connect →
    /// history read → 0 durable rows / no frontier advance → link drop) means the
    /// strap genuinely can't hand over its backlog, so the clean-slate is
    /// offered. Any real progress resets the counter to 0, so a healthy strap —
    /// or one merely behind and actively draining — never reaches this.
    static let terminalStallSlices = 5
    /// A range-loss episode still pending this long has not drained at all — a
    /// healthy strap clears the flag as chunks land (resetting the request time),
    /// so an old request age means genuinely stuck. Persistent (survives
    /// relaunch) and immediate, unlike the in-memory slice count.
    static let terminalStallWindow: TimeInterval = 4 * 60 * 60

    /// Pure decision: is the gap terminally stalled (offer Start fresh)?
    /// Two un-foolable, persistent signals (either fires): the CONSECUTIVE
    /// ZERO-PROGRESS SLICE COUNT (advances only on a genuinely failed history
    /// read, resets on any real progress) and the EPISODE AGE (how long the
    /// range-loss request has stayed pending without clearing). Flush/frontier
    /// timestamps are deliberately NOT used — 0-row `finalized_bank_offload`
    /// churn and live data keep them fresh, which masked the stall on device.
    static func gapIsTerminallyStalled(
        backlogPending: Bool,
        sequenceGapParkedTerminal: Bool,
        consecutiveZeroProgressSlices: Int,
        secondsSinceRangeLossRequested: TimeInterval?,
        stallSlices: Int = terminalStallSlices,
        stallWindow: TimeInterval = terminalStallWindow
    ) -> Bool {
        guard backlogPending else { return false }
        if sequenceGapParkedTerminal { return true }
        if consecutiveZeroProgressSlices >= stallSlices { return true }
        if let age = secondsSinceRangeLossRequested, age >= stallWindow {
            return true
        }
        return false
    }

    static func copy(strapPendingRecords: Int,
                     protectsLiveStream: Bool,
                     secondsSinceLastFlush: TimeInterval?,
                     backgroundLeaseActive: Bool,
                     debtObservedAgeSeconds: TimeInterval? = 0,
                     backlogPending: Bool = false,
                     consecutiveZeroProgressSlices: Int = 0,
                     secondsSinceRangeLossRequested: TimeInterval? = nil,
                     sequenceGapParkedTerminal: Bool = false) -> Copy {
        let pending = max(0, strapPendingRecords)
        let minutes = pending / 60
        let amount = minutes >= 1 ? "~\(minutes) min" : "under a minute"

        // Recoverable. Is the background drain actively making progress? A recent
        // durable flush is the strongest proof; an active background lease is the
        // fallback. When it is, LEAD WITH THE FRESH SIGNAL so a stale pending
        // count can't read as "frozen".
        let activelyDraining: Bool = {
            if let age = secondsSinceLastFlush, age <= activeDrainRecencyWindow { return true }
            return backgroundLeaseActive
        }()

        // Terminally stalled → offer the clean slate (reuses the ✕ → Start fresh
        // wiring). This is the degraded-strap generalization: a strap that keeps
        // dropping the link on every history read never satisfies the narrow
        // "nearly empty" case below, so without this it would nag forever.
        if gapIsTerminallyStalled(
            backlogPending: backlogPending,
            sequenceGapParkedTerminal: sequenceGapParkedTerminal,
            consecutiveZeroProgressSlices: consecutiveZeroProgressSlices,
            secondsSinceRangeLossRequested: secondsSinceRangeLossRequested
        ) {
            return Copy(
                title: "Strap can't catch up",
                subtitle: "No recent progress — start fresh to clear the gap. New data is unaffected.",
                offersRecovery: false
            )
        }

        // A stale pending count cannot prove the gap is gone. With a durable
        // backlog ticket still pending, recoverability is unknown-but-likely:
        // keep the Sync affordance and never claim an amount from the dead
        // number. (2026-08-07 3 AM: an 18 h-old count of 132 hid the Sync
        // button while ~7,300 records sat on the strap.)
        let countIsFresh = debtObservedAgeSeconds.map {
            $0.isFinite && $0 >= 0 && $0 <= debtFreshnessWindow
        } ?? false
        if !countIsFresh, backlogPending {
            if activelyDraining {
                let subtitle = secondsSinceLastFlush
                    .map { "Catching up · synced \(relativeAgo($0))" } ?? "Catching up now"
                return Copy(title: "Catching up history",
                            subtitle: subtitle,
                            offersRecovery: true)
            }
            if protectsLiveStream {
                return Copy(title: "Live HR protected",
                            subtitle: "Catching up when idle",
                            offersRecovery: true)
            }
            return Copy(title: "Catching up history",
                        subtitle: "Resumes shortly",
                        offersRecovery: true)
        }

        // Little/nothing left on the strap → the gap is gone. Say so calmly and
        // never dangle a futile sync, regardless of live-stream/drain state.
        guard pending >= recoverableRecordFloor else {
            return Copy(title: "Some earlier data wasn't recorded",
                        subtitle: "New data is unaffected",
                        offersRecovery: false)
        }
        if activelyDraining {
            let subtitle = secondsSinceLastFlush
                .map { "Catching up · synced \(relativeAgo($0))" } ?? "Catching up now"
            return Copy(title: "Catching up history",
                        subtitle: subtitle,
                        offersRecovery: true)
        }

        // Recoverable but not currently draining. Subtitles are kept SHORT so the
        // single caption line never clips in the narrow banner row.
        if protectsLiveStream {
            // Live HR is streaming; catch-up is deferred to protect it.
            return Copy(title: "Live HR protected",
                        subtitle: "Catching up \(amount) when idle",
                        offersRecovery: true)
        }
        return Copy(title: "Catching up history",
                    subtitle: "\(amount) left · resumes shortly",
                    offersRecovery: true)
    }
}

private struct AtriaMissedDataBanner: View, Equatable {
    let protectsLiveStream: Bool
    let onDismiss: () -> Void
    let onSync: () -> Void
    let onStartFresh: () -> Void

    static func == (lhs: AtriaMissedDataBanner, rhs: AtriaMissedDataBanner) -> Bool {
        lhs.protectsLiveStream == rhs.protectsLiveStream
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            compactIcon
            copyBlock
            Spacer(minLength: 0)
            compactState
            dismissButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(uiColor: .secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(bannerCopy.title). \(bannerCopy.subtitle).")
    }

    private var compactIcon: some View {
        // A cyan sync-loop icon implies "recovering". For an unrecoverable gap
        // that is misleading, so use a calm, neutral info glyph instead.
        let recoverable = bannerCopy.offersRecovery
        return Image(systemName: recoverable ? "arrow.triangle.2.circlepath" : "info.circle")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(recoverable ? Color.cyan : Color.secondary)
            .frame(width: 30, height: 30)
            .background(AtriaIconTileBackground(cornerRadius: 9,
                                                tint: recoverable ? .cyan : .gray))
    }

    /// Honest banner copy driven by what is actually recoverable (strap ring-
    /// buffer pending, P6) AND whether the background drain is actively flushing
    /// (durable-flush recency + active lease) — NOT the stale pending count
    /// alone, which made a working drain read as "stuck at ~8 min".
    /// A huge backlog is a DECISION, not a status. A fresh user pairing a
    /// strap that lived with the official WHOOP app inherits weeks of foreign
    /// flash history; at ~1x replay that backlog never converges, silently
    /// starves sleep confirmation, and poisons the cycle boundary — the exact
    /// failure the owner lived through at 15.5 h, met on day one at 10x. Over
    /// a day of backlog, the banner leads with the choice instead of quietly
    /// "filling".
    private var oversizedBacklogText: String? {
        let seconds = AtriaHomeRecoverySyncPresentation.unresolvedGapSeconds(
            windows: AtriaHistoricalGapLedger.windowsForEvidence(
                defaults: .standard),
            now: Date()
        )
        guard seconds >= 24 * 3_600 else { return nil }
        return String(format: "%.0f days", (seconds / 86_400).rounded())
    }

    private var bannerCopy: AtriaMissedDataBannerPresentation.Copy {
        if let days = oversizedBacklogText {
            return .init(
                title: "This strap holds ~\(days) of history from before Atria",
                subtitle: "Syncing it all is slow and delays sleep and step "
                    + "accuracy. Start fresh keeps live tracking and lets "
                    + "today work now — recommended for a newly paired strap.",
                offersRecovery: true
            )
        }
        let defaults = UserDefaults.standard
        let pending = defaults.integer(
            forKey: AtriaBLEManager.OfflineSyncDefaults.flushDebtPendingRecords
        )
        let lastFlushAt = defaults.object(
            forKey: AtriaBLEManager.OfflineSyncDefaults.lastDurableFlushBoundaryOKAt
        ) as? Double
        let secondsSinceLastFlush = lastFlushAt.map {
            max(0, Date().timeIntervalSince1970 - $0)
        }
        let leaseActive = defaults.string(
            forKey: AtriaBLEManager.OfflineSyncDefaults.backgroundLeaseStatus
        ) == "active"
        let debtObservedAt = defaults.object(
            forKey: AtriaBLEManager.OfflineSyncDefaults.flushDebtObservedAt
        ) as? Double
        let sequenceGapParked = defaults.object(
            forKey: AtriaBLEManager.OfflineSyncDefaults.sequenceGapParkedAt
        ) != nil
        // The consecutive zero-progress slice count is the un-foolable "history
        // isn't draining" signal (0-row offloads keep flush/frontier timestamps
        // fresh, but never advance this).
        let zeroProgressSlices = defaults.integer(
            forKey: AtriaBLEManager.OfflineSyncDefaults.consecutiveZeroProgressSlices
        )
        // Episode age: how long the range-loss request has stayed pending. Set
        // once at episode start (not re-stamped per reconnect), persistent — a
        // healthy strap clears + resets it as chunks land, so a long age means
        // genuinely stuck.
        let rangeLossRequestedAt = defaults.object(
            forKey: AtriaBLEManager.OfflineSyncDefaults.rangeLossBackfillRequestedAt
        ) as? Double
        let secondsSinceRangeLossRequested: TimeInterval? = rangeLossRequestedAt.map {
            max(0, Date().timeIntervalSince1970 - $0)
        }
        return AtriaMissedDataBannerPresentation.copy(
            strapPendingRecords: pending,
            protectsLiveStream: protectsLiveStream,
            secondsSinceLastFlush: secondsSinceLastFlush,
            backgroundLeaseActive: leaseActive,
            debtObservedAgeSeconds: debtObservedAt.map {
                max(0, Date().timeIntervalSince1970 - $0)
            },
            backlogPending: defaults.bool(
                forKey: AtriaBLEManager.OfflineSyncDefaults.rangeLossBackfillPending
            ),
            consecutiveZeroProgressSlices: zeroProgressSlices,
            secondsSinceRangeLossRequested: secondsSinceRangeLossRequested,
            sequenceGapParkedTerminal: sequenceGapParked
        )
    }

    /// Transient confirmation shown when the user taps Sync, so the affordance is
    /// never a dead tap. It reflects the truth: the background drain is already
    /// catching up, and here's how recently it flushed.
    @State private var syncTapFeedback: String?

    private func handleSyncTap() {
        // `onSync` queues the exact process-local connected-history intent. It
        // is safe while live HR is protected and does not invoke the generic
        // force/cutover path.
        onSync()
        if protectsLiveStream {
            syncTapFeedback = "Queued · live tracking stays on"
            return
        }
        let defaults = UserDefaults.standard
        let lastFlushAt = defaults.object(
            forKey: AtriaBLEManager.OfflineSyncDefaults.lastDurableFlushBoundaryOKAt
        ) as? Double
        if let lastFlushAt {
            let ago = AtriaMissedDataBannerPresentation.relativeAgo(
                max(0, Date().timeIntervalSince1970 - lastFlushAt)
            )
            syncTapFeedback = "Already catching up · synced \(ago)"
        } else {
            syncTapFeedback = "Catching up in the background"
        }
    }

    private var copyBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(bannerCopy.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
            Text(syncTapFeedback ?? bannerCopy.subtitle)
                .font(.caption)
                .foregroundStyle(syncTapFeedback == nil ? Color.secondary : Color.cyan)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .task(id: syncTapFeedback) {
                    // Auto-clear the tap confirmation so the row returns to its
                    // live status line.
                    guard syncTapFeedback != nil else { return }
                    try? await Task.sleep(for: .seconds(3))
                    syncTapFeedback = nil
                }
        }
        .layoutPriority(2)
    }

    @ViewBuilder
    private var compactState: some View {
        // Only offer a Sync affordance when there is genuinely recoverable data.
        // For an old, overwritten gap a sync is futile and implies false hope.
        if bannerCopy.offersRecovery {
            Button(action: handleSyncTap) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.caption.weight(.bold))
                    // 44pt hit area (UX-quality audit 2026-07-07): the glyph
                    // stays 16pt, the target doesn't.
                    .frame(width: 32, height: 32)
                    .contentShape(.rect)
            }
            .atriaCardAction(prominent: false, tint: .cyan)
            .accessibilityLabel(protectsLiveStream
                                ? "Queue missed data sync; live tracking stays uninterrupted"
                                : "Catch up recoverable strap data now")
        }
    }

    private var dismissButton: some View {
        // Recoverable: the ✕ snoozes the catch-up status. Unrecoverable: there is
        // nothing to wait for, so the ✕ offers "Start fresh" (a confirm dialog)
        // to clear the gone gap for good — one clean affordance, no crammed button.
        Button(action: bannerCopy.offersRecovery ? onDismiss : onStartFresh) {
            Image(systemName: "xmark")
                .font(.caption.weight(.bold))
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel(bannerCopy.offersRecovery
                            ? "Dismiss catch-up status"
                            : "Start fresh; clear this unrecoverable gap")
    }

    private var missedDataDurationText: String {
        if Self.debugShowsCatchUpPill(arguments: ProcessInfo.processInfo.arguments) {
            return "3.2 h"
        }
        let defaults = UserDefaults.standard
        let requestedAt = defaults.object(forKey: AtriaBLEManager.OfflineSyncDefaults.rangeLossBackfillRequestedAt) as? Double
        let startedAt = defaults.object(forKey: AtriaBLEManager.OfflineSyncDefaults.rangeLossBackfillStartedAt) as? Double
        let reference = requestedAt ?? startedAt
        guard let reference else { return "0.0 h" }
        let hours = max(0, Date().timeIntervalSince1970 - reference) / 3600
        return String(format: "%.1f h", hours)
    }

    private var catchUpProgress: Double {
        // Retained for older handoff fixture compatibility; the current UI is a calm
        // status row and no longer renders a progress bar.
        if Self.debugShowsCatchUpPill(arguments: ProcessInfo.processInfo.arguments) {
            return 0.42
        }
        let defaults = UserDefaults.standard
        let startedAt = defaults.object(forKey: AtriaBLEManager.OfflineSyncDefaults.rangeLossBackfillStartedAt) as? Double
        let requestedAt = defaults.object(forKey: AtriaBLEManager.OfflineSyncDefaults.rangeLossBackfillRequestedAt) as? Double
        let reference = startedAt ?? requestedAt
        guard let reference else { return 0.08 }
        return min(0.96, max(0.08, Date().timeIntervalSince1970 - reference) / (30 * 60))
    }

    #if DEBUG
    private static func debugShowsCatchUpPill(arguments: [String]) -> Bool {
        guard let fixtureIndex = arguments.firstIndex(of: "--atria-ui-fixture") else { return false }
        let valueIndex = arguments.index(after: fixtureIndex)
        return arguments.indices.contains(valueIndex)
            && arguments[valueIndex] == "catching-up-pill"
    }
    #else
    private static func debugShowsCatchUpPill(arguments _: [String]) -> Bool { false }
    #endif
}

private struct AtriaWorkoutDetectionBanner: View, Equatable {
    let prompt: AtriaWorkoutDetectionPrompt
    let onDismiss: () -> Void
    let onStart: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func == (lhs: AtriaWorkoutDetectionBanner, rhs: AtriaWorkoutDetectionBanner) -> Bool {
        lhs.prompt == rhs.prompt
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    Circle()
                        .stroke(.orange.opacity(0.16), lineWidth: 8)
                    Circle()
                        .trim(from: 0, to: prompt.progressFraction)
                        .stroke(.orange, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "figure.mixed.cardio")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.orange)
                }
                .frame(width: 54, height: 54)

                VStack(alignment: .leading, spacing: 3) {
                    Text(prompt.headline)
                        .font(.headline.weight(.semibold))
                    Text(prompt.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)
                }

                Spacer(minLength: 0)

                Text("Strap HR")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(.orange.opacity(0.13), in: Capsule(style: .continuous))
            }

            workoutEvidenceRail

            HStack(spacing: 10) {
                Button(action: onStart) {
                    Text(prompt.primaryTitle)
                        .frame(maxWidth: .infinity)
                }
                .disabled(!prompt.isReviewReady)
                .atriaCardAction(tint: .orange)

                Button(action: onDismiss) {
                    Text("Not now")
                        .frame(maxWidth: .infinity)
                }
                .atriaCardAction(prominent: false, tint: .secondary)
            }
        }
        .padding(14)
        .atriaCard(emphasis: .soft)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(prompt.headline). Heart rate \(prompt.heartRate) beats per minute, \(prompt.bpmOverRest) above rest, strain \(String(format: "%.1f", prompt.strain)), \(prompt.confidenceLabel).")
    }

    private var workoutEvidenceRail: some View {
        // Two calm, clearly SEPARATED bars (user feedback 2026-07-30). The old
        // rail stacked an HR bar and a thin strain bar in ONE ZStack — the strain
        // capsule was offset just 7pt down INTO the HR capsule — so they overlapped
        // and read as one muddy bar. Each metric now owns a labeled row and its
        // own full-height track. The redundant "Strap HR / Strain" footer row and
        // the three Signal/Time/Next decision chips were dropped: the header, these
        // two bars, and the buttons already carry everything this prompt needs.
        VStack(alignment: .leading, spacing: 12) {
            evidenceBar(title: "Effort",
                        valueText: "\(prompt.heartRate) bpm · +\(prompt.bpmOverRest)",
                        fraction: min(max(Double(prompt.bpmOverRest) / 80.0, 0), 1),
                        tint: .orange,
                        rollValue: prompt.heartRate)
            evidenceBar(title: "Strain",
                        valueText: String(format: "%.1f", prompt.strain),
                        fraction: min(max(prompt.strain / 12.0, 0), 1),
                        tint: Metrics.electricStrain,
                        rollValue: prompt.strain)
        }
        .padding(12)
        // Direct child of the banner's .padding(14).atriaCard — concentric keeps
        // this panel's corners parallel to the card's (28 − 14 = 14).
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.concentric(inset: 14), style: .continuous))
    }

    private func evidenceBar(title: String, valueText: String, fraction: Double, tint: Color, rollValue: some Equatable) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.caption.weight(.bold))
                Spacer(minLength: 8)
                Text(valueText)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .contentTransition(reduceMotion ? .identity : .numericText())
                    .animation(reduceMotion ? nil : .snappy(duration: AtriaDesignTokens.Motion.emphatic),
                               value: rollValue)
            }
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(.primary.opacity(0.08))
                    Capsule(style: .continuous)
                        .fill(tint.opacity(0.7))
                        .frame(width: max(6, width * fraction))
                }
            }
            .frame(height: 7)
        }
    }
}

private struct AtriaSavedWorkoutReviewBanner: View, Equatable {
    let candidate: WorkoutReviewCandidate
    let restingHeartRate: Int
    let maxHeartRate: Int
    let onDismiss: () -> Void
    let onReview: () -> Void

    static func == (lhs: AtriaSavedWorkoutReviewBanner, rhs: AtriaSavedWorkoutReviewBanner) -> Bool {
        lhs.candidate == rhs.candidate
            && lhs.restingHeartRate == rhs.restingHeartRate
            && lhs.maxHeartRate == rhs.maxHeartRate
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    Circle()
                        .stroke(.orange.opacity(0.16), lineWidth: 8)
                    Circle()
                        .trim(from: 0, to: candidate.kind == .workout ? 1 : 0.72)
                        .stroke(.orange, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: candidate.kind == .workout ? "checkmark.seal.fill" : "figure.strengthtraining.traditional")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.orange)
                }
                .frame(width: 54, height: 54)

                VStack(alignment: .leading, spacing: 3) {
                    Text(candidate.title)
                        .font(.headline.weight(.semibold))
                    Text("\(timeRangeText) · \(durationText) from strap HR")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)
                }

                Spacer(minLength: 0)

                Text("Review")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(.orange.opacity(0.13), in: Capsule(style: .continuous))
            }

            savedWorkoutEvidenceRail
            savedWorkoutDecisionStrip

            HStack(spacing: 10) {
                Button(action: onReview) {
                    Text("Confirm type")
                        .frame(maxWidth: .infinity)
                }
                .atriaCardAction(tint: .orange)

                Button(action: onDismiss) {
                    Text("Dismiss")
                        .frame(maxWidth: .infinity)
                }
                .atriaCardAction(prominent: false, tint: .secondary)
            }
        }
        .padding(14)
        .atriaCard(emphasis: .soft)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(candidate.title). \(durationText) from strap heart rate, \(timeRangeText), peak \(candidate.peakHR) beats per minute. Strap window \(signalReviewTitle). Confirm type before saving.")
    }

    private var savedWorkoutEvidenceRail: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text("Workout window")
                    .font(.caption.weight(.bold))
                Spacer(minLength: 8)
                Text(timeRangeText)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .layoutPriority(1)
            }

            GeometryReader { proxy in
                let width = max(proxy.size.width, 1)
                let peakProgress = heartRateProgress(candidate.peakHR)
                let averageProgress = heartRateProgress(candidate.avgHR)
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(.primary.opacity(0.08))
                    Capsule(style: .continuous)
                        .fill(.orange.opacity(0.68))
                        .frame(width: max(10, width * peakProgress))
                    Capsule(style: .continuous)
                        .fill(Color.cyan.opacity(0.56))
                        .frame(width: max(8, width * averageProgress), height: 6)
                        .offset(y: 7)
                }
            }
            .frame(height: 17)

            // Colour the labels to match the two bars above (orange = peak HR,
            // cyan = average HR) so the bars are self-explanatory instead of two
            // unlabelled lines.
            HStack(spacing: 8) {
                Label("Peak \(candidate.peakHR)", systemImage: "waveform.path.ecg")
                    .foregroundStyle(.orange)
                Label("Avg \(candidate.avgHR)", systemImage: "smallcircle.filled.circle")
                    .foregroundStyle(.cyan)
                    .monospacedDigit()
                Spacer(minLength: 8)
                Text(durationText)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.caption2.weight(.semibold))
        }
        .padding(12)
        // Direct child of the banner's .padding(14).atriaCard — concentric keeps
        // this panel's corners parallel to the card's (28 − 14 = 14).
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.concentric(inset: 14), style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Workout window \(timeRangeText). Peak \(candidate.peakHR), average \(candidate.avgHR), duration \(durationText).")
    }

    private func heartRateProgress(_ bpm: Int) -> Double {
        guard maxHeartRate > restingHeartRate else { return 0 }
        let value = Double(bpm - restingHeartRate) / Double(maxHeartRate - restingHeartRate)
        return min(max(value, 0), 1)
    }

    // Was three button-looking tiles ("Review Window", "Strap <signal>", "Save
    // After type") that weren't tappable — a false affordance that just narrated
    // the flow the Confirm/Dismiss buttons already drive. Replaced with one clear
    // non-button row that keeps the genuinely useful bit — the strap signal
    // quality — and states the next action plainly.
    private var savedWorkoutDecisionStrip: some View {
        HStack(spacing: 8) {
            Image(systemName: signalReviewIcon)
                .font(.caption.weight(.bold))
                .foregroundStyle(signalReviewTint)
            Text("Strap signal: \(signalReviewTitle)")
                .font(.caption.weight(.bold))
                .foregroundStyle(signalReviewTint)
            Spacer(minLength: 8)
            Text("Confirm the type to save")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(signalReviewTint.opacity(0.10), in: Capsule(style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Strap signal \(signalReviewTitle). Confirm the activity type to save.")
    }

    // Uncalled in code but pinned by test_handoff_static_checks
    // (test_live_workout_auto_detect_prompt_is_inline_and_conservative) as
    // required structure — retained as intentional scaffolding, not deleted.
    private var reviewPathStrip: some View {
        HStack(spacing: 7) {
            pathStep("1", "Window", tint: .cyan)
            pathStep("2", "Type", tint: .orange)
            pathStep("3", "Exercises", tint: .mint)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Workout review path: adjust window, choose type, add exercises.")
    }

    private func pathStep(_ number: String, _ title: String, tint: Color) -> some View {
        HStack(spacing: 5) {
            Text(number)
                .font(.caption2.weight(.black).monospacedDigit())
                .foregroundStyle(tint)
                .frame(width: 18, height: 18)
                .background(tint.opacity(0.12), in: Circle())
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.chip, style: .continuous))
    }

    private var durationText: String {
        let minutes = candidate.durationMinutes
        if minutes >= 60 {
            return "\(minutes / 60)h \(minutes % 60)m"
        }
        return "\(minutes)m"
    }

    private var timeRangeText: String {
        let startText = candidate.start.formatted(date: .omitted, time: .shortened)
        let endText = candidate.end.formatted(date: .omitted, time: .shortened)
        return "\(startText)-\(endText)"
    }

    private var signalReviewTitle: String {
        if candidate.streamCoveragePercent >= 75, candidate.gapCount == 0 {
            return "Ready"
        }
        if candidate.streamCoveragePercent >= 60 {
            return "Review"
        }
        return "Check time"
    }

    private var signalReviewTint: Color {
        if candidate.streamCoveragePercent >= 75, candidate.gapCount == 0 { return .mint }
        if candidate.streamCoveragePercent >= 60 { return .cyan }
        return .orange
    }

    private var signalReviewIcon: String {
        if candidate.streamCoveragePercent >= 75, candidate.gapCount == 0 { return "checkmark.seal.fill" }
        if candidate.streamCoveragePercent >= 60 { return "waveform.path.badge.plus" }
        return "exclamationmark.triangle.fill"
    }

}

private struct AtriaWorkoutReviewHoldBanner: View, Equatable {
    let state: AtriaHomeView.WorkoutReviewHoldState

    static func == (lhs: AtriaWorkoutReviewHoldBanner, rhs: AtriaWorkoutReviewHoldBanner) -> Bool {
        lhs.state == rhs.state
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            holdMark

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(state.title)
                        .font(.headline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                    Text("Strap HR")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.orange.opacity(0.12), in: Capsule(style: .continuous))
                }

                Text(state.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)

                holdPathStrip
            }
        }
        .padding(14)
        .atriaCard(emphasis: .soft)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(state.accessibilityText)
    }

    private var holdMark: some View {
        ZStack {
            Circle()
                .stroke(.orange.opacity(0.16), lineWidth: 7)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(.orange, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: symbolName)
                .font(.headline.weight(.bold))
                .foregroundStyle(.orange)
        }
        .frame(width: 54, height: 54)
        .accessibilityHidden(true)
    }

    private var progress: Double {
        switch state {
        case .waitingForSettle(let bpmOverRest):
            return min(max(Double(bpmOverRest) / 70.0, 0.22), 0.88)
        case .possibleSignal:
            return 0.42
        }
    }

    private var symbolName: String {
        switch state {
        case .waitingForSettle:
            return "heart.fill"
        case .possibleSignal:
            return "waveform.path.ecg"
        }
    }

    private var holdPathStrip: some View {
        HStack(spacing: 7) {
            holdStep("1", "Observe", tint: .orange)
            holdStep("2", "Settle", tint: .cyan)
            holdStep("3", "Ask", tint: .secondary)
        }
        .accessibilityHidden(true)
    }

    private func holdStep(_ number: String, _ title: String, tint: Color) -> some View {
        HStack(spacing: 5) {
            Text(number)
                .font(.caption2.weight(.black).monospacedDigit())
                .foregroundStyle(tint)
                .frame(width: 18, height: 18)
                .background(tint.opacity(0.12), in: Circle())
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.chip, style: .continuous))
    }
}


private struct AtriaWorkoutZoneEvidenceStrip: View, Equatable {
    let zone: Metrics.HeartRateZone

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(spacing: 4) {
                ForEach(0..<6, id: \.self) { index in
                    Capsule(style: .continuous)
                        .fill(Metrics.heartRateZoneTint(index).opacity(index == zone.index ? 0.92 : 0.20))
                        .frame(maxWidth: .infinity)
                        .frame(height: index == zone.index ? 10 : 6)
                }
            }

            VStack(alignment: .trailing, spacing: 1) {
                Text(zone.title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(zone.tint)
                Text(zone.name)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.78)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(zone.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.inset, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.inset, style: .continuous)
                .stroke(zone.tint.opacity(0.14), lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Heart rate evidence \(zone.title), \(zone.name)")
    }
}

private struct AtriaWorkoutReviewFlow: View {
    let draft: AtriaWorkoutReviewDraft
    let onCancel: () -> Void
    let onSave: @MainActor (AtriaWorkoutReviewResult) async -> UserConfirmedWorkout?

    @State private var step: AtriaWorkoutReviewStep = .time
    @State private var start: Date
    @State private var end: Date
    @State private var selectedType: AtriaWorkoutActivityType = .strength
    @State private var selectedSubtype: String?
    @State private var selectedExercises = Set<String>()
    @State private var exerciseSearch = ""
    @State private var exerciseGroups: [AtriaWorkoutExerciseGroup]
    @State private var exerciseNameKeys: Set<String>
    @State private var filteredExerciseGroups: [AtriaWorkoutExerciseGroup]
    @State private var showsAllWorkoutTypes = false
    @State private var typeSearch = ""
    @State private var summaryExerciseHistoryMemo = AtriaWorkoutSummaryExerciseHistoryMemo()
    @State private var isSaving = false

    init(draft: AtriaWorkoutReviewDraft,
         onCancel: @escaping () -> Void,
         onSave: @escaping @MainActor (AtriaWorkoutReviewResult) async -> UserConfirmedWorkout?) {
        self.draft = draft
        self.onCancel = onCancel
        self.onSave = onSave
        _start = State(initialValue: draft.suggestedStart)
        _end = State(initialValue: draft.suggestedEnd)
        _selectedType = State(initialValue: draft.prompt.suggestedActivityType)
        // Detection may suggest only a broad activity type. Preserve subtype
        // abstention until the user explicitly chooses a style in review.
        _selectedSubtype = State(initialValue: nil)
        _step = State(initialValue: Self.debugInitialStep(arguments: ProcessInfo.processInfo.arguments))
        let initialExerciseGroups = AtriaWorkoutExerciseCatalog.allGroups()
        _exerciseGroups = State(initialValue: initialExerciseGroups)
        _exerciseNameKeys = State(initialValue: Self.exerciseNameKeys(in: initialExerciseGroups))
        _filteredExerciseGroups = State(initialValue: AtriaWorkoutExerciseCatalog.filteredGroups(search: "", groups: initialExerciseGroups))
    }

    private var visibleSteps: [AtriaWorkoutReviewStep] {
        selectedType.supportsExerciseSelection ? AtriaWorkoutReviewStep.allCases : [.time, .type, .summary]
    }

    private var visibleWorkoutTypes: [AtriaWorkoutActivityType] {
        // 2026-08-01 (gym-session review): the full catalog is long enough to
        // need a plain text filter. Filtering only applies to the revealed
        // full list; the compact suggested list stays untouched.
        if showsAllWorkoutTypes, !trimmedTypeSearch.isEmpty {
            return AtriaWorkoutActivityType.allCases.filter {
                $0.rawValue.localizedCaseInsensitiveContains(trimmedTypeSearch)
            }
        }
        guard !showsAllWorkoutTypes else { return AtriaWorkoutActivityType.allCases }
        var types = draft.prompt.suggestedActivityTypes
        if !types.contains(selectedType) {
            types.append(selectedType)
        }
        return types
    }

    private var trimmedTypeSearch: String {
        typeSearch.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hiddenWorkoutTypeCount: Int {
        max(AtriaWorkoutActivityType.allCases.count - visibleWorkoutTypes.count, 0)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AtriaDashboardBackdrop()
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            header
                            currentStep
                        }
                        .padding(16)
                        .padding(.bottom, 16)
                    }
                    footer
                }
            }
            .navigationTitle("Review workout")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                reloadExerciseGroups()
            }
            .onChange(of: exerciseSearch) { _, _ in
                refreshFilteredExerciseGroups()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Label("Review effort", systemImage: "waveform.path.ecg")
                .font(.headline.weight(.bold))
                .foregroundStyle(.primary)

            Spacer(minLength: 4)

            headerChip("Peak \(draft.prompt.heartRate)", tint: .orange)

            if let zone = draft.prompt.heartRateZone {
                headerChip(zone.shortLabel, tint: zone.tint)
            }

            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .frame(width: 22, height: 22)
            }
            .atriaGlassIconAction(tint: .secondary, size: 38)
            .accessibilityLabel("Cancel workout review")
        }
        .accessibilityElement(children: .contain)
    }

    private var workoutReceiptBoard: some View {
        HStack(spacing: 8) {
            workoutReceiptTile(title: "Time",
                               value: durationText,
                               detail: "\(start.formatted(date: .omitted, time: .shortened))-\(end.formatted(date: .omitted, time: .shortened))",
                               systemImage: "clock.fill",
                               tint: .cyan)
            workoutReceiptTile(title: "Peak",
                               value: "\(draft.prompt.heartRate)",
                               detail: draft.prompt.heartRateZone?.shortLabel ?? "bpm",
                               systemImage: "waveform.path.ecg",
                               tint: draft.prompt.heartRateZone?.tint ?? .orange)
            workoutReceiptTile(title: "Type",
                               value: selectedType.rawValue,
                               detail: selectedSubtype ?? "Tap type",
                               systemImage: selectedType.icon,
                               tint: .orange)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Workout receipt. Time \(durationText). Peak \(draft.prompt.heartRate). Type \(selectedType.rawValue).")
    }

    private func workoutReceiptTile(title: String,
                                    value: String,
                                    detail: String,
                                    systemImage: String,
                                    tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Image(systemName: systemImage)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(tint.opacity(0.12), in: Circle())

            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.caption.weight(.black).monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.68)
            Text(detail)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.68)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(tint.opacity(0.065), in: RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.inset, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.inset, style: .continuous)
                .stroke(tint.opacity(0.12), lineWidth: 1)
        }
    }

    private var captureEvidenceStrip: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label("What Atria saw", systemImage: "waveform.path.ecg")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.orange)
                Spacer(minLength: 8)
                Text(draft.prompt.isReviewReady ? "Ready for you" : "Check timing")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(draft.prompt.isReviewReady ? .mint : .orange)
            }

            HStack(spacing: 8) {
                captureTile(title: "Time seen",
                            value: "\(draft.prompt.evidenceMinutes)m",
                            progress: min(max(Double(draft.prompt.evidenceMinutes) / 45.0, 0.08), 1),
                            tint: .cyan)
                captureTile(title: "Signal",
                            value: draft.prompt.confidenceLabel,
                            progress: draft.prompt.progressFraction,
                            tint: .orange)
                captureTile(title: "Next",
                            value: draft.prompt.isReviewReady ? "Confirm" : "Wait",
                            progress: draft.prompt.isReviewReady ? 1 : 0.58,
                            tint: draft.prompt.isReviewReady ? .mint : .secondary)
            }
        }
        .padding(12)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.inset, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.inset, style: .continuous)
                .stroke(Color.orange.opacity(0.12), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("What Atria saw. \(draft.prompt.evidenceMinutes == 1 ? "1 minute" : "\(draft.prompt.evidenceMinutes) minutes") of strap heart rate. Signal \(draft.prompt.confidenceLabel). Next \(draft.prompt.isReviewReady ? "confirm workout" : "wait or adjust timing").")
    }

    private func captureTile(title: String, value: String, progress: Double, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Text(title)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(value)
                    .font(.caption2.monospacedDigit().weight(.black))
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.66)
            }

            GeometryReader { proxy in
                let width = max(proxy.size.width, 1)
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(tint.opacity(0.11))
                    Capsule(style: .continuous)
                        .fill(tint.opacity(0.72))
                        .frame(width: max(7, width * min(max(progress, 0), 1)))
                }
            }
            .frame(height: 7)
            .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(tint.opacity(0.06), in: RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.inset, style: .continuous))
    }

    private var reviewDecisionLens: some View {
        HStack(spacing: 8) {
            reviewDecisionMetric(title: "Confirm",
                                 value: "Looks right",
                                 systemImage: "checkmark.seal.fill",
                                 tint: .mint)
            reviewDecisionMetric(title: "Adjust",
                                 value: "Move time",
                                 systemImage: "slider.horizontal.3",
                                 tint: .cyan)
            reviewDecisionMetric(title: "Dismiss",
                                 value: "Not workout",
                                 systemImage: "xmark.circle.fill",
                                 tint: .secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Workout review choices. Confirm type, adjust time, or dismiss.")
    }

    private func reviewDecisionMetric(title: String, value: String, systemImage: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: systemImage)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .background(tint.opacity(0.12), in: Circle())
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.caption.weight(.bold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .atriaInsetCard(tint: tint)
    }

    private var stepIndicator: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ForEach(visibleSteps, id: \.self) { candidate in
                    VStack(spacing: 7) {
                        ZStack {
                            Capsule(style: .continuous)
                                .fill(candidate.rawValue <= step.rawValue ? Color.orange.opacity(0.12) : Color.secondary.opacity(0.07))
                            Text(candidate.title)
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(candidate == step ? .orange : .secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.78)
                        }
                        .frame(height: 30)

                        Capsule(style: .continuous)
                            .fill(candidate.rawValue <= step.rawValue ? Color.orange : Color.secondary.opacity(0.18))
                            .frame(height: candidate == step ? 4 : 2)
                    }
                }
            }

            Text(stepSubtitle)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 2)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Workout review step \(step.title). \(stepContextAccessibilityText)")
    }

    private var stepSubtitle: String {
        switch step {
        case .time:
            return "Confirm time."
        case .type:
            return "Choose type."
        case .exercises:
            return "Add remembered moves."
        case .summary:
            return "Save workout."
        }
    }

    private var currentStepIndex: Int {
        visibleSteps.firstIndex(of: step).map { $0 + 1 } ?? 1
    }

    private var nextStepTitle: String {
        guard let index = visibleSteps.firstIndex(of: step) else { return "Save" }
        let nextIndex = visibleSteps.index(after: index)
        guard visibleSteps.indices.contains(nextIndex) else { return "Save" }
        return visibleSteps[nextIndex].title
    }

    private var stepContextAccessibilityText: String {
        "Now \(step.title), step \(currentStepIndex) of \(visibleSteps.count). Next \(nextStepTitle)."
    }

    private var stepContextRail: some View {
        HStack(spacing: 8) {
            stepContextChip(title: "Now",
                            value: step.title,
                            detail: "\(currentStepIndex)/\(visibleSteps.count)",
                            systemImage: "location.fill",
                            tint: .orange)
            stepContextChip(title: "Next",
                            value: nextStepTitle,
                            detail: selectedType.supportsExerciseSelection ? "Moves next" : "Type only",
                            systemImage: "arrow.forward.circle.fill",
                            tint: step == visibleSteps.last ? .mint : .cyan)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(stepContextAccessibilityText)
    }

    private func stepContextChip(title: String,
                                 value: String,
                                 detail: String,
                                 systemImage: String,
                                 tint: Color) -> some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(tint.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(value)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
            }

            Spacer(minLength: 0)

            Text(detail)
                .font(.caption2.monospacedDigit().weight(.bold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(tint.opacity(0.065), in: RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.inset, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.inset, style: .continuous)
                .stroke(tint.opacity(0.12), lineWidth: 1)
        }
    }

    private func headerChip(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(tint.opacity(0.10), in: Capsule(style: .continuous))
    }

    @ViewBuilder
    private var currentStep: some View {
        switch step {
        case .time:
            timeStep
        case .type:
            typeStep
        case .exercises:
            exerciseStep
        case .summary:
            summaryStep
        }
    }

    private var timeStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepTitle("Time", subtitle: "Adjust only if needed.")
            DatePicker("Start", selection: $start, displayedComponents: [.hourAndMinute, .date])
            DatePicker("End", selection: $end, displayedComponents: [.hourAndMinute, .date])
        }
        .padding(14)
        .atriaCard(emphasis: .soft)
    }

    private var typeStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            stepTitle("Activity", subtitle: "Choose the closest match.")
            typeRevealHeader

            if showsAllWorkoutTypes {
                TextField("Search activity types", text: $typeSearch)
                    .textInputAutocapitalization(.words)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 11)
                    // Direct child of the step's .padding(14).atriaCard — concentric
                    // keeps the field's corners parallel to the card's (28 − 14 = 14).
                    .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.concentric(inset: 14), style: .continuous))
            }

            // Plain one-per-row selection list (2026-08-01 gym-session review):
            // the adaptive chip grid cropped names like "Football / soccer" and
            // relaid every chip on reveal, which made opening the full catalog
            // slow. Full-width rows never truncate and stay cheap to build.
            // With the 77-activity WHOOP-parity catalog (2026-08-05) the
            // revealed list groups by category; search stays a flat filter.
            if showsAllWorkoutTypes, trimmedTypeSearch.isEmpty {
                ForEach(AtriaWorkoutActivityType.Category.allCases) { category in
                    let types = AtriaWorkoutActivityType.allCases.filter {
                        $0.category == category
                    }
                    if !types.isEmpty {
                        Text(category.rawValue.uppercased())
                            .font(.caption2.weight(.bold))
                            .tracking(0.6)
                            .foregroundStyle(.secondary)
                            .padding(.top, 6)
                        VStack(spacing: 2) {
                            ForEach(types) { type in
                                workoutTypeRow(type)
                            }
                        }
                    }
                }
            } else {
                VStack(spacing: 2) {
                    ForEach(visibleWorkoutTypes) { type in
                        workoutTypeRow(type)
                    }
                }
            }

            if visibleWorkoutTypes.isEmpty {
                Text("No activity types match \"\(trimmedTypeSearch)\".")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !selectedType.subtypeOptions.isEmpty {
                chipSection(title: "Style", values: selectedType.subtypeOptions, selected: selectedSubtype) { value in
                    selectedSubtype = value
                }
            }
        }
        .padding(14)
        .atriaCard(emphasis: .soft)
    }

    private var typeRevealHeader: some View {
        HStack(spacing: 10) {
            Label(showsAllWorkoutTypes ? "All activity types" : "Best matches first",
                  systemImage: showsAllWorkoutTypes ? "square.grid.3x3.fill" : "scope")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            Button {
                withAnimation(.snappy(duration: AtriaDesignTokens.Motion.standard)) {
                    showsAllWorkoutTypes.toggle()
                }
                if !showsAllWorkoutTypes {
                    typeSearch = ""
                }
            } label: {
                Text(showsAllWorkoutTypes ? "Less" : "+\(hiddenWorkoutTypeCount)")
                    .font(.caption.weight(.black).monospacedDigit())
                    .foregroundStyle(.orange)
                    .frame(minWidth: 40)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
            }
            .atriaCardAction(prominent: false, tint: .orange)
            .accessibilityLabel(showsAllWorkoutTypes ? "Show fewer workout types" : "Show \(hiddenWorkoutTypeCount) more workout types")
        }
        .padding(.horizontal, 2)
        .accessibilityElement(children: .contain)
    }

    /// One plain full-width row per activity type. Selection is marked in
    /// place — the list order never changes on tap, and long names get the
    /// whole row width instead of a cropped chip.
    private func workoutTypeRow(_ type: AtriaWorkoutActivityType) -> some View {
        let selected = selectedType == type
        return Button {
            applyWorkoutType(type)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: type.icon)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(selected ? Color.orange : .secondary)
                    .frame(width: 26)
                Text(type.rawValue)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(selected ? Color.orange : Color.secondary.opacity(0.4))
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.horizontal, 10)
            .contentShape(RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.chip, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(selected ? Color.orange.opacity(0.10) : Color.clear,
                    in: RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.chip, style: .continuous))
        .accessibilityLabel(type.rawValue)
        .accessibilityValue(selected ? "Selected" : "Not selected")
    }

    private var suggestedTypeRunway: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Activity type", systemImage: "figure.strengthtraining.traditional")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                ForEach(draft.prompt.suggestedActivityTypes) { type in
                    Button {
                        applyWorkoutType(type)
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Image(systemName: type.icon)
                                .font(.headline.weight(.bold))
                                .foregroundStyle(selectedType == type ? .orange : .secondary)
                                .frame(width: 30, height: 30)
                                .background((selectedType == type ? Color.orange : Color.secondary).opacity(0.12),
                                            in: Circle())
                            Text(type.rawValue)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(selectedType == type ? .orange : .primary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)
                            Text(type.supportsExerciseSelection ? "Exercises next" : "Type only")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.70)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background((selectedType == type ? Color.orange : Color.secondary).opacity(selectedType == type ? 0.12 : 0.055),
                                    in: RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.inset, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.inset, style: .continuous)
                                .stroke((selectedType == type ? Color.orange : Color.secondary).opacity(selectedType == type ? 0.20 : 0.10), lineWidth: 1)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Suggested activity \(type.rawValue). \(type.supportsExerciseSelection ? "Exercises next" : "Type only").")
                }
            }
        }
        .padding(12)
        .atriaInsetCard(tint: .orange)
        .accessibilityElement(children: .contain)
    }

    private var selectedTypeLens: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.14))
                Image(systemName: selectedType.icon)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.orange)
            }
            .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 4) {
                Label("Selected type", systemImage: selectedType.icon)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Text(selectedType.rawValue)
                    .font(.headline.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                Text(selectedSubtype ?? (selectedType.supportsExerciseSelection ? "Exercises next" : "No exercise step"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 5) {
                Text(selectedType.supportsExerciseSelection ? "3 steps" : "2 steps")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(selectedType.supportsExerciseSelection ? .mint : .secondary)
                Text(selectedType.supportsExerciseSelection ? "Exercises" : "Type only")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .atriaInsetCard(tint: .orange)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Selected type \(selectedType.rawValue). \(selectedSubtype ?? (selectedType.supportsExerciseSelection ? "Exercises next" : "No exercise step")).")
    }

    private var exerciseStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepTitle("Exercises", subtitle: "Optional")
            if exerciseQuery.isEmpty, !promptExerciseSuggestions.isEmpty {
                exerciseQuickAddStrip
            }

            TextField("Search exercises", text: $exerciseSearch)
                .textInputAutocapitalization(.words)
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                // Direct child of the step's .padding(14).atriaCard — concentric
                // keeps the field's corners parallel to the card's (28 − 14 = 14).
                .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.concentric(inset: 14), style: .continuous))

            if !selectedExercises.isEmpty {
                chipSection(title: "Selected", values: selectedExerciseNames, selected: nil) { value in
                    selectedExercises.remove(value)
                }
            }

            if !exerciseQuery.isEmpty {
                ForEach(filteredExerciseGroups) { group in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(group.title)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 8)], spacing: 8) {
                            ForEach(group.exercises, id: \.self) { exercise in
                                exerciseChip(exercise)
                            }
                        }
                    }
                }
                if shouldOfferCustomExercise {
                    addCustomExerciseButton(exerciseQuery)
                }
            }
        }
        .padding(14)
        .atriaCard(emphasis: .soft)
    }

    private var exerciseQuickAddStrip: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("Likely moves", systemImage: "plus.circle.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text("\(selectedSuggestedExerciseCount)/\(promptExerciseSuggestions.count)")
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .foregroundStyle(.orange)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 8)], spacing: 8) {
                ForEach(promptExerciseSuggestions, id: \.self) { exercise in
                    quickExerciseButton(exercise)
                }
            }
        }
        .padding(12)
        .atriaInsetCard(tint: .orange)
        .accessibilityElement(children: .contain)
    }

    private var exerciseSearchPrompt: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.caption.weight(.bold))
                .foregroundStyle(.cyan)
                .frame(width: 28, height: 28)
                .background(Color.cyan.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text("Search only if needed")
                    .font(.caption.weight(.bold))
                    .lineLimit(1)
                Text("Skip exercises if you are unsure.")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .atriaInsetCard(tint: .cyan)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Search only if needed. Skip exercises if you are unsure.")
    }

    private var exerciseCatalogPreview: some View {
        HStack(spacing: 10) {
            Image(systemName: "books.vertical.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(.cyan)
                .frame(width: 28, height: 28)
                .background(Color.cyan.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text("Search full catalog")
                    .font(.caption.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                Text("\(AtriaWorkoutExerciseCatalog.groups.count) groups ready when needed")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .atriaInsetCard(tint: .cyan)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Search full exercise catalog. \(AtriaWorkoutExerciseCatalog.groups.count) groups ready when needed.")
    }

    private func quickExerciseButton(_ exercise: String) -> some View {
        let selected = selectedExercises.contains(exercise)
        return Button {
            toggleExercise(exercise)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: selected ? "checkmark.circle.fill" : "plus.circle")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(selected ? .mint : .orange)
                Text(exercise)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(selected ? .mint : .primary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.72)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            // Intentionally .chip (was 15): this is a grid cell in the same
            // adaptive(132) LazyVGrid family as exerciseChip, and the review
            // flow's selection surfaces (workoutTypeRow, exerciseChip) all sit
            // at .chip. H4's numeric 14–17→inset rule yields to that convention.
            .background((selected ? Color.mint : Color.orange).opacity(selected ? 0.12 : 0.08),
                        in: RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.chip, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.chip, style: .continuous)
                    .stroke((selected ? Color.mint : Color.orange).opacity(selected ? 0.18 : 0.12), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(selected ? "Remove" : "Add") \(exercise)")
    }

    private var summaryStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            stepTitle("Ready to save", subtitle: "Time, activity, and exercises save together.")

            Label(selectedType.rawValue, systemImage: selectedType.icon)
                .font(.headline.weight(.bold))
                .foregroundStyle(.orange)

            Text("\(summaryTimeRangeText) · \(durationText)")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)

            if !selectedExercises.isEmpty {
                Text(selectedExerciseNames.joined(separator: " · "))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .atriaCard(emphasis: .soft)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Ready to save. \(selectedType.rawValue), \(durationText), \(selectedExercises.count) exercises. Time, activity, and exercises save together.")
    }

    private var summaryReceiptLens: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    Circle()
                        .stroke(Color.orange.opacity(0.14), lineWidth: 7)
                    Circle()
                        .trim(from: 0, to: min(max(draft.prompt.progressFraction, 0.12), 1))
                        .stroke(Color.orange.opacity(0.88),
                                style: StrokeStyle(lineWidth: 7, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: selectedType.icon)
                        .font(.headline.weight(.black))
                        .foregroundStyle(.orange)
                }
                .frame(width: 54, height: 54)

                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedType.rawValue)
                        .font(.title3.weight(.black))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                    Text(selectedSubtype ?? "Reviewed workout")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 4) {
                    Text(durationText)
                        .font(.title2.weight(.black).monospacedDigit())
                        .foregroundStyle(.orange)
                        .contentTransition(.numericText())
                    Text("Strap HR")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.orange.opacity(0.12), in: Capsule(style: .continuous))
                }
            }

            HStack(spacing: 8) {
                summaryReceiptMetric(title: "Time",
                                     value: durationText,
                                     detail: summaryTimeRangeText,
                                     tint: .cyan)
                summaryReceiptMetric(title: "Type",
                                     value: selectedType.rawValue,
                                     detail: selectedSubtype ?? "Activity",
                                     tint: .orange)
                summaryReceiptMetric(title: "Moves",
                                     value: selectedExercises.isEmpty ? "0" : "\(selectedExercises.count)",
                                     detail: selectedExercises.isEmpty ? "Optional" : "Selected",
                                     tint: .mint)
            }

            summaryMemoryRail
            summaryExerciseHistorySection

            if let zone = draft.prompt.heartRateZone {
                AtriaWorkoutZoneEvidenceStrip(zone: zone)
            }

            if !selectedExercises.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Movements saved locally", systemImage: "checkmark.seal.fill")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                    Text(selectedExerciseNames.joined(separator: " · "))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.inset, style: .continuous))
            }
        }
        .padding(12)
        .atriaInsetCard(tint: .orange)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Workout save receipt. Window \(summaryTimeRangeText), \(durationText). Type \(selectedType.rawValue). Exercises \(selectedExercises.count). Save to history and learn from this label. Source strap heart rate.")
    }

    @ViewBuilder
    private var summaryExerciseHistorySection: some View {
        let rows = summaryExerciseHistoryRows
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Exercise history", systemImage: "chart.xyaxis.line")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text("\(rows.count)")
                        .font(.caption2.monospacedDigit().weight(.black))
                        .foregroundStyle(.orange)
                }

                ForEach(rows) { row in
                    summaryExerciseHistoryRow(row)
                }
            }
            .padding(10)
            .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.inset, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.inset, style: .continuous)
                    .stroke(Color.orange.opacity(0.10), lineWidth: 1)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Exercise history from saved sessions. \(rows.count) movements.")
        }
    }

    private var summaryExerciseHistoryRows: [AtriaWorkoutSummaryExerciseHistory] {
        let exercises = summaryExerciseHistoryNames
        let key = AtriaWorkoutSummaryExerciseHistoryMemo.Key(
            exercises: exercises.map(normalizedExercise),
            currentSets: draft.strengthSets,
            history: draft.strengthHistory)
        return summaryExerciseHistoryMemo.rows(key: key) {
            makeSummaryExerciseHistoryRows(exercises: exercises)
        }
    }

    private func makeSummaryExerciseHistoryRows(exercises: [String]) -> [AtriaWorkoutSummaryExerciseHistory] {
        exercises.map { exercise in
            let history = draft.strengthHistory.history(for: exercise)
            let records = draft.strengthHistory.records(for: exercise)
            let currentBest = draft.strengthSets
                .filter { normalizedExercise($0.exercise) == normalizedExercise(exercise) }
                .max(by: { strengthShareScore($0) < strengthShareScore($1) })
            let isPR = currentBest.map { AtriaStrengthLog.isPR($0, against: records) } ?? false
            let sparkline = history.map { strengthShareScore($0.best) }
            return AtriaWorkoutSummaryExerciseHistory(id: normalizedExercise(exercise),
                                                      exercise: exercise,
                                                      days: history.count,
                                                      bestSet: history.last?.best,
                                                      maxE1RM: records.maxE1RM,
                                                      maxWeightKg: records.maxWeightKg,
                                                      sparklineValues: sparkline,
                                                      currentPRSet: isPR ? currentBest : nil)
        }
    }

    private var summaryExerciseHistoryNames: [String] {
        var names: [String] = []
        for name in selectedExerciseNames + draft.strengthSets.map(\.exercise) {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  !names.contains(where: { normalizedExercise($0) == normalizedExercise(trimmed) }) else {
                continue
            }
            names.append(trimmed)
        }
        return Array(names.prefix(4))
    }

    private func summaryExerciseHistoryRow(_ row: AtriaWorkoutSummaryExerciseHistory) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(row.exercise)
                    .font(.caption.weight(.black))
                    .lineLimit(1)
                    .minimumScaleFactor(0.74)

                Spacer(minLength: 8)

                Text(row.days == 0 ? "New" : "\(row.days)d")
                    .font(.caption2.monospacedDigit().weight(.black))
                    .foregroundStyle(row.days == 0 ? .mint : .orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background((row.days == 0 ? Color.mint : Color.orange).opacity(0.12),
                                in: Capsule(style: .continuous))

                if row.currentPRSet != nil {
                    Label("PR", systemImage: "trophy.fill")
                        .font(.caption2.weight(.black))
                        .foregroundStyle(Metrics.electricYellow)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Metrics.electricYellow.opacity(0.12), in: Capsule(style: .continuous))
                }
            }

            AtriaWorkoutSummarySparkline(values: row.sparklineValues, tint: .orange)
                .frame(height: 32)

            HStack(spacing: 8) {
                summaryExerciseMetric("Best", row.bestSet.map(strengthSetShareText) ?? "--")
                summaryExerciseMetric("e1RM", row.maxE1RM.map { Self.formatShareWeightKg($0) } ?? "--")
                summaryExerciseMetric("Max", row.maxWeightKg.map { Self.formatShareWeightKg($0) } ?? "--")
            }
        }
        .padding(10)
        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.inset, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Exercise history \(row.exercise). \(row.days) saved days. Best \(row.bestSet.map(strengthSetShareText) ?? "none"). \(row.currentPRSet == nil ? "" : "New PR.")")
    }

    private func summaryExerciseMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption2.monospacedDigit().weight(.black))
                .lineLimit(1)
                .minimumScaleFactor(0.68)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var summaryMemoryRail: some View {
        HStack(spacing: 8) {
            summaryMemoryNode(title: "Save",
                              value: "Workout",
                              systemImage: "checkmark.seal.fill",
                              tint: .mint)
            summaryMemoryNode(title: "History",
                              value: selectedType.rawValue,
                              systemImage: "clock.arrow.circlepath",
                              tint: .orange)
            summaryMemoryNode(title: "Remember",
                              value: selectedExercises.isEmpty ? "Label" : "\(selectedExercises.count) moves",
                              systemImage: "arrow.triangle.2.circlepath",
                              tint: .cyan)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("After save, Atria adds the workout to history and remembers the selected label.")
    }

    private func summaryMemoryNode(title: String, value: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(tint.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(value)
                    .font(.caption2.weight(.black))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(tint.opacity(0.065), in: RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.inset, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.inset, style: .continuous)
                .stroke(tint.opacity(0.11), lineWidth: 1)
        }
    }

    private func summaryReceiptMetric(title: String, value: String, detail: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.68)
            Text(detail)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(tint.opacity(0.075), in: RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.inset, style: .continuous))
    }

    private var footer: some View {
        VStack(spacing: 8) {
            if let reason = saveDisabledReason {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Can't save yet. \(reason)")
            }

            HStack(spacing: 10) {
                if step != visibleSteps.first {
                    Button("Back") {
                        moveBack()
                    }
                    .atriaCardAction(prominent: false, tint: .secondary)
                    .disabled(isSaving)
                }

                // Always-visible commit (2026-08-01 gym-session review): the
                // user edited the detected window on the Time step and found no
                // Save control — only "Continue". Save is now reachable from
                // every step and commits the complete current draft.
                if step != .summary {
                    Button(isSaving ? "Saving…" : "Save") {
                        commitSave()
                    }
                    .disabled(saveDisabledReason != nil || isSaving)
                    .atriaCardAction(prominent: false, tint: .orange)
                    .accessibilityLabel("Save workout now")
                    .accessibilityHint("Saves the workout with the current time, activity, and exercises without visiting the remaining steps.")
                }

                Button(isSaving ? "Saving…" : primaryActionTitle) {
                    primaryAction()
                }
                .disabled(saveDisabledReason != nil || isSaving)
                .atriaCardAction(tint: .orange)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .atriaInsetCard(cornerRadius: 28, tint: .orange)
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    /// Non-nil while the edited window cannot be saved, with the exact reason
    /// shown next to the disabled Save/Continue buttons instead of a silently
    /// dead control.
    private var saveDisabledReason: String? {
        end > start ? nil : "End must be after start"
    }

    private var primaryActionTitle: String {
        step == .summary ? "Save" : "Continue"
    }

    private var durationText: String {
        let minutes = max(1, Int(end.timeIntervalSince(start) / 60))
        if minutes >= 60 {
            return "\(minutes / 60)h \(minutes % 60)m"
        }
        return "\(minutes)m"
    }

    private var summaryTimeRangeText: String {
        "\(start.formatted(date: .omitted, time: .shortened))-\(end.formatted(date: .omitted, time: .shortened))"
    }

    private func strengthShareScore(_ set: LoggedSet) -> Double {
        AtriaStrengthLog.estimatedOneRepMax(weightKg: set.weightKg, reps: set.reps)
            ?? set.weightKg
            ?? Double(set.reps ?? 0)
    }

    private func normalizedExercise(_ exercise: String) -> String {
        exercise.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func strengthSetShareText(_ set: LoggedSet) -> String {
        let weightText = set.weightKg.map { Self.formatShareWeightKg($0) }
        let repsText = set.reps.map { "\($0)" }
        switch (weightText, repsText) {
        case let (weight?, reps?):
            return "\(weight) x \(reps)"
        case let (weight?, nil):
            return weight
        case let (nil, reps?):
            return "\(reps) reps"
        default:
            return "New best"
        }
    }

    private static func formatShareWeightKg(_ weightKg: Double) -> String {
        let rounded = weightKg.rounded()
        if abs(weightKg - rounded) < 0.01 {
            return "\(Int(rounded)) kg"
        }
        return String(format: "%.1f kg", weightKg)
    }

    private var selectedExerciseNames: [String] {
        Array(selectedExercises).sorted()
    }

    private var exerciseQuery: String {
        exerciseSearch.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var shouldOfferCustomExercise: Bool {
        guard !exerciseQuery.isEmpty else { return false }
        return !exerciseNameKeys.contains(Self.exerciseNameKey(exerciseQuery))
    }

    private var promptExerciseSuggestions: [String] {
        draft.prompt.exerciseSuggestions.flatMap { suggestion in
            AtriaWorkoutExerciseCatalog.suggestedExercises(for: suggestion)
        }
    }

    private var selectedSuggestedExerciseCount: Int {
        promptExerciseSuggestions.filter { selectedExercises.contains($0) }.count
    }

    private func stepTitle(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline.weight(.bold))
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func chipSection(title: String,
                             values: [String],
                             selected: String?,
                             onTap: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                ForEach(values, id: \.self) { value in
                    Button(value) { onTap(value) }
                        .buttonStyle(.plain)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity)
                        .background((selected == value ? Color.orange : Color.secondary).opacity(0.12),
                                    in: Capsule(style: .continuous))
                        .foregroundStyle(selected == value ? Color.orange : Color.secondary)
                }
            }
        }
    }

    private func exerciseChip(_ exercise: String) -> some View {
        let selected = selectedExercises.contains(exercise)
        return Button {
            toggleExercise(exercise)
        } label: {
            Text(exercise)
                .font(.caption.weight(.semibold))
                .lineLimit(2)
                .minimumScaleFactor(0.76)
                .frame(maxWidth: .infinity, minHeight: 42)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        // Genuine grid chip — .chip (was 14) despite H4's numeric 14–17→inset
        // rule; 14 is nearer the chip rung and this IS a chip semantically.
        .background((selected ? Color.orange : Color.secondary).opacity(selected ? 0.14 : 0.08),
                    in: RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.chip, style: .continuous))
        .foregroundStyle(selected ? Color.orange : Color.primary)
    }

    private func addCustomExerciseButton(_ exercise: String) -> some View {
        Button {
            AtriaWorkoutExerciseCatalog.addCustomExercise(exercise)
            selectedExercises.insert(exercise)
            reloadExerciseGroups(search: "")
            exerciseSearch = ""
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus.circle.fill")
                    .font(.callout.weight(.bold))
                    .foregroundStyle(.mint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add \"\(exercise)\"")
                        .font(.caption.weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    Text("Save as a custom exercise")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            // Intentionally .chip (was 15): renders directly below the 12-radius
            // exerciseChip grid as "one more item" in the exercise selection
            // area — matching the chips beats H4's numeric 14–17→inset rule,
            // which would put an 18 corner flush under a field of 12s.
            .background(Color.mint.opacity(0.10), in: RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.chip, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.chip, style: .continuous)
                    .stroke(Color.mint.opacity(0.18), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add custom exercise \(exercise)")
    }

    private func toggleExercise(_ exercise: String) {
        if selectedExercises.contains(exercise) {
            selectedExercises.remove(exercise)
        } else {
            selectedExercises.insert(exercise)
        }
    }

    private func reloadExerciseGroups(search: String? = nil) {
        let groups = AtriaWorkoutExerciseCatalog.allGroups()
        exerciseGroups = groups
        exerciseNameKeys = Self.exerciseNameKeys(in: groups)
        filteredExerciseGroups = AtriaWorkoutExerciseCatalog.filteredGroups(search: search ?? exerciseSearch, groups: groups)
    }

    private func refreshFilteredExerciseGroups() {
        filteredExerciseGroups = AtriaWorkoutExerciseCatalog.filteredGroups(search: exerciseSearch, groups: exerciseGroups)
    }

    private static func exerciseNameKeys(in groups: [AtriaWorkoutExerciseGroup]) -> Set<String> {
        Set(groups.flatMap(\.exercises).map(exerciseNameKey))
    }

    private static func exerciseNameKey(_ exercise: String) -> String {
        exercise
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private func primaryAction() {
        if step == .summary {
            commitSave()
            return
        }
        if step == .type, !selectedType.supportsExerciseSelection {
            step = .summary
            return
        }
        if let index = visibleSteps.firstIndex(of: step),
           visibleSteps.indices.contains(visibleSteps.index(after: index)) {
            step = visibleSteps[visibleSteps.index(after: index)]
        }
    }

    /// The single commit path shared by the summary primary action and the
    /// always-visible footer Save (2026-08-01): every save routes the complete
    /// current draft through the same canonical onSave call.
    private func commitSave() {
        guard !isSaving, end > start else { return }
        isSaving = true
        Task { @MainActor in
            _ = await onSave(AtriaWorkoutReviewResult(
                start: start,
                end: end,
                activityType: selectedType.rawValue,
                activitySubtype: selectedSubtype,
                exerciseNames: selectedExerciseNames,
                strengthSets: draft.strengthSets
            ))
            isSaving = false
        }
    }

    private func applyWorkoutType(_ type: AtriaWorkoutActivityType) {
        selectedType = type
        selectedSubtype = nil
        if !selectedType.supportsExerciseSelection {
            selectedExercises.removeAll()
        }
    }

    private func moveBack() {
        guard let index = visibleSteps.firstIndex(of: step), index > 0 else { return }
        step = visibleSteps[index - 1]
    }

    #if DEBUG
    private static func debugInitialStep(arguments: [String]) -> AtriaWorkoutReviewStep {
        if arguments.contains("--atria-workout-review-type-step") { return .type }
        if arguments.contains("--atria-workout-review-exercises-step") { return .exercises }
        if arguments.contains("--atria-workout-review-summary-step") { return .summary }
        return .time
    }
    #else
    private static func debugInitialStep(arguments: [String]) -> AtriaWorkoutReviewStep { .time }
    #endif
}

private final class AtriaWorkoutSummaryExerciseHistoryMemo {
    struct Key: Equatable {
        let exercises: [String]
        let currentSets: [LoggedSet]
        let history: StrengthHistoryProjection
    }

    private var key: Key?
    private var value: [AtriaWorkoutSummaryExerciseHistory] = []

    func rows(key: Key, build: () -> [AtriaWorkoutSummaryExerciseHistory]) -> [AtriaWorkoutSummaryExerciseHistory] {
        if self.key == key { return value }
        let next = build()
        self.key = key
        value = next
        return next
    }
}

private struct AtriaWorkoutSummaryExerciseHistory: Identifiable, Equatable {
    let id: String
    let exercise: String
    let days: Int
    let bestSet: LoggedSet?
    let maxE1RM: Double?
    let maxWeightKg: Double?
    let sparklineValues: [Double]
    let currentPRSet: LoggedSet?
}

private struct AtriaWorkoutSummarySparkline: View {
    let values: [Double]
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            let normalized = normalizedValues
            let width = max(proxy.size.width, 1)
            let height = max(proxy.size.height, 1)
            let step = normalized.count > 1 ? width / CGFloat(normalized.count - 1) : width
            Path { path in
                guard let first = normalized.first else { return }
                path.move(to: CGPoint(x: 0, y: height - (height * first)))
                for index in normalized.indices.dropFirst() {
                    path.addLine(to: CGPoint(x: CGFloat(index) * step,
                                             y: height - (height * normalized[index])))
                }
            }
            .stroke(tint.opacity(normalized.count > 1 ? 0.90 : 0.28),
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))

            if normalized.isEmpty {
                Capsule(style: .continuous)
                    .fill(Color.secondary.opacity(0.16))
                    .frame(height: 3)
                    .position(x: width / 2, y: height / 2)
            }
        }
        .accessibilityHidden(true)
    }

    private var normalizedValues: [CGFloat] {
        guard let minValue = values.min(),
              let maxValue = values.max(),
              maxValue > 0 else {
            return []
        }
        let spread = max(maxValue - minValue, 1)
        return values.map { value in
            CGFloat(0.16 + (0.78 * ((value - minValue) / spread)))
        }
    }
}

/// Owns dashboard scroll state outside `AtriaHomeView`, preventing every
/// scroll quantum from invalidating the app shell while allowing viewport-
/// pinned overlays to respond directly to the real ScrollView offset.
private struct AtriaDashboardScrollSurface<Content: View>: View {
    let showsCompactTodayHeader: Bool
    let prefersLiveActivityStatus: Bool
    let refresh: @MainActor () async -> Void
    let taskID: String
    let autoScroll: @MainActor (ScrollViewProxy) async -> Void
    @ViewBuilder let content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsCompactHeader = false

    init(showsCompactTodayHeader: Bool,
         prefersLiveActivityStatus: Bool,
         refresh: @escaping @MainActor () async -> Void,
         taskID: String,
         autoScroll: @escaping @MainActor (ScrollViewProxy) async -> Void,
         @ViewBuilder content: @escaping () -> Content) {
        self.showsCompactTodayHeader = showsCompactTodayHeader
        self.prefersLiveActivityStatus = prefersLiveActivityStatus
        self.refresh = refresh
        self.taskID = taskID
        self.autoScroll = autoScroll
        self.content = content
    }

    var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView(showsIndicators: false) {
                content()
            }
            .scrollContentBackground(.hidden)
            // The tabViewBottomAccessory (Live pill) stacks ON TOP of the
            // glass tab capsule, and on this iOS beta its height is not
            // added to the scroll safe area — the last card ("Start
            // activity", the plan pill) ended up permanently clipped
            // behind the bottom chrome (seen live 2026-08-05). Explicit
            // bottom margin keeps every card reachable; scroll-under still
            // shows content beneath the glass while scrolling.
            .contentMargins(.bottom, 72, for: .scrollContent)
            .scrollEdgeEffectStyle(.soft, for: .top)
            .refreshable { await refresh() }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top >= 112
            } action: { _, newValue in
                if newValue != showsCompactHeader { showsCompactHeader = newValue }
            }
            .overlayPreferenceValue(AtriaTodayCompactRingPreferenceKey.self) { presentation in
                ZStack(alignment: .topTrailing) {
                    if showsCompactTodayHeader,
                       !prefersLiveActivityStatus,
                       showsCompactHeader,
                       let presentation {
                        AtriaTodayCompactRingRail(slots: presentation.slots,
                                                  accessibilitySummary: presentation.accessibilitySummary)
                            .transition(reduceMotion ? .identity : .move(edge: .top).combined(with: .opacity))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                // The overlay consumes the scene's live safe-area geometry;
                // it cannot drift beside or underneath the Dynamic Island.
                .safeAreaPadding(.top, 8)
                .padding(.trailing, 12)
                .allowsHitTesting(false)
                .animation(reduceMotion ? nil : .snappy(duration: AtriaDesignTokens.Motion.standard), value: showsCompactHeader)
            }
            .task(id: taskID) {
                await autoScroll(scrollProxy)
            }
        }
    }
}

struct AtriaLiveTabAccessoryPresentation: Equatable {
    let heartRate: Int
    /// WORKOUT strain (the projection's HUD text, "--" before evidence).
    /// This pill is the minimized workout: rendering the day total here made
    /// the bar read "3.2 strain" while the workout screen it reopens said
    /// 1.5 (physically reported 2026-08-13). Workout surfaces carry workout
    /// numbers; the day total lives on the hero ring.
    let strainText: String

    var accessibilityLabel: String {
        let heartRateText = heartRate > 0
            ? "Heart rate \(heartRate) beats per minute"
            : "Heart rate unavailable"
        let strainPhrase = strainText == "--"
            ? "workout strain not yet available"
            : "workout strain \(strainText)"
        return "Live workout minimized. Tap to return. \(heartRateText), \(strainPhrase)."
    }
}

private struct AtriaLiveTabAccessoryHost: View {
    let pulseStore: AtriaHomeModel.PulseLiveStore
    // Only this accessory subtree observes the 750 ms workout projection —
    // the tab shell keeps retaining the store by identity without observing
    // it (the store's own publication contract).
    @ObservedObject var metricStore: AtriaLiveWorkoutMetricStore
    let workoutStart: Date?
    let workoutSystemImage: String
    let onOpenWorkout: () -> Void

    var body: some View {
        AtriaLiveTabAccessory(pulseStore: pulseStore,
                              workoutStart: workoutStart,
                              workoutSystemImage: workoutSystemImage,
                              strainText: metricStore.state.strainHUDText,
                              onOpenWorkout: onOpenWorkout)
    }
}

private struct AtriaLiveTabAccessory: View {
    let pulseStore: AtriaHomeModel.PulseLiveStore
    let workoutStart: Date?
    let workoutSystemImage: String
    let strainText: String
    let onOpenWorkout: () -> Void
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    private var isInline: Bool {
        placement == .inline
    }

    var body: some View {
        if let workoutStart {
            AtriaLiveWorkoutTabAccessory(pulseStore: pulseStore,
                                         workoutStart: workoutStart,
                                         workoutSystemImage: workoutSystemImage,
                                         strainText: strainText,
                                         isInline: isInline,
                                         onOpenWorkout: onOpenWorkout)
        }
    }
}

private struct AtriaLiveWorkoutTabAccessory: View {
    @ObservedObject var pulseStore: AtriaHomeModel.PulseLiveStore
    let workoutStart: Date
    let workoutSystemImage: String
    let strainText: String
    let isInline: Bool
    let onOpenWorkout: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let presentation = AtriaLiveTabAccessoryPresentation(heartRate: pulseStore.state.heartRate,
                                                              strainText: strainText)
        Button(action: onOpenWorkout) {
            HStack(spacing: isInline ? 8 : 10) {
                Image(systemName: workoutSystemImage)
                    .font(isInline ? .caption.weight(.bold) : .subheadline.weight(.bold))
                    .foregroundStyle(Metrics.electricStrain)

                TimelineView(.periodic(from: workoutStart, by: 1)) { context in
                    Text(elapsedText(context.date, since: workoutStart))
                        .font((isInline ? Font.caption : Font.subheadline).weight(.bold))
                        .monospacedDigit()
                        .contentTransition(reduceMotion ? .identity : .numericText())
                        .animation(reduceMotion ? nil : .snappy(duration: AtriaDesignTokens.Motion.emphatic),
                                   value: context.date)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                        .layoutPriority(2)
                }

                Text(pulseStore.state.heartRate > 0 ? "\(pulseStore.state.heartRate) bpm" : "-- bpm")
                    .font((isInline ? Font.caption : Font.subheadline).weight(.semibold))
                    .monospacedDigit()
                    .contentTransition(reduceMotion ? .identity : .numericText())
                    .animation(reduceMotion ? nil : .snappy(duration: AtriaDesignTokens.Motion.emphatic),
                               value: pulseStore.state.heartRate)
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)
                    .allowsTightening(true)
                    .layoutPriority(3)

                Text("\(strainText) strain")
                    .font((isInline ? Font.caption2 : Font.caption).weight(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(reduceMotion ? .identity : .numericText())
                    .animation(reduceMotion ? nil : .snappy(duration: AtriaDesignTokens.Motion.emphatic),
                               value: strainText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)

                if !isInline { Spacer(minLength: 0) }
            }
            .padding(.horizontal, isInline ? 8 : 12)
            .padding(.vertical, isInline ? 4 : 8)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(presentation.accessibilityLabel)
    }

    private func elapsedText(_ date: Date, since start: Date) -> String {
        let total = max(0, Int(date.timeIntervalSince(start)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%02d:%02d", m, s)
    }
}

private struct AtriaStandByOverlay: View {
    @ObservedObject var coreLiveStore: AtriaHomeModel.CoreLiveStore
    @ObservedObject var pulseLiveStore: AtriaHomeModel.PulseLiveStore
    @ObservedObject var heroStore: AtriaHomeModel.HeroStore
    let dismiss: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            HStack(alignment: .center, spacing: 28) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(.green)
                            .frame(width: 10, height: 10)
                        Text(coreLiveStore.state.deviceName.isEmpty ? "Atria live" : coreLiveStore.state.deviceName)
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.72))
                    }

                    Text(pulseLiveStore.state.heartRateText)
                        .font(.system(size: 118, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .contentTransition(reduceMotion ? .identity : .numericText())
                        .animation(reduceMotion ? nil : .snappy(duration: AtriaDesignTokens.Motion.emphatic),
                                   value: pulseLiveStore.state.heartRate)
                        .foregroundStyle(.white)
                        .minimumScaleFactor(0.45)
                        .allowsTightening(true)
                        .layoutPriority(2)

                    Text(pulseLiveStore.state.hasPulseSignal ? "BPM live" : "BPM waiting")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.58))
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(spacing: 14) {
                    AtriaStandByMetric(title: "Recovery",
                                       value: heroStore.state.recoveryValue,
                                       detail: heroStore.state.recoveryDetail,
                                       tint: .green)
                    AtriaStandByMetric(title: "Strain",
                                       value: String(format: "%.1f", heroStore.state.strain),
                                       detail: heroStore.state.strainConfidence,
                                       tint: .orange)
                    AtriaStandByMetric(title: "Calories",
                                       value: coreLiveStore.state.liveActiveCaloriesText,
                                       detail: coreLiveStore.state.liveActiveCalories == nil ? "Profile needed" : "Active estimate",
                                       tint: .pink)
                    if coreLiveStore.state.batteryLevel >= 0 {
                        AtriaStandByMetric(title: "Battery",
                                           value: coreLiveStore.state.batteryStatusSummaryText,
                                           detail: coreLiveStore.state.batteryDetailText,
                                           tint: .cyan)
                    }
                }
                .frame(width: 230)
            }
            .padding(.horizontal, 48)
            .padding(.vertical, 34)

            VStack {
                HStack {
                    Spacer()
                    Button(action: dismiss) {
                        Image(systemName: "xmark")
                            .font(.headline.weight(.bold))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.glass)
                    .accessibilityLabel("Dismiss StandBy view")
                }
                Spacer()
            }
            .padding(24)
        }
        .accessibilityElement(children: .contain)
    }
}

private struct AtriaStandByMetric: View {
    let title: String
    let value: String
    let detail: String
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
            Text(value)
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(reduceMotion ? .identity : .numericText())
                .animation(reduceMotion ? nil : .snappy(duration: AtriaDesignTokens.Motion.emphatic),
                           value: value)
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(detail)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white.opacity(0.58))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.inset, style: .continuous)
                .fill(.white.opacity(0.08))
                .overlay {
                    RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.inset, style: .continuous)
                        .stroke(.white.opacity(0.10), lineWidth: 1)
                }
        }
    }
}

/// Main-actor admission for the saved/archive aggregate projection. Live HR can
/// request UI publication several times per second, while this projection scans
/// saved sessions and their accepted-HR rows. Keep exactly one worker active and
/// collapse any authority burst to the newest trailing generation; an older
/// result can never publish over a newer request.
struct AtriaHomeSavedAggregateRefreshGate: Equatable, Sendable {
    enum Admission: Equatable, Sendable {
        case start(UInt64)
        case coalesced
    }

    enum Completion: Equatable, Sendable {
        case ignored
        case publish
        case start(UInt64)
    }

    private(set) var latestGeneration: UInt64 = 0
    private(set) var inFlightGeneration: UInt64?
    private(set) var trailingGeneration: UInt64?

    mutating func request() -> Admission {
        latestGeneration &+= 1
        guard inFlightGeneration == nil else {
            trailingGeneration = latestGeneration
            return .coalesced
        }
        inFlightGeneration = latestGeneration
        return .start(latestGeneration)
    }

    mutating func complete(_ generation: UInt64) -> Completion {
        guard inFlightGeneration == generation else { return .ignored }
        inFlightGeneration = nil
        if let trailingGeneration {
            self.trailingGeneration = nil
            inFlightGeneration = trailingGeneration
            return .start(trailingGeneration)
        }
        return generation == latestGeneration ? .publish : .ignored
    }

    var outstandingWorkUpperBound: Int {
        (inFlightGeneration == nil ? 0 : 1)
            + (trailingGeneration == nil ? 0 : 1)
    }
}

/// Scene-owned authority for Home's ephemeral live presentation. Bluetooth,
/// journaling, stress persistence, widgets, and ActivityKit keep their own
/// bounded acquisition/durability lanes; this gate controls only mutations of
/// the observable stores that render Home. While the scene is not active, any
/// number of source publications collapse to one dirty bit. The next inactive
/// -> active edge consumes that bit with exactly one latest-value catch-up.
struct AtriaHomeLivePresentationAuthority: Equatable, Sendable {
    enum Transition: Equatable, Sendable {
        case unchanged
        case suspended
        case catchUpLatest
    }

    private(set) var isActive = false
    private(set) var hasSuppressedMutation = false
    private(set) var catchUpIsPending = false

    mutating func admitsMutation(applicationIsActive: Bool) -> Bool {
        guard isActive, applicationIsActive else {
            hasSuppressedMutation = true
            catchUpIsPending = true
            return false
        }
        return true
    }

    mutating func beginCatchUpIfAuthorized(
        applicationIsActive: Bool
    ) -> Bool {
        guard isActive, applicationIsActive else {
            if isActive {
                hasSuppressedMutation = true
                catchUpIsPending = true
            }
            return false
        }
        guard catchUpIsPending else { return false }
        catchUpIsPending = false
        hasSuppressedMutation = false
        return true
    }

    mutating func transition(to active: Bool) -> Transition {
        guard active != isActive else { return .unchanged }
        isActive = active
        catchUpIsPending = true
        guard active else { return .suspended }
        return .catchUpLatest
    }
}

@MainActor
final class AtriaHomeModel {
    nonisolated static let liveHeartRateFreshnessInterval: TimeInterval = 6
    /// Charging is a short explicit-evidence lease, not a percentage trend.
    /// The strap can keep reporting rising SOC after physical removal, so the
    /// top-left bolt disappears within 90 seconds unless another accepted
    /// powered-state packet renews it.
    nonisolated static let freshChargerEvidenceInterval: TimeInterval = 90

    struct BatteryChargeProjection: Equatable {
        let status: AtriaBLEManager.BatteryChargeStatus
        let isCharging: Bool
    }

    nonisolated static func resolvedBatteryChargeProjection(
        liveStatus: AtriaBLEManager.BatteryChargeStatus,
        liveIsCharging: Bool,
        batteryRecentlyDropping: Bool,
        persistedStatus: AtriaBLEManager.BatteryChargeStatus,
        persistedAge: TimeInterval,
        freshnessInterval: TimeInterval = freshChargerEvidenceInterval
    ) -> BatteryChargeProjection {
        if !batteryRecentlyDropping,
           liveStatus == .charging,
           liveIsCharging {
            return BatteryChargeProjection(status: .charging, isCharging: true)
        }

        // A live, explicit non-powered state always outranks older persisted
        // charger proof, even while that older event is still within its TTL.
        if liveStatus == .notCharging || liveStatus == .full {
            return BatteryChargeProjection(status: liveStatus, isCharging: false)
        }

        // Persisted charger state cannot outlive the live connection. Both
        // decoded powered sources can be latched across physical removal, so a
        // reconnect/unknown live state must never resurrect an old bolt.
        _ = persistedStatus
        _ = persistedAge
        _ = freshnessInterval

        // A status/flag mismatch is not charger evidence. Fail closed until a
        // fresh explicit event arrives; percentage movement is intentionally
        // absent from this resolver.
        if liveStatus == .charging || liveIsCharging {
            return BatteryChargeProjection(status: .levelOnly, isCharging: false)
        }
        return BatteryChargeProjection(status: liveStatus, isCharging: false)
    }

    /// Selects the evidence clock that authorizes a powered presentation.
    /// Same-state charger events publish a new live timestamp even when the
    /// status enum itself does not change. Persisted proof is a reconnect-only
    /// fallback and is bounded by the same freshness window.
    nonisolated static func resolvedBatteryChargeVerifiedAt(
        projection: BatteryChargeProjection,
        liveVerifiedAt: Date?,
        persistedStatus: AtriaBLEManager.BatteryChargeStatus,
        persistedAge: TimeInterval,
        now: Date,
        freshnessInterval: TimeInterval = freshChargerEvidenceInterval
    ) -> Date? {
        guard projection.status == .charging, projection.isCharging else { return nil }
        if let liveVerifiedAt {
            let liveAge = now.timeIntervalSince(liveVerifiedAt)
            if liveAge >= 0, liveAge <= freshnessInterval { return liveVerifiedAt }
        }
        guard persistedStatus == .charging,
              persistedAge >= 0,
              persistedAge <= freshnessInterval else { return nil }
        return now.addingTimeInterval(-persistedAge)
    }

    struct StatusState: Equatable {
        var status: AtriaBLEManager.Status
        var bluetoothPermissionDenied: Bool
        var officialAppCoexistenceRisk: AtriaBLEManager.OfficialAppCoexistenceRisk
        var isBluetoothReady: Bool
    }

    struct CoreLiveState: Equatable {
        static let liveRecoveryGraceInterval: TimeInterval = 45

        var status: AtriaBLEManager.Status
        var bluetoothPermissionDenied: Bool
        var deviceName: String
        var displayDeviceName: String
        var batteryLevel: Int
        var batteryIsCharging: Bool
        var batteryChargeStatus: AtriaBLEManager.BatteryChargeStatus
        var batteryRecentlyDropping: Bool
        var batteryReadingIsRecentBaseline: Bool
        var batteryLastVerifiedAt: Date?
        var batteryChargeLastVerifiedAt: Date?
        var strapStreamState: AtriaBLEManager.StrapStreamState
        var rrContinuityState: String
        var hrvSDNN: Double?
        var hrvPNN50: Double?
        var sessionSampleCount: Int
        var hasRecentHeartRateSample: Bool
        var lastReadingAt: Date?
        var liveTRIMP: Double
        var liveActiveCalories: Double?
        var strapStepResearchCount: Int
        var strapStepResearchState: String
        var dailyStepPresentation: AtriaDailyStepPresentation
        var officialAppCoexistenceRisk: AtriaBLEManager.OfficialAppCoexistenceRisk
        var lastScanRequestedAt: Date?
        var lastScanMatchAt: Date?
        var pendingKnownReconnectStartedAt: Date?
        var pendingKnownReconnectReason: String
        var rangeLossBackfillPending: Bool
        var historicalRecoveryPresentation: AtriaBLEManager.HistoricalRecoveryPresentation

        var batteryText: String { batteryLevel >= 0 ? "\(batteryLevel)%" : "--" }
        var batteryChargeText: String {
            guard batteryLevel >= 0 else { return "No fresh reading" }
            switch batteryChargeStatus {
            case .levelOnly: return "Charge unavailable"
            case .charging: return "Strap charging"
            case .notCharging: return "Strap not charging"
            case .full: return "Strap full"
            }
        }
        private var hasActiveChargingEvidence: Bool {
            batteryIsCharging && batteryChargeStatus == .charging && !batteryRecentlyDropping
        }
        var batteryShowsPowered: Bool { hasActiveChargingEvidence }
        var batteryChargeCompactText: String {
            if batteryChargeStatus == .charging && !hasActiveChargingEvidence {
                return "Charge unavailable"
            }
            switch batteryChargeStatus {
            // "Charge unavailable" stays visible — it is a provenance fact,
            // not decoration. The charge states drop the redundant "Strap"
            // prefix on strap-owned surfaces; the fuller wording survives in
            // batteryChargeText / batteryAccessibilityChargeText.
            case .levelOnly: return "Charge unavailable"
            case .charging: return "Charging"
            case .notCharging: return "Not charging"
            case .full: return "Full"
            }
        }
        var batteryHeaderChargeText: String {
            guard batteryLevel >= 0 else { return "--" }
            if batteryChargeStatus == .charging && !hasActiveChargingEvidence {
                return "--"
            }
            switch batteryChargeStatus {
            case .levelOnly: return "--"
            case .charging: return "Strap charging"
            case .notCharging: return "Strap not charging"
            case .full: return "Strap full"
            }
        }
        var batteryHeaderAccessoryText: String? {
            if batteryChargeStatus == .charging && !hasActiveChargingEvidence {
                return nil
            }
            switch batteryChargeStatus {
            case .charging: return "Charging"
            case .full: return "Full"
            case .levelOnly, .notCharging: return nil
            }
        }
        var batteryAccessibilityChargeText: String {
            guard batteryLevel >= 0 else { return "no fresh reading" }
            return batteryHeaderChargeText == "--" ? batteryChargeText : batteryHeaderChargeText
        }
        var batteryAccessibilityText: String {
            guard batteryLevel >= 0 else { return "Strap battery unavailable." }
            return "Strap battery \(batteryText), \(batteryAccessibilityChargeText)."
        }
        var batteryStatusSummaryText: String {
            guard batteryLevel >= 0 else { return "--" }
            // Compact surfaces communicate external power with the battery
            // symbol's bolt; repeating "Charging" wastes space and truncates.
            if batteryShowsPowered || batteryChargeStatus == .full {
                return batteryText
            }
            if batteryReadingIsRecentBaseline {
                return "\(batteryText) · \(batteryRecencyText)"
            }
            return batteryChargeStatus == .levelOnly
                ? batteryText : "\(batteryText) · \(batteryChargeCompactText)"
        }
        var batteryRecencyText: String {
            Self.batteryRecencyText(verifiedAt: batteryLastVerifiedAt)
        }
        static func batteryRecencyText(verifiedAt: Date?, now: Date = Date()) -> String {
            guard let verifiedAt else { return "Recent" }
            let age = max(0, now.timeIntervalSince(verifiedAt))
            if age < 60 { return "just now" }
            if age < 3_600 { return "\(max(1, Int(age / 60)))m ago" }
            return "\(max(1, Int(age / 3_600)))h ago"
        }
        /// If a connectivity surface includes a percentage, its age belongs
        /// to the level-bearing battery packet. A newer HR packet proves only
        /// that the link is alive and must not make an older battery value look
        /// freshly measured.
        var connectivityFreshnessText: String {
            Self.connectivityFreshnessText(
                batteryLevel: batteryLevel,
                batteryVerifiedAt: batteryLastVerifiedAt,
                heartRateReadingAt: lastReadingAt
            )
        }
        static func connectivityFreshnessText(
            batteryLevel: Int,
            batteryVerifiedAt: Date?,
            heartRateReadingAt: Date?,
            now: Date = Date()
        ) -> String {
            if batteryLevel >= 0 {
                return batteryRecencyText(verifiedAt: batteryVerifiedAt, now: now)
            }
            guard let heartRateReadingAt else { return "recently" }
            let age = max(0, now.timeIntervalSince(heartRateReadingAt))
            if age < 2 { return "just now" }
            if age < 60 { return "\(Int(age.rounded())) s ago" }
            if age < 3_600 { return "\(Int((age / 60).rounded())) min ago" }
            return "\(Int((age / 3_600).rounded())) hr ago"
        }
        var lastReadingAgeText: String {
            guard let lastReadingAt else { return "recently" }
            let age = max(0, Date().timeIntervalSince(lastReadingAt))
            if age < 2 { return "just now" }
            if age < 60 { return "\(Int(age.rounded())) s ago" }
            if age < 3_600 { return "\(Int((age / 60).rounded())) min ago" }
            return "\(Int((age / 3_600).rounded())) hr ago"
        }
        var batteryDetailText: String {
            guard batteryLevel >= 0 else { return "No fresh reading" }
            if batteryChargeStatus == .charging && !hasActiveChargingEvidence {
                return "Battery updated \(batteryRecencyText) · charge state unavailable"
            }
            if batteryChargeStatus == .levelOnly {
                return "Battery updated \(batteryRecencyText)"
            }
            return "\(batteryHeaderChargeText) · battery updated \(batteryRecencyText)"
        }
        var rrContinuityText: String { rrContinuityState.replacingOccurrences(of: "_", with: " ") }
        var hrvSDNNText: String { hrvSDNN.map { "\(Int($0.rounded()))" } ?? "--" }
        var hrvPNN50Text: String { hrvPNN50.map { "\(Int($0.rounded()))%" } ?? "--" }
        var needsRRQualityCoach: Bool { rrContinuityState == "poor_contact" }
        func pendingKnownReconnectAge(now: Date = Date()) -> TimeInterval? {
            pendingKnownReconnectStartedAt.map { now.timeIntervalSince($0) }
        }
        func isInRecentLiveRecovery(now: Date = Date()) -> Bool {
            guard !hasRecentHeartRateSample, status != .poweredOff else { return false }
            if let reconnectAge = pendingKnownReconnectAge(now: now),
               reconnectAge >= 0,
               reconnectAge <= Self.liveRecoveryGraceInterval {
                return true
            }
            guard rangeLossBackfillPending else { return false }
            if let matchAt = lastScanMatchAt,
               now.timeIntervalSince(matchAt) <= Self.liveRecoveryGraceInterval {
                return true
            }
            if let requestedAt = lastScanRequestedAt,
               now.timeIntervalSince(requestedAt) <= Self.liveRecoveryGraceInterval {
                return status == .connecting || status == .scanning
            }
            return false
        }
        var liveActiveCaloriesText: String { liveActiveCalories.map { "\(Int($0.rounded()))" } ?? "--" }
        var strapStepsAreValidated: Bool {
            WidgetSnapshotPublisher.strapStepsAreValidated(state: strapStepResearchState)
        }
        var strapStepResearchText: String {
            dailyStepPresentation.valueText
        }
        var hasStrapStepResearch: Bool { dailyStepPresentation.count != nil }
        var isLowBatteryBroadcastShutoff: Bool { strapStreamState == .lowBatteryShutoff }
        var isLowBatteryLiveLimited: Bool {
            strapStreamState == .lowBatteryShutoff || strapStreamState == .lowBatteryReducedDetail
        }
        /// Wear/charge re-attribution for the pulseless states. Device-proven
        /// 2026-08-28: a charging off-wrist strap flapped "No signal"→"Live"
        /// all night. Each claim here is evidence-backed (the strap's own
        /// HR==0 stream, or the bounded charge proof); ambiguity falls
        /// through to the unchanged honest copy below.
        var strapWearAttribution: AtriaStrapWearAttribution {
            AtriaStrapWearAttribution.classify(
                streamState: strapStreamState,
                hasFreshPulse: hasRecentHeartRateSample,
                lastAcceptedPulseAt: lastReadingAt,
                chargingProven: batteryIsCharging,
                batteryRecentlyDropping: batteryRecentlyDropping
            )
        }

        var strapStreamConnectionLabel: String {
            switch strapWearAttribution {
            case .charging: return "Charging"
            case .offWrist: return "Off wrist"
            case .none: break
            }
            switch strapStreamState {
            case .live:
                return "Live"
            case .lowBatteryShutoff:
                return "Charge strap"
            case .lowBatteryReducedDetail:
                return "Low battery"
            case .silentUnknown:
                return "No signal"
            case .warming:
                return "Waiting"
            case .unknown:
                return hasRecentHeartRateSample ? "Live" : "Waiting"
            }
        }
        var strapStreamConnectionDetail: String {
            switch strapWearAttribution {
            case .charging: return "No pulse while charging — resumes on wear"
            case .offWrist: return "Strap streams but sees no pulse"
            case .none: break
            }
            // Per-state short forms; each keeps the honest state fact
            // (arriving / too low / reduced / connected-but-silent / pending).
            switch strapStreamState {
            case .live:
                return "HR arriving"
            case .lowBatteryShutoff:
                return "Too low for live HR"
            case .lowBatteryReducedDetail:
                return "Reduced detail until charged"
            case .silentUnknown:
                return "Connected — no live HR"
            case .warming:
                return "Waiting for live heart rate"
            case .unknown:
                return hasRecentHeartRateSample ? "HR arriving" : "Waiting for live heart rate"
            }
        }
        var strapStreamConnectionSymbol: String {
            switch strapWearAttribution {
            case .charging: return "battery.100percent.bolt"
            case .offWrist: return "applewatch.slash"
            case .none: break
            }
            switch strapStreamState {
            case .live:
                return "bolt.heart.fill"
            case .lowBatteryShutoff, .lowBatteryReducedDetail:
                return "battery.25percent"
            case .silentUnknown:
                return "heart.slash"
            case .warming:
                return "waveform.path.ecg"
            case .unknown:
                return hasRecentHeartRateSample ? "bolt.heart.fill" : "waveform.path.ecg"
            }
        }

        /// SF Symbol matching the level, with the bolt overlay while charging.
        /// One ladder for the whole app (AtriaBatteryIdentity); this file used
        /// to carry two byte-identical copies (2026-08-28).
        var batterySymbol: String {
            guard batteryLevel >= 0 else { return "questionmark.circle" }
            return AtriaBatteryIdentity.systemImage(percent: batteryLevel,
                                                    isCharging: batteryShowsPowered)
        }
    }

    struct PulseLiveState: Equatable {
        var heartRate: Int
        var hasContact: Bool
        var sensorHasContact: Bool
        var averageHeartRate: Int?
        var peakHeartRate: Int?
        var heartRateZone: Metrics.HeartRateZone?
        var recentRRSamples: [AtriaBreathworkSession.RRSample] = []

        var heartRateText: String { heartRate > 0 ? "\(heartRate)" : "--" }
        var hasPulseSignal: Bool { heartRate > 0 || hasContact }
        var needsContactCoach: Bool { !hasPulseSignal && !sensorHasContact }
        var contactText: String { hasPulseSignal ? "Live" : "No signal" }
        var averageHeartRateText: String { averageHeartRate.map(String.init) ?? "--" }
        var peakHeartRateText: String { peakHeartRate.map(String.init) ?? "--" }
    }

    struct HeroPulseState: Equatable {
        var heartRate: Int
        var hasContact: Bool
        var sensorHasContact: Bool
        var heartRateZone: Metrics.HeartRateZone?
        var heartRateBroadcastActive: Bool = false
        var recentRRSamples: [AtriaBreathworkSession.RRSample] = []

        var heartRateText: String { heartRate > 0 ? "\(heartRate)" : "--" }
        var hasPulseSignal: Bool { heartRate > 0 || hasContact }
        var needsContactCoach: Bool { !hasPulseSignal && !sensorHasContact }
    }

    struct PulseSparklineState: Equatable {
        var values: [Int]
        var chartPoints: [HeartRateChartPoint]
    }

    struct HeartRateChartPoint: Identifiable, Equatable {
        let t: Date
        let bpm: Int

        var id: TimeInterval { t.timeIntervalSinceReferenceDate }
    }

    struct CollectionLiveState: Equatable {
        var isRecording: Bool
        var capturedRows: Int
        var captureSummary: String
        var captureWasValidationReady: Bool
        var lastCaptureFile: String
        var standardHROnlyEnabled: Bool
        var longWearModeEnabled: Bool
        var rangeLossBackfillPending: Bool
        var collectionProfile: AtriaBLEManager.CollectionProfile
        var officialAppCoexistenceRisk: AtriaBLEManager.OfficialAppCoexistenceRisk

        var recordingState: String { isRecording ? "Recording" : (captureWasValidationReady ? "Ready" : "Idle") }
        var captureFileLabel: String { lastCaptureFile.isEmpty ? "None" : "Saved" }
        var modeLabel: String {
            longWearModeEnabled ? "All-day wear" : collectionProfile.label
        }
        var coexistenceStatusText: String { officialAppCoexistenceRisk.label }
    }

    struct HeroSnapshot: Equatable {
        let recoveryEstimate: Metrics.RecoveryEstimate
        let recoveryIsProvisional: Bool
        /// A numeric score may remain visible through the next civil day while
        /// the new overnight sleep has not yet been found or confirmed. Keep
        /// the score (it is still real), but never imply it belongs to today's
        /// sleep cycle.
        let recoveryIsFromPreviousSleep: Bool
        /// Handoff-10 CP1: the explicit presentation identity of this hero.
        /// A Today-labelled surface may only render `.current`/`.currentPartial`
        /// values as primary; the prior cycle survives in `priorCycleDisclosure`
        /// as a dated secondary line. Included in equality so a cycle/day
        /// change forces a republish even when the numbers happen to match.
        let identity: AtriaMetricPresentationIdentity?
        let priorCycleDisclosure: AtriaPriorCycleDisclosure?
        let strain: Double
        let strainConfidence: String
        /// Fraction of the elapsed physiological day covered by accepted strap
        /// wear, or nil before the day is long enough to judge (< 3h elapsed).
        ///
        /// This was already being computed in makeHeroSnapshot, used once to
        /// pick a confidence word, and then thrown away -- so a card could say
        /// a number was a lower bound while having no way to state the coverage
        /// that made it one. Carried on the snapshot so the expanded detail can
        /// show the real percentage instead of restating the adjective.
        let dayWearCoverageFraction: Double?
        let guidance: Coach.Guidance
        let hrvValue: String
        let hrvDetail: String
        let hrvNarrative: String
        let stressLevel: AtriaStressLevel?
        let stressValue: String
        let stressDetail: String
        let stressNarrative: String
        /// Compact consumers preserve the scorer's evidence provenance. A
        /// complete v3 HR-only fact remains numeric and is labelled lower
        /// confidence in `stressDetail`.
        let stressEvidenceMode: AtriaStressEvidenceMode?
        let stressMetricTitle: String
        let rrPackageText: String
        let nextAction: String
        let headline: String
        let sessionsCount: Int
        let baselineSamples: Int
        let backupValue: String
        let backupDetail: String
        let restingHeartRate: Int
        let restingHeartRateText: String
        let strainNarrative: String
        let loadRatioText: String
        let loadTargetText: String
        let loadConfidence: String
        let loadReadinessText: String
        let loadACWRSignalText: String
        let loadMonotonyText: String
        let loadMonotonySignalText: String
        let loadACWRDetailText: String
        let loadMonotonyDetailText: String
        let loadSignalSummaryText: String
        let loadNarrative: String
        let hrZoneMinutes: TodayHRZoneMinutes
        /// §13.4 display metadata only — the fused day TRIMP and its
        /// logged-lifting component. Zero (fail-closed) when the date-honest
        /// identity overrides today's strain or on the disconnected fallback;
        /// consumers must then make no combined/split claim.
        var dayTRIMP: Double = 0
        var muscularTRIMP: Double = 0

        /// Home and Today render a compact projection of the canonical stress
        /// state, but a scored enum alone does not prove the reading is still
        /// current. Reuse the same source-clock policy as the expanded Stress
        /// detail and fail closed without changing the scorer's state/history.
        nonisolated static func resolvedStressPresentation(
            state: AtriaStressState,
            lastMeasuredAt: Date?,
            physiologicalCycleStart: Date? = nil,
            now: Date = Date()
        ) -> AtriaStressPresentation {
            let presentation = AtriaStressPresentation.make(state: state)
            guard state.kind == .scored else { return presentation }

            switch AtriaStressReadingFreshness.resolve(
                isScored: true,
                updatedAt: lastMeasuredAt,
                physiologicalCycleStart: physiologicalCycleStart,
                now: now
            ) {
            case .live:
                return presentation
            case .stale:
                return AtriaStressPresentation(
                    level: nil,
                    value: AtriaCompactMetricPresentation.noValue,
                    detail: "Waiting for a fresh stress reading",
                    narrative: "The last scored stress reading is older than 90 seconds, so Atria is not showing it as current."
                )
            case .previousPhysiologicalCycle:
                return AtriaStressPresentation(
                    level: nil,
                    value: AtriaCompactMetricPresentation.noValue,
                    detail: "Waiting for this cycle's first stress reading",
                    narrative: "The last scored stress reading belongs to the previous physiological day, so Atria is not showing it as current."
                )
            case .untimed:
                return AtriaStressPresentation(
                    level: nil,
                    value: AtriaCompactMetricPresentation.noValue,
                    detail: "Reading time unavailable",
                    narrative: "Atria cannot verify when this stress reading was measured, so it is not shown as current."
                )
            }
        }

        var recoveryValue: String {
            Self.recoveryValueText(recoveryEstimate: recoveryEstimate)
        }

        static func recoveryValueText(
            recoveryEstimate: Metrics.RecoveryEstimate
        ) -> String {
            recoveryEstimate.percent.map { "\($0)%" }
                ?? AtriaCompactMetricPresentation.noValue
        }

        var recoveryDetail: String {
            Self.recoveryDetailText(recoveryEstimate: recoveryEstimate,
                                    recoveryIsProvisional: recoveryIsProvisional,
                                    recoveryIsFromPreviousSleep: recoveryIsFromPreviousSleep)
        }

        /// One shared, testable wording policy for the hero, Today, sharing,
        /// and StandBy. This is presentation only; it never changes which
        /// Recovery estimate is selected or when a physiological day advances.
        static func recoveryDetailText(
            recoveryEstimate: Metrics.RecoveryEstimate,
            recoveryIsProvisional: Bool,
            recoveryIsFromPreviousSleep: Bool
        ) -> String {
            // Compact fixed-vocabulary marker, not prose. The marker stays
            // short beside a ring already showing the score; the full reason
            // belongs in the expanded detail.
            //
            // HRV availability now comes from the estimate's structured
            // `usesHRV` flag instead of sniffing its prose for the substring
            // "HRV unavailable". That flag is set false at exactly the sites
            // that emit those details, so this is the authoritative source and
            // cannot drift when the wording changes.
            let presentation = AtriaCompactMetricPresentation.recovery(
                percent: recoveryEstimate.percent,
                confidence: recoveryEstimate.confidence,
                usesHRV: recoveryEstimate.usesHRV,
                isProvisional: recoveryIsProvisional,
                isFromPreviousSleep: recoveryIsFromPreviousSleep
            )
            let base = presentation.marker ?? presentation.level.shortLabel
            return base
        }

        var strainValue: String {
            Metrics.StrainPresentation.resolve(
                value: strain,
                coverageFraction: dayWearCoverageFraction,
                baseConfidence: strainConfidence,
                additionalIncompleteEvidence:
                    strainConfidence.localizedCaseInsensitiveContains("partial")
            ).valueText
        }

        var strainDetail: String {
            // §13.4: the fused number is only shown as an explicitly labeled
            // combined total. strainConfidence itself must stay untouched —
            // "partial" sniffing keys on it.
            muscularTRIMP > 0
                ? "\(strainConfidence) · \(AtriaCompactMetricPresentation.combinedCardioLiftingMarker)"
                : strainConfidence
        }

        static func == (lhs: HeroSnapshot, rhs: HeroSnapshot) -> Bool {
            lhs.recoveryEstimate.percent == rhs.recoveryEstimate.percent
                && lhs.recoveryEstimate.confidence == rhs.recoveryEstimate.confidence
                && lhs.recoveryEstimate.detail == rhs.recoveryEstimate.detail
                && lhs.recoveryIsProvisional == rhs.recoveryIsProvisional
                && lhs.recoveryIsFromPreviousSleep == rhs.recoveryIsFromPreviousSleep
                && lhs.identity == rhs.identity
                && lhs.priorCycleDisclosure == rhs.priorCycleDisclosure
                && lhs.strainConfidence == rhs.strainConfidence
                && lhs.dayWearCoverageFraction == rhs.dayWearCoverageFraction
                && lhs.guidance == rhs.guidance
                && lhs.hrvValue == rhs.hrvValue
                && lhs.hrvDetail == rhs.hrvDetail
                && lhs.hrvNarrative == rhs.hrvNarrative
                && lhs.stressLevel == rhs.stressLevel
                && lhs.stressValue == rhs.stressValue
                && lhs.stressDetail == rhs.stressDetail
                && lhs.stressNarrative == rhs.stressNarrative
                && lhs.stressEvidenceMode == rhs.stressEvidenceMode
                && lhs.stressMetricTitle == rhs.stressMetricTitle
                && lhs.rrPackageText == rhs.rrPackageText
                && lhs.nextAction == rhs.nextAction
                && lhs.headline == rhs.headline
                && lhs.sessionsCount == rhs.sessionsCount
                && lhs.baselineSamples == rhs.baselineSamples
                && lhs.backupValue == rhs.backupValue
                && lhs.backupDetail == rhs.backupDetail
                && lhs.restingHeartRate == rhs.restingHeartRate
                && lhs.restingHeartRateText == rhs.restingHeartRateText
                && lhs.strainNarrative == rhs.strainNarrative
                && lhs.loadRatioText == rhs.loadRatioText
                && lhs.loadTargetText == rhs.loadTargetText
                && lhs.loadConfidence == rhs.loadConfidence
                && lhs.loadReadinessText == rhs.loadReadinessText
                && lhs.loadACWRSignalText == rhs.loadACWRSignalText
                && lhs.loadMonotonyText == rhs.loadMonotonyText
                && lhs.loadMonotonySignalText == rhs.loadMonotonySignalText
                && lhs.loadACWRDetailText == rhs.loadACWRDetailText
                && lhs.loadMonotonyDetailText == rhs.loadMonotonyDetailText
                && lhs.loadSignalSummaryText == rhs.loadSignalSummaryText
                && lhs.loadNarrative == rhs.loadNarrative
                && lhs.hrZoneMinutes == rhs.hrZoneMinutes
                && lhs.muscularTRIMP == rhs.muscularTRIMP
                && Self.displayTRIMPBucket(lhs.dayTRIMP) == Self.displayTRIMPBucket(rhs.dayTRIMP)
                && Self.displayStrainBucket(lhs.strain) == Self.displayStrainBucket(rhs.strain)
        }

        private static func displayStrainBucket(_ value: Double) -> Int {
            Int((value * 10).rounded())
        }

        /// Whole-TRIMP bucket: dayTRIMP moves with live TRIMP each tick; raw
        /// equality would republish the hero at ~1 Hz.
        private static func displayTRIMPBucket(_ value: Double) -> Int {
            Int(value.rounded())
        }
    }

    struct Snapshot: Equatable {
        let referenceText: String
        let sleepValue: String
        let sleepDetail: String
        let workoutText: String
        let loggingText: String
        let trendCoverageText: String
        let trendConfidence: String
        let trendDetail: String
        let confirmedWorkouts: Int
        let confirmedSleeps: Int
    }

    struct HomeStatsState: Equatable {
        let rrPackageText: String
        let hrvDetail: String
        let nextAction: String
        let sessionsCount: Int
        let baselineSamples: Int
        let backupValue: String
        let backupDetail: String
        let restingHeartRate: Int
        let restingHeartRateText: String
    }

    struct ProfileMetricsState: Equatable {
        let vo2MaxEstimate: VO2MaxEstimateSummary
        let biologicalAgeSummary: BiologicalAgeSummary
    }

    struct ActivityState: Equatable {
        let sleepHistorySnapshot: SleepHistorySnapshot
        let sleepHistorySnapshotRevision: Int
        let pendingSleepReview: SleepHistorySnapshot.Night?
        let napReviewCandidates: [SleepHistorySnapshot.Night]
        let confirmedWorkouts: [UserConfirmedWorkout]
        let confirmedWorkoutsRevision: Int
        let workoutReviewCandidate: WorkoutReviewCandidate?
        let activityDetections: [ActivityDetection]
        let historySnapshotRevision: Int
        let reviewFingerprint: String
        let dailyRollupHistory: [DailyRollupStoreEntry]
        let dailyRollupHistoryRevision: Int
    }

    final class HeroStore: ObservableObject {
        @Published fileprivate(set) var state: HeroSnapshot

        init(state: HeroSnapshot) {
            self.state = state
        }
    }

    final class CoreLiveStore: ObservableObject {
        @Published fileprivate(set) var state: CoreLiveState

        init(state: CoreLiveState) {
            self.state = state
        }
    }

    final class PulseLiveStore: ObservableObject {
        @Published fileprivate(set) var state: PulseLiveState

        init(state: PulseLiveState) {
            self.state = state
        }
    }

    final class HeroPulseStore: ObservableObject {
        @Published fileprivate(set) var state: HeroPulseState

        init(state: HeroPulseState) {
            self.state = state
        }
    }

    final class PulseSparklineStore: ObservableObject {
        @Published fileprivate(set) var state: PulseSparklineState

        init(state: PulseSparklineState) {
            self.state = state
        }
    }

    final class CollectionLiveStore: ObservableObject {
        @Published fileprivate(set) var state: CollectionLiveState

        init(state: CollectionLiveState) {
            self.state = state
        }
    }

    final class SnapshotStore: ObservableObject {
        @Published fileprivate(set) var state: Snapshot
        @Published fileprivate(set) var diagnosticsReady = false

        init(state: Snapshot) {
            self.state = state
        }
    }

    final class HomeStatsStore: ObservableObject {
        @Published fileprivate(set) var state: HomeStatsState

        init(state: HomeStatsState) {
            self.state = state
        }
    }

    final class ProfileStore: ObservableObject {
        @Published fileprivate(set) var profile: AthleteProfile

        init(profile: AthleteProfile) {
            self.profile = profile
        }
    }

    final class ProfileMetricsStore: ObservableObject {
        @Published fileprivate(set) var state: ProfileMetricsState

        init(state: ProfileMetricsState) {
            self.state = state
        }
    }

    final class ActivityStore: ObservableObject {
        @Published private(set) var state: ActivityState

        init(state: ActivityState) {
            self.state = state
        }

        @discardableResult
        func refresh(_ next: ActivityState) -> Bool {
            guard next != state else { return false }
            state = next
            return true
        }
    }

    final class StatusStore: ObservableObject {
        @Published fileprivate(set) var state: StatusState

        init(state: StatusState) {
            self.state = state
        }
    }

    let heroStore: HeroStore
    let heroPulseStore: HeroPulseStore
    let statusStore: StatusStore
    let coreLiveStore: CoreLiveStore
    let pulseLiveStore: PulseLiveStore
    let pulseSparklineStore: PulseSparklineStore
    let collectionLiveStore: CollectionLiveStore
    let snapshotStore: SnapshotStore
    let homeStatsStore: HomeStatsStore
    let profileStore: ProfileStore
    let profileMetricsStore: ProfileMetricsStore
    let stressMonitorStore: AtriaStressMonitorStore
    let todaySessionProjectionStore: AtriaTodaySessionProjectionStore
    let activityStore: ActivityStore

    private let ble: AtriaBLEManager
    private let store: SessionStore
    private var cancellables = Set<AnyCancellable>()
    private let coreRefreshSubject = PassthroughSubject<Void, Never>()
    private let heroRefreshSubject = PassthroughSubject<Void, Never>()
    private let diagnosticsRefreshSubject = PassthroughSubject<Void, Never>()
    private let storeRefreshSubject = PassthroughSubject<Void, Never>()
    private var deferredDetails: DeferredDetails?
    private var savedAggregate: SavedAggregate
    private var diagnosticsRequested = false
    private var diagnosticsPresentationIsDirty = false
    private var diagnosticsPresentationResumeScheduled = false
    private var applicationActivationRetryScheduled = false
    private var livePresentationWatchdogTimer: Timer?
    private var liveSessionDerived: LiveSessionDerived
    private var diagnosticsWorkItem: DispatchWorkItem?
    private var diagnosticsWorkInFlight = false
    private var diagnosticsRefreshToken = UUID()
    private var liveHeartRateFreshnessTask: Task<Void, Never>?
    private var stressFreshnessExpiryTask: Task<Void, Never>?
    private var savedAggregateCycleRolloverTask: Task<Void, Never>?
    private var savedAggregateRefreshGate = AtriaHomeSavedAggregateRefreshGate()
    private var pendingSavedAggregateRefreshReason = "initial"
    private let savedAggregateRefreshQueue = DispatchQueue(
        label: "com.adidshaft.atria.home-saved-aggregate",
        qos: .utility
    )
    private var historicalStressReplayGate = AtriaHistoricalStressReplayGenerationGate()
    private var historicalStressCalibrationPublicationGate =
        AtriaHistoricalStressCalibrationPublicationGate()
    private var historicalStressReplayWorker: Task<(AtriaHistoricalStressReplay.Result, AtriaHistoricalStressReplay.GapClassificationDraft?, String?), Never>?
    private let historicalStressReplayTriggerSubject = PassthroughSubject<Void, Never>()
    /// Publishes the exact fallback resting-HR scalar consumed by historical
    /// personalization while the durable baseline is still learning.
    private let historicalStressFallbackRestSubject = CurrentValueSubject<Int, Never>(60)
    private var prefersPulseSparklineUpdates = false
    private var prefersActivityProjectionUpdates = false
    private var activityProjectionIsDirty = false
    private var activityProjectionRefreshScheduled = false
    private var livePresentationAuthority = AtriaHomeLivePresentationAuthority()
    private var scenePresentationIsActive = false
    private var stressPresentationPublicationIsSynchronizing = false
    private var latestHeartRateBroadcastActive = false
    private var profileMetricsKey: ProfileMetricsKey?
    private var savedRestingFallbackCache: SavedRestingFallbackCache?
    #if DEBUG
    private let debugHeroFixture: HeroSnapshot?
    #endif

    private struct SavedAggregate: Equatable {
        let cycleStart: Date
        /// The current wake boundary was drawn by an unconfirmed no-sleep
        /// fallback (a synthetic civil-day rollover), not a confirmed main
        /// sleep. Drives the step presentation's carry-forward so a shifted
        /// sleeper's steps are not stranded in "Yesterday" while today shows
        /// "--" across a fabricated boundary.
        let cycleBoundaryIsUnconfirmedFallback: Bool
        /// The effective start of the CONTINUOUS active period the cumulative
        /// Today metrics (strain/TRIMP/calories/wear) integrate over. Equals
        /// `cycleStart` normally; across an unconfirmed no-sleep fallback it
        /// reaches back to the pre-boundary slice of the same wear period
        /// (bounded to an 18h window) so a synthetic rollover does not zero
        /// those metrics. Steps and the canonical `cycleStart` are deliberately
        /// NOT keyed to this. Used as the wear-coverage denominator origin so it
        /// stays consistent with the folded observed seconds.
        let strainAccumulationStart: Date
        let restingContext: RestingMetricContext
        let savedTodayTRIMP: Double
        let savedActiveSessionTRIMP: Double
        let savedTodayMuscularTRIMP: Double
        let savedTodayActiveCalories: Double?
        let savedActiveSessionActiveCalories: Double?
        let savedTodayStrapSteps: Int
        let savedActiveSessionStrapSteps: Int
        let savedActiveSessionTotalStrapSteps: Int
        let hasSavedToday: Bool
        let sessionsCount: Int
        let baselineSamples: Int
        let confirmedWorkouts: Int
        let confirmedSleeps: Int
        let savedTodayObservedSeconds: TimeInterval
    }

    private struct SavedAggregateRefreshInput: @unchecked Sendable {
        /// COW value snapshots captured at the authority edge. Their reducers
        /// run on `savedAggregateRefreshQueue`; MainActor only retains storage.
        let source: SessionStore.HomeSavedAggregateSourceSnapshot
        let baseline: PersonalBaseline
        let liveRestingHeartRate: Int?
        let activeSessionID: UUID?
        let confirmedWorkouts: Int
        let windowEnd: Date
    }

    private struct DeferredDetails: Equatable {
        let hrvValue: String
        let hrvDetail: String
        let hrvNarrative: String
        let rrPackageText: String
        let referenceText: String
        let sleepValue: String
        let sleepDetail: String
        let workoutText: String
        let loggingText: String
        let backupValue: String
        let backupDetail: String
        let trendCoverageText: String
        let trendConfidence: String
        let trendDetail: String
        let nextAction: String
        let headline: String
        let confirmedWorkouts: Int
        let confirmedSleeps: Int
    }

    // Cold-start seed (launch time-to-content fix, 2026-07-05): the app used to
    // seed this store with a hardcoded "Waiting"/"Preparing" placeholder that
    // stayed on screen until the diagnostics kickoff ran (seconds later). All
    // of the data this needs (dailyRollupHistory, confirmed sleeps/workouts,
    // baseline) is already loaded synchronously in SessionStore.init, so build
    // the first frame from real saved numbers instead.
    //
    // This is split into a thin store-reading wrapper and a pure function
    // (`makeColdStartSnapshot(rollup:rollupIsToday:...)`) so the shaping logic
    // is unit-testable without constructing a SessionStore (which touches the
    // real on-disk sessions.json / daily-rollups.json) -- see
    // AtriaLaunchTimeToContentTests.
    private static func makeColdStartSnapshot(store: SessionStore) -> Snapshot {
        let calendar = Calendar.current
        let now = Date()
        let todayRollup = store.dailyRollupHistory.first { calendar.isDate($0.day, inSameDayAs: now) }
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now) ?? now
        let rollup = todayRollup ?? store.dailyRollupHistory.first { calendar.isDate($0.day, inSameDayAs: yesterday) }
        // Last-known widget snapshot: a same-day fallback when there is no
        // rollup yet at all (e.g. first launch ever, or the rollup file hasn't
        // been written for today), so the first frame still shows the last
        // numbers the widget/Lock Screen displayed rather than "Preparing".
        let widgetSnapshot = rollup == nil ? AtriaIntentSnapshotStore.loadLatestSnapshot() : nil

        return Self.makeColdStartSnapshot(rollup: rollup,
                                          rollupIsToday: todayRollup != nil,
                                          recentRollupCount: store.dailyRollupHistory.prefix(14).count,
                                          widgetSnapshot: widgetSnapshot,
                                          freshHRVSampleCount: store.baseline.freshHRVSampleCount(),
                                          confirmedWorkouts: store.confirmedWorkouts.count,
                                          confirmedSleeps: store.confirmedSleeps.count)
    }

    static func makeColdStartSnapshot(rollup: DailyRollupStoreEntry?,
                                      rollupIsToday: Bool,
                                      recentRollupCount: Int,
                                      widgetSnapshot: WidgetSnapshot?,
                                      freshHRVSampleCount: Int,
                                      confirmedWorkouts: Int,
                                      confirmedSleeps: Int) -> Snapshot {
        let sleepValue: String
        let sleepDetail: String
        if let seconds = rollup?.sleepSeconds, seconds > 0 {
            sleepValue = String(format: "%.1fh", seconds / 3600)
            sleepDetail = rollupIsToday ? "saved history" : "yesterday's saved rollup"
        } else if let hours = widgetSnapshot?.sleepHours, hours > 0 {
            sleepValue = String(format: "%.1fh", hours)
            sleepDetail = "last known"
        } else {
            sleepValue = "Preparing"
            sleepDetail = "saved history"
        }

        let workoutText = rollup?.strain.map { String(format: "Strain %.1f", $0) }
            ?? widgetSnapshot.map { String(format: "Strain %.1f", $0.strain) }
            ?? "Preparing"

        let trendCoverageText: String
        let trendConfidence: String
        let trendDetail: String
        if recentRollupCount >= 3 {
            trendCoverageText = "\(recentRollupCount)d"
            trendConfidence = "local"
            trendDetail = "Saved trends from \(recentRollupCount) recent days."
        } else {
            trendCoverageText = "--"
            trendConfidence = "learning"
            trendDetail = "Saved trends are preparing."
        }

        return Snapshot(referenceText: baselineMaturityText(sampleCount: freshHRVSampleCount),
                        sleepValue: sleepValue,
                        sleepDetail: sleepDetail,
                        workoutText: workoutText,
                        loggingText: rollup != nil ? "saved" : "settling",
                        trendCoverageText: trendCoverageText,
                        trendConfidence: trendConfidence,
                        trendDetail: trendDetail,
                        confirmedWorkouts: confirmedWorkouts,
                        confirmedSleeps: confirmedSleeps)
    }

    private struct LiveSessionDerived: Equatable {
        let sampleCount: Int
        let lastTimestamp: Date?
        let cycleStart: Date
        let rest: Int
        let maxHR: Int
        let biologicalSex: AthleteProfile.BiologicalSex
        let trimp: Double
        let activeCalories: Double?
    }

    struct PulseZoneContext: Equatable {
        let rest: Int
        let maxHR: Int
    }

    struct RestingMetricContext: Equatable {
        let resolved: Int
        let currentForRecovery: Int?
        let hasEvidence: Bool

        var displayText: String {
            hasEvidence ? "\(resolved)" : "Learning"
        }
    }

    private struct ProfileMetricsKey: Equatable {
        let profileAge: Int
        let biologicalSex: AthleteProfile.BiologicalSex
        let biologicalAgeWeekStart: Date
        let biologicalAgeSummaryRevision: Int
        let sessionsLoaded: Bool
        let rest: Int
        let maxHR: Int
        let maxHRSource: AthleteProfile.HRMaxSource
        let restingBaselineSamples: Int
        let hrvBaselineSamples: Int
        let restingTrend14: [Int]
        let dailyMetricRevision: Int
        let sleepRevision: Int
        let trainingLoad: TrainingLoadSummary
    }

    private struct PulseWindowSummary: Equatable {
        let averageHeartRate: Int?
        let peakHeartRate: Int?
    }

    private struct SavedRestingFallbackKey: Equatable {
        let sessionID: UUID?
        let sessionEnd: Date?
        let pointCount: Int
        let firstPointTime: Double?
        let lastPointTime: Double?
    }

    private struct SavedRestingFallbackCache {
        let key: SavedRestingFallbackKey
        let value: Int?
    }

    init(ble: AtriaBLEManager, store: SessionStore) {
        self.ble = ble
        self.store = store
        // The first frame may need one saved-session percentile calculation.
        // Subsequent bounded refreshes use `cachedLatestSavedResting()` and
        // carry this resolved context through the saved aggregate, avoiding
        // repeated sorts of a growing live session in every Home consumer.
        let initialRestingContext = Self.restingMetricContext(
            baselineResting: store.baseline.restingInt,
            liveResting: ble.restingHR,
            latestSavedResting: store.sessions.first?.restingStable
        )
        self.savedAggregate = Self.makeSavedAggregate(ble: ble,
                                                      store: store,
                                                      restingContext: initialRestingContext)
        let initialLiveSessionDerived = Self.makeLiveSessionDerived(samples: ble.session,
                                                                    rest: initialRestingContext.resolved,
                                                                    maxHR: store.profile.maxHR,
                                                                    profile: store.profile,
                                                                    cycleStart: self.savedAggregate.cycleStart)
        let initialStatus = StatusState(status: ble.status,
                                        bluetoothPermissionDenied: ble.bluetoothPermissionDenied,
                                        officialAppCoexistenceRisk: ble.officialAppCoexistenceRisk,
                                        isBluetoothReady: ble.isBluetoothReady)
        let initialCoreLive = Self.makeCoreLiveState(ble: ble,
                                                     liveSessionDerived: initialLiveSessionDerived,
                                                     savedAggregate: self.savedAggregate,
                                                     canonicalStepDays: store.historySnapshot
                                                        .verifiedHistoricalStepEvidenceDays)
        let initialRRSamples = ble.recentBreathworkRRSamples()
        let initialHeroPulse = Self.makeHeroPulseState(ble: ble,
                                                       rest: initialLiveSessionDerived.rest,
                                                       maxHR: initialLiveSessionDerived.maxHR,
                                                       recentRRSamples: initialRRSamples)
        let initialPulseLive = Self.makePulseLiveState(ble: ble,
                                                       rest: initialLiveSessionDerived.rest,
                                                       maxHR: initialLiveSessionDerived.maxHR,
                                                       recentRRSamples: initialRRSamples)
        let initialPulseSparkline = Self.makePulseSparklineState(ble: ble)
        let initialCollectionLive = Self.makeCollectionLiveState(ble: ble)
        let sharedStressStore = AtriaStressMonitorStore(
            historyPersistence: AtriaStressHistoryPersistence.production(),
            presentationPublishingIsActive: false,
            applicationIsActive: {
                UIApplication.shared.applicationState == .active
                    && !AtriaHistoricalProjectionForegroundGate.isBackgrounded
            }
        )
        let initialStressNow = Date()
        sharedStressStore.update(heartRate: initialPulseLive.heartRate,
                                 hasContact: initialPulseLive.hasContact,
                                 recentRRSamples: initialPulseLive.recentRRSamples,
                                 isRecording: ble.isRecording,
                                 zoneIndex: initialPulseLive.heartRateZone?.index,
                                 hrvSnapshot: ble.hrvSnapshot,
                                 baseline: store.baseline,
                                 restingMaxHR: (rest: store.baseline.restingInt ?? initialLiveSessionDerived.rest,
                                               max: store.profile.maxHR),
                                 hasActiveSleepEvidence: AtriaStressMonitorStore
                                    .hasQualifiedActiveSleepEvidence(
                                        in: store.confirmedSleeps,
                                        at: initialStressNow
                                    ),
                                 now: initialStressNow)
        let initialHero = Self.makeHeroSnapshot(ble: ble,
                                                store: store,
                                                live: initialCoreLive,
                                                savedAggregate: self.savedAggregate,
                                                deferredDetails: nil,
                                                stressState: sharedStressStore.state,
                                                stressLastMeasuredAt: sharedStressStore.lastMeasuredAt)
        let initialHeroState: HeroSnapshot
        #if DEBUG
        let debugHeroFixture = Self.debugFixtureProvisionalRecoveryHeroSnapshot(arguments: ProcessInfo.processInfo.arguments)
        self.debugHeroFixture = debugHeroFixture
        initialHeroState = debugHeroFixture ?? initialHero
        if let debugHeroFixture {
            AtriaDebugLog("ATRIADBG slp3_fixture status=provisional_recovery percent=%d detail=%@ provisional=%d",
                          debugHeroFixture.recoveryEstimate.percent ?? 0,
                          debugHeroFixture.recoveryDetail.replacingOccurrences(of: " ", with: "_"),
                          debugHeroFixture.recoveryIsProvisional ? 1 : 0)
        }
        #else
        initialHeroState = initialHero
        #endif
        let initialHomeStats = Self.makeHomeStatsState(hero: initialHero)
        let initialProfileMetrics = Self.makeProfileMetricsState(store: store,
                                                                 liveSessionDerived: initialLiveSessionDerived)
        let initialProfileMetricsKey = Self.profileMetricsKey(store: store,
                                                              liveSessionDerived: initialLiveSessionDerived)
        self.liveSessionDerived = initialLiveSessionDerived
        self.profileMetricsKey = initialProfileMetricsKey
        self.heroStore = HeroStore(state: initialHeroState)
        self.heroPulseStore = HeroPulseStore(state: initialHeroPulse)
        self.statusStore = StatusStore(state: initialStatus)
        self.coreLiveStore = CoreLiveStore(state: initialCoreLive)
        self.pulseLiveStore = PulseLiveStore(state: initialPulseLive)
        self.pulseSparklineStore = PulseSparklineStore(state: initialPulseSparkline)
        self.collectionLiveStore = CollectionLiveStore(state: initialCollectionLive)
        self.snapshotStore = SnapshotStore(state: Self.makeColdStartSnapshot(store: store))
        self.homeStatsStore = HomeStatsStore(state: initialHomeStats)
        self.profileStore = ProfileStore(profile: store.profile)
        self.profileMetricsStore = ProfileMetricsStore(state: initialProfileMetrics)
        self.stressMonitorStore = sharedStressStore
        self.todaySessionProjectionStore = AtriaTodaySessionProjectionStore(
            store: store,
            presentationIsActive: false,
            applicationIsActive: {
                UIApplication.shared.applicationState == .active
                    && !AtriaHistoricalProjectionForegroundGate.isBackgrounded
            }
        )
        self.activityStore = ActivityStore(state: Self.makeActivityState(store: store))
        historicalStressFallbackRestSubject.send(initialLiveSessionDerived.rest)
        bind()
        scheduleSavedAggregateCycleRolloverRefresh()
        coreRefreshSubject.send(())
        heroRefreshSubject.send(())
    }

    func setPulseDetailMode(active: Bool) {
        guard prefersPulseSparklineUpdates != active else { return }
        prefersPulseSparklineUpdates = active
        if active {
            publishPulseLive()
            publishPulseSparkline()
        }
    }

    /// The Activity projection carries sleep/workout/detection/rollup arrays
    /// and a review fingerprint. Broad store revisions can arrive in bursts
    /// after foreground settlement, but those values have no visible consumer
    /// outside the Activity tab. Mark them dirty off-tab and coalesce active-tab
    /// rebuilds to one main-runloop pass so app return and tab scrolling are not
    /// interrupted by duplicate archive comparisons.
    func setActivityProjectionActive(_ active: Bool) {
        guard prefersActivityProjectionUpdates != active else { return }
        prefersActivityProjectionUpdates = active
        guard active else { return }
        activityProjectionIsDirty = true
        scheduleActivityProjectionRefresh()
    }

    /// Scene authority also controls when the durable stress store releases its
    /// private latest computation into @Published presentation mirrors. Home
    /// visibility (`onDisappear`) deliberately does not call this method: an
    /// active Vitals/Activity child must continue receiving stress on tab moves.
    func setScenePresentationActive(_ active: Bool) {
        scenePresentationIsActive = active
        if active {
            synchronizeStressPresentationPublication()
            setLivePresentationActive(true)
            scheduleApplicationDidBecomeActivePresentationRetry()
        } else {
            setLivePresentationActive(false)
            synchronizeStressPresentationPublication()
        }
    }

    /// Home-owned observable-store authority. Suspending does not pause BLE,
    /// journals, stress computation/history, widgets, or ActivityKit. A resume
    /// consumes one latest-value pass; any prior diagnostics intent is requeued
    /// only after that edge and its existing debounce, never run synchronously.
    func setLivePresentationActive(_ active: Bool) {
        todaySessionProjectionStore.setPresentationActive(active)
        switch livePresentationAuthority.transition(to: active) {
        case .unchanged:
            if active { attemptLivePresentationCatchUpIfNeeded() }
            return
        case .suspended:
            if diagnosticsWorkInFlight {
                diagnosticsPresentationIsDirty = true
            }
            diagnosticsPresentationResumeScheduled = false
            liveHeartRateFreshnessTask?.cancel()
            liveHeartRateFreshnessTask = nil
            stressFreshnessExpiryTask?.cancel()
            stressFreshnessExpiryTask = nil
            diagnosticsWorkItem?.cancel()
            diagnosticsWorkItem = nil
            diagnosticsRefreshToken = UUID()
            diagnosticsWorkInFlight = false
            if prefersActivityProjectionUpdates {
                activityProjectionIsDirty = true
            }
        case .catchUpLatest:
            attemptLivePresentationCatchUpIfNeeded()
        }
    }

    private var applicationPresentationIsActive: Bool {
        UIApplication.shared.applicationState == .active
            && !AtriaHistoricalProjectionForegroundGate.isBackgrounded
    }

    private var livePresentationIsCurrentlyAuthorized: Bool {
        livePresentationAuthority.isActive && applicationPresentationIsActive
    }

    private func synchronizeStressPresentationPublication() {
        let active = scenePresentationIsActive && applicationPresentationIsActive
        stressPresentationPublicationIsSynchronizing = true
        stressMonitorStore.setPresentationPublishingActive(active)
        stressPresentationPublicationIsSynchronizing = false
    }

    private func attemptLivePresentationCatchUpIfNeeded() {
        guard livePresentationAuthority.beginCatchUpIfAuthorized(
            applicationIsActive: applicationPresentationIsActive
        ) else { return }
        performLivePresentationCatchUp()
    }

    private func admitsLivePresentationMutation() -> Bool {
        if livePresentationAuthority.catchUpIsPending,
           livePresentationAuthority.beginCatchUpIfAuthorized(
               applicationIsActive: applicationPresentationIsActive
           ) {
            performLivePresentationCatchUp()
            return false
        }
        return livePresentationAuthority.admitsMutation(
            applicationIsActive: applicationPresentationIsActive
        )
    }

    private func performLivePresentationCatchUp() {
        synchronizeStressPresentationPublication()
        todaySessionProjectionStore.setPresentationActive(true)
        publishStatus()
        publishCoreLive()
        publishProfile()
        publishProfileMetrics()
        publishHeroPulse()
        publishPulseLive()
        publishCollectionLive()
        if prefersPulseSparklineUpdates {
            publishPulseSparkline()
        }
        // Stress computation/history already continued in its private lane;
        // foreground presentation reads the released latest state only.
        refreshHeroSnapshot()
        publishSnapshotIfNeeded(Self.makeSnapshot(
            store: store,
            hero: heroStore.state,
            deferredDetails: deferredDetails
        ))
        scheduleStressFreshnessExpiry(
            lastMeasuredAt: stressMonitorStore.lastMeasuredAt
        )
        scheduleActivityProjectionRefresh()
        scheduleDirtyDiagnosticsAfterForegroundIfNeeded()
    }

    func forceRefresh() {
        requestSavedAggregateRefresh(reason: "force_refresh")
        publishStatus()
        publishCoreLive()
        publishHeroPulse()
        publishPulseLive()
        publishPulseSparkline()
        publishCollectionLive()
        refreshHeroSnapshot()
        coreRefreshSubject.send(())
        loadDeferredDiagnosticsIfNeeded(reason: "force_refresh")
    }

    /// Catch up the one CoreLive field whose transport progress is deliberately
    /// unpublished while inactive. This avoids using the broad force-refresh
    /// path at the app-switch edge.
    func refreshHistoricalRecoveryPresentationForForeground() {
        ble.catchUpHistoricalRecoveryProgressForForeground()
        publishCoreLive()
    }

    func refreshDailyGuidanceClock() {
        refreshHeroSnapshot()
    }

    func loadDeferredDiagnosticsIfNeeded(reason: String) {
        if !diagnosticsRequested {
            diagnosticsRequested = true
            AtriaDebugLog("ATRIADBG home_diagnostics status=requested reason=%@", reason)
        }
        requestDeferredDiagnosticsRefresh()
    }

    private func requestDeferredDiagnosticsRefresh() {
        diagnosticsPresentationIsDirty = true
        diagnosticsRefreshSubject.send(())
    }

    /// SwiftUI can deliver `.active` before either UIKit or AtriaApp opens the
    /// process foreground gate. Coalesce both edges to one next-runloop retry;
    /// the existing authority consumes its pending bit exactly once, without
    /// requiring a data publisher.
    private func scheduleApplicationDidBecomeActivePresentationRetry() {
        guard scenePresentationIsActive,
              !applicationActivationRetryScheduled else { return }
        applicationActivationRetryScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.applicationActivationRetryScheduled = false
            guard self.scenePresentationIsActive,
                  self.applicationPresentationIsActive else { return }
            self.synchronizeStressPresentationPublication()
            guard self.livePresentationAuthority.isActive else { return }
            self.todaySessionProjectionStore.setPresentationActive(true)
            self.attemptLivePresentationCatchUpIfNeeded()
        }
    }

    /// Recovery-state-class hardening (2026-08-21 device freeze): a missed
    /// scene-activation edge left every live surface frozen at its launch
    /// snapshot — the battery pill read "Pending" while the engine's
    /// persisted stream state was `live`. Activation is edge-driven (scene
    /// onChange + one-shot retry), and both are fenced behind the very
    /// mirrors a missed edge leaves stale, so one lost edge froze the UI
    /// permanently. This watchdog reads the GROUND TRUTH
    /// (UIApplication.applicationState) on a slow cadence and repairs the
    /// mirrors when they disagree; it is a no-op every tick the pipeline is
    /// healthy, and it never fabricates activation the OS does not report.
    private func startLivePresentationWatchdog() {
        livePresentationWatchdogTimer?.invalidate()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.repairLivePresentationIfActiveButFrozen()
            }
        }
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        livePresentationWatchdogTimer = timer
    }

    private func repairLivePresentationIfActiveButFrozen() {
        guard UIApplication.shared.applicationState == .active else { return }
        if AtriaHistoricalProjectionForegroundGate.isBackgrounded {
            // Mirrors the scene-active onChange arm: the OS says active, so
            // the projection gate's backgrounded latch is provably stale.
            AtriaHistoricalProjectionForegroundGate.isBackgrounded = false
        }
        if !scenePresentationIsActive {
            setScenePresentationActive(true)
        } else if !livePresentationAuthority.isActive
                    || livePresentationAuthority.catchUpIsPending {
            attemptLivePresentationCatchUpIfNeeded()
        }
    }

    private func bind() {
        startLivePresentationWatchdog()
        Publishers.Merge(
            NotificationCenter.default.publisher(
                for: UIApplication.didBecomeActiveNotification
            ).map { _ in () },
            NotificationCenter.default.publisher(
                for: AtriaHistoricalProjectionForegroundGate
                    .didBecomeForegroundNotification
            ).map { _ in () }
        )
        .sink { [weak self] _ in
            self?.scheduleApplicationDidBecomeActivePresentationRetry()
        }
        .store(in: &cancellables)

        let immediateStatusChanges = ble.$status
            .removeDuplicates()
            .map { _ in () }

        immediateStatusChanges
            .sink { [weak self] _ in
                guard let self else { return }
                self.publishStatus()
                self.publishCoreLive()
                self.refreshHeroSnapshot()
            }
            .store(in: &cancellables)

        ble.$officialAppCoexistenceRisk
            .removeDuplicates()
            .map { _ in () }
            .sink { [weak self] _ in
                guard let self else { return }
                self.publishStatus()
                self.publishCollectionLive()
            }
            .store(in: &cancellables)

        ble.$bluetoothPermissionDenied
            .removeDuplicates()
            .map { _ in () }
            .sink { [weak self] _ in
                self?.publishStatus()
            }
            .store(in: &cancellables)

        ble.$isBluetoothReady
            .removeDuplicates()
            .map { _ in () }
            .sink { [weak self] _ in
                self?.publishStatus()
            }
            .store(in: &cancellables)

        ble.$deviceName
            .removeDuplicates()
            .map { _ in () }
            .sink { [weak self] _ in
                self?.publishCoreLive()
            }
            .store(in: &cancellables)

        let coreLiveChanges: [AnyPublisher<Void, Never>] = [
            ble.$status.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            ble.$bluetoothPermissionDenied.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            ble.$isBluetoothReady.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            ble.$hasContact.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            ble.$batteryLevel.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            ble.$batteryChargeStatus.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            ble.$batteryChargeLastVerifiedAt.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            ble.$batteryRecentlyDropping.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            ble.$batteryReadingIsRecentBaseline.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            ble.$batteryProjectionRevision.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            ble.$strapStreamState.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            ble.$rrContinuityState.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            ble.$sessionSampleCount.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            ble.$liveStrapStepResearchCount.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            ble.$liveStrapStepResearchState.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            ble.$liveStrapStepCountCapturedAt.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            ble.$officialAppCoexistenceRisk.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            ble.$lastScanRequestedAt.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            ble.$lastScanMatchAt.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            ble.$pendingKnownReconnectStartedAt.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            ble.$pendingKnownReconnectReason.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            ble.$rangeLossBackfillPending.removeDuplicates().map { _ in () }.eraseToAnyPublisher()
            // historicalRecoveryPresentation stays OFF this broad merge on
            // purpose — it has its own foreground-gated subscription below so
            // history churn cannot fan out through unrelated BLE events.
        ]
        let throttledCoreLiveChanges: AnyPublisher<Void, Never> = Publishers.MergeMany(coreLiveChanges)
            .throttle(for: .milliseconds(400), scheduler: RunLoop.main, latest: true)
            .eraseToAnyPublisher()

        throttledCoreLiveChanges
            .sink { [weak self] (_: Void) in
                self?.publishCoreLive()
            }
            .store(in: &cancellables)

        // Transport row counts are silent while inactive and bounded at their
        // source while active. Keep this presentation off the broad 400 ms
        // CoreLive merge so history cannot fan out through unrelated BLE churn;
        // terminal changes still render immediately in the foreground.
        ble.$historicalRecoveryPresentation
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                guard UIApplication.shared.applicationState == .active else {
                    return
                }
                // @Published emits from willSet. Defer the narrow read until the
                // manager property contains the value delivered by this event.
                Task { @MainActor [weak self] in
                    guard UIApplication.shared.applicationState == .active else {
                        return
                    }
                    self?.publishCoreLive()
                }
            }
            .store(in: &cancellables)

        // CoreLive receives every accepted-sample count, but day strain is
        // rendered from HeroStore. Updating only CoreLive left Home, the
        // minimized workout, haptics, widgets and ActivityKit holding an old
        // strain value until some unrelated store/HRV event arrived. Refresh
        // the lightweight Hero projection on a bounded live cadence; this does
        // not request diagnostics or rebuild the Activity archive projection.
        ble.$sessionSampleCount
            .removeDuplicates()
            .dropFirst()
            .throttle(for: .milliseconds(1500), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in
                self?.refreshHeroSnapshot()
            }
            .store(in: &cancellables)

        let pulseRateChanges = ble.$heartRate
            .removeDuplicates()
            .map { _ in () }
            .eraseToAnyPublisher()

        let pulseContactChanges = ble.$hasContact
            .removeDuplicates()
            .map { _ in () }
            .eraseToAnyPublisher()

        let pulseStatusChanges = ble.$status
            .removeDuplicates()
            .map { _ in () }
            .eraseToAnyPublisher()

        Publishers.MergeMany([pulseRateChanges, pulseContactChanges, pulseStatusChanges])
            .throttle(for: .milliseconds(650), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in
                self?.publishHeroPulse()
            }
            .store(in: &cancellables)

        let pulseSummaryChanges = ble.$liveHeartWindow
            .map { window in
                PulseWindowSummary(averageHeartRate: window.average,
                                   peakHeartRate: window.peak)
            }
            .removeDuplicates()
            .map { _ in () }
            .eraseToAnyPublisher()

        let throttledPulseLiveChanges = Publishers.MergeMany([
            pulseRateChanges,
            pulseContactChanges,
            pulseStatusChanges,
            ble.$sessionSampleCount.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            pulseSummaryChanges
        ])
        .throttle(for: .milliseconds(650), scheduler: RunLoop.main, latest: true)

        throttledPulseLiveChanges
            .sink { [weak self] _ in
                guard let self else { return }
                self.publishPulseLive()
            }
            .store(in: &cancellables)

        ble.$liveHeartWindow
            .map(\.sparkline)
            .removeDuplicates()
            .throttle(for: .milliseconds(1500), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] (_: [Int]) in
                guard let self else { return }
                self.publishPulseLive()
                self.publishHeroPulse()
                if self.prefersPulseSparklineUpdates {
                    self.publishPulseSparkline()
                }
            }
            .store(in: &cancellables)

        Publishers.Merge(
            ble.$hrvSnapshot.map { _ in () }.eraseToAnyPublisher(),
            ble.$hrvQuality.map { _ in () }.eraseToAnyPublisher()
        )
        .throttle(for: .milliseconds(1200), scheduler: RunLoop.main, latest: true)
        .sink { [weak self] _ in
            self?.heroRefreshSubject.send(())
        }
        .store(in: &cancellables)

        let stressChanges = Publishers.MergeMany([
            ble.$heartRate.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            ble.$hasContact.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            ble.$sessionSampleCount.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            ble.$isRecording.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            ble.$hrvSnapshot.map { _ in () }.eraseToAnyPublisher(),
            store.$baseline.map { _ in () }.eraseToAnyPublisher(),
            store.$profile.map { _ in () }.eraseToAnyPublisher()
        ])
        .throttle(for: .seconds(2), scheduler: RunLoop.main, latest: true)

        stressChanges
            .sink { [weak self] _ in
                guard let self else { return }
                self.synchronizeStressPresentationPublication()
                self.attemptLivePresentationCatchUpIfNeeded()
                // Computation/history persistence remains live. The stress
                // store itself withholds @Published mirrors while inactive.
                self.updateSharedStress()
            }
            .store(in: &cancellables)

        // Historical replay reacts only to the fixed-size identity of the
        // exact v3 personalization fields. Baseline/profile/fallback-rest
        // publications are slow authority edges (not the HR hot loop), and
        // equality is O(1).
        Publishers.CombineLatest3(
            store.$baseline,
            store.$profile,
            historicalStressFallbackRestSubject.removeDuplicates()
        )
            .map { baseline, profile, fallbackRest
                -> AtriaHistoricalStressCalibrationFingerprint in
                let personalization = Self.historicalStressPersonalization(
                    baseline: baseline,
                    profile: profile,
                    fallbackRestingHeartRate: fallbackRest,
                    now: Date()
                )
                return AtriaHistoricalStressCalibrationFingerprint(
                    personalization
                )
            }
            .removeDuplicates()
            .sink { [weak self] fingerprint in
                self?.enqueueHistoricalStressCalibrationReplayIfNeeded(
                    fingerprint
                )
            }
            .store(in: &cancellables)

        stressMonitorStore.$state
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let self,
                      !self.stressPresentationPublicationIsSynchronizing else {
                    return
                }
                self.refreshHeroSnapshot()
            }
            .store(in: &cancellables)

        stressMonitorStore.$lastMeasuredAt
            .removeDuplicates()
            .sink { [weak self] lastMeasuredAt in
                guard let self,
                      !self.stressPresentationPublicationIsSynchronizing,
                      self.livePresentationIsCurrentlyAuthorized else { return }
                // `state` publishes immediately before `lastMeasuredAt` on a
                // scored tick. Refresh only when a clock can unlock a currently
                // hidden scored projection; ordinary timestamp renewal merely
                // moves the expiry deadline and adds no render cadence.
                if self.stressMonitorStore.state.kind == .scored,
                   self.stressMonitorStore.state.level != nil,
                   self.heroStore.state.stressLevel == nil,
                   AtriaStressReadingFreshness.resolve(
                       isScored: true,
                       updatedAt: lastMeasuredAt
                   ) == .live {
                    self.heroRefreshSubject.send(())
                }
                self.scheduleStressFreshnessExpiry(lastMeasuredAt: lastMeasuredAt)
            }
            .store(in: &cancellables)

        let collectionLiveChanges = Publishers.MergeMany([
            ble.$isRecording.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            ble.$capturedRows.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            ble.$captureSummary.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            ble.$captureWasValidationReady.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            ble.$lastCaptureFile.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            ble.$standardHROnlyEnabled.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            ble.$longWearModeEnabled.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            ble.$rangeLossBackfillPending.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            ble.$collectionProfile.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            ble.$officialAppCoexistenceRisk.removeDuplicates().map { _ in () }.eraseToAnyPublisher()
        ])
        .throttle(for: .milliseconds(400), scheduler: RunLoop.main, latest: true)

        collectionLiveChanges
            .sink { [weak self] _ in self?.publishCollectionLive() }
            .store(in: &cancellables)

        // Workout saves often publish dashboard/history more than once and a
        // sleep save publishes both sleep and dashboard state. Collapse that
        // transaction burst—and any simultaneous recovered-data fence—into one
        // bounded replay. The generation gate below still cancels an older
        // worker if a genuinely newer publication arrives after the debounce.
        historicalStressReplayTriggerSubject
            .debounce(for: .milliseconds(750), scheduler: RunLoop.main)
            .sink { [weak self] in
                self?.scheduleHistoricalStressReplay(now: Date())
            }
            .store(in: &cancellables)

        store.$dashboardRevision
            .map { _ in () }
            .sink { [weak self] _ in
                self?.requestActivityProjectionRefresh()
                self?.storeRefreshSubject.send(())
            }
            .store(in: &cancellables)

        store.$historySnapshot
            .map { _ in () }
            .sink { [weak self] _ in
                self?.requestSavedAggregateRefresh(reason: "history_snapshot")
                self?.publishCoreLive()
                self?.coreRefreshSubject.send(())
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(
            for: SessionStore.recoveredDataRecomputeDidPublishNotification
        )
        .sink { [weak self] notification in
            guard let self,
                  let publishingStore = notification.object as? SessionStore,
                  publishingStore === self.store else { return }
            self.handleHistoricalStressTerminal(
                sourceReplayRequired: true
            )
        }
        .store(in: &cancellables)

        // This exact-store edge is emitted only after an authoritative
        // confirmed workout/sleep save, edit, or delete is durable and fully
        // published. Recovered intermediate snapshots deliberately never post
        // it; their complete publication fence above owns that replay.
        NotificationCenter.default.publisher(
            for: SessionStore.stressContextDidPublishNotification
        )
        .sink { [weak self] notification in
            guard let self,
                  let publishingStore = notification.object as? SessionStore,
                  publishingStore === self.store else { return }
            self.handleHistoricalStressTerminal(
                sourceReplayRequired: true
            )
        }
        .store(in: &cancellables)

        // A failed/superseded recovered transaction has no full recovered-data
        // publication. Settle only a calibration fingerprint that was actually
        // deferred by that exact store; unchanged rollback state performs no
        // replay, while independent profile/fallback-rest changes that survived
        // the rollback enter the same generation-cancelled debounce lane.
        NotificationCenter.default.publisher(
            for: SessionStore.stressCalibrationFenceDidReleaseNotification
        )
        .sink { [weak self] notification in
            guard let self,
                  let publishingStore = notification.object as? SessionStore,
                  publishingStore === self.store else { return }
            self.handleHistoricalStressTerminal(
                sourceReplayRequired: false
            )
        }
        .store(in: &cancellables)

        // Exact-store terminal authority for saved-session removal/shrink,
        // rollback-preserved live mutations, and a completed backup restore.
        // It shares the generation-cancelled/debounced replay lane above, so a
        // terminal burst never starts duplicate or unbounded scoring work.
        NotificationCenter.default.publisher(
            for: SessionStore.stressReplayDidPublishNotification
        )
        .sink { [weak self] notification in
            guard let self,
                  let publishingStore = notification.object as? SessionStore,
                  publishingStore === self.store else { return }
            self.handleHistoricalStressTerminal(
                sourceReplayRequired: true
            )
        }
        .store(in: &cancellables)

        Publishers.Merge3(
            store.$sleepHistorySnapshot.map { _ in () }.eraseToAnyPublisher(),
            store.$pendingSleepReviewNightForUI.map { _ in () }.eraseToAnyPublisher(),
            store.$napReviewCandidateNightsForUI.map { _ in () }.eraseToAnyPublisher()
        )
            .sink { [weak self] _ in
                self?.requestActivityProjectionRefresh()
                // A newly published real sleep review can unlock a deliberately
                // unverified presentation-only Recovery before confirmation.
                // Refresh the hero immediately; the canonical/frozen Recovery
                // pipeline remains untouched inside SessionStore.
                self?.heroRefreshSubject.send(())
            }
            .store(in: &cancellables)

        Publishers.Merge(
            store.$sleepHistorySnapshot.map { _ in () }.eraseToAnyPublisher(),
            store.$trainingLoadSummarySnapshot.map { _ in () }.eraseToAnyPublisher()
        )
        .throttle(for: .milliseconds(900), scheduler: RunLoop.main, latest: true)
        .sink { [weak self] _ in
            self?.publishProfileMetrics()
            self?.heroRefreshSubject.send(())
        }
        .store(in: &cancellables)

        storeRefreshSubject
            .debounce(for: .milliseconds(900), scheduler: RunLoop.main)
            .sink { [weak self] in
                guard let self else { return }
                self.requestSavedAggregateRefresh(reason: "dashboard_revision")
                self.coreRefreshSubject.send(())
                self.heroRefreshSubject.send(())
                self.publishProfileMetrics()
                if self.diagnosticsRequested {
                    self.requestDeferredDiagnosticsRefresh()
                }
            }
            .store(in: &cancellables)

        store.$profile
            .removeDuplicates()
            .sink { [weak self] profile in
                guard let self else { return }
                if self.ble.maxHRSetting != profile.maxHR {
                    self.ble.maxHRSetting = profile.maxHR
                }
                self.publishProfile()
                self.requestSavedAggregateRefresh(reason: "profile")
                self.publishCoreLive()
                self.publishHeroPulse()
                self.publishPulseLive()
                self.publishProfileMetrics()
                if self.prefersPulseSparklineUpdates {
                    self.publishPulseSparkline()
                }
                self.coreRefreshSubject.send(())
                self.refreshHeroSnapshot()
                if self.diagnosticsRequested {
                    self.requestDeferredDiagnosticsRefresh()
                }
            }
            .store(in: &cancellables)

        store.$baseline
            .dropFirst()
            .sink { [weak self] _ in
                self?.requestSavedAggregateRefresh(reason: "baseline")
            }
            .store(in: &cancellables)

        heroRefreshSubject
            .throttle(for: .milliseconds(1500), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] in
                self?.refreshHeroSnapshot()
            }
            .store(in: &cancellables)

        coreRefreshSubject
            .debounce(for: .milliseconds(450), scheduler: RunLoop.main)
            .sink { [weak self] in
                guard let self,
                      self.admitsLivePresentationMutation() else { return }
                self.publishSnapshotIfNeeded(Self.makeSnapshot(store: self.store,
                                                               hero: self.heroStore.state,
                                                               deferredDetails: self.deferredDetails))
            }
            .store(in: &cancellables)

        diagnosticsRefreshSubject
            .debounce(for: .milliseconds(2800), scheduler: RunLoop.main)
            .sink { [weak self] in
                guard let self,
                      self.livePresentationIsCurrentlyAuthorized else { return }
                self.scheduleDeferredDiagnosticsRefresh()
            }
            .store(in: &cancellables)

    }

    private func publishStatus() {
        guard admitsLivePresentationMutation() else { return }
        let next = StatusState(status: ble.status,
                               bluetoothPermissionDenied: ble.bluetoothPermissionDenied,
                               officialAppCoexistenceRisk: ble.officialAppCoexistenceRisk,
                               isBluetoothReady: ble.isBluetoothReady)
        guard next != statusStore.state else { return }
        statusStore.state = next
    }

    private func publishCoreLive() {
        guard admitsLivePresentationMutation() else { return }
        // This is the accepted-HR hot path. Saved/archive rows are refreshed by
        // their own authority lane and physiological-cycle clock; never scan them
        // from the 400 ms sessionSampleCount publication cadence.
        refreshLiveSessionDerivedIfNeeded()
        var next = Self.makeCoreLiveState(ble: ble,
                                          liveSessionDerived: liveSessionDerived,
                                          savedAggregate: savedAggregate,
                                          canonicalStepDays: store.historySnapshot
                                            .verifiedHistoricalStepEvidenceDays)
        // Anti-flicker (owner report 2026-08-24): the recovery banner is the
        // one status every tab renders, and it oscillated fast enough that
        // Today and Vitals could disagree about the same underlying state.
        // Debounce the DOWNGRADE here — at the single source — so every
        // surface agrees and none of them blanks on a transient recompute.
        // Bounded: a sustained gap still surfaces honestly after the grace.
        let held = AtriaHoldLastGoodPresentation.resolve(
            incoming: next.historicalRecoveryPresentation,
            state: recoveryPresentationHold,
            now: Date()
        )
        recoveryPresentationHold = held.state
        next.historicalRecoveryPresentation = held.value
        guard next != coreLiveStore.state else { return }
        coreLiveStore.state = next
    }

    /// Carry-over for the recovery-banner anti-flicker debounce above.
    private var recoveryPresentationHold =
        AtriaHoldLastGoodPresentation.State<
            AtriaBLEManager.HistoricalRecoveryPresentation
        >.initial

    func refreshDurableStepReceipt() {
        publishCoreLive()
    }

    private func publishHeroPulse() {
        guard admitsLivePresentationMutation() else { return }
        // RR intervals arrive several times a second and the array is only read
        // by the breathwork pacer: refresh it at most 1 Hz, and decide that
        // before scanning the archive-backed RR window. No RR data is lost --
        // the window array carries all recent beats when it does refresh. Each
        // publisher owns its own stamp so call order cannot phase-lock one stale.
        let now = Date()
        let recentRRSamples: [AtriaBreathworkSession.RRSample]
        if now.timeIntervalSince(lastHeroRRRefreshAt) < 1.0 {
            recentRRSamples = heroPulseStore.state.recentRRSamples
        } else {
            lastHeroRRRefreshAt = now
            recentRRSamples = ble.recentBreathworkRRSamples()
        }
        let zoneContext = currentPulseZoneContext()
        var next = Self.makeHeroPulseState(ble: ble,
                                           rest: zoneContext.rest,
                                           maxHR: zoneContext.maxHR,
                                           recentRRSamples: recentRRSamples)
        next.heartRateBroadcastActive = latestHeartRateBroadcastActive
        if next.hasPulseSignal {
            ensureLiveHeartRateFreshnessExpiryScheduled()
        }
        guard next != heroPulseStore.state else { return }
        heroPulseStore.state = next
    }

    func setHeartRateBroadcastActive(_ active: Bool) {
        latestHeartRateBroadcastActive = active
        guard admitsLivePresentationMutation() else { return }
        guard heroPulseStore.state.heartRateBroadcastActive != active else { return }
        heroPulseStore.state.heartRateBroadcastActive = active
    }

    private func publishPulseLive() {
        guard admitsLivePresentationMutation() else { return }
        let now = Date()
        let recentRRSamples: [AtriaBreathworkSession.RRSample]
        if now.timeIntervalSince(lastPulseRRRefreshAt) < 1.0 {
            recentRRSamples = pulseLiveStore.state.recentRRSamples
        } else {
            lastPulseRRRefreshAt = now
            recentRRSamples = ble.recentBreathworkRRSamples()
        }
        let zoneContext = currentPulseZoneContext()
        let next = Self.makePulseLiveState(ble: ble,
                                           rest: zoneContext.rest,
                                           maxHR: zoneContext.maxHR,
                                           recentRRSamples: recentRRSamples)
        // Same 1 Hz RR refresh policy as publishHeroPulse (see comment there).
        guard next != pulseLiveStore.state else { return }
        pulseLiveStore.state = next
    }

    private func refreshLiveHeartRateFreshness() {
        let heartRate = Self.liveHeartRate(ble: ble)
        let hasLiveHeartRate = heartRate > 0
        if heroPulseStore.state.heartRate != heartRate
            || heroPulseStore.state.hasContact != hasLiveHeartRate
            || heroPulseStore.state.sensorHasContact != ble.hasContact {
            publishHeroPulse()
        }
        if pulseLiveStore.state.heartRate != heartRate
            || pulseLiveStore.state.hasContact != hasLiveHeartRate
            || pulseLiveStore.state.sensorHasContact != ble.hasContact {
            publishPulseLive()
        }
        if coreLiveStore.state.hasRecentHeartRateSample != hasLiveHeartRate {
            publishCoreLive()
        }
    }

    /// A permanent 1 Hz timer used to wake the main run loop for the entire app
    /// lifetime just to expire a six-second-old pulse. One coalesced sleeper is
    /// enough: while samples keep arriving it wakes at most once per freshness
    /// window and moves to the newest deadline; after the stream stops it clears
    /// the UI once and does not re-arm.
    private func ensureLiveHeartRateFreshnessExpiryScheduled() {
        guard livePresentationIsCurrentlyAuthorized,
              liveHeartRateFreshnessTask == nil,
              let latestSampleAt = ble.session.last?.t else { return }
        let deadline = latestSampleAt.addingTimeInterval(Self.liveHeartRateFreshnessInterval)
        let delay = min(Self.liveHeartRateFreshnessInterval,
                        max(0, deadline.timeIntervalSinceNow))
        liveHeartRateFreshnessTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled,
                  let self,
                  self.livePresentationIsCurrentlyAuthorized else { return }
            self.liveHeartRateFreshnessTask = nil
            self.refreshLiveHeartRateFreshness()
            if Self.hasRecentHeartRateSample(ble: self.ble) {
                self.ensureLiveHeartRateFreshnessExpiryScheduled()
            }
        }
    }

    /// Refresh the compact stress projection once, just after its source-clock
    /// lease expires. New scored measurements cancel and move this deadline;
    /// there is no per-second timer invalidating the Home hierarchy.
    private func scheduleStressFreshnessExpiry(lastMeasuredAt: Date?) {
        stressFreshnessExpiryTask?.cancel()
        stressFreshnessExpiryTask = nil

        let now = Date()
        guard livePresentationIsCurrentlyAuthorized,
              stressMonitorStore.state.kind == .scored,
              let lastMeasuredAt,
              AtriaStressReadingFreshness.resolve(
                  isScored: true,
                  updatedAt: lastMeasuredAt,
                  now: now
              ) == .live else { return }

        // A live reading can sit immediately before a deterministic no-sleep
        // rollover. Expire at whichever truth boundary comes first so the hero
        // cannot carry a prior-cycle band for the remainder of its 90-second
        // age lease merely because no publisher fires at the rollover instant.
        let cycleRollover = AtriaPhysiologicalCycle.nextNoSleepRollover(
            now: now,
            confirmedSleeps: store.confirmedSleeps,
            calendar: .current
        )
        guard let expiresAt = AtriaStressReadingFreshness.expirationDeadline(
            updatedAt: lastMeasuredAt,
            nextPhysiologicalCycleStart: cycleRollover
        ) else { return }
        let delay = max(0, expiresAt.timeIntervalSince(now) + 0.05)
        stressFreshnessExpiryTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled,
                  let self,
                  self.livePresentationIsCurrentlyAuthorized else { return }
            self.stressFreshnessExpiryTask = nil
            self.refreshHeroSnapshot()
        }
    }

    private func publishPulseSparkline() {
        guard admitsLivePresentationMutation() else { return }
        // Throttle FIRST (2026-07-08 perf audit): the chart buckets per second,
        // but RR/HR arrive several times a second, and makePulseSparklineState
        // (suffix + filter + stride) plus the ~120-element Equatable compare
        // were running on EVERY beat before this gate. 1 Hz is the chart's
        // native resolution; the hero BPM digit stays on the un-gated
        // pulseLiveStore so perceived liveness is unchanged. Staleness is
        // bounded: the next beat after the window publishes.
        let now = Date()
        guard now.timeIntervalSince(lastPulseSparklinePublishAt) >= 1.0 else { return }
        lastPulseSparklinePublishAt = now
        let next = Self.makePulseSparklineState(ble: ble)
        guard next != pulseSparklineStore.state else { return }
        pulseSparklineStore.state = next
    }

    private var lastPulseSparklinePublishAt = Date.distantPast
    private var lastHeroRRRefreshAt = Date.distantPast
    private var lastPulseRRRefreshAt = Date.distantPast

    private func publishCollectionLive() {
        guard admitsLivePresentationMutation() else { return }
        let next = Self.makeCollectionLiveState(ble: ble)
        guard next != collectionLiveStore.state else { return }
        collectionLiveStore.state = next
    }

    private func publishProfile() {
        guard admitsLivePresentationMutation() else { return }
        let next = store.profile
        guard next != profileStore.profile else { return }
        profileStore.profile = next
    }

    private func publishProfileMetrics() {
        guard admitsLivePresentationMutation() else { return }
        refreshLiveSessionDerivedIfNeeded()
        let key = Self.profileMetricsKey(store: store,
                                         liveSessionDerived: liveSessionDerived)
        guard key != profileMetricsKey else { return }
        let next = Self.makeProfileMetricsState(store: store,
                                                liveSessionDerived: liveSessionDerived)
        profileMetricsKey = key
        guard next != profileMetricsStore.state else { return }
        profileMetricsStore.state = next
    }

    private static func makeActivityState(store: SessionStore) -> ActivityState {
        let pendingSleep = store.pendingSleepReviewNightForUI
        let napReviewCandidates = store.napReviewCandidateNightsForUI
        let workoutReview = store.latestWorkoutReviewCandidate(rest: store.baseline.restingInt ?? 60,
                                                                maxHR: store.profile.maxHR,
                                                                source: "activity_projection")
        let detections = store.activityDetectionsForUI
        let detectionsRevision = activityDetectionsFingerprint(detections)
        let reviewFingerprint = ([
            pendingSleep?.id ?? "no-sleep-review",
            workoutReview?.id ?? "no-workout-review",
            workoutReview?.suggestedActivityType?.rawValue ?? "no-workout-type-hint",
            String(detectionsRevision)
        ] + (napReviewCandidates.isEmpty
             ? ["no-nap-review"]
             : napReviewCandidates.map(\.id))).joined(separator: "|")
        return ActivityState(sleepHistorySnapshot: store.sleepHistorySnapshot,
                             sleepHistorySnapshotRevision: store.sleepHistorySnapshotRevision,
                             pendingSleepReview: pendingSleep,
                             napReviewCandidates: napReviewCandidates,
                             confirmedWorkouts: store.confirmedWorkouts,
                             confirmedWorkoutsRevision: store.confirmedWorkoutsRevision,
                             workoutReviewCandidate: workoutReview,
                             activityDetections: detections,
                             historySnapshotRevision: detectionsRevision,
                             reviewFingerprint: reviewFingerprint,
                             dailyRollupHistory: store.dailyRollupHistory,
                             dailyRollupHistoryRevision: store.dailyRollupHistoryRevision)
    }

    private static func activityDetectionsFingerprint(_ detections: [ActivityDetection]) -> Int {
        var hasher = Hasher()
        hasher.combine(detections.count)
        for detection in detections {
            hasher.combine(detection.id)
            hasher.combine(detection.kind.rawValue)
            hasher.combine(detection.start.timeIntervalSinceReferenceDate)
            hasher.combine(detection.end.timeIntervalSinceReferenceDate)
            hasher.combine(detection.suggestedActivityType?.rawValue)
        }
        return hasher.finalize()
    }

    private func publishActivity() {
        guard livePresentationIsCurrentlyAuthorized else {
            activityProjectionIsDirty = true
            return
        }
        activityProjectionIsDirty = false
        activityStore.refresh(Self.makeActivityState(store: store))
    }

    private func requestActivityProjectionRefresh() {
        activityProjectionIsDirty = true
        scheduleActivityProjectionRefresh()
    }

    private func scheduleActivityProjectionRefresh() {
        guard prefersActivityProjectionUpdates,
              livePresentationIsCurrentlyAuthorized,
              activityProjectionIsDirty,
              !activityProjectionRefreshScheduled else { return }
        activityProjectionRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.activityProjectionRefreshScheduled = false
            guard self.prefersActivityProjectionUpdates,
                  self.livePresentationIsCurrentlyAuthorized,
                  self.activityProjectionIsDirty else { return }
            self.publishActivity()
        }
    }

    private func requestSavedAggregateRefresh(reason: String) {
        pendingSavedAggregateRefreshReason = reason
        guard case .start(let generation) = savedAggregateRefreshGate.request() else {
            return
        }
        startSavedAggregateRefresh(generation: generation, reason: reason)
    }

    private func startSavedAggregateRefresh(generation: UInt64, reason: String) {
        let input = savedAggregateRefreshInputSnapshot(now: Date())
        savedAggregateRefreshQueue.async { [weak self, input] in
            let result = Self.makeSavedAggregate(input: input)
            DispatchQueue.main.async { [weak self] in
                self?.finishSavedAggregateRefresh(
                    generation: generation,
                    result: result,
                    reason: reason
                )
            }
        }
    }

    private func finishSavedAggregateRefresh(generation: UInt64,
                                             result: SavedAggregate,
                                             reason: String) {
        switch savedAggregateRefreshGate.complete(generation) {
        case .ignored:
            return
        case .start(let nextGeneration):
            startSavedAggregateRefresh(
                generation: nextGeneration,
                reason: pendingSavedAggregateRefreshReason
            )
        case .publish:
            let changed = result != savedAggregate
            if changed {
                savedAggregate = result
                publishCoreLive()
                refreshHeroSnapshot()
                coreRefreshSubject.send(())
            }
            scheduleSavedAggregateCycleRolloverRefresh()
            AtriaDebugLog(
                "ATRIADBG home_saved_aggregate status=published reason=%@ generation=%llu changed=%d",
                reason,
                generation,
                changed ? 1 : 0
            )
        }
    }

    /// Snapshot only value-semantic authority on MainActor. Array assignments
    /// are COW retains; session filtering, physiological-cycle framing, TRIMP,
    /// calories, steps, baseline freshness, and HR-union work all stay in the
    /// utility worker below.
    private func savedAggregateRefreshInputSnapshot(
        now: Date
    ) -> SavedAggregateRefreshInput {
        return SavedAggregateRefreshInput(
            source: store.homeSavedAggregateSourceSnapshot(),
            baseline: store.baseline,
            liveRestingHeartRate: ble.restingHR,
            activeSessionID: ble.currentLiveSessionID,
            confirmedWorkouts: store.confirmedWorkouts.count,
            windowEnd: now
        )
    }

    /// The start of the CONTINUOUS active period the cumulative Today metrics
    /// (strain/TRIMP/calories/wear) integrate over. For a confirmed boundary —
    /// or when nothing usable precedes the cycle within the bound — this is
    /// `cycleStart`, so behaviour is unchanged. Across an UNCONFIRMED no-sleep
    /// fallback it reaches back to the last confirmed wake (the same unbroken
    /// wear period the synthetic boundary split), clamped so the total window
    /// never exceeds a plausible waking day (18h): a stale anchor must not
    /// integrate multiple days of strain. Always <= cycleStart. Pure + injable
    /// so the boundary is unit-testable.
    nonisolated static func continuousTodayAccumulationStart(
        cycleStart: Date,
        lastConfirmedWake: Date?,
        now: Date,
        isUnconfirmedFallback: Bool
    ) -> Date {
        guard isUnconfirmedFallback else { return cycleStart }
        let floor = now.addingTimeInterval(
            -AtriaCurrentDayPresentation.maximumWakingDayHeldAcrossMidnight
        )
        let candidate = max(lastConfirmedWake ?? floor, floor)
        return min(candidate, cycleStart)
    }

    private nonisolated static func makeSavedAggregate(
        input: SavedAggregateRefreshInput
    ) -> SavedAggregate {
        let restingContext = restingMetricContext(
            baselineResting: input.baseline.restingInt,
            liveResting: input.liveRestingHeartRate,
            latestSavedResting: input.source.latestRawSession
                .map(\.restingStable)
                .flatMap { $0 > 0 ? $0 : nil }
        )
        let cycle = AtriaPhysiologicalCycle.current(
            now: input.windowEnd,
            confirmedSleeps: input.source.confirmedSleeps,
            calendar: .current
        )
        let cycleStart = cycle.start
        // A `.mainSleep` boundary is a real, confirmed day boundary; anything
        // else (`.noSleepFallback` / `.initialFallback`) is a synthetic guess
        // the step presentation may carry a prior receipt across.
        let cycleBoundaryIsUnconfirmedFallback = cycle.boundaryKind != .mainSleep
        let aggregate = SessionStore.homeSavedAggregate(
            from: input.source.canonicalSessions,
            archiveHeartRatePoints: input.source.archiveHeartRatePoints,
            rest: restingContext.resolved,
            maxHR: input.source.profile.maxHR,
            biologicalSex: input.source.profile.biologicalSex,
            profile: input.source.profile,
            activeSessionID: input.activeSessionID,
            calendar: .current,
            now: input.windowEnd,
            cycleStart: cycleStart,
            excludedLoadIntervals: input.source.confirmedSleeps.map {
                DateInterval(start: $0.start, end: $0.end)
            },
            rawSessionCount: input.source.rawSessionCount,
            // GAP-09: fuse logged muscular load into today's Strain on the
            // off-MainActor path too, so the Home hero matches the widget on
            // strength-heavy days (the reducer's window filter keeps this
            // disjoint from the pre-boundary fold below — never double-counted).
            confirmedWorkouts: input.source.confirmedWorkouts
        )
        // Same-defect carry (2026-08-22): across an UNCONFIRMED no-sleep
        // fallback the synthetic boundary splits ONE continuous wear period, so
        // the cumulative Today metrics (strain via TRIMP, calories, wear) that
        // integrate over [cycleStart, now] collapse — "all the numbers went
        // away". Fold the stranded pre-boundary slice back in over
        // [accumulationStart, cycleStart]. The two windows are DISJOINT and the
        // load is window-bounded (dailyLoadTRIMP(within:)), so this partitions
        // the continuous period — never double-counts, never fabricates. Steps
        // are deliberately excluded (their receipt pipeline already carries
        // forward) and the canonical cycleStart is untouched (day identity /
        // recovery / durable freeze stay put). An unconfirmed sleep inside the
        // pre-slice contributes ~0 load (sleep = low HR), so it self-corrects.
        let lastConfirmedWake = AtriaPhysiologicalCycle.latestCompletedMainSleep(
            now: input.windowEnd,
            confirmedSleeps: input.source.confirmedSleeps
        )?.end
        let accumulationStart = continuousTodayAccumulationStart(
            cycleStart: cycleStart,
            lastConfirmedWake: lastConfirmedWake,
            now: input.windowEnd,
            isUnconfirmedFallback: cycleBoundaryIsUnconfirmedFallback
        )
        var savedTodayTRIMP = aggregate.savedTodayTRIMP
        var savedTodayMuscularTRIMP = aggregate.savedTodayMuscularTRIMP
        var savedTodayActiveCalories = aggregate.savedTodayActiveCalories
        var savedTodayObservedSeconds = observedHeartRateUnionSeconds(
            sessions: input.source.rawSessions,
            windowStart: aggregate.day,
            windowEnd: input.windowEnd
        )
        if accumulationStart < cycleStart {
            let preBoundary = SessionStore.homeSavedAggregate(
                from: input.source.canonicalSessions,
                archiveHeartRatePoints: input.source.archiveHeartRatePoints,
                rest: restingContext.resolved,
                maxHR: input.source.profile.maxHR,
                biologicalSex: input.source.profile.biologicalSex,
                profile: input.source.profile,
                activeSessionID: nil,
                calendar: .current,
                now: cycleStart,
                cycleStart: accumulationStart,
                excludedLoadIntervals: input.source.confirmedSleeps.map {
                    DateInterval(start: $0.start, end: $0.end)
                },
                rawSessionCount: input.source.rawSessionCount,
                // GAP-09: the pre-boundary slice must fuse muscular load too;
                // its window [accumulationStart, cycleStart) is disjoint from
                // the main aggregate's, so workouts land in exactly one lane.
                confirmedWorkouts: input.source.confirmedWorkouts
            )
            savedTodayTRIMP += preBoundary.savedTodayTRIMP
            savedTodayMuscularTRIMP += preBoundary.savedTodayMuscularTRIMP
            if let preCalories = preBoundary.savedTodayActiveCalories {
                savedTodayActiveCalories =
                    (savedTodayActiveCalories ?? 0) + preCalories
            }
            savedTodayObservedSeconds += observedHeartRateUnionSeconds(
                sessions: input.source.rawSessions,
                windowStart: accumulationStart,
                windowEnd: cycleStart
            )
        }
        return SavedAggregate(
            cycleStart: aggregate.day,
            cycleBoundaryIsUnconfirmedFallback:
                cycleBoundaryIsUnconfirmedFallback,
            strainAccumulationStart: accumulationStart,
            restingContext: restingContext,
            savedTodayTRIMP: savedTodayTRIMP,
            savedActiveSessionTRIMP: aggregate.savedActiveSessionTRIMP,
            savedTodayMuscularTRIMP: savedTodayMuscularTRIMP,
            savedTodayActiveCalories: savedTodayActiveCalories,
            savedActiveSessionActiveCalories:
                aggregate.savedActiveSessionActiveCalories,
            savedTodayStrapSteps: aggregate.savedTodayStrapSteps,
            savedActiveSessionStrapSteps: aggregate.savedActiveSessionStrapSteps,
            savedActiveSessionTotalStrapSteps:
                aggregate.savedActiveSessionTotalStrapSteps,
            hasSavedToday: aggregate.hasSavedToday || savedTodayTRIMP > 0,
            sessionsCount: aggregate.sessionsCount,
            baselineSamples: input.baseline.freshHRVSampleCount(
                now: input.windowEnd
            ),
            confirmedWorkouts: input.confirmedWorkouts,
            confirmedSleeps: input.source.confirmedSleeps.count,
            savedTodayObservedSeconds: savedTodayObservedSeconds
        )
    }

    private func scheduleSavedAggregateCycleRolloverRefresh() {
        savedAggregateCycleRolloverTask?.cancel()
        savedAggregateCycleRolloverTask = nil
        let now = Date()
        guard let boundary = AtriaPhysiologicalCycle.nextNoSleepRollover(
            now: now,
            confirmedSleeps: store.confirmedSleeps,
            calendar: .current
        ) else { return }
        let delay = max(1, boundary.timeIntervalSince(now) + 1)
        savedAggregateCycleRolloverTask = Task { @MainActor [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(delay * 1_000_000_000)
            )
            guard !Task.isCancelled, let self else { return }
            self.savedAggregateCycleRolloverTask = nil
            self.requestSavedAggregateRefresh(reason: "physiological_cycle_rollover")
        }
    }

    private func refreshHeroSnapshot() {
        guard admitsLivePresentationMutation() else { return }
        #if DEBUG
        if let debugHeroFixture {
            publishHeroSnapshotIfNeeded(debugHeroFixture)
            return
        }
        #endif
        publishHeroSnapshotIfNeeded(Self.makeHeroSnapshot(ble: ble,
                                                          store: store,
                                                          live: coreLiveStore.state,
                                                          savedAggregate: savedAggregate,
                                                          deferredDetails: deferredDetails,
                                                          stressState: stressMonitorStore.state,
                                                          stressLastMeasuredAt: stressMonitorStore.lastMeasuredAt))
    }

    private func updateSharedStress(now: Date = Date()) {
        let rest = store.baseline.restingInt ?? liveSessionDerived.rest
        let maxHR = store.profile.maxHR
        let heartRate = Self.liveHeartRate(ble: ble)
        stressMonitorStore.update(heartRate: heartRate,
                                  hasContact: heartRate > 0,
                                  recentRRSamples: ble.recentBreathworkRRSamples(),
                                  isRecording: ble.isRecording,
                                  zoneIndex: Metrics.heartRateZone(bpm: heartRate,
                                                                 rest: rest,
                                                                 max: maxHR)?.index,
                                  hrvSnapshot: ble.hrvSnapshot,
                                  baseline: store.baseline,
                                  restingMaxHR: (rest: rest, max: maxHR),
                                  hasActiveSleepEvidence: AtriaStressMonitorStore
                                    .hasQualifiedActiveSleepEvidence(
                                        in: store.confirmedSleeps,
                                        at: now
                                    ),
                                  now: now)
    }

    private func enqueueHistoricalStressCalibrationReplayIfNeeded(
        _ fingerprint: AtriaHistoricalStressCalibrationFingerprint
    ) {
        guard historicalStressCalibrationPublicationGate.accepts(
            fingerprint,
            publicationDeferred: store.stressReplayPublicationIsDeferred
        ) else { return }
        invalidateAndEnqueueHistoricalStressReplay()
    }

    /// Compares pending provisional observations with the exact post-fence
    /// personalization. This is O(1) apart from PersonalBaseline's pre-bounded
    /// 90-day calibration projection and never snapshots history/session rows.
    private func handleHistoricalStressTerminal(
        sourceReplayRequired: Bool
    ) {
        guard historicalStressCalibrationPublicationGate.recordTerminal(
            sourceReplayRequired: sourceReplayRequired,
            publicationDeferred: store.stressReplayPublicationIsDeferred
        ) else { return }
        guard releaseDeferredHistoricalStressCalibration() else { return }
        invalidateAndEnqueueHistoricalStressReplay()
    }

    private func releaseDeferredHistoricalStressCalibration(
        now: Date = Date()
    ) -> Bool {
        let personalization = Self.historicalStressPersonalization(
            baseline: store.baseline,
            profile: store.profile,
            fallbackRestingHeartRate: historicalStressFallbackRestSubject.value,
            now: now
        )
        return historicalStressCalibrationPublicationGate.releaseDeferred(
            final: AtriaHistoricalStressCalibrationFingerprint(personalization)
        )
    }

    private static func historicalStressPersonalization(
        baseline: PersonalBaseline,
        profile: AthleteProfile,
        fallbackRestingHeartRate: Int,
        now: Date
    ) -> AtriaPhysiologicalStressModel.Personalization {
        let freshBaseline = baseline.freshSamples(now: now)
        let qualifiedLnRMSSD = freshBaseline
            .filter(\.isOvernightSample)
            .compactMap(\.lnRMSSD)
        return AtriaPhysiologicalStressModel.Personalization(
            restingHeartRate: baseline.restingHR
                ?? Double(fallbackRestingHeartRate),
            maximumHeartRate: Double(profile.maxHR),
            restingBaselineDayCount: baseline.freshRestingSampleCount(now: now),
            hrvBaseline: AtriaPhysiologicalStressModel.robustHRVBaseline(
                lnRMSSDValues: qualifiedLnRMSSD,
                qualifiedDayCount: baseline.freshHRVSampleCount(now: now)
            )
        )
    }

    /// Invalidate a running generation at the publication edge, before the
    /// debounce delay. The delayed subject starts only the newest coalesced
    /// worker; an older result cannot land during that delay.
    private func invalidateAndEnqueueHistoricalStressReplay() {
        _ = historicalStressReplayGate.begin()
        historicalStressReplayWorker?.cancel()
        historicalStressReplayWorker = nil
        historicalStressReplayTriggerSubject.send(())
    }

    /// Handoff-12 CP2: the foreground-return entry into the same debounced,
    /// generation-gated replay lane every other trigger uses. No new worker
    /// kind — reconciliation IS the historical replay, now sourced from the
    /// resident journal union so live-period minutes are reachable.
    func enqueueStressContinuityReconciliation() {
        invalidateAndEnqueueHistoricalStressReplay()
    }

    /// Recovered history is captured only after SessionStore's complete
    /// publication fence. MainActor retains bounded COW source storage without
    /// walking HR/RR rows; scalar materialization, context qualification, window
    /// framing, shared RR qualification, and v3 evaluation run in a cancellable
    /// utility worker. Rapid publications invalidate the older generation before
    /// any result can reach the chronological archive.
    private func scheduleHistoricalStressReplay(now: Date) {
        let generation = historicalStressReplayGate.begin()
        historicalStressReplayWorker?.cancel()
        historicalStressReplayWorker = nil

        let personalization = Self.historicalStressPersonalization(
            baseline: store.baseline,
            profile: store.profile,
            fallbackRestingHeartRate: liveSessionDerived.rest,
            now: now
        )
        let savedSessions = store.historySnapshot.sessions
        let confirmedWorkouts = store.confirmedWorkouts
        let confirmedSleeps = store.confirmedSleeps

        let worker = Task.detached(priority: .utility)
            { () -> (AtriaHistoricalStressReplay.Result,
                     AtriaHistoricalStressReplay.GapClassificationDraft?,
                     String?) in
            // Handoff-12 CP2: today's live-period minutes live in the resident
            // journal, not in any saved session, so a replay sourced only from
            // saved sessions could never reconcile a minute the live scorer
            // missed (backgrounded, starved MainActor, skipped tick, relaunch)
            // until the session sealed — the physically measured 16:12–16:19
            // dense-HR hole. Union the row-capped resident journal in; a cold
            // or busy journal cache keeps the previous source unchanged.
            let journal = (try? SessionStore
                .loadCachedResidentJournalSessionForSleepReview(
                    now: now,
                    cooperativeDeadline: .init(
                        uptimeNanoseconds:
                            DispatchTime.now().uptimeNanoseconds
                            + 2_000_000_000
                    )
                )) ?? nil
            // W1-B (stress-gaps fix 1): the saved-session cache is
            // newest-first and `evaluate` refuses to sort (deliberate
            // overlap-provenance guard), so the resident journal — the newest
            // session — must join at the FRONT after the id dedupe. The old
            // `append` flipped the monotonic direction and made every
            // journal-unioned replay fail closed to `.empty` (device-proven
            // qualifiedAndReconciled=0 since d10f1fcd). A journal older than
            // the head is dropped for this run — fail closed, identical to a
            // no-journal replay.
            let union = AtriaHistoricalStressReplay.journalUnionedSourceSessions(
                savedSessions: savedSessions,
                journal: journal
            )
            let unionSessions = union.sessions
            guard let snapshot = await MainActor.run(body: {
                AtriaHistoricalStressReplay.snapshot(
                    sessions: unionSessions,
                    confirmedWorkouts: confirmedWorkouts,
                    confirmedSleeps: confirmedSleeps,
                    personalization: personalization,
                    now: now
                )
            }) else { return (.empty, nil, nil) }
            let result = AtriaHistoricalStressReplay.evaluate(snapshot)
            // W1-B (stress-gaps fix 4): a structurally-rejected non-empty
            // source yields an honest abort marker for the gap receipts —
            // never per-minute `kernel_declined` for a kernel that never ran.
            let replayAbortReason = AtriaHistoricalStressReplay.replayAbortReason(
                result: result,
                sourceSessions: unionSessions
            )
            // Handoff-13 CP2: the draft classifies against the replay SOURCE
            // only; the finalize step on the main actor overlays merged-store
            // presence and the active-journal row-cap deferral, where those
            // truths live.
            let draft = AtriaHistoricalStressReplay.classifyGapMinutes(
                sessions: unionSessions,
                producedFacts: result.facts,
                activeJournalSpan: union.activeJournalSpan,
                now: now
            )
            return (result, draft, replayAbortReason)
        }
        historicalStressReplayWorker = worker
        Task { @MainActor [weak self] in
            let (replay, draft, replayAbortReason) = await worker.value
            guard !worker.isCancelled,
                  let self,
                  self.historicalStressReplayGate.accepts(generation) else {
                return
            }
            await self.stressMonitorStore.waitForHistoryHydration()
            guard !worker.isCancelled,
                  self.historicalStressReplayGate.accepts(generation) else {
                return
            }
            self.historicalStressReplayWorker = nil
            await self.stressMonitorStore.mergeHistoricalMinuteFacts(
                replay,
                now: now
            )
            if let draft {
                let cadence = AtriaPhysiologicalStressModel.evaluationCadence
                let mergedMinutes = Set(
                    self.stressMonitorStore.history.map {
                        Int(floor($0.t.timeIntervalSince1970 / cadence)
                            * cadence)
                    }
                )
                AtriaHistoricalStressReplay.finalizeGapReceipts(
                    draft: draft,
                    mergedStoreMinutes: mergedMinutes,
                    now: now,
                    replayAbortReason: replayAbortReason
                )
            }
        }
    }

    private func publishHeroSnapshotIfNeeded(_ next: HeroSnapshot) {
        guard admitsLivePresentationMutation() else { return }
        guard next != heroStore.state else { return }
        heroStore.state = next
        publishHomeStatsIfNeeded(Self.makeHomeStatsState(hero: next))
    }

    private func publishSnapshotIfNeeded(_ next: Snapshot) {
        guard admitsLivePresentationMutation() else { return }
        guard next != snapshotStore.state else { return }
        snapshotStore.state = next
    }

    private func publishHomeStatsIfNeeded(_ next: HomeStatsState) {
        guard admitsLivePresentationMutation() else { return }
        guard next != homeStatsStore.state else { return }
        homeStatsStore.state = next
    }

    private func scheduleDeferredDiagnosticsRefresh() {
        guard livePresentationIsCurrentlyAuthorized else { return }
        guard !diagnosticsWorkInFlight else {
            AtriaDebugLog("ATRIADBG home_diagnostics status=skipped reason=refresh_in_flight")
            return
        }
        diagnosticsPresentationIsDirty = false
        diagnosticsWorkItem?.cancel()
        let token = UUID()
        diagnosticsRefreshToken = token
        diagnosticsWorkInFlight = true
        let recoveryIsLearning = heroStore.state.recoveryEstimate.percent == nil
        let workItem = DispatchWorkItem(qos: .utility) { [weak self] in
            guard let self else { return }
            let details = Self.makeDeferredDetails(ble: self.ble,
                                                   store: self.store,
                                                   recoveryIsLearning: recoveryIsLearning)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.diagnosticsRefreshToken == token else {
                    return
                }
                guard self.livePresentationIsCurrentlyAuthorized else {
                    self.diagnosticsPresentationIsDirty = true
                    self.diagnosticsWorkInFlight = false
                    self.diagnosticsWorkItem = nil
                    return
                }
                self.deferredDetails = details
                self.diagnosticsWorkInFlight = false
                if !self.snapshotStore.diagnosticsReady {
                    self.snapshotStore.diagnosticsReady = true
                }
                let nextHero: HeroSnapshot
                #if DEBUG
                if let debugHeroFixture = self.debugHeroFixture {
                    nextHero = debugHeroFixture
                } else {
                    nextHero = Self.makeHeroSnapshot(ble: self.ble,
                                                     store: self.store,
                                                     live: self.coreLiveStore.state,
                                                     savedAggregate: self.savedAggregate,
                                                     deferredDetails: details,
                                                     stressState: self.stressMonitorStore.state,
                                                     stressLastMeasuredAt: self.stressMonitorStore.lastMeasuredAt)
                }
                #else
                nextHero = Self.makeHeroSnapshot(ble: self.ble,
                                                 store: self.store,
                                                 live: self.coreLiveStore.state,
                                                 savedAggregate: self.savedAggregate,
                                                 deferredDetails: details,
                                                 stressState: self.stressMonitorStore.state,
                                                 stressLastMeasuredAt: self.stressMonitorStore.lastMeasuredAt)
                #endif
                self.publishHeroSnapshotIfNeeded(nextHero)
                self.publishSnapshotIfNeeded(Self.makeSnapshot(store: self.store,
                                                               hero: nextHero,
                                                               deferredDetails: details))
                self.scheduleDirtyDiagnosticsAfterForegroundIfNeeded()
            }
        }
        diagnosticsWorkItem = workItem
        DispatchQueue.global(qos: .utility).async(execute: workItem)
    }

    /// A canceled/requested diagnostics pass is retained across suspension, but
    /// its archive projection begins only after the foreground catch-up has
    /// yielded a runloop turn and then passed the existing debounce.
    private func scheduleDirtyDiagnosticsAfterForegroundIfNeeded() {
        guard diagnosticsRequested,
              diagnosticsPresentationIsDirty,
              livePresentationIsCurrentlyAuthorized,
              !diagnosticsPresentationResumeScheduled else { return }
        diagnosticsPresentationResumeScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.diagnosticsPresentationResumeScheduled = false
            guard self.diagnosticsRequested,
                  self.diagnosticsPresentationIsDirty,
                  self.livePresentationIsCurrentlyAuthorized else { return }
            self.diagnosticsRefreshSubject.send(())
        }
    }

    private func refreshLiveSessionDerivedIfNeeded() {
        let rest = currentPulseZoneContext().rest
        let maxHR = store.profile.maxHR
        let profile = store.profile
        let samples = ble.session
        let needsRefresh = liveSessionDerived.rest != rest
            || liveSessionDerived.maxHR != maxHR
            || liveSessionDerived.biologicalSex != profile.biologicalSex
            || (liveSessionDerived.activeCalories != nil) != profile.hasEnergyProfile
            || liveSessionDerived.sampleCount != samples.count
            || liveSessionDerived.lastTimestamp != samples.last?.t
            || liveSessionDerived.cycleStart != savedAggregate.cycleStart

        guard needsRefresh else { return }
        let previousFallbackRest = liveSessionDerived.rest
        liveSessionDerived = Self.nextLiveSessionDerived(
            previous: liveSessionDerived,
            samples: samples,
            rest: rest,
            maxHR: maxHR,
            profile: profile,
            cycleStart: savedAggregate.cycleStart
        )
        if liveSessionDerived.rest != previousFallbackRest {
            historicalStressFallbackRestSubject.send(liveSessionDerived.rest)
        }
    }

    private func currentPulseZoneContext() -> PulseZoneContext {
        PulseZoneContext(rest: currentRestingContext().resolved,
        maxHR: store.profile.maxHR)
    }

    private func currentRestingContext() -> RestingMetricContext {
        Self.restingMetricContext(baselineResting: store.baseline.restingInt,
                                  liveResting: ble.restingHR,
                                  latestSavedResting: cachedLatestSavedResting())
    }

    private func cachedLatestSavedResting() -> Int? {
        let latest = store.sessions.first
        let key = SavedRestingFallbackKey(sessionID: latest?.id,
                                          sessionEnd: latest?.end,
                                          pointCount: latest?.points.count ?? 0,
                                          firstPointTime: latest?.points.first?.t,
                                          lastPointTime: latest?.points.last?.t)
        if let savedRestingFallbackCache,
           savedRestingFallbackCache.key == key {
            return savedRestingFallbackCache.value
        }

        let resolved = latest.map(\.restingStable).flatMap { $0 > 0 ? $0 : nil }
        savedRestingFallbackCache = SavedRestingFallbackCache(key: key, value: resolved)
        return resolved
    }

    nonisolated static func resolvedRestingHeartRate(
        baselineResting: Int?,
        liveResting: Int?,
        latestSavedResting: () -> Int?
    ) -> Int {
        if let baselineResting { return baselineResting }
        if let liveResting { return liveResting }
        return latestSavedResting() ?? 60
    }

    nonisolated static func restingMetricContext(
        baselineResting: Int?,
        liveResting: Int?,
        latestSavedResting: Int?
    ) -> RestingMetricContext {
        RestingMetricContext(
            resolved: resolvedRestingHeartRate(baselineResting: baselineResting,
                                               liveResting: liveResting) {
                latestSavedResting
            },
            // Recovery historically used a current live estimate first and a
            // saved-session estimate second; a learned baseline alone is not a
            // current-cycle measurement.
            currentForRecovery: liveResting ?? latestSavedResting,
            hasEvidence: baselineResting != nil || liveResting != nil || latestSavedResting != nil
        )
    }

    static func pulseZoneContext(baselineResting: Int?,
                                 liveResting: Int?,
                                 latestSavedResting: Int?,
                                 maxHR: Int) -> PulseZoneContext {
        PulseZoneContext(rest: resolvedRestingHeartRate(baselineResting: baselineResting,
                                                        liveResting: liveResting) {
            latestSavedResting
        },
                         maxHR: maxHR)
    }

    nonisolated static func strainConfidence(hasRestingHeartRateEvidence: Bool,
                                              maxHRSource: AthleteProfile.HRMaxSource,
                                              hasLoadEvidence: Bool,
                                              resolvedRest: Int,
                                              maxHR: Int,
                                              wearCoverageFraction: Double? = nil) -> String {
        guard hasRestingHeartRateEvidence,
              hasLoadEvidence,
              resolvedRest > 0,
              maxHR > resolvedRest else { return "learning" }
        let base = maxHRSource == .measured
            ? "local"
            : "provisional · age-estimated max HR"
        return Metrics.StrainPresentation.resolve(
            value: 0,
            coverageFraction: wearCoverageFraction,
            baseConfidence: base
        ).confidence
    }

    /// Union length in seconds of session intervals clipped to the window.
    /// Sessions can overlap (historic workout checkpoints overlapped the
    /// all-day roll), so summing raw durations would double-count wear.
    nonisolated static func observedWearUnionSeconds(
        intervals: [(start: Date, end: Date)],
        windowStart: Date,
        windowEnd: Date
    ) -> TimeInterval {
        guard windowEnd > windowStart else { return 0 }
        let clipped: [(Double, Double)] = intervals.compactMap { interval in
            let start = Swift.max(interval.start.timeIntervalSinceReferenceDate,
                                  windowStart.timeIntervalSinceReferenceDate)
            let end = Swift.min(interval.end.timeIntervalSinceReferenceDate,
                                windowEnd.timeIntervalSinceReferenceDate)
            return end > start ? (start, end) : nil
        }.sorted { $0.0 < $1.0 }
        var total = 0.0
        var openStart: Double?
        var openEnd = 0.0
        for (start, end) in clipped {
            if openStart != nil, start <= openEnd {
                openEnd = Swift.max(openEnd, end)
                continue
            }
            if let currentStart = openStart {
                total += openEnd - currentStart
            }
            openStart = start
            openEnd = end
        }
        if let currentStart = openStart {
            total += openEnd - currentStart
        }
        return total
    }

    /// Qualified wear is the union of accepted HR continuity, not the envelope
    /// of a SavedSession. A reconnect journal can span hours while containing
    /// only minutes of real samples; treating its start/end as continuous wear
    /// makes sparse daily strain look complete.
    nonisolated static func observedHeartRateUnionSeconds(
        sessions: [SavedSession],
        windowStart: Date,
        windowEnd: Date
    ) -> TimeInterval {
        var intervals: [(start: Date, end: Date)] = []
        for session in sessions where session.end > windowStart && session.start < windowEnd {
            let points = AtriaStrengthLog.pointsExcludingIntervals(
                session.points,
                sessionStart: session.start,
                excludedIntervals: session.excludedIntervals
            )
            .compactMap { point -> (date: Date, bpm: Int)? in
                let date = session.start.addingTimeInterval(max(0, point.t))
                guard date >= windowStart, date < windowEnd,
                      (35...240).contains(point.bpm) else { return nil }
                return (date, point.bpm)
            }
            .sorted { $0.date < $1.date }

            for point in points {
                intervals.append((
                    start: max(windowStart, point.date.addingTimeInterval(-0.5)),
                    end: min(windowEnd, point.date.addingTimeInterval(0.5))
                ))
            }
            for pair in zip(points, points.dropFirst()) {
                let gap = pair.1.date.timeIntervalSince(pair.0.date)
                if gap > 0, gap <= AtriaAnalytics.Strain.maximumLoadEvidenceGap {
                    intervals.append((start: pair.0.date, end: pair.1.date))
                }
            }
        }
        return observedWearUnionSeconds(intervals: intervals,
                                        windowStart: windowStart,
                                        windowEnd: windowEnd)
    }

    /// Coverage fraction of the physiological day that has HR evidence, or
    /// nil while the day is too young for the fraction to be meaningful.
    nonisolated static func dayWearCoverageFraction(
        observedSeconds: TimeInterval,
        dayElapsedSeconds: TimeInterval,
        minimumEvaluationWindow: TimeInterval = 3 * 3600
    ) -> Double? {
        guard dayElapsedSeconds >= minimumEvaluationWindow else { return nil }
        return Swift.min(1, Swift.max(0, observedSeconds / dayElapsedSeconds))
    }

    private static func makeCoreLiveState(ble: AtriaBLEManager,
                                          liveSessionDerived: LiveSessionDerived,
                                          savedAggregate: SavedAggregate,
                                          canonicalStepDays: [AtriaHistoricalDailyConsumerProjection.StepDay],
                                          motionTickDailyStore: AtriaWhoop4MotionTickDailyStore = .shared) -> CoreLiveState {
        let deviceName = ble.resolvedDeviceName
        let displayableBatteryLevel = ble.displayableBatteryLevel()
        let batteryRecentlyDropping = displayableBatteryLevel != nil && ble.batteryRecentlyDropping
        let batteryChargeProjection: BatteryChargeProjection
        let batteryChargeLastVerifiedAt: Date?
        if displayableBatteryLevel != nil {
            let now = Date()
            let persistedBattery = AtriaBLEManager.cachedBattery(
                chargeMaxAge: freshChargerEvidenceInterval,
                now: now
            )
            batteryChargeProjection = resolvedBatteryChargeProjection(
                liveStatus: ble.batteryChargeStatus,
                liveIsCharging: ble.batteryIsCharging,
                batteryRecentlyDropping: batteryRecentlyDropping,
                persistedStatus: persistedBattery.chargeStatus,
                persistedAge: persistedBattery.chargeAge
            )
            batteryChargeLastVerifiedAt = resolvedBatteryChargeVerifiedAt(
                projection: batteryChargeProjection,
                liveVerifiedAt: ble.batteryChargeLastVerifiedAt,
                persistedStatus: persistedBattery.chargeStatus,
                persistedAge: persistedBattery.chargeAge,
                now: now
            )
        } else {
            batteryChargeProjection = BatteryChargeProjection(status: .levelOnly,
                                                               isCharging: false)
            batteryChargeLastVerifiedAt = nil
        }
        let strapStepsToday = mergedStrapStepResearchCount(
            savedToday: savedAggregate.savedTodayStrapSteps,
            savedActiveSession: savedAggregate.savedActiveSessionStrapSteps,
            savedActiveSessionTotal: savedAggregate.savedActiveSessionTotalStrapSteps,
            liveActiveSession: ble.liveStrapStepResearchCount
        )
        let currentCycleStepDays: [
            AtriaHistoricalDailyConsumerProjection.StepDay
        ]
        let qualifiedCanonicalStepDays =
            motionTickDailyStore.removingUnqualifiedResearchEvidence(
                from: canonicalStepDays
            )
        let strapIdentifiers =
            AtriaWhoop4MotionTickDailyStore.persistedStrapIdentifiers()
        if !strapIdentifiers.isEmpty {
            currentCycleStepDays = motionTickDailyStore
                .mergingCurrentCycleReceipt(
                    into: qualifiedCanonicalStepDays,
                    strapIdentifiers: strapIdentifiers,
                    windowStart: savedAggregate.cycleStart,
                    now: Date()
                )
        } else {
            currentCycleStepDays = qualifiedCanonicalStepDays
        }
        // 2026-07-31: disclosure-only prior-cycle receipt. Never merged into
        // currentCycleStepDays; presentation may only name it while today's
        // value stays "--".
        let priorCycleReceipt = strapIdentifiers.isEmpty
            ? nil
            : motionTickDailyStore.latestReceipt(
                before: savedAggregate.cycleStart,
                strapIdentifiers: strapIdentifiers
            )
        var dailyStepPresentation = AtriaDailyStepPresentation.resolve(
            day: Date(),
            now: Date(),
            liveCount: strapStepsToday,
            liveValidationState: ble.liveStrapStepResearchState,
            liveCapturedAt: ble.liveStrapStepCountCapturedAt,
            canonicalDays: currentCycleStepDays,
            liveAuthorityQualified:
                AtriaWhoop4GravityCadenceStepModel
                    .releaseDailyAuthorityQualified,
            physiologicalDayStart: savedAggregate.cycleStart,
            priorCycleReceipt: priorCycleReceipt.map {
                .init(steps: $0.steps, endedAt: $0.capturedThrough)
            },
            boundaryIsUnconfirmedFallback:
                savedAggregate.cycleBoundaryIsUnconfirmedFallback
        )
        // Classify strap-motion availability so the step copy stops promising an
        // endless sync when the transport is a terminal pure-HR fallback (while
        // keeping the verified count/coverage). Computed once per Core-Live
        // rebuild, not per HR sample.
        dailyStepPresentation.motionAvailability = ble.strapMotionAvailability
        let activeCaloriesToday = SessionStore.mergedTodayActiveCalories(
            savedToday: savedAggregate.savedTodayActiveCalories,
            savedActiveSession: savedAggregate.savedActiveSessionActiveCalories,
            liveActiveSession: liveSessionDerived.activeCalories
        )
        return CoreLiveState(status: ble.status,
                             bluetoothPermissionDenied: ble.bluetoothPermissionDenied,
                             deviceName: deviceName,
                             displayDeviceName: AtriaDeviceDisplayName.shortName(for: deviceName),
                             batteryLevel: displayableBatteryLevel ?? -1,
                             batteryIsCharging: batteryChargeProjection.isCharging,
                             batteryChargeStatus: batteryChargeProjection.status,
                             batteryRecentlyDropping: batteryRecentlyDropping,
                             batteryReadingIsRecentBaseline: displayableBatteryLevel != nil && ble.batteryReadingIsRecentBaseline,
                             batteryLastVerifiedAt: ble.lastVerifiedBatteryLevelAt,
                             batteryChargeLastVerifiedAt: batteryChargeLastVerifiedAt,
                             strapStreamState: ble.strapStreamState,
                             rrContinuityState: ble.rrContinuityState,
                             hrvSDNN: ble.hrvSnapshot?.sdnn,
                             hrvPNN50: ble.hrvSnapshot?.pnn50,
                             sessionSampleCount: liveSessionDerived.sampleCount,
                             hasRecentHeartRateSample: hasRecentHeartRateSample(ble: ble),
                             lastReadingAt: liveSessionDerived.lastTimestamp,
                             liveTRIMP: liveSessionDerived.trimp,
                             liveActiveCalories: activeCaloriesToday,
                             strapStepResearchCount: strapStepsToday,
                             strapStepResearchState: ble.liveStrapStepResearchState,
                             dailyStepPresentation: dailyStepPresentation,
                             officialAppCoexistenceRisk: ble.officialAppCoexistenceRisk,
                             lastScanRequestedAt: ble.lastScanRequestedAt,
                             lastScanMatchAt: ble.lastScanMatchAt,
                             pendingKnownReconnectStartedAt: ble.pendingKnownReconnectStartedAt,
                             pendingKnownReconnectReason: ble.pendingKnownReconnectReason,
                             rangeLossBackfillPending: ble.rangeLossBackfillPending,
                             historicalRecoveryPresentation: ble.historicalRecoveryPresentation)
    }

    nonisolated static func mergedStrapStepResearchCount(savedToday: Int,
                                                        savedActiveSession: Int,
                                                        liveActiveSession: Int) -> Int {
        let saved = max(0, savedToday)
        let savedActive = min(saved, max(0, savedActiveSession))
        return saved - savedActive + max(savedActive, max(0, liveActiveSession))
    }

    nonisolated static func mergedStrapStepResearchCount(savedToday: Int,
                                                        savedActiveSession: Int,
                                                        savedActiveSessionTotal: Int,
                                                        liveActiveSession: Int) -> Int {
        let saved = max(0, savedToday)
        let checkpointRaw = max(0, savedActiveSessionTotal)
        let newSinceCheckpoint = max(0, liveActiveSession - checkpointRaw)
        return saved + newSinceCheckpoint
    }

    private static func makePulseLiveState(ble: AtriaBLEManager,
                                           rest: Int,
                                           maxHR: Int,
                                           recentRRSamples: [AtriaBreathworkSession.RRSample]) -> PulseLiveState {
        let reconciledHeartRate = liveHeartRate(ble: ble)
        return PulseLiveState(heartRate: reconciledHeartRate,
                              hasContact: reconciledHeartRate > 0,
                              sensorHasContact: ble.hasContact,
                              averageHeartRate: ble.liveHeartWindow.average,
                              peakHeartRate: ble.liveHeartWindow.peak,
                              heartRateZone: Metrics.heartRateZone(bpm: reconciledHeartRate,
                                                                    rest: rest,
                                                                    max: maxHR),
                              recentRRSamples: recentRRSamples)
    }

    private static func makeHeroPulseState(ble: AtriaBLEManager,
                                           rest: Int,
                                           maxHR: Int,
                                           recentRRSamples: [AtriaBreathworkSession.RRSample]) -> HeroPulseState {
        let reconciledHeartRate = liveHeartRate(ble: ble)
        return HeroPulseState(heartRate: reconciledHeartRate,
                              hasContact: reconciledHeartRate > 0,
                              sensorHasContact: ble.hasContact,
                              heartRateZone: Metrics.heartRateZone(bpm: reconciledHeartRate,
                                                                    rest: rest,
                                                                    max: maxHR),
                              recentRRSamples: recentRRSamples)
    }

    private static func makePulseSparklineState(ble: AtriaBLEManager) -> PulseSparklineState {
        PulseSparklineState(values: ble.liveHeartWindow.sparkline,
                            chartPoints: compactHeartChartPoints(Array(ble.session.suffix(900))))
    }

    private static func liveHeartRate(ble: AtriaBLEManager) -> Int {
        resolvedLiveHeartRate(heartRate: ble.heartRate,
                              sensorHasContact: ble.hasContact,
                              status: ble.status,
                              latestSampleHeartRate: ble.session.last?.bpm,
                              latestSampleAt: ble.session.last?.t)
    }

    nonisolated static func resolvedLiveHeartRate(heartRate: Int,
                                                  sensorHasContact: Bool,
                                                  status: AtriaBLEManager.Status,
                                                  latestSampleHeartRate: Int?,
                                                  latestSampleAt: Date?,
                                                  now: Date = Date()) -> Int {
        guard status == .connected,
              sensorHasContact,
              let latestSampleAt,
              let latestSampleHeartRate,
              latestSampleHeartRate > 0 else {
            return 0
        }
        let sampleAge = now.timeIntervalSince(latestSampleAt)
        guard sampleAge >= 0,
              sampleAge <= liveHeartRateFreshnessInterval else { return 0 }
        if heartRate > 0 { return heartRate }
        return latestSampleHeartRate
    }

    private static func hasRecentHeartRateSample(ble: AtriaBLEManager, now: Date = Date()) -> Bool {
        resolvedLiveHeartRate(heartRate: ble.heartRate,
                              sensorHasContact: ble.hasContact,
                              status: ble.status,
                              latestSampleHeartRate: ble.session.last?.bpm,
                              latestSampleAt: ble.session.last?.t,
                              now: now) > 0
    }

    private static func compactHeartChartPoints(_ samples: [HRSample], targetCount: Int = 120) -> [HeartRateChartPoint] {
        let valid = samples.filter { $0.bpm > 0 }
        guard valid.count > targetCount else {
            return valid.map { HeartRateChartPoint(t: $0.t, bpm: $0.bpm) }
        }
        let stride = Double(valid.count - 1) / Double(targetCount - 1)
        return (0..<targetCount).map { index in
            let sample = valid[Int((Double(index) * stride).rounded())]
            return HeartRateChartPoint(t: sample.t, bpm: sample.bpm)
        }
    }

    private static func makeCollectionLiveState(ble: AtriaBLEManager) -> CollectionLiveState {
        return CollectionLiveState(isRecording: ble.isRecording,
                                   capturedRows: ble.capturedRows,
                                   captureSummary: ble.captureSummary,
                                   captureWasValidationReady: ble.captureWasValidationReady,
                                   lastCaptureFile: ble.lastCaptureFile,
                                   standardHROnlyEnabled: ble.standardHROnlyEnabled,
                                   longWearModeEnabled: ble.longWearModeEnabled,
                                   rangeLossBackfillPending: ble.rangeLossBackfillPending,
                                   collectionProfile: ble.collectionProfile,
                                   officialAppCoexistenceRisk: ble.officialAppCoexistenceRisk)
    }

    /// W3-B (strain-targets fix 2): the presentation authority in
    /// `SessionStore.pendingSleepRecoveryEstimate` stamps every pending
    /// sleep-review preview with this marker. The preview is display evidence
    /// only and must NEVER reach the durable strain-target minter, whatever
    /// its tier; a source-scan test pins the Sessions.swift stamp to this
    /// constant so the two cannot drift.
    nonisolated static let pendingSleepReviewPreviewDetailMarker = "pending sleep review"

    /// Durable coaching targets require numeric AUTHORITATIVE Recovery.
    /// Canonical tiers mint canonically; a numeric authoritative `.unverified`
    /// projection may provisionally fill an empty cycle slot (W3-B fix 2,
    /// via `AtriaDailyStrainTargetStore.mintAuthority`). The pending
    /// sleep-review presentation preview is intentionally `.unverified` and
    /// stays visual-only — it is stripped here by its authority marker before
    /// any write authority is derived.
    nonisolated static func recoveryAuthorizedForStrainTarget(
        _ estimate: Metrics.RecoveryEstimate
    ) -> (percent: Int, tier: Metrics.RecoveryEstimate.Confidence)? {
        guard !estimate.detail.contains(Self.pendingSleepReviewPreviewDetailMarker) else {
            return nil
        }
        guard estimate.confidence == .personalBaseline
                || estimate.confidence == .validated
                || estimate.confidence == .unverified,
              let percent = estimate.percent else { return nil }
        return (percent, estimate.confidence)
    }

    /// W3-B (strain-targets fix 5): shifted-sleeper presentation continuity.
    /// During the post-wake window where the cycle has flipped but recovery is
    /// not yet canonical (no frozen target and no live kernel target), append
    /// the PRIOR cycle's frozen target to the guidance sentence as a dated
    /// disclosure — the AtriaCurrentDayPresentation/AtriaPriorCycleDisclosure
    /// pattern: a prior cycle's value may only appear dated, never as today's
    /// primary. No fabricated value: the real prior target with its real date,
    /// and `target` stays nil so the zone chip stays absent
    /// (`TargetZones.strain` fail-closed behavior).
    nonisolated static func guidanceDisclosingPriorCycleStrainTarget(
        _ guidance: Coach.Guidance,
        priorCycleTarget: AtriaFrozenDailyStrainTarget?
    ) -> Coach.Guidance {
        guard guidance.target == nil, let prior = priorCycleTarget else { return guidance }
        let dateText = prior.day.formatted(.dateTime.month(.abbreviated).day())
        let qualifier = prior.isProvisional ? "provisional target" : "target"
        let disclosure = String(format: " Prior cycle (%@) %@ was %.1f — shown dated until this cycle's recovery is ready.",
                                dateText, qualifier, prior.target)
        return Coach.Guidance(headline: guidance.headline,
                              detail: guidance.detail + disclosure,
                              color: guidance.color,
                              target: nil,
                              state: guidance.state,
                              reason: guidance.reason + "_prior_cycle_target_disclosed")
    }

    private static func makeHeroSnapshot(ble: AtriaBLEManager,
                                         store: SessionStore,
                                         live: CoreLiveState,
                                         savedAggregate: SavedAggregate,
                                         deferredDetails: DeferredDetails?,
                                         stressState: AtriaStressState,
                                         stressLastMeasuredAt: Date?) -> HeroSnapshot {
        let restingContext = savedAggregate.restingContext
        let rest = restingContext.resolved
        let calendar = Calendar.current
        let now = Date()
        // `rest` remains the learned/stable math anchor for zones, TRIMP,
        // strain and VO2. The number shown as RHR must instead be the current
        // physiological-cycle measurement used by recovery and Vitals.
        let presentationRestingHeartRate = store.currentCycleRestingHeartRateForPresentation(
            on: now,
            calendar: calendar
        )
        // Same deterministic no-value token as every other metric value. Left as
        // the old word, the Vitals heart-rate row rendered "Now --", "Average
        // --", "Peak --" beside "Resting Learning": one row, one state, two
        // vocabularies.
        let restText = presentationRestingHeartRate.map(String.init)
            ?? AtriaCompactMetricPresentation.noValue
        let fallbackHrv = fallbackHeroHRVState(ble: ble, store: store)
        let headline = deferredDetails?.headline ?? defaultHeroHeadline(status: ble.status)
        let nextAction = deferredDetails?.nextAction ?? defaultHeroNextAction(status: ble.status)

        let physiologicalCycle = AtriaPhysiologicalCycle.current(now: now,
                                                                 confirmedSleeps: store.confirmedSleeps,
                                                                 calendar: calendar)
        let maxHR = store.profile.maxHR
        let latestSleep = store.currentPhysiologicalMainSleep(on: now, calendar: calendar)
        let sleepRecoveryIsProvisional = latestSleep == nil
        let storedRecovery = store.dailyRollupHistory.first {
            physiologicalCycle.boundaryKind == .mainSleep
                && calendar.isDate($0.day, inSameDayAs: physiologicalCycle.start)
                && $0.recovery != nil
        }
        // SessionStore owns the wake-to-wake recovery projection. Frozen days
        // never evaluate Recovery v2; a provisional input set is memoized for a
        // bounded four-hour cadence shared with widgets and notifications.
        let recovery = store.recoveryProjectionForPresentation(
            now: now,
            calendar: calendar,
            initialFallbackHRVSnapshot: ble.recoveryHRVSnapshot,
            liveRestingHeartRate: ble.restingHR,
            pendingSleepReview: store.pendingSleepReviewNightForUI
        )
        let recoveryIsProvisional = sleepRecoveryIsProvisional
            || recovery.confidence == .unverified
            || recovery.confidence == .learning
        // Handoff-10 CP1: the presentation identity decides what a
        // Today-labelled surface may show as PRIMARY. The cycle's frozen
        // values belong to the anchoring wake's civil day (or the fallback
        // boundary's); when that is not today, the primary becomes today's
        // own partial row (with its real limited confidence) or a terminal
        // awaiting state, and the prior cycle survives only as a dated
        // disclosure. The wake-to-wake math above is unchanged.
        let cycleValueSourceDay: Date? = physiologicalCycle.boundaryKind == .mainSleep
            ? latestSleep.map { $0.end ?? $0.day }
            : physiologicalCycle.start
        let todayRollup = store.dailyRollupHistory.first {
            calendar.isDate($0.day, inSameDayAs: calendar.startOfDay(for: now))
        }
        let priorCycleRollup = cycleValueSourceDay.flatMap { sourceDay in
            store.dailyRollupHistory.first {
                calendar.isDate($0.day, inSameDayAs: sourceDay) && $0.recovery != nil
            }
        }
        let dayResolution = AtriaCurrentDayPresentation.resolve(
            now: now,
            cycleStart: physiologicalCycle.start,
            cycleEnd: AtriaPhysiologicalCycle.nextNoSleepRollover(
                now: now,
                confirmedSleeps: store.confirmedSleeps,
                calendar: calendar
            ),
            anchorSleepID: physiologicalCycle.anchorSleepID,
            cycleValueSourceDay: cycleValueSourceDay,
            currentDayPartialRecovery: AtriaCurrentDayPresentation
                .currentDayPartialRecovery(
                    fromRollupSummary: todayRollup?.recoverySummary,
                    rollupDay: todayRollup?.day,
                    now: now,
                    calendar: calendar
                ),
            currentDayPartialStrain: todayRollup?.strain,
            priorCycle: priorCycleRollup.map {
                AtriaPriorCycleDisclosure(civilDay: $0.day,
                                          recoveryPercent: $0.recovery,
                                          sleepSeconds: $0.sleepSeconds,
                                          strain: $0.strain)
            },
            calendar: calendar
        )
        let presentedRecovery = dayResolution.recoveryOverride ?? recovery
        let presentedRecoveryIsProvisional = dayResolution.recoveryOverride != nil
            || recoveryIsProvisional
        // The primary never carries a prior cycle's value anymore; the dated
        // disclosure replaces the old heuristic marker.
        let recoveryIsFromPreviousSleep = false
        let stress = HeroSnapshot.resolvedStressPresentation(
            state: stressState,
            lastMeasuredAt: stressLastMeasuredAt,
            physiologicalCycleStart: physiologicalCycle.start,
            now: now
        )
        let liveTRIMP = live.liveTRIMP
        let totalTRIMP = SessionStore.mergedTodayTRIMP(
            savedToday: savedAggregate.savedTodayTRIMP,
            savedActiveSession: savedAggregate.savedActiveSessionTRIMP,
            liveActiveSession: liveTRIMP
        )
        let strain = Metrics.strain(fromTRIMP: totalTRIMP)
        let load = store.trainingLoadSummarySnapshot
        let hasRestEvidence = restingContext.hasEvidence
        // Live samples arrive at ~1 Hz, so the live count approximates seconds
        // of current-session evidence not yet checkpointed into saved records.
        let wearCoverage = Self.dayWearCoverageFraction(
            observedSeconds: savedAggregate.savedTodayObservedSeconds
                + Double(live.sessionSampleCount),
            // Denominator origin must match the (possibly folded) observed
            // numerator: across an unconfirmed fallback both span the continuous
            // active period from strainAccumulationStart, so coverage stays a
            // true fraction instead of an inflated >1 ratio.
            dayElapsedSeconds:
                now.timeIntervalSince(savedAggregate.strainAccumulationStart)
        )
        let baseStrainConfidence = strainConfidence(
            hasRestingHeartRateEvidence: hasRestEvidence,
            maxHRSource: store.profile.maxHRSource,
            hasLoadEvidence: savedAggregate.hasSavedToday || live.sessionSampleCount >= 60,
            resolvedRest: rest,
            maxHR: maxHR,
            wearCoverageFraction: wearCoverage
        )
        let strainPresentation = Metrics.StrainPresentation.resolve(
            value: strain,
            coverageFraction: wearCoverage,
            baseConfidence: baseStrainConfidence,
            additionalIncompleteEvidence: AtriaWorkoutMetricPresentation.cycleStrainIsIncomplete(
            start: physiologicalCycle.start,
            end: now,
            strain: strain,
            workouts: store.confirmedWorkouts
            )
        )
        let strainConfidence = strainPresentation.confidence

        let recoveryIsAttributedToCurrentDay = physiologicalCycle.boundaryKind == .noSleepFallback
            || storedRecovery != nil
            || (latestSleep.map { ($0.end ?? $0.day) == physiologicalCycle.start } == true)
        let loadIsPrepared = store.hasLoadedSavedSessions && store.trainingLoadSummaryIsPrepared
        // Pending-review Recovery is display evidence only — the gate strips
        // it before any write authority is derived. Canonical
        // personal-baseline/validated authority may mint, replace, or
        // invalidate the durable daily strain target; a numeric authoritative
        // `.unverified` projection may provisionally fill an empty cycle slot
        // (W3-B fix 2, shared `mintAuthority` standard, tier recorded as
        // provenance); visual guidance below may still use the clearly
        // labelled pending estimate.
        let strainTargetRecovery = recoveryAuthorizedForStrainTarget(recovery)
        let frozenTarget = AtriaDailyStrainTargetStore.resolve(recovery: strainTargetRecovery?.percent,
                                                               recoveryConfidence: strainTargetRecovery?.tier,
                                                               load: load,
                                                               recoveryIsAttributedToCurrentDay: recoveryIsAttributedToCurrentDay
                                                                   && strainTargetRecovery != nil,
                                                               loadIsPrepared: loadIsPrepared,
                                                               mutationAuthority: strainTargetRecovery == nil
                                                                   ? .preserveExisting
                                                                   : AtriaDailyStrainTargetStore.mintAuthority(
                                                                       recoveryConfidence: strainTargetRecovery?.tier),
                                                               cycleStart: physiologicalCycle.start,
                                                               now: now,
                                                               calendar: calendar)
        let kernelGuidance = Coach.guide(recovery: recovery,
                                         strain: strain,
                                         load: load,
                                         frozenTarget: frozenTarget?.target,
                                         frozenRecovery: frozenTarget?.recovery)
        // Assessment §13.3 (2026-08-14): the kernel still mints the frozen
        // 9–17 target; only the SENTENCE the user reads is rewritten in the
        // whiteboard's vocabulary (personal bands vs yesterday's TRIMP).
        // Mirrors the Today whiteboard's yesterday derivation.
        let whiteboardYesterday = latestSleep.flatMap { night -> DailyRollupStoreEntry? in
            guard let prior = calendar.date(byAdding: .day,
                                            value: -1,
                                            to: calendar.startOfDay(for: night.day)) else { return nil }
            return store.dailyRollupHistory.first { calendar.isDate($0.day, inSameDayAs: prior) }
        }
        let whiteboardGuidance = AtriaWhiteboardCoachSentence.rewrite(
            kernel: kernelGuidance,
            context: .init(hrvMS: Int(deferredDetails?.hrvValue ?? fallbackHrv.value),
                           restingHR: presentationRestingHeartRate,
                           baseline: AtriaBaselineTargetSnapshot(store.baseline),
                           yesterdayTRIMP: whiteboardYesterday?.trimp,
                           yesterdayStrainDisplay: whiteboardYesterday?.strain))
        // W3-B (strain-targets fix 5): the shifted sleeper who confirmed a
        // ~19:15 wake sees the cycle flip with no canonical recovery yet. When
        // no target exists for the new cycle, the prior cycle's REAL frozen
        // target survives only as a dated disclosure inside the guidance
        // sentence; `target` stays nil so the zone chip stays absent.
        let guidance = Self.guidanceDisclosingPriorCycleStrainTarget(
            whiteboardGuidance,
            priorCycleTarget: frozenTarget == nil && whiteboardGuidance.target == nil
                ? AtriaDailyStrainTargetStore.priorCycleSnapshot(cycleStart: physiologicalCycle.start,
                                                                 now: now,
                                                                 calendar: calendar)
                : nil)
        // Handoff-10 CP1: present the identity-resolved values. Cycle math
        // (guidance, strain target) above intentionally still uses the
        // wake-to-wake projection; only what the Today surface DISPLAYS as
        // primary changes.
        let presentedStrain = dayResolution.strainOverride ?? strain
        let presentedStrainConfidence = dayResolution.strainOverride != nil
            ? Metrics.StrainPresentation.resolve(
                value: presentedStrain,
                coverageFraction: wearCoverage,
                baseConfidence: baseStrainConfidence,
                additionalIncompleteEvidence: true
              ).confidence
            : strainConfidence
        return HeroSnapshot(recoveryEstimate: presentedRecovery,
                            recoveryIsProvisional: presentedRecoveryIsProvisional,
                            recoveryIsFromPreviousSleep: recoveryIsFromPreviousSleep,
                            identity: dayResolution.identity,
                            priorCycleDisclosure: dayResolution.priorCycle,
                            strain: presentedStrain,
                            strainConfidence: presentedStrainConfidence,
                            dayWearCoverageFraction: wearCoverage,
                            guidance: guidance,
                            hrvValue: deferredDetails?.hrvValue ?? fallbackHrv.value,
                            hrvDetail: deferredDetails?.hrvDetail ?? fallbackHrv.detail,
                            hrvNarrative: deferredDetails?.hrvNarrative ?? fallbackHrv.narrative,
                            stressLevel: stress.level,
                            stressValue: stress.value,
                            stressDetail: stress.detail,
                            stressNarrative: stress.narrative,
                            stressEvidenceMode: stress.evidenceMode,
                            stressMetricTitle: stress.metricTitle,
                            rrPackageText: deferredDetails?.rrPackageText ?? fallbackHrv.packageText,
                            nextAction: nextAction,
                            headline: headline,
                            sessionsCount: savedAggregate.sessionsCount,
                            baselineSamples: savedAggregate.baselineSamples,
                            backupValue: deferredDetails?.backupValue ?? "Preparing",
                            backupDetail: deferredDetails?.backupDetail ?? "saved history",
                            restingHeartRate: presentationRestingHeartRate ?? rest,
                            restingHeartRateText: restText,
                            strainNarrative: String(format: "TRIMP %.1f after active-checkpoint reconciliation (saved %.1f, saved active %.1f, live %.1f, logged lifting %.1f)", totalTRIMP, savedAggregate.savedTodayTRIMP, savedAggregate.savedActiveSessionTRIMP, liveTRIMP, savedAggregate.savedTodayMuscularTRIMP),
                            loadRatioText: load.ratioText,
                            loadTargetText: load.targetBandText,
                            loadConfidence: load.confidence,
                            loadReadinessText: load.readinessText,
                            loadACWRSignalText: load.acwrSignalText,
                            loadMonotonyText: load.monotonyText,
                            loadMonotonySignalText: load.monotonySignalText,
                            loadACWRDetailText: load.acwrDetailText,
                            loadMonotonyDetailText: load.monotonyDetailText,
                            loadSignalSummaryText: load.signalSummaryText,
                            loadNarrative: load.detail,
                            hrZoneMinutes: store.todayHRZoneMinutesSnapshot,
                            // §13.4: display split only — zero under the
                            // date-honest identity override (no split claim).
                            dayTRIMP: dayResolution.strainOverride == nil ? totalTRIMP : 0,
                            muscularTRIMP: dayResolution.strainOverride == nil
                                ? savedAggregate.savedTodayMuscularTRIMP : 0)
    }

    #if DEBUG
    static func debugFixtureProvisionalRecoveryHeroSnapshot(arguments: [String]) -> HeroSnapshot? {
        guard let fixtureIndex = arguments.firstIndex(of: "--atria-ui-fixture") else { return nil }
        let valueIndex = arguments.index(after: fixtureIndex)
        guard arguments.indices.contains(valueIndex),
              arguments[valueIndex] == "pending-sleep-provisional-recovery" else {
            return nil
        }

        let now = Date()
        var baseline = PersonalBaseline()
        for index in 0..<PersonalBaseline.trustedMinimumSamples {
            let observedAt = now.addingTimeInterval(-Double(index + 1) * 86_400)
            baseline.learn(fromResting: 60 + (index % 3),
                           hrv: 64 + (index % 5),
                           at: observedAt,
                           overnight: true)
        }

        let end = Calendar.current.date(bySettingHour: 7, minute: 24, second: 0, of: now) ?? now
        let start = end.addingTimeInterval(-8 * 60 * 60)
        let night = SleepHistorySnapshot.Night(id: "debug-ui-fixture-provisional-recovery-night",
                                               day: Calendar.current.startOfDay(for: end),
                                               start: start,
                                               end: end,
                                               duration: end.timeIntervalSince(start),
                                               restingHR: 59,
                                               hrv: 70,
                                               respiratoryRate: 14.8,
                                               sleepEfficiency: 0.92,
                                               confidence: "debug_fixture_pending_sleep",
                                               source: "sleep_window",
                                               confirmed: false,
                                               stageSegments: [])
        let recovery = SessionStore.presentationRecoveryEstimate(
            authoritative: Metrics.RecoveryEstimate(
                percent: nil,
                confidence: .learning,
                usesHRV: false,
                detail: "learning: need saved sleep",
                contributors: []
            ),
            hasConfirmedMainSleep: false,
            hasFrozenRecovery: false,
            pendingSleepReview: night,
            baseline: baseline,
            respiratoryBaseline: nil,
            now: end.addingTimeInterval(60),
            physiologicalCycle: AtriaPhysiologicalCycle(
                start: Calendar.current.date(bySettingHour: 6, minute: 0, second: 0, of: end)
                    ?? Calendar.current.startOfDay(for: end),
                boundaryKind: .initialFallback,
                anchorSleepID: nil,
                expectedInterval: AtriaPhysiologicalCycle.defaultInterval
            ),
            calendar: .current
        )
        let strain = 4.2
        let guidance = Coach.guide(recovery: recovery, strain: strain, load: .learning)
        // §13.3 (2026-08-14): the fixture surfaces the production whiteboard
        // sentence built from the same trusted fixture baseline and the
        // night's measured HRV/RHR; the kernel line above stays for its
        // pinned target math.
        let displayGuidance = AtriaWhiteboardCoachSentence.rewrite(
            kernel: guidance,
            context: .init(hrvMS: night.hrv,
                           restingHR: night.restingHR,
                           baseline: AtriaBaselineTargetSnapshot(baseline),
                           yesterdayTRIMP: nil,
                           yesterdayStrainDisplay: nil))
        return HeroSnapshot(recoveryEstimate: recovery,
                            recoveryIsProvisional: !night.confirmed,
                            recoveryIsFromPreviousSleep: false,
                            identity: nil,
                            priorCycleDisclosure: nil,
                            strain: strain,
                            strainConfidence: "local",
                            // Night-scoped snapshot: day wear coverage is not
                            // evaluated here, and nil means "not measured"
                            // rather than "zero coverage".
                            dayWearCoverageFraction: nil,
                            guidance: displayGuidance,
                            hrvValue: night.hrvText,
                            hrvDetail: "personal baseline",
                            hrvNarrative: "Debug fixture: pending sleep uses the normal recovery model before confirmation.",
                            stressLevel: .calm,
                            stressValue: "0.0 / 3",
                            stressDetail: "personal baseline",
                            stressNarrative: "Debug fixture stress is neutral while provisional recovery is shown.",
                            stressEvidenceMode: .physiologicalStress,
                            stressMetricTitle: "Physiological stress",
                            rrPackageText: "Personal",
                            nextAction: "Confirming sleep will reconcile this recovery without a modal.",
                            headline: "Provisional recovery is ready.",
                            sessionsCount: PersonalBaseline.trustedMinimumSamples,
                            baselineSamples: PersonalBaseline.trustedMinimumSamples,
                            backupValue: "Ready",
                            backupDetail: "debug fixture",
                            restingHeartRate: night.restingHR ?? 0,
                            restingHeartRateText: night.restingHRText,
                            strainNarrative: "Debug fixture strain is fixed so the recovery ring proof is stable.",
                            loadRatioText: "Learning",
                            loadTargetText: "Learning",
                            loadConfidence: "learning",
                            loadReadinessText: "Learning",
                            loadACWRSignalText: "Learning",
                            loadMonotonyText: "Learning",
                            loadMonotonySignalText: "Learning",
                            loadACWRDetailText: TrainingLoadSummary.learning.acwrDetailText,
                            loadMonotonyDetailText: TrainingLoadSummary.learning.monotonyDetailText,
                            loadSignalSummaryText: "Learning",
                            loadNarrative: "Training load appears after local strain history builds.",
                            hrZoneMinutes: .empty)
    }
    #endif

    private struct FallbackHeroHRVState {
        let value: String
        let detail: String
        let narrative: String
        let packageText: String
    }

    private static func fallbackHeroHRVState(ble: AtriaBLEManager,
                                             store: SessionStore) -> FallbackHeroHRVState {
        let now = Date()
        let validatedSource = store.latestReferenceValidatedHRVForDisplay
        let localSource = store.latestLocalRMSSDForDisplay
        let projection = AtriaCurrentCycleHRVDisplayProjection.resolve(
            validated: validatedSource,
            live: ble.hrvSnapshot,
            local: localSource,
            now: now
        )

        // Deterministic no-value token, matching every other metric value.
        let value = projection.map { String($0.value) }
            ?? AtriaCompactMetricPresentation.noValue

        let detail: String
        if let projection {
            let tier = projection.source == .referenceValidated
                ? "validated" : "personal"
            detail = "\(tier) · \(hrvMeasurementAgeText(projection.measuredAt, now: now))"
        } else {
            detail = hrvSettlingText(quality: ble.hrvQuality,
                                     liveHeartRate: liveHeartRate(ble: ble))
        }

        let narrative: String
        if let projection {
            let label = projection.source == .referenceValidated
                ? "Checked" : "Personal"
            narrative = "\(label) HRV was measured \(hrvMeasurementAgeText(projection.measuredAt, now: now))."
        } else {
            narrative = "Atria is waiting for a fresh beat-to-beat HRV window."
        }

        let packageText: String
        if projection?.source == .referenceValidated {
            packageText = "Validated"
        } else if projection?.source == .liveRRWindow {
            packageText = "Unverified"
        } else if projection?.source == .localDisplay {
            packageText = "Personal"
        } else {
            packageText = "Learning"
        }

        return FallbackHeroHRVState(value: value,
                                    detail: detail,
                                    narrative: narrative,
                                    packageText: packageText)
    }

    private static func hrvMeasurementAgeText(_ measuredAt: Date, now: Date) -> String {
        let age = max(0, now.timeIntervalSince(measuredAt))
        if age < 2 * 60 { return "just now" }
        if age < 60 * 60 { return "\(max(2, Int(age / 60)))m ago" }
        return "\(max(1, Int(age / 3_600)))h ago"
    }

    private static func hrvSettlingText(quality: String, liveHeartRate: Int) -> String {
        guard liveHeartRate > 0 else { return quality }
        let normalized = quality.lowercased()
        if normalized.contains("stable contact")
            || normalized.contains("poor contact")
            || normalized.contains("poor_contact") {
            return "HRV settling"
        }
        return quality
    }

    private static func defaultHeroHeadline(status: AtriaBLEManager.Status) -> String {
        if status == .connected {
            return "Strap is connected."
        }
        return "A lighter dashboard that gets to your signal faster."
    }

    private static func defaultHeroNextAction(status: AtriaBLEManager.Status) -> String {
        if status != .connected {
            return "Keep the phone near the strap until Atria reconnects."
        }
        return "Settling saved insights in the background."
    }

    private static func makeDisconnectedHeroSnapshot(live: CoreLiveState,
                                                     savedAggregate: SavedAggregate,
                                                     fallbackHrv: FallbackHeroHRVState,
                                                     headline: String,
                                                     nextAction: String,
                                                     rest: Int,
                                                     restText: String) -> HeroSnapshot {
        let guidance: Coach.Guidance
        switch live.status {
        case .scanning:
            guidance = Coach.Guidance(headline: "Looking for your strap",
                                      detail: "Your dashboard stays responsive while Atria searches for your strap nearby.",
                                      color: .orange,
                                      target: nil,
                                      state: "learning",
                                      reason: "disconnected_scanning_fast_path")
        case .connecting:
            guidance = Coach.Guidance(headline: "Connecting to your strap",
                                      detail: "Atria is finishing the connection. Your live readings appear right after.",
                                      color: .orange,
                                      target: nil,
                                      state: "learning",
                                      reason: "disconnected_connecting_fast_path")
        case .poweredOff:
            guidance = Coach.Guidance(headline: "Turn Bluetooth on to continue",
                                      detail: "Your data is safe. Atria reconnects automatically once Bluetooth is back on.",
                                      color: .orange,
                                      target: nil,
                                      state: "learning",
                                      reason: "disconnected_powered_off_fast_path")
        case .disconnected:
            guidance = Coach.Guidance(headline: "Ready to reconnect",
                                      detail: "Your saved data is here right away while Atria keeps trying to reconnect in the background.",
                                      color: .blue,
                                      target: nil,
                                      state: "learning",
                                      reason: "disconnected_idle_fast_path")
        case .connected:
            guidance = Coach.Guidance(headline: "Connected and reading live",
                                      detail: "Your live scores fill in moments after the screen is ready.",
                                      color: .green,
                                      target: nil,
                                      state: "learning",
                                      reason: "connected_fast_path_placeholder")
        }

        let hasSavedBackup = savedAggregate.sessionsCount > 0

        return HeroSnapshot(recoveryEstimate: Metrics.RecoveryEstimate(percent: nil,
                                                                       confidence: .learning,
                                                                       usesHRV: false,
                                                                       detail: "learning: reconnecting",
                                                                       contributors: []),
                            recoveryIsProvisional: false,
                            recoveryIsFromPreviousSleep: false,
                            identity: nil,
                            priorCycleDisclosure: nil,
                            strain: 0,
                            strainConfidence: "standby",
                            // Standby/reconnecting snapshot: nothing has been
                            // measured yet, so coverage is unknown rather than 0.
                            dayWearCoverageFraction: nil,
                            guidance: guidance,
                            hrvValue: fallbackHrv.value,
                            hrvDetail: fallbackHrv.detail,
                            hrvNarrative: fallbackHrv.narrative,
                            stressLevel: nil,
                            // Standby/reconnecting snapshot: deterministic
                            // no-value token like every other metric value.
                            stressValue: AtriaCompactMetricPresentation.noValue,
                            stressDetail: "Five-minute cardiac window",
                            stressNarrative: "Physiological stress appears after the strap reconnects and a complete five-minute cardiac window is ready.",
                            stressEvidenceMode: nil,
                            stressMetricTitle: "Physiological stress",
                            rrPackageText: fallbackHrv.packageText,
                            nextAction: nextAction,
                            headline: headline,
                            sessionsCount: savedAggregate.sessionsCount,
                            baselineSamples: savedAggregate.baselineSamples,
                            backupValue: hasSavedBackup ? "Ready" : "Learning",
                            backupDetail: hasSavedBackup ? "saved on device" : "no backup yet",
                            restingHeartRate: rest,
                            restingHeartRateText: restText,
                            strainNarrative: "Live strain resumes after the strap reconnects.",
                            loadRatioText: "Learning",
                            loadTargetText: "Learning",
                            loadConfidence: "learning",
                            loadReadinessText: "Learning",
                            loadACWRSignalText: "Learning",
                            loadMonotonyText: "Learning",
                            loadMonotonySignalText: "Learning",
                            loadACWRDetailText: TrainingLoadSummary.learning.acwrDetailText,
                            loadMonotonyDetailText: TrainingLoadSummary.learning.monotonyDetailText,
                            loadSignalSummaryText: "Learning",
                            loadNarrative: "Training load appears after local strain history builds.",
                            hrZoneMinutes: .empty)
    }

    private static func makeSnapshot(store: SessionStore,
                                     hero: HeroSnapshot,
                                     deferredDetails: DeferredDetails?) -> Snapshot {
        let defaultReferenceText = baselineMaturityText(sampleCount: hero.baselineSamples)
        // Before diagnostics finish, fall back to the same real-data cold-start
        // seed used at launch instead of hardcoded "Preparing" strings, so the
        // tiles keep showing saved numbers rather than reverting to placeholders.
        let coldStart = deferredDetails == nil ? Self.makeColdStartSnapshot(store: store) : nil

        return Snapshot(referenceText: deferredDetails?.referenceText ?? defaultReferenceText,
                        sleepValue: deferredDetails?.sleepValue ?? coldStart?.sleepValue ?? "Preparing",
                        sleepDetail: deferredDetails?.sleepDetail ?? coldStart?.sleepDetail ?? "saved history",
                        workoutText: deferredDetails?.workoutText ?? coldStart?.workoutText ?? "Preparing",
                        loggingText: deferredDetails?.loggingText ?? coldStart?.loggingText ?? "settling",
                        trendCoverageText: deferredDetails?.trendCoverageText ?? coldStart?.trendCoverageText ?? "--",
                        trendConfidence: deferredDetails?.trendConfidence ?? coldStart?.trendConfidence ?? "learning",
                        trendDetail: deferredDetails?.trendDetail ?? coldStart?.trendDetail ?? "Saved trends are preparing.",
                        confirmedWorkouts: deferredDetails?.confirmedWorkouts ?? store.confirmedWorkouts.count,
                        confirmedSleeps: deferredDetails?.confirmedSleeps ?? store.confirmedSleeps.count)
    }

    private static func makeHomeStatsState(hero: HeroSnapshot) -> HomeStatsState {
        HomeStatsState(rrPackageText: hero.rrPackageText,
                       hrvDetail: hero.hrvDetail,
                       nextAction: hero.nextAction,
                       sessionsCount: hero.sessionsCount,
                       baselineSamples: hero.baselineSamples,
                       backupValue: hero.backupValue,
                       backupDetail: hero.backupDetail,
                       restingHeartRate: hero.restingHeartRate,
                       restingHeartRateText: hero.restingHeartRateText)
    }

    private static func makeProfileMetricsState(store: SessionStore,
                                                liveSessionDerived: LiveSessionDerived) -> ProfileMetricsState {
        let vo2 = store.vo2MaxEstimateSummary(rest: liveSessionDerived.rest,
                                              maxHR: store.profile.maxHR)
        return ProfileMetricsState(vo2MaxEstimate: vo2,
                                   biologicalAgeSummary: store.biologicalAgeSummary(vo2MaxEstimate: vo2))
    }

    private static func profileMetricsKey(store: SessionStore,
                                          liveSessionDerived: LiveSessionDerived) -> ProfileMetricsKey {
        ProfileMetricsKey(profileAge: store.profile.age,
                          biologicalSex: store.profile.biologicalSex,
                          biologicalAgeWeekStart: SessionStore.biologicalAgeCacheWeekStart(for: Date()),
                          biologicalAgeSummaryRevision: store.biologicalAgeSummaryRevision,
                          sessionsLoaded: store.hasLoadedSavedSessions,
                          rest: liveSessionDerived.rest,
                          maxHR: store.profile.maxHR,
                          maxHRSource: store.profile.maxHRSource,
                          restingBaselineSamples: store.baseline.freshRestingSampleCount(),
                          hrvBaselineSamples: store.baseline.freshHRVSampleCount(),
                          restingTrend14: store.restingTrend14,
                          dailyMetricRevision: store.dailyMetricHistoryRevision,
                          sleepRevision: store.sleepHistorySnapshotRevision,
                          trainingLoad: store.trainingLoadSummarySnapshot)
    }

    private static func makeSavedAggregate(ble: AtriaBLEManager,
                                           store: SessionStore,
                                           restingContext: RestingMetricContext) -> SavedAggregate {
        let rest = restingContext.resolved
        let maxHR = store.profile.maxHR
        let aggregate = store.homeSavedAggregate(rest: rest,
                                                 maxHR: maxHR,
                                                 activeSessionID: ble.currentLiveSessionID)
        let cycleBoundaryIsUnconfirmedFallback = AtriaPhysiologicalCycle.current(
            now: Date(),
            confirmedSleeps: store.confirmedSleeps,
            calendar: .current
        ).boundaryKind != .mainSleep
        return SavedAggregate(cycleStart: aggregate.day,
                              cycleBoundaryIsUnconfirmedFallback:
                                cycleBoundaryIsUnconfirmedFallback,
                              // Cold-start seed: canonical window only; the full
                              // off-MainActor refresh applies the continuous
                              // fold. Seeding with cycleStart keeps it honest.
                              strainAccumulationStart: aggregate.day,
                              restingContext: restingContext,
                              savedTodayTRIMP: aggregate.savedTodayTRIMP,
                              savedActiveSessionTRIMP: aggregate.savedActiveSessionTRIMP,
                              savedTodayMuscularTRIMP: aggregate.savedTodayMuscularTRIMP,
                              savedTodayActiveCalories: aggregate.savedTodayActiveCalories,
                              savedActiveSessionActiveCalories: aggregate.savedActiveSessionActiveCalories,
                              savedTodayStrapSteps: aggregate.savedTodayStrapSteps,
                              savedActiveSessionStrapSteps: aggregate.savedActiveSessionStrapSteps,
                              savedActiveSessionTotalStrapSteps: aggregate.savedActiveSessionTotalStrapSteps,
                              hasSavedToday: aggregate.hasSavedToday,
                              sessionsCount: aggregate.sessionsCount,
                              baselineSamples: store.baseline.freshHRVSampleCount(),
                              confirmedWorkouts: store.confirmedWorkouts.count,
                              confirmedSleeps: store.confirmedSleeps.count,
                              savedTodayObservedSeconds: observedHeartRateUnionSeconds(
                                  sessions: store.sessions,
                                  windowStart: aggregate.day,
                                  windowEnd: Date()
                              ))
    }

    private static func makeDeferredDetails(ble: AtriaBLEManager,
                                            store: SessionStore,
                                            recoveryIsLearning: Bool) -> DeferredDetails {
        let diagnostics = store.homeDashboardDiagnostics()
        let now = Date()
        let displayHRV = AtriaCurrentCycleHRVDisplayProjection.resolve(
            validated: store.latestReferenceValidatedHRVForDisplay,
            live: ble.hrvSnapshot,
            local: store.latestLocalRMSSDForDisplay,
            now: now
        )
        let rrPackage = diagnostics.rrPackage
        let sleep = diagnostics.sleep
        let workout = diagnostics.workout
        let collection = diagnostics.collection
        let backup = diagnostics.backup
        let trend90 = diagnostics.trend90

        let hrvValue: String
        if let displayHRV {
            hrvValue = "\(displayHRV.value)"
        } else {
            hrvValue = "Learning"
        }

        let hrvDetail: String
        if displayHRV?.source == .referenceValidated {
            hrvDetail = "validated"
        } else if displayHRV != nil {
            hrvDetail = "personal baseline"
        } else {
            hrvDetail = hrvSettlingText(quality: ble.hrvQuality,
                                        liveHeartRate: liveHeartRate(ble: ble))
        }

        let hrvNarrative: String
        if displayHRV?.source == .referenceValidated {
            hrvNarrative = "Checked HRV is ready."
        } else if displayHRV != nil {
            hrvNarrative = "Beat-to-beat data is ready as personal-baseline HRV."
        } else {
            hrvNarrative = hrvSettlingText(quality: ble.hrvQuality,
                                           liveHeartRate: liveHeartRate(ble: ble))
        }

        let sleepValue: String
        let sleepDetail: String
        if sleep.ready {
            sleepValue = "Ready"
            sleepDetail = sleep.confidence
        } else if sleep.fallbackAvailable {
            sleepValue = "Maybe"
            sleepDetail = "\(Int((sleep.fallbackDuration / 60).rounded()))m saved"
        } else if sleep.candidates > 0 {
            sleepValue = "\(sleep.candidates)"
            sleepDetail = sleep.blocker.replacingOccurrences(of: "_", with: " ")
        } else {
            sleepValue = "Learning"
            sleepDetail = "no window"
        }

        let workoutText: String
        if workout.ready {
            workoutText = "Ready"
        } else if workout.strengthCandidate {
            workoutText = "Strength-like"
        } else if workout.nearMiss {
            workoutText = "Near miss"
        } else if workout.source != "none" {
            workoutText = "Peak \(workout.peakHR)bpm"
        } else {
            workoutText = "Learning"
        }

        let loggingText: String
        if collection.ready {
            let sourceText = collection.source == "saved_session_tail" ? "saved" : "live"
            loggingText = collection.samples == 1 ? "\(sourceText) 1 sample" : "\(sourceText) \(collection.samples) samples"
        } else {
            loggingText = collection.blocker.replacingOccurrences(of: "_", with: " ")
        }

        let backupValue: String
        let backupDetail: String
        if backup.current {
            backupValue = "Ready"
            backupDetail = backup.sessions == 1 ? "1 session" : "\(backup.sessions) sessions"
        } else if backup.available {
            backupValue = "Stale"
            backupDetail = backup.reason.replacingOccurrences(of: "_", with: " ")
        } else {
            backupValue = "Missing"
            backupDetail = "not saved"
        }

        let rrPackageText: String
        if displayHRV?.source == .referenceValidated {
            rrPackageText = "Validated"
        } else if rrPackage.ready {
            rrPackageText = "Ready"
        } else if rrPackage.rrSamples > 0 {
            rrPackageText = "\(rrPackage.rrSamples) beats"
        } else {
            rrPackageText = "Learning"
        }

        let referenceText = baselineMaturityText(sampleCount: store.baseline.freshHRVSampleCount())

        let headline: String
        if ble.status == .connected {
            headline = "Live connection is active."
        } else if rrPackage.ready {
            headline = "Saved beat-to-beat data is ready while the strap reconnects."
        } else {
            headline = "A lighter dashboard that gets to your signal faster."
        }

        let nextAction: String
        if ble.status != .connected {
            nextAction = "Keep the phone near the strap until Atria reconnects."
        } else if recoveryIsLearning && rrPackage.ready {
            nextAction = "Keep wearing while Atria finishes your personal baseline."
        } else if !collection.ready {
            nextAction = "Keep Atria open a little longer while backup settles."
        } else {
            nextAction = "Keep wearing; local backup is active."
        }

        return DeferredDetails(hrvValue: hrvValue,
                               hrvDetail: hrvDetail,
                               hrvNarrative: hrvNarrative,
                               rrPackageText: rrPackageText,
                               referenceText: referenceText,
                               sleepValue: sleepValue,
                               sleepDetail: sleepDetail,
                               workoutText: workoutText,
                               loggingText: loggingText,
                               backupValue: backupValue,
                               backupDetail: backupDetail,
                               trendCoverageText: "\(trend90.coveragePercent)%",
                               trendConfidence: trend90.confidence,
                               trendDetail: trend90.detail,
                               nextAction: nextAction,
                               headline: headline,
                               confirmedWorkouts: store.confirmedWorkouts.count,
                               confirmedSleeps: store.confirmedSleeps.count)
    }

    private static func baselineMaturityText(sampleCount: Int) -> String {
        sampleCount >= PersonalBaseline.trustedMinimumSamples ? "Ready" : "\(max(0, sampleCount))/\(PersonalBaseline.trustedMinimumSamples)"
    }

    private static func makeLiveSessionDerived(samples: [HRSample],
                                               rest: Int,
                                               maxHR: Int,
                                               profile: AthleteProfile,
                                               cycleStart: Date) -> LiveSessionDerived {
        let cycleSamples = samples.filter { $0.t >= cycleStart }
        return LiveSessionDerived(sampleCount: samples.count,
                           lastTimestamp: samples.last?.t,
                           cycleStart: cycleStart,
                           rest: rest,
                           maxHR: maxHR,
                           biologicalSex: profile.biologicalSex,
                           trimp: liveSessionDailyLoadTRIMP(
                                cycleSamples,
                                rest: rest,
                                max: maxHR,
                                sex: profile.biologicalSex
                           ),
                           activeCalories: Metrics.dayCalories(cycleSamples.map {
                               Metrics.HeartRateEnergySample(t: $0.t, bpm: $0.bpm)
                           }, rest: rest, profile: profile))
    }

    private static func nextLiveSessionDerived(previous: LiveSessionDerived,
                                               samples: [HRSample],
                                               rest: Int,
                                               maxHR: Int,
                                               profile: AthleteProfile,
                                               cycleStart: Date) -> LiveSessionDerived {
        guard previous.rest == rest,
              previous.maxHR == maxHR,
              previous.biologicalSex == profile.biologicalSex,
              previous.cycleStart == cycleStart,
              (previous.activeCalories != nil) == profile.hasEnergyProfile,
              samples.count >= previous.sampleCount,
              previous.sampleCount > 0,
              previous.sampleCount <= samples.count,
              previous.lastTimestamp == samples[previous.sampleCount - 1].t else {
            return makeLiveSessionDerived(samples: samples,
                                          rest: rest,
                                          maxHR: maxHR,
                                          profile: profile,
                                          cycleStart: cycleStart)
        }

        guard samples.count > previous.sampleCount else {
            return LiveSessionDerived(sampleCount: samples.count,
                                      lastTimestamp: samples.last?.t,
                                      cycleStart: cycleStart,
                                      rest: rest,
                                      maxHR: maxHR,
                                      biologicalSex: profile.biologicalSex,
                                      trimp: previous.trimp,
                                      activeCalories: previous.activeCalories)
        }

        guard maxHR > rest else {
            return LiveSessionDerived(sampleCount: samples.count,
                                      lastTimestamp: samples.last?.t,
                                      cycleStart: cycleStart,
                                      rest: rest,
                                      maxHR: maxHR,
                                      biologicalSex: profile.biologicalSex,
                                      trimp: 0,
                                      activeCalories: nil)
        }

        let strainParameters = AtriaAnalytics.Strain.banisterParameters(for: profile.biologicalSex)
        let strainConfiguration = AtriaStrainLoadModel.Configuration(
            restingBPM: Double(rest),
            maximumBPM: Double(maxHR),
            intensityMultiplier: strainParameters.multiplier,
            intensityCoefficient: strainParameters.coefficient,
            mode: .continuousDay,
            maximumGap: AtriaAnalytics.Strain.maximumLoadEvidenceGap
        )
        var total = previous.trimp
        var activeCalories = previous.activeCalories ?? 0
        for index in previous.sampleCount..<samples.count {
            // Match the canonical SavedSession/Metrics TRIMP boundary. A short
            // telemetry gap is integrated from the mean of its two real HR
            // endpoints; a longer gap remains unknown and contributes nothing.
            guard samples[index - 1].t >= cycleStart,
                  samples[index].t >= cycleStart else { continue }
            let evaluation = AtriaStrainLoadModel.evaluateInterval(
                from: AtriaStrainLoadModel.Sample(
                    timestamp: samples[index - 1].t.timeIntervalSinceReferenceDate,
                    bpm: Double(samples[index - 1].bpm)
                ),
                to: AtriaStrainLoadModel.Sample(
                    timestamp: samples[index].t.timeIntervalSinceReferenceDate,
                    bpm: Double(samples[index].bpm)
                ),
                configuration: strainConfiguration
            )
            guard evaluation.isAccepted else { continue }
            total += evaluation.load
            if profile.hasEnergyProfile {
                activeCalories += Metrics.dayCalories([
                    Metrics.HeartRateEnergySample(t: samples[index - 1].t, bpm: samples[index - 1].bpm),
                    Metrics.HeartRateEnergySample(t: samples[index].t, bpm: samples[index].bpm),
                ], rest: rest, profile: profile) ?? 0
            }
        }
        return LiveSessionDerived(sampleCount: samples.count,
                                  lastTimestamp: samples.last?.t,
                                  cycleStart: cycleStart,
                                  rest: rest,
                                  maxHR: maxHR,
                                  biologicalSex: profile.biologicalSex,
                                  trimp: total,
                                  activeCalories: profile.hasEnergyProfile ? activeCalories : nil)
    }

    private static func liveSessionDailyLoadTRIMP(
        _ samples: [HRSample],
        rest: Int,
        max: Int,
        sex: AthleteProfile.BiologicalSex
    ) -> Double {
        guard samples.count > 1, max > rest else { return 0 }
        let origin = samples[0].t
        return Metrics.dailyLoadTRIMP(
            samples.map { (t: $0.t.timeIntervalSince(origin), bpm: $0.bpm) },
            rest: rest,
            max: max,
            sex: sex
        )
    }
}

private struct AtriaToolbarIcon: View, Equatable {
    let symbol: String

    static func == (lhs: AtriaToolbarIcon, rhs: AtriaToolbarIcon) -> Bool {
        lhs.symbol == rhs.symbol
    }

    var body: some View {
        Image(systemName: symbol)
            .font(.footnote.weight(.semibold))
            .imageScale(.small)
            .foregroundStyle(.primary)
    }
}

private struct AtriaHeaderActionButtonStyle: ButtonStyle {
    private static let size: CGFloat = AtriaHeaderControlMetrics.height

    func makeBody(configuration: Configuration) -> some View {
        AtriaGlassIconButtonStyle(tint: .secondary, size: Self.size)
            .makeBody(configuration: configuration)
    }
}

enum AtriaHomeChromeLayout {
    /// The dashboard is intentionally full-bleed. Its header therefore keeps a
    /// small, explicit portrait lane clear of the Dynamic Island instead of
    /// relying on a nested scroll-view's safe-area propagation.
    static func topChromeClearance(verticalSizeClass: UserInterfaceSizeClass?) -> CGFloat {
        // 26 -> 8 (owner 2026-08-28 strict pass): the safe-area inset already
        // clears the status bar; the extra clearance was dead air above the
        // status chip.
        verticalSizeClass == .regular ? 8 : 0
    }

    static func showsHomeStatusChip(workoutIsActive: Bool) -> Bool {
        !workoutIsActive
    }

    static func stacksStatusAndActions(dynamicTypeSize: DynamicTypeSize,
                                       workoutIsActive: Bool) -> Bool {
        dynamicTypeSize.isAccessibilitySize && showsHomeStatusChip(workoutIsActive: workoutIsActive)
    }
}

private struct AtriaHomeTopChrome: View {
    let statusStore: AtriaHomeModel.StatusStore
    let coreLiveStore: AtriaHomeModel.CoreLiveStore
    let pulseLiveStore: AtriaHomeModel.PulseLiveStore
    let prefersLiveActivityStatus: Bool
    let onShowSettings: () -> Void
    let onShowStrap: () -> Void
    let activityStartIsAvailable: Bool
    let onStartActivity: () -> Void
    let onAddActivity: () -> Void
    let onTapStatusWhenNotConnected: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            if AtriaHomeChromeLayout.stacksStatusAndActions(
                dynamicTypeSize: dynamicTypeSize,
                workoutIsActive: prefersLiveActivityStatus
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    statusChip
                    actionButtons
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            } else {
                HStack(alignment: .center, spacing: 10) {
                    if AtriaHomeChromeLayout.showsHomeStatusChip(
                        workoutIsActive: prefersLiveActivityStatus
                    ) {
                        statusChip
                    }
                    Spacer(minLength: 8)
                    actionButtons
                }
            }
        }
        .frame(maxWidth: .infinity,
               minHeight: AtriaHeaderControlMetrics.height,
               alignment: .center)
        .padding(.top, AtriaHomeChromeLayout.topChromeClearance(verticalSizeClass: verticalSizeClass))
        // No .clipped() here: the status chip already draws its own bounded
        // capsule background, so nothing overflows that needs clipping — and
        // clipping this HStack at an exact 44pt height cropped the header
        // buttons' Liquid Glass press/glow effect (AtriaGlassIconButtonStyle),
        // which paints slightly outside its own frame when pressed.
    }

    private var statusChip: some View {
        AtriaTopStatusChipHost(statusStore: statusStore,
                               coreLiveStore: coreLiveStore,
                               pulseLiveStore: pulseLiveStore,
                               onTapWhenConnected: onShowStrap,
                               onTapWhenNotConnected: onTapStatusWhenNotConnected)
    }

    private var actionButtons: some View {
        HStack(spacing: 10) {
            // One native menu replaces the ambiguous chat bubble. The trigger
            // remains the only new glass surface; both destinations reuse their
            // existing sheets and keep the Today page's in-content actions.
            Menu {
                Button(action: onStartActivity) {
                    Label("Start workout", systemImage: "figure.run")
                }
                .disabled(!activityStartIsAvailable)

                Button(action: onAddActivity) {
                    Label("Add workout", systemImage: "calendar.badge.plus")
                }
            } label: {
                AtriaToolbarIcon(symbol: "plus")
            }
            .menuOrder(.fixed)
            .menuIndicator(.hidden)
            .buttonStyle(AtriaHeaderActionButtonStyle())
            .accessibilityLabel("Activity shortcuts")
            .accessibilityHint("Start a live activity or add a past activity.")

            // Settings remains reachable while the strap reconnects and while
            // the workout's compact metrics move to ActivityKit surfaces.
            Button(action: onShowSettings) {
                AtriaToolbarIcon(symbol: "gearshape")
            }
            .buttonStyle(AtriaHeaderActionButtonStyle())
            .accessibilityLabel("Settings")
        }
    }
}

private enum AtriaHeaderControlMetrics {
    static let height: CGFloat = 44
    static let statusMinWidth: CGFloat = 96
    static let iconSpacing: CGFloat = 8
}

struct AtriaTopStatusPresentation: Equatable {
    enum Tone: Equatable {
        case green
        case yellow
        case orange
        case cyan
        case red
        case secondary
    }

    let label: String
    let symbol: String
    let accessorySymbol: String?
    let accessibilityLabel: String
    let tone: Tone
    let isConnected: Bool

    init(label: String,
         symbol: String,
         tone: Tone,
         isConnected: Bool,
         accessorySymbol: String? = nil,
         accessibilityLabel: String? = nil) {
        self.label = label
        self.symbol = symbol
        self.accessorySymbol = accessorySymbol
        self.accessibilityLabel = accessibilityLabel ?? label
        self.tone = tone
        self.isConnected = isConnected
    }
}

struct AtriaTopStatusProjectionInput: Equatable {
    let status: AtriaBLEManager.Status
    let bluetoothPermissionDenied: Bool
    let isBluetoothReady: Bool
    let hasPulseSignal: Bool
    let hasRecentHeartRateSample: Bool
    let lastReadingAt: Date?
    let displayDeviceName: String
    let strapStreamState: AtriaBLEManager.StrapStreamState
    let strapStreamConnectionLabel: String
    let strapStreamConnectionSymbol: String
    let lastScanRequestedAt: Date?
    let lastScanMatchAt: Date?
    let pendingKnownReconnectStartedAt: Date?
    let rangeLossBackfillPending: Bool
    let hasEverConnected: Bool
    let battery: AtriaHeaderBatterySnapshot
}

/// One value-semantic battery observation feeds the entire top-left control.
/// Keeping percentage, power state and verification time together prevents a
/// render from pairing a new percentage with an older charging/timestamp state.
struct AtriaHeaderBatterySnapshot: Equatable {
    enum PowerState: Equatable {
        case none
        case unknown
        case charging
        case full
    }

    let level: Int?
    let powerState: PowerState
    let isRecentBaseline: Bool
    let verifiedAt: Date?
    /// Independent from the percentage timestamp: a charger event may arrive
    /// without a new level packet, and neither event may renew the other.
    let chargeVerifiedAt: Date?

    init(level rawLevel: Int,
         showsPowered: Bool,
         chargeStatus: AtriaBLEManager.BatteryChargeStatus,
         isRecentBaseline: Bool,
         verifiedAt: Date?,
         chargeVerifiedAt: Date? = nil) {
        guard (0...100).contains(rawLevel) else {
            level = nil
            powerState = .none
            self.isRecentBaseline = false
            self.verifiedAt = nil
            self.chargeVerifiedAt = nil
            return
        }

        level = rawLevel
        switch chargeStatus {
        case .charging where showsPowered:
            powerState = .charging
        case .full:
            powerState = .full
        case .notCharging:
            powerState = .none
        case .levelOnly, .charging:
            // A status/flag mismatch is not charger evidence. Preserve unknown
            // separately from an explicit not-charging event.
            powerState = .unknown
        }
        self.isRecentBaseline = isRecentBaseline
        self.verifiedAt = verifiedAt
        self.chargeVerifiedAt = powerState == .charging ? chargeVerifiedAt : nil
    }

    func powerState(at now: Date) -> PowerState {
        guard powerState == .charging else { return powerState }
        guard let chargeVerifiedAt else { return .unknown }
        let age = now.timeIntervalSince(chargeVerifiedAt)
        return age >= 0 && age <= AtriaHomeModel.freshChargerEvidenceInterval
            ? .charging : .unknown
    }
}

struct AtriaTopStatusPulseTrigger: Equatable {
    let hasPulseSignal: Bool
}

enum AtriaTopStatusProjection {
    static let linkingWindow: TimeInterval = 8
    static let freshPulseWindow: TimeInterval = 15
    static let liveRecoveryGraceInterval: TimeInterval = 45

    static func presentation(input: AtriaTopStatusProjectionInput,
                             now: Date) -> AtriaTopStatusPresentation {
        let hasPulseSignal = input.hasPulseSignal || input.hasRecentHeartRateSample
        let recovering = isRecovering(input: input, now: now)
        let reconnectAge = input.pendingKnownReconnectStartedAt.map { now.timeIntervalSince($0) }
        let activelyLinking = reconnectAge.map { $0 >= 0 && $0 <= linkingWindow } ?? false
        let freshPulse = input.lastReadingAt.map {
            let age = now.timeIntervalSince($0)
            return age >= 0 && age <= freshPulseWindow
        } ?? false

        let displayStatus: AtriaBLEManager.Status
        if recovering, input.status != .poweredOff {
            displayStatus = .connecting
        } else if hasPulseSignal {
            switch input.status {
            case .poweredOff:
                displayStatus = .poweredOff
            case .disconnected:
                displayStatus = freshPulse ? .connected : .disconnected
            case .connected, .connecting, .scanning:
                displayStatus = .connected
            }
        } else {
            displayStatus = input.status
        }

        // One shared rule for every connection surface (see
        // AtriaLiveSignalTruth.freshPulseOverridesLaggingStream). This pill was
        // the original owner of the rule; the Strap screen and the Overview
        // card now read the same definition instead of each carrying its own.
        let freshPulseOverridesLaggingStream = AtriaLiveSignalTruth
            .freshPulseOverridesLaggingStream(hasPulseSignal: hasPulseSignal,
                                              streamState: input.strapStreamState)

        var label: String
        if displayStatus == .connected {
            // A fresh accepted pulse is stronger evidence than a lagging stream
            // projection. Service discovery and the battery read can finish after
            // HR notifications resume, so never show "Waiting" while BPM is live.
            if freshPulseOverridesLaggingStream {
                label = "Live"
            } else {
                label = input.strapStreamConnectionLabel
            }
        } else {
            switch displayStatus {
            case .connected:
                label = hasPulseSignal ? "Live" : "No signal"
            case .connecting:
                if recovering {
                    label = "Reading…"
                } else if !input.isBluetoothReady {
                    label = input.bluetoothPermissionDenied
                        ? "Permission"
                        : "Bluetooth recovering"
                } else if activelyLinking {
                    // "Linking…" — the device name shrank this compact chip to
                    // 0.6-scale micro-text; the name lives on the Strap screen.
                    label = "Linking…"
                } else if reconnectAge != nil {
                    label = "Reconnecting…"
                } else {
                    label = "Connecting"
                }
            case .scanning:
                label = "Searching"
            case .poweredOff:
                label = input.bluetoothPermissionDenied ? "Permission" : "Bluetooth off"
            case .disconnected:
                if input.bluetoothPermissionDenied {
                    label = "Permission"
                } else if !input.isBluetoothReady {
                    label = "Bluetooth unavailable"
                } else if !input.hasEverConnected {
                    label = "Disconnected"
                } else if activelyLinking {
                    // "Linking…" — the device name shrank this compact chip to
                    // 0.6-scale micro-text; the name lives on the Strap screen.
                    label = "Linking…"
                } else {
                    label = "Reconnecting…"
                }
            }
        }

        var symbol: String
        if displayStatus == .connected {
            if freshPulseOverridesLaggingStream {
                symbol = "bolt.heart.fill"
            } else {
                symbol = input.strapStreamConnectionSymbol
            }
        } else {
            switch displayStatus {
            case .connected: symbol = hasPulseSignal ? "bolt.heart.fill" : "heart.slash"
            case .connecting:
                symbol = input.bluetoothPermissionDenied
                    ? "hand.raised.fill"
                    : (recovering
                        ? "waveform.path.ecg"
                        : "dot.radiowaves.left.and.right")
            case .scanning: symbol = "dot.radiowaves.left.and.right"
            case .poweredOff: symbol = input.bluetoothPermissionDenied ? "hand.raised.fill" : "bolt.slash.fill"
            case .disconnected:
                symbol = input.bluetoothPermissionDenied
                    ? "hand.raised.fill"
                    : (input.isBluetoothReady
                        ? "bolt.horizontal.circle"
                        : "exclamationmark.triangle")
            }
        }

        var tone: AtriaTopStatusPresentation.Tone
        if displayStatus == .connected {
            if freshPulseOverridesLaggingStream {
                tone = .green
            } else {
                switch input.strapStreamState {
                case .live: tone = .green
                case .lowBatteryShutoff, .lowBatteryReducedDetail: tone = .yellow
                case .silentUnknown: tone = .orange
                case .warming, .unknown: tone = .cyan
                }
            }
        } else {
            switch displayStatus {
            case .connected: tone = hasPulseSignal ? .green : .orange
            case .connecting:
                tone = input.bluetoothPermissionDenied
                    ? .red
                    : (recovering ? .cyan : .yellow)
            case .scanning: tone = .cyan
            case .poweredOff: tone = .red
            case .disconnected:
                tone = input.bluetoothPermissionDenied || !input.isBluetoothReady
                    ? .red
                    : (input.hasEverConnected ? .yellow : .secondary)
            }
        }

        // Keep the compact pill to collection state plus percentage. Battery
        // Service notifications are change-driven, so their timestamp belongs
        // in the Strap/Battery detail only; showing it here falsely makes live
        // collection look stale. Restoration sentinels never reach this
        // projection. Charging stays a compact visual state with its bolt.
        var accessorySymbol: String?
        var accessibilityLabel: String?
        if displayStatus == .connected,
           freshPulse || input.strapStreamState == .live {
            if let batteryLevel = input.battery.level {
                symbol = batterySymbol(level: batteryLevel)
                let currentPowerState = input.battery.powerState(at: now)
                if currentPowerState == .charging {
                    label = "\(batteryLevel)%"
                    accessorySymbol = "bolt.fill"
                    accessibilityLabel = "Live strap, \(batteryLevel)%, Charging"
                    tone = .green
                } else if currentPowerState == .full {
                    // Full SOC is not proof that the strap is still on external
                    // power. Reserve the bolt for independently proven charging.
                    label = "\(batteryLevel)% · Full"
                    accessibilityLabel = "Live strap, \(batteryLevel)%, Full"
                    tone = .green
                } else if currentPowerState == .unknown {
                    accessibilityLabel = "Live strap, \(batteryLevel)%, charger status unavailable"
                    if batteryLevel <= 20 {
                        label = "\(batteryLevel)% · Low"
                        tone = .orange
                    } else if input.battery.isRecentBaseline {
                        label = "\(batteryLevel)%"
                        tone = .green
                    } else {
                        // Unknown charger evidence must be silent in the compact
                        // pill. The level itself is verified; a question mark
                        // makes that reading look uncertain and gives an
                        // internal fail-closed state user-facing prominence.
                        label = "\(batteryLevel)%"
                        tone = .green
                    }
                } else if batteryLevel <= 20 {
                    label = "\(batteryLevel)% · Low"
                    tone = .orange
                } else if input.battery.isRecentBaseline {
                    label = "\(batteryLevel)%"
                    tone = .green
                } else {
                    label = "\(batteryLevel)%"
                    tone = .green
                }
            } else {
                // Battery Service notifications are CHANGE-driven: a stable
                // strap can go hours without a packet, so after any reconnect
                // (or an app reinstall) the credible level ages past the
                // 10-minute display-freshness limit and this branch used to
                // pin "Battery pending ?" on a perfectly healthy live strap
                // for hours (field reports 2026-08-07, twice). That is the
                // same mistake the charger branch above already rejects:
                // giving an internal fail-closed state user-facing
                // prominence. The pill's job is collection state — say the
                // strap is live, stay silent about the unconfirmed
                // percentage, and let the Strap/Battery detail carry it.
                label = "Live"
                accessibilityLabel = "Live strap, battery percentage not yet confirmed"
                tone = .cyan
            }
        }

        return AtriaTopStatusPresentation(label: label,
                                          symbol: symbol,
                                          tone: tone,
                                          isConnected: displayStatus == .connected,
                                          accessorySymbol: accessorySymbol,
                                          accessibilityLabel: accessibilityLabel)
    }

    private static func batterySymbol(level: Int) -> String {
        AtriaBatteryIdentity.systemImage(percent: level)
    }

    static func nextSemanticDeadline(input: AtriaTopStatusProjectionInput,
                                     now: Date) -> Date? {
        let candidates: [Date?] = [
            input.lastReadingAt?.addingTimeInterval(freshPulseWindow),
            input.pendingKnownReconnectStartedAt?.addingTimeInterval(linkingWindow),
            input.pendingKnownReconnectStartedAt?.addingTimeInterval(liveRecoveryGraceInterval),
            input.rangeLossBackfillPending
                ? input.lastScanMatchAt?.addingTimeInterval(liveRecoveryGraceInterval) : nil,
            input.rangeLossBackfillPending
                ? input.lastScanRequestedAt?.addingTimeInterval(liveRecoveryGraceInterval) : nil,
            nextBatteryRecencyDeadline(verifiedAt: input.battery.verifiedAt,
                                       isRecent: input.battery.isRecentBaseline,
                                       now: now),
            nextChargingExpiryDeadline(battery: input.battery, now: now),
        ]
        return candidates.compactMap { $0 }.filter { $0 >= now }.min()
    }

    private static func batteryRecencyText(verifiedAt: Date?, now: Date) -> String {
        AtriaHomeModel.CoreLiveState.batteryRecencyText(verifiedAt: verifiedAt, now: now)
    }

    private static func nextBatteryRecencyDeadline(verifiedAt: Date?,
                                                   isRecent: Bool,
                                                   now: Date) -> Date? {
        guard isRecent, let verifiedAt, verifiedAt <= now else { return nil }
        let age = now.timeIntervalSince(verifiedAt)
        if age < 60 { return verifiedAt.addingTimeInterval(60) }
        if age < 3_600 {
            let completedMinutes = floor(age / 60)
            return verifiedAt.addingTimeInterval((completedMinutes + 1) * 60)
        }
        let completedHours = floor(age / 3_600)
        return verifiedAt.addingTimeInterval((completedHours + 1) * 3_600)
    }

    private static func nextChargingExpiryDeadline(battery: AtriaHeaderBatterySnapshot,
                                                   now: Date) -> Date? {
        guard battery.powerState == .charging,
              let verifiedAt = battery.chargeVerifiedAt else { return nil }
        let expiry = verifiedAt.addingTimeInterval(AtriaHomeModel.freshChargerEvidenceInterval)
        return expiry >= now ? expiry : nil
    }

    private static func isRecovering(input: AtriaTopStatusProjectionInput,
                                     now: Date) -> Bool {
        guard !input.hasRecentHeartRateSample, input.status != .poweredOff else { return false }
        if let startedAt = input.pendingKnownReconnectStartedAt {
            let age = now.timeIntervalSince(startedAt)
            if age >= 0, age <= liveRecoveryGraceInterval { return true }
        }
        guard input.rangeLossBackfillPending else { return false }
        if let matchAt = input.lastScanMatchAt,
           now.timeIntervalSince(matchAt) <= liveRecoveryGraceInterval {
            return true
        }
        if let requestedAt = input.lastScanRequestedAt,
           now.timeIntervalSince(requestedAt) <= liveRecoveryGraceInterval {
            return input.status == .connecting || input.status == .scanning
        }
        return false
    }
}

@MainActor
final class AtriaTopStatusProjectionStore: ObservableObject {
    @Published private(set) var presentation: AtriaTopStatusPresentation

    private var input: AtriaTopStatusProjectionInput
    private var hasEverConnected: Bool
    private var cancellables = Set<AnyCancellable>()
    private var deadlineTask: Task<Void, Never>?
    private let now: () -> Date

    init(statusStore: AtriaHomeModel.StatusStore,
         coreLiveStore: AtriaHomeModel.CoreLiveStore,
         pulseLiveStore: AtriaHomeModel.PulseLiveStore,
         defaults: UserDefaults = .standard,
         now: @escaping () -> Date = Date.init) {
        self.now = now
        hasEverConnected = defaults.integer(forKey: AtriaBLEManager.LinkDefaults.successes) > 0
            || statusStore.state.status == .connected
        input = Self.makeInput(status: statusStore.state,
                               core: coreLiveStore.state,
                               pulse: AtriaTopStatusPulseTrigger(hasPulseSignal: pulseLiveStore.state.hasPulseSignal),
                               hasEverConnected: hasEverConnected)
        presentation = AtriaTopStatusProjection.presentation(input: input, now: now())

        let status = statusStore.$state
            .map { state in
                AtriaTopStatusStatusTrigger(status: state.status,
                                            bluetoothPermissionDenied: state.bluetoothPermissionDenied,
                                            isBluetoothReady: state.isBluetoothReady)
            }
            .removeDuplicates()
        let core = coreLiveStore.$state
            .map(AtriaTopStatusCoreTrigger.init)
            .removeDuplicates()
        let pulse = pulseLiveStore.$state
            .map { AtriaTopStatusPulseTrigger(hasPulseSignal: $0.hasPulseSignal) }
            .removeDuplicates()

        Publishers.CombineLatest3(status, core, pulse)
            .sink { [weak self] status, core, pulse in
                self?.receive(status: status, core: core, pulse: pulse)
            }
            .store(in: &cancellables)
        scheduleDeadlineRefresh()
    }

    deinit { deadlineTask?.cancel() }

    private func receive(status: AtriaTopStatusStatusTrigger,
                         core: AtriaTopStatusCoreTrigger,
                         pulse: AtriaTopStatusPulseTrigger) {
        if status.status == .connected { hasEverConnected = true }
        input = Self.makeInput(status: status,
                               core: core,
                               pulse: pulse,
                               hasEverConnected: hasEverConnected)
        refresh()
    }

    private func refresh() {
        let next = AtriaTopStatusProjection.presentation(input: input, now: now())
        if next != presentation { presentation = next }
        scheduleDeadlineRefresh()
    }

    private func scheduleDeadlineRefresh() {
        deadlineTask?.cancel()
        guard let deadline = AtriaTopStatusProjection.nextSemanticDeadline(input: input, now: now()) else {
            deadlineTask = nil
            return
        }
        let delay = max(0.01, deadline.timeIntervalSince(now()) + 0.01)
        deadlineTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.deadlineTask = nil
            self?.refresh()
        }
    }

    private static func makeInput(status: AtriaHomeModel.StatusState,
                                  core: AtriaHomeModel.CoreLiveState,
                                  pulse: AtriaTopStatusPulseTrigger,
                                  hasEverConnected: Bool) -> AtriaTopStatusProjectionInput {
        makeInput(status: AtriaTopStatusStatusTrigger(status: status.status,
                                                      bluetoothPermissionDenied: status.bluetoothPermissionDenied,
                                                      isBluetoothReady: status.isBluetoothReady),
                  core: AtriaTopStatusCoreTrigger(core),
                  pulse: pulse,
                  hasEverConnected: hasEverConnected)
    }

    private static func makeInput(status: AtriaTopStatusStatusTrigger,
                                  core: AtriaTopStatusCoreTrigger,
                                  pulse: AtriaTopStatusPulseTrigger,
                                  hasEverConnected: Bool) -> AtriaTopStatusProjectionInput {
        AtriaTopStatusProjectionInput(status: status.status,
                                      bluetoothPermissionDenied: status.bluetoothPermissionDenied,
                                      isBluetoothReady: status.isBluetoothReady,
                                      hasPulseSignal: pulse.hasPulseSignal,
                                      hasRecentHeartRateSample: core.hasRecentHeartRateSample,
                                      lastReadingAt: core.lastReadingAt,
                                      displayDeviceName: core.displayDeviceName,
                                      strapStreamState: core.strapStreamState,
                                      strapStreamConnectionLabel: core.strapStreamConnectionLabel,
                                      strapStreamConnectionSymbol: core.strapStreamConnectionSymbol,
                                      lastScanRequestedAt: core.lastScanRequestedAt,
                                      lastScanMatchAt: core.lastScanMatchAt,
                                      pendingKnownReconnectStartedAt: core.pendingKnownReconnectStartedAt,
                                      rangeLossBackfillPending: core.rangeLossBackfillPending,
                                      hasEverConnected: hasEverConnected,
                                      battery: core.battery)
    }
}

private struct AtriaTopStatusStatusTrigger: Equatable {
    let status: AtriaBLEManager.Status
    let bluetoothPermissionDenied: Bool
    let isBluetoothReady: Bool
}

private struct AtriaTopStatusCoreTrigger: Equatable {
    let hasRecentHeartRateSample: Bool
    let lastReadingAt: Date?
    let displayDeviceName: String
    let strapStreamState: AtriaBLEManager.StrapStreamState
    let strapStreamConnectionLabel: String
    let strapStreamConnectionSymbol: String
    let lastScanRequestedAt: Date?
    let lastScanMatchAt: Date?
    let pendingKnownReconnectStartedAt: Date?
    let rangeLossBackfillPending: Bool
    let battery: AtriaHeaderBatterySnapshot

    init(_ state: AtriaHomeModel.CoreLiveState) {
        hasRecentHeartRateSample = state.hasRecentHeartRateSample
        lastReadingAt = state.lastReadingAt
        displayDeviceName = state.displayDeviceName
        strapStreamState = state.strapStreamState
        strapStreamConnectionLabel = state.strapStreamConnectionLabel
        strapStreamConnectionSymbol = state.strapStreamConnectionSymbol
        lastScanRequestedAt = state.lastScanRequestedAt
        lastScanMatchAt = state.lastScanMatchAt
        pendingKnownReconnectStartedAt = state.pendingKnownReconnectStartedAt
        rangeLossBackfillPending = state.rangeLossBackfillPending
        battery = AtriaHeaderBatterySnapshot(
            level: state.batteryLevel,
            showsPowered: state.batteryShowsPowered,
            chargeStatus: state.batteryChargeStatus,
            isRecentBaseline: state.batteryReadingIsRecentBaseline,
            verifiedAt: state.batteryLastVerifiedAt,
            chargeVerifiedAt: state.batteryChargeLastVerifiedAt
        )
    }
}

/// The host observes one compact semantic projection. Raw RR arrays, calories,
/// sample counts, and other live-store fields cannot invalidate this view.
struct AtriaTopStatusChipHost: View {
    @StateObject private var projectionStore: AtriaTopStatusProjectionStore
    let onTapWhenConnected: () -> Void
    let onTapWhenNotConnected: () -> Void

    init(statusStore: AtriaHomeModel.StatusStore,
         coreLiveStore: AtriaHomeModel.CoreLiveStore,
         pulseLiveStore: AtriaHomeModel.PulseLiveStore,
         onTapWhenConnected: @escaping () -> Void,
         onTapWhenNotConnected: @escaping () -> Void) {
        _projectionStore = StateObject(wrappedValue: AtriaTopStatusProjectionStore(
            statusStore: statusStore,
            coreLiveStore: coreLiveStore,
            pulseLiveStore: pulseLiveStore
        ))
        self.onTapWhenConnected = onTapWhenConnected
        self.onTapWhenNotConnected = onTapWhenNotConnected
    }

    var body: some View {
        AtriaTopStatusChip(presentation: projectionStore.presentation,
                           onTapWhenConnected: onTapWhenConnected,
                           onTapWhenNotConnected: onTapWhenNotConnected)
            .equatable()
    }
}

private struct AtriaTopStatusChip: View, Equatable {
    let presentation: AtriaTopStatusPresentation
    let onTapWhenConnected: () -> Void
    let onTapWhenNotConnected: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.presentation == rhs.presentation
    }

    var body: some View {
        Button(action: presentation.isConnected ? onTapWhenConnected : onTapWhenNotConnected) {
            chipLabel
        }
        .buttonStyle(.plain)
    }

    private var chipLabel: some View {
        HStack(spacing: 5) {
            Image(systemName: presentation.symbol)
                .imageScale(.small)
            Text(presentation.label)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .allowsTightening(true)
            if let accessorySymbol = presentation.accessorySymbol {
                Image(systemName: accessorySymbol)
                    .font(.caption2.weight(.black))
                    .imageScale(.small)
                    .accessibilityHidden(true)
            }
        }
        .font(.caption.weight(.bold))
        // The state hue already lives in the glass surface. Adaptive primary
        // remains legible when Liquid Glass intensifies a connected tint.
        .foregroundStyle(presentation.isConnected ? Color.primary : toneColor)
        .padding(.horizontal, 12)
        .frame(minWidth: AtriaHeaderControlMetrics.statusMinWidth,
               maxWidth: 172,
               minHeight: AtriaHeaderControlMetrics.height,
               maxHeight: AtriaHeaderControlMetrics.height)
        .glassEffect(
            .regular
                .tint(toneColor.opacity(colorScheme == .dark ? 0.34 : 0.22))
                .interactive(),
            in: .capsule
        )
        .contentShape(Capsule())
        .accessibilityLabel("Strap status \(presentation.accessibilityLabel)")
    }

    private var toneColor: Color {
        switch presentation.tone {
        case .green: return .green
        case .yellow: return .yellow
        case .orange: return .orange
        case .cyan: return .cyan
        case .red: return .red
        case .secondary: return .secondary
        }
    }
}

/// Determines whether a visible status belongs in the reconnect/setup guide.
///
/// Connected sensor states are useful explanations, but they are not
/// connection failures. Metric-acquisition states such as HRV settling belong
/// on the metric that needs them, not in this global connection surface.
enum AtriaConnectionGuidanceDomain: Equatable {
    case bluetoothLink
    case appCoexistence
    case strapPower
    case wearSignal

    var offersConnectionGuide: Bool {
        switch self {
        case .bluetoothLink, .appCoexistence:
            return true
        case .strapPower, .wearSignal:
            return false
        }
    }
}

private struct AtriaConnectionDiagnosis: Equatable {
    private static let lowBatteryThreshold = 25
    private static let pendingKnownReconnectActionAge: TimeInterval = 15

    let title: String
    /// Full-sentence guidance. Never rendered as banner body copy — it stays
    /// in the banner accessibilityLabel and the local-notification body, and
    /// the "?" connection-guide sheet carries the expanded recovery steps for
    /// the domains that offer it. Relocated, never deleted.
    let action: String
    /// Terse on-banner imperative rendered in the visible action slot.
    let imperative: String
    let systemImage: String
    let tint: Color
    let guidanceDomain: AtriaConnectionGuidanceDomain

    static func == (lhs: AtriaConnectionDiagnosis, rhs: AtriaConnectionDiagnosis) -> Bool {
        lhs.title == rhs.title
            && lhs.action == rhs.action
            && lhs.systemImage == rhs.systemImage
            && lhs.guidanceDomain == rhs.guidanceDomain
    }

    var showsImmediately: Bool {
        title == "Bluetooth is off"
            || title == "Bluetooth permission needed"
            || title == "Strap battery too low"
            || title == "Strap battery low"
    }

    var sendsLocalNotification: Bool {
        title == "Bluetooth is off"
            || title == "Strap battery too low"
            || title == "Strap battery low"
            // Fit check is deliberately NOT in showsImmediately, so it only notifies
            // after persisting through the candidate delay — no blip-triggered alerts.
            || title == "Fit check needed"
    }

    static func derive(live: AtriaHomeModel.CoreLiveState,
                       pulse: AtriaHomeModel.PulseLiveState,
                       officialAppInstalled: Bool) -> AtriaConnectionDiagnosis? {
        let officialAppRiskActive = officialAppInstalled && live.officialAppCoexistenceRisk != .cleared
        let stalePairingSuspected = !officialAppInstalled && live.officialAppCoexistenceRisk == .suspected
        let pendingKnownReconnectAge = live.pendingKnownReconnectAge() ?? 0
        let pendingKnownReconnectActive = pendingKnownReconnectAge >= Self.pendingKnownReconnectActionAge
        let isRecoveringLiveSignal = live.isInRecentLiveRecovery()
        let needsContactCoach = pulse.needsContactCoach
            && !live.hasRecentHeartRateSample
            && !isRecoveringLiveSignal

        switch live.status {
        case .poweredOff:
            if live.bluetoothPermissionDenied {
                return AtriaConnectionDiagnosis(title: "Bluetooth permission needed",
                                                action: "Allow Bluetooth for Atria in Settings.",
                                                imperative: "Allow Bluetooth in Settings",
                                                systemImage: "hand.raised.fill",
                                                tint: .red,
                                                guidanceDomain: .bluetoothLink)
            }
            return AtriaConnectionDiagnosis(title: "Bluetooth is off",
                                            action: "Turn on Bluetooth in Settings.",
                                            imperative: "Turn on Bluetooth",
                                            systemImage: "bolt.slash.fill",
                                            tint: .red,
                                            guidanceDomain: .bluetoothLink)
        case .connected where live.isLowBatteryLiveLimited:
            return AtriaConnectionDiagnosis(title: "Strap battery too low",
                                            action: "Charge your strap to resume live heart rate.",
                                            imperative: "Charge your strap",
                                            systemImage: "battery.25percent",
                                            tint: Metrics.electricYellow,
                                            guidanceDomain: .strapPower)
        case .connected where needsContactCoach:
            return AtriaConnectionDiagnosis(title: "Fit check needed",
                                            action: "Tighten the strap fit so Atria can read pulse.",
                                            imperative: "Tighten the strap",
                                            systemImage: "heart.slash",
                                            tint: .orange,
                                            guidanceDomain: .wearSignal)
        case _ where live.batteryLevel >= 0 && live.batteryLevel <= Self.lowBatteryThreshold && live.batteryRecentlyDropping && !live.batteryIsCharging:
            return AtriaConnectionDiagnosis(title: "Strap battery low",
                                            action: "Charge your strap before a workout or overnight wear.",
                                            imperative: "Charge your strap",
                                            systemImage: "battery.25percent",
                                            tint: Metrics.electricYellow,
                                            guidanceDomain: .strapPower)
        case .connected where officialAppRiskActive && live.officialAppCoexistenceRisk == .suspected:
            return AtriaConnectionDiagnosis(title: "WHOOP may interrupt",
                                            action: "Close or uninstall WHOOP if readings fragment.",
                                            imperative: "Close the WHOOP app",
                                            systemImage: "exclamationmark.triangle.fill",
                                            tint: .orange,
                                            guidanceDomain: .appCoexistence)
        case .connected where officialAppRiskActive:
            return AtriaConnectionDiagnosis(title: "WHOOP app watch",
                                            action: "Atria is streaming; close WHOOP if drops return.",
                                            // Atria is streaming here, so the terse form keeps the
                                            // conditional rather than ordering an unneeded close.
                                            imperative: "Close WHOOP if drops return",
                                            systemImage: "app.connected.to.app.below.fill",
                                            tint: .orange,
                                            guidanceDomain: .appCoexistence)
        case .scanning, .connecting:
            if officialAppRiskActive {
                return AtriaConnectionDiagnosis(title: "WHOOP app may interfere",
                                                action: "Keep the strap nearby and close WHOOP if it keeps reclaiming it.",
                                                imperative: "Close the WHOOP app",
                                                systemImage: "exclamationmark.triangle.fill",
                                                tint: .orange,
                                                guidanceDomain: .appCoexistence)
            }
            if pendingKnownReconnectActive {
                return AtriaConnectionDiagnosis(title: "Strap out of range",
                                                action: "Atria is still reconnecting to your saved strap. Bring it closer or keep wearing it.",
                                                imperative: "Bring your strap closer",
                                                systemImage: "dot.radiowaves.left.and.right",
                                                tint: .cyan,
                                                guidanceDomain: .bluetoothLink)
            }
            if stalePairingSuspected {
                return AtriaConnectionDiagnosis(title: "Connection keeps dropping",
                                                action: "Forget the strap in Bluetooth, then reconnect.",
                                                imperative: "Re-pair in Bluetooth settings",
                                                systemImage: "arrow.triangle.2.circlepath.circle.fill",
                                                tint: .orange,
                                                guidanceDomain: .bluetoothLink)
            }
            return AtriaConnectionDiagnosis(title: "Looking for your strap",
                                            action: "Bring your strap closer and keep it on your wrist.",
                                            imperative: "Bring your strap closer",
                                            systemImage: "dot.radiowaves.left.and.right",
                                            tint: .cyan,
                                            guidanceDomain: .bluetoothLink)
        case .disconnected:
            if officialAppRiskActive {
                return AtriaConnectionDiagnosis(title: "WHOOP app may interfere",
                                                action: "Close or uninstall WHOOP if it keeps reclaiming the strap.",
                                                imperative: "Close the WHOOP app",
                                                systemImage: "exclamationmark.triangle.fill",
                                                tint: .orange,
                                                guidanceDomain: .appCoexistence)
            }
            if pendingKnownReconnectActive {
                return AtriaConnectionDiagnosis(title: "Strap out of range",
                                                action: "Atria is still waiting for your saved strap. Bring it closer or keep wearing it.",
                                                imperative: "Bring your strap closer",
                                                systemImage: "dot.radiowaves.left.and.right",
                                                tint: .cyan,
                                                guidanceDomain: .bluetoothLink)
            }
            if stalePairingSuspected {
                return AtriaConnectionDiagnosis(title: "Stale Bluetooth pairing",
                                                action: "Forget the strap in Bluetooth, then reconnect.",
                                                imperative: "Re-pair in Bluetooth settings",
                                                systemImage: "arrow.triangle.2.circlepath.circle.fill",
                                                tint: .orange,
                                                guidanceDomain: .bluetoothLink)
            }
            return AtriaConnectionDiagnosis(title: "Strap disconnected",
                                            action: "Bring it closer. If it keeps failing, forget it in Bluetooth and reconnect.",
                                            imperative: "Bring your strap closer",
                                            systemImage: "bolt.horizontal.circle",
                                            tint: .blue,
                                            guidanceDomain: .bluetoothLink)
        case .connected:
            return nil
        }
    }
}

private struct AtriaConnectionDiagnosisBanner: View, Equatable {
    let diagnosis: AtriaConnectionDiagnosis
    let onHelp: () -> Void

    static func == (lhs: AtriaConnectionDiagnosisBanner, rhs: AtriaConnectionDiagnosisBanner) -> Bool {
        lhs.diagnosis == rhs.diagnosis
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: diagnosis.systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(diagnosis.tint)
                .frame(width: 30, height: 30)
                .background(AtriaIconTileBackground(cornerRadius: 9, tint: diagnosis.tint))

            VStack(alignment: .leading, spacing: 3) {
                Text(diagnosis.title)
                    .font(.subheadline.weight(.semibold))
                    // Connection states are already stressful; never squeeze a
                    // meaningful diagnosis into an unreadable one-line label.
                    // The handoff's mobile callouts reserve real text space,
                    // and this is a transient, low-frequency surface so the
                    // extra line has no scrolling-performance cost.
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                // Terse imperative on the banner; the full sentence stays in
                // the combined accessibilityLabel below and in the "?"
                // connection-guide sheet for the domains that offer it.
                Text(diagnosis.imperative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(2)

            Spacer(minLength: 0)

            if diagnosis.guidanceDomain.offersConnectionGuide {
                Button(action: onHelp) {
                    Image(systemName: "questionmark.circle")
                        .font(.caption.weight(.bold))
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(diagnosis.tint)
                .accessibilityLabel("Connection help")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        // The design handoff uses a distinct, calm status callout rather than
        // another dense flat row. This banner is visible only for an actionable
        // connection problem, so one native glass pass improves hierarchy
        // without adding glass work to the normal scrolling dashboard.
        .atriaGlassCard(cornerRadius: AtriaDesignTokens.Radius.inset)
        .overlay {
            RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.inset,
                             style: .continuous)
                .stroke(diagnosis.tint.opacity(0.22), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(diagnosis.title). \(diagnosis.action)")
    }
}
