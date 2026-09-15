import Foundation

/// Physiological insights that do not depend on journal tags. Computed from
/// persisted daily rollups so they survive raw-archive retirement.
struct AtriaLearnedInsight: Identifiable, Equatable, Codable, Sendable {
    enum Kind: String, Codable, Equatable, Sendable {
        case sleepDebt
        case weeklySleepDebt
        case loadMismatch
        case restingHRDrift
        case recoveryDrift
        case hrvDrift
        case weeklyStrain
        case bedtimeSpread
        case daySnapshot
        case readiness
        case yesterdayStrain
        case stackedRecovery
    }

    let id: String
    let kind: Kind
    let headline: String
    let detail: String
    let isPositive: Bool
    let asOf: Date

    var systemImage: String {
        switch kind {
        case .sleepDebt, .weeklySleepDebt, .bedtimeSpread: return "moon.zzz.fill"
        case .loadMismatch, .weeklyStrain, .yesterdayStrain: return "bolt.heart.fill"
        case .restingHRDrift: return "heart.fill"
        case .recoveryDrift, .readiness, .stackedRecovery: return "figure.walk"
        case .hrvDrift: return "waveform.path.ecg"
        case .daySnapshot: return "calendar"
        }
    }

    /// Larger, more pictorial glyph for Today's read rings. Distinct from the
    /// compact-bar icon so Sleep / Recovery / Strain can be recognized at a
    /// glance.
    var pictureSystemImage: String {
        switch kind {
        case .sleepDebt: return "moon.stars.fill"
        case .weeklySleepDebt: return "moon.fill"
        case .bedtimeSpread: return "clock.fill"
        case .recoveryDrift, .readiness: return "heart.circle.fill"
        case .stackedRecovery: return "square.stack.3d.up.fill"
        case .hrvDrift: return "waveform.path.ecg"
        case .restingHRDrift: return "heart.fill"
        case .loadMismatch, .weeklyStrain: return "bolt.heart.fill"
        case .yesterdayStrain: return "flame.fill"
        case .daySnapshot: return "sun.max.fill"
        }
    }

    enum RingFamily: String, Equatable, Sendable {
        case recovery
        case sleep
        case strain
        case other

        var title: String {
            switch self {
            case .recovery: return "Recovery"
            case .sleep: return "Sleep"
            case .strain: return "Strain"
            case .other: return "Read"
            }
        }
    }

    var ringFamily: RingFamily {
        switch kind {
        case .sleepDebt, .weeklySleepDebt, .bedtimeSpread: return .sleep
        case .recoveryDrift, .readiness, .stackedRecovery, .hrvDrift, .restingHRDrift:
            return .recovery
        case .loadMismatch, .weeklyStrain, .yesterdayStrain: return .strain
        case .daySnapshot: return .other
        }
    }

    /// Visual valence for the picture ring. Not a metric score.
    var pictureRingFill: Double {
        isPositive ? 0.84 : 0.36
    }

    /// Lower ranks win the Sleep / Recovery / Strain hero slot.
    var ringHeroRank: Int {
        switch kind {
        case .stackedRecovery: return 0
        case .recoveryDrift: return 1
        case .readiness: return 2
        case .hrvDrift: return 3
        case .restingHRDrift: return 4
        case .sleepDebt: return 0
        case .weeklySleepDebt: return 1
        case .bedtimeSpread: return 2
        case .yesterdayStrain: return 0
        case .loadMismatch: return 1
        case .weeklyStrain: return 2
        case .daySnapshot: return 9
        }
    }

    /// One Sleep / Recovery / Strain read, in the same order as Today's rings.
    static func ringHeroInsights(from insights: [AtriaLearnedInsight]) -> [AtriaLearnedInsight] {
        let order: [RingFamily] = [.recovery, .sleep, .strain]
        return order.compactMap { family in
            insights
                .filter { $0.ringFamily == family }
                .min { $0.ringHeroRank < $1.ringHeroRank }
        }
    }

