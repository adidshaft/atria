import SwiftUI
import Charts

struct RRSample: Identifiable {
    let t: Date
    let ms: Double
    let corrected: Bool
    let interpolated: Bool

    /// Beat timestamps are the stable domain identity. Re-running the HRV
    /// analysis must update the same chart points instead of replacing every
    /// point with a fresh UUID and forcing a full Swift Charts diff.
    var id: Date { t }
}

/// Explicit origin attached to every newly persisted beat-to-beat interval.
///
/// Missing provenance is intentionally represented by `nil` on persistence
/// models so archives written before this field existed remain decodable. A
/// missing value is never upgraded to standard Heart Rate Measurement (2A37)
/// evidence during restore or metric calculation.
enum AtriaRRSourceProvenance: String, Codable, Equatable, Sendable {
    case standardHeartRateMeasurement2A37 = "standard_2a37"
    case validatedProprietaryRealtime = "validated_proprietary_realtime"
    case verifiedWhoop4HistoricalV24 = "verified_whoop4_historical_v24"
}

struct RRInterval {
    let t: Date
    let ms: Double
    let expectedHR: Int?
    let source: AtriaRRSourceProvenance?

    init(t: Date,
         ms: Double,
         expectedHR: Int?,
         source: AtriaRRSourceProvenance? = nil) {
        self.t = t
        self.ms = ms
        self.expectedHR = expectedHR
        self.source = source
    }
}

struct HRVSnapshot: Codable, Equatable, Sendable {
    enum Provenance: String, Codable, Sendable {
        case localRRWindow = "local_rr_window"
        case sleepRRWindow = "sleep_rr_window"
        case unknown
    }

    static let maxReadyRRGapSeconds: TimeInterval = 3
    static let maxRRImpliedHRMismatchBPM = 35.0
    /// The RR decoder accepts intervals through 2,000 ms (30 bpm). Readiness
    /// therefore needs to scale with observed duration instead of requiring a
    /// fixed 240 beats, which made a clean five-minute window impossible for
    /// athletes below 48 bpm. Continuity and retained-sample confidence remain
    /// independent hard gates.
    static let minimumReadyBeatsPerSecond = 0.5

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
    /// Count of true neighboring NN differences used by RMSSD/pNN50. Optional so
    /// previously persisted snapshots still decode; a missing legacy value fails
    /// readiness closed instead of assuming rejected beats were adjacent.
    let successiveDifferenceCount: Int?
    let windowSeconds: TimeInterval
    let maxRRGapSeconds: TimeInterval
    let respiratoryRate: Double?
    let measurementStart: Date?
    let measurementEnd: Date
    let analyzedAt: Date
    let provenance: Provenance

    init(rmssd: Double,
         sdnn: Double,
         pnn50: Double,
         lnRMSSD: Double,
         confidence: Double,
         kept: Int,
         raw: Int,
         rejectedOutOfRange: Int,
         rejectedDeltaOver20Percent: Int,
         rejectedHRMismatch: Int,
         interpolated: Int,
         successiveDifferenceCount: Int? = nil,
         windowSeconds: TimeInterval,
         maxRRGapSeconds: TimeInterval,
         respiratoryRate: Double?,
         measurementStart: Date? = nil,
         measurementEnd: Date = .distantPast,
         analyzedAt: Date = .distantPast,
         provenance: Provenance = .unknown) {
        self.rmssd = rmssd
        self.sdnn = sdnn
        self.pnn50 = pnn50
        self.lnRMSSD = lnRMSSD
        self.confidence = confidence
        self.kept = kept
        self.raw = raw
        self.rejectedOutOfRange = rejectedOutOfRange
        self.rejectedDeltaOver20Percent = rejectedDeltaOver20Percent
        self.rejectedHRMismatch = rejectedHRMismatch
        self.interpolated = interpolated
        self.successiveDifferenceCount = successiveDifferenceCount
        self.windowSeconds = windowSeconds
        self.maxRRGapSeconds = maxRRGapSeconds
        self.respiratoryRate = respiratoryRate
        self.measurementStart = measurementStart
        self.measurementEnd = measurementEnd
        self.analyzedAt = analyzedAt
        self.provenance = provenance
    }

