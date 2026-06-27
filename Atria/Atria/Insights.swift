import SwiftUI

/// A personal baseline that LEARNS over time. After each saved session we fold
/// its stable resting HR into an exponential moving average, so "your normal"
/// adapts to you instead of being a fixed guess. Persisted in UserDefaults.
struct PersonalBaseline: Codable {
    var restingHR: Double?      // learned resting baseline (EMA)
    var hrvEMA: Double?         // learned HRV baseline (EMA, ms)
    var sessions: Int = 0
    var updated: Date?
    var samples: [BaselineSample] = []

    private static let alpha = 0.25   // weight on the newest session
    private static let maxSamples = 90
    static let trustedMinimumSamples = 14
    static let staleAfter: TimeInterval = 21 * 24 * 60 * 60

    struct BaselineSample: Codable {
        let date: Date
        let restingHR: Double
        let rmssd: Double?

        var lnRMSSD: Double? {
            guard let rmssd, rmssd > 0 else { return nil }
            return log(rmssd)
        }
    }

    init(restingHR: Double? = nil, hrvEMA: Double? = nil, sessions: Int = 0,
         updated: Date? = nil, samples: [BaselineSample] = []) {
        self.restingHR = restingHR
        self.hrvEMA = hrvEMA
        self.sessions = sessions
        self.updated = updated
        self.samples = samples
    }

    enum CodingKeys: String, CodingKey {
        case restingHR, hrvEMA, sessions, updated, samples
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        restingHR = try c.decodeIfPresent(Double.self, forKey: .restingHR)
        hrvEMA = try c.decodeIfPresent(Double.self, forKey: .hrvEMA)
        sessions = try c.decodeIfPresent(Int.self, forKey: .sessions) ?? 0
        updated = try c.decodeIfPresent(Date.self, forKey: .updated)
        samples = try c.decodeIfPresent([BaselineSample].self, forKey: .samples) ?? []
    }

    mutating func learn(fromResting resting: Int, hrv: Int, at observedAt: Date = Date()) {
        if resting > 0 {
            restingHR = restingHR.map { $0 * (1 - Self.alpha) + Double(resting) * Self.alpha }
                ?? Double(resting)
        }
        if hrv > 0 {
            hrvEMA = hrvEMA.map { $0 * (1 - Self.alpha) + Double(hrv) * Self.alpha }
                ?? Double(hrv)
        }
        sessions += 1
        updated = observedAt
        if resting > 0 {
            samples.append(BaselineSample(date: updated ?? observedAt,
                                          restingHR: Double(resting),
                                          rmssd: hrv > 0 ? Double(hrv) : nil))
            if samples.count > Self.maxSamples {
                samples.removeFirst(samples.count - Self.maxSamples)
            }
        }
    }

    var restingInt: Int? { restingHR.map { Int($0.rounded()) } }
    var hrvInt: Int? { hrvEMA.map { Int($0.rounded()) } }
    var hrvSampleCount: Int { samples.compactMap(\.lnRMSSD).count }
    var restingSampleCount: Int { samples.count }

    func freshSamples(now: Date = Date()) -> [BaselineSample] {
        samples.filter { sample in
            let age = now.timeIntervalSince(sample.date)
            return age >= 0 && age <= Self.staleAfter
        }
    }

    func freshRestingSampleCount(now: Date = Date()) -> Int {
        freshSamples(now: now).count
    }

    func freshHRVSampleCount(now: Date = Date()) -> Int {
        freshSamples(now: now).compactMap(\.lnRMSSD).count
    }

    func isStale(now: Date = Date()) -> Bool {
        guard let updated else { return true }
        return now.timeIntervalSince(updated) > Self.staleAfter
    }

    func hasTrustedRestingBaseline(now: Date = Date()) -> Bool {
        freshRestingSampleCount(now: now) >= Self.trustedMinimumSamples && !isStale(now: now)
    }

    func hasTrustedHRVBaseline(now: Date = Date()) -> Bool {
        freshHRVSampleCount(now: now) >= Self.trustedMinimumSamples && !isStale(now: now)
    }

    var restingStats: (mean: Double, sd: Double, count: Int)? {
        stats(freshSamples().map(\.restingHR))
    }

