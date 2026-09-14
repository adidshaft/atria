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
        case .loadMismatch, .weeklyStrain: return "bolt.heart.fill"
        case .restingHRDrift: return "heart.fill"
        case .recoveryDrift, .readiness: return "figure.walk"
        case .hrvDrift: return "waveform.path.ecg"
        case .daySnapshot: return "calendar"
        }
    }
}

/// Compact ledger written beside rollups. Raw historical chunks may be retired
/// after 7 days; this file is never a retention candidate.
enum AtriaDurableInsightStore {
    static let filename = "learned-insights-v1.json"
    static let schema = 1

    struct Payload: Codable, Equatable {
        var schema: Int
        var updatedAt: Date
        var insights: [AtriaLearnedInsight]
    }

    static func fileURL(
        documents: URL? = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first
    ) -> URL? {
        documents?.appendingPathComponent(filename)
    }

    static func load(from url: URL? = fileURL()) -> [AtriaLearnedInsight] {
        guard let url,
              let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.schema == schema else { return [] }
        return payload.insights
    }

    @discardableResult
    static func save(_ insights: [AtriaLearnedInsight],
                     at url: URL? = fileURL(),
                     now: Date = Date()) -> Bool {
        guard let url else { return false }
        let payload = Payload(schema: schema, updatedAt: now, insights: insights)
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
    static let maximumInsights = 6

    static func insights(rollups: [DailyRollupStoreEntry],
                         now: Date = Date()) -> [AtriaLearnedInsight] {
        let ordered = rollups.sorted { $0.day > $1.day }
        guard let latest = ordered.first else { return [] }
        var results: [AtriaLearnedInsight] = []

        if let sleep = sleepDebt(latest: latest, now: now) {
            results.append(sleep)
        }
        if let recovery = recoveryDrift(ordered: ordered, now: now) {
            results.append(recovery)
        }
        if let weekly = weeklySleepDebt(ordered: ordered, now: now) {
            results.append(weekly)
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

    private static func sleepDebt(latest: DailyRollupStoreEntry,
                                  now: Date) -> AtriaLearnedInsight? {
        guard let slept = latest.sleepSeconds, slept > 0,
              let need = latest.sleepNeedSeconds, need > 0 else { return nil }
        let deltaHours = hours(need - slept)
        guard abs(deltaHours) >= 0.4 else { return nil }
        let sleptText = hourText(hours(slept))
        let needText = hourText(hours(need))
        if deltaHours > 0 {
            return AtriaLearnedInsight(
                id: "sleep-debt",
                kind: .sleepDebt,
                headline: "Last night was \(hourText(deltaHours)) under your need",
                detail: "You slept \(sleptText) against a \(needText) need. That gap is tonight's first recovery lever.",
                isPositive: false,
                asOf: now
            )
        }
        return AtriaLearnedInsight(
            id: "sleep-surplus",
            kind: .sleepDebt,
            headline: "Last night covered your sleep need",
            detail: "You slept \(sleptText) against a \(needText) need — a real surplus, not a rounded guess.",
            isPositive: true,
            asOf: now
        )
    }

    private static func weeklySleepDebt(ordered: [DailyRollupStoreEntry],
                                        now: Date) -> AtriaLearnedInsight? {
        let window = ordered.prefix(7).compactMap { entry -> Double? in
            guard let slept = entry.sleepSeconds, slept > 0,
                  let need = entry.sleepNeedSeconds, need > 0 else { return nil }
            return hours(need - slept)
        }
        guard window.count >= 4 else { return nil }
        let total = window.reduce(0, +)
        guard total >= 2.5 else { return nil }
        return AtriaLearnedInsight(
            id: "weekly-sleep-debt",
            kind: .weeklySleepDebt,
            headline: "\(hourText(total)) of sleep debt this week",
            detail: "Across \(window.count) measured nights you are still short of your own need. Bank sleep before stacking strain.",
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
                detail: "Signals say back off — \(parts.joined(separator: ", ")). Easy movement is fine; hard strain is not.",
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
        let times = ordered.prefix(7).compactMap(\.bedtimeMinutes)
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
}
