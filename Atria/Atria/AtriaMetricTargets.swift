import SwiftUI

enum AtriaMetricZoneLevel: String, Equatable, Codable {
    case green
    case yellow
    case red

    var tint: Color {
        switch self {
        case .green: return .green
        case .yellow: return .orange
        case .red: return .red
        }
    }

    var warningSystemImage: String? {
        switch self {
        case .green: return nil
        case .yellow: return "exclamationmark.circle"
        case .red: return "exclamationmark.triangle.fill"
        }
    }

    var label: String {
        switch self {
        case .green: return "In target"
        case .yellow: return "Watch"
        case .red: return "Out of range"
        }
    }
}

struct AtriaMetricTarget: Equatable, Codable {
    enum Direction: String, Equatable, Codable {
        case higherIsBetter
        case lowerIsBetter
        case targetBand
    }

    enum Source: String, Equatable, Codable {
        case researchDefault
        case personalBaseline
        case userEdited

        var label: String {
            switch self {
            case .researchDefault: return "Research default"
            case .personalBaseline: return "Personal baseline"
            case .userEdited: return "User edited"
            }
        }
    }

    let metricID: String
    let direction: Direction
    let greenLower: Double
    let yellowLower: Double
    let optimalRange: ClosedRange<Double>?
    let yellowBuffer: Double?
    let redThreshold: Double?
    let goal: Double?
    let source: Source

    static let recoveryRecommended = AtriaMetricTarget(metricID: "recovery",
                                                       direction: .higherIsBetter,
                                                       greenLower: 67,
                                                       yellowLower: 34,
                                                       optimalRange: 67...100,
                                                       yellowBuffer: 33,
                                                       redThreshold: 34,
                                                       goal: 67,
                                                       source: .researchDefault)

    init(metricID: String,
         direction: Direction,
         greenLower: Double,
         yellowLower: Double,
         optimalRange: ClosedRange<Double>? = nil,
         yellowBuffer: Double? = nil,
         redThreshold: Double? = nil,
         goal: Double? = nil,
         source: Source) {
        self.metricID = metricID
        self.direction = direction
        self.greenLower = greenLower
        self.yellowLower = yellowLower
        self.optimalRange = optimalRange
        self.yellowBuffer = yellowBuffer
        self.redThreshold = redThreshold
        self.goal = goal
        self.source = source
    }

    static func recovery(greenLower: Double, yellowLower: Double) -> AtriaMetricTarget {
        let clampedYellow = min(max(yellowLower, 1), 99)
        let clampedGreen = min(max(greenLower, clampedYellow + 1), 100)
        let isDefault = Int(clampedGreen.rounded()) == 67 && Int(clampedYellow.rounded()) == 34
        return AtriaMetricTarget(metricID: "recovery",
                                 direction: .higherIsBetter,
                                 greenLower: clampedGreen,
                                 yellowLower: clampedYellow,
                                 optimalRange: clampedGreen...100,
                                 yellowBuffer: clampedGreen - clampedYellow,
                                 redThreshold: clampedYellow,
                                 goal: clampedGreen,
                                 source: isDefault ? .researchDefault : .userEdited)
    }

    var summaryText: String {
        let base = "\(source.label) · Green >= \(Int(greenLower.rounded()))%, yellow \(Int(yellowLower.rounded()))-\(Int(greenLower.rounded()) - 1)%, red < \(Int(yellowLower.rounded()))%"
        let details = [
            optimalRange.map { "optimal \(Int($0.lowerBound.rounded()))-\(Int($0.upperBound.rounded()))" },
            yellowBuffer.map { "yellow buffer \(Int($0.rounded()))" },
            redThreshold.map { "red threshold \(Int($0.rounded()))" },
            goal.map { "goal \(Int($0.rounded()))" },
        ].compactMap { $0 }
        guard !details.isEmpty else { return base }
        return base + " · " + details.joined(separator: " · ")
    }
}

struct AtriaMetricZone: Equatable {
    let level: AtriaMetricZoneLevel
    let title: String
    let current: String
    let targetSummary: String
    let recommendation: String
    let disclaimer: String

    var tint: Color { level.tint }
    var warningSystemImage: String? { level.warningSystemImage }
    var showsWarning: Bool { warningSystemImage != nil }

