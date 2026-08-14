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
    // Custom layouts can expose the full catalog; the default remains focused
    // enough to scan without turning Today into a second Vitals screen.
    static let maxTodayCards = 14

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
        // Assessment P0.2 (2026-08-14): Fitness age is a compact local
        // approximation and must not ship in the DEFAULT glance deck —
        // measured metrics lead the morning. Users can still add the tile
        // from Customize; existing saved layouts are untouched.
        AtriaHomeLayoutConfig(glanceMetrics: ["hrv", "rhr", "stress", "steps", "hrZones", "workouts", "sleepEfficiency"],
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

    /// Reorders presentation keys only. Metric values and their live stores are
    /// never moved or copied; the persisted layout continues to reference each
    /// card by its stable catalog identifier.
    mutating func moveGlanceMetric(_ draggedKey: String, before targetKey: String) {
        var keys = validated().glanceMetrics
        guard draggedKey != targetKey,
              let draggedIndex = keys.firstIndex(of: draggedKey),
              keys.contains(targetKey) else { return }
        keys.remove(at: draggedIndex)
        guard let targetIndex = keys.firstIndex(of: targetKey) else { return }
        keys.insert(draggedKey, at: targetIndex)
        glanceMetrics = keys
    }

    /// VoiceOver counterpart to drag/drop. Boundary moves deliberately leave
    /// the order unchanged so
    /// repeated accessibility actions cannot corrupt or wrap the saved order.
    mutating func shiftGlanceMetric(_ key: String, direction: Int) {
        var keys = validated().glanceMetrics
        guard let index = keys.firstIndex(of: key) else { return }
        let destination = index + direction
        guard keys.indices.contains(destination) else { return }
        keys.swapAt(index, destination)
        glanceMetrics = keys
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
        "sleepPerformance",
        "rhr",
        "respiratoryRate",
        "steps",
        "hrZones",
        "workouts",
        "strainCompare",
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
