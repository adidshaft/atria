import AppIntents
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