    var emphasisLabel: String {
        switch kind {
        case .sleepDebt: return isPositive ? "Covered" : "Short"
        case .weeklySleepDebt: return "Week"
        case .loadMismatch: return isPositive ? "Cleared" : "Load"
        case .restingHRDrift: return isPositive ? "Calmer" : "Elevated"
        case .recoveryDrift: return isPositive ? "Up" : "Down"
        case .hrvDrift: return isPositive ? "Higher" : "Lower"
        case .weeklyStrain: return isPositive ? "Easier" : "Heavier"
        case .bedtimeSpread: return "Clock"
        case .daySnapshot: return "Today"
        case .readiness: return isPositive ? "Go" : "Hold"
        case .yesterdayStrain: return "Yesterday"
        case .stackedRecovery: return "Stack"
        }
    }
}

/// Compact ledger written beside rollups. Raw historical chunks may be retired
/// after 7 days; this file is never a retention candidate. Schema 1 stored
/// only the current read; schema 2 keeps a 21-day day-by-day ledger so a
/// later refresh cannot erase earlier captures.
enum AtriaDurableInsightStore {
    static let filename = "learned-insights-v1.json"
    static let schema = 2
    static let supportedSchemas: Set<Int> = [1, 2]
    static let ledgerHorizonDays = 21

    struct Payload: Codable, Equatable {
        var schema: Int
        var updatedAt: Date
        var insights: [AtriaLearnedInsight]
        var ledger: [AtriaLearnedInsight]

        init(schema: Int = AtriaDurableInsightStore.schema,
             updatedAt: Date,
             insights: [AtriaLearnedInsight],
             ledger: [AtriaLearnedInsight] = []) {
            self.schema = schema
            self.updatedAt = updatedAt
            self.insights = insights
            self.ledger = ledger
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schema = try container.decode(Int.self, forKey: .schema)
            updatedAt = try container.decode(Date.self, forKey: .updatedAt)
            insights = try container.decode([AtriaLearnedInsight].self, forKey: .insights)
            ledger = try container.decodeIfPresent([AtriaLearnedInsight].self, forKey: .ledger) ?? []
        }
    }

    static func fileURL(
        documents: URL? = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first
    ) -> URL? {
        documents?.appendingPathComponent(filename)
    }

    static func loadPayload(from url: URL? = fileURL()) -> Payload {
        guard let url,
              let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              supportedSchemas.contains(payload.schema) else {
            return Payload(updatedAt: Date(timeIntervalSince1970: 0), insights: [])
        }
        return payload
    }

    static func load(from url: URL? = fileURL()) -> [AtriaLearnedInsight] {
        loadPayload(from: url).insights
    }

    static func loadLedger(from url: URL? = fileURL()) -> [AtriaLearnedInsight] {
        loadPayload(from: url).ledger
    }

    /// Keep one snapshot per civil day. Incoming rollup reads win for that
    /// day; days the current rollup set no longer has still stay until they
    /// fall outside the 21-day horizon.
    static func mergeLedger(existing: [AtriaLearnedInsight],
                            incoming: [AtriaLearnedInsight],
                            now: Date,
                            calendar: Calendar = .current) -> [AtriaLearnedInsight] {
        let today = calendar.startOfDay(for: now)
        let cutoff = calendar.date(byAdding: .day, value: -ledgerHorizonDays, to: today) ?? today
        var byDay: [TimeInterval: AtriaLearnedInsight] = [:]
        for insight in existing + incoming {
            let day = calendar.startOfDay(for: insight.asOf)
            guard day >= cutoff else { continue }
            byDay[day.timeIntervalSince1970] = insight
        }
        return byDay.values.sorted { $0.asOf > $1.asOf }
    }

