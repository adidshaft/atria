import Foundation

/// Opt-in menstrual cycle tracking (v1).
///
/// Self-contained by design: its own JSON file in Documents
/// (`atria-cycle-tracking.json`), never touches `Sessions.swift`, and is not
/// referenced anywhere in `AtriaResearchBundle.swift`. That file's bundle is
/// built from an explicit ALLOWLIST schema (`AtriaResearchBundlePayload`) —
/// a field not modeled there cannot leak into a research bundle by
/// construction, so this store is excluded automatically with no extra work.
///
/// Default OFF. This is sensitive personal health data; the user opts in
/// explicitly from the Journal tab's Cycle card, never silently.
///
/// Honesty rules: phase is always an ESTIMATE, never presented as a diagnosed
/// fact. With fewer than two completed cycles logged there is no personal
/// cycle-length data yet, so estimation falls back to calendar-average phase
/// lengths and is labeled "estimating"; with two or more, boundaries use the
/// user's own median cycle length and are labeled "personalized" — still an
/// estimate, just a better-informed one.
enum AtriaCycleTracking {
    static let enabledKey = "atria.cycleTracking.enabled"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: enabledKey)
        AtriaDebugLog("ATRIADBG cycle_tracking status=%@", enabled ? "enabled" : "disabled")
        if !enabled {
            // Disabling stops new phase estimates from surfacing anywhere
            // (Journal card, AI coach) but deliberately does NOT delete the
            // logged dates — re-enabling should not lose history the user
            // already trusted this phone with.
        }
    }

    /// One phase-aware line for the AI coach (`AtriaAICoach.swift`), or nil
    /// when tracking is off or no period has ever been logged. Always
    /// prefixed "Cycle estimate" per the honesty rules — never phrased as a
    /// diagnosed fact.
    static func coachGuidanceLine(now: Date = Date()) -> String? {
        guard isEnabled else { return nil }
        let store = AtriaCycleTrackingStore()
        guard let estimate = store.currentEstimate(now: now) else { return nil }
        let tierNote = estimate.confidence == .estimating ? " (calendar estimate, not yet personalized)" : ""
        return "Cycle estimate: day \(estimate.cycleDay), \(estimate.phase.title.lowercased()) phase\(tierNote) — \(estimate.phase.coachNote)"
    }
}

/// One logged period. `end` is nil while the period is ongoing.
struct AtriaCyclePeriodEntry: Codable, Equatable, Identifiable {
    var start: Date
    var end: Date?

    var id: TimeInterval { start.timeIntervalSince1970 }
}

enum AtriaCyclePhase: String, Codable, CaseIterable, Equatable {
    case menstrual
    case follicular
    case ovulatory
    case luteal

    var title: String {
        switch self {
        case .menstrual: return "Menstrual"
        case .follicular: return "Follicular"
        case .ovulatory: return "Ovulatory"
        case .luteal: return "Luteal"
        }
    }

    var symbolName: String {
        switch self {
        case .menstrual: return "drop.fill"
        case .follicular: return "leaf.fill"
        case .ovulatory: return "circle.hexagongrid.fill"
        case .luteal: return "moon.fill"
        }
    }

    /// Short, honest note used both in the Journal card and appended to the
    /// AI coach's guidance — physiological context, not a diagnosis.
    var coachNote: String {
        switch self {
        case .menstrual:
            return "energy and RHR can run lower; an easier day is a normal response, not a bad recovery."
        case .follicular:
            return "recovery capacity tends to trend upward through this window."
        case .ovulatory:
            return "small HRV/RHR dips around ovulation are common and don't necessarily mean under-recovery."
        case .luteal:
            return "RHR and temperature typically run a little higher and recovery scores can read lower for physiological reasons, not just training load."
        }
    }
}

/// Estimation confidence tier — the honesty-rules label shown alongside any
/// phase estimate. Never silently upgraded past what the logged data supports.
enum AtriaCycleConfidence: String, Codable, Equatable {
    /// Fewer than 2 completed cycles logged: calendar-default phase lengths
    /// only, no personal cycle-length data yet.
    case estimating
    /// >=2 completed cycles: phase boundaries use the user's own median
    /// cycle length. Still an estimate — cycles vary — just better-informed.
    case personalized
}

struct AtriaCycleEstimate: Equatable {
    let phase: AtriaCyclePhase
    /// 1-based day within the current (estimated) cycle.
    let cycleDay: Int
    let confidence: AtriaCycleConfidence
}

