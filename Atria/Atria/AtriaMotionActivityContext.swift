import Combine
import CoreMotion
import Foundation

/// A conservative, time-aligned summary of the phone's native motion context.
/// Heart rate is deliberately absent: exertion can support a workout prompt,
/// but it cannot identify walking, running, cycling, driving, or dance.
struct AtriaMotionActivityContext: Equatable {
    enum Kind: String, Equatable {
        case stationary
        case walking
        case running
        case cycling
        case automotive
        case unknown
    }

    enum Confidence: Int, Comparable, Equatable {
        case low
        case medium
        case high

        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    let kind: Kind
    let confidence: Confidence
    /// The beginning of the current Core Motion classification.
    let startedAt: Date
    /// When Atria last received or queried evidence that this was current.
    let observedAt: Date

    static let unknown = AtriaMotionActivityContext(kind: .unknown,
                                                    confidence: .low,
                                                    startedAt: .distantPast,
                                                    observedAt: .distantPast)
}

enum AtriaMotionActivityGate {
    static let minimumSuggestionDuration: TimeInterval = 2 * 60
    static let maximumEvidenceAge: TimeInterval = 45
    static let maximumFutureSkew: TimeInterval = 5

    struct Decision: Equatable {
        let vetoesWorkoutPrompt: Bool
        let suggestedActivityType: AtriaWorkoutActivityType?
    }

    /// Automotive evidence is a hard veto. Locomotion labels are suggestions
    /// only after fresh, medium-or-better evidence has remained unambiguous for
    /// two minutes. Everything else abstains, including dance.
    static func evaluate(_ context: AtriaMotionActivityContext,
                         now: Date = Date()) -> Decision {
        let evidenceAge = now.timeIntervalSince(context.observedAt)
        let classificationAge = now.timeIntervalSince(context.startedAt)
        guard evidenceAge >= -maximumFutureSkew,
              evidenceAge <= maximumEvidenceAge,
              classificationAge >= 0 else {
            return Decision(vetoesWorkoutPrompt: false,
                            suggestedActivityType: nil)
        }

        if context.kind == .automotive, context.confidence >= .medium {
            // A hard negative needs at least medium native confidence. A low
            // confidence label abstains rather than hiding a real workout.
            return Decision(vetoesWorkoutPrompt: true,
                            suggestedActivityType: nil)
        }

        guard context.confidence >= .medium,
              classificationAge >= minimumSuggestionDuration else {
            return Decision(vetoesWorkoutPrompt: false,
                            suggestedActivityType: nil)
        }

        let suggestion: AtriaWorkoutActivityType?
        switch context.kind {
        case .walking: suggestion = .walking
        case .running: suggestion = .running
        case .cycling: suggestion = .cycling
        case .stationary, .automotive, .unknown: suggestion = nil
        }
        return Decision(vetoesWorkoutPrompt: false,
                        suggestedActivityType: suggestion)
    }
}

/// A bounded, non-sensitive audit snapshot for the phone-motion workout gate.
/// It intentionally stores no coordinates, route, raw accelerometer samples, or
/// motion history. Unchanged observations are checkpointed at most every five
/// minutes so the 30-second Core Motion refresh never becomes a write loop.
struct AtriaMotionActivityDiagnosticSnapshot: Equatable {
    let authorization: String
    let monitorState: String
    let kind: String
    let confidence: String
    let startedAt: Date?
    let observedAt: Date?
    let decision: String
    let decisionAt: Date
    let persistedAt: Date
}

@MainActor
final class AtriaMotionActivityDiagnostics {
    static let defaultsKey = "atria.motionContext.diagnostics"
    static let minimumUnchangedWriteInterval: TimeInterval = 5 * 60
    static let schemaVersion = 1

    private let defaults: UserDefaults
    private let minimumUnchangedWriteInterval: TimeInterval
    private var lastSignature: String?
    private var lastPersistedAt: Date?

    init(defaults: UserDefaults = .standard,
         minimumUnchangedWriteInterval: TimeInterval? = nil) {
        self.defaults = defaults
        self.minimumUnchangedWriteInterval = minimumUnchangedWriteInterval
            ?? Self.minimumUnchangedWriteInterval
        if let snapshot = Self.snapshot(from: defaults.dictionary(forKey: Self.defaultsKey)) {
            lastSignature = Self.signature(authorization: snapshot.authorization,
                                           monitorState: snapshot.monitorState,
                                           kind: snapshot.kind,
                                           confidence: snapshot.confidence,
                                           startedAt: snapshot.startedAt,
                                           decision: snapshot.decision)
            lastPersistedAt = snapshot.persistedAt
        }
    }

