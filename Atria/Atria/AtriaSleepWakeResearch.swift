import Foundation

/// Stable ordering for checked sleep projections. Swift's standard-library
/// sort is intentionally retained by every unchecked/legacy entry point; the
/// merge path exists only so a bounded projection can observe cancellation or
/// its absolute deadline while ordering a dense night.
enum AtriaSleepCooperativeAlgorithms {
    @discardableResult
    static func stableSort<Element>(
        _ values: inout [Element],
        shouldContinue: () -> Bool,
        areInIncreasingOrder: (Element, Element) -> Bool
    ) -> Bool {
        guard shouldContinue() else { return false }
        guard values.count > 1 else { return true }
        var source = values
        // Drop the caller's reference before the first merge write so the
        // cancellable path retains two buffers, not three archive-sized copies.
        // Every caller discards the local stage on `false`.
        values.removeAll(keepingCapacity: false)
        var destination = source
        var width = 1
        while width < source.count {
            guard shouldContinue() else { return false }
            var lower = 0
            while lower < source.count {
                let middle = min(lower + width, source.count)
                let upper = min(lower + width + width, source.count)
                var left = lower
                var right = middle
                var output = lower
                while output < upper {
                    if output.isMultiple(of: 256), !shouldContinue() {
                        return false
                    }
                    if left < middle,
                       (right >= upper
                        || !areInIncreasingOrder(source[right], source[left])) {
                        destination[output] = source[left]
                        left += 1
                    } else {
                        destination[output] = source[right]
                        right += 1
                    }
                    output += 1
                }
                lower = upper
            }
            swap(&source, &destination)
            width = width > source.count / 2 ? source.count : width * 2
        }
        guard shouldContinue() else { return false }
        values = source
        return shouldContinue()
    }

    static func stableSort<Element>(
        _ values: inout [Element],
        cooperativeDeadline: AtriaSleepSettlementDeadline,
        areInIncreasingOrder: (Element, Element) -> Bool
    ) throws {
        try cooperativeDeadline.checkpoint()
        guard values.count > 1 else { return }
        var source = values
        values.removeAll(keepingCapacity: false)
        var destination = source
        var width = 1
        while width < source.count {
            try cooperativeDeadline.checkpoint()
            var lower = 0
            while lower < source.count {
                let middle = min(lower + width, source.count)
                let upper = min(lower + width + width, source.count)
                var left = lower
                var right = middle
                var output = lower
                while output < upper {
                    if output.isMultiple(of: 256) {
                        try cooperativeDeadline.checkpoint()
                    }
                    if left < middle,
                       (right >= upper
                        || !areInIncreasingOrder(source[right], source[left])) {
                        destination[output] = source[left]
                        left += 1
                    } else {
                        destination[output] = source[right]
                        right += 1
                    }
                    output += 1
                }
                lower = upper
            }
            swap(&source, &destination)
            width = width > source.count / 2 ? source.count : width * 2
        }
        values = source
        try cooperativeDeadline.checkpoint()
    }
}

enum AtriaSleepWakeResearch {
    struct Result: Equatable {
        let state: String
        let confidence: String
        let reason: String
    }

    struct HeartSample: Equatable {
        let t: Date
        let bpm: Int
    }

    /// A provenance-qualified beat-to-beat interval. Qualification (2A37 /
    /// verified WHOOP4 historical V24 provenance, 300–2000 ms physiologic
    /// clamp) happens at the gather in `sleepStageQualifiedRRInputs`; the
    /// engine treats every sample it receives as already qualified.
    struct RRSample: Equatable {
        let t: Date
        let ms: Double
    }

    /// Test-visible accounting for the bounded stage path. `sampleVisits`
    /// counts actual timestamped HR/motion inspections in the inner algorithm,
    /// not merely the number of inputs handed to it. This makes an accidental
    /// epoch-times-night rescan fail deterministically without wall-clock tests.
    /// `rrVisits` is the RR tachogram loop's OWN ledger (2026-08-20): RR work
    /// must never leak into `sampleVisits`, whose semantics are pinned by the
    /// fallback performance tests.
    struct FallbackStageDiagnostics: Equatable {
        let segments: [SleepStageSegment]
        let sampleVisits: Int
        let rrVisits: Int
    }

    private final class StageWorkCounter {
        private(set) var sampleVisits = 0
        private(set) var rrVisits = 0

        func visit(_ count: Int = 1) {
            sampleVisits += max(0, count)
        }

        func visitRR(_ count: Int = 1) {
            rrVisits += max(0, count)
        }
    }

    /// Research stage output is presentation-eligible only when both streams
    /// stay locally supported. These match the recovered-motion receipt's
    /// maximum tolerated hole and are intentionally stricter than the old
    /// whole-window HR fallback.
    private static let maximumEvidenceGap: TimeInterval = 90
    private static let minimumTimelineCoverageFraction = 0.85
    /// Was 15, which contradicted the invariant the comment above states. The
    /// rest of the stack tolerates 90 s holes — `maximumEvidenceGap` here,
    /// `activeJournalSegmentGapLimit`, `AtriaRecoveredMotionAnalytics`
    /// sufficiency, `AtriaSleepStageIntegrity.validates` — so 15 was the lone
    /// outlier, and it is applied to the WHOLE window: one 16 s hole anywhere
    /// in eight hours failed the entire night's HR support and the hypnogram
    /// came back empty. A strap that drops a couple of seconds of notifications
    /// is the normal case, not a degraded one, so in practice this rejected
    /// nights that had perfectly usable HR. Field report 2026-08-19, item 10.
    private static let maximumHeartRateGap: TimeInterval = 90
    private static let minimumHeartRateSamplesPerMinute = 6.0
    /// RR features exist for an epoch only when at least this many qualified
    /// beats fall inside the exact 30-second epoch (≈0.5 in-epoch coverage at
    /// sleeping heart rates). Below the floor every RR field is nil and the
    /// HR-only rules apply to that epoch — the per-epoch-validity rule
    /// (no interpolation, no borrowing) extended to RR. Wider windows remain
    /// useful only for smoothing after real in-epoch beats anchor the epoch,
    /// exactly like the HR rule at `sampleRange` below.
    private static let minimumQualifiedRRBeatsPerEpoch = 15

    // MARK: P3 decision-refinement constants (2026-08-20, design 1.1 step 4)
    //
    // Every constant below is consulted ONLY when the epoch's own RR is valid
    // (`rrEpochValid`) AND the night produced a median RMSSD reference. An
    // rr-empty run — or any epoch below the 15-beat floor — takes the exact
    // pre-RR decision path: no RR input means no behavior change.