    @discardableResult
    static func save(_ insights: [AtriaLearnedInsight],
                     ledger: [AtriaLearnedInsight] = [],
                     at url: URL? = fileURL(),
                     now: Date = Date()) -> Bool {
        guard let url else { return false }
        let payload = Payload(updatedAt: now, insights: insights, ledger: ledger)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload) else { return false }
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}

enum AtriaLearnedInsights {
    static let maximumInsights = 7

    static func insights(rollups: [DailyRollupStoreEntry],
                         now: Date = Date(),
                         sleepNeedFallbackSeconds: TimeInterval? = nil) -> [AtriaLearnedInsight] {
        let ordered = rollups.sorted { $0.day > $1.day }
        guard let latest = ordered.first else { return [] }
        var results: [AtriaLearnedInsight] = []
        let fallbackNeed = sleepNeedFallbackSeconds.flatMap { $0 > 0 ? $0 : nil }

        if let stacked = stackedRecovery(ordered: ordered, now: now, sleepNeedFallbackSeconds: fallbackNeed) {
            results.append(stacked)
        }
        if let sleep = sleepDebt(ordered: ordered, now: now, sleepNeedFallbackSeconds: fallbackNeed) {
            results.append(sleep)
        }
        if let recovery = recoveryDrift(ordered: ordered, now: now) {
            results.append(recovery)
        }
        if let weekly = weeklySleepDebt(ordered: ordered, now: now, sleepNeedFallbackSeconds: fallbackNeed) {
            results.append(weekly)
        }
        if let yesterday = yesterdayStrain(ordered: ordered, now: now) {
            results.append(yesterday)
        }
        if let load = loadMismatch(ordered: ordered, now: now) {
            results.append(load)
        }
        if let hrv = hrvDrift(ordered: ordered, now: now) {
            results.append(hrv)
        }
        if let rhr = restingHRDrift(ordered: ordered, now: now) {
            results.append(rhr)
        }
        if let strain = weeklyStrain(ordered: ordered, now: now) {
            results.append(strain)
        }
        if let bedtime = bedtimeSpread(ordered: ordered, now: now) {
            results.append(bedtime)
        }
        if let plan = readiness(latest: latest, now: now) {
            results.append(plan)
        }
        if results.isEmpty, let snapshot = daySnapshot(latest: latest, now: now) {
            results.append(snapshot)
        }

        return Array(results.prefix(maximumInsights))
    }

    private static func hours(_ seconds: TimeInterval) -> Double {
        seconds / 3600
    }

    private static func hourText(_ hoursValue: Double) -> String {
        let totalMinutes = Int((hoursValue * 60).rounded())
        let hrs = totalMinutes / 60
        let mins = abs(totalMinutes % 60)
        if hrs == 0 { return "\(mins)m" }
        if mins == 0 { return "\(hrs)h" }
        return "\(hrs)h \(mins)m"
    }

    /// Most recent night that actually recorded sleep. Today's in-progress
    /// rollup is often empty at dawn, which previously hid last night entirely.
    private static func mostRecentSleepNight(
        _ ordered: [DailyRollupStoreEntry]
    ) -> DailyRollupStoreEntry? {
        ordered.first { ($0.sleepSeconds ?? 0) > 0 }
    }

    /// Frozen sleep-need when present; otherwise the median of other measured
    /// nights. Never writes a fabricated need back onto the rollup.
    private static func sleepReferenceSeconds(
        for entry: DailyRollupStoreEntry,
        ordered: [DailyRollupStoreEntry],
        sleepNeedFallbackSeconds: TimeInterval? = nil
    ) -> (seconds: TimeInterval, kind: String)? {
        if let need = entry.sleepNeedSeconds, need > 0 {
            return (need, "need")
        }
        if let fallback = sleepNeedFallbackSeconds, fallback > 0 {
            return (fallback, "need")
        }
        let others = ordered.compactMap { other -> TimeInterval? in
            guard other.day != entry.day, let slept = other.sleepSeconds, slept > 0 else {
                return nil
            }
            return slept
        }
        guard others.count >= 3 else { return nil }
        let sorted = others.sorted()
        return (sorted[sorted.count / 2], "usual")
    }

