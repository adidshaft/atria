import Foundation

/// Per-night summary + personal baseline comparisons ("ups and downs",
/// "unusual for you") built on `AtriaNightTimelineAnalyzer`.
///
/// Population rule: every comparison is against the SAME person's own recent
/// nights (robust median / MAD), never a fixed population norm. Flags need both
/// a statistical departure (|z| over the person's own spread) and a minimum
/// absolute effect size, so sensor noise never becomes an alarm. No medical
/// claims: output says "unusual for you", never a diagnosis. Clock times use
/// circular statistics so bedtimes crossing midnight and afternoon sleepers are
/// handled (the noon-anchor split defect of the old consistency metric).
struct AtriaNightSummary: Equatable, Codable, Sendable {
    var night: Date                 // onset
    var onset: Date
    var wake: Date
    var asleepMinutes: Double       // onset→wake minus up/restless/not-worn episodes
    var disturbedMinutes: Double
    var interruptions: Int
    var ups: Int
    var sleepingHeartRate: Double?
    var sleepingRMSSD: Double?
    /// Fraction of onset→wake minutes with any data (live or history).
    var coverage: Double

    static func from(_ result: AtriaNightTimelineAnalyzer.Result,
                     minutes: [AtriaNightTimelineAnalyzer.Minute]) -> AtriaNightSummary? {
        guard let onset = result.onset, let wake = result.wake, wake > onset else { return nil }
        let window = wake.timeIntervalSince(onset) / 60
        let disturbing: Set<AtriaNightTimelineAnalyzer.Kind> = [.restless, .up, .notWorn]
        let inWindow = result.episodes.filter { disturbing.contains($0.kind) && $0.start >= onset && $0.end <= wake }
        let disturbed = inWindow.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) / 60 }
        let windowIndices = minutes.indices.filter { minutes[$0].start >= onset && minutes[$0].start < wake }
        let expected = max(1, Int(window.rounded()))
        let covered = windowIndices.filter { minutes[$0].heartRate != nil || minutes[$0].motion != nil }.count
        let restingRR = windowIndices
            .filter { result.states.indices.contains($0) && [.still, .unknownMotion].contains(result.states[$0]) }
            .flatMap { minutes[$0].rrIntervals }
        return AtriaNightSummary(
            night: onset, onset: onset, wake: wake,
            asleepMinutes: max(0, window - disturbed), disturbedMinutes: disturbed,
            interruptions: inWindow.filter { $0.kind != .notWorn }.count,
            ups: inWindow.filter { $0.kind == .up }.count,
            sleepingHeartRate: result.sleepingHeartRate,
            sleepingRMSSD: AtriaNightTimelineAnalyzer.rmssd(restingRR),
            coverage: min(1, Double(covered) / Double(expected)))
    }
}

enum AtriaNightBaseline {
    enum Metric: String, CaseIterable, Codable, Sendable {
        case bedtime, wakeTime, asleep, disturbed, sleepingHeartRate, sleepingHRV
    }

    enum Direction: String, Codable, Sendable { case higher, lower, earlier, later, typical }
    enum Severity: String, Codable, Sendable { case typical, notable, unusual }

    struct Comparison: Equatable, Sendable {
        var metric: Metric
        var value: Double
        var usual: Double
        var delta: Double          // value - usual (minutes for times; units otherwise)
        var direction: Direction
        var severity: Severity
        var sentence: String
    }

    enum Outcome: Equatable, Sendable {
        /// Fewer than `minimumNights` qualifying nights.
        case learning(nightsCollected: Int, nightsNeeded: Int)
        case compared([Comparison])
    }

    static let minimumNights = 5
    static let maximumNights = 28
    static let minimumCoverage = 0.8
    static let notableZ = 1.0
    static let unusualZ = 2.5

    /// Spread floor (avoid over-sensitivity for very consistent people) and
    /// minimum absolute effect for a flag, per metric. Generic physiology, not
    /// tuned to any individual.
    static func spreadFloor(_ m: Metric) -> Double {
        switch m {
        case .bedtime, .wakeTime: return 20       // minutes
        case .asleep, .disturbed: return 20       // minutes
        case .sleepingHeartRate: return 1.5       // bpm
        case .sleepingHRV: return 5               // ms
        }
    }

    static func minimumEffect(_ m: Metric) -> Double {
        switch m {
        case .bedtime, .wakeTime: return 45
        case .asleep: return 30
        case .disturbed: return 20
        case .sleepingHeartRate: return 4
        case .sleepingHRV: return 10
        }
    }

    static func compare(tonight: AtriaNightSummary, history: [AtriaNightSummary]) -> Outcome {
        let prior = history
            .filter { $0.coverage >= minimumCoverage && $0.night < tonight.night }
            .sorted { $0.night > $1.night }
            .prefix(maximumNights)
        guard prior.count >= minimumNights else {
            return .learning(nightsCollected: prior.count, nightsNeeded: minimumNights)
        }
        var out: [Comparison] = []
        for metric in Metric.allCases {
            if let c = comparison(metric, tonight: tonight, prior: Array(prior)) { out.append(c) }
        }
        return .compared(out)
    }

    // MARK: Internals

