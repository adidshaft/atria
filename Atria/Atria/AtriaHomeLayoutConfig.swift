import Foundation

struct AtriaHomeLayoutConfig: Codable, Equatable {
    enum RingCenterMetric: String, Codable, CaseIterable {
        case recovery
        case sleep
        case strain
    }

    enum LegendStatStyle: String, Codable, CaseIterable {
        case value
        case valueAndState
    }

    enum Accent: String, Codable, CaseIterable {
        case atria
        case mint
        case cyan
        case coral
        case violet
    }

    static let storageKey = "atria.home.layout.v1"
    static let maxTodayCards = 8

    var glanceMetrics: [String]
    var sizeOverrides: [String: String]
    var showLiveStrip: Bool
    var showHighlights: Bool
    var showPlan: Bool
    var showAICoach: Bool
    var ringCenterMetric: RingCenterMetric
    var legendStatStyle: LegendStatStyle
    var accent: Accent

    static var `default`: AtriaHomeLayoutConfig {
        AtriaHomeLayoutConfig(glanceMetrics: ["recovery", "strain", "sleep", "hrv", "rhr", "steps"],
                              sizeOverrides: [:],
                              showLiveStrip: true,
                              showHighlights: true,
                              showPlan: true,
                              showAICoach: true,
                              ringCenterMetric: .recovery,
                              legendStatStyle: .valueAndState,
                              accent: .atria)
    }

    func validated(allowedMetricKeys: [String] = AtriaHomeLayoutCatalog.metricKeys,
                   allowedSizeValues: Set<String> = AtriaHomeLayoutCatalog.sizeValues) -> AtriaHomeLayoutConfig {
        let allowed = Set(allowedMetricKeys)
        var seen = Set<String>()
        let metrics = glanceMetrics.compactMap { key -> String? in
            guard allowed.contains(key), !seen.contains(key) else { return nil }
            seen.insert(key)
            return key
        }
        let sizes = sizeOverrides.filter { key, value in
            allowed.contains(key) && allowedSizeValues.contains(value)
        }
        return AtriaHomeLayoutConfig(glanceMetrics: Array(metrics.prefix(Self.maxTodayCards)),
                                     sizeOverrides: sizes,
                                     showLiveStrip: showLiveStrip,
                                     showHighlights: showHighlights,
                                     showPlan: showPlan,
                                     showAICoach: showAICoach,
                                     ringCenterMetric: ringCenterMetric,
                                     legendStatStyle: legendStatStyle,
                                     accent: accent)
    }

    func encodedData(encoder: JSONEncoder = AtriaHomeLayoutCatalog.encoder()) throws -> Data {
        try encoder.encode(validated())
    }

    static func decoded(from data: Data,
                        decoder: JSONDecoder = JSONDecoder()) throws -> AtriaHomeLayoutConfig {
        try decoder.decode(AtriaHomeLayoutConfig.self, from: data).validated()
    }

    static func resetData(encoder: JSONEncoder = AtriaHomeLayoutCatalog.encoder()) throws -> Data {
        try AtriaHomeLayoutConfig.default.validated().encodedData(encoder: encoder)
    }
}

enum AtriaHomeLayoutCatalog {
    static let metricKeys = [
        "recovery",
        "strain",
        "load",
        "hrv",
        "stress",
        "sleep",
        "sleepHistory",
        "sleepEfficiency",
        "rhr",
        "respiratoryRate",
        "steps",
        "calories",
        "vo2max",
        "bioAge",
        "bloodOxygen",
        "bodyTemp",
        "trend",
        "insights"
    ]

    static let sizeValues: Set<String> = ["compact", "wide", "wideShort"]

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