    private static let shortNightSeconds: TimeInterval = 6.5 * 3_600

    private static func sleepDebt(ordered: [DailyRollupStoreEntry],
                                  now: Date,
                                  sleepNeedFallbackSeconds: TimeInterval? = nil) -> AtriaLearnedInsight? {
        guard let night = mostRecentSleepNight(ordered),
              let slept = night.sleepSeconds, slept > 0 else { return nil }
        let sleptText = hourText(hours(slept))
        if let reference = sleepReferenceSeconds(
            for: night,
            ordered: ordered,
            sleepNeedFallbackSeconds: sleepNeedFallbackSeconds
        ) {
            let deltaHours = hours(reference.seconds - slept)
            if abs(deltaHours) >= 0.4 {
                let referenceText = hourText(hours(reference.seconds))
                if deltaHours > 0 {
                    let versus = reference.kind == "need"
                        ? "against a \(referenceText) need"
                        : "versus your usual \(referenceText)"
                    return AtriaLearnedInsight(
                        id: "sleep-debt",
                        kind: .sleepDebt,
                        headline: "Last night was \(hourText(deltaHours)) under your \(reference.kind)",
                        detail: "You slept \(sleptText) \(versus). That gap is tonight's first recovery lever.",
                        isPositive: false,
                        asOf: now
                    )
                }
                return AtriaLearnedInsight(
                    id: "sleep-surplus",
                    kind: .sleepDebt,
                    headline: "Last night covered your sleep \(reference.kind)",
                    detail: "You slept \(sleptText) against \(referenceText) — a real surplus, not a rounded guess.",
                    isPositive: true,
                    asOf: now
                )
            }
        }
        guard slept < shortNightSeconds else { return nil }
        return AtriaLearnedInsight(
            id: "sleep-short",
            kind: .sleepDebt,
            headline: "Last night was only \(sleptText)",
            detail: "That's a short night even without a stored sleep-need. Protect this evening if you can.",
            isPositive: false,
            asOf: now
        )
    }

    /// Prefer a stored sleep-need from this week so chronic short nights are
    /// not compared only to each other. A week of 4–5 h nights has a low
    /// median, which previously hid several hours of debt versus the need
    /// already on the latest rollup.
    private static func weeklyStoredSleepNeedSeconds(
        _ ordered: [DailyRollupStoreEntry],
        sleepNeedFallbackSeconds: TimeInterval? = nil
    ) -> TimeInterval? {
        let week = ordered.prefix(7).compactMap(\.sleepNeedSeconds).filter { $0 > 0 }
        if let latest = week.first { return latest }
        if let fallback = sleepNeedFallbackSeconds, fallback > 0 { return fallback }
        return ordered.compactMap(\.sleepNeedSeconds).first { $0 > 0 }
    }

    private static func weeklySleepDebt(ordered: [DailyRollupStoreEntry],
                                        now: Date,
                                        sleepNeedFallbackSeconds: TimeInterval? = nil) -> AtriaLearnedInsight? {
        let storedNeed = weeklyStoredSleepNeedSeconds(
            ordered,
            sleepNeedFallbackSeconds: sleepNeedFallbackSeconds
        )
        let window = ordered.prefix(7).compactMap { entry -> Double? in
            guard let slept = entry.sleepSeconds, slept > 0 else { return nil }
            if let need = entry.sleepNeedSeconds ?? storedNeed, need > 0 {
                return hours(need - slept)
            }
            return nil
        }
        guard window.count >= 4 else { return nil }
        let total = window.reduce(0, +)
        guard total >= 2.5 else { return nil }
        let needText = storedNeed.map { hourText(hours($0)) }
        let versus = needText.map { "versus a \($0) sleep need" }
            ?? "versus the sleep need stored from your nights"
        return AtriaLearnedInsight(
            id: "weekly-sleep-debt",
            kind: .weeklySleepDebt,
            headline: "\(hourText(total)) of sleep debt this week",
            detail: "Across \(window.count) measured nights the shortfall adds up \(versus).",
            isPositive: false,
            asOf: now
        )
    }

