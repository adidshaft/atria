import Foundation

/// Fail-closed authority for step evidence that spans a historical gap.
///
/// WHOOP 4 historical `0x2f` rows currently expose approximately 1 Hz gravity,
/// not the full-rate R10 motion stream used by Atria's live pedometer and not a
/// decoded on-strap cumulative step counter. Those rows are useful motion
/// evidence, but they are never step evidence here.
enum AtriaHistoricalStepRecovery {
    static let algorithmVersion = "historical-step-recovery-v1"

    enum State: String, Codable, Equatable, Sendable {
        case exactRecovered = "exact_recovered"
        case partialObserved = "partial_observed"
        case missing
    }

    enum Confidence: String, Codable, Equatable, Sendable {
        case exact
        case preliminary
        case unavailable
    }

    enum Provenance: String, Codable, Equatable, Sendable {
        /// Reserved for a decoded, validated counter produced on the strap.
        case whoop4NativeCumulativeCounter = "whoop4_native_cumulative_counter"
        /// Atria's full-rate, connected R10 streaming detector.
        case r10LivePedometerPreliminary = "r10_live_pedometer_preliminary"
        /// Downloaded historical gravity. Explicitly not step-capable.
        case whoop4HistoricalGravity1Hz = "whoop4_historical_gravity_1hz"
    }

    enum Reason: String, Codable, Equatable, Sendable {
        case exactNativeCounterDelta = "exact_native_counter_delta"
        case noStepCapableEvidence = "no_step_capable_evidence"
        case historicalGravityNotStepCapable = "historical_gravity_not_step_capable"
        case nativeCounterUnvalidated = "native_counter_unvalidated"
        case nativeCounterIntervalMismatch = "native_counter_interval_mismatch"
        case nativeCounterEpochMismatch = "native_counter_epoch_mismatch"
        case nativeCounterRegression = "native_counter_regression"
        case nativeCounterImplausibleCadence = "native_counter_implausible_cadence"
        case localLedgerOnly = "local_ledger_only"
        case ambiguousLocalLedgerEvidence = "ambiguous_local_ledger_evidence"
        case invalidGap = "invalid_gap"
    }

    struct Configuration: Codable, Equatable, Sendable {
        /// This is only an integrity ceiling for an already decoded native
        /// counter. It is not an estimator and is never used to create steps.
        let maximumStepsPerSecond: Double

        static let production = Configuration(maximumStepsPerSecond: 8)
    }

    struct NativeCounterEvidence: Codable, Equatable, Sendable {
        let start: Date
        let end: Date
        let startCount: Int64
        let endCount: Int64
        /// Must remain identical across both endpoints. Counter resets and
        /// wraps require a new epoch rather than guessed rollover arithmetic.
        let startCounterEpochID: String
        let endCounterEpochID: String
        let provenance: Provenance
        let validationAuthority: String
        let validated: Bool
    }

    struct LocalLedgerEvidence: Codable, Equatable, Sendable {
        let start: Date
        let end: Date
        let adjustedStepDelta: Int
        let rawStepDelta: Int
        let provenance: Provenance
        let detectorState: String?
    }

    struct Result: Codable, Equatable, Sendable {
        let algorithmVersion: String
        let gapStart: Date
        let gapEnd: Date
        let state: State
        let confidence: Confidence
        /// Populated only by validated native counter evidence whose interval
        /// exactly equals the requested gap.
        let recoveredStepDelta: Int?
        /// Connected R10 detector evidence is retained diagnostically, but it
        /// must never be presented as recovered disconnected-time steps.
        let observedPreliminaryStepDelta: Int
        let observedPreliminaryRawStepDelta: Int
        let observedCoverageSeconds: Int
        let missingCoverageSeconds: Int
        let provenance: [Provenance]
        let reason: Reason
    }

    /// Historical gravity cannot safely produce a step delta. Keeping this as
    /// the aggregate builder's sole entry point makes that limitation explicit
    /// and prevents an accidental future promotion of motion rows to steps.
    static func stepDeltaFromHistoricalGravity() -> Int? { nil }

    /// Converts two local ledger checkpoints into explicitly preliminary
    /// observation evidence. The ledger is Atria's connected R10 detector
    /// checkpoint, not a strap-native counter, so this function never upgrades
    /// the result to exact recovered steps.
    static func localLedgerEvidence(
        before: AtriaStrapStepLedger.Record,
        after: AtriaStrapStepLedger.Record
    ) -> LocalLedgerEvidence? {
        guard after.updatedAt > before.updatedAt,
              after.cumulativeSteps >= before.cumulativeSteps,
              after.cumulativeRawSteps >= before.cumulativeRawSteps else {
            return nil
        }
        return .init(
            start: before.updatedAt,
            end: after.updatedAt,
            adjustedStepDelta: after.cumulativeSteps - before.cumulativeSteps,
            rawStepDelta: after.cumulativeRawSteps - before.cumulativeRawSteps,
            provenance: .r10LivePedometerPreliminary,
            detectorState: after.state
        )
    }

