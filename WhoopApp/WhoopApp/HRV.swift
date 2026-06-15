import SwiftUI
import Charts

struct RRSample: Identifiable {
    let id = UUID()
    let t: Date
    let ms: Double
    let corrected: Bool
    let interpolated: Bool
}

struct RRInterval {
    let t: Date
    let ms: Double
    let expectedHR: Int?
}

struct HRVSnapshot {
    static let maxReadyRRGapSeconds: TimeInterval = 3
    static let maxRRImpliedHRMismatchBPM = 35.0

    let rmssd: Double
    let sdnn: Double
    let pnn50: Double
    let lnRMSSD: Double
    let confidence: Double
    let kept: Int
    let raw: Int
    let rejectedOutOfRange: Int
    let rejectedDeltaOver20Percent: Int
    let rejectedHRMismatch: Int
    let interpolated: Int
    let windowSeconds: TimeInterval
    let maxRRGapSeconds: TimeInterval
    let respiratoryRate: Double?

    var isReady: Bool {
        windowSeconds >= 300
        && maxRRGapSeconds <= Self.maxReadyRRGapSeconds
        && kept >= 240
        && confidence >= 0.75
    }
    var confidencePercent: Int { Int((confidence * 100).rounded()) }
    var readinessReason: String {
        if windowSeconds < 300 { return "window" }
        if maxRRGapSeconds > Self.maxReadyRRGapSeconds { return "gap" }
        if kept < 240 { return "beats" }
        if confidence < 0.75 { return "confidence" }
        return "ready"
    }
    var readinessMessage: String {
        switch readinessReason {
        case "ready":
            return "ready"
        case "window":
            return "learning: build 5-min window"
        case "gap":
            return "learning: RR gaps"
        case "beats":
            return "learning: need 240 clean RR"
        case "confidence":
            return "learning: low RR confidence"
        default:
            return "learning"
        }
    }
}

enum HRVAnalyzer {
    static func analyze(_ raw: [RRInterval], now: Date = Date()) -> (HRVSnapshot?, [RRSample]) {
        let window = raw.filter { now.timeIntervalSince($0.t) <= 300 }
        guard window.count >= 2 else { return (nil, []) }
        let coverage = raw.first.map { min(300, now.timeIntervalSince($0.t)) } ?? 0
        let maxRRGapSeconds = maxGapSeconds(in: window)

        var kept: [RRInterval] = []
        var corrected: [RRSample] = []
        var rejectedOutOfRange = 0
        var rejectedDeltaOver20Percent = 0
        var rejectedHRMismatch = 0
        for rr in window {
            guard (300...2000).contains(rr.ms) else {
                rejectedOutOfRange += 1
                corrected.append(RRSample(t: rr.t, ms: rr.ms, corrected: false, interpolated: false))
                continue
            }
            if let expectedHR = rr.expectedHR, expectedHR > 0 {
                let impliedHR = 60_000.0 / rr.ms
                guard abs(impliedHR - Double(expectedHR)) <= HRVSnapshot.maxRRImpliedHRMismatchBPM else {
                    rejectedHRMismatch += 1
                    corrected.append(RRSample(t: rr.t, ms: rr.ms, corrected: false, interpolated: false))
                    continue
                }
            }
            if let previous = kept.last {
                let delta = abs(rr.ms - previous.ms) / previous.ms
                guard delta <= 0.20 else {
                    rejectedDeltaOver20Percent += 1
                    corrected.append(RRSample(t: rr.t, ms: rr.ms, corrected: false, interpolated: false))
                    continue
                }
            }
            kept.append(rr)
            corrected.append(RRSample(t: rr.t, ms: rr.ms, corrected: true, interpolated: false))
        }
        let metricSamples = kept.sorted { $0.t < $1.t }

        let confidence = window.isEmpty ? 0 : Double(kept.count) / Double(window.count)
        guard metricSamples.count >= 2 else {
            let learning = HRVSnapshot(rmssd: 0, sdnn: 0, pnn50: 0, lnRMSSD: 0,
                                       confidence: confidence, kept: kept.count,
                                       raw: window.count,
                                       rejectedOutOfRange: rejectedOutOfRange,
                                       rejectedDeltaOver20Percent: rejectedDeltaOver20Percent,
                                       rejectedHRMismatch: rejectedHRMismatch,
                                       interpolated: 0,
                                       windowSeconds: coverage,
                                       maxRRGapSeconds: maxRRGapSeconds,
                                       respiratoryRate: nil)
            return (learning, corrected)
        }

        let diffs = zip(metricSamples.dropFirst(), metricSamples).map { $0.ms - $1.ms }
        let rmssd = sqrt(diffs.map { $0 * $0 }.reduce(0, +) / Double(diffs.count))
        let mean = metricSamples.map(\.ms).reduce(0, +) / Double(metricSamples.count)
        let sdnn = sqrt(metricSamples.map { pow($0.ms - mean, 2) }.reduce(0, +) / Double(metricSamples.count - 1))
        let pnn50 = Double(diffs.filter { abs($0) > 50 }.count) / Double(diffs.count) * 100
        let lnRMSSD = rmssd > 0 ? log(rmssd) : 0
        let resp = respiratoryRate(from: metricSamples, now: now)
        let snapshot = HRVSnapshot(rmssd: rmssd, sdnn: sdnn, pnn50: pnn50,
                                   lnRMSSD: lnRMSSD, confidence: confidence,
                                   kept: kept.count, raw: window.count,
                                   rejectedOutOfRange: rejectedOutOfRange,
                                   rejectedDeltaOver20Percent: rejectedDeltaOver20Percent,
                                   rejectedHRMismatch: rejectedHRMismatch,
                                   interpolated: 0,
                                   windowSeconds: coverage,
                                   maxRRGapSeconds: maxRRGapSeconds,
                                   respiratoryRate: resp)
        return (snapshot, corrected)
    }