    private static func loadMismatch(ordered: [DailyRollupStoreEntry],
                                     now: Date) -> AtriaLearnedInsight? {
        guard ordered.count >= 2 else { return nil }
        let today = ordered[0]
        let yesterday = ordered[1]
        guard let recovery = today.recovery,
              let strain = yesterday.strain, strain >= 8 else { return nil }
        if recovery <= 49 {
            return AtriaLearnedInsight(
                id: "load-mismatch",
                kind: .loadMismatch,
                headline: "Yesterday's strain has not cleared",
                detail: String(format: "Strain was %.1f and recovery is %d%%. Keep today's load easy until recovery climbs.",
                               strain, recovery),
                isPositive: false,
                asOf: now
            )
        }
        if recovery >= 70, strain >= 10 {
            return AtriaLearnedInsight(
                id: "load-cleared",
                kind: .loadMismatch,
                headline: "You absorbed yesterday's load",
                detail: String(format: "Strain was %.1f and recovery is still %d%%. You can train if the rest of the day stays honest.",
                               strain, recovery),
                isPositive: true,
                asOf: now
            )
        }
        return nil
    }

    private static func restingHRDrift(ordered: [DailyRollupStoreEntry],
                                       now: Date) -> AtriaLearnedInsight? {
        guard let latest = ordered.first?.rhr, latest > 0 else { return nil }
        let prior = ordered.dropFirst().prefix(7).compactMap(\.rhr).filter { $0 > 0 }
        guard prior.count >= 3 else { return nil }
        let mean = Double(prior.reduce(0, +)) / Double(prior.count)
        let delta = Int((Double(latest) - mean).rounded())
        guard abs(delta) >= 3 else { return nil }
        if delta > 0 {
            return AtriaLearnedInsight(
                id: "rhr-up",
                kind: .restingHRDrift,
                headline: "Resting HR is \(delta) bpm above usual",
                detail: "This morning is \(latest) bpm versus \(Int(mean.rounded())) bpm across the last \(prior.count) mornings. Heat, late strain, or short sleep usually sit behind that.",
                isPositive: false,
                asOf: now
            )
        }
        return AtriaLearnedInsight(
            id: "rhr-down",
            kind: .restingHRDrift,
            headline: "Resting HR is \(abs(delta)) bpm below usual",
            detail: "This morning is \(latest) bpm versus \(Int(mean.rounded())) bpm across the last \(prior.count) mornings — a calmer baseline, not a one-beat flicker.",
            isPositive: true,
            asOf: now
        )
    }

    private static func readiness(latest: DailyRollupStoreEntry,
                                  now: Date) -> AtriaLearnedInsight? {
        let recovery = latest.recovery
        let sleepPerformance = latest.sleepPerformance
        let rhr = latest.rhr
        guard recovery != nil || sleepPerformance != nil || rhr != nil else { return nil }

        let recovering = (recovery.map { $0 <= 49 } ?? false)
            || (sleepPerformance.map { $0 < 70 } ?? false)
        let pushing = (recovery.map { $0 >= 70 } ?? false)
            && (sleepPerformance.map { $0 >= 90 } ?? true)

        if recovering {
            var parts: [String] = []
            if let recovery { parts.append("recovery \(recovery)%") }
            if let sleepPerformance { parts.append("sleep \(sleepPerformance)% of need") }
            return AtriaLearnedInsight(
                id: "readiness-recover",
                kind: .readiness,
                headline: "Today: recover",
                detail: "Signals say back off — \(parts.joined(separator: ", ")). Keep the day's load lighter than usual.",
                isPositive: false,
                asOf: now
            )
        }
        if pushing {
            return AtriaLearnedInsight(
                id: "readiness-push",
                kind: .readiness,
                headline: "Today: you can push",
                detail: "Recovery and last night both cleared the bar. Keep the work inside a day you can still finish well.",
                isPositive: true,
                asOf: now
            )
        }
        return AtriaLearnedInsight(
            id: "readiness-maintain",
            kind: .readiness,
            headline: "Today: maintain",
            detail: "Nothing is loudly off, and nothing is loudly green. Keep the usual load; do not stack a surprise peak.",
            isPositive: true,
            asOf: now
        )
    }

