import Foundation

enum AtriaAnalytics {
    enum ManualSleep {
        static func inferredIsNap(start: Date,
                                  end: Date,
                                  currentSelection: Bool,
                                  calendar: Calendar = .current) -> Bool {
            guard end > start else { return currentSelection }
            let duration = end.timeIntervalSince(start)
            if duration >= AggregateSleepCandidate.strictMinimumDuration {
                return false
            }
            guard duration >= AggregateSleepCandidate.napMinimumDuration,
                  duration <= AggregateSleepCandidate.napMaximumSpan else {
                return currentSelection
            }
            let startHour = calendar.component(.hour, from: start)
            let endHour = calendar.component(.hour, from: end)
            let daytimeWindow = startHour >= 11 && endHour <= 20
            return daytimeWindow || duration < AggregateSleepCandidate.strictMinimumDuration
        }
    }

    enum TargetZones {
        static func recovery(_ pct: Int?,
                             target: AtriaMetricTarget = .recoveryRecommended) -> AtriaMetricZone? {
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

        static func strain(strain: Double,
                           target: Double?,
                           greenBand: Double = 1.5,
                           yellowBand: Double = 3.0) -> AtriaMetricZone? {
            guard let target else { return nil }
            let delta = strain - target
            let absDelta = abs(delta)
            let safeGreenBand = min(max(greenBand, 0.5), 5.0)
            let safeYellowBand = min(max(yellowBand, safeGreenBand + 0.5), 8.0)
            let level: AtriaMetricZoneLevel = absDelta <= safeGreenBand ? .green : (absDelta <= safeYellowBand ? .yellow : .red)
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
                                   targetSummary: String(format: "Green within +/-%.1f, yellow within +/-%.1f, red farther from %.1f.", safeGreenBand, safeYellowBand, target),
                                   recommendation: recommendation,
                                   disclaimer: AtriaMetricZone.nonMedicalDisclaimer)
        }

        static func hrv(_ rmssd: Int?,
                        baseline: Int?,
                        baselineSamples: Int,
                        greenRatio: Double = 0.95,
                        yellowRatio: Double = 0.85) -> AtriaMetricZone? {
            guard baselineSamples >= PersonalBaseline.trustedMinimumSamples,
                  let rmssd, let baseline, baseline > 0 else { return nil }
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
            let target = "Personal baseline · Green >= \(greenValue) ms, yellow \(yellowValue)-\(greenValue - 1) ms, red below."
            return AtriaMetricZone(level: level,
                                   title: "HRV target",
                                   current: current,
                                   targetSummary: target,
                                   recommendation: recommendation,
                                   disclaimer: AtriaMetricZone.nonMedicalDisclaimer)
        }

        static func restingHeartRate(_ bpm: Int?,
                                     baseline: Int?,
                                     baselineSamples: Int,
                                     greenDelta: Int = 3,
                                     yellowDelta: Int = 7) -> AtriaMetricZone? {
            guard baselineSamples >= PersonalBaseline.trustedMinimumSamples,
                  let bpm, let baseline, baseline > 0 else { return nil }
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
            let target = "Personal baseline · Green <= \(baseline + safeGreenDelta) bpm, yellow \(baseline + safeGreenDelta + 1)-\(baseline + safeYellowDelta) bpm, red above."
            return AtriaMetricZone(level: level,
                                   title: "Resting HR target",
                                   current: "\(bpm) bpm, \(delta >= 0 ? "+" : "")\(delta) vs baseline.",
                                   targetSummary: target,
                                   recommendation: recommendation,
                                   disclaimer: AtriaMetricZone.nonMedicalDisclaimer)
        }

        static func sleepEfficiency(_ efficiency: Double?,
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

        static func sleepDuration(_ hours: Double?, goalHours: Double = 8.0) -> AtriaMetricZone? {
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
                                   targetSummary: String(format: "User goal · Green >= %.1fh, yellow %.1f-%.1fh, red below %.1fh.",
                                                         safeGoal,
                                                         safeGoal * 0.85,
                                                         safeGoal - 0.1,
                                                         safeGoal * 0.85),
                                   recommendation: recommendation,
                                   disclaimer: AtriaMetricZone.nonMedicalDisclaimer)
        }