    static let nonMedicalDisclaimer = "General wellness guidance only, not medical advice."
}

struct AtriaBaselineTargetSnapshot: Equatable {
    let hrvBaseline: Int?
    let hrvSampleCount: Int
    let hrvLnMean: Double?
    let hrvLnSD: Double?
    let hrvTrusted: Bool
    let restingBaseline: Int?
    let restingSampleCount: Int
    let restingMean: Double?
    let restingSD: Double?
    let restingTrusted: Bool

    init(_ baseline: PersonalBaseline) {
        let hrvStats = baseline.lnRMSSDStats
        let restingStats = baseline.restingStats
        hrvBaseline = baseline.hrvInt
        hrvSampleCount = baseline.freshHRVSampleCount()
        hrvLnMean = hrvStats?.mean
        hrvLnSD = hrvStats?.sd
        hrvTrusted = baseline.hasTrustedHRVBaseline() && (hrvStats?.count ?? 0) >= PersonalBaseline.trustedMinimumSamples
        restingBaseline = baseline.restingInt
        restingSampleCount = baseline.freshRestingSampleCount()
        restingMean = restingStats?.mean
        restingSD = restingStats?.sd
        restingTrusted = baseline.hasTrustedRestingBaseline() && (restingStats?.count ?? 0) >= PersonalBaseline.trustedMinimumSamples
    }
}

extension AtriaMetricZone {
    static func zone(for value: Double, target: AtriaMetricTarget) -> AtriaMetricZoneLevel {
        if let optimalRange = target.optimalRange,
           optimalRange.contains(value) {
            return .green
        }

        switch target.direction {
        case .higherIsBetter:
            if value >= target.greenLower { return .green }
            if value >= target.yellowLower { return .yellow }
            return .red
        case .lowerIsBetter:
            if value <= target.greenLower { return .green }
            if value <= target.yellowLower { return .yellow }
            return .red
        case .targetBand:
            guard let goal = target.goal else {
                if value >= target.greenLower { return .green }
                if value >= target.yellowLower { return .yellow }
                return .red
            }
            let greenBand = target.optimalRange.map { max(abs(goal - $0.lowerBound), abs($0.upperBound - goal)) } ?? 0
            let yellowBand = max(target.yellowBuffer ?? greenBand, greenBand)
            let redBand = max(target.redThreshold ?? yellowBand, yellowBand)
            let delta = abs(value - goal)
            if delta <= greenBand { return .green }
            if delta <= redBand || delta <= yellowBand { return .yellow }
            return .red
        }
    }
}

extension Metrics {
    static func recoveryZone(_ pct: Int?, target: AtriaMetricTarget = .recoveryRecommended) -> AtriaMetricZone? {
        AtriaAnalytics.TargetZones.recovery(pct, target: target)
    }

    static func strainZone(strain: Double,
                           target: Double?,
                           greenBand: Double = 1.5,
                           yellowBand: Double = 3.0) -> AtriaMetricZone? {
        AtriaAnalytics.TargetZones.strain(strain: strain,
                                          target: target,
                                          greenBand: greenBand,
                                          yellowBand: yellowBand)
    }

    static func hrvZone(_ rmssd: Int?,
                        baseline: Int?,
                        baselineSamples: Int,
                        baselineTrusted: Bool,
                        baselineTarget: AtriaBaselineTargetSnapshot? = nil,
                        greenRatio: Double = 0.95,
                        yellowRatio: Double = 0.85) -> AtriaMetricZone? {
        AtriaAnalytics.TargetZones.hrv(rmssd,
                                       baseline: baseline,
                                       baselineSamples: baselineSamples,
                                       baselineTrusted: baselineTrusted,
                                       baselineTarget: baselineTarget,
                                       greenRatio: greenRatio,
                                       yellowRatio: yellowRatio)
    }