    private static func recoveryDrift(ordered: [DailyRollupStoreEntry],
                                      now: Date) -> AtriaLearnedInsight? {
        guard let latest = ordered.first?.recovery else { return nil }
        let prior = ordered.dropFirst().prefix(7).compactMap(\.recovery)
        guard prior.count >= 3 else {
            return AtriaLearnedInsight(
                id: "recovery-today",
                kind: .recoveryDrift,
                headline: latest <= 49
                    ? "Recovery is \(latest)% — take it easy"
                    : "Recovery is \(latest)% this morning",
                detail: latest <= 49
                    ? "That is a yellow morning. Keep strain light until this number climbs."
                    : "A few more mornings will show whether this is your usual or a one-day swing.",
                isPositive: latest >= 67,
                asOf: now
            )
        }
        let mean = Double(prior.reduce(0, +)) / Double(prior.count)
        let delta = Int((Double(latest) - mean).rounded())
        guard abs(delta) >= 8 || latest <= 49 else { return nil }
        if delta < 0 {
            return AtriaLearnedInsight(
                id: "recovery-down",
                kind: .recoveryDrift,
                headline: "Recovery is \(abs(delta)) points below your week",
                detail: "This morning is \(latest)% versus \(Int(mean.rounded()))% across the last \(prior.count) mornings. Sleep, heat, or yesterday's load usually sit behind that.",
                isPositive: false,
                asOf: now
            )
        }
        return AtriaLearnedInsight(
            id: "recovery-up",
            kind: .recoveryDrift,
            headline: "Recovery is \(delta) points above your week",
            detail: "This morning is \(latest)% versus \(Int(mean.rounded()))% across the last \(prior.count) mornings — a real bounce, not a one-point flicker.",
            isPositive: true,
            asOf: now
        )
    }

    private static func hrvDrift(ordered: [DailyRollupStoreEntry],
                                 now: Date) -> AtriaLearnedInsight? {
        func ms(_ ln: Double) -> Int { Int(exp(ln).rounded()) }
        guard let latestLn = ordered.first?.lnRMSSD else { return nil }
        let prior = ordered.dropFirst().prefix(7).compactMap(\.lnRMSSD)
        guard prior.count >= 3 else { return nil }
        let latest = ms(latestLn)
        let mean = ms(prior.reduce(0, +) / Double(prior.count))
        let delta = latest - mean
        guard abs(delta) >= 6 else { return nil }
        if delta < 0 {
            return AtriaLearnedInsight(
                id: "hrv-down",
                kind: .hrvDrift,
                headline: "HRV is \(abs(delta)) ms below usual",
                detail: "This morning is \(latest) ms versus \(mean) ms across the last \(prior.count) mornings. Short sleep and leftover strain pull this down.",
                isPositive: false,
                asOf: now
            )
        }
        return AtriaLearnedInsight(
            id: "hrv-up",
            kind: .hrvDrift,
            headline: "HRV is \(delta) ms above usual",
            detail: "This morning is \(latest) ms versus \(mean) ms across the last \(prior.count) mornings — a calmer beat-to-beat picture.",
            isPositive: true,
            asOf: now
        )
    }

