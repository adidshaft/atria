import Foundation

/// Pure reconstruction of a persisted active-session journal.
///
/// This module deliberately has no CoreBluetooth dependency. It validates and
/// transforms immutable journal input off the main actor; `AtriaBLEManager`
/// remains responsible only for scheduling the read and publishing the result.
enum AtriaActiveSessionRestorePreparer {
    struct ResearchAggregates: Equatable, Sendable {
        let sensorProbeFrames: Int
        let spo2CandidateFrames: Int
        let skinTempCandidateFrames: Int
        let skinTempCandidateValueSum: Int
        let skinTempCandidateValueCount: Int
        /// RESEARCH-ONLY SpO2 candidate byte-value capture at the two historical
        /// hypotheses (offsets 64/66). Sum+count so a mean can be computed and
        /// cross-checked against a reference app. Never an SpO2 percentage.
        let spo2Offset64ValueSum: Int
        let spo2Offset64ValueCount: Int
        let spo2Offset66ValueSum: Int
        let spo2Offset66ValueCount: Int
        let strapSteps: Int
        let strapRawSteps: Int
        let strapDeviceTimestamp: UInt32?
        let strapStepState: String?
        /// RESEARCH-ONLY gyro-cadence shadow steps for the live session.
        /// Validation evidence only — never feeds a user-facing count.
        let gyroCadenceResearchSteps: Int
        /// Distinguishes a legacy journal with no gyro field from a validated
        /// zero-step gyro observation. Collapsing both to integer zero caused
        /// restored sessions to falsely publish `r10_live_validated`.
        let hasGyroCadenceResearchEvidence: Bool

        init(sensorProbeFrames: Int,
             spo2CandidateFrames: Int,
             skinTempCandidateFrames: Int,
             skinTempCandidateValueSum: Int,
             skinTempCandidateValueCount: Int,
             spo2Offset64ValueSum: Int = 0,
             spo2Offset64ValueCount: Int = 0,
             spo2Offset66ValueSum: Int = 0,
             spo2Offset66ValueCount: Int = 0,
             strapSteps: Int = 0,
             strapRawSteps: Int = 0,
             strapDeviceTimestamp: UInt32? = nil,
             strapStepState: String? = nil,
             gyroCadenceResearchSteps: Int = 0,
             hasGyroCadenceResearchEvidence: Bool = false) {
            self.sensorProbeFrames = sensorProbeFrames
            self.spo2CandidateFrames = spo2CandidateFrames
            self.skinTempCandidateFrames = skinTempCandidateFrames
            self.skinTempCandidateValueSum = skinTempCandidateValueSum
            self.skinTempCandidateValueCount = skinTempCandidateValueCount
            self.spo2Offset64ValueSum = spo2Offset64ValueSum
            self.spo2Offset64ValueCount = spo2Offset64ValueCount
            self.spo2Offset66ValueSum = spo2Offset66ValueSum
            self.spo2Offset66ValueCount = spo2Offset66ValueCount
            self.strapSteps = strapSteps
            self.strapRawSteps = strapRawSteps
            self.strapDeviceTimestamp = strapDeviceTimestamp
            self.strapStepState = strapStepState
            self.gyroCadenceResearchSteps = gyroCadenceResearchSteps
            self.hasGyroCadenceResearchEvidence = hasGyroCadenceResearchEvidence
        }

        static let zero = ResearchAggregates(sensorProbeFrames: 0,
                                             spo2CandidateFrames: 0,
                                             skinTempCandidateFrames: 0,
                                             skinTempCandidateValueSum: 0,
                                             skinTempCandidateValueCount: 0,
                                             spo2Offset64ValueSum: 0,
                                             spo2Offset64ValueCount: 0,
                                             spo2Offset66ValueSum: 0,
                                             spo2Offset66ValueCount: 0)
    }

    /// Fully prepared restore output produced away from the MainActor. The
    /// carrier is immutable; `@unchecked` is limited to legacy value types
    /// (`HRSample`, `RRInterval`, and `SavedSession`) that predate Sendable
    /// annotations but contain no shared mutable reference state here.
    struct Preparation: @unchecked Sendable {
        struct JournalIdentity: Equatable, Sendable {
            let id: UUID
            let updatedAt: Date
            let schema: Int
            let sampleCount: Int
            let rrSampleCount: Int
        }