    /// RR-assisted REM edge band: each bound is the existing night REM band's
    /// bound relaxed by a small, documented margin. An epoch inside this
    /// widened shell is admitted as REM only when its local RMSSD is elevated
    /// above the night median (the REM autonomic-variability signature). The
    /// admission runs strictly AFTER every awake rule in `stage()`, so RR can
    /// only ever widen REM recall among epochs already cleared as non-awake —
    /// it can never convert an epoch the awake rules would call awake.
    private static let remEdgeProgressLowerBound = 0.15 // band: 0.18
    private static let remEdgeProgressUpperBound = 0.91 // band: 0.88
    private static let remEdgeDeltaLowerBound = 1.0 // band: 2
    private static let remEdgeDeltaUpperBound = 14.0 // band: 12
    private static let remEdgeVariabilityFloor = 2.4 // band: 3.2
    private static let remEdgeTrendFloor = -1.5 // band: -1 (exclusive)
    /// "Elevated" means STRICTLY greater than the night median times this
    /// factor. The strict comparison keeps a degenerate flat tachogram
    /// (median 0, local 0) from counting as elevated.
    private static let remRMSSDElevationFactor = 1.2
    /// Deep hedge, estimate-lane epochs only (`motionMeasurementValidated ==
    /// false` — deep is the least reliable HR-only call): with valid RR a deep
    /// call must also beat these tightened ceilings AND sit strictly below the
    /// night-median RMSSD. An epoch that matches the legacy deep region but
    /// fails the hedge falls to LIGHT — never sws (which display-folds to
    /// deep) and never awake — so awake seconds are bit-identical before and
    /// after by construction and `reconcilesForPresentation` is unaffected.
    private static let estimateDeepHedgeTrendCeiling = 1.0 // legacy: 1.5
    private static let estimateDeepHedgeVariabilityCeiling = 3.0 // legacy: 3.5

    private struct EpochFeature: Equatable {
        let start: Date
        let end: Date
        let averageHR: Double
        let shortSmoothHR: Double
        let longSmoothHR: Double
        let differenceOfGaussians: Double
        let localVariability: Double
        let progress: Double
        let motionStillnessPrior: Double
        let motionMovementIntensity: Double
        let motionMeasurementValidated: Bool
        // RR tachogram features (2026-08-20, P1). Computed only when
        // `rrEpochValid`; nil otherwise. As of P3, `stage()` consumes
        // `rrRMSSDLocal` (with the once-per-night median) for two strictly
        // refinement-only rules: REM edge admission and the estimate-lane
        // deep hedge. Awake decisions never read any RR field.
        let rrMedianMs: Double?
        let rrRMSSDLocal: Double?
        let rrShortSmooth: Double?
        let rrLongSmooth: Double?
        let rrDoG: Double?
        let rrEpochValid: Bool
    }

    static func classify(duration: TimeInterval,
                         averageHR: Int,
                         restingHR: Int,
                         imuStillnessRatio: Double?,
                         imuMovementIntensity: Double?,
                         strapSteps: Int?,
                         /// A zero step count is useful only after at least one
                         /// strap-motion frame established that the step channel
                         /// was actually observed.  `nil`/false is not zero.
                         strapStepEvidenceAvailable: Bool = false,
                         windowStart: Date? = nil,
                         hrStandardDeviation: Double? = nil,
                         calendar: Calendar = .current) -> Result {
        guard duration >= 20 * 60 else {
            return Result(state: "learning", confidence: "none", reason: "short_window")
        }
        guard let imuStillnessRatio, let imuMovementIntensity else {
            if duration >= 3 * 60 * 60,
               averageHR <= restingHR + 12,
               (hrStandardDeviation ?? .infinity) <= 9,
               let windowStart,
               hrOnlySleepStartReady(windowStart, calendar: calendar) {
                return Result(state: "sleep_research", confidence: "hr_only", reason: "hr_pattern_no_imu")
            }
            return Result(state: "learning", confidence: "none", reason: "imu_missing")
        }
        let lowMotion = imuStillnessRatio >= 0.72 && imuMovementIntensity <= 0.18
        let lowHR = averageHR <= restingHR + 18
        // Do not turn an absent R10 step channel into a measured zero.  That
        // previously let a quiet-looking HR/IMU interval from active wear
        // become `sleep_research`, which can surface as a false nap and can
        // suppress normal activity accounting.  Overnight HR-only handling is
        // deliberately separate above; this is the motion-backed path and
        // requires its independent strap-step evidence.
        guard strapStepEvidenceAvailable, let strapSteps else {
            return Result(state: "learning", confidence: "none", reason: "strap_steps_missing")
        }
        let lowSteps = strapSteps <= max(8, Int(duration / 600))
        if lowMotion && lowHR && lowSteps {
            return Result(state: "sleep_research", confidence: "research", reason: "low_motion_low_hr")
        }
        return Result(state: "wake_research", confidence: "research", reason: "motion_or_hr_active")
    }

    private static func hrOnlySleepStartReady(_ start: Date, calendar: Calendar) -> Bool {
        let hour = calendar.component(.hour, from: start)
        return hour >= 20 || hour <= 3
    }

    static func stageSegments(samples: [HeartSample],
                              start: Date,
                              end: Date,
                              restingHR: Int,
                              isNap: Bool,
                              motionValidated _: Bool,
                              motionEpochs: [AtriaRecoveredMotionEpoch] = [],
                              rrSamples: [RRSample] = [],
                              qualifiedRRCoverageFraction: Double = 0,
                              allowHROnlyEstimate: Bool = false) -> [SleepStageSegment] {
        (try? stageSegmentsCore(samples: samples,
                                start: start,
                                end: end,
                                restingHR: restingHR,
                                isNap: isNap,
                                motionEpochs: motionEpochs,
                                rrSamples: rrSamples,
                                qualifiedRRCoverageFraction: qualifiedRRCoverageFraction,
                                allowHROnlyEstimate: allowHROnlyEstimate,
                                workCounter: nil,
                                cooperativeDeadline: nil)) ?? []
    }

    /// Checked equivalent used only by foreground-authorized bounded work. It
    /// returns the complete legacy-equivalent timeline or throws; a deadline or
    /// cancellation can never publish a partially classified night.
    static func stageSegments(
        samples: [HeartSample],
        start: Date,
        end: Date,
        restingHR: Int,
        isNap: Bool,
        motionValidated _: Bool,
        motionEpochs: [AtriaRecoveredMotionEpoch] = [],
        rrSamples: [RRSample] = [],
        qualifiedRRCoverageFraction: Double = 0,
        allowHROnlyEstimate: Bool = false,
        cooperativeDeadline: AtriaSleepSettlementDeadline
    ) throws -> [SleepStageSegment] {
        try stageSegmentsCore(samples: samples,
                              start: start,
                              end: end,
                              restingHR: restingHR,
                              isNap: isNap,
                              motionEpochs: motionEpochs,
                              rrSamples: rrSamples,
                              qualifiedRRCoverageFraction: qualifiedRRCoverageFraction,
                              allowHROnlyEstimate: allowHROnlyEstimate,
                              workCounter: nil,
                              cooperativeDeadline: cooperativeDeadline)
    }