    static func recover(
        gap: DateInterval,
        nativeCounter: NativeCounterEvidence? = nil,
        localLedger: [LocalLedgerEvidence] = [],
        historicalGravityRows: Int = 0,
        configuration: Configuration = .production
    ) -> Result {
        guard valid(gap: gap),
              configuration.maximumStepsPerSecond.isFinite,
              configuration.maximumStepsPerSecond > 0 else {
            return missing(gap: gap, reason: .invalidGap)
        }

        if let nativeCounter {
            if let rejection = nativeRejection(
                nativeCounter,
                gap: gap,
                configuration: configuration
            ) {
                return missing(gap: gap, reason: rejection,
                               provenance: [nativeCounter.provenance])
            }
            let delta64 = nativeCounter.endCount - nativeCounter.startCount
            guard let delta = Int(exactly: delta64) else {
                return missing(gap: gap, reason: .nativeCounterRegression,
                               provenance: [nativeCounter.provenance])
            }
            return .init(
                algorithmVersion: algorithmVersion,
                gapStart: gap.start,
                gapEnd: gap.end,
                state: .exactRecovered,
                confidence: .exact,
                recoveredStepDelta: delta,
                observedPreliminaryStepDelta: 0,
                observedPreliminaryRawStepDelta: 0,
                observedCoverageSeconds: 0,
                missingCoverageSeconds: 0,
                provenance: [.whoop4NativeCumulativeCounter],
                reason: .exactNativeCounterDelta
            )
        }

        switch preliminarySummary(localLedger, within: gap) {
        case let .valid(adjusted, raw, coverage) where coverage > 0:
            let gapSeconds = roundedSeconds(gap.duration)
            return .init(
                algorithmVersion: algorithmVersion,
                gapStart: gap.start,
                gapEnd: gap.end,
                state: .partialObserved,
                confidence: .preliminary,
                recoveredStepDelta: nil,
                observedPreliminaryStepDelta: adjusted,
                observedPreliminaryRawStepDelta: raw,
                observedCoverageSeconds: coverage,
                missingCoverageSeconds: max(0, gapSeconds - coverage),
                provenance: [.r10LivePedometerPreliminary],
                reason: .localLedgerOnly
            )
        case .ambiguous:
            return missing(gap: gap, reason: .ambiguousLocalLedgerEvidence,
                           provenance: [.r10LivePedometerPreliminary])
        case .valid:
            let reason: Reason = historicalGravityRows > 0
                ? .historicalGravityNotStepCapable
                : .noStepCapableEvidence
            let provenance: [Provenance] = historicalGravityRows > 0
                ? [.whoop4HistoricalGravity1Hz]
                : []
            return missing(gap: gap, reason: reason, provenance: provenance)
        }
    }

    private enum PreliminarySummary {
        case valid(adjusted: Int, raw: Int, coverage: Int)
        case ambiguous
    }

    private static func preliminarySummary(
        _ evidence: [LocalLedgerEvidence],
        within gap: DateInterval
    ) -> PreliminarySummary {
        let sorted = evidence.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.end < $1.end
        }
        var previousEnd: Date?
        var adjusted = 0
        var raw = 0
        var coverage = 0
        for item in sorted {
            guard item.provenance == .r10LivePedometerPreliminary,
                  item.start >= gap.start,
                  item.end <= gap.end,
                  item.end > item.start,
                  item.adjustedStepDelta >= 0,
                  item.rawStepDelta >= 0,
                  item.adjustedStepDelta <= item.rawStepDelta,
                  previousEnd.map({ item.start >= $0 }) ?? true,
                  let nextAdjusted = adding(adjusted, item.adjustedStepDelta),
                  let nextRaw = adding(raw, item.rawStepDelta),
                  let nextCoverage = adding(coverage, roundedSeconds(item.end.timeIntervalSince(item.start))) else {
                return .ambiguous
            }
            adjusted = nextAdjusted
            raw = nextRaw
            coverage = nextCoverage
            previousEnd = item.end
        }
        return .valid(adjusted: adjusted, raw: raw, coverage: coverage)
    }

    private static func nativeRejection(
        _ evidence: NativeCounterEvidence,
        gap: DateInterval,
        configuration: Configuration
    ) -> Reason? {
        guard evidence.validated,
              evidence.provenance == .whoop4NativeCumulativeCounter,
              !evidence.validationAuthority.isEmpty else {
            return .nativeCounterUnvalidated
        }
        guard evidence.start == gap.start, evidence.end == gap.end else {
            return .nativeCounterIntervalMismatch
        }
        guard !evidence.startCounterEpochID.isEmpty,
              evidence.startCounterEpochID == evidence.endCounterEpochID else {
            return .nativeCounterEpochMismatch
        }
        guard evidence.startCount >= 0,
              evidence.endCount >= evidence.startCount else {
            return .nativeCounterRegression
        }
        let delta = Double(evidence.endCount - evidence.startCount)
        let ceiling = gap.duration * configuration.maximumStepsPerSecond
        guard delta.isFinite, ceiling.isFinite, delta <= ceiling.rounded(.up) else {
            return .nativeCounterImplausibleCadence
        }
        return nil
    }

    private static func valid(gap: DateInterval) -> Bool {
        gap.end > gap.start && gap.duration.isFinite && gap.duration <= Double(Int.max)
    }

    private static func missing(
        gap: DateInterval,
        reason: Reason,
        provenance: [Provenance] = []
    ) -> Result {
        .init(
            algorithmVersion: algorithmVersion,
            gapStart: gap.start,
            gapEnd: gap.end,
            state: .missing,
            confidence: .unavailable,
            recoveredStepDelta: nil,
            observedPreliminaryStepDelta: 0,
            observedPreliminaryRawStepDelta: 0,
            observedCoverageSeconds: 0,
            missingCoverageSeconds: valid(gap: gap) ? roundedSeconds(gap.duration) : 0,
            provenance: provenance,
            reason: reason
        )
    }

    private static func roundedSeconds(_ duration: TimeInterval) -> Int {
        guard duration.isFinite, duration > 0, duration <= Double(Int.max) else { return 0 }
        return Int(duration.rounded())
    }

    private static func adding(_ lhs: Int, _ rhs: Int) -> Int? {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? nil : sum
    }
}
