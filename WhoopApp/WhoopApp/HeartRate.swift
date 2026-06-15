import SwiftUI
import Charts

/// One timestamped heart-rate sample.
struct HRSample: Identifiable {
    let id = UUID()
    let t: Date
    let bpm: Int
}

/// Standard 5-zone model as a percentage of max HR.
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

    /// Lower bound as a fraction of max HR.
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

    static func zone(for bpm: Int, maxHR: Int) -> HRZone {
        guard bpm > 0, maxHR > 0 else { return .rest }
        let frac = Double(bpm) / Double(maxHR)
        return HRZone.allCases.last { frac >= $0.lowerFraction } ?? .rest
    }
}

/// Live HR line chart over the session.
struct HRChart: View {
    let samples: [HRSample]
    let maxHR: Int

    var body: some View {
        Chart(samples) { s in
            LineMark(x: .value("Time", s.t), y: .value("BPM", s.bpm))
                .interpolationMethod(.catmullRom)
                .foregroundStyle(.red.gradient)
            AreaMark(x: .value("Time", s.t), y: .value("BPM", s.bpm))
                .interpolationMethod(.catmullRom)
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
            .animation(.easeInOut(duration: 0.25), value: current)
        }
    }
}
