import Foundation
import Security

struct AtriaAICoachSettings: Codable, Equatable {
    enum Mode: String, Codable, CaseIterable {
        case off
        case local
        case cloud

        var title: String {
            switch self {
            case .off: return "Off"
            case .local: return "Local"
            case .cloud: return "Cloud"
            }
        }
    }

    enum CloudProvider: String, Codable, CaseIterable {
        case openAI
        case claude

        var title: String {
            switch self {
            case .openAI: return "OpenAI"
            case .claude: return "Claude"
            }
        }
    }

    var mode: Mode = .off
    var cloudProvider: CloudProvider = .openAI
    var localModelEnabled = false

    private static let key = "atria.aiCoach.settings.v1"

    static func load() -> AtriaAICoachSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode(AtriaAICoachSettings.self, from: data) else {
            return AtriaAICoachSettings()
        }
        return decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}

struct AtriaCoachContext: Equatable {
    let guidance: Coach.Guidance
    let strain: Double
    let recoveryText: String
    let hrvText: String
    let stressText: String
    let baselineSamples: Int
    let sessionsCount: Int
}

protocol AtriaCoachProvider {
    func answer(context: AtriaCoachContext) async -> AtriaCoachAnswer
}

struct AtriaCoachAnswer: Equatable {
    let title: String
    let detail: String
    let disclosure: String
}

struct AtriaLocalCoachProvider: AtriaCoachProvider {
    func answer(context: AtriaCoachContext) async -> AtriaCoachAnswer {
        let target = context.guidance.target.map { String(format: "%.1f", $0) } ?? "learning"
        return AtriaCoachAnswer(
            title: context.guidance.headline,
            detail: "Today: strain \(String(format: "%.1f", context.strain)) vs target \(target). Recovery \(context.recoveryText), HRV \(context.hrvText), stress \(context.stressText). \(context.guidance.detail)",
            disclosure: "Local mode uses only on-device Atria metrics. No data leaves this iPhone."
        )
    }
}

struct AtriaCloudCoachProvider: AtriaCoachProvider {
    let provider: AtriaAICoachSettings.CloudProvider
    let hasAPIKey: Bool

    func answer(context: AtriaCoachContext) async -> AtriaCoachAnswer {
        guard hasAPIKey else {
            return AtriaCoachAnswer(
                title: "Cloud coach disabled",
                detail: "Paste your own \(provider.title) API key before cloud answers can run.",
                disclosure: "Cloud mode is opt-in. When enabled, Atria will send selected local metrics to \(provider.title)."
            )
        }
        return AtriaCoachAnswer(
            title: "\(provider.title) coach ready",
            detail: "The provider seam and secure key storage are ready. Network requests stay disabled until a reviewed provider client is added.",
            disclosure: "No cloud request was sent from this build."
        )
    }
}

enum AtriaCoachProviderFactory {
    static func make(settings: AtriaAICoachSettings, hasAPIKey: Bool) -> AtriaCoachProvider? {
        switch settings.mode {
        case .off:
            return nil
        case .local:
            return AtriaLocalCoachProvider()
        case .cloud:
            return AtriaCloudCoachProvider(provider: settings.cloudProvider, hasAPIKey: hasAPIKey)
        }
    }
}

enum AtriaCoachKeychain {
    private static let service = "com.adidshaft.atria.aiCoach"

    static func saveAPIKey(_ key: String, provider: AtriaAICoachSettings.CloudProvider) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return }
        deleteAPIKey(provider: provider)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
            kSecValueData as String: data
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func hasAPIKey(provider: AtriaAICoachSettings.CloudProvider) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
            kSecReturnData as String: false,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    static func deleteAPIKey(provider: AtriaAICoachSettings.CloudProvider) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue
        ]
        SecItemDelete(query as CFDictionary)
    }
}
