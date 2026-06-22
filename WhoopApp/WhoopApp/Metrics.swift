import SwiftUI

/// WHOOP-style headline metrics computed locally from strap data.
///
/// These are honest approximations of WHOOP's proprietary scores:
/// - **Strain** uses Banister's TRIMP (training impulse) mapped to the 0–21 scale.
/// - **Recovery** uses the user's own ready RR/HRV data once enough personal
///   baseline exists, and labels the result honestly until reference validated.
enum Metrics {

    // MARK: Strain (0–21)

    /// Banister TRIMP over a series of (secondsFromStart, bpm) samples.
    /// Each sample contributes dt · HRr · 0.64 · e^(1.92·HRr).
    static func trimp(_ series: [(t: Double, bpm: Int)], rest: Int, max: Int) -> Double {
        guard series.count > 1, max > rest else { return 0 }
        let span = Double(max - rest)
        var total = 0.0
        for i in 1..<series.count {
            let dtMin = (series[i].t - series[i-1].t) / 60.0
            guard dtMin > 0, dtMin < 5 else { continue }   // skip gaps
            let hrr = Swift.min(Swift.max((Double(series[i].bpm) - Double(rest)) / span, 0), 1)
            total += dtMin * hrr * 0.64 * exp(1.92 * hrr)
        }
        return total
    }

    struct StrainZoneSummary: Equatable {
        let secondsZ0: TimeInterval
        let secondsZ1: TimeInterval
        let secondsZ2: TimeInterval
        let secondsZ3: TimeInterval
        let secondsZ4: TimeInterval
        let droppedGapSeconds: TimeInterval
        let samples: Int
        let minHRReserve: Double
        let maxHRReserve: Double

        static let empty = StrainZoneSummary(secondsZ0: 0,
                                             secondsZ1: 0,
                                             secondsZ2: 0,
                                             secondsZ3: 0,
                                             secondsZ4: 0,
                                             droppedGapSeconds: 0,
                                             samples: 0,
                                             minHRReserve: 0,
                                             maxHRReserve: 0)

        var totalSeconds: TimeInterval {
            secondsZ0 + secondsZ1 + secondsZ2 + secondsZ3 + secondsZ4
        }

        static func + (lhs: StrainZoneSummary, rhs: StrainZoneSummary) -> StrainZoneSummary {
            let samples = lhs.samples + rhs.samples
            let minReserve: Double
            let maxReserve: Double
            if lhs.samples == 0 {
                minReserve = rhs.minHRReserve
                maxReserve = rhs.maxHRReserve
            } else if rhs.samples == 0 {
                minReserve = lhs.minHRReserve
                maxReserve = lhs.maxHRReserve
            } else {
                minReserve = Swift.min(lhs.minHRReserve, rhs.minHRReserve)
                maxReserve = Swift.max(lhs.maxHRReserve, rhs.maxHRReserve)
            }
            return StrainZoneSummary(secondsZ0: lhs.secondsZ0 + rhs.secondsZ0,
                                     secondsZ1: lhs.secondsZ1 + rhs.secondsZ1,
                                     secondsZ2: lhs.secondsZ2 + rhs.secondsZ2,
                                     secondsZ3: lhs.secondsZ3 + rhs.secondsZ3,
                                     secondsZ4: lhs.secondsZ4 + rhs.secondsZ4,
                                     droppedGapSeconds: lhs.droppedGapSeconds + rhs.droppedGapSeconds,
                                     samples: samples,
                                     minHRReserve: minReserve,
                                     maxHRReserve: maxReserve)
        }
    }

