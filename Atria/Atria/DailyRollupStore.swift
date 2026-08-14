import Foundation

struct DailyRollupVitals: Codable, Equatable {
    struct Stat: Codable, Equatable {
        let mean: Double
        let sd: Double
        let n: Int
    }

    let rhr: Stat?
    let hrv: Stat?
    let resp: Stat?
}

/// The recovery score and the model provenance that produced it. Recovery is a
/// once-per-morning value, so every surface must carry these fields together
/// instead of replacing only `score` on a newly computed live estimate.
struct FrozenRecoverySummary: Codable, Equatable {
    /// The observations and personal comparators that were present when a
    /// morning Recovery result was minted. This is a receipt, not an input to a
    /// later recalculation: completed cycles must remain inspectable without
    /// being silently reinterpreted from today's rolling baseline.
    struct InputSnapshot: Codable, Equatable {
        struct Baseline: Codable, Equatable {
            let mean: Double
            let standardDeviation: Double?
            let sampleCount: Int
            let trusted: Bool
        }

        /// Shadow evidence for a future Recovery model. It is independent from
        /// the v2 mean/SD inputs above, so historic v2 scores stay exactly
        /// replayable while outcome validation evaluates a robust 30-day
        /// candidate. Optional fields preserve decoding of existing receipts.
        struct RecoveryComparison: Codable, Equatable {
            struct Statistic: Codable, Equatable {
                let location: Double
                let scale: Double
                let sampleCount: Int
            }

            let asOf: Date
            let comparisonHorizonDays: Int
            let recentQualificationHorizonDays: Int
            let statistic: String
            let restingHeartRate: Statistic?
            let hrv: Statistic?
            let recentQualifiedRestingDays: Int
            let recentQualifiedHRVNights: Int
            let restingTrusted: Bool
            let hrvTrusted: Bool

            init(_ comparison: PersonalBaseline.RecoveryComparison) {
                asOf = comparison.asOf
                comparisonHorizonDays = comparison.comparisonHorizonDays
                recentQualificationHorizonDays = comparison.recentQualificationHorizonDays
                statistic = comparison.statistic
                restingHeartRate = comparison.restingHeartRate.map {
                    Statistic(location: $0.location,
                              scale: $0.scale,
                              sampleCount: $0.sampleCount)
                }
                hrv = comparison.hrv.map {
                    Statistic(location: $0.location,
                              scale: $0.scale,
                              sampleCount: $0.sampleCount)
                }
                recentQualifiedRestingDays = comparison.recentQualifiedRestingDays
                recentQualifiedHRVNights = comparison.recentQualifiedHRVNights
                restingTrusted = comparison.restingTrusted
                hrvTrusted = comparison.hrvTrusted
            }
        }

        let hrvRMSSD: Double?
        let restingHeartRateBPM: Double?
        let sleepDurationSeconds: TimeInterval?
        let sleepEfficiency: Double?
        let respiratoryRate: Double?
        let hrvBaseline: Baseline?
        let restingHeartRateBaseline: Baseline?
        let respiratoryRateBaseline: Baseline?
        let baselineUpdatedAt: Date?
        let recoveryComparison: RecoveryComparison?

        init(hrvRMSSD: Double?,
             restingHeartRateBPM: Double?,
             sleepDurationSeconds: TimeInterval?,
             sleepEfficiency: Double?,
             respiratoryRate: Double?,
             baseline: PersonalBaseline,
             respiratoryBaseline: (mean: Double, sd: Double, count: Int)?,
             now: Date = Date(),
             calendar: Calendar = .current) {
            self.hrvRMSSD = hrvRMSSD.flatMap { $0 > 0 ? $0 : nil }
            self.restingHeartRateBPM = restingHeartRateBPM.flatMap { $0 > 0 ? $0 : nil }
            self.sleepDurationSeconds = sleepDurationSeconds.flatMap { $0 > 0 ? $0 : nil }
            self.sleepEfficiency = sleepEfficiency.flatMap { (0...1).contains($0) ? $0 : nil }
            self.respiratoryRate = respiratoryRate.flatMap { $0 > 0 ? $0 : nil }

            let hrvStats = baseline.lnRMSSDStats(now: now)
            let hrvMean = hrvStats?.mean ?? baseline.hrvEMA
            hrvBaseline = hrvMean.map {
                Baseline(mean: $0,
                         standardDeviation: hrvStats?.sd,
                         sampleCount: hrvStats?.count ?? baseline.freshHRVSampleCount(now: now),
                         trusted: baseline.hasTrustedHRVBaseline(now: now))
            }

            let restingStats = baseline.restingStats(now: now)
            let restingMean = restingStats?.mean ?? baseline.restingHR
            restingHeartRateBaseline = restingMean.map {
                Baseline(mean: $0,
                         standardDeviation: restingStats?.sd,
                         sampleCount: restingStats?.count ?? baseline.freshRestingSampleCount(now: now),
                         trusted: baseline.hasTrustedRestingBaseline(now: now))
            }

            respiratoryRateBaseline = respiratoryBaseline.map {
                Baseline(mean: $0.mean,
                         standardDeviation: $0.sd,
                         sampleCount: $0.count,
                         trusted: $0.count >= PersonalBaseline.trustedMinimumSamples && $0.sd > 0.1)
            }
            baselineUpdatedAt = baseline.updated
            recoveryComparison = RecoveryComparison(
                baseline.recoveryComparison(now: now, calendar: calendar)
            )
        }
    }

    struct Contributor: Codable, Equatable {
        let kind: String
        let value: Double?
        let unit: String?
        let zScore: Double?
        let weight: Double?
        let detail: String?
        let displayValue: String?
        let direction: Int?

        init(kind: String,
             value: Double? = nil,
             unit: String? = nil,
             zScore: Double? = nil,
             weight: Double? = nil,
             detail: String? = nil,
             displayValue: String? = nil,
             direction: Int? = nil) {
            self.kind = kind
            self.value = value
            self.unit = unit
            self.zScore = zScore
            self.weight = weight
            self.detail = detail
            self.displayValue = displayValue
            self.direction = direction
        }
    }

    static let recoveryV2Source = "recovery_v2"
    /// This is intentionally separate from the storage schema. Bump it only
    /// when Recovery v2's calculation semantics change, never for a UI-only
    /// presentation adjustment.
    // v3 makes the scoring input authority match the Sleep UI: HR-only
    // capture/span coverage can no longer masquerade as sleep efficiency.
    static let recoveryV2ModelVersion = 3
    static let savedDailyMetricSource = "saved_daily_metric"
    static let legacyRollupSource = "legacy_rollup"
    static let legacyWidgetSource = "legacy_widget_snapshot"

