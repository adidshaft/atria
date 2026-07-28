import SwiftUI

/// A personal baseline that LEARNS over time. After each saved session we fold
/// its stable resting HR into an exponential moving average, so "your normal"
/// adapts to you instead of being a fixed guess. Persisted in UserDefaults.
struct PersonalBaseline: Codable {
    /// Version 1 means every HRV-bearing sample was admitted only from
    /// qualified standard 2A37 RR inside a confirmed main-sleep window.
    /// Older persisted baselines used a clock-only "overnight" heuristic and
    /// must fail closed until SessionStore rebuilds them from durable evidence.
    static let currentHRVQualificationVersion = 1

    var restingHR: Double?      // learned resting baseline (EMA)
    var hrvEMA: Double?         // learned HRV baseline (EMA, ms)
    var sessions: Int = 0
    var updated: Date?
    var samples: [BaselineSample] = []
    var hrvQualificationVersion: Int = Self.currentHRVQualificationVersion

    private static let alpha = 0.1    // weight on the newest session
    /// One anomalous night must not yank "your normal": per-sample EMA movement
    /// is bounded in addition to the alpha weighting.
    private static let maxRestingStepBPM = 2.0
    private static let maxHRVStepMS = 6.0
    private static let maxSamples = 90
    static let trustedMinimumSamples = 14
    static let staleAfter: TimeInterval = 21 * 24 * 60 * 60
    /// Once this many fresh OVERNIGHT HRV samples exist, the lnRMSSD baseline is
    /// computed from overnight samples only (WHOOP-like sleep-window HRV). Below it,
    /// we fall back to all samples so an intermittent overnight stream never starves
    /// the baseline.
    static let overnightHRVPreferenceMinimum = 7

    struct BaselineSample: Codable {
        let date: Date
        let restingHR: Double
        let rmssd: Double?
        /// Version-1 semantics: true only when this sample's qualified standard
        /// 2A37 RR came from inside a confirmed main-sleep window. The optional
        /// representation keeps old payloads decodable, but version-0 values are
        /// never trusted as confirmed-sleep evidence.
        var overnight: Bool?

        var lnRMSSD: Double? {
            guard let rmssd, rmssd > 0 else { return nil }
            return log(rmssd)
        }

        var isOvernightSample: Bool { overnight == true }
    }

    init(restingHR: Double? = nil, hrvEMA: Double? = nil, sessions: Int = 0,
         updated: Date? = nil, samples: [BaselineSample] = [],
         hrvQualificationVersion: Int = Self.currentHRVQualificationVersion) {
        self.restingHR = restingHR
        self.hrvEMA = hrvEMA
        self.sessions = sessions
        self.updated = updated
        self.samples = samples
        self.hrvQualificationVersion = hrvQualificationVersion
    }

    enum CodingKeys: String, CodingKey {
        case restingHR, hrvEMA, sessions, updated, samples, hrvQualificationVersion
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        restingHR = try c.decodeIfPresent(Double.self, forKey: .restingHR)
        let decodedQualificationVersion = try c.decodeIfPresent(Int.self,
                                                                 forKey: .hrvQualificationVersion) ?? 0
        hrvQualificationVersion = decodedQualificationVersion
        hrvEMA = decodedQualificationVersion >= Self.currentHRVQualificationVersion
            ? try c.decodeIfPresent(Double.self, forKey: .hrvEMA)
            : nil
        sessions = try c.decodeIfPresent(Int.self, forKey: .sessions) ?? 0
        updated = try c.decodeIfPresent(Date.self, forKey: .updated)
        let decodedSamples = try c.decodeIfPresent([BaselineSample].self, forKey: .samples) ?? []
        if decodedQualificationVersion >= Self.currentHRVQualificationVersion {
            samples = decodedSamples
        } else {
            // Retain trustworthy resting-HR history, but strip HRV whose old
            // clock-only provenance cannot prove confirmed main sleep.
            samples = decodedSamples.map {
                BaselineSample(date: $0.date,
                               restingHR: $0.restingHR,
                               rmssd: nil,
                               overnight: false)
            }
        }
    }

