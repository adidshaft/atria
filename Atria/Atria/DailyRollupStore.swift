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
    static let savedDailyMetricSource = "saved_daily_metric"
    static let legacyRollupSource = "legacy_rollup"
    static let legacyWidgetSource = "legacy_widget_snapshot"

    let score: Int
    let confidence: String
    let source: String
    let model: String?
    /// Civil day whose morning inputs produced this score. This prevents an old
    /// score from being silently treated as a fresh result from today's model.
    let scoredDay: Date?
    let usesHRV: Bool
    let detail: String
    let contributors: [Contributor]

    init(score: Int,
         confidence: String,
         source: String,
         model: String? = nil,
         scoredDay: Date? = nil,
         usesHRV: Bool,
         detail: String,
         contributors: [Contributor]) {
        self.score = min(max(score, 0), 100)
        self.confidence = confidence
        self.source = source
        self.model = model
        self.scoredDay = scoredDay
        self.usesHRV = usesHRV
        self.detail = detail
        self.contributors = contributors
    }

    init?(estimate: Metrics.RecoveryEstimate,
         scoredDay: Date,
         source: String = FrozenRecoverySummary.recoveryV2Source,
         model: String? = "recovery_v2") {
        guard let score = estimate.percent else { return nil }
        self.init(score: score,
                  confidence: estimate.confidence.rawValue,
                  source: source,
                  model: model,
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
                  })
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
                  scoredDay: metric.day,
                  usesHRV: metric.hrv != nil,
                  detail: "frozen daily recovery",
                  contributors: values)
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
                                     scoredDay: scoredDay,
                                     usesHRV: lnRMSSD != nil,
                                     detail: "frozen daily recovery",
                                     contributors: values)
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
                                     scoredDay: scoredDay,
                                     usesHRV: usesHRV,
                                     detail: nextDetail,
                                     contributors: contributors)
    }

    func replacingScoredDay(_ day: Date) -> FrozenRecoverySummary {
        FrozenRecoverySummary(score: score,
                              confidence: confidence,
                              source: source,
                              model: model,
                              scoredDay: day,
                              usesHRV: usesHRV,
                              detail: detail,
                              contributors: contributors)
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
            return .validated
        default:
            // Unknown historical labels stay conservative. They must never be
            // upgraded using whatever baseline happens to be current today.
            return .unverified
        }
    }
}

