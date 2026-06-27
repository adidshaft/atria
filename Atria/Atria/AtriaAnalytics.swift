import Foundation

enum AtriaAnalytics {
    enum Recovery {
        struct Estimate: Equatable {
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

        /// Recovery v2: lnRMSSD z-score against a personal rolling baseline, blended
        /// with resting-HR z-score and saved sleep evidence. Recovery displays after
        /// local data sufficiency; external reference validation upgrades the
        /// confidence tier and HealthKit writes, but does not block in-app display.
        static func estimate(hrvSnapshot: HRVSnapshot?,
                             fallbackRMSSD: Int?,
                             restingNow: Int?,
                             baseline: PersonalBaseline,
                             hrvReferenceValidated: Bool = false,
                             sleepEfficiency: Double? = nil,
                             sleepDurationHours: Double? = nil) -> Estimate {
            guard let restingNow else {
                return Estimate(percent: nil, confidence: .learning,
                                usesHRV: false, detail: "learning: need resting HR")
            }

            guard let restingStats = baseline.restingStats else {
                return Estimate(percent: nil, confidence: .learning,
                                usesHRV: false, detail: "learning: need baseline")
            }

            let restingZ = zScore(Double(restingNow), mean: restingStats.mean, sd: restingStats.sd)
            let rmssdNow = hrvSnapshot?.isReady == true
                ? hrvSnapshot?.rmssd
                : fallbackRMSSD.map(Double.init)
            guard let rmssdNow, rmssdNow > 0 else {
                return Estimate(percent: nil, confidence: .learning,
                                usesHRV: false,
                                detail: "learning: need a clean HRV window")
            }

            guard let hrvStats = baseline.lnRMSSDStats, hrvStats.count >= 7 else {
                return Estimate(percent: nil, confidence: .learning,
                                usesHRV: false,
                                detail: "learning HRV baseline \(baseline.hrvSampleCount)/7")
            }

            let hrvZ = zScore(log(rmssdNow), mean: hrvStats.mean, sd: hrvStats.sd)
            guard let sleepZ = sleepRecoveryZ(efficiency: sleepEfficiency,
                                              durationHours: sleepDurationHours) else {
                return Estimate(percent: nil, confidence: .learning,
                                usesHRV: true,
                                detail: "learning: need saved sleep")
            }

            let blendedZ = 0.60 * hrvZ - 0.25 * restingZ + 0.15 * sleepZ
            let percent = Int(min(max(50 + blendedZ * 16, 1), 99).rounded())
            let confidence: Estimate.Confidence = hrvReferenceValidated ? .validated : .personalBaseline
            return Estimate(percent: percent, confidence: confidence,
                            usesHRV: true,
                            detail: String(format: "lnRMSSD z %.1f · RHR z %.1f · Sleep z %.1f", hrvZ, restingZ, sleepZ))
        }

        private static func zScore(_ value: Double, mean: Double, sd: Double) -> Double {
            guard sd > 0.1 else { return 0 }
            return (value - mean) / sd
        }

        private static func sleepRecoveryZ(efficiency: Double?, durationHours: Double?) -> Double? {
            var components: [Double] = []
            if let efficiency {
                components.append((min(max(efficiency, 0), 1) - 0.85) / 0.10)
            }
            if let durationHours, durationHours > 0 {
                let capped = min(max(durationHours, 0), 9)
                components.append((capped - 7.0) / 1.5)
            }
            guard !components.isEmpty else { return nil }
            let average = components.reduce(0, +) / Double(components.count)
            return min(max(average, -2), 2)
        }
    }