    let score: Int
    let confidence: String
    let source: String
    let model: String?
    /// Nil means the record predates versioned Recovery receipts. Legacy rows
    /// remain viewable, but they are never advertised as reproducible history.
    let modelVersion: Int?
    /// Civil day whose morning inputs produced this score. This prevents an old
    /// score from being silently treated as a fresh result from today's model.
    let scoredDay: Date?
    let usesHRV: Bool
    let detail: String
    let contributors: [Contributor]
    let inputSnapshot: InputSnapshot?

    init(score: Int,
         confidence: String,
         source: String,
         model: String? = nil,
         modelVersion: Int? = nil,
         scoredDay: Date? = nil,
         usesHRV: Bool,
         detail: String,
         contributors: [Contributor],
         inputSnapshot: InputSnapshot? = nil) {
        self.score = min(max(score, 0), 100)
        self.confidence = confidence
        self.source = source
        self.model = model
        // A model version without the matching frozen inputs creates a false
        // sense of replayability. Legacy/rebuilt summaries retain their score
        // and contributors but remain deliberately unversioned.
        self.modelVersion = inputSnapshot == nil ? nil : modelVersion
        self.scoredDay = scoredDay
        self.usesHRV = usesHRV
        self.detail = detail
        self.contributors = contributors
        self.inputSnapshot = inputSnapshot
    }

    init?(estimate: Metrics.RecoveryEstimate,
         scoredDay: Date,
         source: String = FrozenRecoverySummary.recoveryV2Source,
         model: String? = "recovery_v2",
         modelVersion: Int? = FrozenRecoverySummary.recoveryV2ModelVersion,
         inputSnapshot: InputSnapshot? = nil) {
        guard let score = estimate.percent else { return nil }
        self.init(score: score,
                  confidence: estimate.confidence.rawValue,
                  source: source,
                  model: model,
                  modelVersion: modelVersion,
                  scoredDay: scoredDay,
                  usesHRV: estimate.usesHRV,
                  detail: estimate.detail,
                  contributors: estimate.contributors.map {
                    Contributor(kind: $0.kind.rawValue,
                                zScore: $0.zScore,
                                weight: $0.weight,
                                detail: $0.detail,
                                displayValue: $0.displayValue,
                                direction: $0.direction)
                  },
                  inputSnapshot: inputSnapshot)
    }

    init?(metric: SavedDailyMetric) {
        guard let score = metric.recoveryPercent else { return nil }
        if let summary = metric.recoverySummary,
           summary.score == score {
            self = summary.replacingScoredDay(metric.day)
            return
        }
        var values: [Contributor] = []
        if let hrv = metric.hrv {
            values.append(Contributor(kind: "hrv", value: Double(hrv), unit: "ms"))
        }
        if let restingHR = metric.restingHR {
            values.append(Contributor(kind: "restingHeartRate", value: Double(restingHR), unit: "bpm"))
        }
        if let sleepDuration = metric.sleepDuration {
            values.append(Contributor(kind: "sleep", value: sleepDuration, unit: "seconds"))
        }
        if let respiratoryRate = metric.respiratoryRate {
            values.append(Contributor(kind: "respiration", value: respiratoryRate, unit: "breaths_per_minute"))
        }
        self.init(score: score,
                  confidence: metric.recoveryConfidence,
                  source: Self.savedDailyMetricSource,
                  model: "recovery_v2",
                  modelVersion: nil,
                  scoredDay: metric.day,
                  usesHRV: metric.hrv != nil,
                  detail: "frozen daily recovery",
                  contributors: values,
                  inputSnapshot: nil)
    }

    static func legacy(score: Int,
                       scoredDay: Date,
                       lnRMSSD: Double?,
                       restingHR: Int?,
                       sleepSeconds: TimeInterval?,
                       respiratoryRate: Double?) -> FrozenRecoverySummary {
        var values: [Contributor] = []
        if let lnRMSSD {
            values.append(Contributor(kind: "hrv", value: lnRMSSD, unit: "lnRMSSD"))
        }
        if let restingHR {
            values.append(Contributor(kind: "restingHeartRate", value: Double(restingHR), unit: "bpm"))
        }
        if let sleepSeconds {
            values.append(Contributor(kind: "sleep", value: sleepSeconds, unit: "seconds"))
        }
        if let respiratoryRate {
            values.append(Contributor(kind: "respiration", value: respiratoryRate, unit: "breaths_per_minute"))
        }
        return FrozenRecoverySummary(score: score,
                                     confidence: Metrics.RecoveryEstimate.Confidence.unverified.rawValue,
                                     source: legacyRollupSource,
                                     modelVersion: nil,
                                     scoredDay: scoredDay,
                                     usesHRV: lnRMSSD != nil,
                                     detail: "frozen daily recovery",
                                     contributors: values,
                                     inputSnapshot: nil)
    }

    var recoveryEstimate: Metrics.RecoveryEstimate {
        Metrics.RecoveryEstimate(percent: score,
                                 confidence: Self.recoveryConfidence(from: confidence),
                                 usesHRV: usesHRV,
                                 detail: detail,
                                 contributors: contributors.compactMap { contributor in
                                    guard let kind = Metrics.RecoveryEstimate.Contributor.Kind(rawValue: contributor.kind),
                                          let zScore = contributor.zScore,
                                          let weight = contributor.weight,
                                          let detail = contributor.detail else {
                                        return nil
                                    }
                                    return Metrics.RecoveryEstimate.Contributor(kind: kind,
                                                                                 zScore: zScore,
                                                                                 weight: weight,
                                                                                 detail: detail,
                                                                                 displayValue: contributor.displayValue,
                                                                                 direction: contributor.direction)
                                 })
    }

    func replacingScore(_ score: Int, detailSuffix: String? = nil) -> FrozenRecoverySummary {
        let nextDetail: String
        if let detailSuffix, !detail.contains(detailSuffix) {
            nextDetail = "\(detail) · \(detailSuffix)"
        } else {
            nextDetail = detail
        }
        return FrozenRecoverySummary(score: score,
                                     confidence: confidence,
                                     source: source,
                                     model: model,
                                     modelVersion: modelVersion,
                                     scoredDay: scoredDay,
                                     usesHRV: usesHRV,
                                     detail: nextDetail,
                                     contributors: contributors,
                                     inputSnapshot: inputSnapshot)
    }

