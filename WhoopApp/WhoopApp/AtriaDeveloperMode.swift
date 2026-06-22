import Foundation

enum AtriaDeveloperMode {
    static let defaultsKey = "atria.developerMode.enabled"
    static let launchArgument = "--atria-developer-mode"

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
        || UserDefaults.standard.bool(forKey: defaultsKey)
    }
}