    enum VO2Max {
        static func summary(rest: Int,
                            maxHR: Int,
                            restingSamples: Int,
                            maxHRMeasured: Bool,
                            restingTrend: [Int]) -> VO2MaxEstimateSummary {
            guard rest > 0, maxHR > rest else {
                return learning(detail: "Need RHR",
                                narrative: "Atria needs resting HR and HRmax before estimating VO2max.",
                                trendDetail: "Needs resting baseline.")
            }
            guard restingSamples >= 7 else {
                return learning(detail: "\(restingSamples)/7 RHR",
                                narrative: "Atria needs 7 resting nights before estimating VO2max.",
                                trendDetail: "\(restingSamples)/7 RHR nights.")
            }
            guard maxHRMeasured else {
                return learning(detail: "Need HRmax",
                                narrative: "Atria needs a measured HRmax before estimating VO2max.",
                                trendDetail: "Needs measured HRmax.")
            }

            let boundedEstimate = boundedEstimate(rest: rest, maxHR: maxHR)
            let confidence = "rough estimate"
            let detail = "\(confidence) · RHR \(rest) · HRmax \(maxHR)"
            let trend = trendText(currentEstimate: boundedEstimate,
                                  maxHR: maxHR,
                                  restingTrend: restingTrend)
            return VO2MaxEstimateSummary(value: boundedEstimate,
                                         confidence: confidence,
                                         detail: detail,
                                         narrative: "Rough estimate from measured max HR and resting baseline.",
                                         trendText: trend.text,
                                         trendDetail: trend.detail,
                                         trendDelta: trend.delta)
        }

        static func estimate(rest: Int, maxHR: Int) -> Double? {
            guard rest > 0, maxHR > rest else { return nil }
            return boundedEstimate(rest: rest, maxHR: maxHR)
        }

        static func trendText(currentEstimate: Double,
                              maxHR: Int,
                              restingTrend: [Int]) -> (text: String, detail: String, delta: Double?) {
            let rests = restingTrend.filter { $0 > 0 }
            guard rests.count >= 2, let oldestRest = rests.first else {
                return ("Learning", "Needs 2 cached RHR points.", nil)
            }
            let previousEstimate = boundedEstimate(rest: oldestRest, maxHR: maxHR)
            let delta = currentEstimate - previousEstimate
            if abs(delta) < 0.2 {
                return ("Stable", "vs \(rests.count)-point RHR trend.", delta)
            }
            return (String(format: "%+.1f", delta), "vs \(rests.count)-point RHR trend.", delta)
        }

        private static func boundedEstimate(rest: Int, maxHR: Int) -> Double {
            let rawEstimate = 15.3 * Double(maxHR) / Double(rest)
            return min(max(rawEstimate, 20), 80)
        }

        private static func learning(detail: String,
                                     narrative: String,
                                     trendDetail: String) -> VO2MaxEstimateSummary {
            VO2MaxEstimateSummary(value: nil,
                                  confidence: "learning",
                                  detail: detail,
                                  narrative: narrative,
                                  trendText: "Learning",
                                  trendDetail: trendDetail,
                                  trendDelta: nil)
        }
    }

    enum BiologicalAge {
        // Reference curves are compact local approximations of commonly published
        // ACSM/Cooper VO2max percentile tables, resting-HR norms, age-related RMSSD
        // decline, adult sleep guidance, activity norms, and BMI bands. They are
        // monotonic and intentionally conservative; no network or medical inference.
        static func summary(chronologicalAge: Int, factors: [BioAgeFactor]) -> BiologicalAgeSummary {
            let weighted = factors.reduce(0) { $0 + Double($1.ageEquivalent) * $1.weight }
            let totalWeight = factors.reduce(0) { $0 + $1.weight }
            let unclamped = Int((weighted / max(totalWeight, 0.01)).rounded())
            let biologicalAge = min(max(unclamped, chronologicalAge - 20), chronologicalAge + 20)
            return BiologicalAgeSummary(biologicalAge: biologicalAge,
                                        chronologicalAge: chronologicalAge,
                                        ageDelta: biologicalAge - chronologicalAge,
                                        factors: factors,
                                        blockers: [],
                                        footnote: BiologicalAgeSummary.footnoteText)
        }