    mutating func learn(fromResting resting: Int, hrv: Int, at observedAt: Date = Date(), overnight: Bool = false) {
        sessions += 1
        updated = observedAt
        if resting > 0 {
            samples.append(BaselineSample(date: observedAt,
                                          restingHR: Double(resting),
                                          rmssd: hrv > 0 ? Double(hrv) : nil,
                                          overnight: overnight))
            // Reconnects and segmented saves can produce several qualified
            // windows on one civil day. A personal baseline is a day-level
            // signal, so those fragments must not receive extra statistical or
            // EMA weight. Confirmed-sleep evidence wins over daytime evidence;
            // within one evidence class the lowest qualified resting window is
            // the canonical observation.
            samples = Self.canonicalDailySamples(samples)
            if samples.count > Self.maxSamples {
                samples.removeFirst(samples.count - Self.maxSamples)
            }
            rebuildLearnedValuesFromCanonicalSamples()
        } else if hrv > 0 {
            // HRV without a paired qualified resting observation has no durable
            // day anchor and must not silently bias the baseline.
            hrvEMA = Self.ema(values: samples.compactMap(\.rmssd),
                              maximumStep: Self.maxHRVStepMS)
        }
    }

    var restingInt: Int? { restingHR.map { Int($0.rounded()) } }
    var hrvInt: Int? {
        guard hrvQualificationVersion >= Self.currentHRVQualificationVersion else { return nil }
        return hrvEMA.map { Int($0.rounded()) }
    }
    var hrvSampleCount: Int {
        guard hrvQualificationVersion >= Self.currentHRVQualificationVersion else { return 0 }
        return Self.canonicalDailySamples(samples).compactMap(\.lnRMSSD).count
    }
    var restingSampleCount: Int { Self.canonicalDailySamples(samples).count }

    func freshSamples(now: Date = Date()) -> [BaselineSample] {
        Self.canonicalDailySamples(samples).filter { sample in
            let age = now.timeIntervalSince(sample.date)
            return age >= 0 && age <= Self.staleAfter
        }
    }

    // Trust counts distinct DAYS, not raw samples: several sessions in one day
    // must not fast-track a "trusted" baseline.
    func freshRestingSampleCount(now: Date = Date()) -> Int {
        Self.distinctDayCount(freshSamples(now: now))
    }

    func freshHRVSampleCount(now: Date = Date()) -> Int {
        guard hrvQualificationVersion >= Self.currentHRVQualificationVersion else { return 0 }
        return Self.distinctDayCount(freshSamples(now: now).filter {
            $0.lnRMSSD != nil && $0.isOvernightSample
        })
    }

    private static func distinctDayCount(_ samples: [BaselineSample],
                                         calendar: Calendar = .current) -> Int {
        Set(samples.map { calendar.startOfDay(for: $0.date) }).count
    }

    static func canonicalDailySamples(
        _ samples: [BaselineSample],
        calendar: Calendar = .current
    ) -> [BaselineSample] {
        var byDay: [Date: BaselineSample] = [:]
        for sample in samples.sorted(by: { $0.date < $1.date }) {
            let day = calendar.startOfDay(for: sample.date)
            guard let existing = byDay[day] else {
                byDay[day] = sample
                continue
            }
            let existingPriority = existing.isOvernightSample ? 1 : 0
            let incomingPriority = sample.isOvernightSample ? 1 : 0
            if incomingPriority > existingPriority
                || (incomingPriority == existingPriority
                    && sample.restingHR < existing.restingHR) {
                byDay[day] = sample
            }
        }
        return byDay.values.sorted { $0.date < $1.date }
    }

