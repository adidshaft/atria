import SwiftUI

struct AtriaFrozenDailyStrainTarget: Codable, Equatable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let day: Date
    let timeZoneIdentifier: String
    let recovery: Int
    let target: Double
    let loadAdjustment: Double
    let loadProvenance: String
    let createdAt: Date

    init(day: Date,
         timeZoneIdentifier: String,
         recovery: Int,
         target: Double,
         loadAdjustment: Double,
         loadProvenance: String,
         createdAt: Date) {
        self.schemaVersion = Self.currentSchemaVersion
        self.day = day
        self.timeZoneIdentifier = timeZoneIdentifier
        self.recovery = recovery
        self.target = target
        self.loadAdjustment = loadAdjustment
        self.loadProvenance = loadProvenance
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, day, timeZoneIdentifier, recovery, target
        case loadAdjustment, loadProvenance, createdAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        day = try values.decode(Date.self, forKey: .day)
        timeZoneIdentifier = try values.decodeIfPresent(String.self, forKey: .timeZoneIdentifier) ?? "legacy"
        recovery = try values.decode(Int.self, forKey: .recovery)
        target = try values.decode(Double.self, forKey: .target)
        loadAdjustment = try values.decodeIfPresent(Double.self, forKey: .loadAdjustment) ?? 0
        loadProvenance = try values.decodeIfPresent(String.self, forKey: .loadProvenance) ?? "legacy"
        createdAt = try values.decodeIfPresent(Date.self, forKey: .createdAt) ?? day
    }
}

enum AtriaDailyStrainTargetStore {
    static let storageKey = "atria.coach.frozenDailyStrainTarget.v1"

    static func resolve(recovery: Int?,
                        load: TrainingLoadSummary?,
                        recoveryIsAttributedToCurrentDay: Bool = true,
                        loadIsPrepared: Bool = true,
                        now: Date = Date(),
                        calendar: Calendar = .current,
                        defaults: UserDefaults = .standard) -> AtriaFrozenDailyStrainTarget? {
        if let existing = loadSnapshot(defaults: defaults),
           existing.target.isFinite,
           (0...21).contains(existing.target),
           calendar.isDate(existing.day, inSameDayAs: now) {
            return existing
        }

        guard recoveryIsAttributedToCurrentDay,
              loadIsPrepared,
              let recovery else {
            return nil
        }

        let base = Coach.baseStrainTarget(recovery: recovery)
        let adjustment: Double
        let provenance: String
        if let load, load.confidence != "learning", let ratio = load.ratio {
            if ratio > 1.30 {
                adjustment = -2
                provenance = "load_high"
            } else if ratio < 0.80 {
                adjustment = 1
                provenance = "load_low"
            } else {
                adjustment = 0
                provenance = "load_aligned"
            }
        } else {
            adjustment = 0
            provenance = "load_learning_at_mint"
        }
        let snapshot = AtriaFrozenDailyStrainTarget(
            day: calendar.startOfDay(for: now),
            timeZoneIdentifier: calendar.timeZone.identifier,
            recovery: recovery,
            target: min(max(base + adjustment, 4), 21),
            loadAdjustment: adjustment,
            loadProvenance: provenance,
            createdAt: now
        )
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: storageKey)
        }
        return snapshot
    }

    static func loadSnapshot(defaults: UserDefaults = .standard) -> AtriaFrozenDailyStrainTarget? {
        guard let data = defaults.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(AtriaFrozenDailyStrainTarget.self, from: data)
    }
}

/// The core daily loop: recovery sets an "optimal strain" target for the day,
/// and we tell you whether to push, hold, or rest based on where today's strain
/// sits relative to that target.
enum Coach {

    /// Recovery → recommended strain target (0–21). Higher recovery earns a
    /// higher target; low recovery caps it low.
    static func optimalStrain(recovery: Int) -> Double {
        baseStrainTarget(recovery: recovery)
    }

