import SwiftUI
import Charts

/// One timestamped heart-rate sample.
struct HRSample: Identifiable {
    let id = UUID()
    let t: Date
    let bpm: Int
}

/// The public zone model uses heart-rate reserve (HRR): boundaries are
/// measured from the resting HR used for the workout, never from zero.
enum HRZone: Int, CaseIterable {
    case rest = 0, warmup, fatBurn, aerobic, anaerobic, max

    var name: String {
        switch self {
        case .rest: return "Rest"
        case .warmup: return "Warm-up"
        case .fatBurn: return "Fat burn"
        case .aerobic: return "Aerobic"
        case .anaerobic: return "Anaerobic"
        case .max: return "Max"
        }
    }

    var color: Color {
        switch self {
        case .rest: return .gray
        case .warmup: return .blue
        case .fatBurn: return .green
        case .aerobic: return .yellow
        case .anaerobic: return .orange
        case .max: return .red
        }
    }

    /// Lower bound as a fraction of heart-rate reserve.
    var lowerFraction: Double {
        switch self {
        case .rest: return 0.0
        case .warmup: return 0.50
        case .fatBurn: return 0.60
        case .aerobic: return 0.70
        case .anaerobic: return 0.80
        case .max: return 0.90
        }
    }

    static func zone(for bpm: Int, maxHR: Int, restingHR: Int? = nil) -> HRZone {
        guard bpm > 0, maxHR > 0 else { return .rest }
        let safeRest = restingHR ?? 0
        guard maxHR > safeRest else { return .rest }
        let frac = Double(bpm - safeRest) / Double(maxHR - safeRest)
        return HRZone.allCases.last { frac >= $0.lowerFraction } ?? .rest
    }
}

/// Frozen BPM boundaries for one workout.  Old aggregate-only workouts have
/// no trustworthy historical profile snapshot and intentionally remain nil.
struct AtriaHRRZoneBoundaries: Codable, Equatable {
    let restingHR: Int
    let maxHR: Int

    init?(restingHR: Int, maxHR: Int) {
        guard restingHR > 0, maxHR > restingHR else { return nil }
        self.restingHR = restingHR
        self.maxHR = maxHR
    }

    func lowerBPM(for zone: HRZone) -> Int {
        Int((Double(restingHR) + zone.lowerFraction * Double(maxHR - restingHR)).rounded())
    }

    func rangeText(for zone: HRZone) -> String {
        switch zone {
        case .rest: return "< \(lowerBPM(for: .warmup)) bpm"
        case .max: return "≥ \(lowerBPM(for: .max)) bpm"
        default:
            let next = HRZone(rawValue: zone.rawValue + 1)!
            return "\(lowerBPM(for: zone))–\(lowerBPM(for: next) - 1) bpm"
        }
    }
}

/// Live HR line chart over the session.
struct HRChart: View {
    let samples: [HRSample]
    let maxHR: Int

    var body: some View {
        Chart(samples) { s in
            LineMark(x: .value("Time", s.t), y: .value("BPM", s.bpm))
                .interpolationMethod(.linear)
                .foregroundStyle(.red.gradient)
            AreaMark(x: .value("Time", s.t), y: .value("BPM", s.bpm))
                .interpolationMethod(.linear)
                .foregroundStyle(.red.opacity(0.12).gradient)
        }
        .chartYScale(domain: yDomain)
        .chartXAxis(.hidden)
        .frame(height: 160)
    }

    private var yDomain: ClosedRange<Int> {
        let bpms = samples.map(\.bpm)
        let lo = max((bpms.min() ?? 60) - 8, 40)
        let hi = min((bpms.max() ?? 120) + 8, maxHR + 10)
        return lo...max(hi, lo + 20)
    }
}

/// Horizontal zone indicator with the current zone highlighted.
struct ZoneBar: View {
    let current: HRZone
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Zone: \(current.name)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(current.color)
            HStack(spacing: 3) {
                ForEach(HRZone.allCases, id: \.rawValue) { z in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(z == current ? z.color : z.color.opacity(0.25))
                        .frame(height: z == current ? 14 : 8)
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: current)
        }
    }
}