    /// Fresh HRV samples that came from an overnight/sleep window.
    func freshOvernightHRVSampleCount(now: Date = Date()) -> Int {
        guard hrvQualificationVersion >= Self.currentHRVQualificationVersion else { return 0 }
        return freshSamples(now: now).filter { $0.isOvernightSample }.compactMap(\.lnRMSSD).count
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

    /// Display-ready maturity qualifier for the resting baseline, e.g.
    /// "Learning · 5 of 14 days". `nil` once the baseline is trusted.
    ///
    /// Resting HR can learn from a qualified daytime low-HR window, so the
    /// maturity unit is days. HRV remains explicitly sleep-window qualified.
    ///
    /// Deliberately mirrors `AtriaFitnessAge`'s "Early estimate · day N of M":
    /// a value is shown from the first day and the qualifier discloses how far
    /// the baseline has matured, rather than withholding the reading until it
    /// is confident. Withholding is not more honest — it just leaves the wearer
    /// with nothing while the app silently waits.
    ///
    /// This is the ONE place the maturity state should be read from, so the
    /// caveat can be surfaced in a single location instead of being repeated
    /// against every derived number.
    func restingBaselineMaturityQualifierText(now: Date = Date()) -> String? {
        guard !hasTrustedRestingBaseline(now: now) else { return nil }
        let days = min(freshRestingSampleCount(now: now), Self.trustedMinimumSamples)
        return "Learning · \(days) of \(Self.trustedMinimumSamples) days"
    }

    var restingStats: (mean: Double, sd: Double, count: Int)? {
        restingStats(now: Date())
    }

    /// Testable variant with an explicit `now` — mirrors lnRMSSDStats(now:) so
    /// callers that inject a clock (stress scoring, tests) stay deterministic.
    func restingStats(now: Date) -> (mean: Double, sd: Double, count: Int)? {
        stats(freshSamples(now: now).map(\.restingHR))
    }

    /// HRV baseline stats, preferring overnight/sleep-window samples (like WHOOP's
    /// sleep-weighted HRV) once enough exist; otherwise falls back to all fresh
    /// samples so an intermittent overnight stream never blocks the baseline.
    var lnRMSSDStats: (mean: Double, sd: Double, count: Int)? {
        lnRMSSDStats(now: Date())
    }

    /// Testable variant with an explicit `now` for deterministic calibration.
    func lnRMSSDStats(now: Date) -> (mean: Double, sd: Double, count: Int)? {
        guard hrvQualificationVersion >= Self.currentHRVQualificationVersion else { return nil }
        let fresh = freshSamples(now: now)
        let overnight = fresh.filter { $0.isOvernightSample }.compactMap(\.lnRMSSD)
        if overnight.count >= Self.overnightHRVPreferenceMinimum {
            return stats(overnight)
        }
        // Ramp toward the overnight-only baseline instead of switching at a cliff:
        // w = overnightCount / 7 blends the overnight stats with the all-fresh stats
        // so mean/sd are continuous as the 7th overnight sample arrives.
        guard overnight.count >= 1,
              let overnightStats = stats(overnight),
              let allStats = stats(fresh.compactMap(\.lnRMSSD)),
              allStats.count > overnightStats.count
        else {
            return stats(fresh.compactMap(\.lnRMSSD))
        }
        let w = min(Double(overnight.count) / Double(Self.overnightHRVPreferenceMinimum), 1)
        let mean = w * overnightStats.mean + (1 - w) * allStats.mean
        let variance = w * (overnightStats.sd * overnightStats.sd + pow(overnightStats.mean - mean, 2))
            + (1 - w) * (allStats.sd * allStats.sd + pow(allStats.mean - mean, 2))
        return (mean, sqrt(variance), allStats.count)
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

    private mutating func rebuildLearnedValuesFromCanonicalSamples() {
        restingHR = Self.ema(values: samples.map(\.restingHR),
                             maximumStep: Self.maxRestingStepBPM)
        hrvEMA = Self.ema(values: samples.compactMap(\.rmssd),
                          maximumStep: Self.maxHRVStepMS)
    }

    private static func ema(values: [Double], maximumStep: Double) -> Double? {
        guard var value = values.first else { return nil }
        for next in values.dropFirst() {
            let step = alpha * (next - value)
            value += min(max(step, -maximumStep), maximumStep)
        }
        return value
    }

    // Persistence
    static let persistenceKey = "personalBaseline"
    static func load() -> PersonalBaseline {
        guard let data = UserDefaults.standard.data(forKey: persistenceKey),
              let b = try? JSONDecoder().decode(PersonalBaseline.self, from: data)
        else { return PersonalBaseline() }
        return b
    }
    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.persistenceKey)
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

    static let persistenceKey = "athleteProfile"
    static let onboardingCompletionKey = "atria.onboarding.completed.v1"
    enum CodingKeys: String, CodingKey {
        case age, measuredMaxHR, maxHRSource, biologicalSex, weightKg, heightCm, updated, hasCompletedOnboarding
    }

    static var defaultAge: Int { 30 }
    static var defaultMeasuredMaxHR: Int {
        defaultMeasuredMaxHR(userDefaults: .standard)
    }

    static func defaultMeasuredMaxHR(userDefaults: UserDefaults) -> Int {
        userDefaults.object(forKey: "maxHR") as? Int ?? 190
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
        // A legacy scalar is not evidence that the value was measured. Older
        // payloads commonly persisted the 190 placeholder without provenance;
        // treating that as measured silently upgrades strain confidence and can
        // unlock VO2max. Only an explicitly encoded source may claim measured.
        maxHRSource = try c.decodeIfPresent(HRMaxSource.self, forKey: .maxHRSource) ?? .ageEstimate
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

    static func load(userDefaults: UserDefaults = .standard) -> AthleteProfile {
        let completedFlag = userDefaults.bool(forKey: onboardingCompletionKey)
        guard let data = userDefaults.data(forKey: persistenceKey),
              let p = try? JSONDecoder().decode(AthleteProfile.self, from: data)
        else {
            return AthleteProfile(age: defaultAge,
                                  measuredMaxHR: defaultMeasuredMaxHR(userDefaults: userDefaults),
                                  maxHRSource: .ageEstimate,
                                  biologicalSex: .unspecified,
                                  weightKg: 0,
                                  heightCm: 0,
                                  updated: nil,
                                  hasCompletedOnboarding: completedFlag)
        }
        guard completedFlag, !p.hasCompletedOnboarding else { return p }
        var bridged = p
        bridged.hasCompletedOnboarding = true
        return bridged
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.persistenceKey)
        }
        UserDefaults.standard.set(maxHR, forKey: "maxHR")
        UserDefaults.standard.set(hasCompletedOnboarding, forKey: Self.onboardingCompletionKey)
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
        UserDefaults.standard.set(true, forKey: Self.onboardingCompletionKey)
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
                .atriaInspectableGraph(
                    AtriaInspectableGraph(
                        title: "Resting HR trend",
                        subtitle: baseline.map { "Baseline \($0) bpm" },
                        content: .timeSeries([
                            .init(title: "Resting HR",
                                  unit: " bpm",
                                  tint: .teal,
                                  points: points.map {
                                      .init(date: $0.start, value: Double($0.resting))
                                  })
                        ])
                    )
                )
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
        .atriaInspectableGraph(rows.isEmpty ? nil : AtriaInspectableGraph(
            title: "Time in heart-rate zones",
            subtitle: "Recorded session duration",
            content: .histogram(rows.map { row in
                .init(label: row.zone.name,
                      value: row.seconds / 60,
                      unit: " min",
                      tint: row.zone.color)
            })
        ))
    }

    private func fmt(_ s: Double) -> String {
        let i = Int(s)
        return i >= 60 ? "\(i/60)m \(i%60)s" : "\(i)s"
    }
}