    func replacingScoredDay(_ day: Date) -> FrozenRecoverySummary {
        FrozenRecoverySummary(score: score,
                              confidence: confidence,
                              source: source,
                              model: model,
                              modelVersion: modelVersion,
                              scoredDay: day,
                              usesHRV: usesHRV,
                              detail: detail,
                              contributors: contributors,
                              inputSnapshot: inputSnapshot)
    }

    static func preferred(score: Int,
                          candidates: [FrozenRecoverySummary?]) -> FrozenRecoverySummary? {
        var best: FrozenRecoverySummary?
        for candidate in candidates.compactMap({ $0 }) where candidate.score == score {
            guard let current = best else {
                best = candidate
                continue
            }
            if candidate.provenanceRank > current.provenanceRank {
                best = candidate
            }
        }
        return best
    }

    private var provenanceRank: Int {
        if contributors.contains(where: { $0.zScore != nil && $0.weight != nil }) { return 4 }
        if source == Self.recoveryV2Source { return 3 }
        if source == Self.savedDailyMetricSource { return 2 }
        return 1
    }

    private static func recoveryConfidence(from value: String) -> Metrics.RecoveryEstimate.Confidence {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: " ")
            .lowercased() {
        case Metrics.RecoveryEstimate.Confidence.learning.rawValue:
            return .learning
        case Metrics.RecoveryEstimate.Confidence.personalBaseline.rawValue:
            return .personalBaseline
        case Metrics.RecoveryEstimate.Confidence.validated.rawValue:
            // 2026-08-14 (assessment P0.3): historical receipts minted while
            // RR reference validation upgraded the tier said "validated", but
            // that only ever meant the HRV measurement was cross-checked and a
            // personal baseline existed — not that the score predicts
            // readiness. `.validated` is reserved for a held-out outcome
            // study; replay the strongest honest claim instead. The stored
            // string is untouched.
            return .personalBaseline
        default:
            // Unknown historical labels stay conservative. They must never be
            // upgraded using whatever baseline happens to be current today.
            return .unverified
        }
    }
}

enum DailyRecoveryResolver {
    static func summary(rollups: [DailyRollupStoreEntry],
                        metrics: [SavedDailyMetric],
                        calendar: Calendar = .current,
                        now: Date = Date(),
                        carryLatest: Bool) -> FrozenRecoverySummary? {
        let today = rollups.first {
            calendar.isDate($0.day, inSameDayAs: now) && $0.recovery != nil
        }
        guard let rollup = today ?? (carryLatest ? rollups.first(where: { $0.recovery != nil }) : nil) else {
            return nil
        }
        let metric = metrics.first {
            calendar.isDate($0.day, inSameDayAs: rollup.day)
                && $0.recoveryPercent == rollup.recovery
        }
        return rollup.resolvedRecoverySummary(matching: metric, calendar: calendar)
    }

    /// Resolves the immutable recovery minted at the wake boundary that owns
    /// the active physiological cycle. Civil midnight must not move recovery
    /// to a different rollup while that wake-to-wake cycle is still active.
    static func summary(rollups: [DailyRollupStoreEntry],
                        metrics: [SavedDailyMetric],
                        physiologicalCycle: AtriaPhysiologicalCycle,
                        anchorSleep: SleepHistorySnapshot.Night? = nil,
                        calendar: Calendar = .current) -> FrozenRecoverySummary? {
        if physiologicalCycle.boundaryKind == .initialFallback
            || physiologicalCycle.boundaryKind == .noSleepFallback {
            guard anchorSleep == nil,
                  let rollup = rollups.first(where: {
                      limitedFallbackCivilDayBelongsToCycle(
                          $0.day,
                          physiologicalCycle: physiologicalCycle,
                          calendar: calendar
                      )
                          && $0.recovery != nil
                  }),
                  let metric = metrics.first(where: {
                      calendar.isDate($0.day, inSameDayAs: rollup.day)
                          && $0.recoveryPercent == rollup.recovery
                  }),
                  let summary = rollup.resolvedRecoverySummary(matching: metric,
                                                               calendar: calendar),
                  limitedFallbackSummaryIsAuthoritative(
                      summary,
                      metric: metric,
                      physiologicalCycle: physiologicalCycle,
                      calendar: calendar
                  ) else {
                return nil
            }
            return summary
        }
        guard physiologicalCycle.boundaryKind == .mainSleep else { return nil }
        guard let rollup = rollups.first(where: {
            calendar.isDate($0.day, inSameDayAs: physiologicalCycle.start)
                && $0.recovery != nil
        }) else { return nil }
        let metric = metrics.first {
            calendar.isDate($0.day, inSameDayAs: rollup.day)
                && $0.recoveryPercent == rollup.recovery
        }
        // Confirming or adjusting sleep moves the physiological-day anchor
        // immediately, while the durable daily metric is refreshed on a utility
        // task. During that short handoff an older recovery from the same civil
        // day must not masquerade as the newly confirmed sleep's frozen result.
        // Requiring the persisted overnight inputs to match lets consumers show
        // a freshly evaluated provisional result until the new freeze lands.
        if let anchorSleep {
            guard anchorSleep.confirmed,
                  !anchorSleep.isNapEvidence,
                  let metric,
                  metricMatchesCurrentPhysiologicalNight(
                    metric,
                    night: anchorSleep,
                    physiologicalCycle: physiologicalCycle
                  ) else {
                return nil
            }
        }
        return rollup.resolvedRecoverySummary(matching: metric, calendar: calendar)
    }

    /// Durable metric history is civil-day keyed even when a no-sleep
    /// physiological cycle begins in the afternoon. The midnight row inside
    /// that still-active wake-to-wake interval belongs to the same cycle; if it
    /// is rejected, Home recomputes from a later live RHR while detail/history
    /// keep the persisted score. Never admit the following midnight or broaden
    /// initial-wear authority beyond its own civil day.
    private static func limitedFallbackCivilDayBelongsToCycle(
        _ day: Date,
        physiologicalCycle: AtriaPhysiologicalCycle,
        calendar: Calendar
    ) -> Bool {
        if calendar.isDate(day, inSameDayAs: physiologicalCycle.start) {
            return true
        }
        guard physiologicalCycle.boundaryKind == .noSleepFallback,
              day > physiologicalCycle.start,
              let nextBoundary = calendar.date(
                  byAdding: .day,
                  value: 1,
                  to: physiologicalCycle.start
              ) else {
            return false
        }
        return day < nextBoundary
    }