    var isReady: Bool {
        windowSeconds >= 300
        && maxRRGapSeconds <= Self.maxReadyRRGapSeconds
        && kept >= minimumReadyBeatCount
        && hasSufficientSuccessiveDifferences
        && confidence >= 0.75
    }
    var minimumReadyBeatCount: Int {
        Int(ceil(max(0, windowSeconds) * Self.minimumReadyBeatsPerSecond))
    }
    var confidencePercent: Int { Int((confidence * 100).rounded()) }
    var minimumReadySuccessiveDifferenceCount: Int {
        Int(ceil(Double(max(0, kept - 1)) * 0.70))
    }
    var hasSufficientSuccessiveDifferences: Bool {
        guard let successiveDifferenceCount else { return false }
        return successiveDifferenceCount >= max(1, minimumReadySuccessiveDifferenceCount)
    }
    func isDisplayEligible(on now: Date = Date(),
                           maximumAge: TimeInterval = 24 * 60 * 60) -> Bool {
        guard isReady else { return false }
        let age = now.timeIntervalSince(measurementEnd)
        return age >= -5 * 60 && age <= maximumAge
    }

    func isRecoveryEligible(on now: Date,
                            calendar: Calendar = .current) -> Bool {
        guard isReady else { return false }
        let age = now.timeIntervalSince(measurementEnd)
        guard age >= -300,
              age <= 24 * 60 * 60,
              calendar.isDate(measurementEnd, inSameDayAs: now) else {
            return false
        }
        return (4...11).contains(calendar.component(.hour, from: measurementEnd))
    }

    /// Stress is a present-tense metric. Persisted cadence HRV remains useful for
    /// daily recovery/baselines, but it must not be reused as if it described the
    /// user's current autonomic state after a relaunch or hours without RR data.
    func isLiveStressEligible(on now: Date = Date(),
                              maximumAge: TimeInterval = 10 * 60) -> Bool {
        guard isReady, provenance == .localRRWindow else { return false }
        let age = now.timeIntervalSince(measurementEnd)
        return age >= -5 && age <= maximumAge
    }

    var readinessReason: String {
        if windowSeconds < 300 { return "window" }
        if maxRRGapSeconds > Self.maxReadyRRGapSeconds { return "gap" }
        if kept < minimumReadyBeatCount { return "beats" }
        if !hasSufficientSuccessiveDifferences { return "differences" }
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
            return "learning: need enough beats for this window"
        case "differences":
            return "learning: need continuous neighboring beats"
        case "confidence":
            return "learning: beat-to-beat confidence"
        default:
            return "learning"
        }
    }
}

enum AtriaHRVSuccessiveDifferences {
    /// HRV is defined over successive NN intervals. A rejected beat breaks that
    /// succession, so values on opposite sides of an artifact must never be
    /// differenced as though they were neighboring beats.
    static func adjacentValues(_ accepted: [(ordinal: Int, value: Double)]) -> [Double] {
        guard accepted.count >= 2 else { return [] }
        var differences: [Double] = []
        differences.reserveCapacity(accepted.count - 1)
        for index in 1..<accepted.count where accepted[index].ordinal == accepted[index - 1].ordinal + 1 {
            differences.append(accepted[index].value - accepted[index - 1].value)
        }
        return differences
    }
}