    static func baseStrainTarget(recovery: Int) -> Double {
        let clamped = min(max(Double(recovery), 0), 100)
        if clamped <= 33 { return 9 }
        if clamped >= 67 { return 17 }
        return 9 + ((clamped - 33) / 34) * 8
    }

    static func liveStrainTarget(recovery: Int, accumulatedStrain strain: Double) -> Double {
        // A daily goal must not move backward as the user makes progress.
        // Recovery (and, in the overload below, training load) establishes the
        // target; accumulated strain only determines progress and guidance
        // state. Keep the argument for source compatibility with existing
        // callers while making the target stable for the civil day.
        _ = strain
        return baseStrainTarget(recovery: recovery)
    }

    struct Guidance: Equatable {
        let headline: String
        let detail: String
        let color: Color
        let target: Double?
        let state: String
        let reason: String

        static func == (lhs: Guidance, rhs: Guidance) -> Bool {
            lhs.headline == rhs.headline
                && lhs.detail == rhs.detail
                && lhs.target == rhs.target
                && lhs.state == rhs.state
                && lhs.reason == rhs.reason
        }
    }

    static func guide(recovery: Int?, strain: Double) -> Guidance {
        guard let r = recovery else {
            return Guidance(headline: "Building your baseline",
                            detail: "Recovery is learning; strain target stays off until enough local inputs are ready.",
                            color: .secondary, target: nil,
                            state: "learning",
                            reason: "recovery_unavailable")
        }
        let target = liveStrainTarget(recovery: r, accumulatedStrain: strain)
        if r < 34 {
            return Guidance(headline: "Prioritize recovery",
                            detail: "Recovery is low; keep strain light and let your body rebuild.",
                            color: .red, target: target,
                            state: "ready",
                            reason: "low_recovery")
        }
        if strain > target + 2 {
            return Guidance(headline: "Ease off",
                            detail: "You are past today's optimal strain; more risks overreaching.",
                            color: .orange, target: target,
                            state: "ready",
                            reason: "strain_above_target")
        }
        if strain < target - 2 {
            return Guidance(headline: "Room to push",
                            detail: "You can safely add strain to reach today's target.",
                            color: .green, target: target,
                            state: "ready",
                            reason: "strain_below_target")
        }
        return Guidance(headline: "On target",
                        detail: "Your strain matches what today's recovery supports.",
                        color: .blue, target: target,
                        state: "ready",
                        reason: "strain_on_target")
    }

    static func guide(recovery estimate: Metrics.RecoveryEstimate,
                      strain: Double,
                      load: TrainingLoadSummary? = nil,
                      frozenTarget: Double? = nil,
                      frozenRecovery: Int? = nil) -> Guidance {
        guard let percent = estimate.percent ?? frozenRecovery else {
            // estimate.detail is an internal "learning: <reason>" status string;
            // strip the redundant "learning:" prefix (the headline already says
            // "Guidance learning") so the sentence doesn't read the awkward
            // "…recovery data: learning: need resting HR."
            let rawDetail = estimate.detail.isEmpty ? "more data" : estimate.detail.replacingOccurrences(of: "_", with: " ")
            let detail = rawDetail.replacingOccurrences(of: "learning: ", with: "")
            return Guidance(headline: "Guidance learning",
                            detail: "Waiting for enough recovery data: \(detail).",
                            color: .secondary,
                            target: nil,
                            state: "learning",
                            reason: "recovery_\(estimate.confidence.rawValue)_not_ready")
        }
        if let frozenTarget {
            return guide(recovery: percent, strain: strain, frozenTarget: frozenTarget)
        }
        var guidance = guide(recovery: percent, strain: strain)
        guard let load, load.confidence != "learning", let ratio = load.ratio else {
            return guidance
        }

        let adjustedTarget: Double
        let loadClause: String
        let loadReason: String
        if ratio > 1.30 {
            adjustedTarget = max(4, (guidance.target ?? optimalStrain(recovery: percent)) - 2)
            loadClause = " Acute load is above your longer base, so today's target is softened."
            loadReason = "load_high"
        } else if ratio < 0.80 {
            adjustedTarget = min(21, (guidance.target ?? optimalStrain(recovery: percent)) + 1)
            loadClause = " Recent load is below your base, so there is room to rebuild gradually."
            loadReason = "load_low"
        } else {
            adjustedTarget = guidance.target ?? optimalStrain(recovery: percent)
            loadClause = " Load is aligned with your base."
            loadReason = "load_aligned"
        }

        if strain > adjustedTarget + 2 {
            guidance = Guidance(headline: "Ease off",
                                detail: "You are past today's adjusted strain target.\(loadClause)",
                                color: .orange,
                                target: adjustedTarget,
                                state: guidance.state,
                                reason: "\(guidance.reason)_\(loadReason)")
        } else if strain < adjustedTarget - 2 {
            guidance = Guidance(headline: "Room to push",
                                detail: "You can add strain toward today's adjusted target.\(loadClause)",
                                color: .green,
                                target: adjustedTarget,
                                state: guidance.state,
                                reason: "\(guidance.reason)_\(loadReason)")
        } else {
            guidance = Guidance(headline: "On target",
                                detail: "Your strain matches today's adjusted target.\(loadClause)",
                                color: .blue,
                                target: adjustedTarget,
                                state: guidance.state,
                                reason: "\(guidance.reason)_\(loadReason)")
        }
        return guidance
    }