    /// HR-reserve zone seconds for auditing Strain behavior across rest to max.
    /// Buckets: z0 <30%, z1 30-50%, z2 50-70%, z3 70-85%, z4 >=85% HR reserve.
    static func strainZoneSummary(_ series: [(t: Double, bpm: Int)], rest: Int, max: Int) -> StrainZoneSummary {
        guard series.count > 1, max > rest else { return .empty }
        let span = Double(max - rest)
        var z0 = 0.0, z1 = 0.0, z2 = 0.0, z3 = 0.0, z4 = 0.0
        var dropped = 0.0
        var minReserve = 1.0
        var maxReserve = 0.0
        var usableSamples = 0
        for i in 1..<series.count {
            let dt = series[i].t - series[i - 1].t
            guard dt > 0 else { continue }
            if dt >= 5 {
                dropped += dt
                continue
            }
            let reserve = Swift.min(Swift.max((Double(series[i].bpm) - Double(rest)) / span, 0), 1)
            minReserve = Swift.min(minReserve, reserve)
            maxReserve = Swift.max(maxReserve, reserve)
            usableSamples += 1
            switch reserve {
            case ..<0.30: z0 += dt
            case ..<0.50: z1 += dt
            case ..<0.70: z2 += dt
            case ..<0.85: z3 += dt
            default: z4 += dt
            }
        }
        guard usableSamples > 0 else {
            return StrainZoneSummary(secondsZ0: 0,
                                     secondsZ1: 0,
                                     secondsZ2: 0,
                                     secondsZ3: 0,
                                     secondsZ4: 0,
                                     droppedGapSeconds: dropped,
                                     samples: 0,
                                     minHRReserve: 0,
                                     maxHRReserve: 0)
        }
        return StrainZoneSummary(secondsZ0: z0,
                                 secondsZ1: z1,
                                 secondsZ2: z2,
                                 secondsZ3: z3,
                                 secondsZ4: z4,
                                 droppedGapSeconds: dropped,
                                 samples: usableSamples,
                                 minHRReserve: minReserve,
                                 maxHRReserve: maxReserve)
    }

    /// Map cumulative TRIMP to the 0–21 strain scale (saturating exponential).
    static func strain(fromTRIMP trimp: Double) -> Double {
        guard trimp > 0 else { return 0 }
        return Swift.min(21.0 * (1 - exp(-trimp / 40.0)), 21.0)
    }

    // MARK: Recovery (0–100 %)

    struct RecoveryEstimate: Equatable {
        enum Confidence: String {
            case learning
            case unverified
            case personalBaseline = "personal baseline"
            case validated
        }

        let percent: Int?
        let confidence: Confidence
        let usesHRV: Bool
        let detail: String
    }

    /// HR-only recovery: at/below baseline reads high; elevated resting reads low.
    static func recovery(restingNow: Int, baseline: Int) -> Int {
        guard restingNow > 0, baseline > 0 else { return 0 }
        let delta = Double(restingNow - baseline)          // + = elevated (worse)
        return Int(Swift.min(Swift.max(75 - delta * 5, 1), 99).rounded())
    }

    /// HRV-driven recovery (WHOOP's primary signal), blended with resting HR.
    /// HRV above your norm → high recovery; elevated resting HR penalizes it.
    static func recovery(hrvNow: Int, hrvBaseline: Int, restingNow: Int, restingBaseline: Int) -> Int {
        guard hrvNow > 0, hrvBaseline > 0 else {
            return recovery(restingNow: restingNow, baseline: restingBaseline)
        }
        let hrvScore = 66.0 * Double(hrvNow) / Double(hrvBaseline)   // ratio centered on green edge
        let restingPenalty = restingNow > 0 && restingBaseline > 0
            ? 3.0 * Double(restingNow - restingBaseline) : 0
        return Int(Swift.min(Swift.max(hrvScore - restingPenalty, 1), 99).rounded())
    }

