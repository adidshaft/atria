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

struct HRVSnapshot: Equatable {
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
            return "learning: beat-to-beat gaps"
        case "beats":
            return "learning: need 240 beat-to-beat samples"
        case "confidence":
            return "learning: beat-to-beat confidence"
        default:
            return "learning"
        }
    }
}

enum HRVAnalyzer {
    static func analyze<C: Collection>(_ raw: C,
                        now: Date = Date(),
                        includeTachogram: Bool = true) -> (HRVSnapshot?, [RRSample]) where C.Element == RRInterval {
        guard raw.count >= 2 else { return (nil, []) }
        let minimumWindowDate = now.addingTimeInterval(-300)
        guard let windowStartIndex = raw.firstIndex(where: { $0.t >= minimumWindowDate }) else {
            return (nil, [])
        }

        let window = raw[windowStartIndex...]
        guard window.count >= 2, let firstSample = window.first else { return (nil, []) }
        let coverage = min(300, now.timeIntervalSince(firstSample.t))

        var kept: [RRInterval] = []
        kept.reserveCapacity(window.count)
        var corrected: [RRSample] = []
        if includeTachogram {
            corrected.reserveCapacity(window.count)
        }
        var rejectedOutOfRange = 0
        var rejectedDeltaOver20Percent = 0
        var rejectedHRMismatch = 0
        var maxRRGapSeconds: TimeInterval = 0
        var previousWindowSample: RRInterval?

        let windowArray = Array(window)
        for index in windowArray.indices {
            let rr = windowArray[index]
            if let previousWindowSample {
                maxRRGapSeconds = max(maxRRGapSeconds, rr.t.timeIntervalSince(previousWindowSample.t))
            }
            previousWindowSample = rr

            guard (300...2000).contains(rr.ms) else {
                rejectedOutOfRange += 1
                if includeTachogram {
                    corrected.append(RRSample(t: rr.t, ms: rr.ms, corrected: false, interpolated: false))
                }
                continue
            }
            if let expectedHR = rr.expectedHR, expectedHR > 0 {
                let impliedHR = 60_000.0 / rr.ms
                guard abs(impliedHR - Double(expectedHR)) <= HRVSnapshot.maxRRImpliedHRMismatchBPM else {
                    rejectedHRMismatch += 1
                    if includeTachogram {
                        corrected.append(RRSample(t: rr.t, ms: rr.ms, corrected: false, interpolated: false))
                    }
                    continue
                }
            }
            if let localMedian = localMedianRR(in: windowArray, around: index), localMedian > 0 {
                let delta = abs(rr.ms - localMedian) / localMedian
                guard delta <= 0.20 else {
                    rejectedDeltaOver20Percent += 1
                    if includeTachogram {
                        corrected.append(RRSample(t: rr.t, ms: rr.ms, corrected: false, interpolated: false))
                    }
                    continue
                }
            }
            kept.append(rr)
            if includeTachogram {
                corrected.append(RRSample(t: rr.t, ms: rr.ms, corrected: true, interpolated: false))
            }
        }

        let confidence = Double(kept.count) / Double(window.count)
        guard kept.count >= 2 else {
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

        var rrTotal = 0.0
        var diffSquareTotal = 0.0
        var pnn50Count = 0
        for index in kept.indices {
            let value = kept[index].ms
            rrTotal += value
            guard index > 0 else { continue }
            let diff = value - kept[index - 1].ms
            diffSquareTotal += diff * diff
            if abs(diff) > 50 {
                pnn50Count += 1
            }
        }

        let diffCount = kept.count - 1
        let rmssd = sqrt(diffSquareTotal / Double(diffCount))
        let mean = rrTotal / Double(kept.count)
        var varianceTotal = 0.0
        for sample in kept {
            let delta = sample.ms - mean
            varianceTotal += delta * delta
        }
        let sdnn = sqrt(varianceTotal / Double(kept.count - 1))
        let pnn50 = Double(pnn50Count) / Double(diffCount) * 100
        let lnRMSSD = rmssd > 0 ? log(rmssd) : 0
        let resp = respiratoryRate(from: kept, now: now)
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

    private static func respiratoryRate(from kept: [RRInterval], now: Date) -> Double? {
        AtriaAnalytics.RespRateRsa.estimate(samples: kept.map { (t: $0.t, ms: $0.ms) }, now: now)
    }

    private static func localMedianRR(in samples: [RRInterval], around index: Int) -> Double? {
        let radius = 2
        let lower = max(samples.startIndex, index - radius)
        let upper = min(samples.index(before: samples.endIndex), index + radius)
        let values = samples[lower...upper]
            .map(\.ms)
            .filter { (300...2000).contains($0) }
            .sorted()
        guard values.count >= 3 else { return nil }
        let middle = values.count / 2
        if values.count.isMultiple(of: 2) {
            return (values[middle - 1] + values[middle]) / 2
        }
        return values[middle]
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
