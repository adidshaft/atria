import Foundation

// Experimental relative skin signal — a DIRECTIONAL raw-scale signal, never a
// temperature. It answers only: is this strap's qualified nightly raw
// skin-sensor value lower or higher than this same strap's own recent
// qualified-night baseline? It carries no degrees, no absolute temperature, no
// body/core/fever/illness/recovery meaning, and no comparability across straps,
// layouts, payload generations, or users. The validated Celsius decoder remains
// unavailable and this value never enters `skinTemperatureDeviationCelsius`,
// daily rollups, HealthKit, widgets, reports, recovery/strain, or coaching.

/// Exact sensor authority a night's raw signal was produced under. Two nights
/// may share a baseline only when every field matches. Never a hardware serial —
/// `pseudonymousStrapKey` is a stable local pseudonym.
struct AtriaRelativeSkinSignalAuthority: Codable, Hashable, Sendable {
    let pseudonymousStrapKey: String
    let layoutVersion: String
    let payloadLength: Int
    let rawOffset: Int
    let algorithmVersion: String
}

/// Typed reason no current numeric result is authorized.
enum AtriaRelativeSkinSignalBlocker: String, Codable, Sendable, Error {
    case noCurrentConfirmedMainSleep
    case noCurrentRawEvidence
    case unknownSensorAuthority
    case mixedSensorAuthority
    case incompleteArchive
    case insufficientRows
    case insufficientCoveredMinutes
    case insufficientCoverage
    case buildingBaseline
    case staleEvidence
}

/// One qualified night's raw median + evidence, under one exact authority.
struct AtriaRelativeSkinNightSummary: Codable, Equatable, Sendable {
    let cycleDay: Date
    let confirmedSleepID: String
    let sleepStart: Date
    let sleepEnd: Date
    let authority: AtriaRelativeSkinSignalAuthority
    /// Median of per-civil-minute medians inside the confirmed sleep. Raw units.
    let nightlyRawMedian: Double
    let qualifiedRowCount: Int
    let coveredMinuteCount: Int
    let coverageFraction: Double
    /// True only when validated motion excluded high-motion minutes. False on the
    /// pure-HR transport (no IMU) — the result then carries reduced confidence and
    /// never claims stillness.
    let motionQualified: Bool
    let calculatedAt: Date
}

/// The published experimental result: the current qualified night vs the personal
/// raw baseline, or a typed blocker. Raw-unit delta only — never the absolute
/// median as a user-facing value.
struct AtriaRelativeSkinSignalSummary: Codable, Equatable, Sendable {
    let algorithmVersion: String
    let currentNight: AtriaRelativeSkinNightSummary?
    let baselineRawMedian: Double?
    let baselineNightCount: Int
    let rawDelta: Double?
    /// robustDelta / robustScale; used only for optional directional labelling
    /// once motion-qualified evidence exists. Finite or nil.
    let normalizedIndex: Double?
    let motionQualified: Bool
    let blocker: AtriaRelativeSkinSignalBlocker?

    static let empty = AtriaRelativeSkinSignalSummary(
        algorithmVersion: AtriaRelativeSkinSignal.algorithmVersion,
        currentNight: nil,
        baselineRawMedian: nil,
        baselineNightCount: 0,
        rawDelta: nil,
        normalizedIndex: nil,
        motionQualified: false,
        blocker: nil
    )
}

/// Pure, unit-tested computation for the relative skin signal. No I/O, no BLE, no
/// archive access — the caller supplies already-qualified per-night summaries.
enum AtriaRelativeSkinSignal {
    static let algorithmVersion = "relskin.v1"
    static let minimumQualifiedRows = 100
    static let minimumCoveredMinutes = 60
    static let minimumCoverageFraction = 0.50
    static let minimumPriorNights = 7
    static let maximumBaselineNights = 30
    static let robustScaleFloor = 1.0
    static let madConstant = 1.4826

