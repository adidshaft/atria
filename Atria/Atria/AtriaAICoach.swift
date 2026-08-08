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
    let stressMetricTitle: String
    let stressEvidenceMode: AtriaStressEvidenceMode?
    let baselineSamples: Int
    let sessionsCount: Int

    init(guidance: Coach.Guidance,
         strain: Double,
         recoveryText: String,
         hrvText: String,
         stressText: String,
         stressMetricTitle: String = "Stress",
         stressEvidenceMode: AtriaStressEvidenceMode? = nil,
         baselineSamples: Int,
         sessionsCount: Int) {
        self.guidance = guidance
        self.strain = strain
        self.recoveryText = recoveryText
        self.hrvText = hrvText
        self.stressText = stressText
        self.stressMetricTitle = stressMetricTitle
        self.stressEvidenceMode = stressEvidenceMode
        self.baselineSamples = baselineSamples
        self.sessionsCount = sessionsCount
    }
}

/// One wording policy for local coaching. HR-only evidence remains useful, but
/// it must never enter an insight sentence under the physiological Stress name.
enum AtriaCoachStressPresentation {
    static func clause(context: AtriaCoachContext) -> String {
        let title = context.stressMetricTitle
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = title.isEmpty ? "Stress" : title
        switch context.stressEvidenceMode {
        case .cardiacArousal:
            return "Cardiac arousal \(context.stressText) (HR only; not a numeric Stress score)"
        case .physiologicalStress, nil:
            return "\(resolvedTitle) \(context.stressText)"
        }
    }
}

struct AtriaCoachPayload: Codable, Equatable {
    struct VitalRange: Codable, Equatable {
        let low: Double?
        let high: Double?
    }

    struct DailyMetrics: Codable, Equatable {
        let day: Date
        let tzOffsetMinutes: Int
        let recovery: Int?
        let lnRMSSD: Double?
        let rhr: Int?
        let sleepSeconds: TimeInterval?
        let sleepPerformance: Int?
        let bedtimeMinutes: Int?
        let strain: Double?
        let respiratoryRate: Double?
        let vitals: DailyRollupVitals?
        let nutrition: AtriaNutritionSummary?
        let fitnessAgeDelta: Int?

        init(_ entry: DailyRollupStoreEntry) {
            day = entry.day
            tzOffsetMinutes = entry.tzOffsetMinutes
            recovery = entry.recovery
            lnRMSSD = entry.lnRMSSD
            rhr = entry.rhr
            sleepSeconds = entry.sleepSeconds
            sleepPerformance = entry.sleepPerformance
            bedtimeMinutes = entry.bedtimeMinutes
            strain = entry.strain
            respiratoryRate = entry.respiratoryRate
            vitals = entry.vitals
            nutrition = entry.nutrition
            fitnessAgeDelta = entry.fitnessAgeDelta
        }
    }

    let today: DailyMetrics?
    let last7: [DailyMetrics]
    let now: String
    let weekday: String
    let units: String
    let baselines: [String: VitalRange]

    init(today: DailyRollupStoreEntry?,
         last7: [DailyRollupStoreEntry],
         now: String,
         weekday: String,
         units: String,
         baselines: [String: VitalRange]) {
        self.today = today.map(DailyMetrics.init)
        self.last7 = last7.map(DailyMetrics.init)
        self.now = now
        self.weekday = weekday
        self.units = units
        self.baselines = baselines
    }

    private init(sanitizedToday: DailyMetrics?,
                 sanitizedLast7: [DailyMetrics],
                 now: String,
                 weekday: String,
                 units: String,
                 baselines: [String: VitalRange]) {
        today = sanitizedToday
        last7 = sanitizedLast7
        self.now = now
        self.weekday = weekday
        self.units = units
        self.baselines = baselines
    }

    static let systemPrompt = "Answer ONLY from DATA. If a value is not in DATA, say you don't have it — never estimate, never use population numbers as if personal. Today is {now}."

    var receiptSummary: String {
        guard let today else { return "Based on: no daily rollup yet" }
        var parts = [Self.formattedDay(today.day)]
        if let recovery = today.recovery {
            parts.append("Recovery \(recovery) %")
        }
        if let sleepSeconds = today.sleepSeconds {
            parts.append("Sleep \(Self.formatSleep(sleepSeconds))")
        }
        if let lnRMSSD = today.lnRMSSD {
            parts.append("HRV \(Int(exp(lnRMSSD).rounded()))")
        }
        if let rhr = today.rhr {
            parts.append("RHR \(rhr)")
        }
        return "Based on: \(parts.joined(separator: " · "))"
    }