enum AtriaShortWindowRMSSD {
    /// Computes RMSSD only from one continuous, artifact-screened run of
    /// timestamped standard RR intervals. The longest continuous run is used so
    /// disconnected islands cannot be stitched together merely because their
    /// interval values sum to the requested coverage.
    static func value(samples: [(date: Date, ms: Double)],
                      minimumCoverageSeconds: TimeInterval,
                      maximumGapSeconds: TimeInterval = HRVSnapshot.maxReadyRRGapSeconds) -> Double? {
        guard minimumCoverageSeconds > 0,
              maximumGapSeconds > 0,
              samples.count >= 3 else { return nil }

        let ordered = samples
            .filter { $0.date.timeIntervalSinceReferenceDate.isFinite && $0.ms.isFinite }
            .sorted { $0.date < $1.date }
        guard ordered.count >= 3 else { return nil }

        var segments: [[(date: Date, ms: Double)]] = []
        var current: [(date: Date, ms: Double)] = []
        for sample in ordered {
            if let previous = current.last {
                let gap = sample.date.timeIntervalSince(previous.date)
                if gap <= 0 || gap > maximumGapSeconds {
                    if current.count >= 3 { segments.append(current) }
                    current.removeAll(keepingCapacity: true)
                }
            }
            current.append(sample)
        }
        if current.count >= 3 { segments.append(current) }

        guard let segment = segments.max(by: {
            coveredSeconds($0) < coveredSeconds($1)
        }), coveredSeconds(segment) >= minimumCoverageSeconds else { return nil }

        var kept: [(ordinal: Int, value: Double)] = []
        kept.reserveCapacity(segment.count)
        for index in segment.indices {
            let sample = segment[index]
            guard (300...2000).contains(sample.ms) else { continue }
            let lower = max(segment.startIndex, index - 2)
            let upper = min(segment.index(before: segment.endIndex), index + 2)
            let local = segment[lower...upper]
                .map { $0.ms }
                .filter { (300...2000).contains($0) }
                .sorted()
            if local.count >= 3 {
                let middle = local.count / 2
                let median = local.count.isMultiple(of: 2)
                    ? (local[middle - 1] + local[middle]) / 2
                    : local[middle]
                guard median > 0,
                      abs(sample.ms - median) / median <= 0.20 else { continue }
            }
            kept.append((ordinal: index, value: sample.ms))
        }

        guard Double(kept.count) / Double(segment.count) >= 0.75 else { return nil }
        let differences = AtriaHRVSuccessiveDifferences.adjacentValues(kept)
        let minimumDifferenceCount = max(
            1,
            Int(ceil(Double(max(0, kept.count - 1)) * 0.70))
        )
        guard differences.count >= minimumDifferenceCount else { return nil }
        let meanSquare = differences.reduce(0) { $0 + ($1 * $1) } / Double(differences.count)
        let rmssd = sqrt(meanSquare)
        return rmssd.isFinite && rmssd > 0 ? rmssd : nil
    }

    private static func coveredSeconds(_ samples: [(date: Date, ms: Double)]) -> TimeInterval {
        guard let first = samples.first, let last = samples.last else { return 0 }
        // Standard BLE RR values are intervals ending at their timestamps.
        // Count the first measured interval, never an interval after the last
        // timestamp (which would invent future coverage).
        let firstInterval = (300...2000).contains(first.ms) ? first.ms / 1_000 : 0
        return max(0, last.date.timeIntervalSince(first.date) + firstInterval)
    }
}

enum HRVAnalyzer {
    static func analyze<C: Collection>(_ raw: C,
                        now: Date = Date(),
                        includeTachogram: Bool = true,
                        provenance: HRVSnapshot.Provenance = .localRRWindow) -> (HRVSnapshot?, [RRSample]) where C.Element == RRInterval {
        guard raw.count >= 2 else { return (nil, []) }
        let minimumWindowDate = now.addingTimeInterval(-300)
        guard let windowStartIndex = raw.firstIndex(where: { $0.t >= minimumWindowDate }) else {
            return (nil, [])
        }

        let window = raw[windowStartIndex...]
        guard window.count >= 2, let firstSample = window.first else { return (nil, []) }
        guard window.allSatisfy({
            $0.source == .standardHeartRateMeasurement2A37
        }) else {
            // Legacy nil and mixed proprietary fallback windows are evidence,
            // not a standard 2A37 metric stream.
            return (nil, [])
        }
        // RR timestamps mark interval ends. At 30-40 bpm the first beat inside
        // this slice normally lands after the five-minute boundary even though
        // its measured interval crosses that boundary. Include only that real
        // measured portion so low-rate windows are not impossible by design.
        let firstIntervalSeconds = (300...2000).contains(firstSample.ms)
            ? firstSample.ms / 1_000
            : 0
        let measuredStart = max(
            minimumWindowDate,
            firstSample.t.addingTimeInterval(-firstIntervalSeconds)
        )
        let coverage = min(300, max(0, now.timeIntervalSince(measuredStart)))

        var kept: [RRInterval] = []
        kept.reserveCapacity(window.count)
        var keptOrdinals: [Int] = []
        keptOrdinals.reserveCapacity(window.count)
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
            keptOrdinals.append(index)
            if includeTachogram {
                corrected.append(RRSample(t: rr.t, ms: rr.ms, corrected: true, interpolated: false))
            }
        }
        if let lastSample = windowArray.last {
            maxRRGapSeconds = max(maxRRGapSeconds, now.timeIntervalSince(lastSample.t))
        }

        let measurementEnd = windowArray.last?.t ?? now

