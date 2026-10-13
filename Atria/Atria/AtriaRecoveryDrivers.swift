import SwiftUI

/// The "why" under today's recovery number: how each input sits against the
/// wearer's own 28-day baseline (W3.1). It explains the existing score; it is
/// not a new score. A driver appears only when today has the value and the
/// baseline has at least `minimumBaselineDays` days of it (personal baseline,
/// n = 1 — never population constants).
enum AtriaRecoveryDrivers {
    enum Kind: String, CaseIterable, Sendable {
        case hrv, restingHeartRate, sleep, bedtime, strain

        var label: String {
            switch self {
            case .hrv: return "HRV"
            case .restingHeartRate: return "RHR"
            case .sleep: return "Sleep"
            case .bedtime: return "Bedtime"
            case .strain: return "Strain"
            }
        }
    }

    struct Driver: Identifiable, Equatable, Sendable {
        let kind: Kind
        /// Today minus the 28-day baseline, in display units
        /// (ms, bpm, hours, minutes, strain points).
        let delta: Double
        /// `delta` measured in the kind's "meaningful change" step, for ranking.
        let magnitude: Double
        /// nil when the direction is neither good nor bad (on-baseline).
        let favourable: Bool?

        var id: String { kind.rawValue }

        var arrow: String {
            if magnitude < 1 { return "equal" }
            return delta > 0 ? "arrow.up" : "arrow.down"
        }

        var valueText: String {
            switch kind {
            case .hrv: return String(format: "%+.0f ms", delta)
            case .restingHeartRate: return String(format: "%+.0f", delta)
            case .sleep:
                let minutes = Int((delta * 60).rounded())
                return minutes >= 0 ? "+\(minutes)m" : "\(minutes)m"
            case .bedtime:
                let minutes = Int(delta.rounded())
                return minutes == 0 ? "on time" : (minutes > 0 ? "\(minutes)m late" : "\(-minutes)m early")
            case .strain: return String(format: "%+.1f", delta)
            }
        }
    }

    static let baselineDays = 28
    static let minimumBaselineDays = 7

    /// One "meaningful change" step per kind; below one step reads as level.
    static func step(_ kind: Kind) -> Double {
        switch kind {
        case .hrv: return 5
        case .restingHeartRate: return 2
        case .sleep: return 0.5
        case .bedtime: return 30
        case .strain: return 2
        }
    }

    /// Drivers for the morning of `now`, most notable first.
    static func make(rollups: [DailyRollupStoreEntry],
                     now: Date,
                     calendar: Calendar = .current) -> [Driver] {
        let today = calendar.startOfDay(for: now)
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
              let windowStart = calendar.date(byAdding: .day, value: -baselineDays, to: today)
        else { return [] }
        var byDay: [Date: DailyRollupStoreEntry] = [:]
        for entry in rollups {
            let day = calendar.startOfDay(for: entry.day)
            if day >= windowStart && day <= today { byDay[day] = entry }
        }
        var drivers: [Driver] = []
        for kind in Kind.allCases {
            // Strain is yesterday's load against the baseline before it.
            let subjectDay = kind == .strain ? yesterday : today
            guard let subject = byDay[subjectDay].flatMap({ value(kind, $0) }) else { continue }
            let baseline = byDay.compactMap { day, entry -> Double? in
                day < subjectDay ? value(kind, entry) : nil
            }
            guard baseline.count >= minimumBaselineDays else { continue }
            let mean = kind == .bedtime
                ? circularMeanMinutes(baseline)
                : baseline.reduce(0, +) / Double(baseline.count)
            let delta = kind == .bedtime ? wrappedMinutes(subject - mean) : subject - mean
            let magnitude = abs(delta) / step(kind)
            drivers.append(Driver(kind: kind,
                                  delta: delta,
                                  magnitude: magnitude,
                                  favourable: magnitude < 1 ? nil : favourable(kind, delta: delta)))
        }
        return drivers.sorted { $0.magnitude > $1.magnitude }
    }

    static func value(_ kind: Kind, _ entry: DailyRollupStoreEntry) -> Double? {
        switch kind {
        case .hrv: return entry.lnRMSSD.flatMap { $0.isFinite ? exp($0) : nil }
        case .restingHeartRate: return entry.rhr.flatMap { $0 > 0 ? Double($0) : nil }
        case .sleep: return entry.sleepSeconds.flatMap { $0 > 0 ? $0 / 3600 : nil }
        case .bedtime: return entry.bedtimeMinutes.map(Double.init)
        case .strain: return entry.strain.flatMap { $0 >= 0 ? $0 : nil }
        }
    }

    /// Higher HRV and more sleep help recovery; higher resting HR, a later
    /// bedtime than usual and a harder day than usual weigh on it.
    static func favourable(_ kind: Kind, delta: Double) -> Bool {
        switch kind {
        case .hrv, .sleep: return delta > 0
        case .restingHeartRate, .bedtime, .strain: return delta < 0
        }
    }

    /// Bedtimes wrap at midnight (the owner sleeps ~13:00–19:00 IST), so the
    /// baseline is a circular mean over the 24 h clock, not an arithmetic one.
    static func circularMeanMinutes(_ minutes: [Double]) -> Double {
        let radians = minutes.map { $0 / 1440 * 2 * .pi }
        let x = radians.map(cos).reduce(0, +)
        let y = radians.map(sin).reduce(0, +)
        var angle = atan2(y, x)
        if angle < 0 { angle += 2 * .pi }
        return angle / (2 * .pi) * 1440
    }

    static func wrappedMinutes(_ minutes: Double) -> Double {
        var value = minutes.truncatingRemainder(dividingBy: 1440)
        if value > 720 { value -= 1440 }
        if value < -720 { value += 1440 }
        return value
    }
}

/// One line under the Today rings: the three most notable drivers with an
/// arrow, coloured only by whether the deviation helps or weighs on recovery.
/// Taps open the existing recovery detail (its contributor map is the
/// provenance card).
struct AtriaRecoveryDriversStrip: View, Equatable {
    let drivers: [AtriaRecoveryDrivers.Driver]
    let onOpen: () -> Void

    static let maximumVisible = 3

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.drivers == rhs.drivers }

    var body: some View {
        let visible = Array(drivers.prefix(Self.maximumVisible))
        Button(action: onOpen) {
            HStack(spacing: 14) {
                ForEach(visible) { driver in
                    HStack(spacing: 3) {
                        Text(driver.kind.label)
                            .foregroundStyle(.secondary)
                        Image(systemName: driver.arrow)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(tint(driver))
                        Text(driver.valueText)
                            .monospacedDigit()
                            .foregroundStyle(.primary)
                    }
                    .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .font(.caption.weight(.semibold))
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(visible))
        .accessibilityHint("Opens what shaped today's recovery")
    }

    private func tint(_ driver: AtriaRecoveryDrivers.Driver) -> Color {
        switch driver.favourable {
        case .some(true): return Metrics.electricGreen
        case .some(false): return Metrics.electricRed
        case .none: return .secondary
        }
    }

    private func accessibilityText(_ visible: [AtriaRecoveryDrivers.Driver]) -> String {
        "Versus your 28-day baseline: " + visible.map { "\($0.kind.label) \($0.valueText)" }
            .joined(separator: ", ")
    }
}