    var auditLines: [String] {
        var lines = [
            "Now: \(now)",
            "Weekday: \(weekday)",
            "Units: \(units)",
            "Days sent: \(last7.count)"
        ]
        if let today {
            lines.append("Today: \(Self.formattedDay(today.day))")
            if let recovery = today.recovery { lines.append("Recovery: \(recovery) %") }
            if let sleepSeconds = today.sleepSeconds { lines.append("Sleep: \(Self.formatSleep(sleepSeconds))") }
            if let lnRMSSD = today.lnRMSSD { lines.append("HRV: \(Int(exp(lnRMSSD).rounded())) ms") }
            if let rhr = today.rhr { lines.append("RHR: \(rhr) bpm") }
            if let strain = today.strain { lines.append("Strain: \(String(format: "%.1f", strain))") }
            if let nutrition = today.nutrition, let fuelSummary = nutrition.fuelSummary {
                lines.append("Nutrition: \(fuelSummary)")
            }
        } else {
            lines.append("Today: no daily rollup")
        }
        for key in baselines.keys.sorted() {
            let range = baselines[key]
            let low = range?.low.map { String(format: "%.1f", $0) } ?? "--"
            let high = range?.high.map { String(format: "%.1f", $0) } ?? "--"
            lines.append("Baseline \(key): \(low)...\(high)")
        }
        return lines
    }

    var serializedNumbers: [Double] {
        var numbers: [Double] = []
        if let data = try? JSONEncoder().encode(self),
           let text = String(data: data, encoding: .utf8) {
            numbers.append(contentsOf: Self.numberTokens(in: text).map(\.value))
        }
        if let today {
            if let recovery = today.recovery { numbers.append(Double(recovery)) }
            if let rhr = today.rhr { numbers.append(Double(rhr)) }
            if let lnRMSSD = today.lnRMSSD { numbers.append(exp(lnRMSSD)) }
            if let strain = today.strain { numbers.append(strain) }
            if let sleepSeconds = today.sleepSeconds {
                numbers.append(sleepSeconds / 3600)
                numbers.append(sleepSeconds / 60)
            }
            if let nutrition = today.nutrition {
                numbers.append(contentsOf: [
                    nutrition.kcal,
                    nutrition.proteinG,
                    nutrition.carbsG,
                    nutrition.fatG,
                    nutrition.waterMl,
                    nutrition.caffeineMg,
                    nutrition.alcoholDrinks.map { Double($0) }
                ].compactMap { $0 })
            }
        }
        return numbers
    }

    static func legacy(context: AtriaCoachContext,
                       now: Date = Date(),
                       calendar: Calendar = .current) -> AtriaCoachPayload {
        let day = calendar.startOfDay(for: now)
        let recovery = integer(from: context.recoveryText)
        let hrv = integer(from: context.hrvText)
        let today = DailyRollupStoreEntry(day: day,
                                          recovery: recovery,
                                          lnRMSSD: hrv.map { log(Double(max($0, 1))) },
                                          strain: context.strain,
                                          calendar: calendar)
        return AtriaCoachPayload(today: today,
                                 last7: [today],
                                 now: ISO8601DateFormatter().string(from: now),
                                 weekday: DateFormatter.localizedString(from: now, dateStyle: .full, timeStyle: .none),
                                 units: Locale.current.measurementSystem == .metric ? "metric" : "imperial",
                                 baselines: [
                                    "recovery": VitalRange(low: 0, high: 100),
                                    "strain": VitalRange(low: 0, high: 21)
                                 ])
    }

    static func fromRollups(rollups: [DailyRollupStoreEntry],
                            fallback context: AtriaCoachContext,
                            now: Date = Date(),
                            calendar: Calendar = .current,
                            timeZone: TimeZone = .current,
                            units: String = Locale.current.measurementSystem == .metric ? "metric" : "imperial",
                            baselines: [String: VitalRange]) -> AtriaCoachPayload {
        let sanitized = rollups
            .sorted { $0.day > $1.day }
            .map(DailyMetrics.init)
        let today = sanitized.first ?? legacy(context: context, now: now, calendar: calendar).today
        let last7: [DailyMetrics]
        if sanitized.isEmpty, let today {
            last7 = [today]
        } else {
            last7 = Array(sanitized.prefix(7))
        }
        return AtriaCoachPayload(sanitizedToday: today,
                                 sanitizedLast7: last7,
                                 now: localISO8601(now, timeZone: timeZone),
                                 weekday: weekdayString(now, calendar: calendar, timeZone: timeZone),
                                 units: units,
                                 baselines: baselines)
    }