    static func restingHeartRateZone(_ bpm: Int?,
                                     baseline: Int?,
                                     baselineSamples: Int,
                                     baselineTrusted: Bool,
                                     baselineTarget: AtriaBaselineTargetSnapshot? = nil,
                                     greenDelta: Int = 3,
                                     yellowDelta: Int = 7) -> AtriaMetricZone? {
        AtriaAnalytics.TargetZones.restingHeartRate(bpm,
                                                    baseline: baseline,
                                                    baselineSamples: baselineSamples,
                                                    baselineTrusted: baselineTrusted,
                                                    baselineTarget: baselineTarget,
                                                    greenDelta: greenDelta,
                                                    yellowDelta: yellowDelta)
    }

    static func sleepEfficiencyZone(_ efficiency: Double?,
                                    greenLower: Double = 90,
                                    yellowLower: Double = 80) -> AtriaMetricZone? {
        AtriaAnalytics.TargetZones.sleepEfficiency(efficiency,
                                                   greenLower: greenLower,
                                                   yellowLower: yellowLower)
    }

    static func sleepDurationZone(_ hours: Double?, goalHours: Double = 8.0) -> AtriaMetricZone? {
        AtriaAnalytics.TargetZones.sleepDuration(hours, goalHours: goalHours)
    }

    static func stepsZone(_ steps: Int?, goal: Int = 8_000) -> AtriaMetricZone? {
        AtriaAnalytics.TargetZones.steps(steps, goal: goal)
    }

    static func activeCaloriesZone(_ calories: Double?, goal: Int = 500) -> AtriaMetricZone? {
        AtriaAnalytics.TargetZones.activeCalories(calories, goal: goal)
    }

    static func vo2TrendZone(_ summary: VO2MaxEstimateSummary,
                             greenDelta: Double = 0.2,
                             redDelta: Double = -0.2) -> AtriaMetricZone? {
        AtriaAnalytics.TargetZones.vo2Trend(summary,
                                            greenDelta: greenDelta,
                                            redDelta: redDelta)
    }

    static func biologicalAgeZone(_ summary: BiologicalAgeSummary,
                                  greenOlderDelta: Int = 0,
                                  yellowOlderDelta: Int = 3) -> AtriaMetricZone? {
        AtriaAnalytics.TargetZones.biologicalAge(summary,
                                                 greenOlderDelta: greenOlderDelta,
                                                 yellowOlderDelta: yellowOlderDelta)
    }

    static func respiratoryRateZone(_ breathsPerMinute: Double?,
                                    baseline: Double?,
                                    baselineSamples: Int,
                                    greenDelta: Double = 1.5,
                                    yellowDelta: Double = 3.0) -> AtriaMetricZone? {
        AtriaAnalytics.TargetZones.respiratoryRate(breathsPerMinute,
                                                   baseline: baseline,
                                                   baselineSamples: baselineSamples,
                                                   greenDelta: greenDelta,
                                                   yellowDelta: yellowDelta)
    }

    static func skinTemperatureDeviationZone(_ summary: IMUAuditSummary.SkinTemperatureDeviationSummary,
                                             greenDelta: Double = 0.5,
                                             yellowDelta: Double = 1.0) -> AtriaMetricZone? {
        AtriaAnalytics.TargetZones.skinTemperatureDeviation(summary,
                                                            greenDelta: greenDelta,
                                                            yellowDelta: yellowDelta)
    }

    static func bloodOxygenResearchZone(candidateFrames: Int,
                                        goalFrames: Int = 8) -> AtriaMetricZone? {
        AtriaAnalytics.TargetZones.bloodOxygenResearch(candidateFrames: candidateFrames,
                                                       goalFrames: goalFrames)
    }
}

struct AtriaMetricZoneInfoSheet: View {
    let zone: AtriaMetricZone

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Image(systemName: zone.warningSystemImage ?? "checkmark.circle.fill")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(zone.tint)
                        .frame(width: 42, height: 42)
                        .background(AtriaIconTileBackground(cornerRadius: 14, tint: zone.tint))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(zone.title)
                            .font(.headline.weight(.semibold))
                        Text(zone.current)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Target zone")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(zone.targetSummary)
                        .font(.body.weight(.semibold))
                }
                .padding(14)
                .atriaInsetCard(tint: zone.tint)

                VStack(alignment: .leading, spacing: 8) {
                    Text("What to do")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(zone.recommendation)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .atriaInsetCard(tint: zone.tint)

                Text(zone.disclaimer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)
            }
            .padding(20)
            .navigationTitle("Metric info")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