    private static func weeklyStrain(ordered: [DailyRollupStoreEntry],
                                     now: Date) -> AtriaLearnedInsight? {
        let current = ordered.prefix(7).compactMap(\.strain)
        let previous = ordered.dropFirst(7).prefix(7).compactMap(\.strain)
        guard current.count >= 4, previous.count >= 4 else { return nil }
        let currentSum = current.reduce(0, +)
        let previousSum = previous.reduce(0, +)
        guard previousSum > 0 else { return nil }
        let ratio = currentSum / previousSum
        guard ratio >= 1.25 || ratio <= 0.75 else { return nil }
        if ratio >= 1.25 {
            return AtriaLearnedInsight(
                id: "strain-up",
                kind: .weeklyStrain,
                headline: "This week's load is up \(Int(((ratio - 1) * 100).rounded()))%",
                detail: String(format: "Strain summed to %.0f over %d days versus %.0f the week before. Bank sleep or this compounds.",
                               currentSum, current.count, previousSum),
                isPositive: false,
                asOf: now
            )
        }
        return AtriaLearnedInsight(
            id: "strain-down",
            kind: .weeklyStrain,
            headline: "This week's load is down \(Int(((1 - ratio) * 100).rounded()))%",
            detail: String(format: "Strain summed to %.0f over %d days versus %.0f the week before. Use the room, or keep deloading if recovery is still catching up.",
                           currentSum, current.count, previousSum),
            isPositive: true,
            asOf: now
        )
    }

    private static func bedtimeSpread(ordered: [DailyRollupStoreEntry],
                                      now: Date) -> AtriaLearnedInsight? {
        let times = Array(ordered.compactMap(\.bedtimeMinutes).prefix(7))
        guard times.count >= 4 else { return nil }
        let mean = Double(times.reduce(0, +)) / Double(times.count)
        let variance = times.reduce(0.0) { $0 + pow(Double($1) - mean, 2) } / Double(times.count)
        let stdevMinutes = sqrt(variance)
        guard stdevMinutes >= 45 else { return nil }
        return AtriaLearnedInsight(
            id: "bedtime-spread",
            kind: .bedtimeSpread,
            headline: "Bedtime is swinging by \(Int(stdevMinutes.rounded())) minutes",
            detail: "Across \(times.count) nights the clock is not settling. A tighter window is one of the fastest recovery levers you still control.",
            isPositive: false,
            asOf: now
        )
    }

    private static func daySnapshot(latest: DailyRollupStoreEntry,
                                    now: Date) -> AtriaLearnedInsight? {
        var parts: [String] = []
        if let recovery = latest.recovery { parts.append("recovery \(recovery)%") }
        if let strain = latest.strain {
            parts.append(String(format: "strain %.1f", strain))
        }
        if let slept = latest.sleepSeconds, slept > 0 {
            parts.append("sleep \(hourText(hours(slept)))")
        }
        if let rhr = latest.rhr, rhr > 0 { parts.append("RHR \(rhr)") }
        guard !parts.isEmpty else { return nil }
        return AtriaLearnedInsight(
            id: "day-snapshot",
            kind: .daySnapshot,
            headline: "Today's picture",
            detail: parts.joined(separator: " · ") + ". These stay even after raw sensor files are retired.",
            isPositive: (latest.recovery ?? 50) >= 50,
            asOf: now
        )
    }

    private static func yesterdayStrain(ordered: [DailyRollupStoreEntry],
                                        now: Date) -> AtriaLearnedInsight? {
        guard ordered.count >= 2, let strain = ordered[1].strain, strain >= 6 else {
            return nil
        }
        let prior = ordered.dropFirst(2).prefix(6).compactMap(\.strain)
        let comparison: String
        if prior.count >= 3 {
            let mean = prior.reduce(0, +) / Double(prior.count)
            if strain >= mean + 3 {
                comparison = String(format: "That sits %.1f above your recent days. Recover today before stacking another peak.",
                                    strain - mean)
            } else if strain + 3 <= mean {
                comparison = String(format: "That is lighter than your recent %.1f average — room to train if recovery agrees.",
                                    mean)
            } else {
                comparison = "In line with your recent days. Do not treat it as a free pass or a warning on its own."
            }
        } else {
            comparison = "Today's first job is to clear it, not to match it."
        }
        return AtriaLearnedInsight(
            id: "yesterday-strain",
            kind: .yesterdayStrain,
            headline: String(format: "Yesterday carried %.1f strain", strain),
            detail: comparison,
            isPositive: strain < 10,
            asOf: now
        )
    }

