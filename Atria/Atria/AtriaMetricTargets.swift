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
        guard let pct else { return nil }
        let level: AtriaMetricZoneLevel
        if Double(pct) >= target.greenLower {
            level = .green
        } else if Double(pct) >= target.yellowLower {
            level = .yellow
        } else {
            level = .red
        }

        let recommendation: String
        switch level {
        case .green:
            recommendation = "Recovery is inside your target zone. Match training load to how you feel."
        case .yellow:
            recommendation = "Low recovery -- keep today light, hydrate, and get to bed earlier."
        case .red:
            recommendation = "Very low recovery -- prioritize rest, hydration, and an easy day."
        }

        return AtriaMetricZone(level: level,
                               title: "Recovery target",
                               current: "\(pct)% recovery is \(level.label.lowercased()).",
                               targetSummary: target.summaryText,
                               recommendation: recommendation,
                               disclaimer: AtriaMetricZone.nonMedicalDisclaimer)
    }

    static func strainZone(strain: Double, target: Double?) -> AtriaMetricZone? {
        guard let target else { return nil }
        let delta = strain - target
        let absDelta = abs(delta)
        let level: AtriaMetricZoneLevel = absDelta <= 1.5 ? .green : (absDelta <= 3.0 ? .yellow : .red)
        let recommendation: String
        switch level {
        case .green:
            recommendation = "Strain is inside today's recovery-scaled target band."
        case .yellow where delta > 0:
            recommendation = "You're past today's suggested strain for your recovery -- ease off to protect tomorrow."
        case .red where delta > 0:
            recommendation = "You're far past today's suggested strain. Keep the rest of the day light."
        case .yellow:
            recommendation = "Room to add load if you feel good."
        case .red:
            recommendation = "Well under today's target. Add easy movement or training only if it fits how you feel."
        }
        return AtriaMetricZone(level: level,
                               title: "Strain target",
                               current: String(format: "Strain %.1f vs target %.1f.", strain, target),
                               targetSummary: String(format: "Green within +/-1.5, yellow within +/-3.0, red farther from %.1f.", target),
                               recommendation: recommendation,
                               disclaimer: AtriaMetricZone.nonMedicalDisclaimer)
    }

    static func hrvZone(_ rmssd: Int?, baseline: Int?, baselineSamples: Int) -> AtriaMetricZone? {
        guard baselineSamples >= 7, let rmssd, let baseline, baseline > 0 else { return nil }
        let ratio = Double(rmssd) / Double(baseline)
        let level: AtriaMetricZoneLevel = ratio >= 0.95 ? .green : (ratio >= 0.85 ? .yellow : .red)
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
        let target = "Green >= \(Int((Double(baseline) * 0.95).rounded())) ms, yellow \(Int((Double(baseline) * 0.85).rounded()))-\(Int((Double(baseline) * 0.95).rounded()) - 1) ms, red below."
        return AtriaMetricZone(level: level,
                               title: "HRV target",
                               current: current,
                               targetSummary: target,
                               recommendation: recommendation,
                               disclaimer: AtriaMetricZone.nonMedicalDisclaimer)
    }

    static func restingHeartRateZone(_ bpm: Int?, baseline: Int?, baselineSamples: Int) -> AtriaMetricZone? {
        guard baselineSamples >= 7, let bpm, let baseline, baseline > 0 else { return nil }
        let delta = bpm - baseline
        let level: AtriaMetricZoneLevel = delta <= 3 ? .green : (delta <= 7 ? .yellow : .red)
        let recommendation: String
        switch level {
        case .green:
            recommendation = "Resting heart rate is near your baseline."
        case .yellow:
            recommendation = "Resting HR is up vs your norm -- fatigue, stress, dehydration, or poor sleep can move it. Hydrate and keep the day lighter."
        case .red:
            recommendation = "Resting HR is well above your norm. Prioritize rest, hydration, and an easy day."
        }
        let target = "Green <= \(baseline + 3) bpm, yellow \(baseline + 4)-\(baseline + 7) bpm, red above."
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

    static func vo2TrendZone(_ summary: VO2MaxEstimateSummary) -> AtriaMetricZone? {
        guard summary.value != nil, summary.trendText != "Learning" else { return nil }
        let trimmedTrend = summary.trendText.trimmingCharacters(in: .whitespacesAndNewlines)
        let level: AtriaMetricZoneLevel
        if trimmedTrend.localizedCaseInsensitiveContains("stable") {
            level = .yellow
        } else if trimmedTrend.hasPrefix("+") {
            level = .green
        } else if trimmedTrend.hasPrefix("-") {
            level = .red
        } else {
            return nil
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
                               targetSummary: "Green improving, yellow flat, red declining.",
                               recommendation: recommendation,
                               disclaimer: "Estimated fitness trend. \(AtriaMetricZone.nonMedicalDisclaimer)")
    }

    static func biologicalAgeZone(_ summary: BiologicalAgeSummary) -> AtriaMetricZone? {
        guard summary.isReady, let delta = summary.ageDelta else { return nil }
        let level: AtriaMetricZoneLevel
        if delta <= 0 {
            level = .green
        } else if delta <= 3 {
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
                               targetSummary: "Green younger than chronological age, yellow slightly older, red older.",
                               recommendation: recommendation,
                               disclaimer: summary.footnote)
    }

    static func respiratoryRateZone(_ breathsPerMinute: Double?,
                                    baseline: Double?,
                                    baselineSamples: Int) -> AtriaMetricZone? {
        guard baselineSamples >= 3,
              let breathsPerMinute,
              let baseline,
              baseline > 0 else { return nil }
        let delta = breathsPerMinute - baseline
        let absDelta = abs(delta)
        let level: AtriaMetricZoneLevel = absDelta <= 1.5 ? .green : (absDelta <= 3.0 ? .yellow : .red)
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
                               targetSummary: String(format: "Green within +/-1.5/min, yellow within +/-3.0/min, red farther from %.1f/min.", baseline),
                               recommendation: recommendation,
                               disclaimer: "Research sleep-only estimate. \(AtriaMetricZone.nonMedicalDisclaimer)")
    }

    static func skinTemperatureDeviationZone(_ summary: IMUAuditSummary.SkinTemperatureDeviationSummary) -> AtriaMetricZone? {
        guard summary.isReady, let delta = summary.latestDeltaCelsius else { return nil }
        let absDelta = abs(delta)
        let level: AtriaMetricZoneLevel = absDelta <= 0.5 ? .green : (absDelta <= 1.0 ? .yellow : .red)
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
                               targetSummary: "Green within +/-0.5 delta C, yellow within +/-1.0, red farther from baseline.",
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