    /// Initial wear and a later no-sleep rollover have no current confirmed wake
    /// boundary, but production still mints one explicitly limited RHR-only
    /// score for the fallback day. Once persisted, that score must be the
    /// authority everywhere; recomputing from a later live RHR otherwise lets
    /// Home/widget disagree with history.
    ///
    /// This deliberately admits only the exact recovery-v2 no-sleep/no-HRV
    /// structure. Historical scores, sleep-bearing rows, HRV-bearing rows,
    /// stronger confidence tiers, and a different fallback day all fail closed.
    private static func limitedFallbackSummaryIsAuthoritative(
        _ summary: FrozenRecoverySummary,
        metric: SavedDailyMetric,
        physiologicalCycle: AtriaPhysiologicalCycle,
        calendar: Calendar
    ) -> Bool {
        guard physiologicalCycle.boundaryKind == .initialFallback
                || physiologicalCycle.boundaryKind == .noSleepFallback,
              limitedFallbackCivilDayBelongsToCycle(
                  metric.day,
                  physiologicalCycle: physiologicalCycle,
                  calendar: calendar
              ),
              summary.scoredDay.map({
                  calendar.isDate($0, inSameDayAs: metric.day)
              }) == true else {
            return false
        }
        return limitedFallbackMetricIsStructurallyAuthoritative(
            metric,
            summary: summary,
            day: metric.day,
            calendar: calendar
        )
    }

    /// A persisted day-one/no-sleep score must not be reminted from a later
    /// live RHR during an ordinary history refresh. This structural check is
    /// shared with the merge path so the durable authority cannot briefly win
    /// at launch and then drift after the next asynchronous rollup rebuild.
    static func limitedFallbackMetricIsStructurallyAuthoritative(
        _ metric: SavedDailyMetric,
        summary: FrozenRecoverySummary? = nil,
        day: Date,
        calendar: Calendar = .current
    ) -> Bool {
        guard calendar.isDate(metric.day, inSameDayAs: day),
              let summary = summary ?? metric.recoverySummary,
              summary.scoredDay.map({
                  calendar.isDate($0, inSameDayAs: day)
              }) == true,
              summary.source == FrozenRecoverySummary.recoveryV2Source,
              summary.model == "recovery_v2",
              summary.confidence == Metrics.RecoveryEstimate.Confidence.unverified.rawValue,
              !summary.usesHRV,
              metric.recoveryPercent == summary.score,
              metric.recoveryConfidence == Metrics.RecoveryEstimate.Confidence.unverified.rawValue,
              metric.hrv == nil,
              metric.sleepDuration == nil,
              metric.sleepSpan == nil,
              metric.sleepStart == nil,
              metric.sleepEnd == nil,
              metric.sleepSource == nil,
              metric.restingHR.map({ $0 > 0 }) == true else {
            return false
        }

        let sleep = summary.contributors.first { $0.kind == "sleep" }
        let hrv = summary.contributors.first { $0.kind == "hrv" }
        let resting = summary.contributors.first { $0.kind == "restingHeartRate" }
        return sleep?.weight == 0
            && hrv?.weight == 0
            && resting.map { ($0.weight ?? 0) > 0 } == true
    }

    /// One source of truth for non-interactive consumers such as widgets and
    /// notifications. Main-sleep cycles prefer the frozen morning result.
    /// Without a confirmed sleep, keep the current limited-evidence estimate
    /// rather than blanking the product; its confidence/detail must disclose
    /// that sleep is unavailable and it is never frozen as a morning score.
    static func currentEstimate(liveEstimate: Metrics.RecoveryEstimate,
                                rollups: [DailyRollupStoreEntry],
                                metrics: [SavedDailyMetric],
                                physiologicalCycle: AtriaPhysiologicalCycle,
                                anchorSleep: SleepHistorySnapshot.Night? = nil,
                                calendar: Calendar = .current) -> Metrics.RecoveryEstimate {
        return summary(rollups: rollups,
                       metrics: metrics,
                       physiologicalCycle: physiologicalCycle,
                       anchorSleep: anchorSleep,
                       calendar: calendar)?.recoveryEstimate
            ?? liveEstimate
    }

    /// Exact overnight-input identity used both while preserving a morning
    /// freeze and while resolving it. A tolerance would hide a genuinely edited
    /// sleep window or a newly decoded vital, so persisted values intentionally
    /// compare exactly to the confirmed snapshot that minted them.
    static func metricMatchesConfirmedNight(_ metric: SavedDailyMetric,
                                            night: SleepHistorySnapshot.Night) -> Bool {
        guard night.confirmed, !night.isNapEvidence else { return false }
        let span = night.start.flatMap { start in
            night.end.flatMap { end in end > start ? end.timeIntervalSince(start) : nil }
        }
        return metric.sleepEnd == night.end
            && metric.sleepDuration == night.duration
            && metric.sleepSpan == span
            && metric.hrv == night.hrv
            && metric.restingHR == night.restingHR
            && metric.respiratoryRate == night.respiratoryRate
    }

    /// A resumed-sleep segment extends the physiological wake boundary while
    /// the durable main-sleep card can still temporarily expose only the
    /// original fragment. Accept that one precise shape without weakening the
    /// ordinary exact-input gate. An edited same-boundary night still fails:
    /// the exception requires the snapshot's old end to precede the cycle's
    /// final linked wake and the persisted span to end exactly at that wake.
    static func metricMatchesCurrentPhysiologicalNight(
        _ metric: SavedDailyMetric,
        night: SleepHistorySnapshot.Night,
        physiologicalCycle: AtriaPhysiologicalCycle
    ) -> Bool {
        guard physiologicalCycle.boundaryKind == .mainSleep,
              night.confirmed,
              !night.isNapEvidence else { return false }
        if metricMatchesConfirmedNight(metric, night: night) {
            return metric.sleepEnd == physiologicalCycle.start
        }
        guard let nightStart = night.start,
              let nightEnd = night.end,
              nightEnd < physiologicalCycle.start,
              metric.sleepStart == nightStart,
              metric.sleepEnd == physiologicalCycle.start,
              metric.sleepSpan == physiologicalCycle.start.timeIntervalSince(nightStart),
              let metricDuration = metric.sleepDuration,
              metricDuration >= night.duration,
              metricDuration <= physiologicalCycle.start.timeIntervalSince(nightStart),
              metric.hrv == night.hrv,
              metric.restingHR == night.restingHR,
              metric.respiratoryRate == night.respiratoryRate else {
            return false
        }
        return true
    }

