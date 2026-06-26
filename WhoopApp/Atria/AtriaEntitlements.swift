import SwiftUI

/// Single seam for future premium licensing without shipping a paywall today.
struct AtriaEntitlements: Equatable {
    enum Feature: String, CaseIterable {
        case localMetrics
        case healthKitExport
        case backgroundCollection
        case liveActivity
        case mediaControls
        case hapticAlerts
        case aiCoachLocal
        case aiCoachCloud
    }

    enum Tier: String, Codable {
        case paidApp
        case premium
    }

    var tier: Tier = .paidApp
    var premiumOverrides: Set<Feature> = []

    func isEnabled(_ feature: Feature) -> Bool {
        switch feature {
        case .localMetrics,
             .healthKitExport,
             .backgroundCollection,
             .liveActivity,
             .mediaControls,
             .hapticAlerts,
             .aiCoachLocal,
             .aiCoachCloud:
            return true
        }
    }
}

private struct AtriaEntitlementsKey: EnvironmentKey {
    static let defaultValue = AtriaEntitlements()
}

extension EnvironmentValues {
    var atriaEntitlements: AtriaEntitlements {
        get { self[AtriaEntitlementsKey.self] }
        set { self[AtriaEntitlementsKey.self] = newValue }
    }
}