    var lnRMSSDStats: (mean: Double, sd: Double, count: Int)? {
        stats(freshSamples().compactMap(\.lnRMSSD))
    }

    /// Feedback vs the learned norm: negative = below baseline (more recovered).
    func delta(comparedTo resting: Int) -> Int? {
        guard let base = restingInt else { return nil }
        return resting - base
    }

    private func stats(_ values: [Double]) -> (mean: Double, sd: Double, count: Int)? {
        guard !values.isEmpty else { return nil }
        let mean = values.reduce(0, +) / Double(values.count)
        guard values.count > 1 else { return (mean, 0, values.count) }
        let variance = values.reduce(0) { $0 + pow($1 - mean, 2) } / Double(values.count - 1)
        return (mean, sqrt(variance), values.count)
    }

    // Persistence
    private static let key = "personalBaseline"
    static func load() -> PersonalBaseline {
        guard let data = UserDefaults.standard.data(forKey: key),
              let b = try? JSONDecoder().decode(PersonalBaseline.self, from: data)
        else { return PersonalBaseline() }
        return b
    }
    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}

// MARK: - Athlete profile / onboarding

struct AthleteProfile: Codable, Equatable {
    enum BiologicalSex: String, Codable, CaseIterable, Identifiable {
        case male
        case female
        case unspecified

        var id: String { rawValue }

        var label: String {
            switch self {
            case .male: return "Male"
            case .female: return "Female"
            case .unspecified: return "Unspecified"
            }
        }
    }

    enum HRMaxSource: String, Codable, CaseIterable, Identifiable {
        case ageEstimate
        case measured

        var id: String { rawValue }
        var label: String {
            switch self {
            case .ageEstimate: return "Age"
            case .measured: return "Measured"
            }
        }
    }

    var age: Int
    var measuredMaxHR: Int
    var maxHRSource: HRMaxSource
    var biologicalSex: BiologicalSex
    var weightKg: Double
    var heightCm: Double
    var updated: Date?
    var hasCompletedOnboarding: Bool

    private static let key = "athleteProfile"
    enum CodingKeys: String, CodingKey {
        case age, measuredMaxHR, maxHRSource, biologicalSex, weightKg, heightCm, updated, hasCompletedOnboarding
    }

    static var defaultAge: Int { 30 }
    static var defaultMeasuredMaxHR: Int {
        UserDefaults.standard.object(forKey: "maxHR") as? Int ?? 190
    }

    init(age: Int, measuredMaxHR: Int, maxHRSource: HRMaxSource,
         biologicalSex: BiologicalSex = .unspecified,
         weightKg: Double = 0,
         heightCm: Double = 0,
         updated: Date?, hasCompletedOnboarding: Bool) {
        self.age = age
        self.measuredMaxHR = measuredMaxHR
        self.maxHRSource = maxHRSource
        self.biologicalSex = biologicalSex
        self.weightKg = weightKg
        self.heightCm = heightCm
        self.updated = updated
        self.hasCompletedOnboarding = hasCompletedOnboarding
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        age = try c.decodeIfPresent(Int.self, forKey: .age) ?? Self.defaultAge
        measuredMaxHR = try c.decodeIfPresent(Int.self, forKey: .measuredMaxHR) ?? Self.defaultMeasuredMaxHR
        maxHRSource = try c.decodeIfPresent(HRMaxSource.self, forKey: .maxHRSource) ?? .measured
        biologicalSex = try c.decodeIfPresent(BiologicalSex.self, forKey: .biologicalSex) ?? .unspecified
        weightKg = try c.decodeIfPresent(Double.self, forKey: .weightKg) ?? 0
        heightCm = try c.decodeIfPresent(Double.self, forKey: .heightCm) ?? 0
        updated = try c.decodeIfPresent(Date.self, forKey: .updated)
        hasCompletedOnboarding = try c.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? false
    }

    var ageEstimatedMaxHR: Int {
        Int((208.0 - 0.7 * Double(age)).rounded())
    }

    var maxHR: Int {
        switch maxHRSource {
        case .ageEstimate: return ageEstimatedMaxHR
        case .measured: return measuredMaxHR
        }
    }

