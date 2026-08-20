import AppIntents
import Foundation
import SwiftUI

enum AtriaIntentDestination: String, AppEnum, Codable {
    case today
    case vitals
    case journal
    case collection

    static var typeDisplayName: LocalizedStringResource { "Atria destination" }
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Atria destination"

    static var caseDisplayRepresentations: [Self: DisplayRepresentation] {
        [
            .today: "Today",
            .vitals: "Vitals",
            .journal: "Journal",
            .collection: "Strap"
        ]
    }
}

enum AtriaCaptureCommand: String, AppEnum, Codable {
    case start
    case stop

    static var typeDisplayName: LocalizedStringResource { "Backup command" }
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Backup command"

    static var caseDisplayRepresentations: [Self: DisplayRepresentation] {
        [
            .start: "Start",
            .stop: "Stop"
        ]
    }
}

enum AtriaFocusMode: String, AppEnum, Codable {
    case off
    case workout
    case sleep

    static var typeDisplayName: LocalizedStringResource { "Atria Focus mode" }
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Atria Focus mode"

    static var caseDisplayRepresentations: [Self: DisplayRepresentation] {
        [
            .off: "Off",
            .workout: "Workout backup",
            .sleep: "Sleep backup"
        ]
    }
}

struct OpenAtriaIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Atria"
    static let description = IntentDescription("Open Atria to a selected local dashboard.")
    static let openAppWhenRun = true

    @Parameter(title: "Destination")
    var destination: AtriaIntentDestination

    init() {
        destination = .today
    }

    init(destination: AtriaIntentDestination) {
        self.destination = destination
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        AtriaIntentCommandStore.save(.open(destination))
        return .result(dialog: "Opening \(destination.dialogName) in Atria.")
    }
}

struct AtriaMetricsIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Atria metrics"
    static let description = IntentDescription("Read the latest local recovery, strain, and HRV snapshot.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView & ReturnsValue<String> {
        guard let snapshot = AtriaIntentSnapshotStore.loadLatestSnapshot() else {
            let learning = "Atria is still learning. Open the app once to refresh the local snapshot."
            return .result(value: learning,
                           dialog: IntentDialog(stringLiteral: learning),
                           view: AtriaMetricsSnippetView(snapshot: nil))
        }

        let recovery = AtriaIntentMetricPresentation.recoverySpoken(
            percent: snapshot.recoveryPercent,
            confidence: snapshot.recoveryConfidence
        )
        let hrv = snapshot.hrvRMSSD.map { "\($0) milliseconds" } ?? snapshot.hrvState
        let strain = AtriaIntentMetricPresentation.strainSpoken(
            value: snapshot.strain,
            detail: snapshot.strainDetail,
            appRenderedValueText: snapshot.strainValueText
        )
        let summary = "Recovery is \(recovery), strain is \(strain), and HRV is \(hrv)."
        return .result(value: summary,
                       dialog: IntentDialog(stringLiteral: summary),
                       view: AtriaMetricsSnippetView(snapshot: snapshot))
    }
}

/// Compact Siri/Shortcuts snippet card: the three headline numbers at a glance,
/// rendered from the same app-group snapshot the widgets use.
private struct AtriaMetricsSnippetView: View {
    let snapshot: WidgetSnapshot?

    var body: some View {
        HStack(spacing: 14) {
            stat(label: "Recovery",
                 value: snapshot.map {
                    AtriaIntentMetricPresentation.recoveryCompact(
                        percent: $0.recoveryPercent,
                        confidence: $0.recoveryConfidence
                    )
                 } ?? "--",
                 tint: .cyan)
            stat(label: "Strain",
                 value: snapshot.map {
                    AtriaIntentMetricPresentation.strainCompact(
                        value: $0.strain,
                        detail: $0.strainDetail,
                        appRenderedValueText: $0.strainValueText
                    )
                 } ?? "--",
                 tint: .orange)
            stat(label: "HRV",
                 value: snapshot?.hrvRMSSD.map { "\($0)ms" } ?? "--",
                 tint: .purple)
        }
        .padding(16)
    }

