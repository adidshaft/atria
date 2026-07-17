import Foundation

enum AtriaDeveloperMode {
    static let defaultsKey = "atria.developerMode.enabled"
    static let expiryDefaultsKey = "atria.developerMode.expiresAt"
    static let launchArgument = "--atria-developer-mode"
    static let leaseDuration: TimeInterval = 7 * 24 * 60 * 60

    static var isEnabled: Bool {
        isEnabled(arguments: ProcessInfo.processInfo.arguments,
                  defaults: .standard,
                  now: Date())
    }

    // 2026-07-18: CoreBluetooth may restore the app without launch arguments.
    // Persist a dated lease so developer tools survive that honest relaunch,
    // while still expiring automatically instead of becoming a hidden setting.
    static func isEnabled(arguments: [String],
                          defaults: UserDefaults,
                          now: Date) -> Bool {
        if arguments.contains(launchArgument) {
            defaults.set(true, forKey: defaultsKey)
            defaults.set(now.addingTimeInterval(leaseDuration), forKey: expiryDefaultsKey)
            return true
        }

        guard defaults.bool(forKey: defaultsKey),
              let expiresAt = defaults.object(forKey: expiryDefaultsKey) as? Date,
              expiresAt > now else {
            disable(defaults: defaults)
            return false
        }
        return true
    }

    static func disable(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
        defaults.removeObject(forKey: expiryDefaultsKey)
    }
}