        static func steps(_ steps: Int?, goal: Int = 8_000) -> AtriaMetricZone? {
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
                                   targetSummary: "User goal · Green >= \(safeGoal), yellow \(safeGoal / 2)-\(safeGoal - 1), red below \(safeGoal / 2).",
                                   recommendation: recommendation,
                                   disclaimer: AtriaMetricZone.nonMedicalDisclaimer)
        }

        static func activeCalories(_ calories: Double?, goal: Int = 500) -> AtriaMetricZone? {
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
                                   targetSummary: "User goal · Green >= \(safeGoal) kcal, yellow \(safeGoal / 2)-\(safeGoal - 1) kcal, red below \(safeGoal / 2) kcal.",
                                   recommendation: recommendation,
                                   disclaimer: "Estimated from heart rate/profile. \(AtriaMetricZone.nonMedicalDisclaimer)")
        }

        static func vo2Trend(_ summary: VO2MaxEstimateSummary,
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

        static func biologicalAge(_ summary: BiologicalAgeSummary,
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

        static func respiratoryRate(_ breathsPerMinute: Double?,
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
                                   targetSummary: String(format: "Research baseline · Green within +/-%.1f/min, yellow within +/-%.1f/min, red farther from %.1f/min.", safeGreenDelta, safeYellowDelta, baseline),
                                   recommendation: recommendation,
                                   disclaimer: "Research sleep-only estimate. \(AtriaMetricZone.nonMedicalDisclaimer)")
        }

        static func skinTemperatureDeviation(_ summary: IMUAuditSummary.SkinTemperatureDeviationSummary,
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
                                   targetSummary: String(format: "Research baseline · Green within +/-%.1f delta C, yellow within +/-%.1f, red farther from baseline.", safeGreenDelta, safeYellowDelta),
                                   recommendation: recommendation,
                                   disclaimer: "Research relative sleep-only deviation; not an absolute temperature. \(AtriaMetricZone.nonMedicalDisclaimer)")
        }
    }

    enum Strain {
        struct ZoneSummary: Equatable {
            let secondsZ0: TimeInterval
            let secondsZ1: TimeInterval
            let secondsZ2: TimeInterval
            let secondsZ3: TimeInterval
            let secondsZ4: TimeInterval
            let droppedGapSeconds: TimeInterval
            let samples: Int
            let minHRReserve: Double
            let maxHRReserve: Double

            static let empty = ZoneSummary(secondsZ0: 0,
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

            static func + (lhs: ZoneSummary, rhs: ZoneSummary) -> ZoneSummary {
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
                    minReserve = min(lhs.minHRReserve, rhs.minHRReserve)
                    maxReserve = max(lhs.maxHRReserve, rhs.maxHRReserve)
                }
                return ZoneSummary(secondsZ0: lhs.secondsZ0 + rhs.secondsZ0,
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

        /// Banister TRIMP over a series of (secondsFromStart, bpm) samples.
        /// Each sample contributes dt · HRr · 0.64 · e^(1.92·HRr).
        static func trimp(_ series: [(t: Double, bpm: Int)], rest: Int, max: Int) -> Double {
            guard series.count > 1, max > rest else { return 0 }
            let span = Double(max - rest)
            var total = 0.0
            for index in 1..<series.count {
                let dtMin = (series[index].t - series[index - 1].t) / 60.0
                guard dtMin > 0, dtMin < 5 else { continue }
                let hrr = Swift.min(Swift.max((Double(series[index].bpm) - Double(rest)) / span, 0), 1)
                total += dtMin * hrr * 0.64 * exp(1.92 * hrr)
            }
            return total
        }

        static func activeCalories(_ samples: [HRSample], rest: Int, profile: AthleteProfile) -> Double? {
            guard samples.count > 1, rest > 0, profile.hasEnergyProfile else { return nil }
            let resting = energyKcalPerMinute(heartRate: rest, profile: profile)
            var total = 0.0
            for index in 1..<samples.count {
                let dtMin = samples[index].t.timeIntervalSince(samples[index - 1].t) / 60.0
                guard dtMin > 0, dtMin < 5, samples[index].bpm > 0 else { continue }
                let gross = energyKcalPerMinute(heartRate: samples[index].bpm, profile: profile)
                total += max(0, gross - resting) * dtMin
            }
            return total
        }

        /// HR-reserve zone seconds for auditing Strain behavior across rest to max.
        /// Buckets: z0 <30%, z1 30-50%, z2 50-70%, z3 70-85%, z4 >=85% HR reserve.
        static func zoneSummary(_ series: [(t: Double, bpm: Int)], rest: Int, max: Int) -> ZoneSummary {
            guard series.count > 1, max > rest else { return .empty }
            let span = Double(max - rest)
            var z0 = 0.0, z1 = 0.0, z2 = 0.0, z3 = 0.0, z4 = 0.0
            var dropped = 0.0
            var minReserve = 1.0
            var maxReserve = 0.0
            var usableSamples = 0
            for index in 1..<series.count {
                let dt = series[index].t - series[index - 1].t
                guard dt > 0 else { continue }
                if dt >= 5 {
                    dropped += dt
                    continue
                }
                let reserve = Swift.min(Swift.max((Double(series[index].bpm) - Double(rest)) / span, 0), 1)
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
                return ZoneSummary(secondsZ0: 0,
                                   secondsZ1: 0,
                                   secondsZ2: 0,
                                   secondsZ3: 0,
                                   secondsZ4: 0,
                                   droppedGapSeconds: dropped,
                                   samples: 0,
                                   minHRReserve: 0,
                                   maxHRReserve: 0)
            }
            return ZoneSummary(secondsZ0: z0,
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
        static func score(fromTRIMP trimp: Double) -> Double {
            guard trimp > 0 else { return 0 }
            return min(21.0 * (1 - exp(-trimp / 40.0)), 21.0)
        }

        private static func energyKcalPerMinute(heartRate: Int, profile: AthleteProfile) -> Double {
            let hr = Double(heartRate)
            let weight = profile.weightKg
            let age = Double(profile.age)
            switch profile.biologicalSex {
            case .male:
                return max(0, (-55.0969 + 0.6309 * hr + 0.1988 * weight + 0.2017 * age) / 4.184)
            case .female:
                return max(0, (-20.4022 + 0.4472 * hr - 0.1263 * weight + 0.0740 * age) / 4.184)
            case .unspecified:
                return 0
            }
        }
    }

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

        /// HR-only recovery: at/below baseline reads high; elevated resting reads low.
        static func restingOnly(restingNow: Int, baseline: Int) -> Int {
            guard restingNow > 0, baseline > 0 else { return 0 }
            let delta = Double(restingNow - baseline)
            return Int(min(max(75 - delta * 5, 1), 99).rounded())
        }

        /// HRV-driven recovery (the primary signal), blended with resting HR.
        static func estimate(hrvNow: Int, hrvBaseline: Int, restingNow: Int, restingBaseline: Int) -> Int {
            guard hrvNow > 0, hrvBaseline > 0 else {
                return restingOnly(restingNow: restingNow, baseline: restingBaseline)
            }
            let hrvScore = 66.0 * Double(hrvNow) / Double(hrvBaseline)
            let restingPenalty = restingNow > 0 && restingBaseline > 0
                ? 3.0 * Double(restingNow - restingBaseline) : 0
            return Int(min(max(hrvScore - restingPenalty, 1), 99).rounded())
        }

        /// Recovery v2: logistic personal z-score model. HRV is the primary signal,
        /// resting HR is inverted, sleep contributes once saved, and respiration is
        /// neutral until a trusted respiratory baseline exists.
        static func estimate(hrvSnapshot: HRVSnapshot?,
                             fallbackRMSSD: Int?,
                             restingNow: Int?,
                             baseline: PersonalBaseline,
                             hrvReferenceValidated: Bool = false,
                             sleepEfficiency: Double? = nil,
                             sleepDurationHours: Double? = nil,
                             respiratoryRate: Double? = nil,
                             respiratoryBaseline: (mean: Double, sd: Double, count: Int)? = nil) -> Estimate {
            guard let restingNow else {
                return Estimate(percent: nil, confidence: .learning,
                                usesHRV: false, detail: "learning: need resting HR")
            }

            guard baseline.hasTrustedRestingBaseline(),
                  let restingStats = baseline.restingStats else {
                return Estimate(percent: nil, confidence: .learning,
                                usesHRV: false,
                                detail: "learning RHR baseline \(baseline.restingSampleCount)/\(PersonalBaseline.trustedMinimumSamples)")
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

            guard baseline.hasTrustedHRVBaseline(),
                  let hrvStats = baseline.lnRMSSDStats,
                  hrvStats.count >= PersonalBaseline.trustedMinimumSamples else {
                return Estimate(percent: nil, confidence: .learning,
                                usesHRV: false,
                                detail: "learning HRV baseline \(baseline.hrvSampleCount)/\(PersonalBaseline.trustedMinimumSamples)")
            }

            let hrvZ = zScore(log(rmssdNow), mean: hrvStats.mean, sd: hrvStats.sd)
            guard let sleepZ = sleepRecoveryZ(efficiency: sleepEfficiency,
                                              durationHours: sleepDurationHours) else {
                return Estimate(percent: nil, confidence: .learning,
                                usesHRV: true,
                                detail: "learning: need saved sleep")
            }

            let respirationZ = respiratoryRecoveryZ(rate: respiratoryRate,
                                                    baseline: respiratoryBaseline)
            let blendedZ = 0.60 * hrvZ - 0.20 * restingZ + 0.15 * sleepZ + 0.05 * respirationZ
            let percent = logisticRecoveryPercent(z: blendedZ)
            let confidence: Estimate.Confidence = hrvReferenceValidated ? .validated : .personalBaseline
            let respirationDetail = respirationZ == 0
                ? "Resp neutral"
                : String(format: "Resp z %.1f", respirationZ)
            return Estimate(percent: percent, confidence: confidence,
                            usesHRV: true,
                            detail: String(format: "lnRMSSD z %.1f · RHR z %.1f · Sleep z %.1f · %@", hrvZ, restingZ, sleepZ, respirationDetail))
        }

        private static func zScore(_ value: Double, mean: Double, sd: Double) -> Double {
            guard sd > 0.1 else { return 0 }
            return (value - mean) / sd
        }

        private static func logisticRecoveryPercent(z: Double) -> Int {
            let k = 1.6
            let z0 = -0.20
            let raw = 100.0 / (1.0 + exp(-k * (z - z0)))
            return Int(min(max(raw, 1), 99).rounded())
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

        private static func respiratoryRecoveryZ(rate: Double?,
                                                 baseline: (mean: Double, sd: Double, count: Int)?) -> Double {
            guard let rate,
                  rate > 0,
                  let baseline,
                  baseline.count >= PersonalBaseline.trustedMinimumSamples,
                  baseline.sd > 0.1 else { return 0 }
            return min(max(-zScore(rate, mean: baseline.mean, sd: baseline.sd), -2), 2)
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
            let pace = agingPace(biologicalAge: biologicalAge,
                                 chronologicalAge: chronologicalAge,
                                 factors: factors)
            return BiologicalAgeSummary(biologicalAge: biologicalAge,
                                        chronologicalAge: chronologicalAge,
                                        ageDelta: biologicalAge - chronologicalAge,
                                        agingPaceText: pace.text,
                                        agingPaceDetail: pace.detail,
                                        factors: factors,
                                        blockers: [],
                                        footnote: BiologicalAgeSummary.footnoteText)
        }

        static func agingPace(biologicalAge: Int,
                              chronologicalAge: Int,
                              factors: [BioAgeFactor]) -> (text: String, detail: String) {
            let delta = biologicalAge - chronologicalAge
            let youngerWeight = factors
                .filter { $0.direction == .younger }
                .reduce(0) { $0 + $1.weight }
            let olderWeight = factors
                .filter { $0.direction == .older }
                .reduce(0) { $0 + $1.weight }
            let dominant = youngerWeight >= olderWeight ? "younger" : "older"
            if delta <= -3 {
                return ("Younger pace",
                        "Current estimate is \(abs(delta))y younger; \(dominant) factors carry the most weight.")
            }
            if delta >= 3 {
                return ("Older pace",
                        "Current estimate is \(delta)y older; \(dominant) factors carry the most weight.")
            }
            return ("On pace",
                    "Current estimate is close to chronological age; weekly trend unlocks after more local estimates.")
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
            let reference = sex == .female ? femaleVO2AgeReference : maleVO2AgeReference
            return interpolatedAgeEquivalent(for: vo2,
                                             reference: reference,
                                             higherIsYounger: true)
        }

        // Compact local age-equivalent reference tables adapted from ACSM/Cooper
        // VO2max norms, resting-HR norms, and age-related RMSSD decline. Values are
        // approximate decade anchors; interpolation keeps the estimate monotonic
        // while avoiding a fake precision curve.
        private static let maleVO2AgeReference: [(age: Int, value: Double)] = [
            (20, 52.0), (30, 48.5), (40, 45.0), (50, 41.5),
            (60, 38.0), (70, 34.5), (80, 31.0), (90, 27.5)
        ]

        private static let femaleVO2AgeReference: [(age: Int, value: Double)] = [
            (20, 44.0), (30, 41.0), (40, 38.0), (50, 35.0),
            (60, 32.0), (70, 29.0), (80, 26.0), (90, 23.0)
        ]

        private static let restingHRAgeReference: [(age: Int, value: Double)] = [
            (20, 58), (30, 60), (40, 62), (50, 64),
            (60, 66), (70, 68), (80, 70), (90, 72)
        ]

        private static let rmssdAgeReference: [(age: Int, value: Double)] = [
            (20, 70), (30, 58), (40, 46), (50, 36),
            (60, 28), (70, 22), (80, 18), (90, 14)
        ]

        private static func interpolatedAgeEquivalent(for value: Double,
                                                      reference: [(age: Int, value: Double)],
                                                      higherIsYounger: Bool) -> Int {
            guard let youngest = reference.first,
                  let oldest = reference.last else { return 90 }
            if higherIsYounger {
                if value >= youngest.value { return 18 }
                if value <= oldest.value { return 90 }
            } else {
                if value <= youngest.value { return 18 }
                if value >= oldest.value { return 90 }
            }

            for index in 1..<reference.count {
                let previous = reference[index - 1]
                let next = reference[index]
                let insideBand = higherIsYounger
                    ? (value <= previous.value && value >= next.value)
                    : (value >= previous.value && value <= next.value)
                guard insideBand else { continue }
                let numerator = higherIsYounger ? previous.value - value : value - previous.value
                let denominator = abs(previous.value - next.value)
                let fraction = numerator / max(denominator, 0.01)
                let age = Double(previous.age) + fraction * Double(next.age - previous.age)
                return min(max(Int(age.rounded()), 18), 90)
            }
            return 90
        }

        static func rhrAgeEquivalent(_ restingHR: Int) -> Int {
            interpolatedAgeEquivalent(for: Double(restingHR),
                                      reference: restingHRAgeReference,
                                      higherIsYounger: false)
        }

        static func hrvAgeEquivalent(_ rmssd: Int) -> Int {
            interpolatedAgeEquivalent(for: Double(rmssd),
                                      reference: rmssdAgeReference,
                                      higherIsYounger: true)
        }

        static func sleepAgeEquivalent(durationHours: Double,
                                       efficiency: Double,
                                       consistencyPercent: Int?,
                                       chronologicalAge: Int) -> Int {
            let durationPenalty = abs(durationHours - 7.5) * 2.0
            let efficiencyPenalty = max(0, 0.85 - efficiency) * 35
            let consistencyPenalty = consistencyPercent.map { max(0, 80 - Double($0)) / 8.0 } ?? 0
            let bonus = durationPenalty < 1.0 && efficiency >= 0.88 && (consistencyPercent ?? 80) >= 85 ? -4.0 : 0
            return min(max(Int((Double(chronologicalAge) + durationPenalty + efficiencyPenalty + consistencyPenalty + bonus).rounded()), 18), 90)
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
                .map { Strain.score(fromTRIMP: $0.value) }
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