    private static func comparison(_ metric: Metric, tonight: AtriaNightSummary,
                                   prior: [AtriaNightSummary]) -> Comparison? {
        let value: Double
        let usual: Double
        let spread: Double
        switch metric {
        case .bedtime, .wakeTime:
            let pick: (AtriaNightSummary) -> Date = metric == .bedtime ? { $0.onset } : { $0.wake }
            let minutes = prior.map { clockMinutes(pick($0)) }
            value = clockMinutes(pick(tonight))
            usual = circularMean(minutes)
            spread = circularMAD(minutes, center: usual)
        default:
            let pick: (AtriaNightSummary) -> Double? = {
                switch metric {
                case .asleep: return $0.asleepMinutes
                case .disturbed: return $0.disturbedMinutes
                case .sleepingHeartRate: return $0.sleepingHeartRate
                case .sleepingHRV: return $0.sleepingRMSSD
                default: return nil
                }
            }
            guard let v = pick(tonight) else { return nil }
            let values = prior.compactMap(pick)
            guard values.count >= minimumNights else { return nil }
            value = v
            usual = median(values)
            spread = 1.4826 * median(values.map { abs($0 - usual) })
        }
        let delta = [.bedtime, .wakeTime].contains(metric) ? circularDelta(value, usual) : value - usual
        let z = delta / max(spread, spreadFloor(metric))
        let meaningful = abs(delta) >= minimumEffect(metric)
        let severity: Severity = meaningful && abs(z) >= unusualZ ? .unusual
            : meaningful && abs(z) >= notableZ ? .notable : .typical
        let direction: Direction
        if severity == .typical {
            direction = .typical
        } else if [.bedtime, .wakeTime].contains(metric) {
            direction = delta > 0 ? .later : .earlier
        } else {
            direction = delta > 0 ? .higher : .lower
        }
        return Comparison(metric: metric, value: value, usual: usual, delta: delta,
                          direction: direction, severity: severity,
                          sentence: sentence(metric, value: value, usual: usual, delta: delta,
                                             direction: direction, severity: severity))
    }

    static func sentence(_ m: Metric, value: Double, usual: Double, delta: Double,
                         direction: Direction, severity: Severity) -> String {
        func clock(_ minutes: Double) -> String {
            let total = (Int(minutes.rounded()) % 1_440 + 1_440) % 1_440
            return String(format: "%02d:%02d", total / 60, total % 60)
        }
        func duration(_ minutes: Double) -> String {
            let m = Int(abs(minutes).rounded())
            return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m) min"
        }
        // 2026-09-24: no "unusually" mid-sentence ("6 unusually lower than
        // usual" read badly); severity still orders the lines on screen.
        let qualifier = ""
        switch m {
        case .bedtime:
            return severity == .typical ? "Fell asleep \(clock(value)), around your usual time."
                : "Fell asleep \(clock(value)), \(duration(delta)) \(qualifier)\(direction == .later ? "later" : "earlier") than usual."
        case .wakeTime:
            return severity == .typical ? "Woke \(clock(value)), around your usual time."
                : "Woke \(clock(value)), \(duration(delta)) \(qualifier)\(direction == .later ? "later" : "earlier") than usual."
        case .asleep:
            return severity == .typical ? "Slept \(duration(value)), typical for you."
                : "Slept \(duration(value)), \(duration(delta)) \(qualifier)\(direction == .higher ? "more" : "less") than usual."
        case .disturbed:
            return severity == .typical ? "Restless or up for \(duration(value)), typical for you."
                : "Restless or up for \(duration(value)), \(qualifier)\(direction == .higher ? "more" : "less") than usual (\(duration(usual)))."
        case .sleepingHeartRate:
            return severity == .typical ? "Sleeping heart rate \(Int(value.rounded())) bpm, typical for you."
                : "Sleeping heart rate \(Int(value.rounded())) bpm, \(Int(abs(delta).rounded())) \(qualifier)\(direction == .higher ? "higher" : "lower") than usual."
        case .sleepingHRV:
            return severity == .typical ? "Sleeping HRV \(Int(value.rounded())) ms, typical for you."
                : "Sleeping HRV \(Int(value.rounded())) ms, \(qualifier)\(direction == .higher ? "higher" : "lower") than usual (\(Int(usual.rounded())))."
        }
    }

    static func clockMinutes(_ date: Date, calendar: Calendar = .current) -> Double {
        let c = calendar.dateComponents([.hour, .minute, .second], from: date)
        return Double((c.hour ?? 0) * 60 + (c.minute ?? 0)) + Double(c.second ?? 0) / 60
    }

    /// Smallest signed difference a − b on a 24 h clock, in minutes.
    static func circularDelta(_ a: Double, _ b: Double) -> Double {
        var d = (a - b).truncatingRemainder(dividingBy: 1_440)
        if d > 720 { d -= 1_440 }
        if d < -720 { d += 1_440 }
        return d
    }

    static func circularMean(_ minutes: [Double]) -> Double {
        let angles = minutes.map { $0 / 1_440 * 2 * .pi }
        let s = angles.reduce(0) { $0 + sin($1) }, c = angles.reduce(0) { $0 + cos($1) }
        var mean = atan2(s, c) / (2 * .pi) * 1_440
        if mean < 0 { mean += 1_440 }
        return mean >= 1_440 - 1e-9 ? 0 : mean
    }

    static func circularMAD(_ minutes: [Double], center: Double) -> Double {
        1.4826 * median(minutes.map { abs(circularDelta($0, center)) })
    }

    static func median(_ values: [Double]) -> Double {
        let s = values.sorted()
        guard !s.isEmpty else { return 0 }
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
}