    /// Median of a numeric list (nil if empty). Even count = mean of the two
    /// middle values.
    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let n = sorted.count
        if n.isMultiple(of: 2) {
            return (sorted[n / 2 - 1] + sorted[n / 2]) / 2
        }
        return sorted[n / 2]
    }

    /// Night value = median of per-civil-minute medians, so a dense sampling
    /// burst inside one minute cannot dominate the night.
    static func nightlyRawMedian(minuteMedians: [Double]) -> Double? {
        median(minuteMedians)
    }

    /// Median Absolute Deviation about the median.
    static func mad(_ values: [Double]) -> Double? {
        guard let m = median(values) else { return nil }
        return median(values.map { abs($0 - m) })
    }

    /// robustScale = max(1 raw unit, 1.4826 * MAD) — always finite and > 0 so a
    /// zero-MAD baseline still yields a finite normalized index.
    static func robustScale(priorNightlyMedians: [Double]) -> Double {
        let madValue = mad(priorNightlyMedians) ?? 0
        return Swift.max(robustScaleFloor, madConstant * madValue)
    }

    /// Qualification gate for one night's raw evidence. Returns the first failing
    /// blocker or nil when the night qualifies.
    static func nightQualifies(rowCount: Int,
                               coveredMinutes: Int,
                               coverageFraction: Double) -> AtriaRelativeSkinSignalBlocker? {
        if rowCount < minimumQualifiedRows { return .insufficientRows }
        if coveredMinutes < minimumCoveredMinutes { return .insufficientCoveredMinutes }
        if coverageFraction < minimumCoverageFraction { return .insufficientCoverage }
        return nil
    }

    /// Resolve the published summary from the current qualified night and the
    /// prior qualified nights. Only prior nights sharing the current night's exact
    /// authority count toward the baseline; the current night is excluded from its
    /// own baseline by identity; at most the most recent 30 prior nights are kept;
    /// at least 7 are required before a numeric delta.
    static func resolve(currentNight: AtriaRelativeSkinNightSummary?,
                        priorNights: [AtriaRelativeSkinNightSummary],
                        blockerIfNoCurrent: AtriaRelativeSkinSignalBlocker)
        -> AtriaRelativeSkinSignalSummary {
        guard let current = currentNight else {
            return .init(algorithmVersion: algorithmVersion,
                         currentNight: nil,
                         baselineRawMedian: nil,
                         baselineNightCount: 0,
                         rawDelta: nil,
                         normalizedIndex: nil,
                         motionQualified: false,
                         blocker: blockerIfNoCurrent)
        }
        let qualifiedPrior = priorNights
            .filter { $0.authority == current.authority
                && $0.confirmedSleepID != current.confirmedSleepID }
            .sorted { $0.sleepEnd > $1.sleepEnd }
            .prefix(maximumBaselineNights)
        let priorMedians = qualifiedPrior.map(\.nightlyRawMedian)
        guard priorMedians.count >= minimumPriorNights,
              let baseline = median(priorMedians) else {
            return .init(algorithmVersion: algorithmVersion,
                         currentNight: current,
                         baselineRawMedian: nil,
                         baselineNightCount: priorMedians.count,
                         rawDelta: nil,
                         normalizedIndex: nil,
                         motionQualified: current.motionQualified,
                         blocker: .buildingBaseline)
        }
        let rawDelta = current.nightlyRawMedian - baseline
        let scale = robustScale(priorNightlyMedians: priorMedians)
        let rawIndex = rawDelta / scale
        return .init(algorithmVersion: algorithmVersion,
                     currentNight: current,
                     baselineRawMedian: baseline,
                     baselineNightCount: priorMedians.count,
                     rawDelta: rawDelta,
                     normalizedIndex: rawIndex.isFinite ? rawIndex : nil,
                     motionQualified: current.motionQualified,
                     blocker: nil)
    }

    // MARK: - Pure per-night extraction

    /// One raw skin-sensor sample inside (or around) a confirmed sleep. Kept
    /// deliberately decoupled from `HistoricalArchive.SkinTemperatureRawPoint` so
    /// this computation stays pure and unit-testable with no archive import.
    struct RawSkinSample: Equatable, Sendable {
        let t: Date
        let raw: Int
        let strapIdentifier: String?
    }

    /// Worn-range gate for a single raw sample (WHOOP-4 v24 layout). Values
    /// outside this band are off-body / sensor-fault and never seed a night.
    static let wornRawRange: ClosedRange<Int> = 550...2040

    /// Stable, non-reversible local pseudonym for a strap identifier. Never the
    /// hardware serial itself — only a fold of it, so nights from the same strap
    /// group together without exposing the serial. Empty / missing identifiers
    /// collapse to a single "<unknown>" bucket that never shares a baseline with
    /// an identified strap (the authority still records the layout/offset).
    static func pseudonymousStrapKey(from identifier: String?) -> String {
        let normalized = identifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        guard !normalized.isEmpty else { return "unknown" }
        // FNV-1a 64-bit fold — deterministic across launches, one-way, compact.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in normalized.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return "strap-" + String(hash, radix: 36)
    }

    /// Build one night's raw-median summary from the samples that fall inside a
    /// confirmed sleep window, or the first qualification blocker. Pure: the
    /// caller supplies the already-sliced samples and the exact authority.
    ///
    /// - The night value is the median of per-civil-minute medians of worn-range
    ///   raw, so a dense within-minute sampling burst cannot dominate the night.
    /// - `qualifiedRowCount` counts only worn-range samples.
    /// - `coverageFraction` = covered civil minutes / expected minutes in the
    ///   window (capped at 1.0); expected minutes derive from the window length.
    static func nightSummary(
        samples: [RawSkinSample],
        sleepStart: Date,
        sleepEnd: Date,
        confirmedSleepID: String,
        cycleDay: Date,
        authority: AtriaRelativeSkinSignalAuthority,
        motionQualified: Bool,
        calculatedAt: Date,
        calendar: Calendar = .current
    ) -> Result<AtriaRelativeSkinNightSummary, AtriaRelativeSkinSignalBlocker> {
        guard sleepEnd > sleepStart else { return .failure(.noCurrentRawEvidence) }

        // Bucket worn-range samples by absolute civil minute.
        var minuteBuckets: [Int: [Double]] = [:]
        var qualifiedRowCount = 0
        for sample in samples {
            guard sample.t >= sleepStart, sample.t <= sleepEnd else { continue }
            guard wornRawRange.contains(sample.raw) else { continue }
            qualifiedRowCount += 1
            let minute = Int(sample.t.timeIntervalSince1970 / 60.0)
            minuteBuckets[minute, default: []].append(Double(sample.raw))
        }

        let minuteMedians = minuteBuckets.values.compactMap { median($0) }
        let coveredMinuteCount = minuteMedians.count
        let expectedMinutes = Swift.max(1, Int((sleepEnd.timeIntervalSince(sleepStart) / 60.0).rounded()))
        let coverageFraction = Swift.min(1.0, Double(coveredMinuteCount) / Double(expectedMinutes))

        if let blocker = nightQualifies(
            rowCount: qualifiedRowCount,
            coveredMinutes: coveredMinuteCount,
            coverageFraction: coverageFraction
        ) {
            return .failure(blocker)
        }
        guard let nightMedian = nightlyRawMedian(minuteMedians: minuteMedians) else {
            return .failure(.noCurrentRawEvidence)
        }

        return .success(.init(
            cycleDay: cycleDay,
            confirmedSleepID: confirmedSleepID,
            sleepStart: sleepStart,
            sleepEnd: sleepEnd,
            authority: authority,
            nightlyRawMedian: nightMedian,
            qualifiedRowCount: qualifiedRowCount,
            coveredMinuteCount: coveredMinuteCount,
            coverageFraction: coverageFraction,
            motionQualified: motionQualified,
            calculatedAt: calculatedAt
        ))
    }

    /// Personal-signal directional label (only meaningful once motion-qualified
    /// evidence exists). These are personal-signal zones, not health/fever zones.
    enum DirectionalZone: String, Equatable, Sendable {
        case lowerThanUsual
        case withinUsualRange
        case higherThanUsual
    }

    static func directionalZone(normalizedIndex: Double?) -> DirectionalZone? {
        guard let index = normalizedIndex, index.isFinite else { return nil }
        if index <= -1.5 { return .lowerThanUsual }
        if index >= 1.5 { return .higherThanUsual }
        return .withinUsualRange
    }
}