    private func stat(label: String, value: String, tint: Color) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title3.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(tint)
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

struct AtriaFocusFilterIntent: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Atria data backup"
    static let description = IntentDescription("Automatically tune local Atria backup when a Focus is active.")
    static let openAppWhenRun = false

    @Parameter(title: "Mode")
    var mode: AtriaFocusMode?

    init() {
        mode = .off
    }

    init(mode: AtriaFocusMode) {
        self.mode = mode
    }

    var displayRepresentation: DisplayRepresentation {
        switch resolvedMode {
        case .off:
            return DisplayRepresentation(title: "Atria off",
                                         subtitle: "Do not change backup")
        case .workout:
            return DisplayRepresentation(title: "Workout backup",
                                         subtitle: "Start live backup")
        case .sleep:
            return DisplayRepresentation(title: "Sleep backup",
                                         subtitle: "Arm overnight backup")
        }
    }

    static func suggestedFocusFilters(for context: FocusFilterSuggestionContext) async -> [AtriaFocusFilterIntent] {
        [
            AtriaFocusFilterIntent(mode: .workout),
            AtriaFocusFilterIntent(mode: .sleep),
            AtriaFocusFilterIntent(mode: .off)
        ]
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let mode = resolvedMode
        AtriaIntentCommandStore.save(.focus(mode))
        AtriaIntentCommandStore.persistFocusMode(mode)
        return .result(dialog: "\(mode.dialogVerb) Atria backup.")
    }

    private var resolvedMode: AtriaFocusMode {
        mode ?? .off
    }
}

struct AtriaCaptureIntent: AppIntent {
    static let title: LocalizedStringResource = "Control Atria backup"
    static let description = IntentDescription("Start or stop Atria's local backup when the app opens.")
    static let openAppWhenRun = true

    @Parameter(title: "Command")
    var command: AtriaCaptureCommand

    init() {
        command = .start
    }

    init(command: AtriaCaptureCommand) {
        self.command = command
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        AtriaIntentCommandStore.save(.capture(command))
        return .result(dialog: "\(command.dialogVerb) Atria backup.")
    }
}

struct AtriaAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AtriaMetricsIntent(),
            phrases: [
                "What's my recovery in \(.applicationName)",
                "Check my Atria metrics with \(.applicationName)"
            ],
            shortTitle: "Atria metrics",
            systemImageName: "heart.text.square"
        )

        AppShortcut(
            intent: OpenAtriaIntent(destination: .vitals),
            phrases: [
                "Open vitals in \(.applicationName)",
                "Show my vitals in \(.applicationName)"
            ],
            shortTitle: "Open vitals",
            systemImageName: "waveform.path.ecg"
        )

        AppShortcut(
            intent: OpenAtriaIntent(destination: .journal),
            phrases: [
                "Open my journal in \(.applicationName)",
                "Log my morning check-in in \(.applicationName)"
            ],
            shortTitle: "Morning check-in",
            systemImageName: "square.and.pencil"
        )

        AppShortcut(
            intent: AtriaCaptureIntent(command: .start),
            phrases: [
                "Start backup in \(.applicationName)",
                "Start Atria session with \(.applicationName)"
            ],
            shortTitle: "Start backup",
            systemImageName: "record.circle"
        )

        AppShortcut(
            intent: AtriaCaptureIntent(command: .stop),
            phrases: [
                "Stop backup in \(.applicationName)",
                "Stop Atria session with \(.applicationName)"
            ],
            shortTitle: "Stop backup",
            systemImageName: "stop.circle"
        )
    }
}

enum AtriaIntentCommand: Codable, Equatable {
    case open(AtriaIntentDestination)
    case capture(AtriaCaptureCommand)
    case focus(AtriaFocusMode)
}

enum AtriaIntentCommandStore {
    private static let key = "atria.intent.pendingCommand.v1"
    private static let appGroupID = "group.com.adidshaft.atria"