    static func fabricationFlags(response: String, payload: AtriaCoachPayload) -> [String] {
        let allowed = payload.serializedNumbers.map { round($0 * 10) / 10 }
        return numberTokens(in: response).compactMap { token in
            guard !allowed.contains(where: { abs($0 - token.value) <= 1.0 }) else { return nil }
            return token.raw
        }
    }

    private static func integer(from text: String) -> Int? {
        numberTokens(in: text).first.map { Int($0.value.rounded()) }
    }

    private static func numberTokens(in text: String) -> [(raw: String, value: Double)] {
        let pattern = #"([0-9]+(?:\.[0-9]+)?)\s?(%|percent|bpm|ms|kcal|steps?|kg|lbs?|h(?:ours?)?|min(?:utes?)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let nsText = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)).compactMap { match in
            guard match.numberOfRanges >= 3,
                  let value = Double(nsText.substring(with: match.range(at: 1))) else {
                return nil
            }
            return (nsText.substring(with: match.range(at: 0)), value)
        }
    }

    private static func formattedDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter.string(from: date)
    }

    private static func localISO8601(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withTimeZone]
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }

    private static func weekdayString(_ date: Date, calendar: Calendar, timeZone: TimeZone = .current) -> String {
        var calendar = calendar
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.setLocalizedDateFormatFromTemplate("EEEE")
        return formatter.string(from: date)
    }

    private static func formatSleep(_ seconds: TimeInterval) -> String {
        let totalMinutes = max(0, Int((seconds / 60).rounded()))
        return "\(totalMinutes / 60):\(String(format: "%02d", totalMinutes % 60))"
    }
}

protocol AtriaCoachProvider {
    var networkPolicy: AtriaCoachNetworkPolicy { get }
    func answer(payload: AtriaCoachPayload, context: AtriaCoachContext) async -> AtriaCoachAnswer
}

enum AtriaCoachNetworkPolicy: String, Equatable {
    case none
    case offlineOnly
    case cloudDisabled
}

struct AtriaCoachAnswer: Equatable {
    let title: String
    let detail: String
    let disclosure: String
    let networkPolicy: AtriaCoachNetworkPolicy
}

struct AtriaLocalCoachProvider: AtriaCoachProvider {
    let networkPolicy: AtriaCoachNetworkPolicy = .offlineOnly

    func answer(payload: AtriaCoachPayload, context: AtriaCoachContext) async -> AtriaCoachAnswer {
        let target = context.guidance.target.map { String(format: "%.1f", $0) } ?? "learning"
        let stressClause = AtriaCoachStressPresentation.clause(context: context)
        var detail = "Today: strain \(String(format: "%.1f", context.strain)) vs target \(target). Recovery \(context.recoveryText), HRV \(context.hrvText), \(stressClause). \(context.guidance.detail)"
        // Cycle tracking is opt-in and off by default (AtriaCycleTracking.swift);
        // this line only appears when the user enabled it AND a phase estimate
        // exists, and is always labeled "Cycle estimate" — never presented as a
        // diagnosed fact.
        if let cycleLine = AtriaCycleTracking.coachGuidanceLine() {
            detail += " \(cycleLine)"
        }
        return AtriaCoachAnswer(
            title: context.guidance.headline,
            detail: detail,
            disclosure: "\(payload.receiptSummary). Local mode uses only on-device Atria metrics. No data leaves this iPhone.",
            networkPolicy: networkPolicy
        )
    }
}

struct AtriaCloudCoachProvider: AtriaCoachProvider {
    let provider: AtriaAICoachSettings.CloudProvider
    let hasAPIKey: Bool
    let networkPolicy: AtriaCoachNetworkPolicy = .cloudDisabled

    func answer(payload: AtriaCoachPayload, context: AtriaCoachContext) async -> AtriaCoachAnswer {
        guard hasAPIKey else {
            return AtriaCoachAnswer(
                title: "Cloud coach disabled",
                detail: "Paste your own \(provider.title) API key before cloud answers can run.",
                disclosure: "Cloud mode is opt-in. Atria will not send data until a reviewed provider client is added.",
                networkPolicy: networkPolicy
            )
        }
        let preview = AtriaCoachProviderRequestBuilder.requestPreview(provider: provider,
                                                                      payload: payload)
        return AtriaCoachAnswer(
            title: "\(provider.title) request preview ready",
            detail: "\(preview.summary). \(preview.promptLine). Network requests stay disabled until a reviewed provider client is added.",
            disclosure: "No cloud request was sent. \(preview.payloadLine)",
            networkPolicy: networkPolicy
        )
    }
}