    private static func stackedRecovery(ordered: [DailyRollupStoreEntry],
                                        now: Date,
                                        sleepNeedFallbackSeconds: TimeInterval? = nil) -> AtriaLearnedInsight? {
        guard let latest = ordered.first,
              let recovery = latest.recovery, recovery <= 49,
              let night = mostRecentSleepNight(ordered),
              let slept = night.sleepSeconds, slept > 0 else { return nil }
        let referenceSeconds = sleepReferenceSeconds(
            for: night,
            ordered: ordered,
            sleepNeedFallbackSeconds: sleepNeedFallbackSeconds
        )?.seconds
            ?? shortNightSeconds
        let deltaHours = hours(referenceSeconds - slept)
        guard deltaHours >= 1 else { return nil }
        return AtriaLearnedInsight(
            id: "stacked-recovery",
            kind: .stackedRecovery,
            headline: "Low recovery is stacked on short sleep",
            detail: "Recovery is \(recovery)% and last night was \(hourText(deltaHours)) under a full night. Easy movement only until both move.",
            isPositive: false,
            asOf: now
        )
    }

    /// One captured read per civil day for the last 21 nights. Today's
    /// current-state cards stay in `insights(rollups:)`; this is the ledger
    /// that must survive a later refresh overwriting those seven.
    static func dailyReads(rollups: [DailyRollupStoreEntry],
                           now: Date = Date(),
                           calendar: Calendar = .current) -> [AtriaLearnedInsight] {
        let today = calendar.startOfDay(for: now)
        let cutoff = calendar.date(
            byAdding: .day,
            value: -AtriaDurableInsightStore.ledgerHorizonDays,
            to: today
        ) ?? today
        return rollups
            .filter { $0.day >= cutoff }
            .sorted { $0.day > $1.day }
            .compactMap { dayRead(entry: $0, calendar: calendar) }
    }

    private static func dayRead(entry: DailyRollupStoreEntry,
                                calendar: Calendar) -> AtriaLearnedInsight? {
        var parts: [String] = []
        if let recovery = entry.recovery { parts.append("recovery \(recovery)%") }
        if let strain = entry.strain {
            parts.append(String(format: "strain %.1f", strain))
        }
        if let slept = entry.sleepSeconds, slept > 0 {
            parts.append("sleep \(hourText(hours(slept)))")
        }
        if let rhr = entry.rhr, rhr > 0 { parts.append("RHR \(rhr)") }
        if let hrv = entry.lnRMSSD, hrv > 0 {
            parts.append(String(format: "HRV %.0f", hrv))
        }
        guard !parts.isEmpty else { return nil }
        let day = calendar.startOfDay(for: entry.day)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEE d MMM"
        let dayText = formatter.string(from: day)
        let headline: String
        if let recovery = entry.recovery {
            headline = "\(dayText) · recovery \(recovery)%"
        } else if let slept = entry.sleepSeconds, slept > 0 {
            headline = "\(dayText) · slept \(hourText(hours(slept)))"
        } else {
            headline = dayText
        }
        return AtriaLearnedInsight(
            id: "day-read-\(Int(day.timeIntervalSince1970))",
            kind: .daySnapshot,
            headline: headline,
            detail: parts.joined(separator: " · ") + ".",
            isPositive: (entry.recovery ?? 50) >= 50,
            asOf: day
        )
    }
}