    var sourceLabel: String {
        switch maxHRSource {
        case .ageEstimate: return "age estimate"
        case .measured: return "measured"
        }
    }

    var hasEnergyProfile: Bool {
        biologicalSex != .unspecified && weightKg > 0
    }

    static func load() -> AthleteProfile {
        guard let data = UserDefaults.standard.data(forKey: key),
              let p = try? JSONDecoder().decode(AthleteProfile.self, from: data)
        else {
            return AthleteProfile(age: defaultAge,
                                  measuredMaxHR: defaultMeasuredMaxHR,
                                  maxHRSource: .measured,
                                  biologicalSex: .unspecified,
                                  weightKg: 0,
                                  heightCm: 0,
                                  updated: nil,
                                  hasCompletedOnboarding: false)
        }
        return p
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
        UserDefaults.standard.set(maxHR, forKey: "maxHR")
    }

    mutating func clamp() {
        age = min(max(age, 13), 100)
        measuredMaxHR = min(max(measuredMaxHR, 120), 220)
        weightKg = weightKg > 0 ? min(max(weightKg, 30), 250) : 0
        heightCm = heightCm > 0 ? min(max(heightCm, 120), 230) : 0
        updated = Date()
    }

    mutating func completeOnboarding() {
        clamp()
        hasCompletedOnboarding = true
    }
}

// MARK: - Main-screen baseline card

struct BaselineCard: View {
    let baseline: PersonalBaseline
    let currentResting: Int?      // resting of the live session, if any

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Resting baseline", systemImage: "waveform.path.ecg")
                    .font(.headline)
                Spacer()
                if baseline.sessions > 0 {
                    Text("learned from \(baseline.sessions)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(baseline.restingInt.map { "\($0)" } ?? "—")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                Text("bpm").font(.caption).foregroundStyle(.secondary)
                Spacer()
                feedback
            }
        }
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder private var feedback: some View {
        if let cur = currentResting, let d = baseline.delta(comparedTo: cur) {
            let below = d <= 0
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(below ? "↓" : "↑") \(abs(d)) bpm")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(below ? .green : .orange)
                Text(below ? "below your norm" : "above your norm")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        } else if baseline.sessions == 0 {
            Text("finish a session\nto start learning")
                .font(.caption2).multilineTextAlignment(.trailing)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Resting-HR trend across sessions

import Charts

struct RestingTrendPoint: Identifiable {
    let id: UUID
    let start: Date
    let resting: Int
}

struct RestingTrendChart: View {
    let points: [RestingTrendPoint]
    let baseline: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Resting HR trend").font(.headline)
            if points.count < 2 {
                Text("Save at least two sessions to see your trend.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Chart {
                    ForEach(points) { point in
                        LineMark(x: .value("Date", point.start),
                                 y: .value("Resting", point.resting))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(.teal)
                        PointMark(x: .value("Date", point.start),
                                  y: .value("Resting", point.resting))
                            .foregroundStyle(.teal)
                    }
                    if let b = baseline {
                        RuleMark(y: .value("Baseline", b))
                            .lineStyle(.init(lineWidth: 1, dash: [4, 4]))
                            .foregroundStyle(.secondary)
                            .annotation(position: .top, alignment: .leading) {
                                Text("baseline \(b)").font(.caption2).foregroundStyle(.secondary)
                            }
                    }
                }
                .frame(height: 160)
            }
        }
    }
}

// MARK: - Session time-in-zone breakdown

struct TimeInZoneRow: Identifiable {
    let zone: HRZone
    let seconds: Double

    var id: Int { zone.rawValue }
}

struct TimeInZoneView: View {
    let rows: [TimeInZoneRow]
    let total: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Time in zone").font(.headline)
            ForEach(rows) { row in
                HStack(spacing: 8) {
                    Text(row.zone.name)
                        .font(.caption).frame(width: 78, alignment: .leading)
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(row.zone.color.gradient)
                            .frame(width: geo.size.width * row.seconds / total)
                    }
                    .frame(height: 14)
                    Text(fmt(row.seconds))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 52, alignment: .trailing)
                }
            }
        }
    }

    private func fmt(_ s: Double) -> String {
        let i = Int(s)
        return i >= 60 ? "\(i/60)m \(i%60)s" : "\(i)s"
    }
}