    private static func stageSegmentsCore(
        samples: [HeartSample],
        start: Date,
        end: Date,
        restingHR: Int,
        isNap: Bool,
        motionEpochs: [AtriaRecoveredMotionEpoch],
        rrSamples: [RRSample] = [],
        // P2 (2026-08-20, design 1.2): consumed ONLY at the estimate lane's
        // mint in `merge()` — coverage ≥ 0.90 mints the strong-RR estimate
        // prefix instead of the plain one. Never admission evidence: no gate
        // above or below reads it, and the motion lane ignores it entirely.
        qualifiedRRCoverageFraction: Double = 0,
        allowHROnlyEstimate: Bool = false,
        workCounter: StageWorkCounter?,
        cooperativeDeadline: AtriaSleepSettlementDeadline?
    ) throws -> [SleepStageSegment] {
        try cooperativeDeadline?.checkpoint()
        let duration = end.timeIntervalSince(start)
        guard duration >= 20 * 60,
              restingHR > 0 else { return [] }

        // A record-level Boolean is not time-aligned evidence. The motion
        // RECEIPT still requires actual recovered epochs covering this exact
        // window, even when a legacy record says `motionValidated == true`.
        // 2026-08-12: insufficient motion no longer discards the night —
        // dense HR alone may still stage, but the output is minted with
        // `SleepStageSegment.hrEstimateIDPrefix` so it can only ever render
        // through the labeled-estimate lane and never claims motion authority.
        // Every other gate below (dense local HR, epoch quorum, dense local
        // timeline evidence) applies identically to both lanes.
        workCounter?.visit(motionEpochs.count)
        let motionProvenance: AtriaRecoveredMotionAnalytics.SleepProvenance
        if let cooperativeDeadline {
            motionProvenance = try AtriaRecoveredMotionAnalytics.sleepProvenance(
                epochs: motionEpochs,
                start: start,
                end: end,
                cooperativeDeadline: cooperativeDeadline
            )
        } else {
            motionProvenance = AtriaRecoveredMotionAnalytics.sleepProvenance(
                epochs: motionEpochs,
                start: start,
                end: end
            )
        }
        let motionBacked = motionProvenance.measurementSufficient
        // The estimate lane is OPT-IN because it is expensive: before it
        // existed, an insufficient-motion window returned [] here at near-zero
        // cost, and hot callers (compact latest-night settlement, review
        // projections) budget their production deadlines around that. Only
        // deliberate lanes — a user-initiated save, the cooperative stage
        // backfill — pay for HR-only staging.
        guard motionBacked || allowHROnlyEstimate else { return [] }

        workCounter?.visit(samples.count)
        let sorted: [HeartSample]
        if let cooperativeDeadline {
            var checked: [HeartSample] = []
            checked.reserveCapacity(samples.count)
            for (index, sample) in samples.enumerated() {
                if index.isMultiple(of: 256) {
                    try cooperativeDeadline.checkpoint()
                }
                if sample.t >= start, sample.t <= end, sample.bpm > 0 {
                    checked.append(sample)
                }
            }
            try AtriaSleepCooperativeAlgorithms.stableSort(
                &checked,
                cooperativeDeadline: cooperativeDeadline,
                areInIncreasingOrder: { $0.t < $1.t }
            )
            sorted = checked
        } else {
            sorted = samples
                .filter { $0.t >= start && $0.t <= end && $0.bpm > 0 }
                .sorted { $0.t < $1.t }
        }
        guard try heartRateEvidenceIsDense(sorted,
                                           start: start,
                                           end: end,
                                           workCounter: workCounter,
                                           cooperativeDeadline: cooperativeDeadline) else {
            return []
        }

        // RR is a refinement input, never admission evidence: every gate above
        // ran without it, so a night that fails closed never pays for RR work.
        // Provenance qualification and the physiologic ms clamp happen at the
        // gather; the engine only re-asserts window bounds and finiteness.
        workCounter?.visitRR(rrSamples.count)
        let orderedRR: [RRSample]
        if rrSamples.isEmpty {
            orderedRR = []
        } else if let cooperativeDeadline {
            var checked: [RRSample] = []
            checked.reserveCapacity(rrSamples.count)
            for (index, sample) in rrSamples.enumerated() {
                if index.isMultiple(of: 256) {
                    try cooperativeDeadline.checkpoint()
                }
                if sample.t >= start, sample.t <= end,
                   sample.ms.isFinite, sample.ms > 0 {
                    checked.append(sample)
                }
            }
            try AtriaSleepCooperativeAlgorithms.stableSort(
                &checked,
                cooperativeDeadline: cooperativeDeadline,
                areInIncreasingOrder: { $0.t < $1.t }
            )
            orderedRR = checked
        } else {
            orderedRR = rrSamples
                .filter { $0.t >= start && $0.t <= end && $0.ms.isFinite && $0.ms > 0 }
                .sorted { $0.t < $1.t }
        }

        let epoch: TimeInterval = 30
        let epochCount = max(1, Int(duration / epoch))
        let features = try epochFeatures(samples: sorted,
                                         rrSamples: orderedRR,
                                         start: start,
                                         end: end,
                                         epochCount: epochCount,
                                         motionEpochs: motionEpochs,
                                         motionBacked: motionBacked,
                                         workCounter: workCounter,
                                         cooperativeDeadline: cooperativeDeadline)
        // P3 (2026-08-20, design 1.1 step 4): the night-level RMSSD reference
        // is computed exactly ONCE per run and handed to every epoch decision —
        // `stage()` never rescans the night. Nil whenever no epoch carries
        // valid RR, which keeps rr-empty runs on the exact pre-RR path.
        let nightMedianRMSSD = try nightMedianLocalRMSSD(
            features: features,
            workCounter: workCounter,
            cooperativeDeadline: cooperativeDeadline
        )
        var staged: [(start: Date, end: Date, stage: SleepStageKind)] = []

        for (index, feature) in features.enumerated() {
            if index.isMultiple(of: 256) {
                try cooperativeDeadline?.checkpoint()
            }
            let stage = stage(feature: feature,
                              restingHR: restingHR,
                              isNap: isNap,
                              nightMedianRMSSD: nightMedianRMSSD)
            staged.append((feature.start, feature.end, stage))
        }

        guard staged.count >= max(8, epochCount / 3) else { return [] }
        let merged = try merge(staged,
                               motionBacked: motionBacked,
                               qualifiedRRCoverageFraction: qualifiedRRCoverageFraction,
                               cooperativeDeadline: cooperativeDeadline)
        return try timelineHasDenseLocalEvidence(merged,
                                                 start: start,
                                                 end: end,
                                                 cooperativeDeadline: cooperativeDeadline)
            ? merged
            : []
    }

