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
        case .red: return "Low"
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
    }

    let metricID: String
    let direction: Direction
    let greenLower: Double
    let yellowLower: Double
    let source: Source

    static let recoveryRecommended = AtriaMetricTarget(metricID: "recovery",
                                                       direction: .higherIsBetter,
                                                       greenLower: 67,
                                                       yellowLower: 34,
                                                       source: .researchDefault)

    static func recovery(greenLower: Double, yellowLower: Double) -> AtriaMetricTarget {
        let clampedYellow = min(max(yellowLower, 1), 99)
        let clampedGreen = min(max(greenLower, clampedYellow + 1), 100)
        let isDefault = Int(clampedGreen.rounded()) == 67 && Int(clampedYellow.rounded()) == 34
        return AtriaMetricTarget(metricID: "recovery",
                                 direction: .higherIsBetter,
                                 greenLower: clampedGreen,
                                 yellowLower: clampedYellow,
                                 source: isDefault ? .researchDefault : .userEdited)
    }

    var summaryText: String {
        "Green >= \(Int(greenLower.rounded()))%, yellow \(Int(yellowLower.rounded()))-\(Int(greenLower.rounded()) - 1)%, red < \(Int(yellowLower.rounded()))%"
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
                        greenRatio: Double = 0.95,
                        yellowRatio: Double = 0.85) -> AtriaMetricZone? {
        AtriaAnalytics.TargetZones.hrv(rmssd,
                                       baseline: baseline,
                                       baselineSamples: baselineSamples,
                                       greenRatio: greenRatio,
                                       yellowRatio: yellowRatio)
    }

    static func restingHeartRateZone(_ bpm: Int?,
                                     baseline: Int?,
                                     baselineSamples: Int,
                                     greenDelta: Int = 3,
                                     yellowDelta: Int = 7) -> AtriaMetricZone? {
        AtriaAnalytics.TargetZones.restingHeartRate(bpm,
                                                    baseline: baseline,
                                                    baselineSamples: baselineSamples,
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
        guard baselineSamples >= 3,
              let breathsPerMinute,
              let baseline,
              baseline > 0 else { return nil }
        let delta = breathsPerMinute - baseline
        let absDelta = abs(delta)
        let safeGreenDelta = min(max(greenDelta, 0.5), 4.0)
        let safeYellowDelta = min(max(yellowDelta, safeGreenDelta + 0.5), 8.0)
        let level: AtriaMetricZoneLevel = absDelta <= safeGreenDelta ? .green : (absDelta <= safeYellowDelta ? .yellow : .red)
        let recommendation: String
        switch level {
        case .green:
            recommendation = "Respiratory rate is close to your local sleep baseline."
        case .yellow:
            recommendation = "Respiratory rate is slightly off your baseline -- environment, poor sleep, stress, or illness onset can move it. Watch the trend, not one night."
        case .red:
            recommendation = "Respiratory rate is well off your baseline. Treat this as a wellness signal only and prioritize rest if you feel off."
        }
        return AtriaMetricZone(level: level,
                               title: "Respiratory rate baseline",
                               current: String(format: "%.1f/min, %+.1f vs %.1f baseline.", breathsPerMinute, delta, baseline),
                               targetSummary: String(format: "Green within +/-%.1f/min, yellow within +/-%.1f/min, red farther from %.1f/min.", safeGreenDelta, safeYellowDelta, baseline),
                               recommendation: recommendation,
                               disclaimer: "Research sleep-only estimate. \(AtriaMetricZone.nonMedicalDisclaimer)")
    }

    static func skinTemperatureDeviationZone(_ summary: IMUAuditSummary.SkinTemperatureDeviationSummary,
                                             greenDelta: Double = 0.5,
                                             yellowDelta: Double = 1.0) -> AtriaMetricZone? {
        guard summary.isReady, let delta = summary.latestDeltaCelsius else { return nil }
        let absDelta = abs(delta)
        let safeGreenDelta = min(max(greenDelta, 0.2), 2.0)
        let safeYellowDelta = min(max(yellowDelta, safeGreenDelta + 0.1), 4.0)
        let level: AtriaMetricZoneLevel = absDelta <= safeGreenDelta ? .green : (absDelta <= safeYellowDelta ? .yellow : .red)
        let recommendation: String
        switch level {
        case .green:
            recommendation = "Skin temperature deviation is close to your local sleep baseline."
        case .yellow:
            recommendation = "Skin temperature is slightly off your baseline -- room temperature, alcohol, cycle, travel, or illness onset can move it."
        case .red:
            recommendation = "Skin temperature is well off your baseline. Treat this as informational and compare with how you feel."
        }
        return AtriaMetricZone(level: level,
                               title: "Skin temperature baseline",
                               current: String(format: "%+.1f delta C vs sleep baseline.", delta),
                               targetSummary: String(format: "Green within +/-%.1f delta C, yellow within +/-%.1f, red farther from baseline.", safeGreenDelta, safeYellowDelta),
                               recommendation: recommendation,
                               disclaimer: "Research relative sleep-only deviation; not an absolute temperature. \(AtriaMetricZone.nonMedicalDisclaimer)")
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
