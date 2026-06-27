import Foundation

enum AtriaAnalytics {
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
