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
            .collection: "Collection"
        ]
    }
}

enum AtriaCaptureCommand: String, AppEnum, Codable {
    case start
    case stop

    static var typeDisplayName: LocalizedStringResource { "Capture command" }
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Capture command"

    static var caseDisplayRepresentations: [Self: DisplayRepresentation] {
        [
            .start: "Start",
            .stop: "Stop"
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

struct AtriaCaptureIntent: AppIntent {
    static let title: LocalizedStringResource = "Control Atria capture"
    static let description = IntentDescription("Start or stop Atria's local capture when the app opens.")
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
        return .result(dialog: "\(command.dialogVerb) Atria capture.")
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
                "Start capture in \(.applicationName)",
                "Start Atria session with \(.applicationName)"
            ],
            shortTitle: "Start capture",
            systemImageName: "record.circle"
        )

        AppShortcut(
            intent: AtriaCaptureIntent(command: .stop),
            phrases: [
                "Stop capture in \(.applicationName)",
                "Stop Atria session with \(.applicationName)"
            ],
            shortTitle: "Stop capture",
            systemImageName: "stop.circle"
        )
    }
}

enum AtriaIntentCommand: Codable, Equatable {
    case open(AtriaIntentDestination)
    case capture(AtriaCaptureCommand)
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
        case .collection: return "Collection"
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
