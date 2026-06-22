import SwiftUI

/// WHOOP's core daily loop: recovery sets an "optimal strain" target for the day,
/// and we tell you whether to push, hold, or rest based on where today's strain
/// sits relative to that target.
enum Coach {

    /// Recovery → recommended strain target (0–21). Higher recovery earns a
    /// higher target; low recovery caps it low.
    static func optimalStrain(recovery: Int) -> Double {
        6.0 + Double(recovery) / 100.0 * 13.0      // ~6 at 0% … ~19 at 100%
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
                            detail: "Recovery is learning; strain target stays off until the inputs are validated.",
                            color: .secondary, target: nil,
                            state: "learning",
                            reason: "recovery_unavailable")
        }
        let target = optimalStrain(recovery: r)
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
                      load: TrainingLoadSummary? = nil) -> Guidance {
        guard let percent = estimate.percent else {
            let blocker = estimate.detail.isEmpty ? "learning" : estimate.detail
            return Guidance(headline: "Guidance learning",
                            detail: "Waiting for enough recovery data: \(blocker).",
                            color: .secondary,
                            target: nil,
                            state: "learning",
                            reason: "recovery_\(estimate.confidence.rawValue)_not_ready")
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
        .background(AtriaQuietCardBackground())
    }
}
