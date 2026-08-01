import Foundation

/// Shared persistence for the onboarding personalization/consent pages added in
/// design-parity slice 6 (2026-08-01). Every helper here writes through the
/// EXACT same real backing store the rest of the app already reads, so an
/// onboarding choice is never a cosmetic preview — it takes effect immediately:
///
///   • nickname     -> "atria.user.nickname"            (AtriaTodayScreen greeting)
///   • ring slots   -> "atria.today.ringMetrics"        (AtriaTodayScreen tri-ring order)
///   • ring center  -> AtriaHomeLayoutConfig.storageKey  (ringCenterMetric — Today + widget)
///   • cycle toggle -> AtriaCycleTracking.setEnabled     (Journal cycle card / AI coach)
///
/// Research sharing keeps its existing inspector-gated consent path
/// (`AtriaResearchSharing.grantConsent`), owned by the post-flow sharing step in
/// `ContentView` — it is deliberately NOT duplicated here so a user is never
/// asked to consent twice.
///
/// The load helpers mirror `AtriaTodayScreen`/`ContentView` exactly (same key
/// names, same CSV format, same legacy `ringOrder` seed, same 3-slot padding),
/// so re-entering onboarding shows the choices already in effect rather than the
/// bare defaults. A `store` seam keeps every helper unit-testable against an
/// isolated `UserDefaults` suite.
enum AtriaOnboardingPersonalization {
    static let nicknameKey = "atria.user.nickname"
    static let ringMetricsKey = "atria.today.ringMetrics"
    /// Legacy order key AtriaTodayScreen still reads as a one-time seed when the
    /// newer ring-metrics key was never explicitly set on this device.
    static let ringOrderSeedKey = "atria.today.ringOrder"

    // MARK: - Nickname (P1)

    static func loadNickname(store: UserDefaults = .standard) -> String {
        store.string(forKey: nicknameKey) ?? ""
    }

    /// Persists a trimmed nickname, or removes the key entirely when the field
    /// is blank — the same "skipping looks like skipping" contract the standalone
    /// nickname step used, so an empty entry never leaves a stray "" greeting.
    static func persistNickname(_ raw: String, store: UserDefaults = .standard) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            store.removeObject(forKey: nicknameKey)
        } else {
            store.set(trimmed, forKey: nicknameKey)
        }
    }

    // MARK: - Ring slots, outer -> inner (P2)

    static func loadRingSlots(store: UserDefaults = .standard) -> [AtriaTriRingSlot] {
        let metrics = store.string(forKey: ringMetricsKey) ?? ""
        let seed = store.string(forKey: ringOrderSeedKey) ?? ""
        let raw = metrics.isEmpty ? seed : metrics
        var seen = Set<AtriaTriRingSlot>()
        var result = raw
            .split(separator: ",")
            .compactMap { AtriaTriRingSlot(rawValue: String($0)) }
            .filter { seen.insert($0).inserted }
        for slot in AtriaTriRingSlot.defaultOrder where !result.contains(slot) {
            result.append(slot)
        }
        return Array(result.prefix(3))
    }

    static func persistRingSlots(_ slots: [AtriaTriRingSlot], store: UserDefaults = .standard) {
        store.set(slots.map(\.rawValue).joined(separator: ","), forKey: ringMetricsKey)
    }

    /// Swap-rather-than-duplicate assignment, identical to AtriaTodayScreen: if
    /// `slot` already occupies a different position, the two positions trade
    /// places instead of leaving one metric on two rings.
    static func assign(_ slot: AtriaTriRingSlot,
                       toPosition position: Int,
                       in slots: [AtriaTriRingSlot]) -> [AtriaTriRingSlot] {
        var slots = slots
        guard slots.indices.contains(position) else { return slots }
        if let existing = slots.firstIndex(of: slot), existing != position {
            slots.swapAt(existing, position)
        } else {
            slots[position] = slot
        }
        return slots
    }

    // MARK: - Ring center metric (P2)
    // Stored inside the AtriaHomeLayoutConfig JSON blob, exactly like the
    // Customize Today sheet and the widget snapshot read it.

    static func loadRingCenterMetric(store: UserDefaults = .standard) -> AtriaHomeLayoutConfig.RingCenterMetric {
        loadHomeLayoutConfig(store: store).ringCenterMetric
    }

    static func persistRingCenterMetric(_ metric: AtriaHomeLayoutConfig.RingCenterMetric,
                                        store: UserDefaults = .standard) {
        var config = loadHomeLayoutConfig(store: store)
        config.ringCenterMetric = metric
        if let encoded = try? config.encodedData(),
           let json = String(data: encoded, encoding: .utf8) {
            store.set(json, forKey: AtriaHomeLayoutConfig.storageKey)
        }
    }

    private static func loadHomeLayoutConfig(store: UserDefaults) -> AtriaHomeLayoutConfig {
        guard let data = store.string(forKey: AtriaHomeLayoutConfig.storageKey)?.data(using: .utf8),
              !data.isEmpty,
              let decoded = try? AtriaHomeLayoutConfig.decoded(from: data) else {
            return .default
        }
        return decoded
    }
}