    private static func epochFeatures(samples: [HeartSample],
                                      rrSamples: [RRSample] = [],
                                      start: Date,
                                      end: Date,
                                      epochCount: Int,
                                      motionEpochs: [AtriaRecoveredMotionEpoch],
                                      motionBacked: Bool,
                                      workCounter: StageWorkCounter?,
                                      cooperativeDeadline: AtriaSleepSettlementDeadline?) throws -> [EpochFeature] {
        try cooperativeDeadline?.checkpoint()
        let epoch: TimeInterval = 30
        let duration = max(1, end.timeIntervalSince(start))
        let orderedMotionEpochs: [AtriaRecoveredMotionEpoch]
        if let cooperativeDeadline {
            var checked = motionEpochs
            try AtriaSleepCooperativeAlgorithms.stableSort(
                &checked,
                cooperativeDeadline: cooperativeDeadline,
                areInIncreasingOrder: {
                    if $0.start != $1.start { return $0.start < $1.start }
                    return $0.end < $1.end
                }
            )
            orderedMotionEpochs = checked
        } else {
            orderedMotionEpochs = motionEpochs.sorted {
                if $0.start != $1.start { return $0.start < $1.start }
                return $0.end < $1.end
            }
        }
        var nextMotionIndex = 0
        var activeMotionEpochs: [AtriaRecoveredMotionEpoch] = []
        var features: [EpochFeature] = []
        features.reserveCapacity(epochCount)

        for index in 0..<epochCount {
            if index.isMultiple(of: 8) {
                try cooperativeDeadline?.checkpoint()
            }
            let epochStart = start.addingTimeInterval(Double(index) * epoch)
            let epochEnd = index == epochCount - 1 ? end : min(end, epochStart.addingTimeInterval(epoch))
            let center = epochStart.addingTimeInterval(epochEnd.timeIntervalSince(epochStart) / 2)

            // Stage epochs advance monotonically. Retain only motion intervals
            // that can overlap this epoch, then admit newly starting intervals
            // once. The former filter-per-epoch implementation rescanned the
            // complete night of motion for every 30-second output epoch.
            var retainedMotionEpochs: [AtriaRecoveredMotionEpoch] = []
            retainedMotionEpochs.reserveCapacity(activeMotionEpochs.count)
            for (activeIndex, motionEpoch) in activeMotionEpochs.enumerated() {
                if activeIndex.isMultiple(of: 64) {
                    try cooperativeDeadline?.checkpoint()
                }
                workCounter?.visit()
                if motionEpoch.end > epochStart {
                    retainedMotionEpochs.append(motionEpoch)
                }
            }
            activeMotionEpochs = retainedMotionEpochs
            while nextMotionIndex < orderedMotionEpochs.count {
                if nextMotionIndex.isMultiple(of: 64) {
                    try cooperativeDeadline?.checkpoint()
                }
                let motionEpoch = orderedMotionEpochs[nextMotionIndex]
                workCounter?.visit()
                guard motionEpoch.start < epochEnd else { break }
                if motionEpoch.end > epochStart {
                    activeMotionEpochs.append(motionEpoch)
                }
                nextMotionIndex += 1
            }

            let epochRange = try sampleRange(in: samples,
                                             from: epochStart,
                                             through: epochEnd,
                                             workCounter: workCounter,
                                             cooperativeDeadline: cooperativeDeadline)
            // Never borrow a distant HR sample to paint an unsupported epoch.
            // Wider windows remain useful only for smoothing/variability after
            // a real sample anchors this exact 30-second epoch.
            guard !epochRange.isEmpty else { continue }
            let nearbyRange = try sampleRange(in: samples,
                                              from: center.addingTimeInterval(-5 * 60),
                                              through: center.addingTimeInterval(5 * 60),
                                              workCounter: workCounter,
                                              cooperativeDeadline: cooperativeDeadline)
            let averageHR = try averageHeartRate(in: samples,
                                                 range: epochRange,
                                                 workCounter: workCounter,
                                                 cooperativeDeadline: cooperativeDeadline) ?? 0
            let shortSmoothHR = try gaussianSmoothedHR(samples: samples,
                                                       center: center,
                                                       sigma: 120,
                                                       workCounter: workCounter,
                                                       cooperativeDeadline: cooperativeDeadline) ?? averageHR
            let longSmoothHR = try gaussianSmoothedHR(samples: samples,
                                                      center: center,
                                                      sigma: 600,
                                                      workCounter: workCounter,
                                                      cooperativeDeadline: cooperativeDeadline) ?? shortSmoothHR
            let variability = try heartRateStandardDeviation(in: samples,
                                                             range: nearbyRange,
                                                             workCounter: workCounter,
                                                             cooperativeDeadline: cooperativeDeadline)
            let progress = epochStart.timeIntervalSince(start) / duration
            let motion = try motionContext(epochs: activeMotionEpochs,
                                           start: epochStart,
                                           end: epochEnd,
                                           workCounter: workCounter,
                                           cooperativeDeadline: cooperativeDeadline)
            // In the motion-backed lane an epoch without sufficiently
            // covered, validated, time-aligned motion remains blank; a
            // whole-record Boolean cannot fill it. The HR-only ESTIMATE lane
            // (2026-08-12) instead stages such epochs from HR with a neutral
            // motion prior and `motionMeasurementValidated == false`, which
            // routes the classifier to its stricter HR-only awake rule.
            if motionBacked, motion == nil { continue }
            // RR features carry the identical per-epoch validity rule: only
            // real beats inside THIS 30-second epoch can anchor them, and a
            // sparse epoch keeps nil RR fields no matter how dense its
            // neighbors are. RR is never interpolated or borrowed.
            let rrRange = try rrSampleRange(in: rrSamples,
                                            from: epochStart,
                                            through: epochEnd,
                                            workCounter: workCounter,
                                            cooperativeDeadline: cooperativeDeadline)
            let rrEpochValid = rrRange.count >= minimumQualifiedRRBeatsPerEpoch
            var rrMedianMs: Double?
            var rrRMSSDLocal: Double?
            var rrShortSmooth: Double?
            var rrLongSmooth: Double?
            var rrDoG: Double?
            if rrEpochValid {
                rrMedianMs = try rrMedianMilliseconds(in: rrSamples,
                                                      range: rrRange,
                                                      workCounter: workCounter,
                                                      cooperativeDeadline: cooperativeDeadline)
                rrRMSSDLocal = try rrRootMeanSquareSuccessiveDifference(
                    in: rrSamples,
                    range: rrRange,
                    workCounter: workCounter,
                    cooperativeDeadline: cooperativeDeadline
                )
                let short = try gaussianSmoothedRRMs(samples: rrSamples,
                                                     center: center,
                                                     sigma: 120,
                                                     workCounter: workCounter,
                                                     cooperativeDeadline: cooperativeDeadline)
                    ?? rrMedianMs
                let long = try gaussianSmoothedRRMs(samples: rrSamples,
                                                    center: center,
                                                    sigma: 600,
                                                    workCounter: workCounter,
                                                    cooperativeDeadline: cooperativeDeadline)
                    ?? short
                rrShortSmooth = short
                rrLongSmooth = long
                if let short, let long {
                    rrDoG = short - long
                }
            }
            features.append(EpochFeature(start: epochStart,
                                         end: epochEnd,
                                         averageHR: averageHR,
                                         shortSmoothHR: shortSmoothHR,
                                         longSmoothHR: longSmoothHR,
                                         differenceOfGaussians: shortSmoothHR - longSmoothHR,
                                         localVariability: variability,
                                         progress: progress,
                                         motionStillnessPrior: motion?.stillness ?? 1,
                                         motionMovementIntensity: motion?.intensity ?? 0,
                                         motionMeasurementValidated: motion != nil,
                                         rrMedianMs: rrMedianMs,
                                         rrRMSSDLocal: rrRMSSDLocal,
                                         rrShortSmooth: rrShortSmooth,
                                         rrLongSmooth: rrLongSmooth,
                                         rrDoG: rrDoG,
                                         rrEpochValid: rrEpochValid))
        }
        try cooperativeDeadline?.checkpoint()
        return features
    }

