import Charts
import Foundation
import SwiftUI

/// Why an intraday chart has no data for a stretch of time.
///
/// Owner requirement (2026-09-24): "identify the cases where there is
/// absolutely no data and it should be clear in the graph." Lines already
/// break at gaps (never interpolated); this adds a quiet, labeled band so the
/// blank reads as a fact instead of a rendering glitch.
///
/// Every reason except `.noData` needs positive evidence from
/// `AtriaGapWearClassification`. An `.indeterminate` verdict (or no evidence
/// at all) is never promoted to a confident reason — it stays "No data".
enum AtriaChartGapReason: String, Equatable, Sendable, CaseIterable {
    case notWorn
    case charging
    case syncing
    case noData

    var label: String {
        switch self {
        case .notWorn: return "Not worn"
        case .charging: return "Charging"
        case .syncing: return "Syncing…"
        case .noData: return "No data"
        }
    }

    /// Maps a wear/recoverability verdict to a chart reason. `nil` means the
    /// verdict carries no confident reason and the band stays "No data".
    static func confident(from verdict: AtriaGapWearClassification.Verdict) -> AtriaChartGapReason? {
        switch verdict {
        case .charging: return .charging
        case .offWrist: return .notWorn
        case .wornUndrained(recoverable: true), .appOrRadioDown(recoverable: true): return .syncing
        case .wornUndrained(recoverable: false), .appOrRadioDown(recoverable: false),
             .unrecoverable, .indeterminate:
            return nil
        }
    }
}

struct AtriaChartGapBand: Identifiable, Equatable, Sendable {
    let start: Date
    let end: Date
    let reason: AtriaChartGapReason

    var id: String { "\(start.timeIntervalSince1970)-\(end.timeIntervalSince1970)" }
    var duration: TimeInterval { end.timeIntervalSince(start) }
}

/// Evidence the band builder may use. Empty evidence is valid and simply
/// yields "No data" for every gap.
struct AtriaChartGapEvidence: Equatable, Sendable {
    struct ClassifiedWindow: Equatable, Sendable {
        let interval: DateInterval
        let reason: AtriaChartGapReason
    }

    /// Spans the strap proved off-wrist (zero contact bracketing the gap).
    var offWristSpans: [DateInterval] = []
    /// Gap-ledger windows whose verdict carried a confident reason.
    var classifiedWindows: [ClassifiedWindow] = []

    static let none = AtriaChartGapEvidence()
}

enum AtriaChartNoDataBands {
    /// Shorter holes are signal hiccups the trace already smooths over
    /// (`traceDisplayContinuityGap` is 5 min); a band that narrow would be a
    /// sliver of noise. Fifteen minutes is the smallest gap worth naming.
    static let minimumBandDuration: TimeInterval = 15 * 60
    /// Share of a gap that evidence must cover before its reason is named.
    /// Anything less fails closed to "No data".
    static let confidentCoverage = 0.8
    /// Share of the plotted domain a band must span before its label is
    /// drawn; narrower bands keep the tint without cramped text.
    static let labelMinimumDomainFraction = 0.12

    /// Missing-data bands for a time-series chart.
    ///
    /// - Parameters:
    ///   - sampleDates: real observation timestamps (any order).
    ///   - domain: the chart's x domain.
    ///   - now: the present; bands never extend into the future.
    ///   - evidence: reason evidence; `.none` yields "No data" bands only.
    /// - Returns: `[]` when there are no samples at all — an empty chart
    ///   already shows its own empty-state message, and a full-width band
    ///   would just repeat it.
    static func bands(sampleDates: [Date],
                      domain: ClosedRange<Date>,
                      now: Date = Date(),
                      evidence: AtriaChartGapEvidence = .none,
                      minimumGap: TimeInterval? = nil) -> [AtriaChartGapBand] {
        let upper = min(domain.upperBound, now)
        guard upper > domain.lowerBound else { return [] }
        let dates = sampleDates
            .filter { $0 >= domain.lowerBound && $0 <= upper }
            .sorted()
        guard let first = dates.first, let last = dates.last else { return [] }
        let minimumGap = minimumGap ?? cadenceAwareMinimumGap(sortedDates: dates)

        var holes: [(Date, Date)] = []
        if first.timeIntervalSince(domain.lowerBound) >= minimumGap {
            holes.append((domain.lowerBound, first))
        }
        for (previous, next) in zip(dates, dates.dropFirst())
        where next.timeIntervalSince(previous) >= minimumGap {
            holes.append((previous, next))
        }
        if upper.timeIntervalSince(last) >= minimumGap {
            holes.append((last, upper))
        }
        return holes.map { start, end in
            AtriaChartGapBand(start: start,
                              end: end,
                              reason: reason(for: DateInterval(start: start, end: end),
                                             evidence: evidence))
        }
    }

    /// Down-sampled or bucketed series (five-minute buckets, ~6-minute
    /// representative points) must not read their own spacing as missing
    /// data: the threshold is the larger of `minimumBandDuration` and 2.5×
    /// the series' median spacing.
    static func cadenceAwareMinimumGap(sortedDates: [Date]) -> TimeInterval {
        let deltas = zip(sortedDates, sortedDates.dropFirst())
            .map { $1.timeIntervalSince($0) }
            .filter { $0 > 0 }
            .sorted()
        guard !deltas.isEmpty else { return minimumBandDuration }
        return max(minimumBandDuration, deltas[deltas.count / 2] * 2.5)
    }