        enum TerminalDisposition: Equatable, Sendable {
            case absent
            case schemaMismatch(identity: JournalIdentity)
            case stale(age: TimeInterval, identity: JournalIdentity)
            case insufficientSamples(identity: JournalIdentity)
        }

        struct HeartRateStats: Equatable, Sendable {
            let minimum: Int?
            let maximum: Int?
            let total: Int
            let count: Int
            let mean: Double
            let m2: Double
        }

        struct LivePayload: @unchecked Sendable {
            let record: ActiveSessionJournalRecord
            let now: Date
            let age: TimeInterval
            let session: [HRSample]
            let sessionPoints: [SavedSession.Point]
            let stats: HeartRateStats
            let lastHeartRates: [Int]
            let recentValid: [Int]
            let displayHeartRate: Int
            let rrArchive: [RRInterval]
            let rrPoints: [SavedSession.RRPoint]
            let recentRRBeatTimes: [Date]
            let researchAggregates: ResearchAggregates?
        }

        struct StaleSegmentPayload: @unchecked Sendable {
            let savedSession: SavedSession
            let now: Date
            let age: TimeInterval
            let researchAggregatesWereMalformed: Bool
        }

        enum Payload: @unchecked Sendable {
            case terminal(TerminalDisposition)
            case staleSegment(StaleSegmentPayload)
            case live(LivePayload)
        }

        let payload: Payload
    }

    private static let recentRRBeatWindowSeconds: TimeInterval = 10 * 60

    static func validatedResearchAggregates(
        from record: ActiveSessionJournalRecord
    ) -> ResearchAggregates? {
        let sensorFrames = record.sensorResearchProbeFrames ?? 0
        let spo2Frames = record.spo2ResearchCandidateFrames ?? 0
        let skinTempFrames = record.skinTempResearchCandidateFrames ?? 0
        guard sensorFrames >= 0, spo2Frames >= 0, skinTempFrames >= 0 else { return nil }

        let strap: (steps: Int, raw: Int, state: String?)
        switch (record.strapStepResearchCount, record.strapStepResearchRawCount) {
        case (nil, nil):
            strap = (0, 0, nil)
        case let (steps?, raw?) where steps >= 0 && raw >= 0
            && steps <= 10_000_000 && raw <= 10_000_000:
            strap = (steps, raw, record.strapStepResearchState)
        default:
            return nil
        }

        let gyroCadenceResearchSteps = record.gyroCadenceResearchSteps ?? 0
        guard gyroCadenceResearchSteps >= 0,
              gyroCadenceResearchSteps <= 10_000_000 else { return nil }

        let temperatureValues: (sum: Int, count: Int)
        switch (record.skinTempResearchCandidateValueSum,
                record.skinTempResearchCandidateValueCount) {
        case (nil, nil):
            temperatureValues = (0, 0)
        case let (sum?, count?) where sum >= 0 && count >= 0 && (count > 0 || sum == 0):
            temperatureValues = (sum, count)
        default:
            return nil
        }

        let oxygenOffset64Values: (sum: Int, count: Int)
        switch (record.spo2ResearchCandidateOffset64ValueSum,
                record.spo2ResearchCandidateOffset64ValueCount) {
        case (nil, nil):
            oxygenOffset64Values = (0, 0)
        case let (sum?, count?) where sum >= 0 && count >= 0 && (count > 0 || sum == 0):
            oxygenOffset64Values = (sum, count)
        default:
            return nil
        }

        let oxygenOffset66Values: (sum: Int, count: Int)
        switch (record.spo2ResearchCandidateOffset66ValueSum,
                record.spo2ResearchCandidateOffset66ValueCount) {
        case (nil, nil):
            oxygenOffset66Values = (0, 0)
        case let (sum?, count?) where sum >= 0 && count >= 0 && (count > 0 || sum == 0):
            oxygenOffset66Values = (sum, count)
        default:
            return nil
        }
        return ResearchAggregates(sensorProbeFrames: sensorFrames,
                                  spo2CandidateFrames: spo2Frames,
                                  skinTempCandidateFrames: skinTempFrames,
                                  skinTempCandidateValueSum: temperatureValues.sum,
                                  skinTempCandidateValueCount: temperatureValues.count,
                                  spo2Offset64ValueSum: oxygenOffset64Values.sum,
                                  spo2Offset64ValueCount: oxygenOffset64Values.count,
                                  spo2Offset66ValueSum: oxygenOffset66Values.sum,
                                  spo2Offset66ValueCount: oxygenOffset66Values.count,
                                  strapSteps: strap.steps,
                                  strapRawSteps: strap.raw,
                                  strapDeviceTimestamp: record.strapStepResearchDeviceTimestamp
                                      .flatMap { $0 > 0 ? $0 : nil },
                                  strapStepState: strap.state,
                                  gyroCadenceResearchSteps: gyroCadenceResearchSteps,
                                  hasGyroCadenceResearchEvidence:
                                      record.gyroCadenceResearchSteps != nil)
    }