    private static func stage(feature: EpochFeature,
                              restingHR: Int,
                              isNap: Bool,
                              nightMedianRMSSD: Double?) -> SleepStageKind {
        let delta = feature.averageHR - Double(restingHR)
        let trendUp = feature.differenceOfGaussians
        let variability = feature.localVariability
        let stillness = feature.motionStillnessPrior
        if delta >= 18 || (trendUp >= 7 && variability >= 4) { return .awake }
        if !feature.motionMeasurementValidated && (delta >= 13 || trendUp >= 5) { return .awake }
        if feature.motionMeasurementValidated,
           (stillness < 0.55 || feature.motionMovementIntensity > 0.35) { return .awake }
        if stillness < 0.7 && variability >= 6 { return .awake }
        // P3 (2026-08-20): the ONLY behavior-changing RR phase. Both RR
        // refinements below are gated strictly on this epoch's own RR validity
        // plus the once-per-night median RMSSD; every awake rule above ran
        // first and never consults RR, so awake decisions are RR-blind by
        // construction. Naps keep their dedicated rules untouched — the
        // design's band/threshold references are the night rules.
        let localRMSSD: Double? = feature.rrEpochValid ? feature.rrRMSSDLocal : nil
        if isNap {
            if feature.progress > 0.20 && delta <= 10 && variability >= 3.5 && trendUp > -1 { return .rem }
            if delta <= 3 && variability <= 3 { return .deep }
            if delta <= 7 && trendUp <= 3 { return .sws }
            return .light
        }
        if feature.progress < 0.06 || feature.progress > 0.94, delta >= 10 { return .awake }
        if feature.progress >= 0.18 && feature.progress <= 0.88 && delta >= 2 && delta <= 12 && variability >= 3.2 && trendUp > -1 {
            return .rem
        }
        // (a) RR-assisted REM edge admission — recall-widening ONLY. Placed
        // strictly after every awake rule and after the untouched legacy REM
        // band: an epoch inside the documented widened shell of that band is
        // admitted as REM when its local RMSSD is elevated above the night
        // median (REM autonomic-variability signature).
        if let localRMSSD, let nightMedianRMSSD,
           localRMSSD > nightMedianRMSSD * remRMSSDElevationFactor,
           feature.progress >= remEdgeProgressLowerBound,
           feature.progress <= remEdgeProgressUpperBound,
           delta >= remEdgeDeltaLowerBound, delta <= remEdgeDeltaUpperBound,
           variability >= remEdgeVariabilityFloor,
           trendUp > remEdgeTrendFloor {
            return .rem
        }
        if delta <= 2 && trendUp <= 1.5 && variability <= 3.5 {
            // (b) Deep hedge — deep is the least reliable HR-only call. On an
            // estimate-lane epoch with valid RR, the legacy deep region must
            // also beat the tightened ceilings and a strictly-below-median
            // RMSSD. A failed hedge falls to LIGHT: never sws (which
            // display-folds to deep) and never awake, so the change is
            // reconcile-neutral by construction. Motion-validated epochs keep
            // the legacy rule verbatim.
            if feature.motionMeasurementValidated { return .deep }
            guard let localRMSSD, let nightMedianRMSSD else { return .deep }
            if trendUp <= estimateDeepHedgeTrendCeiling,
               variability <= estimateDeepHedgeVariabilityCeiling,
               localRMSSD < nightMedianRMSSD {
                return .deep
            }
            return .light
        }
        if delta <= 7 && trendUp <= 3.5 { return .sws }
        return .light
    }

    /// Kept as a test-visible compatibility surface for the former fallback.
    /// It now runs the same fail-closed engine and never expands global HR
    /// statistics across epochs that lack local HR or motion evidence.
    static func fallbackStageDiagnostics(samples: [HeartSample],
                                         start: Date,
                                         end: Date,
                                         restingHR: Int,
                                         isNap: Bool,
                                         motionValidated: Bool,
                                         motionEpochs: [AtriaRecoveredMotionEpoch] = [],
                                         rrSamples: [RRSample] = []) -> FallbackStageDiagnostics {
        _ = motionValidated
        let workCounter = StageWorkCounter()
        return FallbackStageDiagnostics(
            segments: (try? stageSegmentsCore(samples: samples,
                                              start: start,
                                              end: end,
                                              restingHR: restingHR,
                                              isNap: isNap,
                                              motionEpochs: motionEpochs,
                                              rrSamples: rrSamples,
                                              workCounter: workCounter,
                                              cooperativeDeadline: nil)) ?? [],
            sampleVisits: workCounter.sampleVisits,
            rrVisits: workCounter.rrVisits
        )
    }

    /// Test-visible per-epoch RR feature projection (2026-08-20, P1). This
    /// narrow probe lets pure tests pin per-epoch validity (≥15 in-epoch
    /// beats), the no-borrowing rule, and the feature arithmetic without
    /// widening the engine's private surface. (Since P3, `stage()` also
    /// consumes `rrRMSSDLocal` through its refinement-only rules; the probe's
    /// meaning — features as computed, before any decision — is unchanged.)
    struct RRFeatureDiagnostics: Equatable {
        let start: Date
        let end: Date
        let rrEpochValid: Bool
        let rrMedianMs: Double?
        let rrRMSSDLocal: Double?
        let rrShortSmooth: Double?
        let rrLongSmooth: Double?
        let rrDoG: Double?
    }