    static func save(_ command: AtriaIntentCommand) {
        guard let data = try? JSONEncoder().encode(command) else { return }
        UserDefaults.standard.set(data, forKey: key)
        UserDefaults(suiteName: appGroupID)?.set(data, forKey: key)
    }

    static func consume() -> AtriaIntentCommand? {
        let sharedDefaults = UserDefaults(suiteName: appGroupID)
        let data = sharedDefaults?.data(forKey: key) ?? UserDefaults.standard.data(forKey: key)
        guard let data,
              let command = try? JSONDecoder().decode(AtriaIntentCommand.self, from: data) else {
            return nil
        }
        sharedDefaults?.removeObject(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        return command
    }

    static func persistFocusMode(_ mode: AtriaFocusMode) {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: AtriaBLEManager.CaptureDefaults.configured)
        // Workout focus pins the duty cycle to full capture; other modes clear
        // the override (sleep hours are already full-rate via the sleep window).
        defaults.set(mode == .workout, forKey: AtriaBLEManager.DutyCycleDefaults.focusFullCapture)
        switch mode {
        case .off:
            defaults.set(false, forKey: AtriaBLEManager.LongWearDefaults.enabled)
            defaults.set(false, forKey: AtriaBLEManager.RadioDefaults.standardHROnly)
            defaults.set(true, forKey: AtriaBLEManager.LongWearDefaults.userSelected)
            defaults.set("focus_off", forKey: AtriaBLEManager.RadioDefaults.lastReason)
        case .workout:
            defaults.set(true, forKey: AtriaBLEManager.LongWearDefaults.enabled)
            defaults.set(true, forKey: AtriaBLEManager.RadioDefaults.standardHROnly)
            defaults.set(true, forKey: AtriaBLEManager.LongWearDefaults.userSelected)
            defaults.set("Workout Focus", forKey: AtriaBLEManager.LongWearDefaults.label)
            defaults.set(AtriaBLEManager.CollectionProfile.maxCoverage.rawValue,
                         forKey: AtriaBLEManager.CollectionProfileDefaults.profile)
            defaults.set("focus_workout", forKey: AtriaBLEManager.RadioDefaults.lastReason)
        case .sleep:
            defaults.set(true, forKey: AtriaBLEManager.LongWearDefaults.enabled)
            defaults.set(true, forKey: AtriaBLEManager.RadioDefaults.standardHROnly)
            defaults.set(true, forKey: AtriaBLEManager.LongWearDefaults.userSelected)
            defaults.set("Sleep Focus", forKey: AtriaBLEManager.LongWearDefaults.label)
            defaults.set(AtriaBLEManager.CollectionProfile.batterySaver.rawValue,
                         forKey: AtriaBLEManager.CollectionProfileDefaults.profile)
            defaults.set("focus_sleep", forKey: AtriaBLEManager.RadioDefaults.lastReason)
        }
    }
}

// Not private: the launch time-to-content cold-start seed (AtriaHomeModel,
// AtriaHomeView.swift) reads the last-known widget snapshot synchronously at
// init so the first frame can show real last-known numbers instead of a
// placeholder while the session decode is still in flight.
enum AtriaIntentSnapshotStore {
    private static let key = "atria.widgetSnapshot.v1"
    private static let appGroupID = "group.com.adidshaft.atria"