    static var noSleepEstimate: Metrics.RecoveryEstimate {
        Metrics.RecoveryEstimate(
            percent: nil,
            confidence: .unverified,
            usesHRV: false,
            detail: "No confirmed main sleep was recorded for this physiological cycle, so recovery is unavailable.",
            contributors: []
        )
    }

}

struct DailyRollupStoreEntry: Codable, Equatable, Identifiable {
    let day: Date
    let tzOffsetMinutes: Int
    var recovery: Int? {
        didSet {
            if recoverySummary?.score != recovery {
                recoverySummary = nil
            }
        }
    }
    var recoverySummary: FrozenRecoverySummary? {
        didSet {
            if let recoverySummary, recovery != recoverySummary.score {
                recovery = recoverySummary.score
            }
        }
    }
    var lnRMSSD: Double?
    var rhr: Int?
    var sleepSeconds: TimeInterval?
    /// The frozen adaptive Sleep Need for this exact night. A missing value is
    /// historical unknown, never an invitation to rebuild it from current data.
    var sleepNeedSeconds: TimeInterval?
    var sleepPerformance: Int?
    var bedtimeMinutes: Int?
    var strain: Double?
    var strainCoverageFraction: Double?
    var strainEvidenceQuality: Metrics.StrainEvidenceQuality?
    var respiratoryRate: Double?
    /// Relative sleep skin-temperature deviation in Celsius, finalized into the
    /// morning/day rollup so product surfaces do not drift with live sessions.
    var skinTemperatureDeviationCelsius: Double?
    var vitals: DailyRollupVitals?
    var nutrition: AtriaNutritionSummary?
    /// Fitness-age delta (biological minus chronological years) for this day,
    /// captured only once `BiologicalAgeSummary.isReady` — persisted so the
    /// pace-of-aging trend can be computed from the slope of this value over
    /// time. Additive/optional so legacy rollup rows without this field keep
    /// decoding via `decodeIfPresent` (nil).
    var fitnessAgeDelta: Int?
    /// GAP-06: the night's provisional composite Sleep Score receipt, derived
    /// exclusively from that morning's frozen inputs (Sufficiency from the
    /// frozen need receipt, Consistency as persisted on the day's metric, and
    /// motion-qualified efficiency) — never from today's rolling windows, so a
    /// settled night's score cannot drift as later nights land. Additive /
    /// optional per the docs/16 migration policy: legacy rows decode nil and
    /// cold-session imports simply omit it (a re-mint from the same frozen
    /// inputs reproduces it byte-identically).
    var sleepScore: AtriaSleepScore?

    var id: Date { day }

    private enum CodingKeys: String, CodingKey {
        case day
        case tzOffsetMinutes
        case recovery
        case recoverySummary
        case lnRMSSD
        case rhr
        case sleepSeconds
        case sleepNeedSeconds
        case sleepPerformance
        case bedtimeMinutes
        case strain
        case strainCoverageFraction
        case strainEvidenceQuality
        case respiratoryRate
        case skinTemperatureDeviationCelsius
        case vitals
        case nutrition
        case fitnessAgeDelta
        case sleepScore
    }