    static func rrFeatureDiagnosticsForTesting(
        samples: [HeartSample],
        rrSamples: [RRSample],
        start: Date,
        end: Date,
        motionEpochs: [AtriaRecoveredMotionEpoch] = []
    ) -> [RRFeatureDiagnostics] {
        let duration = max(1, end.timeIntervalSince(start))
        let sorted = samples
            .filter { $0.t >= start && $0.t <= end && $0.bpm > 0 }
            .sorted { $0.t < $1.t }
        let orderedRR = rrSamples
            .filter { $0.t >= start && $0.t <= end && $0.ms.isFinite && $0.ms > 0 }
            .sorted { $0.t < $1.t }
        let motionBacked = AtriaRecoveredMotionAnalytics.sleepProvenance(
            epochs: motionEpochs,
            start: start,
            end: end
        ).measurementSufficient
        let epochCount = max(1, Int(duration / 30))
        let features = (try? epochFeatures(samples: sorted,
                                           rrSamples: orderedRR,
                                           start: start,
                                           end: end,
                                           epochCount: epochCount,
                                           motionEpochs: motionEpochs,
                                           motionBacked: motionBacked,
                                           workCounter: nil,
                                           cooperativeDeadline: nil)) ?? []
        return features.map {
            RRFeatureDiagnostics(start: $0.start,
                                 end: $0.end,
                                 rrEpochValid: $0.rrEpochValid,
                                 rrMedianMs: $0.rrMedianMs,
                                 rrRMSSDLocal: $0.rrRMSSDLocal,
                                 rrShortSmooth: $0.rrShortSmooth,
                                 rrLongSmooth: $0.rrLongSmooth,
                                 rrDoG: $0.rrDoG)
        }
    }

    /// Test-visible probe for the dominant checked inner loop. Production calls
    /// this only through `stageSegments`; exposing the narrow probe lets a
    /// deterministic clock prove cancellation occurs inside Gaussian work rather
    /// than merely before or after the stage engine.
    static func checkedGaussianSmoothingForTesting(
        samples: [HeartSample],
        center: Date,
        sigma: TimeInterval,
        cooperativeDeadline: AtriaSleepSettlementDeadline
    ) throws -> Double? {
        try gaussianSmoothedHR(samples: samples,
                               center: center,
                               sigma: sigma,
                               workCounter: nil,
                               cooperativeDeadline: cooperativeDeadline)
    }

    private static func timelineHasDenseLocalEvidence(
        _ segments: [SleepStageSegment],
        start: Date,
        end: Date,
        cooperativeDeadline: AtriaSleepSettlementDeadline?
    ) throws -> Bool {
        try cooperativeDeadline?.checkpoint()
        let duration = end.timeIntervalSince(start)
        guard duration > 0, !segments.isEmpty else { return false }
        var covered: TimeInterval = 0
        var previousEnd = start
        var maximumGap: TimeInterval = 0
        for (index, segment) in segments.enumerated() {
            if index.isMultiple(of: 256) {
                try cooperativeDeadline?.checkpoint()
            }
            guard segment.end > segment.start,
                  segment.start >= previousEnd,
                  segment.start >= start,
                  segment.end <= end else { return false }
            maximumGap = max(maximumGap, segment.start.timeIntervalSince(previousEnd))
            covered += segment.duration
            previousEnd = segment.end
        }
        maximumGap = max(maximumGap, end.timeIntervalSince(previousEnd))
        return covered / duration >= minimumTimelineCoverageFraction
            && maximumGap <= maximumEvidenceGap
    }

    private static func heartRateEvidenceIsDense(
        _ samples: [HeartSample],
        start: Date,
        end: Date,
        workCounter: StageWorkCounter?,
        cooperativeDeadline: AtriaSleepSettlementDeadline?
    ) throws -> Bool {
        try cooperativeDeadline?.checkpoint()
        let duration = end.timeIntervalSince(start)
        guard duration > 0,
              let first = samples.first,
              let last = samples.last else { return false }
        let requiredSamples = Int(ceil(
            duration / 60 * minimumHeartRateSamplesPerMinute
        ))
        guard samples.count >= requiredSamples,
              first.t.timeIntervalSince(start) <= maximumHeartRateGap,
              end.timeIntervalSince(last.t) <= maximumHeartRateGap else {
            return false
        }
        for index in 1..<samples.count {
            if index.isMultiple(of: 256) {
                try cooperativeDeadline?.checkpoint()
            }
            workCounter?.visit(2)
            if samples[index].t.timeIntervalSince(samples[index - 1].t) > maximumHeartRateGap {
                return false
            }
        }
        return true
    }

    private static func motionContext(
        epochs: [AtriaRecoveredMotionEpoch],
        start: Date,
        end: Date,
        workCounter: StageWorkCounter?,
        cooperativeDeadline: AtriaSleepSettlementDeadline?
    ) throws -> (stillness: Double, intensity: Double)? {
        struct MotionSupport {
            var start: Date
            var end: Date
            let stillness: Double
            let intensity: Double
        }

        try cooperativeDeadline?.checkpoint()
        let duration = end.timeIntervalSince(start)
        guard duration > 0 else { return nil }
        let support: [MotionSupport]
        if let cooperativeDeadline {
            var checked: [MotionSupport] = []
            checked.reserveCapacity(epochs.count)
            for (index, epoch) in epochs.enumerated() {
                if index.isMultiple(of: 64) {
                    try cooperativeDeadline.checkpoint()
                }
                workCounter?.visit()
                guard epoch.measurementValidated,
                      epoch.end > start,
                      epoch.start < end,
                      let stillness = epoch.stillnessRatio,
                      let intensity = epoch.movementIntensity,
                      stillness.isFinite,
                      intensity.isFinite else { continue }
                let lower = max(start, epoch.start)
                let upper = min(end, epoch.end)
                guard upper > lower else { continue }
                checked.append(MotionSupport(start: lower,
                                             end: upper,
                                             stillness: stillness,
                                             intensity: intensity))
            }
            try AtriaSleepCooperativeAlgorithms.stableSort(
                &checked,
                cooperativeDeadline: cooperativeDeadline,
                areInIncreasingOrder: {
                    if $0.start != $1.start { return $0.start < $1.start }
                    return $0.end < $1.end
                }
            )
            support = checked
        } else {
            support = epochs.compactMap { epoch -> MotionSupport? in
                workCounter?.visit()
                guard epoch.measurementValidated,
                      epoch.end > start,
                      epoch.start < end,
                      let stillness = epoch.stillnessRatio,
                      let intensity = epoch.movementIntensity,
                      stillness.isFinite,
                      intensity.isFinite else { return nil }
                let lower = max(start, epoch.start)
                let upper = min(end, epoch.end)
                guard upper > lower else { return nil }
                return MotionSupport(start: lower,
                                     end: upper,
                                     stillness: stillness,
                                     intensity: intensity)
            }.sorted {
                if $0.start != $1.start { return $0.start < $1.start }
                return $0.end < $1.end
            }
        }

        // Compact latest-night preparation can attach the same recovered epoch
        // to both saved sessions at a reconnect boundary. Count identical
        // support once. If overlapping projections disagree, that wall-clock
        // interval has no single measurement authority, so withhold the entire
        // 30-second stage epoch instead of averaging a conflict into precision.
        var uniqueSupport: [MotionSupport] = []
        uniqueSupport.reserveCapacity(support.count)
        for (index, candidate) in support.enumerated() {
            if index.isMultiple(of: 64) {
                try cooperativeDeadline?.checkpoint()
            }
            workCounter?.visit()
            guard var previous = uniqueSupport.last else {
                uniqueSupport.append(candidate)
                continue
            }
            let overlaps = candidate.start < previous.end
            let sameMeasurement = candidate.stillness == previous.stillness
                && candidate.intensity == previous.intensity
            if overlaps {
                guard sameMeasurement else { return nil }
                previous.end = max(previous.end, candidate.end)
                uniqueSupport[uniqueSupport.count - 1] = previous
            } else if candidate.start == previous.end, sameMeasurement {
                previous.end = candidate.end
                uniqueSupport[uniqueSupport.count - 1] = previous
            } else {
                uniqueSupport.append(candidate)
            }
        }

        var covered: TimeInterval = 0
        var weightedStillness = 0.0
        var weightedIntensity = 0.0
        for (index, interval) in uniqueSupport.enumerated() {
            if index.isMultiple(of: 64) {
                try cooperativeDeadline?.checkpoint()
            }
            workCounter?.visit()
            let intervalDuration = interval.end.timeIntervalSince(interval.start)
            covered += intervalDuration
            weightedStillness += interval.stillness * intervalDuration
            weightedIntensity += interval.intensity * intervalDuration
        }
        guard covered / duration >= 0.80 else { return nil }
        try cooperativeDeadline?.checkpoint()
        return (weightedStillness / covered, weightedIntensity / covered)
    }

