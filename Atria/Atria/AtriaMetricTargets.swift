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
        guard baselineSamples >= 7, let rmssd, let baseline, baseline > 0 else { return nil }
        let ratio = Double(rmssd) / Double(baseline)
        let safeYellow = min(max(yellowRatio, 0.50), 0.98)
        let safeGreen = min(max(greenRatio, safeYellow + 0.01), 1.20)
        let level: AtriaMetricZoneLevel = ratio >= safeGreen ? .green : (ratio >= safeYellow ? .yellow : .red)
        let recommendation: String
        switch level {
        case .green:
            recommendation = "HRV is near your personal baseline. Match your day to recovery and sleep."
        case .yellow:
            recommendation = "HRV below your norm -- usually stress, short sleep, alcohol, or heavy load. Prioritize sleep and an easier day."
        case .red:
            recommendation = "HRV is well below your norm. Keep today easy and focus on sleep, hydration, and recovery."
        }
        let current = "\(rmssd) ms vs \(baseline) ms baseline."
        let greenValue = Int((Double(baseline) * safeGreen).rounded())
        let yellowValue = Int((Double(baseline) * safeYellow).rounded())
        let target = "Green >= \(greenValue) ms, yellow \(yellowValue)-\(greenValue - 1) ms, red below."
        return AtriaMetricZone(level: level,
                               title: "HRV target",
                               current: current,
                               targetSummary: target,
                               recommendation: recommendation,
                               disclaimer: AtriaMetricZone.nonMedicalDisclaimer)
    }

    static func restingHeartRateZone(_ bpm: Int?,
                                     baseline: Int?,
                                     baselineSamples: Int,
                                     greenDelta: Int = 3,
                                     yellowDelta: Int = 7) -> AtriaMetricZone? {
        guard baselineSamples >= 7, let bpm, let baseline, baseline > 0 else { return nil }
        let delta = bpm - baseline
        let safeGreenDelta = min(max(greenDelta, 0), 12)
        let safeYellowDelta = min(max(yellowDelta, safeGreenDelta + 1), 20)
        let level: AtriaMetricZoneLevel = delta <= safeGreenDelta ? .green : (delta <= safeYellowDelta ? .yellow : .red)
        let recommendation: String
        switch level {
        case .green:
            recommendation = "Resting heart rate is near your baseline."
        case .yellow:
            recommendation = "Resting HR is up vs your norm -- fatigue, stress, dehydration, or poor sleep can move it. Hydrate and keep the day lighter."
        case .red:
            recommendation = "Resting HR is well above your norm. Prioritize rest, hydration, and an easy day."
        }
        let target = "Green <= \(baseline + safeGreenDelta) bpm, yellow \(baseline + safeGreenDelta + 1)-\(baseline + safeYellowDelta) bpm, red above."
        return AtriaMetricZone(level: level,
                               title: "Resting HR target",
                               current: "\(bpm) bpm, \(delta >= 0 ? "+" : "")\(delta) vs baseline.",
                               targetSummary: target,
                               recommendation: recommendation,
                               disclaimer: AtriaMetricZone.nonMedicalDisclaimer)
    }

    static func sleepEfficiencyZone(_ efficiency: Double?,
                                    greenLower: Double = 90,
                                    yellowLower: Double = 80) -> AtriaMetricZone? {
        guard let efficiency else { return nil }
        let pct = Int((efficiency * 100).rounded())
        let safeYellow = min(max(yellowLower, 50), 95)
        let safeGreen = min(max(greenLower, safeYellow + 1), 99)
        let level: AtriaMetricZoneLevel = Double(pct) >= safeGreen ? .green : (Double(pct) >= safeYellow ? .yellow : .red)
        let recommendation: String
        switch level {
        case .green:
            recommendation = "Sleep efficiency is in the target zone."
        case .yellow:
            recommendation = "Restless night -- cut late caffeine or alcohol, cool the room, and keep bed/wake times consistent."
        case .red:
            recommendation = "Sleep was inefficient. Keep the room cool and dark, reduce late stimulants, and protect a consistent schedule."
        }
        return AtriaMetricZone(level: level,
                               title: "Sleep efficiency target",
                               current: "\(pct)% sleep efficiency.",
                               targetSummary: "Green >= \(Int(safeGreen.rounded()))%, yellow \(Int(safeYellow.rounded()))-\(Int(safeGreen.rounded()) - 1)%, red below \(Int(safeYellow.rounded()))%.",
                               recommendation: recommendation,
                               disclaimer: AtriaMetricZone.nonMedicalDisclaimer)
    }

    static func sleepDurationZone(_ hours: Double?, goalHours: Double = 8.0) -> AtriaMetricZone? {
        guard let hours, hours > 0 else { return nil }
        let safeGoal = min(max(goalHours, 4.0), 12.0)
        let ratio = hours / safeGoal
        let level: AtriaMetricZoneLevel = ratio >= 1.0 ? .green : (ratio >= 0.85 ? .yellow : .red)
        let remaining = max(0, safeGoal - hours)
        let recommendation: String
        switch level {
        case .green:
            recommendation = "Sleep duration met your goal. Keep bed and wake times consistent."
        case .yellow:
            recommendation = String(format: "A little under your sleep goal -- aim for about %.1fh more and keep bed and wake times consistent.", remaining)
        case .red:
            recommendation = String(format: "Under your sleep need -- aim for about %.1fh more and keep bed and wake times consistent.", remaining)
        }
        return AtriaMetricZone(level: level,
                               title: "Sleep duration target",
                               current: String(format: "%.1fh sleep vs %.1fh goal.", hours, safeGoal),
                               targetSummary: String(format: "Green >= %.1fh, yellow %.1f-%.1fh, red below %.1fh.",
                                                     safeGoal,
                                                     safeGoal * 0.85,
                                                     safeGoal - 0.1,
                                                     safeGoal * 0.85),
                               recommendation: recommendation,
                               disclaimer: AtriaMetricZone.nonMedicalDisclaimer)
    }

    static func stepsZone(_ steps: Int?, goal: Int = 8_000) -> AtriaMetricZone? {
        guard let steps, steps > 0 else { return nil }
        let safeGoal = max(goal, 1_000)
        let level: AtriaMetricZoneLevel = steps >= safeGoal ? .green : (steps >= safeGoal / 2 ? .yellow : .red)
        let recommendation: String
        switch level {
        case .green:
            recommendation = "Steps are at or above your daily goal."
        case .yellow:
            recommendation = "Below your step goal -- a short walk closes the gap."
        case .red:
            recommendation = "Well below your step goal. Add easy movement when it fits your day."
        }
        return AtriaMetricZone(level: level,
                               title: "Steps target",
                               current: "\(steps) steps vs \(safeGoal) goal.",
                               targetSummary: "Green >= \(safeGoal), yellow \(safeGoal / 2)-\(safeGoal - 1), red below \(safeGoal / 2).",
                               recommendation: recommendation,
                               disclaimer: AtriaMetricZone.nonMedicalDisclaimer)
    }

    static func activeCaloriesZone(_ calories: Double?, goal: Int = 500) -> AtriaMetricZone? {
        guard let calories, calories > 0 else { return nil }
        let roundedCalories = Int(calories.rounded())
        let safeGoal = min(max(goal, 100), 3_000)
        let level: AtriaMetricZoneLevel = roundedCalories >= safeGoal ? .green : (roundedCalories >= safeGoal / 2 ? .yellow : .red)
        let recommendation: String
        switch level {
        case .green:
            recommendation = "Estimated active calories are at or above your daily goal."
        case .yellow:
            recommendation = "Below your active-calorie goal -- a short walk or easy session can close the gap."
        case .red:
            recommendation = "Well below your active-calorie goal. Add easy movement only if it fits your recovery."
        }
        return AtriaMetricZone(level: level,
                               title: "Calories target",
                               current: "\(roundedCalories) kcal vs \(safeGoal) kcal goal.",
                               targetSummary: "Green >= \(safeGoal) kcal, yellow \(safeGoal / 2)-\(safeGoal - 1) kcal, red below \(safeGoal / 2) kcal.",
                               recommendation: recommendation,
                               disclaimer: "Estimated from heart rate/profile. \(AtriaMetricZone.nonMedicalDisclaimer)")
    }

    static func vo2TrendZone(_ summary: VO2MaxEstimateSummary,
                             greenDelta: Double = 0.2,
                             redDelta: Double = -0.2) -> AtriaMetricZone? {
        guard summary.value != nil,
              summary.trendText != "Learning",
              let trendDelta = summary.trendDelta else { return nil }
        let trimmedTrend = summary.trendText.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeGreenDelta = min(max(greenDelta, 0.0), 2.0)
        let safeRedDelta = max(min(redDelta, -0.05), -2.0)
        let level: AtriaMetricZoneLevel
        if trendDelta >= safeGreenDelta {
            level = .green
        } else if trendDelta <= safeRedDelta {
            level = .red
        } else {
            level = .yellow
        }

        let recommendation: String
        switch level {
        case .green:
            recommendation = "VO2max trend is improving. Keep the cardio and recovery habits consistent."
        case .yellow:
            recommendation = "VO2max trend is flat -- consistent cardio, Zone 2, intervals, and sleep move this most."
        case .red:
            recommendation = "Trending the wrong way -- consistent cardio, Zone 2, intervals, and sleep move this most."
        }

        return AtriaMetricZone(level: level,
                               title: "VO2max trend",
                               current: "Trend \(trimmedTrend), \(summary.trendDetail)",
                               targetSummary: String(format: "Green >= +%.1f, yellow %.1f to %.1f, red <= %.1f.", safeGreenDelta, safeRedDelta, safeGreenDelta, safeRedDelta),
                               recommendation: recommendation,
                               disclaimer: "Estimated fitness trend. \(AtriaMetricZone.nonMedicalDisclaimer)")
    }

    static func biologicalAgeZone(_ summary: BiologicalAgeSummary,
                                  greenOlderDelta: Int = 0,
                                  yellowOlderDelta: Int = 3) -> AtriaMetricZone? {
        guard summary.isReady, let delta = summary.ageDelta else { return nil }
        let safeGreenDelta = min(max(greenOlderDelta, -10), 10)
        let safeYellowDelta = min(max(yellowOlderDelta, safeGreenDelta + 1), 20)
        let level: AtriaMetricZoneLevel
        if delta <= safeGreenDelta {
            level = .green
        } else if delta <= safeYellowDelta {
            level = .yellow
        } else {
            level = .red
        }

        let recommendation: String
        switch level {
        case .green:
            recommendation = "Body age is on the younger side for your profile. Keep the fitness, sleep, HRV, and recovery habits consistent."
        case .yellow:
            recommendation = "Body age is slightly older than your profile. Consistent cardio, sleep, HRV, and recovery habits move this estimate most."
        case .red:
            recommendation = "Body age is older than your profile. Prioritize consistent cardio, sleep regularity, recovery, and easier days when strain is high."
        }

        return AtriaMetricZone(level: level,
                               title: "Body age target",
                               current: "\(summary.valueText), \(summary.detailText).",
                               targetSummary: "Green <= +\(safeGreenDelta)y vs chronological, yellow <= +\(safeYellowDelta)y, red above.",
                               recommendation: recommendation,
                               disclaimer: summary.footnote)
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