    init(day: Date,
         tzOffsetMinutes: Int? = nil,
         recovery: Int? = nil,
         recoverySummary: FrozenRecoverySummary? = nil,
         lnRMSSD: Double? = nil,
         rhr: Int? = nil,
         sleepSeconds: TimeInterval? = nil,
         sleepNeedSeconds: TimeInterval? = nil,
         sleepPerformance: Int? = nil,
         bedtimeMinutes: Int? = nil,
         strain: Double? = nil,
         strainCoverageFraction: Double? = nil,
         strainEvidenceQuality: Metrics.StrainEvidenceQuality? = nil,
         respiratoryRate: Double? = nil,
         skinTemperatureDeviationCelsius: Double? = nil,
         vitals: DailyRollupVitals? = nil,
         nutrition: AtriaNutritionSummary? = nil,
         fitnessAgeDelta: Int? = nil,
         sleepScore: AtriaSleepScore? = nil,
         calendar: Calendar = .current) {
        let normalizedDay = calendar.startOfDay(for: day)
        self.day = normalizedDay
        self.tzOffsetMinutes = tzOffsetMinutes
            ?? calendar.timeZone.secondsFromGMT(for: normalizedDay) / 60
        self.recovery = recoverySummary?.score ?? recovery
        self.recoverySummary = recoverySummary
        self.lnRMSSD = lnRMSSD
        self.rhr = rhr
        self.sleepSeconds = sleepSeconds
        self.sleepNeedSeconds = sleepNeedSeconds.flatMap { $0 > 0 ? $0 : nil }
        self.sleepPerformance = sleepPerformance
        self.bedtimeMinutes = bedtimeMinutes
        self.strain = strain
        self.strainCoverageFraction = strainCoverageFraction.map { min(1, max(0, $0)) }
        self.strainEvidenceQuality = strainEvidenceQuality
        self.respiratoryRate = respiratoryRate
        self.skinTemperatureDeviationCelsius = skinTemperatureDeviationCelsius
        self.vitals = vitals
        self.nutrition = nutrition
        self.fitnessAgeDelta = fitnessAgeDelta
        // A composite with no score is Sufficiency-on-its-own; never store it
        // as a receipt.
        self.sleepScore = sleepScore.flatMap { $0.score == nil ? nil : $0 }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tzOffsetMinutes = try container.decode(Int.self, forKey: .tzOffsetMinutes)
        let dayText = try container.decode(String.self, forKey: .day)
        guard let formatter = Self.dayFormatter(tzOffsetMinutes: tzOffsetMinutes),
              let day = formatter.date(from: dayText) else {
            throw DecodingError.dataCorruptedError(forKey: .day,
                                                   in: container,
                                                   debugDescription: "Expected yyyy-MM-dd date with a valid persisted offset.")
        }
        self.day = day
        let decodedRecovery = try container.decodeIfPresent(Int.self, forKey: .recovery)
        let decodedRecoverySummary = try container.decodeIfPresent(FrozenRecoverySummary.self,
                                                                    forKey: .recoverySummary)
        recovery = decodedRecoverySummary?.score ?? decodedRecovery
        recoverySummary = decodedRecoverySummary
        lnRMSSD = try container.decodeIfPresent(Double.self, forKey: .lnRMSSD)
        rhr = try container.decodeIfPresent(Int.self, forKey: .rhr)
        sleepSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .sleepSeconds)
        sleepNeedSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .sleepNeedSeconds)
        sleepPerformance = try container.decodeIfPresent(Int.self, forKey: .sleepPerformance)
        bedtimeMinutes = try container.decodeIfPresent(Int.self, forKey: .bedtimeMinutes)
        strain = try container.decodeIfPresent(Double.self, forKey: .strain)
        strainCoverageFraction = try container.decodeIfPresent(
            Double.self,
            forKey: .strainCoverageFraction
        ).map { min(1, max(0, $0)) }
        strainEvidenceQuality = try container.decodeIfPresent(
            Metrics.StrainEvidenceQuality.self,
            forKey: .strainEvidenceQuality
        )
        respiratoryRate = try container.decodeIfPresent(Double.self, forKey: .respiratoryRate)
        skinTemperatureDeviationCelsius = try container.decodeIfPresent(Double.self, forKey: .skinTemperatureDeviationCelsius)
        vitals = try container.decodeIfPresent(DailyRollupVitals.self, forKey: .vitals)
        nutrition = try container.decodeIfPresent(AtriaNutritionSummary.self, forKey: .nutrition)
        fitnessAgeDelta = try container.decodeIfPresent(Int.self, forKey: .fitnessAgeDelta)
        sleepScore = try container.decodeIfPresent(AtriaSleepScore.self, forKey: .sleepScore)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        guard let formatter = Self.dayFormatter(tzOffsetMinutes: tzOffsetMinutes) else {
            throw EncodingError.invalidValue(tzOffsetMinutes,
                                             EncodingError.Context(codingPath: encoder.codingPath,
                                                                   debugDescription: "Invalid persisted timezone offset."))
        }
        try container.encode(formatter.string(from: day), forKey: .day)
        try container.encode(tzOffsetMinutes, forKey: .tzOffsetMinutes)
        let coherentSummary = recoverySummary.flatMap { $0.score == recovery ? $0 : nil }
        try container.encodeIfPresent(coherentSummary?.score ?? recovery, forKey: .recovery)
        try container.encodeIfPresent(coherentSummary, forKey: .recoverySummary)
        try container.encodeIfPresent(lnRMSSD, forKey: .lnRMSSD)
        try container.encodeIfPresent(rhr, forKey: .rhr)
        try container.encodeIfPresent(sleepSeconds, forKey: .sleepSeconds)
        try container.encodeIfPresent(sleepNeedSeconds, forKey: .sleepNeedSeconds)
        try container.encodeIfPresent(sleepPerformance, forKey: .sleepPerformance)
        try container.encodeIfPresent(bedtimeMinutes, forKey: .bedtimeMinutes)
        try container.encodeIfPresent(strain, forKey: .strain)
        try container.encodeIfPresent(strainCoverageFraction, forKey: .strainCoverageFraction)
        try container.encodeIfPresent(strainEvidenceQuality, forKey: .strainEvidenceQuality)
        try container.encodeIfPresent(respiratoryRate, forKey: .respiratoryRate)
        try container.encodeIfPresent(skinTemperatureDeviationCelsius, forKey: .skinTemperatureDeviationCelsius)
        try container.encodeIfPresent(vitals, forKey: .vitals)
        try container.encodeIfPresent(nutrition, forKey: .nutrition)
        try container.encodeIfPresent(fitnessAgeDelta, forKey: .fitnessAgeDelta)
        try container.encodeIfPresent(sleepScore, forKey: .sleepScore)
    }

    private static func dayFormatter(tzOffsetMinutes: Int) -> DateFormatter? {
        guard let timeZone = TimeZone(secondsFromGMT: tzOffsetMinutes * 60) else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }

    func resolvedRecoverySummary(matching metric: SavedDailyMetric? = nil,
                                 calendar: Calendar = .current) -> FrozenRecoverySummary? {
        guard let recovery else { return nil }
        let metricSummary: FrozenRecoverySummary?
        if let metric,
           calendar.isDate(metric.day, inSameDayAs: day),
           metric.recoveryPercent == recovery {
            metricSummary = FrozenRecoverySummary(metric: metric)
        } else {
            metricSummary = nil
        }
        let summary = FrozenRecoverySummary.preferred(score: recovery,
                                                      candidates: [recoverySummary, metricSummary])
            ?? FrozenRecoverySummary.legacy(score: recovery,
                                            scoredDay: day,
                                            lnRMSSD: lnRMSSD,
                                            restingHR: rhr,
                                            sleepSeconds: sleepSeconds,
                                            respiratoryRate: respiratoryRate)
        return summary.replacingScoredDay(day)
    }
}

final class DailyRollupStore {
    private let url: URL
    private let recoveryMetricsURL: URL?
    private var calendar: Calendar
    private let queue = DispatchQueue(label: "com.adidshaft.atria.daily-rollups", qos: .utility)
    private var cache: [DailyRollupStoreEntry]
    private var cacheIndexByDay: [Date: Int] = [:]
    private var recoverySummariesByDay: [Date: FrozenRecoverySummary]
    /// Restore spans this file and several other canonical destinations. While
    /// that transaction owns persistence, mutations may update the in-memory
    /// cache but cannot enqueue a stale file image behind the transaction.
    /// Restore and recovered-data publication may overlap briefly while their
    /// main-actor coordinators supersede work. A depth counter prevents either
    /// fence from resuming disk writes while the other still owns the file.
    private var persistencePauseDepth = 0