    private static func gaussianSmoothedHR(samples: [HeartSample],
                                           center: Date,
                                           sigma: TimeInterval,
                                           workCounter: StageWorkCounter?,
                                           cooperativeDeadline: AtriaSleepSettlementDeadline?) throws -> Double? {
        try cooperativeDeadline?.checkpoint()
        guard sigma > 0 else { return nil }
        let radius = sigma * 3
        let range = try sampleRange(in: samples,
                                    from: center.addingTimeInterval(-radius),
                                    through: center.addingTimeInterval(radius),
                                    workCounter: workCounter,
                                    cooperativeDeadline: cooperativeDeadline)
        guard !range.isEmpty else { return nil }
        var weighted = 0.0
        var weights = 0.0
        for index in range {
            if index.isMultiple(of: 256) {
                try cooperativeDeadline?.checkpoint()
            }
            workCounter?.visit()
            let sample = samples[index]
            let distance = sample.t.timeIntervalSince(center)
            let weight = exp(-0.5 * pow(distance / sigma, 2))
            weighted += Double(sample.bpm) * weight
            weights += weight
        }
        try cooperativeDeadline?.checkpoint()
        guard weights > 0 else { return nil }
        return weighted / weights
    }

    private static func sampleRange(in samples: [HeartSample],
                                    from start: Date,
                                    through end: Date,
                                    workCounter: StageWorkCounter?,
                                    cooperativeDeadline: AtriaSleepSettlementDeadline?) throws -> Range<Int> {
        try cooperativeDeadline?.checkpoint()
        var lowerLow = 0
        var lowerHigh = samples.count
        while lowerLow < lowerHigh {
            let middle = (lowerLow + lowerHigh) / 2
            workCounter?.visit()
            if samples[middle].t < start {
                lowerLow = middle + 1
            } else {
                lowerHigh = middle
            }
        }

        var upperLow = lowerLow
        var upperHigh = samples.count
        while upperLow < upperHigh {
            let middle = (upperLow + upperHigh) / 2
            workCounter?.visit()
            if samples[middle].t <= end {
                upperLow = middle + 1
            } else {
                upperHigh = middle
            }
        }
        try cooperativeDeadline?.checkpoint()
        return lowerLow..<upperLow
    }

    private static func averageHeartRate(in samples: [HeartSample],
                                         range: Range<Int>,
                                         workCounter: StageWorkCounter?,
                                         cooperativeDeadline: AtriaSleepSettlementDeadline?) throws -> Double? {
        guard !range.isEmpty else { return nil }
        var total = 0.0
        for index in range {
            if index.isMultiple(of: 256) {
                try cooperativeDeadline?.checkpoint()
            }
            workCounter?.visit()
            total += Double(samples[index].bpm)
        }
        return total / Double(range.count)
    }

    private static func heartRateStandardDeviation(in samples: [HeartSample],
                                                   range: Range<Int>,
                                                   workCounter: StageWorkCounter?,
                                                   cooperativeDeadline: AtriaSleepSettlementDeadline?) throws -> Double {
        guard range.count >= 2,
              let mean = try averageHeartRate(in: samples,
                                              range: range,
                                              workCounter: workCounter,
                                              cooperativeDeadline: cooperativeDeadline) else { return 0 }
        var squaredDeltaTotal = 0.0
        for index in range {
            if index.isMultiple(of: 256) {
                try cooperativeDeadline?.checkpoint()
            }
            workCounter?.visit()
            let delta = Double(samples[index].bpm) - mean
            squaredDeltaTotal += delta * delta
        }
        return sqrt(squaredDeltaTotal / Double(range.count))
    }

    // MARK: - RR tachogram helpers (2026-08-20, P1)
    // Deliberate parallels of the HR helpers above, typed for `RRSample` and
    // accounted through `rrVisits` ONLY — never `sampleVisits`, whose values
    // are pinned by the fallback performance tests.

    private static func rrSampleRange(in samples: [RRSample],
                                      from start: Date,
                                      through end: Date,
                                      workCounter: StageWorkCounter?,
                                      cooperativeDeadline: AtriaSleepSettlementDeadline?) throws -> Range<Int> {
        try cooperativeDeadline?.checkpoint()
        var lowerLow = 0
        var lowerHigh = samples.count
        while lowerLow < lowerHigh {
            let middle = (lowerLow + lowerHigh) / 2
            workCounter?.visitRR()
            if samples[middle].t < start {
                lowerLow = middle + 1
            } else {
                lowerHigh = middle
            }
        }

        var upperLow = lowerLow
        var upperHigh = samples.count
        while upperLow < upperHigh {
            let middle = (upperLow + upperHigh) / 2
            workCounter?.visitRR()
            if samples[middle].t <= end {
                upperLow = middle + 1
            } else {
                upperHigh = middle
            }
        }
        try cooperativeDeadline?.checkpoint()
        return lowerLow..<upperLow
    }

    /// Median beat interval within one epoch's local range. Even counts take
    /// the mean of the two central values.
    private static func rrMedianMilliseconds(in samples: [RRSample],
                                             range: Range<Int>,
                                             workCounter: StageWorkCounter?,
                                             cooperativeDeadline: AtriaSleepSettlementDeadline?) throws -> Double? {
        guard !range.isEmpty else { return nil }
        var values: [Double] = []
        values.reserveCapacity(range.count)
        for index in range {
            if index.isMultiple(of: 256) {
                try cooperativeDeadline?.checkpoint()
            }
            workCounter?.visitRR()
            values.append(samples[index].ms)
        }
        values.sort()
        try cooperativeDeadline?.checkpoint()
        let middle = values.count / 2
        if values.count.isMultiple(of: 2) {
            return (values[middle - 1] + values[middle]) / 2
        }
        return values[middle]
    }