        static func factor(id: String,
                           label: String,
                           ageEquivalent: Int,
                           chronologicalAge: Int,
                           weight: Double,
                           detail: String) -> BioAgeFactor {
            let delta = ageEquivalent - chronologicalAge
            return BioAgeFactor(id: id,
                                label: label,
                                ageEquivalent: ageEquivalent,
                                deltaVsChronological: delta,
                                direction: delta == 0 ? .neutral : (delta < 0 ? .younger : .older),
                                weight: weight,
                                detail: detail)
        }

        static func vo2AgeEquivalent(_ vo2: Double, sex: AthleteProfile.BiologicalSex) -> Int {
            let baseAt20 = sex == .female ? 44.0 : 52.0
            let yearlyDrop = sex == .female ? 0.30 : 0.35
            return min(max(Int((20 + (baseAt20 - vo2) / yearlyDrop).rounded()), 18), 90)
        }

        static func rhrAgeEquivalent(_ restingHR: Int) -> Int {
            min(max(Int((30 + Double(restingHR - 60) * 0.8).rounded()), 18), 90)
        }

        static func hrvAgeEquivalent(_ rmssd: Int) -> Int {
            let safe = max(8, Double(rmssd))
            return min(max(Int((20 - log(safe / 70.0) / 0.018).rounded()), 18), 90)
        }

        static func sleepAgeEquivalent(durationHours: Double,
                                       efficiency: Double,
                                       chronologicalAge: Int) -> Int {
            let durationPenalty = abs(durationHours - 7.5) * 2.0
            let efficiencyPenalty = max(0, 0.85 - efficiency) * 35
            let bonus = durationPenalty < 1.0 && efficiency >= 0.88 ? -4.0 : 0
            return min(max(Int((Double(chronologicalAge) + durationPenalty + efficiencyPenalty + bonus).rounded()), 18), 90)
        }

        static func activityAgeEquivalent(_ chronicLoad: Double,
                                          chronologicalAge: Int) -> Int {
            let delta = min(max((chronicLoad - 25) / 3.0, -8), 8)
            return min(max(Int((Double(chronologicalAge) - delta).rounded()), 18), 90)
        }

        static func bmiAgeEquivalent(_ bmi: Double,
                                     chronologicalAge: Int) -> Int {
            let penalty = bmi < 18.5 ? (18.5 - bmi) * 1.2 : max(0, bmi - 24.9) * 0.8
            return min(max(Int((Double(chronologicalAge) + penalty).rounded()), 18), 90)
        }
    }

    enum TrainingLoad {
        static func summary(sessions: [SavedSession],
                            rest: Int,
                            maxHR: Int,
                            calendar: Calendar = .current) -> TrainingLoadSummary {
            guard maxHR > rest else { return .learning }
            var trimpByDay: [Date: Double] = [:]
            for session in sessions where session.points.count >= 2 {
                let day = calendar.startOfDay(for: session.start)
                trimpByDay[day, default: 0] += session.trimp(rest: rest, max: maxHR)
            }
            let dailyStrains = trimpByDay
                .sorted { $0.key > $1.key }
                .map { Metrics.strain(fromTRIMP: $0.value) }
            return summary(dailyStrains: dailyStrains)
        }

