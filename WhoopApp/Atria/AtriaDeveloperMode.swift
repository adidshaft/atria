import Foundation

enum AtriaDeveloperMode {
    static let defaultsKey = "atria.developerMode.enabled"
    static let launchArgument = "--atria-developer-mode"

    static var isEnabled: Bool {
        let enabledByLaunchArgument = ProcessInfo.processInfo.arguments.contains(launchArgument)
        if !enabledByLaunchArgument, UserDefaults.standard.bool(forKey: defaultsKey) {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        }
        return enabledByLaunchArgument
    }
}