    /// The reason for one gap: the first confident reason whose evidence
    /// covers at least `confidentCoverage` of it, otherwise "No data".
    static func reason(for gap: DateInterval,
                       evidence: AtriaChartGapEvidence) -> AtriaChartGapReason {
        guard gap.duration > 0 else { return .noData }
        // Charging outranks off-wrist (same precedence as the classifier);
        // both outrank "syncing", which is the only recoverable claim.
        for candidate in [AtriaChartGapReason.charging, .notWorn, .syncing] {
            var spans = evidence.classifiedWindows
                .filter { $0.reason == candidate }
                .map(\.interval)
            if candidate == .notWorn { spans += evidence.offWristSpans }
            if coveredFraction(of: gap, by: spans) >= confidentCoverage {
                return candidate
            }
        }
        return .noData
    }

    /// Fraction of `gap` covered by the union of `spans` (overlaps once).
    static func coveredFraction(of gap: DateInterval, by spans: [DateInterval]) -> Double {
        let clipped = spans.compactMap { $0.intersection(with: gap) }
            .filter { $0.duration > 0 }
            .sorted { $0.start < $1.start }
        guard var current = clipped.first else { return 0 }
        var covered: TimeInterval = 0
        for span in clipped.dropFirst() {
            if span.start > current.end {
                covered += current.duration
                current = span
            } else if span.end > current.end {
                current = DateInterval(start: current.start, end: span.end)
            }
        }
        covered += current.duration
        return min(1, covered / gap.duration)
    }

    static func showsLabel(_ band: AtriaChartGapBand, domain: ClosedRange<Date>) -> Bool {
        let total = domain.upperBound.timeIntervalSince(domain.lowerBound)
        guard total > 0 else { return false }
        return band.duration / total >= labelMinimumDomainFraction
    }

    /// Spoken summary for chart accessibility values, e.g.
    /// "No data 01:10–03:40". Nil when there are no bands.
    static func accessibilitySummary(_ bands: [AtriaChartGapBand],
                                     timeZone: TimeZone = .current) -> String? {
        guard !bands.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return bands.map {
            "\($0.reason.label) \(formatter.string(from: $0.start))–\(formatter.string(from: $0.end))"
        }
        .joined(separator: ", ")
    }
}

/// Reads the durable gap evidence the app keeps today for chart bands.
///
/// Only the proven off-wrist tally (`OffWristExclusion`, recorded when a gap
/// opens with zero contact bracketing it) names a reason in production.
/// Gap-ledger windows carry no wear evidence yet (session-HR overlap,
/// contact-at-open, charging proof), so `AtriaGapWearClassification` would
/// return `.indeterminate` for every one of them; reading the ledger file on a
/// render path for a guaranteed "No data" would be pure cost. When the ledger
/// persists that evidence, classify its windows with
/// `AtriaChartGapReason.confident(from:)` into `classifiedWindows` here — the
/// charts need no change.
enum AtriaChartGapEvidenceProvider {
    private static let lock = NSLock()
    private static var memo: (bucket: Int, value: AtriaChartGapEvidence)?

    static func current(now: Date = Date(),
                        defaults: UserDefaults = .standard) -> AtriaChartGapEvidence {
        // A one-minute memo: chart bodies re-render often, the tally changes
        // only when a gap opens.
        let bucket = Int(now.timeIntervalSince1970 / 60)
        lock.lock()
        defer { lock.unlock() }
        if defaults === UserDefaults.standard, let memo, memo.bucket == bucket {
            return memo.value
        }
        let offWrist = AtriaGapWearClassification.OffWristExclusion
            .retainedSpans(now: now, defaults: defaults)
            .map { DateInterval(start: Date(timeIntervalSince1970: $0.startUnix),
                                end: Date(timeIntervalSince1970: $0.endUnix)) }
        let value = AtriaChartGapEvidence(offWristSpans: offWrist, classifiedWindows: [])
        if defaults === UserDefaults.standard { memo = (bucket, value) }
        return value
    }
}

/// The one visual for a no-data band inside any Swift Charts time series:
/// a full-height, very quiet fill with a caption label on top when the band
/// is wide enough to hold it. Place it FIRST in the chart body so data marks
/// draw above it.
struct AtriaNoDataBandMarks: ChartContent {
    let bands: [AtriaChartGapBand]
    let domain: ClosedRange<Date>

    var body: some ChartContent {
        ForEach(bands) { band in
            RectangleMark(xStart: .value("Gap start", band.start),
                          xEnd: .value("Gap end", band.end))
                .foregroundStyle(AtriaChartVisualGrammar.noDataBandFill)
                .annotation(position: .overlay, alignment: .top, spacing: 4) {
                    if AtriaChartNoDataBands.showsLabel(band, domain: domain) {
                        Text(band.reason.label)
                            .font(AtriaChartVisualGrammar.noDataBandLabelFont)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .padding(.top, 4)
                    }
                }
                .accessibilityLabel(band.reason.label)
        }
    }
}
