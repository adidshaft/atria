import AppIntents
import Foundation

enum AtriaIntentDestination: String, AppEnum, Codable {
    case today
    case vitals
    case collection

    static var typeDisplayName: LocalizedStringResource { "Atria destination" }
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Atria destination"

    static var caseDisplayRepresentations: [Self: DisplayRepresentation] {
        [
            .today: "Today",
            .vitals: "Vitals",
            .collection: "Data"
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

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let snapshot = AtriaIntentSnapshotStore.loadLatestSnapshot() else {
            return .result(dialog: "Atria is still learning. Open the app once to refresh the local snapshot.")
        }

        let recovery = snapshot.recoveryPercent.map { "\($0) percent" } ?? "learning"
        let hrv = snapshot.hrvRMSSD.map { "\($0) milliseconds" } ?? snapshot.hrvState
        let strain = String(format: "%.1f", snapshot.strain)
        return .result(dialog: "Recovery is \(recovery), strain is \(strain), and HRV is \(hrv).")
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

private enum AtriaIntentSnapshotStore {
    private static let key = "atria.widgetSnapshot.v1"
    private static let appGroupID = "group.com.adidshaft.atria"

    static func loadLatestSnapshot() -> WidgetSnapshot? {
        let defaults = UserDefaults(suiteName: appGroupID) ?? .standard
        guard let data = defaults.data(forKey: key) ?? UserDefaults.standard.data(forKey: key) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }
}

private extension AtriaIntentDestination {
    var dialogName: String {
        switch self {
        case .today: return "Today"
        case .vitals: return "Vitals"
        case .collection: return "Data"
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