    init(url: URL? = nil,
         recoveryMetricsURL: URL? = nil,
         calendar: Calendar = .current,
         loadPersisted: Bool = true,
         fileManager: FileManager = .default) {
        self.calendar = calendar
        let defaultDocuments = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        if let url {
            self.url = url
            self.recoveryMetricsURL = recoveryMetricsURL
        } else {
            self.url = defaultDocuments.appendingPathComponent("daily-rollups.json")
            self.recoveryMetricsURL = recoveryMetricsURL
                ?? defaultDocuments.appendingPathComponent("daily-metrics.json")
        }
        recoverySummariesByDay = loadPersisted
            ? Self.loadRecoverySummaries(from: self.recoveryMetricsURL, calendar: calendar)
            : [:]
        let loaded = loadPersisted ? Self.load(from: self.url) : []
        cache = []
        cache.reserveCapacity(loaded.count)
        var normalizedByDay: [Date: DailyRollupStoreEntry] = [:]
        for entry in loaded {
            guard let components = Self.persistedCivilComponents(for: entry),
                  let rematerializedDay = calendar.date(from: components) else { continue }
            var normalized = DailyRollupStoreEntry(day: rematerializedDay,
                                                   recovery: entry.recovery,
                                                   recoverySummary: entry.recoverySummary,
                                                   lnRMSSD: entry.lnRMSSD,
                                                   rhr: entry.rhr,
                                                   sleepSeconds: entry.sleepSeconds,
                                                   sleepNeedSeconds: entry.sleepNeedSeconds,
                                                   sleepPerformance: entry.sleepPerformance,
                                                   bedtimeMinutes: entry.bedtimeMinutes,
                                                   strain: entry.strain,
                                                   strainCoverageFraction: entry.strainCoverageFraction,
                                                   strainEvidenceQuality: entry.strainEvidenceQuality,
                                                   respiratoryRate: entry.respiratoryRate,
                                                   skinTemperatureDeviationCelsius: entry.skinTemperatureDeviationCelsius,
                                                   vitals: entry.vitals,
                                                   nutrition: entry.nutrition,
                                                   fitnessAgeDelta: entry.fitnessAgeDelta,
                                                   calendar: calendar)
            if let recovery = normalized.recovery {
                let metricSummary = recoverySummariesByDay[normalized.day]
                let preferred = FrozenRecoverySummary.preferred(score: recovery,
                                                                candidates: [normalized.recoverySummary,
                                                                             metricSummary])
                normalized.recoverySummary = preferred?.replacingScoredDay(normalized.day)
                    ?? normalized.resolvedRecoverySummary(calendar: calendar)
            }
            normalizedByDay[normalized.day] = normalized
        }
        cache = normalizedByDay.values.sorted { $0.day > $1.day }
        rebuildCacheIndex()
        if loadPersisted, cache != loaded {
            schedulePersistence(of: cache)
        }
    }

    func rollup(for day: Date) -> DailyRollupStoreEntry? {
        let normalized = calendar.startOfDay(for: day)
        guard let index = cacheIndexByDay[normalized] else { return nil }
        return cache[index]
    }

    func rollups(last count: Int) -> [DailyRollupStoreEntry] {
        Array(cache.prefix(max(0, count)))
    }

    @discardableResult
    func updateCalendar(_ newCalendar: Calendar) -> Bool {
        let previousCalendar = calendar
        let civilEntries = cache.map { entry in
            (entry, previousCalendar.dateComponents([.year, .month, .day], from: entry.day))
        }

        calendar = newCalendar
        var normalizedByDay: [Date: DailyRollupStoreEntry] = [:]
        normalizedByDay.reserveCapacity(civilEntries.count)
        for (entry, components) in civilEntries {
            guard let rematerializedDay = newCalendar.date(from: components) else { continue }
            let normalized = normalizedEntry(from: entry, day: rematerializedDay)
            if normalizedByDay[normalized.day] == nil {
                normalizedByDay[normalized.day] = normalized
            }
        }

        let updatedCache = normalizedByDay.values.sorted { $0.day > $1.day }
        let changed = updatedCache != cache
        cache = updatedCache
        rebuildCacheIndex()

        schedulePersistence(of: cache)
        return changed
    }

    func upsert(_ rollup: DailyRollupStoreEntry) {
        upsertMany([rollup])
    }

    func upsertMany(_ rollups: [DailyRollupStoreEntry]) {
        guard !rollups.isEmpty else { return }

        var normalizedByDay: [Date: DailyRollupStoreEntry] = [:]
        normalizedByDay.reserveCapacity(rollups.count)
        for rollup in rollups {
            let day = calendar.startOfDay(for: rollup.day)
            let existingSummary = cacheIndexByDay[day].flatMap { cache[$0].recoverySummary }
            let normalized = normalizedEntry(from: rollup,
                                             day: day,
                                             preserving: existingSummary)
            normalizedByDay[normalized.day] = normalized
        }

        var insertedNewDay = false
        for normalized in normalizedByDay.values {
            if let index = cacheIndexByDay[normalized.day] {
                cache[index] = normalized
            } else {
                cache.append(normalized)
                insertedNewDay = true
            }
        }
        if insertedNewDay {
            cache.sort { $0.day > $1.day }
            rebuildCacheIndex()
        }

        schedulePersistence(of: cache)
    }

    func reconcile(_ rollups: [DailyRollupStoreEntry], replacingDays: Set<Date>) {
        guard !rollups.isEmpty || !replacingDays.isEmpty else { return }

        var normalizedByDay: [Date: DailyRollupStoreEntry] = [:]
        normalizedByDay.reserveCapacity(rollups.count)
        for rollup in rollups {
            let day = calendar.startOfDay(for: rollup.day)
            let existingSummary = cacheIndexByDay[day].flatMap { cache[$0].recoverySummary }
            let normalized = normalizedEntry(from: rollup,
                                             day: day,
                                             preserving: existingSummary)
            normalizedByDay[normalized.day] = normalized
        }

        for normalized in normalizedByDay.values {
            if let index = cacheIndexByDay[normalized.day] {
                cache[index] = normalized
            } else {
                cache.append(normalized)
            }
        }

        let normalizedReplacingDays = Set(replacingDays.map { calendar.startOfDay(for: $0) })
        for day in normalizedReplacingDays where normalizedByDay[day] == nil {
            guard let index = cache.firstIndex(where: {
                calendar.startOfDay(for: $0.day) == day
            }) else { continue }

            if cache[index].nutrition != nil || cache[index].fitnessAgeDelta != nil {
                cache[index].recovery = nil
                cache[index].lnRMSSD = nil
                cache[index].rhr = nil
                cache[index].sleepSeconds = nil
                cache[index].sleepPerformance = nil
                cache[index].bedtimeMinutes = nil
                cache[index].strain = nil
                cache[index].respiratoryRate = nil
                cache[index].skinTemperatureDeviationCelsius = nil
                cache[index].vitals = nil
                recoverySummariesByDay.removeValue(forKey: day)
            } else {
                cache.remove(at: index)
                recoverySummariesByDay.removeValue(forKey: day)
            }
        }

        cache.sort { $0.day > $1.day }
        rebuildCacheIndex()

        schedulePersistence(of: cache)
    }