    static func loadLatestSnapshot() -> WidgetSnapshot? {
        guard FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) != nil,
              let defaults = UserDefaults(suiteName: appGroupID),
              let data = defaults.data(forKey: key) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(WidgetSnapshot.self, from: data) else {
            return nil
        }
        // Handoff-10 CP1: past the display-day identity expiry this snapshot
        // may no longer answer for "today" — fail closed to the learning
        // dialog instead of re-wearing a prior day's values after relaunch.
        guard snapshotAnswersForCurrentDay(
            createdAt: snapshot.createdAt,
            displayCivilDayKey: snapshot.displayCivilDayKey,
            displayTimeZoneIdentifier: snapshot.displayTimeZoneIdentifier,
            recoveryExpiresAt: snapshot.recoveryExpiresAt,
            biomarkerExpiresAt: snapshot.biomarkerExpiresAt,
            strainExpiresAt: snapshot.strainCycleExpiresAt
        ) else { return nil }
        return snapshot
    }

    /// Pure display-day identity check. Legacy payloads remain decodable but
    /// only answer while their own creation clock is on the current local day.
    static func snapshotAnswersForCurrentDay(
        createdAt: Date,
        displayCivilDayKey: String?,
        displayTimeZoneIdentifier: String? = nil,
        recoveryExpiresAt: Date?,
        biomarkerExpiresAt: Date? = nil,
        strainExpiresAt: Date? = nil,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        let currentDayKey = WidgetSnapshotPublisher.civilDayKey(
            for: now,
            calendar: calendar
        )
        let timeZoneMatches = displayTimeZoneIdentifier.map {
            $0 == calendar.timeZone.identifier
        } ?? true
        let dayMatches = (displayCivilDayKey.map { $0 == currentDayKey }
            ?? calendar.isDate(createdAt, inSameDayAs: now)) && timeZoneMatches
        guard dayMatches else { return false }
        return [recoveryExpiresAt, biomarkerExpiresAt, strainExpiresAt]
            .compactMap { $0 }
            .allSatisfy { now < $0 }
    }
}

enum AtriaIntentMetricPresentation {
    nonisolated static func recoverySpoken(
        percent: Int?,
        confidence: String
    ) -> String {
        guard let percent else { return "learning" }
        return confidence == Metrics.RecoveryEstimate.Confidence.unverified.rawValue
            ? "\(percent) percent, early estimate"
            : "\(percent) percent"
    }

    nonisolated static func recoveryCompact(
        percent: Int?,
        confidence: String
    ) -> String {
        guard let percent else { return "--" }
        return confidence == Metrics.RecoveryEstimate.Confidence.unverified.rawValue
            ? "~\(percent)%" : "\(percent)%"
    }

    nonisolated static func strainSpoken(
        value: Double,
        detail: String?,
        appRenderedValueText: String? = nil
    ) -> String {
        // 2026-08-20 (widget-sync RC4, §13.6 pre-render): prefer the exact
        // string the in-app hero rendered. "≥" is unspeakable, so the spoken
        // surface translates the lower-bound qualifier without re-deriving
        // the number; the derivation below stays as legacy fallback.
        if let appRenderedValueText {
            if appRenderedValueText.hasPrefix("≥") {
                let numeric = appRenderedValueText.dropFirst()
                    .trimmingCharacters(in: .whitespaces)
                return "at least \(numeric)"
            }
            return appRenderedValueText
        }
        let numeric = String(format: "%.1f", value)
        return detail?.localizedCaseInsensitiveContains("partial") == true
            ? "at least \(numeric)" : numeric
    }

    nonisolated static func strainCompact(
        value: Double,
        detail: String?,
        appRenderedValueText: String? = nil
    ) -> String {
        // 2026-08-20 (widget-sync RC4): the compact stat shows the app-
        // rendered value verbatim when the snapshot carries one.
        if let appRenderedValueText { return appRenderedValueText }
        let numeric = String(format: "%.1f", value)
        return detail?.localizedCaseInsensitiveContains("partial") == true
            ? "≥ \(numeric)" : numeric
    }
}

private extension AtriaIntentDestination {
    var dialogName: String {
        switch self {
        case .today: return "Today"
        case .vitals: return "Vitals"
        case .journal: return "Journal"
        case .collection: return "Strap"
        }
    }
}

private extension AtriaCaptureCommand {
    var dialogVerb: String {
        switch self {
        case .start: return "Starting"
        case .stop: return "Stopping"
        }
    }
}

private extension AtriaFocusMode {
    var dialogVerb: String {
        switch self {
        case .off: return "Leaving"
        case .workout: return "Starting workout"
        case .sleep: return "Arming sleep"
        }
    }
}