    @discardableResult
    func record(context: AtriaMotionActivityContext,
                decision: AtriaMotionActivityGate.Decision,
                authorization: String,
                monitorState: String = "running",
                now: Date = Date(),
                force: Bool = false) -> Bool {
        let kind = context.kind.rawValue
        let confidence = Self.confidenceText(context.confidence)
        let startedAt = context.startedAt == .distantPast ? nil : context.startedAt
        let observedAt = context.observedAt == .distantPast ? nil : context.observedAt
        let decisionText = Self.decisionText(decision)
        let signature = Self.signature(authorization: authorization,
                                       monitorState: monitorState,
                                       kind: kind,
                                       confidence: confidence,
                                       startedAt: startedAt,
                                       decision: decisionText)
        let unchangedIntervalElapsed = lastPersistedAt.map {
            now.timeIntervalSince($0) >= minimumUnchangedWriteInterval
        } ?? true
        guard force || signature != lastSignature || unchangedIntervalElapsed else {
            return false
        }

        var payload: [String: Any] = [
            "schemaVersion": Self.schemaVersion,
            "authorization": authorization,
            "monitorState": monitorState,
            "kind": kind,
            "confidence": confidence,
            "decision": decisionText,
            "decisionAt": now.timeIntervalSince1970,
            "persistedAt": now.timeIntervalSince1970
        ]
        if let startedAt { payload["startedAt"] = startedAt.timeIntervalSince1970 }
        if let observedAt { payload["observedAt"] = observedAt.timeIntervalSince1970 }
        defaults.set(payload, forKey: Self.defaultsKey)
        lastSignature = signature
        lastPersistedAt = now
        return true
    }

    func recordStopped(authorization: String, now: Date = Date()) {
        record(context: .unknown,
               decision: .init(vetoesWorkoutPrompt: false, suggestedActivityType: nil),
               authorization: authorization,
               monitorState: "stopped",
               now: now,
               force: true)
    }

    func snapshot() -> AtriaMotionActivityDiagnosticSnapshot? {
        Self.snapshot(from: defaults.dictionary(forKey: Self.defaultsKey))
    }

    private static func confidenceText(_ confidence: AtriaMotionActivityContext.Confidence) -> String {
        switch confidence {
        case .low: return "low"
        case .medium: return "medium"
        case .high: return "high"
        }
    }

    private static func decisionText(_ decision: AtriaMotionActivityGate.Decision) -> String {
        if decision.vetoesWorkoutPrompt { return "veto_workout_prompt" }
        if let suggestion = decision.suggestedActivityType {
            return "suggest_\(suggestion.rawValue)"
        }
        return "abstain"
    }

    private static func signature(authorization: String,
                                  monitorState: String,
                                  kind: String,
                                  confidence: String,
                                  startedAt: Date?,
                                  decision: String) -> String {
        [authorization,
         monitorState,
         kind,
         confidence,
         startedAt.map { String($0.timeIntervalSince1970) } ?? "missing",
         decision].joined(separator: "|")
    }

    private static func snapshot(from payload: [String: Any]?) -> AtriaMotionActivityDiagnosticSnapshot? {
        guard let payload,
              let authorization = payload["authorization"] as? String,
              let monitorState = payload["monitorState"] as? String,
              let kind = payload["kind"] as? String,
              let confidence = payload["confidence"] as? String,
              let decision = payload["decision"] as? String,
              let decisionAtValue = payload["decisionAt"] as? TimeInterval,
              let persistedAtValue = payload["persistedAt"] as? TimeInterval else {
            return nil
        }
        let startedAt = (payload["startedAt"] as? TimeInterval).map(Date.init(timeIntervalSince1970:))
        let observedAt = (payload["observedAt"] as? TimeInterval).map(Date.init(timeIntervalSince1970:))
        return AtriaMotionActivityDiagnosticSnapshot(
            authorization: authorization,
            monitorState: monitorState,
            kind: kind,
            confidence: confidence,
            startedAt: startedAt,
            observedAt: observedAt,
            decision: decision,
            decisionAt: Date(timeIntervalSince1970: decisionAtValue),
            persistedAt: Date(timeIntervalSince1970: persistedAtValue)
        )
    }
}

/// Owns Core Motion's event stream and periodically queries its short history.
/// `CMMotionActivityManager` reports changes rather than a reliable heartbeat;
/// the bounded query is what lets the gate prove that evidence is still current
/// without polling sensors at high frequency.
@MainActor
final class AtriaMotionActivityMonitor: ObservableObject {
    @Published private(set) var context = AtriaMotionActivityContext.unknown

    private static let refreshInterval: Duration = .seconds(30)
    private static let queryLookback: TimeInterval = 5 * 60

    private let manager = CMMotionActivityManager()
    private let diagnostics: AtriaMotionActivityDiagnostics
    private var refreshTask: Task<Void, Never>?
    private var isRunning = false

    init(diagnostics: AtriaMotionActivityDiagnostics? = nil) {
        self.diagnostics = diagnostics ?? AtriaMotionActivityDiagnostics()
    }