        let confidence = Double(kept.count) / Double(window.count)
        guard kept.count >= 2 else {
            let learning = HRVSnapshot(rmssd: 0, sdnn: 0, pnn50: 0, lnRMSSD: 0,
                                       confidence: confidence, kept: kept.count,
                                       raw: window.count,
                                       rejectedOutOfRange: rejectedOutOfRange,
                                       rejectedDeltaOver20Percent: rejectedDeltaOver20Percent,
                                       rejectedHRMismatch: rejectedHRMismatch,
                                       interpolated: 0,
                                       successiveDifferenceCount: 0,
                                       windowSeconds: coverage,
                                       maxRRGapSeconds: maxRRGapSeconds,
                                       respiratoryRate: nil,
                                       measurementStart: measuredStart,
                                       measurementEnd: measurementEnd,
                                       analyzedAt: now,
                                       provenance: provenance)
            return (learning, corrected)
        }

        var rrTotal = 0.0
        for sample in kept { rrTotal += sample.ms }
        let differences = AtriaHRVSuccessiveDifferences.adjacentValues(
            zip(keptOrdinals, kept).map { (ordinal: $0.0, value: $0.1.ms) }
        )
        let diffCount = differences.count
        let diffSquareTotal = differences.reduce(0) { $0 + ($1 * $1) }
        let pnn50Count = differences.reduce(0) { $0 + (abs($1) > 50 ? 1 : 0) }
        let rmssd = diffCount > 0 ? sqrt(diffSquareTotal / Double(diffCount)) : 0
        let mean = rrTotal / Double(kept.count)
        var varianceTotal = 0.0
        for sample in kept {
            let delta = sample.ms - mean
            varianceTotal += delta * delta
        }
        let sdnn = sqrt(varianceTotal / Double(kept.count - 1))
        let pnn50 = diffCount > 0 ? Double(pnn50Count) / Double(diffCount) * 100 : 0
        let lnRMSSD = rmssd > 0 ? log(rmssd) : 0
        let resp = respiratoryRate(from: kept, now: now)
        let snapshot = HRVSnapshot(rmssd: rmssd, sdnn: sdnn, pnn50: pnn50,
                                   lnRMSSD: lnRMSSD, confidence: confidence,
                                   kept: kept.count, raw: window.count,
                                   rejectedOutOfRange: rejectedOutOfRange,
                                   rejectedDeltaOver20Percent: rejectedDeltaOver20Percent,
                                   rejectedHRMismatch: rejectedHRMismatch,
                                   interpolated: 0,
                                   successiveDifferenceCount: diffCount,
                                   windowSeconds: coverage,
                                   maxRRGapSeconds: maxRRGapSeconds,
                                   respiratoryRate: resp,
                                   measurementStart: measuredStart,
                                   measurementEnd: measurementEnd,
                                   analyzedAt: now,
                                   provenance: provenance)
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
    private let correctedSamples: [RRSample]
    private let uncorrectedSamples: [RRSample]
    private let yDomain: ClosedRange<Double>

    init(samples: [RRSample]) {
        correctedSamples = samples.filter(\.corrected)
        uncorrectedSamples = samples.filter { !$0.corrected }
        let values = samples.map(\.ms)
        let lo = max((values.min() ?? 600) - 80, 300)
        let hi = min((values.max() ?? 1000) + 80, 2000)
        yDomain = lo...max(hi, lo + 100)
    }

    var body: some View {
        Chart {
            ForEach(correctedSamples) { s in
                LineMark(x: .value("Time", s.t), y: .value("RR", s.ms))
                    .interpolationMethod(.linear)
                    .foregroundStyle(.purple.gradient)
            }
            ForEach(uncorrectedSamples) { s in
                PointMark(x: .value("Time", s.t), y: .value("RR", s.ms))
                    .symbolSize(24)
                    .foregroundStyle(.orange)
            }
        }
        .chartXAxis(.hidden)
        .chartYScale(domain: yDomain)
        .frame(height: 120)
        .atriaInspectableGraph(
            AtriaInspectableGraph(
                title: "RR tachogram",
                subtitle: "Corrected intervals and excluded artifacts",
                content: .timeSeries([
                    .init(title: "Corrected RR",
                          unit: " ms",
                          tint: .purple,
                          points: AtriaInspectableGraph.segmentedPoints(
                            correctedSamples.map { (date: $0.t, value: $0.ms) },
                            gapThreshold: HRVSnapshot.maxReadyRRGapSeconds
                          )),
                    .init(title: "Excluded",
                          unit: " ms",
                          tint: .orange,
                          points: uncorrectedSamples.enumerated().map { index, sample in
                              .init(date: sample.t, value: sample.ms, segment: index)
                          })
                ])
            )
        )
    }
}