    static func guide(recovery: Int, strain: Double, frozenTarget target: Double) -> Guidance {
        let safeTarget = min(max(target, 0), 21)
        if recovery < 34 {
            return Guidance(headline: "Prioritize recovery",
                            detail: "Recovery is low; keep strain light and let your body rebuild.",
                            color: .red, target: safeTarget,
                            state: "ready", reason: "low_recovery_frozen_daily_target")
        }
        if strain > safeTarget + 2 {
            return Guidance(headline: "Ease off",
                            detail: "You are past today's strain target.",
                            color: .orange, target: safeTarget,
                            state: "ready", reason: "strain_above_frozen_daily_target")
        }
        if strain < safeTarget - 2 {
            return Guidance(headline: "Room to push",
                            detail: "You can safely add strain toward today's target.",
                            color: .green, target: safeTarget,
                            state: "ready", reason: "strain_below_frozen_daily_target")
        }
        return Guidance(headline: "On target",
                        detail: "Your strain matches today's target.",
                        color: .blue, target: safeTarget,
                        state: "ready", reason: "strain_on_frozen_daily_target")
    }
}

struct DailyGuidanceCard: View {
    let guidance: Coach.Guidance
    let strain: Double

    init(guidance: Coach.Guidance, strain: Double) {
        self.guidance = guidance
        self.strain = strain
    }

    init(recovery: Metrics.RecoveryEstimate, strain: Double) {
        self.guidance = Coach.guide(recovery: recovery, strain: strain)
        self.strain = strain
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(guidance.color).frame(width: 10, height: 10)
                Text(guidance.headline).font(.headline)
                Spacer()
                if let t = guidance.target {
                    Text("target \(String(format: "%.1f", t))")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(guidance.state)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(guidance.detail).font(.subheadline).foregroundStyle(.secondary)

            if let t = guidance.target {
                // current strain vs target, on the 0–21 scale
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary).frame(height: 8)
                        Capsule().fill(guidance.color.gradient)
                            .frame(width: geo.size.width * CGFloat(min(strain / 21, 1)), height: 8)
                        // target marker
                        Rectangle().fill(.primary.opacity(0.5))
                            .frame(width: 2, height: 16)
                            .offset(x: geo.size.width * CGFloat(min(t / 21, 1)) - 1)
                    }
                }
                .frame(height: 16)
                HStack {
                    Text("strain \(String(format: "%.1f", strain))")
                    Spacer()
                    Text("0 — 21").foregroundStyle(.tertiary)
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding()
        .atriaCard(cornerRadius: 22, emphasis: .soft)
    }
}