    private func normalizedEntry(from rollup: DailyRollupStoreEntry,
                                 day: Date? = nil,
                                 preserving existingSummary: FrozenRecoverySummary? = nil) -> DailyRollupStoreEntry {
        let normalizedDay = calendar.startOfDay(for: day ?? rollup.day)
        let summary: FrozenRecoverySummary?
        if let recovery = rollup.recovery {
            let preferredSummary = FrozenRecoverySummary.preferred(
                score: recovery,
                candidates: [rollup.recoverySummary,
                             existingSummary,
                             recoverySummariesByDay[normalizedDay]]
            )
            summary = preferredSummary?.replacingScoredDay(normalizedDay)
                ?? FrozenRecoverySummary.legacy(score: recovery,
                                                scoredDay: normalizedDay,
                                                lnRMSSD: rollup.lnRMSSD,
                                                restingHR: rollup.rhr,
                                                sleepSeconds: rollup.sleepSeconds,
                                                respiratoryRate: rollup.respiratoryRate)
        } else {
            summary = nil
        }
        if let summary {
            recoverySummariesByDay[normalizedDay] = summary
        }
        return DailyRollupStoreEntry(day: normalizedDay,
                              recovery: rollup.recovery,
                              recoverySummary: summary,
                              lnRMSSD: rollup.lnRMSSD,
                              rhr: rollup.rhr,
                              sleepSeconds: rollup.sleepSeconds,
                              sleepNeedSeconds: rollup.sleepNeedSeconds,
                              sleepPerformance: rollup.sleepPerformance,
                              bedtimeMinutes: rollup.bedtimeMinutes,
                              strain: rollup.strain,
                              strainCoverageFraction: rollup.strainCoverageFraction,
                              strainEvidenceQuality: rollup.strainEvidenceQuality,
                              respiratoryRate: rollup.respiratoryRate,
                              skinTemperatureDeviationCelsius: rollup.skinTemperatureDeviationCelsius,
                              vitals: rollup.vitals,
                              nutrition: rollup.nutrition,
                              fitnessAgeDelta: rollup.fitnessAgeDelta,
                              calendar: calendar)
    }

    private static func load(from url: URL) -> [DailyRollupStoreEntry] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([DailyRollupStoreEntry].self, from: data) else {
            return []
        }
        return decoded.sorted { $0.day > $1.day }
    }

    private static func loadRecoverySummaries(from url: URL?,
                                              calendar: Calendar) -> [Date: FrozenRecoverySummary] {
        guard let url,
              let data = try? Data(contentsOf: url) else { return [:] }
        let decoder = JSONDecoder()
        decoder.userInfo[SavedDailyMetric.codingCalendarUserInfoKey] = calendar
        guard let metrics = try? decoder.decode([SavedDailyMetric].self, from: data) else { return [:] }
        var summaries: [Date: FrozenRecoverySummary] = [:]
        for metric in metrics {
            guard let summary = FrozenRecoverySummary(metric: metric) else { continue }
            let day = calendar.startOfDay(for: metric.day)
            if summaries[day] == nil {
                summaries[day] = summary.replacingScoredDay(day)
            }
        }
        return summaries
    }

    private static func persistedCivilComponents(for entry: DailyRollupStoreEntry) -> DateComponents? {
        guard let timeZone = TimeZone(secondsFromGMT: entry.tzOffsetMinutes * 60) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.dateComponents([.year, .month, .day], from: entry.day)
    }

    @discardableResult
    private static func persist(_ rollups: [DailyRollupStoreEntry], to url: URL) -> Bool {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(rollups)
            try data.write(to: url, options: .atomic)
            AtriaDebugLog("ATRIADBG daily_rollup_store_save status=ok rows=%d bytes=%d path=%@",
                          rollups.count,
                          data.count,
                          url.lastPathComponent)
            return true
        } catch {
            AtriaDebugLog("ATRIADBG daily_rollup_store_save status=failed error=%@",
                          error.localizedDescription)
            return false
        }
    }

    /// Flushes the newest in-memory authority after every previously queued
    /// rollup image. Morning settlement uses this completion as its durability
    /// fence before releasing Home/widget publication.
    func persistCurrentSnapshot(completion: @escaping (Bool) -> Void) {
        guard persistencePauseDepth == 0 else {
            completion(false)
            return
        }
        let snapshot = cache
        let targetURL = url
        queue.async {
            let succeeded = Self.persist(snapshot, to: targetURL)
            DispatchQueue.main.async {
                completion(succeeded)
            }
        }
    }

    func replaceAll(_ rollups: [DailyRollupStoreEntry]) {
        // `replaceAll` is also a transaction rollback primitive. Rebuild the
        // side provenance index from the replacement image instead of retaining
        // recovery summaries introduced by the discarded image.
        recoverySummariesByDay.removeAll(keepingCapacity: true)
        cache = rollups.map { normalizedEntry(from: $0) }.sorted { $0.day > $1.day }
        rebuildCacheIndex()
        schedulePersistence(of: cache)
    }

    /// Recovered analytics prepare several dependent projections before one
    /// publication fence. Keep rollup writes in memory until that fence commits
    /// so a later component failure cannot leave a partially advanced file.
    func beginRecoveredDataPublicationFence() {
        persistencePauseDepth &+= 1
    }

    /// Ends the recovered-data fence and persists exactly the selected final
    /// image (the prepared image on commit, or the restored image on rollback).
    func endRecoveredDataPublicationFence(persistCurrentSnapshot: Bool = true) {
        let snapshot = persistCurrentSnapshot ? cache : nil
        persistencePauseDepth = max(0, persistencePauseDepth - 1)
        if let snapshot, persistencePauseDepth == 0 {
            schedulePersistence(of: snapshot)
        }
    }

    /// MainActor-owned transaction fence. Draining after pausing ensures every
    /// previously queued image is durable before restore captures its rollback
    /// image. Subsequent mutations remain in memory until the fence ends.
    func beginPersistenceFence() async {
        persistencePauseDepth &+= 1
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }

    /// Resume normal writes and publish the newest cache image, never an image
    /// captured before or midway through restore.
    func endPersistenceFence(persistCurrentSnapshot: Bool = true) {
        let snapshot = persistCurrentSnapshot ? cache : nil
        persistencePauseDepth = max(0, persistencePauseDepth - 1)
        if let snapshot, persistencePauseDepth == 0 {
            schedulePersistence(of: snapshot)
        }
    }

    private func schedulePersistence(of snapshot: [DailyRollupStoreEntry]) {
        if persistencePauseDepth > 0 {
            return
        }
        let targetURL = url
        queue.async {
            Self.persist(snapshot, to: targetURL)
        }
    }

    private func rebuildCacheIndex() {
        cacheIndexByDay.removeAll(keepingCapacity: true)
        cacheIndexByDay.reserveCapacity(cache.count)
        for (index, entry) in cache.enumerated() {
            let normalized = calendar.startOfDay(for: entry.day)
            if cacheIndexByDay[normalized] == nil {
                cacheIndexByDay[normalized] = index
            }
        }
    }
}