        static func summary(dailyStrains: [Double]) -> TrainingLoadSummary {
            guard !dailyStrains.isEmpty else { return .learning }

            let acuteRollups = Array(dailyStrains.prefix(7))
            let chronicRollups = Array(dailyStrains.prefix(28))
            let acute = average(acuteRollups) ?? 0
            let chronic = average(chronicRollups) ?? 0
            let ratio = chronic > 0 ? acute / chronic : nil
            let monotony = trainingMonotony(acuteRollups)
            let enoughAcute = acuteRollups.count >= 3
            let enoughChronic = chronicRollups.count >= 14
            let confidence: String
            if enoughChronic {
                confidence = "local"
            } else if enoughAcute {
                confidence = "partial"
            } else {
                confidence = "learning"
            }

            let targetBand = targetBand(acute: acute, ratio: ratio, enoughAcute: enoughAcute)
            let acwrSignal = acwrReadinessSignal(ratio: ratio, enoughChronic: enoughChronic)
            let monotonySignal = monotonyReadinessSignal(monotony: monotony, enoughAcute: enoughAcute)
            let readiness = trainingReadiness(acwrSignal: acwrSignal,
                                             monotonySignal: monotonySignal,
                                             ratio: ratio)
            let detail = detail(confidence: confidence, readiness: readiness, ratio: ratio)

            return TrainingLoadSummary(acuteLoad: acute,
                                       chronicLoad: chronic,
                                       ratio: ratio,
                                       monotony: monotony,
                                       confidence: confidence,
                                       readiness: readiness,
                                       acwrSignal: acwrSignal,
                                       monotonySignal: monotonySignal,
                                       targetBand: targetBand,
                                       detail: detail)
        }

        static func trainingMonotony(_ dailyStrains: [Double]) -> Double? {
            guard dailyStrains.count >= 3,
                  let mean = average(dailyStrains),
                  mean > 0 else { return nil }
            let variance = dailyStrains.reduce(0) { total, value in
                total + pow(value - mean, 2)
            } / Double(dailyStrains.count)
            let standardDeviation = sqrt(variance)
            guard standardDeviation > 0.05 else { return 9.99 }
            return min(mean / standardDeviation, 9.99)
        }

        static func acwrReadinessSignal(ratio: Double?, enoughChronic: Bool) -> String {
            guard enoughChronic, let ratio else { return "learning" }
            if ratio >= 1.50 || ratio < 0.60 { return "bad" }
            if ratio > 1.30 || ratio < 0.80 { return "watch" }
            return "good"
        }

        static func monotonyReadinessSignal(monotony: Double?, enoughAcute: Bool) -> String {
            guard enoughAcute, let monotony else { return "learning" }
            if monotony >= 2.50 { return "bad" }
            if monotony >= 2.00 { return "watch" }
            return "good"
        }

        static func trainingReadiness(acwrSignal: String,
                                      monotonySignal: String,
                                      ratio: Double?) -> String {
            guard acwrSignal != "learning" || monotonySignal != "learning" else { return "learning" }
            if acwrSignal == "bad" || monotonySignal == "bad" { return "rundown" }
            if acwrSignal == "watch" || monotonySignal == "watch" { return "strained" }
            if let ratio, ratio < 0.80 { return "primed" }
            return "balanced"
        }

        private static func targetBand(acute: Double,
                                       ratio: Double?,
                                       enoughAcute: Bool) -> ClosedRange<Double>? {
            guard enoughAcute else { return nil }
            if let ratio {
                if ratio > 1.30 {
                    return max(0, acute - 4)...max(0, acute - 1)
                }
                if ratio < 0.80 {
                    return acute...min(21, acute + 3)
                }
            }
            return max(0, acute - 1.5)...min(21, acute + 1.5)
        }

        private static func detail(confidence: String,
                                   readiness: String,
                                   ratio: Double?) -> String {
            if confidence == "learning" {
                return TrainingLoadSummary.learning.detail
            }
            if readiness == "rundown" {
                return "Rundown: training load is either spiking or too repetitive. Keep the next session easy."
            }
            if readiness == "strained" {
                return "Strained: ACWR or monotony is elevated. Favor recovery or a lighter day."
            }
            if readiness == "primed" {
                return "Primed: recent strain is below your base, with room to add load if recovery feels good."
            }
            if let ratio {
                if ratio > 1.30 {
                    return "Acute load is running ahead of your 28-day base."
                }
                if ratio < 0.80 {
                    return "Recent strain is below your longer baseline."
                }
                return "Recent strain is aligned with your longer baseline."
            }
            return TrainingLoadSummary.learning.detail
        }

        private static func average(_ values: [Double]) -> Double? {
            guard !values.isEmpty else { return nil }
            return values.reduce(0, +) / Double(values.count)
        }
    }
}