    /// RMSSD over the successive differences of consecutive beats INSIDE the
    /// epoch's local range only — differences never span an epoch's borrowed
    /// neighbors.
    private static func rrRootMeanSquareSuccessiveDifference(
        in samples: [RRSample],
        range: Range<Int>,
        workCounter: StageWorkCounter?,
        cooperativeDeadline: AtriaSleepSettlementDeadline?
    ) throws -> Double? {
        guard range.count >= 2 else { return nil }
        var squaredDifferenceTotal = 0.0
        for index in (range.lowerBound + 1)..<range.upperBound {
            if index.isMultiple(of: 256) {
                try cooperativeDeadline?.checkpoint()
            }
            workCounter?.visitRR(2)
            let difference = samples[index].ms - samples[index - 1].ms
            squaredDifferenceTotal += difference * difference
        }
        return sqrt(squaredDifferenceTotal / Double(range.count - 1))
    }

    /// The night-level RMSSD reference for the P3 decision refinements:
    /// the median of every rr-valid epoch's local RMSSD (awake epochs
    /// included — determinism over cleverness), computed exactly once per
    /// stage run in `stageSegmentsCore` and passed into `stage()`, which must
    /// never rescan the night per epoch. Nil when no epoch carries valid RR,
    /// so an rr-empty run records ZERO RR work here and every RR refinement
    /// stays inert.
    private static func nightMedianLocalRMSSD(
        features: [EpochFeature],
        workCounter: StageWorkCounter?,
        cooperativeDeadline: AtriaSleepSettlementDeadline?
    ) throws -> Double? {
        var values: [Double] = []
        values.reserveCapacity(features.count)
        for (index, feature) in features.enumerated() {
            if index.isMultiple(of: 256) {
                try cooperativeDeadline?.checkpoint()
            }
            guard feature.rrEpochValid,
                  let rmssd = feature.rrRMSSDLocal else { continue }
            workCounter?.visitRR()
            values.append(rmssd)
        }
        guard !values.isEmpty else { return nil }
        if let cooperativeDeadline {
            try AtriaSleepCooperativeAlgorithms.stableSort(
                &values,
                cooperativeDeadline: cooperativeDeadline,
                areInIncreasingOrder: <
            )
        } else {
            values.sort()
        }
        try cooperativeDeadline?.checkpoint()
        let middle = values.count / 2
        if values.count.isMultiple(of: 2) {
            return (values[middle - 1] + values[middle]) / 2
        }
        return values[middle]
    }

    private static func gaussianSmoothedRRMs(samples: [RRSample],
                                             center: Date,
                                             sigma: TimeInterval,
                                             workCounter: StageWorkCounter?,
                                             cooperativeDeadline: AtriaSleepSettlementDeadline?) throws -> Double? {
        try cooperativeDeadline?.checkpoint()
        guard sigma > 0 else { return nil }
        let radius = sigma * 3
        let range = try rrSampleRange(in: samples,
                                      from: center.addingTimeInterval(-radius),
                                      through: center.addingTimeInterval(radius),
                                      workCounter: workCounter,
                                      cooperativeDeadline: cooperativeDeadline)
        guard !range.isEmpty else { return nil }
        var weighted = 0.0
        var weights = 0.0
        for index in range {
            if index.isMultiple(of: 256) {
                try cooperativeDeadline?.checkpoint()
            }
            workCounter?.visitRR()
            let sample = samples[index]
            let distance = sample.t.timeIntervalSince(center)
            let weight = exp(-0.5 * pow(distance / sigma, 2))
            weighted += sample.ms * weight
            weights += weight
        }
        try cooperativeDeadline?.checkpoint()
        guard weights > 0 else { return nil }
        return weighted / weights
    }

    private static func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func standardDeviation(_ values: [Double]) -> Double {
        guard values.count >= 2, let mean = average(values) else { return 0 }
        let variance = values.reduce(0) { total, value in
            total + pow(value - mean, 2)
        } / Double(values.count)
        return sqrt(variance)
    }

    private static func merge(
        _ staged: [(start: Date, end: Date, stage: SleepStageKind)],
        motionBacked: Bool,
        qualifiedRRCoverageFraction: Double,
        cooperativeDeadline: AtriaSleepSettlementDeadline?
    ) throws -> [SleepStageSegment] {
        try cooperativeDeadline?.checkpoint()
        // Provenance is encoded in the segment id itself so every downstream
        // consumer (receipt checks, duration credit, migration preservation)
        // can distinguish the lanes without trusting record-level flags.
        // P2 (2026-08-20, design 1.2): the estimate lane splits into two
        // display-confidence tiers by the window's qualified-RR coverage —
        // ≥ 0.90 (inclusive, same grammar as the 0.60 floors) mints the
        // strong-RR estimate prefix. Both estimate prefixes route through
        // the `allHREstimateProvenance` choke point, so the duration-credit
        // fence, backfill hygiene, and Night downgrade gates treat the tiers
        // identically; the tier changes label copy only. The motion lane's
        // prefix is deliberately untouched so
        // `hasTimeAlignedResearchStageReceipt` semantics never move.
        let provenancePrefix: String
        if motionBacked {
            provenancePrefix = SleepStageSegment.motionReceiptIDPrefix
        } else if qualifiedRRCoverageFraction >= 0.90 {
            provenancePrefix = SleepStageSegment.hrEstimateStrongRRIDPrefix
        } else {
            provenancePrefix = SleepStageSegment.hrEstimateIDPrefix
        }
        var merged: [(start: Date, end: Date, stage: SleepStageKind)] = []
        for (index, item) in staged.enumerated() {
            if index.isMultiple(of: 256) {
                try cooperativeDeadline?.checkpoint()
            }
            // NOTE: must peek at `merged.last` (not `popLast()`) — popping before the
            // stage/adjacency check unconditionally discards the previous run when the
            // check fails, collapsing the whole segmentation down to just the final run.
            if let last = merged.last, last.stage == item.stage, item.start.timeIntervalSince(last.end) <= 1 {
                merged[merged.count - 1].end = item.end
            } else {
                merged.append(item)
            }
        }
        if cooperativeDeadline == nil {
            return merged.enumerated().map { index, item in
                SleepStageSegment(id: "\(provenancePrefix)\(Int(item.start.timeIntervalSince1970))-\(index)-\(item.stage.rawValue)",
                                  start: item.start,
                                  end: item.end,
                                  stage: item.stage)
            }
        }
        var segments: [SleepStageSegment] = []
        segments.reserveCapacity(merged.count)
        for (index, item) in merged.enumerated() {
            if index.isMultiple(of: 256) {
                try cooperativeDeadline?.checkpoint()
            }
            segments.append(SleepStageSegment(
                id: "\(provenancePrefix)\(Int(item.start.timeIntervalSince1970))-\(index)-\(item.stage.rawValue)",
                start: item.start,
                end: item.end,
                stage: item.stage
            ))
        }
        try cooperativeDeadline?.checkpoint()
        return segments
    }
}