    func start() {
        guard !isRunning else { return }
        guard CMMotionActivityManager.isActivityAvailable() else {
            diagnostics.record(context: .unknown,
                               decision: AtriaMotionActivityGate.evaluate(.unknown),
                               authorization: Self.authorizationText(),
                               monitorState: "unavailable",
                               force: true)
            return
        }
        let authorization = CMMotionActivityManager.authorizationStatus()
        guard authorization != .denied, authorization != .restricted else {
            recordUnavailableAuthorization(authorization)
            return
        }
        isRunning = true
        // Persist the fail-closed state before Core Motion can present its
        // permission prompt. If the user has not answered yet, device evidence
        // must say not-determined/abstain instead of looking uninstrumented.
        diagnostics.record(context: .unknown,
                           decision: AtriaMotionActivityGate.evaluate(.unknown),
                           authorization: Self.authorizationText(),
                           monitorState: "starting",
                           force: true)
        manager.startActivityUpdates(to: .main) { [weak self] activity in
            guard let activity else { return }
            Task { @MainActor [weak self] in
                self?.consume(activity, observedAt: Date())
            }
        }
        queryCurrentContext()
        refreshTask = Task { @MainActor [weak self] in
            while let self, self.isRunning, !Task.isCancelled {
                try? await Task.sleep(for: Self.refreshInterval)
                guard !Task.isCancelled, self.isRunning else { break }
                self.queryCurrentContext()
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        refreshTask?.cancel()
        refreshTask = nil
        manager.stopActivityUpdates()
        // Old evidence must not survive a background interval and suppress or
        // label a later, unrelated HR episode on foreground return.
        context = .unknown
        diagnostics.recordStopped(authorization: Self.authorizationText())
    }

    func recordGateDecision(_ decision: AtriaMotionActivityGate.Decision,
                            now: Date = Date()) {
        diagnostics.record(context: context,
                           decision: decision,
                           authorization: Self.authorizationText(),
                           now: now)
    }

    private func queryCurrentContext(now: Date = Date()) {
        manager.queryActivityStarting(from: now.addingTimeInterval(-Self.queryLookback),
                                      to: now,
                                      to: .main) { [weak self] activities, error in
            Task { @MainActor [weak self] in
                guard let self, self.isRunning else { return }
                guard error == nil, let latest = activities?.last else {
                    let authorization = CMMotionActivityManager.authorizationStatus()
                    if authorization == .denied || authorization == .restricted {
                        self.isRunning = false
                        self.refreshTask?.cancel()
                        self.refreshTask = nil
                        self.manager.stopActivityUpdates()
                        self.context = .unknown
                        self.recordUnavailableAuthorization(authorization)
                        return
                    }
                    let decision = AtriaMotionActivityGate.evaluate(self.context, now: Date())
                    self.recordGateDecision(decision)
                    return
                }
                self.consume(latest, observedAt: Date())
            }
        }
    }

    private func consume(_ activity: CMMotionActivity, observedAt: Date) {
        let context = AtriaMotionActivityContext(kind: Self.kind(for: activity),
                                                 confidence: Self.confidence(for: activity.confidence),
                                                 startedAt: activity.startDate,
                                                 observedAt: observedAt)
        if self.context != context {
            self.context = context
        }
        recordGateDecision(AtriaMotionActivityGate.evaluate(context, now: observedAt),
                           now: observedAt)
    }

    private static func kind(for activity: CMMotionActivity) -> AtriaMotionActivityContext.Kind {
        // Automotive always wins over simultaneous low-level movement flags.
        guard !activity.automotive else { return .automotive }
        let locomotion: [AtriaMotionActivityContext.Kind] = [
            activity.walking ? .walking : nil,
            activity.running ? .running : nil,
            activity.cycling ? .cycling : nil
        ].compactMap { $0 }
        guard locomotion.count <= 1 else { return .unknown }
        if let only = locomotion.first { return only }
        if activity.stationary { return .stationary }
        return .unknown
    }

    private static func confidence(for confidence: CMMotionActivityConfidence) -> AtriaMotionActivityContext.Confidence {
        switch confidence {
        case .high: return .high
        case .medium: return .medium
        case .low: return .low
        @unknown default: return .low
        }
    }

    private func recordUnavailableAuthorization(_ authorization: CMAuthorizationStatus) {
        context = .unknown
        diagnostics.record(context: .unknown,
                           decision: AtriaMotionActivityGate.evaluate(.unknown),
                           authorization: Self.authorizationText(authorization),
                           monitorState: authorization == .denied ? "permission_denied" : "restricted",
                           force: true)
    }

    private static func authorizationText(_ status: CMAuthorizationStatus = CMMotionActivityManager.authorizationStatus()) -> String {
        switch status {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not_determined"
        @unknown default: return "unknown"
        }
    }
}