    private static func maxGapSeconds(in samples: [RRInterval]) -> TimeInterval {
        guard samples.count >= 2 else { return 0 }
        let sorted = samples.sorted { $0.t < $1.t }
        return zip(sorted.dropFirst(), sorted)
            .map { $0.t.timeIntervalSince($1.t) }
            .max() ?? 0
    }

    private static func respiratoryRate(from kept: [RRInterval], now: Date) -> Double? {
        let recent = kept.filter { now.timeIntervalSince($0.t) <= 90 }
        guard recent.count >= 20,
              let first = recent.first?.t,
              let last = recent.last?.t else { return nil }
        let duration = last.timeIntervalSince(first)
        guard duration >= 45 else { return nil }

        let start = first.timeIntervalSinceReferenceDate
        let relative = recent.map { ($0.t.timeIntervalSinceReferenceDate - start, $0.ms) }
        let sampleRate = 4.0
        let step = 1.0 / sampleRate
        let count = Int(duration / step) + 1
        guard count >= Int(45 * sampleRate) else { return nil }

        var resampled: [Double] = []
        resampled.reserveCapacity(count)
        var sourceIndex = 0
        for index in 0..<count {
            let t = Double(index) * step
            while sourceIndex + 1 < relative.count && relative[sourceIndex + 1].0 < t {
                sourceIndex += 1
            }
            guard sourceIndex + 1 < relative.count else { break }
            let a = relative[sourceIndex]
            let b = relative[sourceIndex + 1]
            let span = b.0 - a.0
            guard span > 0 else { continue }
            let fraction = (t - a.0) / span
            resampled.append(a.1 + (b.1 - a.1) * fraction)
        }
        guard resampled.count >= Int(45 * sampleRate) else { return nil }

        let mean = resampled.reduce(0, +) / Double(resampled.count)
        let centered = resampled.map { $0 - mean }
        let totalPower = centered.map { $0 * $0 }.reduce(0, +)
        guard totalPower > 0 else { return nil }

        var bestRate = 0.0
        var bestPower = 0.0
        var bandPower = 0.0
        for breathsPerMinute in stride(from: 6.0, through: 30.0, by: 0.5) {
            let frequency = breathsPerMinute / 60.0
            var real = 0.0
            var imaginary = 0.0
            for (index, value) in centered.enumerated() {
                let angle = 2.0 * Double.pi * frequency * Double(index) / sampleRate
                real += value * cos(angle)
                imaginary -= value * sin(angle)
            }
            let power = real * real + imaginary * imaginary
            bandPower += power
            if power > bestPower {
                bestPower = power
                bestRate = breathsPerMinute
            }
        }
        guard bestPower > 0, bestPower / max(bandPower, bestPower) >= 0.18 else { return nil }
        return bestRate
    }
}

struct TachogramChart: View {
    let samples: [RRSample]

    var body: some View {
        Chart {
            ForEach(samples.filter(\.corrected)) { s in
                LineMark(x: .value("Time", s.t), y: .value("RR", s.ms))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(.purple.gradient)
            }
            ForEach(samples.filter { !$0.corrected }) { s in
                PointMark(x: .value("Time", s.t), y: .value("RR", s.ms))
                    .symbolSize(24)
                    .foregroundStyle(.orange)
            }
        }
        .chartXAxis(.hidden)
        .chartYScale(domain: yDomain)
        .frame(height: 120)
    }

    private var yDomain: ClosedRange<Double> {
        let values = samples.map(\.ms)
        let lo = max((values.min() ?? 600) - 80, 300)
        let hi = min((values.max() ?? 1000) + 80, 2000)
        return lo...max(hi, lo + 100)
    }
}