enum DailyRecoveryResolver {
    struct DisplayResolution: Equatable {
        let summary: FrozenRecoverySummary
        let liftedAfterNap: Bool
    }

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
                      calendar.isDate($0.day, inSameDayAs: physiologicalCycle.start)
                          && $0.recovery != nil
                  }),
                  let metric = metrics.first(where: {
                      calendar.isDate($0.day, inSameDayAs: physiologicalCycle.start)
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
            guard anchorSleep.id == physiologicalCycle.anchorSleepID,
                  anchorSleep.confirmed,
                  !anchorSleep.isNapEvidence,
                  let metric,
                  metricMatchesConfirmedNight(metric, night: anchorSleep) else {
                return nil
            }
        }
        return rollup.resolvedRecoverySummary(matching: metric, calendar: calendar)
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
              calendar.isDate(metric.day, inSameDayAs: physiologicalCycle.start),
              summary.scoredDay.map({
                  calendar.isDate($0, inSameDayAs: physiologicalCycle.start)
              }) == true else {
            return false
        }
        return limitedFallbackMetricIsStructurallyAuthoritative(
            metric,
            summary: summary,
            day: physiologicalCycle.start,
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

    static var noSleepEstimate: Metrics.RecoveryEstimate {
        Metrics.RecoveryEstimate(
            percent: nil,
            confidence: .unverified,
            usesHRV: false,
            detail: "No confirmed main sleep was recorded for this physiological cycle, so recovery is unavailable.",
            contributors: []
        )
    }

    static func applyingNap(to summary: FrozenRecoverySummary,
                            sleepHistory: SleepHistorySnapshot,
                            latestSleep: SleepHistorySnapshot.Night?,
                            calendar: Calendar = .current) -> DisplayResolution {
        guard let latestSleep,
              let scoredDay = summary.scoredDay,
              calendar.isDate(scoredDay, inSameDayAs: latestSleep.day) else {
            return DisplayResolution(summary: summary, liftedAfterNap: false)
        }
        let adjustment = sleepHistory.napAdjustedRecovery(morningRecovery: summary.score,
                                                          for: latestSleep,
                                                          calendar: calendar)
        guard adjustment.lifted, let percent = adjustment.percent else {
            return DisplayResolution(summary: summary, liftedAfterNap: false)
        }
        return DisplayResolution(summary: summary.replacingScore(percent, detailSuffix: "nap_lift"),
                                 liftedAfterNap: true)
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
    var sleepPerformance: Int?
    var bedtimeMinutes: Int?
    var strain: Double?
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

    var id: Date { day }

    private enum CodingKeys: String, CodingKey {
        case day
        case tzOffsetMinutes
        case recovery
        case recoverySummary
        case lnRMSSD
        case rhr
        case sleepSeconds
        case sleepPerformance
        case bedtimeMinutes
        case strain
        case respiratoryRate
        case skinTemperatureDeviationCelsius
        case vitals
        case nutrition
        case fitnessAgeDelta
    }

    init(day: Date,
         tzOffsetMinutes: Int? = nil,
         recovery: Int? = nil,
         recoverySummary: FrozenRecoverySummary? = nil,
         lnRMSSD: Double? = nil,
         rhr: Int? = nil,
         sleepSeconds: TimeInterval? = nil,
         sleepPerformance: Int? = nil,
         bedtimeMinutes: Int? = nil,
         strain: Double? = nil,
         respiratoryRate: Double? = nil,
         skinTemperatureDeviationCelsius: Double? = nil,
         vitals: DailyRollupVitals? = nil,
         nutrition: AtriaNutritionSummary? = nil,
         fitnessAgeDelta: Int? = nil,
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
        self.sleepPerformance = sleepPerformance
        self.bedtimeMinutes = bedtimeMinutes
        self.strain = strain
        self.respiratoryRate = respiratoryRate
        self.skinTemperatureDeviationCelsius = skinTemperatureDeviationCelsius
        self.vitals = vitals
        self.nutrition = nutrition
        self.fitnessAgeDelta = fitnessAgeDelta
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
        sleepPerformance = try container.decodeIfPresent(Int.self, forKey: .sleepPerformance)
        bedtimeMinutes = try container.decodeIfPresent(Int.self, forKey: .bedtimeMinutes)
        strain = try container.decodeIfPresent(Double.self, forKey: .strain)
        respiratoryRate = try container.decodeIfPresent(Double.self, forKey: .respiratoryRate)
        skinTemperatureDeviationCelsius = try container.decodeIfPresent(Double.self, forKey: .skinTemperatureDeviationCelsius)
        vitals = try container.decodeIfPresent(DailyRollupVitals.self, forKey: .vitals)
        nutrition = try container.decodeIfPresent(AtriaNutritionSummary.self, forKey: .nutrition)
        fitnessAgeDelta = try container.decodeIfPresent(Int.self, forKey: .fitnessAgeDelta)
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
        try container.encodeIfPresent(sleepPerformance, forKey: .sleepPerformance)
        try container.encodeIfPresent(bedtimeMinutes, forKey: .bedtimeMinutes)
        try container.encodeIfPresent(strain, forKey: .strain)
        try container.encodeIfPresent(respiratoryRate, forKey: .respiratoryRate)
        try container.encodeIfPresent(skinTemperatureDeviationCelsius, forKey: .skinTemperatureDeviationCelsius)
        try container.encodeIfPresent(vitals, forKey: .vitals)
        try container.encodeIfPresent(nutrition, forKey: .nutrition)
        try container.encodeIfPresent(fitnessAgeDelta, forKey: .fitnessAgeDelta)
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
                                                   sleepPerformance: entry.sleepPerformance,
                                                   bedtimeMinutes: entry.bedtimeMinutes,
                                                   strain: entry.strain,
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
                              sleepPerformance: rollup.sleepPerformance,
                              bedtimeMinutes: rollup.bedtimeMinutes,
                              strain: rollup.strain,
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

    private static func persist(_ rollups: [DailyRollupStoreEntry], to url: URL) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(rollups)
            try data.write(to: url, options: .atomic)
            AtriaDebugLog("ATRIADBG daily_rollup_store_save status=ok rows=%d bytes=%d path=%@",
                          rollups.count,
                          data.count,
                          url.lastPathComponent)
        } catch {
            AtriaDebugLog("ATRIADBG daily_rollup_store_save status=failed error=%@",
                          error.localizedDescription)
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