    /// Recovery v2: lnRMSSD z-score against a personal rolling baseline, blended
    /// with resting-HR z-score. Recovery displays after local data sufficiency;
    /// external reference validation upgrades the confidence tier and HealthKit
    /// writes, but does not block in-app display.
    static func recoveryV2(hrvSnapshot: HRVSnapshot?, fallbackRMSSD: Int?,
                           restingNow: Int?, baseline: PersonalBaseline,
                           hrvReferenceValidated: Bool = false) -> RecoveryEstimate {
        guard let restingNow else {
            return RecoveryEstimate(percent: nil, confidence: .learning,
                                    usesHRV: false, detail: "learning: need resting HR")
        }

        guard let restingStats = baseline.restingStats else {
            return RecoveryEstimate(percent: nil, confidence: .learning,
                                    usesHRV: false, detail: "learning: need baseline")
        }

        let restingZ = zScore(Double(restingNow), mean: restingStats.mean, sd: restingStats.sd)
        let rmssdNow = hrvSnapshot?.isReady == true
            ? hrvSnapshot?.rmssd
            : fallbackRMSSD.map(Double.init)
        guard let rmssdNow, rmssdNow > 0 else {
            return RecoveryEstimate(percent: nil, confidence: .learning,
                                    usesHRV: false,
                                    detail: "learning: need a clean HRV window")
        }

        guard let hrvStats = baseline.lnRMSSDStats, hrvStats.count >= 7 else {
            return RecoveryEstimate(percent: nil, confidence: .learning,
                                    usesHRV: false,
                                    detail: "learning HRV baseline \(baseline.hrvSampleCount)/7")
        }

        let hrvZ = zScore(log(rmssdNow), mean: hrvStats.mean, sd: hrvStats.sd)
        let blendedZ = 0.75 * hrvZ - 0.25 * restingZ
        let percent = Int(Swift.min(Swift.max(50 + blendedZ * 16, 1), 99).rounded())
        let confidence: RecoveryEstimate.Confidence = hrvReferenceValidated ? .validated : .personalBaseline
        return RecoveryEstimate(percent: percent, confidence: confidence,
                                usesHRV: true,
                                detail: String(format: "lnRMSSD z %.1f · RHR z %.1f", hrvZ, restingZ))
    }

    private static func zScore(_ value: Double, mean: Double, sd: Double) -> Double {
        guard sd > 0.1 else { return 0 }
        return (value - mean) / sd
    }

    static func recoveryColor(_ pct: Int) -> Color {
        switch pct {
        case 67...: return .green
        case 34..<67: return .yellow
        default: return .red
        }
    }

    static func strainColor(_ s: Double) -> Color {
        switch s {
        case ..<8: return .blue
        case 8..<14: return .teal
        case 14..<18: return .orange
        default: return .red
        }
    }
}

// MARK: - Recovery ring

struct RecoveryRing: View, Equatable {
    let percent: Int?     // nil = not enough data yet
    var detail: String = ""
    var confidence: Metrics.RecoveryEstimate.Confidence = .learning

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().stroke(.quaternary, lineWidth: 10)
                if let p = percent {
                    Circle()
                        .trim(from: 0, to: CGFloat(p) / 100)
                        .stroke(Metrics.recoveryColor(p),
                                style: .init(lineWidth: 10, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                VStack(spacing: 0) {
                    Text(percent.map { "\($0)" } ?? "—")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    Text("%").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(width: 92, height: 92)
            Text("Recovery").font(.caption).foregroundStyle(.secondary)
            if !detail.isEmpty {
                Text(confidence.rawValue)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(confidence == .validated ? .green : .orange)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(AtriaQuietCardBackground())
        .transaction { transaction in
            transaction.animation = nil
        }
    }
}

// MARK: - Strain gauge

struct StrainGauge: View, Equatable {
    let strain: Double
    var detail: String = ""
    var confidence: String = "learning"

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().trim(from: 0, to: 0.75).stroke(.quaternary,
                    style: .init(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(135))
                Circle().trim(from: 0, to: 0.75 * CGFloat(strain / 21))
                    .stroke(Metrics.strainColor(strain),
                            style: .init(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(135))
                VStack(spacing: 0) {
                    Text(String(format: "%.1f", strain))
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                    Text("of 21").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(width: 92, height: 92)
            Text("Day strain").font(.caption).foregroundStyle(.secondary)
            if !detail.isEmpty {
                Text(confidence)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(confidence == "local" ? .green : .orange)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.72)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(AtriaQuietCardBackground())
        .transaction { transaction in
            transaction.animation = nil
        }
    }
}