    static func prepare(
        _ record: ActiveSessionJournalRecord?,
        now: Date,
        maxAge: TimeInterval,
        maxSamples: Int,
        segmentGapLimit: TimeInterval,
        biologicalSex: AthleteProfile.BiologicalSex
    ) -> Preparation {
        guard let record else {
            return Preparation(payload: .terminal(.absent))
        }
        let identity = Preparation.JournalIdentity(
            id: record.id,
            updatedAt: record.updatedAt,
            schema: record.schema,
            sampleCount: record.samples.count,
            rrSampleCount: record.rrSamples?.count ?? 0
        )
        guard record.schema == ActiveSessionJournal.schema else {
            return Preparation(payload: .terminal(.schemaMismatch(identity: identity)))
        }

        let age = now.timeIntervalSince(record.updatedAt)
        guard age <= maxAge else {
            return Preparation(payload: .terminal(.stale(age: age, identity: identity)))
        }

        let retainedSamples = Array(
            record.samples
                .filter { now.timeIntervalSince($0.t) <= maxAge }
                .suffix(max(0, maxSamples))
        )
        let retainedRRSamples = (record.rrSamples ?? [])
            .filter { now.timeIntervalSince($0.t) <= maxAge }
        guard let first = retainedSamples.first,
              let last = retainedSamples.last,
              retainedSamples.count > 1 else {
            return Preparation(payload: .terminal(.insufficientSamples(identity: identity)))
        }

        let researchAggregates = validatedResearchAggregates(from: record)
        let label = record.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "All-day wear"
            : record.label
        let scopedRRSamples = retainedRRSamples.filter {
            $0.t >= first.t && $0.t <= last.t.addingTimeInterval(1)
        }
        // A decoded legacy journal remains inspectable, but only a stream whose
        // every retained beat explicitly identifies standard 2A37 may re-enter
        // live HRV/recovery/stress/breathwork calculations. Never salvage the
        // standard-looking subset of a mixed fallback stream as one continuous
        // validated window.
        let qualifiedStandardRRSamples = scopedRRSamples.allSatisfy({
            $0.source == .standardHeartRateMeasurement2A37
        }) ? scopedRRSamples : []

        if age >= segmentGapLimit {
            let saved = SavedSession(
                id: record.id,
                start: first.t,
                end: last.t,
                label: label,
                points: retainedSamples.map {
                    SavedSession.Point(t: $0.t.timeIntervalSince(first.t), bpm: $0.bpm)
                },
                hrv: nil,
                rrPoints: scopedRRSamples.isEmpty ? nil : scopedRRSamples.map {
                    SavedSession.RRPoint(t: $0.t.timeIntervalSince(first.t),
                                         ms: $0.ms,
                                         source: $0.source)
                },
                hrvReferenceValidated: false,
                motionHintCount: nil,
                motionHintKinds: nil,
                motionEvidenceSource: "unavailable",
                motionEvidenceValidated: false,
                motionShortCount: nil,
                motionShortMean: nil,
                motionShortMin: nil,
                motionShortMax: nil,
                motionShortOverOneCount: nil,
                strapStepResearchCount: researchAggregates.map(\.strapSteps).flatMap { $0 > 0 ? $0 : nil },
                strapStepResearchAgreement: nil,
                strapStepResearchState: researchAggregates?.strapStepState,
                sensorResearchProbeFrames: researchAggregates?.sensorProbeFrames,
                spo2ResearchCandidateFrames: researchAggregates?.spo2CandidateFrames,
                skinTempResearchCandidateFrames: researchAggregates?.skinTempCandidateFrames,
                skinTempResearchCandidateValueSum: researchAggregates?.skinTempCandidateValueSum,
                skinTempResearchCandidateValueCount: researchAggregates?.skinTempCandidateValueCount,
                spo2ResearchCandidateOffset64ValueSum: researchAggregates?.spo2Offset64ValueSum,
                spo2ResearchCandidateOffset64ValueCount: researchAggregates?.spo2Offset64ValueCount,
                spo2ResearchCandidateOffset66ValueSum: researchAggregates?.spo2Offset66ValueSum,
                spo2ResearchCandidateOffset66ValueCount: researchAggregates?.spo2Offset66ValueCount,
                biologicalSex: biologicalSex,
                hrRaw2A37: record.rawHRNotifications,
                hrAccepted: record.acceptedHRSamples,
                hrZero: record.zeroHRSamples,
                hrArtifactHeld: record.heldArtifacts,
                hrArtifactDropped: record.droppedArtifacts,
                hrRawGaps: record.rawHRGaps,
                hrAcceptedGaps: record.acceptedHRGaps,
                hrMaxRawGap: record.maxRawHRGap,
                hrMaxAcceptedGap: record.maxAcceptedHRGap,
                strengthSets: record.strengthSets,
                excludedIntervals: record.excludedIntervals,
                eventTimeZoneIdentifier: record.eventTimeZoneIdentifier
            )
            return Preparation(payload: .staleSegment(
                Preparation.StaleSegmentPayload(
                    savedSession: saved,
                    now: now,
                    age: age,
                    researchAggregatesWereMalformed: researchAggregates == nil
                )
            ))
        }

        let session = retainedSamples.map { HRSample(t: $0.t, bpm: $0.bpm) }
        let rrArchive = qualifiedStandardRRSamples.map {
            RRInterval(t: $0.t,
                       ms: Double($0.ms),
                       expectedHR: nil,
                       source: .standardHeartRateMeasurement2A37)
        }
        let recentValid = Array(session.suffix(5).map(\.bpm))
        let live = Preparation.LivePayload(
            record: record,
            now: now,
            age: age,
            session: session,
            sessionPoints: retainedSamples.map {
                SavedSession.Point(t: $0.t.timeIntervalSince(first.t), bpm: $0.bpm)
            },
            stats: heartRateStats(for: retainedSamples),
            lastHeartRates: Array(session.suffix(60).map(\.bpm)),
            recentValid: recentValid,
            displayHeartRate: median(recentValid) ?? last.bpm,
            rrArchive: rrArchive,
            rrPoints: qualifiedStandardRRSamples.map {
                SavedSession.RRPoint(t: $0.t.timeIntervalSince(first.t),
                                     ms: $0.ms,
                                     source: .standardHeartRateMeasurement2A37)
            },
            recentRRBeatTimes: rrArchive.compactMap {
                now.timeIntervalSince($0.t) <= recentRRBeatWindowSeconds ? $0.t : nil
            },
            researchAggregates: researchAggregates
        )
        return Preparation(payload: .live(live))
    }

    private static func heartRateStats(
        for samples: [ActiveSessionJournalRecord.Sample]
    ) -> Preparation.HeartRateStats {
        guard !samples.isEmpty else {
            return .init(minimum: nil, maximum: nil, total: 0, count: 0, mean: 0, m2: 0)
        }
        var minimum = Int.max
        var maximum = Int.min
        var total = 0
        var count = 0
        var mean = 0.0
        var m2 = 0.0
        for sample in samples {
            minimum = min(minimum, sample.bpm)
            maximum = max(maximum, sample.bpm)
            total += sample.bpm
            count += 1
            let value = Double(sample.bpm)
            let delta = value - mean
            mean += delta / Double(count)
            m2 += delta * (value - mean)
        }
        return .init(
            minimum: minimum == Int.max ? nil : minimum,
            maximum: maximum == Int.min ? nil : maximum,
            total: total,
            count: count,
            mean: mean,
            m2: m2
        )
    }

    private static func median(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }
}