/// One JSON file in Documents, entirely separate from `Sessions.swift` and
/// the research-bundle allowlist. Entries are tiny (a handful of dates a
/// year) — loads eagerly, saves on every mutation.
final class AtriaCycleTrackingStore: ObservableObject {
    static let fileName = "atria-cycle-tracking.json"

    @Published private(set) var entries: [AtriaCyclePeriodEntry] = []
    private var loaded = false
    private let url: URL

    init(directory: URL? = nil) {
        let base = directory
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        url = base.appendingPathComponent(Self.fileName)
        loadIfNeeded()
    }

    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder.atriaCycle.decode([AtriaCyclePeriodEntry].self, from: data) else {
            return
        }
        entries = decoded.sorted { $0.start < $1.start }
    }

    var completedCycleCount: Int {
        loadIfNeeded()
        return max(0, entries.count - 1)
    }

    var mostRecentPeriodEnd: Date? {
        loadIfNeeded()
        return entries.last?.end
    }

    var isPeriodOngoing: Bool {
        loadIfNeeded()
        return entries.last?.end == nil
    }

    /// Logs a new period start. If the previous period was never explicitly
    /// ended, it is closed at its own start date (a single logged day)
    /// rather than left open indefinitely — an open-ended entry would
    /// otherwise poison cycle-length math forever.
    @discardableResult
    func logPeriodStart(_ date: Date = Date(), calendar: Calendar = .current) -> AtriaCyclePeriodEntry {
        loadIfNeeded()
        let day = calendar.startOfDay(for: date)
        if let lastIndex = entries.indices.last, entries[lastIndex].end == nil, entries[lastIndex].start < day {
            entries[lastIndex].end = entries[lastIndex].start
        }
        entries.removeAll { calendar.startOfDay(for: $0.start) == day }
        entries.append(AtriaCyclePeriodEntry(start: day, end: nil))
        entries.sort { $0.start < $1.start }
        persist()
        AtriaDebugLog("ATRIADBG cycle_tracking status=period_start entries=%d", entries.count)
        return entries.last!
    }

    /// Ends the most recent (ongoing) period. Does nothing if there is no
    /// ongoing period to close.
    func logPeriodEnd(_ date: Date = Date(), calendar: Calendar = .current) {
        loadIfNeeded()
        guard let lastIndex = entries.indices.last, entries[lastIndex].end == nil else { return }
        let day = calendar.startOfDay(for: date)
        entries[lastIndex].end = max(day, entries[lastIndex].start)
        persist()
        AtriaDebugLog("ATRIADBG cycle_tracking status=period_end")
    }

    func deleteEntry(_ entry: AtriaCyclePeriodEntry) {
        loadIfNeeded()
        entries.removeAll { $0.id == entry.id }
        persist()
    }

    /// Deletes all logged dates. Used from the disable affordance's "also
    /// clear logged dates" path — tracking itself can be turned off without
    /// this (see `AtriaCycleTracking.setEnabled`).
    func deleteAll() {
        loadIfNeeded()
        entries.removeAll()
        persist()
        AtriaDebugLog("ATRIADBG cycle_tracking status=history_cleared")
    }

    private func persist() {
        guard let data = try? JSONEncoder.atriaCycle.encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Phase estimation

    private static let calendarDefaultCycleLength = 28
    private static let calendarDefaultPeriodLength = 5
    private static let lutealPhaseLength = 14 // relatively fixed post-ovulation, independent of cycle length
    private static let minCyclesForPersonalization = 2

    /// Median length (days) between successive logged period starts. nil
    /// until at least `minCyclesForPersonalization` completed gaps exist.
    var medianCycleLengthDays: Int? {
        loadIfNeeded()
        let starts = entries.map(\.start).sorted()
        guard starts.count >= Self.minCyclesForPersonalization + 1 else { return nil }
        var gaps: [Int] = []
        for index in 1..<starts.count {
            let days = Calendar.current.dateComponents([.day], from: starts[index - 1], to: starts[index]).day ?? 0
            if days > 0 { gaps.append(days) }
        }
        guard gaps.count >= Self.minCyclesForPersonalization else { return nil }
        let sorted = gaps.sorted()
        let median = sorted[sorted.count / 2]
        // A too-short/long median (bad data, missed logs) would misestimate
        // every phase boundary — fall back to the calendar default instead.
        guard (15...60).contains(median) else { return nil }
        return median
    }

    /// Median logged period length (days), when enough completed periods
    /// exist; the calendar default otherwise.
    private var medianPeriodLengthDays: Int {
        loadIfNeeded()
        let lengths = entries.compactMap { entry -> Int? in
            guard let end = entry.end else { return nil }
            let days = Calendar.current.dateComponents([.day], from: entry.start, to: end).day ?? 0
            return days + 1
        }
        guard lengths.count >= Self.minCyclesForPersonalization else { return Self.calendarDefaultPeriodLength }
        let sorted = lengths.sorted()
        return sorted[sorted.count / 2]
    }

    /// Current phase estimate, or nil when no period has ever been logged.
    func currentEstimate(now: Date = Date(), calendar: Calendar = .current) -> AtriaCycleEstimate? {
        loadIfNeeded()
        guard let last = entries.last else { return nil }
        let today = calendar.startOfDay(for: now)
        let daysSinceStart = calendar.dateComponents([.day], from: last.start, to: today).day ?? 0
        guard daysSinceStart >= 0 else { return nil }

        let personalizedLength = medianCycleLengthDays
        let cycleLength = personalizedLength ?? Self.calendarDefaultCycleLength
        let confidence: AtriaCycleConfidence = personalizedLength != nil ? .personalized : .estimating
        let periodLength = min(medianPeriodLengthDays, cycleLength - 1)

        // Wrap into the current cycle if the last logged start is stale
        // (a period was skipped or simply not logged) — never claim a cycle
        // day beyond one full cycle length.
        let wrappedDay = (daysSinceStart % cycleLength) + 1
        let ovulationDay = max(periodLength + 1, cycleLength - Self.lutealPhaseLength)

        let phase: AtriaCyclePhase
        if wrappedDay <= periodLength {
            phase = .menstrual
        } else if wrappedDay < ovulationDay - 1 {
            phase = .follicular
        } else if wrappedDay <= ovulationDay + 1 {
            phase = .ovulatory
        } else {
            phase = .luteal
        }

        return AtriaCycleEstimate(phase: phase, cycleDay: wrappedDay, confidence: confidence)
    }

    /// Phase estimate for a PAST day, or nil when the day can't honestly be
    /// classified: before the first logged period, or beyond one median
    /// cycle length after its anchoring period start (unlike
    /// `currentEstimate`, history never wraps — an unlogged stretch stays
    /// unclassified rather than guessed).
    func phaseEstimate(on day: Date, calendar: Calendar = .current) -> AtriaCyclePhase? {
        loadIfNeeded()
        let target = calendar.startOfDay(for: day)
        guard let anchor = entries.last(where: { calendar.startOfDay(for: $0.start) <= target }) else { return nil }
        let cycleLength = medianCycleLengthDays ?? Self.calendarDefaultCycleLength
        let periodLength = min(medianPeriodLengthDays, cycleLength - 1)
        let dayIndex = (calendar.dateComponents([.day], from: calendar.startOfDay(for: anchor.start), to: target).day ?? 0) + 1
        guard dayIndex >= 1, dayIndex <= cycleLength else { return nil }
        let ovulationDay = max(periodLength + 1, cycleLength - Self.lutealPhaseLength)
        if dayIndex <= periodLength { return .menstrual }
        if dayIndex < ovulationDay - 1 { return .follicular }
        if dayIndex <= ovulationDay + 1 { return .ovulatory }
        return .luteal
    }

    /// Average recovery per phase over the trailing 90 days. Only rendered
    /// once the estimate is personalized (>=2 completed cycles) and only for
    /// phases with at least `minimumDaysPerPhase` classified recovery days.
    static let minimumDaysPerPhase = 3

    func recoveryPatternsByPhase(days: [(day: Date, recovery: Int?)],
                                 now: Date = Date(),
                                 calendar: Calendar = .current) -> [(phase: AtriaCyclePhase, averageRecovery: Int, dayCount: Int)] {
        loadIfNeeded()
        guard completedCycleCount >= 2 else { return [] }
        let windowStart = calendar.date(byAdding: .day, value: -90, to: calendar.startOfDay(for: now))
            ?? calendar.startOfDay(for: now)
        var buckets: [AtriaCyclePhase: [Int]] = [:]
        for entry in days {
            guard let recovery = entry.recovery,
                  entry.day >= windowStart,
                  let phase = phaseEstimate(on: entry.day, calendar: calendar) else { continue }
            buckets[phase, default: []].append(recovery)
        }
        return AtriaCyclePhase.allCases.compactMap { phase in
            guard let values = buckets[phase], values.count >= Self.minimumDaysPerPhase else { return nil }
            return (phase: phase, averageRecovery: values.reduce(0, +) / values.count, dayCount: values.count)
        }
    }
}

extension JSONEncoder {
    static var atriaCycle: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var atriaCycle: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