enum AtriaCoachProviderRequestBuilder {
    struct RequestPreview: Equatable {
        let summary: String
        let promptLine: String
        let payloadLine: String
    }

    static func systemPrompt(for payload: AtriaCoachPayload) -> String {
        AtriaCoachPayload.systemPrompt.replacingOccurrences(of: "{now}", with: payload.now)
    }

    static func payloadJSON(_ payload: AtriaCoachPayload) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(payload)
        return String(decoding: data, as: UTF8.self)
    }

    static func requestBody(provider: AtriaAICoachSettings.CloudProvider,
                            model: String,
                            payload: AtriaCoachPayload,
                            maxTokens: Int = 600) throws -> Data {
        switch provider {
        case .openAI:
            return try openAIResponsesBody(model: model, payload: payload, maxTokens: maxTokens)
        case .claude:
            return try claudeMessagesBody(model: model, payload: payload, maxTokens: maxTokens)
        }
    }

    static func requestPreview(provider: AtriaAICoachSettings.CloudProvider,
                               payload: AtriaCoachPayload,
                               maxTokens: Int = 600) -> RequestPreview {
        let model = defaultModel(for: provider)
        let bodyBytes = (try? requestBody(provider: provider,
                                          model: model,
                                          payload: payload,
                                          maxTokens: maxTokens).count) ?? 0
        let prompt = systemPrompt(for: payload)
        return RequestPreview(summary: "\(provider.title) body prepared for \(model), \(bodyBytes) bytes, \(maxTokens) token cap",
                              promptLine: "Prompt pinned: \(prompt)",
                              payloadLine: payload.receiptSummary)
    }

    static func defaultModel(for provider: AtriaAICoachSettings.CloudProvider) -> String {
        switch provider {
        case .openAI: return "gpt-4.1-mini"
        case .claude: return "claude-3-5-haiku-latest"
        }
    }

    private static func openAIResponsesBody(model: String,
                                            payload: AtriaCoachPayload,
                                            maxTokens: Int) throws -> Data {
        let body = OpenAIResponsesBody(model: model,
                                       instructions: systemPrompt(for: payload),
                                       input: [
                                        OpenAIInput(role: "user",
                                                    content: [
                                                        OpenAIContent(type: "input_text",
                                                                      text: try userMessageText(payload: payload))
                                                    ])
                                       ],
                                       maxOutputTokens: maxTokens)
        return try encode(body)
    }

    private static func claudeMessagesBody(model: String,
                                           payload: AtriaCoachPayload,
                                           maxTokens: Int) throws -> Data {
        let body = ClaudeMessagesBody(model: model,
                                      maxTokens: maxTokens,
                                      system: systemPrompt(for: payload),
                                      messages: [
                                        ClaudeMessage(role: "user",
                                                      content: [
                                                        ClaudeContent(type: "text",
                                                                      text: try userMessageText(payload: payload))
                                                      ])
                                      ])
        return try encode(body)
    }

    private static func userMessageText(payload: AtriaCoachPayload) throws -> String {
        "DATA:\n\(try payloadJSON(payload))"
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private struct OpenAIResponsesBody: Encodable {
        let model: String
        let instructions: String
        let input: [OpenAIInput]
        let maxOutputTokens: Int

        enum CodingKeys: String, CodingKey {
            case model
            case instructions
            case input
            case maxOutputTokens = "max_output_tokens"
        }
    }

    private struct OpenAIInput: Encodable {
        let role: String
        let content: [OpenAIContent]
    }

    private struct OpenAIContent: Encodable {
        let type: String
        let text: String
    }

    private struct ClaudeMessagesBody: Encodable {
        let model: String
        let maxTokens: Int
        let system: String
        let messages: [ClaudeMessage]

        enum CodingKeys: String, CodingKey {
            case model
            case maxTokens = "max_tokens"
            case system
            case messages
        }
    }

    private struct ClaudeMessage: Encodable {
        let role: String
        let content: [ClaudeContent]
    }

    private struct ClaudeContent: Encodable {
        let type: String
        let text: String
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
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
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
